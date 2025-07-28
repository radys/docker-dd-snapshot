#!/bin/bash

# This script creates a forensically sound dd image of a Docker container,
# ensuring that all original file MACB timestamps are preserved.
# It requires root privileges to run.

# Exit immediately if a command exits with a non-zero status,
# if it tries to use an undefined variable, or if a command in a pipeline fails.
set -euo pipefail

# --- Configuration ---
# You can change these variables to target a different container or verification file.
CONTAINER_NAME="my-container"
VERIFICATION_FILE="/etc/hosts" # A file that is guaranteed to exist in the container.

# --- Path and Device Setup ---
# All generated files will be placed in a 'forensic_image_output' directory.
OUTPUT_DIR="./forensic_image_output"
IMG_PATH="${OUTPUT_DIR}/docker-container.img"
TARFILE="${OUTPUT_DIR}/rootfs.tar"
TIMESTAMP_EXPORT_PATH="${OUTPUT_DIR}/macb_list.txt"
MOUNTPOINT="${OUTPUT_DIR}/mountpoint"
LOOPDEV=$(losetup -f) # Find the next available loop device

# --- Docker Container Check ---
echo "[i] Checking for Docker container '$CONTAINER_NAME'..."
if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "Error: Docker container named '$CONTAINER_NAME' does not exist." >&2
  exit 1
fi
echo "[+] Container found."

# --- Preparation and Cleanup ---
echo "[i] Cleaning up from previous runs and preparing directories..."
umount "$MOUNTPOINT" 2>/dev/null || true
if losetup -a | grep -q "$LOOPDEV"; then
  losetup -d "$LOOPDEV" 2>/dev/null || true
fi
rm -rf "$OUTPUT_DIR"
mkdir -p "$MOUNTPOINT"

# --- Create and Prepare Disk Image ---
echo "[+] Creating a 2GB disk image: $IMG_PATH"
dd if=/dev/zero of="$IMG_PATH" bs=1M count=2048 status=progress
echo "[+] Formatting image with ext4 filesystem..."
mkfs.ext4 -F "$IMG_PATH"

# --- Get Container's Timezone Offset ---
# This is the key to correct timestamp restoration. We calculate the difference
# between the container's local time and UTC time in seconds.
echo "[i] Getting timezone offset from container '$CONTAINER_NAME'..."
OFFSET_SECONDS=$(docker exec "$CONTAINER_NAME" bash -c 'echo "$(($(date +%s) - $(date -u +%s)))"')
echo "[i] Container timezone offset is: $OFFSET_SECONDS seconds from UTC."

# --- Export Raw Epoch Timestamps from Container ---
echo "[+] Exporting raw MACB timestamps from container to $TIMESTAMP_EXPORT_PATH"
docker exec "$CONTAINER_NAME" bash -c '
  find / -xdev $ -type f -o -type d -o -type l $ 2>/dev/null | while read -r f; do
    # Export: filepath|ctime|mtime|atime|crtime (all as epoch seconds)
    stat_out=$(stat --format="%n|%Z|%Y|%X|%W" "$f" 2>/dev/null)
    if [ -n "$stat_out" ]; then
      echo "$stat_out"
    fi
  done
' > "$TIMESTAMP_EXPORT_PATH"

# --- Export Filesystem and Populate Image ---
echo "[+] Exporting container filesystem to $TARFILE..."
docker export "$CONTAINER_NAME" -o "$TARFILE"
echo "[+] Mounting disk image and extracting archive..."
mount -o loop "$IMG_PATH" "$MOUNTPOINT"
tar -xf "$TARFILE" -C "$MOUNTPOINT"
echo "[+] Filesystem extracted. Unmounting image to apply timestamps."
umount "$MOUNTPOINT"

# --- Verification (Before) ---
echo "[i] Getting timestamps for '$VERIFICATION_FILE' BEFORE restoration for comparison..."
# Use losetup to ensure debugfs works on a non-mounted image
losetup "$LOOPDEV" "$IMG_PATH"
TIMESTAMPS_BEFORE=$(debugfs -R "stat $VERIFICATION_FILE" "$LOOPDEV" 2>/dev/null || echo "File not found.")

# --- Apply Original Timestamps ---
echo "[+] Applying original timestamps to the image, adjusted for timezone..."
while IFS='|' read -r filepath ctime mtime atime crtime; do
  # Remove leading '/' to make path relative for debugfs
  filepath_rel=${filepath#/}
  
  # Skip if the file/dir doesn't exist in the image (e.g., /proc, /sys)
  if ! debugfs -R "stat $filepath_rel" "$LOOPDEV" >/dev/null 2>&1; then
    continue
  fi

  # Adjust epoch time by the container's timezone offset to get the true UTC time
  ctime_adj=$((ctime - OFFSET_SECONDS))
  mtime_adj=$((mtime - OFFSET_SECONDS))
  atime_adj=$((atime - OFFSET_SECONDS))
  crtime_adj=$((crtime - OFFSET_SECONDS))

  # If crtime is 0 (not supported by FS), use ctime as a fallback.
  if [ "$crtime" -eq 0 ]; then
    crtime_adj=$ctime_adj
  fi

  # Convert the *adjusted* epoch time to the YYYYMMDDHHMMSS format that debugfs requires
  ctime_fmt=$(date -u -d @"$ctime_adj" "+%Y%m%d%H%M%S")
  mtime_fmt=$(date -u -d @"$mtime_adj" "+%Y%m%d%H%M%S")
  atime_fmt=$(date -u -d @"$atime_adj" "+%Y%m%d%H%M%S")
  crtime_fmt=$(date -u -d @"$crtime_adj" "+%Y%m%d%H%M%S")

  # Pipe commands directly to debugfs for efficiency
  {
    echo "set_inode_field $filepath_rel ctime $ctime_fmt"
    echo "set_inode_field $filepath_rel crtime $crtime_fmt"
    echo "set_inode_field $filepath_rel mtime $mtime_fmt"
    echo "set_inode_field $filepath_rel atime $atime_fmt"
  } | debugfs -w "$LOOPDEV" >/dev/null

done < "$TIMESTAMP_EXPORT_PATH"
echo "[+] Timestamp restoration complete."

# --- Verification (After) ---
echo "[i] Getting timestamps for '$VERIFICATION_FILE' AFTER restoration..."
TIMESTAMPS_AFTER=$(debugfs -R "stat $VERIFICATION_FILE" "$LOOPDEV" 2>/dev/null || echo "File not found.")

echo -e "\n--- TIMESTAMPS BEFORE (from tar extraction) ---\n$TIMESTAMPS_BEFORE"
echo -e "\n--- TIMESTAMPS AFTER (restored to match container time) ---\n$TIMESTAMPS_AFTER"

# --- Final Cleanup ---
echo "[i] Detaching loop device..."
losetup -d "$LOOPDEV"
echo -e "\n[+] Done. The final image is located at: $IMG_PATH"
