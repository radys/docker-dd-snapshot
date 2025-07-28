# Docker Forensic Imager

This repository provides a guide and a self-contained script for creating a forensically sound `dd` disk image from a running Docker container. The primary goal is to preserve the original file MACB (Modify, Access, Change, Birth) timestamps accurately, which is critical for digital forensics and incident response.

The script handles common challenges such as timezone differences between the host and the container, ensuring that the timestamps in the final disk image are a true representation of the container's state.

---

## Key Features

* Creates a raw `dd` image of a container's filesystem.
* Preserves original MACB timestamps for all files, directories, and symlinks.
* Automatically handles timezone offsets between the container and the host machine.
* Uses `debugfs` for low-level, direct manipulation of inode metadata.
* Self-contained script with clear configuration variables.
* Includes verification step to compare timestamps before and after the process.

---

## ⚙️ Process Overview

The process is divided into two main parts:

1. **Preparation Phase**
2. **Execution of the Imaging Script**

### 1. Preparation

A target Docker container is identified or created. This container can have any file activity to make the imaging process realistic.

### 2. Script Execution

* **Initialization:**
  The script cleans up old files, creates an empty disk image (`.img`), and formats it with an `ext4` filesystem.

* **Timezone Calculation:**
  It calculates the container's timezone offset in seconds by comparing its local time with UTC. This is crucial for correct timestamp conversion.

* **Timestamp Export:**
  It exports a list of all files from the container along with their raw epoch timestamps (`ctime`, `mtime`, `atime`, `crtime`).

* **Filesystem Export:**
  The entire container filesystem is exported into a `.tar` archive.

* **Population:**
  The script extracts the `.tar` archive into the mounted disk image. At this point, all timestamps reflect the extraction time, not the original time.

* **Timestamp Restoration:**
  It reads the exported list, adjusts each original timestamp using the calculated timezone offset, and uses `debugfs` to write the correct timestamps directly into the filesystem's inodes.

* **Verification:**
  Finally, it shows the timestamps of a specific file before and after the restoration process to prove it was successful.

---

## Usage Instructions

### Step 1: Prepare a Target Container

First, you need a running Docker container to image. If you don't have one, you can create a demo container and modify some files inside it.

```bash
# 1. Run a container in the background
docker run -d -it --name my-container debian:bullseye-slim sleep infinity

# 2. Create a test file and modify another to generate some activity
docker exec my-container touch /root/new_file.txt
docker exec my-container sh -c 'echo "data" >> /etc/hosts'
docker exec my-container touch -d "2021-05-10 14:00:00" /root/new_file.txt # Backdate a file
```

---

### Step 2: Run the Imaging Script

Save the script as `create_image.sh`, make it executable, and run it. The script will guide you through the process and create the `forensic_image_output` directory with the final image and intermediate files.

> **Note:** Root privileges are required because the script uses `losetup`, `mount`, and `debugfs`.

```bash
# Make the script executable
chmod +x create_image.sh

# Run the script with sudo
sudo ./create_image.sh
```

---

### Step 3: Analyze the Result

After the script finishes, a file named `docker-container.img` will be in the output directory. You can mount this image and inspect its contents:

```bash
# Mount the final image to inspect it
mkdir -p /mnt/container_image
mount ./forensic_image_output/docker-container.img /mnt/container_image

# Check the timestamps of the files
stat /mnt/container_image/root/new_file.txt
stat /mnt/container_image/etc/hosts

# Unmount when you're done
umount /mnt/container_image
```
