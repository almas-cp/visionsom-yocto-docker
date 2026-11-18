# WSL2 Setup Guide — VisionSOM-STM32MP1 Yocto Build

This guide walks you through setting up a clean Windows 10/11 system to build the VisionSOM-STM32MP1 Yocto image using **WSL2** (Windows Subsystem for Linux) and **Docker**.

---

## 1. Prerequisites & Hardware Requirements

* **Windows Version**: Windows 11 (recommended) or Windows 10 (Build 19041 or higher).
* **CPU**: 8+ physical cores recommended.
* **RAM**: Minimum **16 GB** (32 GB recommended). BitBake is extremely memory-intensive.
* **Storage**: Minimum **200–250 GB** free space on an SSD (NVMe preferred).

---

## 2. Step 1: Install & Set Up WSL2

Open **PowerShell as Administrator** on Windows and run:

```powershell
# Install WSL2 with Ubuntu 22.04 LTS
wsl --install -d Ubuntu-22.04

# Ensure WSL2 is the default version
wsl --set-default-version 2
```

Restart your computer if prompted. Launch **Ubuntu 22.04** from the Start Menu, complete initial user setup (`username` and `password`).

> [!TIP]
> **Windows 11 Users — Enable Sparse VHD (Automatic Disk Space Reclaim)**
> By default, the WSL `.vhdx` file only grows and never shrinks when files are deleted. Run this in Windows PowerShell while WSL is shut down:
> ```powershell
> wsl --shutdown
> wsl --manage Ubuntu-22.04 --set-sparse true
> ```

---

## 3. Step 2: Configure `.wslconfig` (Critical for Yocto)

Yocto builds can easily exhaust host RAM and lock up Windows without limits. Configure resource allocations by creating `%USERPROFILE%\.wslconfig` on Windows.

1. In Windows, press `Win + R`, type `notepad %USERPROFILE%\.wslconfig`, and hit Enter.
2. Paste the following configuration (adjust to your machine's hardware):

```ini
[wsl2]
# Allocate ~75% of your total system RAM (e.g., 24GB on a 32GB system, or 12GB on 16GB)
memory=16GB

# Allocate dedicated swap space on SSD to prevent out-of-memory (OOM) compiler crashes
swap=16GB

# Allocate CPU cores (leave 2 cores for Windows)
processors=8

# Enable page reporting to return unused memory to Windows
pageReporting=true
```

3. Save the file and restart WSL in PowerShell:
```powershell
wsl --shutdown
```
Re-open Ubuntu 22.04.

---

## 4. Step 3: CRITICAL RULE — Never Use `/mnt/c/`

> [!CAUTION]
> **Do NOT clone or build the project under `/mnt/c/...`!**
> Accessing NTFS drives through `/mnt/c/` causes:
> - Up to 10× slower disk I/O performance.
> - Case-insensitivity issues that break Linux kernel and BitBake builds.
> - File permission/POSIX compatibility failures.
>
> **Always store and run the build inside the native Linux filesystem** (e.g., `/home/<username>/...`).

---

## 5. Step 4: Install Docker & Docker Compose inside Ubuntu

Run all the following commands **inside your Ubuntu 22.04 terminal**:

```bash
# 1. Update package index and install prerequisites
sudo apt update && sudo apt install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git \
    rsync

# 2. Install Docker Engine directly in WSL2
sudo apt install -y docker.io docker-compose-v2

# 3. Add your current user to the docker group
sudo usermod -aG docker $USER

# 4. Activate docker group for the current terminal session
newgrp docker

# 5. Start and enable Docker service
sudo systemctl enable --now docker
```

Verify that Docker works without `sudo`:
```bash
docker ps
docker compose version
```

---

## 6. Step 5: Clone and Configure the Repository

```bash
# 1. Navigate to your Linux home directory
cd ~

# 2. Clone the repository
git clone <your-repository-url> visionsom-yocto-docker
cd visionsom-yocto-docker

# 3. Ensure all scripts are executable
chmod +x run_build.sh save.sh scripts/*.sh

# 4. Create and edit your .env configuration
cp .env.example .env
nano .env
```

### Key `.env` Settings for WSL2:
Ensure the following variables match your environment:
```bash
# Run `id -u` and `id -g` to check (almost always 1000 in Ubuntu)
HOST_UID=1000
HOST_GID=1000

# Keep workspace relative to the project directory
YOCTO_WORKSPACE=./workspace
SSTATE_CACHE=./cache/sstate
DL_DIR=./cache/downloads

# Target board:
# mp157a-hdmi-lt-emmc-mx  → VisionSOM with HDMI
# mp157a-dsi-rvt-emmc-mx  → VisionSOM with DSI display
MACHINE=mp157a-dsi-rvt-emmc-mx

# Match threads to processors allocated in .wslconfig
BB_NUMBER_THREADS=8
PARALLEL_MAKE=-j8
```

---

## 7. Step 6: Run the Build

Run the automated build script:

```bash
./run_build.sh
```

### What to Expect:
1. **Container Build** (~3–5 minutes): Builds the Ubuntu 22.04 container with Yocto Scarthgap tools.
2. **Workspace Init & Fetch** (~20–40 minutes): Fetches OpenSTLinux manifests, Yocto layers, and clones sub-layers (~10 GB).
3. **Compilation & Packaging** (~3–6 hours on first build): Compiles cross-toolchains, kernel, and image packages.

---

## 8. Step 7: Accessing & Flashing the Built Images

Once the build finishes, image files are located at:
```bash
~/visionsom-yocto-docker/workspace/st-yocto/build-openstlinuxweston-*/tmp-glibc/deploy/images/${MACHINE}/
```

### Option A: Flash from Windows using STM32CubeProgrammer (Recommended)

1. You can access the WSL2 filesystem directly from Windows Explorer at:
   `\\wsl$\Ubuntu-22.04\home\<your-user>\visionsom-yocto-docker\`
2. Open **STM32CubeProgrammer** on Windows.
3. Set board BOOT jumpers to USB DFU mode: **BOOT0=0, BOOT1=0, BOOT2=0**.
4. Connect the carrier board's **USB-OTG** port to your Windows PC.
5. In STM32CubeProgrammer, select **USB**, click **Connect**.
6. Select the TSV layout file:
   `flashlayout_st-image-core/optee/FlashLayout_emmc_*.tsv`
7. Click **Download** to flash the eMMC.

### Option B: USB Passthrough to WSL with `usbipd-win`

If you prefer flashing via the command line inside WSL:
1. In Windows PowerShell (Admin), install usbipd:
   ```powershell
   winget install --interactive --exact dorssel.usbipd-win
   ```
2. Put the board in DFU mode and find the device:
   ```powershell
   usbipd list
   usbipd bind --busid <BUSID>
   usbipd attach --wsl --busid <BUSID>
   ```
3. Inside WSL, flash using `STM32_Programmer_CLI`.

---

## 9. Troubleshooting & FAQ

| Issue | Cause | Solution |
|---|---|---|
| `mkdir: Permission denied` | Docker volume owned by root or wrong `.env` path | Ensure `YOCTO_WORKSPACE=./workspace` in `.env` and run `mkdir -p workspace cache`. |
| `Cannot connect to docker daemon` | User not in docker group or docker service stopped | Run `sudo systemctl start docker` and `newgrp docker`. |
| Build gets killed (Exit code 137 / OOM) | Out of RAM / compiler killed by Linux OOM killer | Increase `memory` and `swap` in `%USERPROFILE%\.wslconfig`, or lower `BB_NUMBER_THREADS=4`. |
| WSL disk full error | `.vhdx` consumed entire partition | Clean up old BitBake tmp dirs: `rm -rf workspace/st-yocto/build-*/tmp-glibc` and shrink with `wsl --manage Ubuntu-22.04 --set-sparse true`. |
| Extremely slow build (days instead of hours) | Project located in `/mnt/c/` | Move the entire folder into `~/` in the native Linux filesystem. |
