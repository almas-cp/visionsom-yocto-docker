# VisionSOM-STM32MP1 — Dockerised Yocto Scarthgap Build

Portable, reproducible build environment for:

- **Board:** SoMLabs VisionSOM-STM32MP1 (SLS18)
- **OS:** OpenSTLinux 6.6 / Yocto Scarthgap (5.0)
- **Extras:** LoRaWAN (Basics Station) + Azure IoT Edge 1.5.x

All build state (sources, sstate-cache, downloads, images) lives on the **host**
via bind mounts. The Docker image is stateless — you can wipe and rebuild it
without losing your build cache.

---

## Directory Layout

```
visionsom-yocto-docker/
├── Dockerfile                          ← Build environment image
├── docker-compose.yml                  ← Service definition + volume mounts
├── .env.example                        ← Machine/path config template (copy to .env)
├── scripts/
│   ├── init.sh                         ← First-time workspace setup (run once)
│   ├── build.sh                        ← Configure layers + run bitbake
│   └── shell.sh                        ← Interactive BitBake shell
└── layers/
    └── meta-st-stm32mpu-app-lorawan/   ← LoRaWAN layer (ported to Scarthgap)
        ├── conf/layer.conf
        ├── recipes-framework/basicstation/
        ├── recipes-kernel/linux/
        └── recipes-st/images/

workspace/          ← Created by init.sh (gitignored)
  st-yocto/
    layers/         ← All meta layers
    build-*/        ← BitBake build dirs
cache/
  sstate/           ← Shared sstate-cache (share via NFS for multi-machine)
  downloads/        ← Shared DL_DIR
```

---

## Prerequisites

- Docker Engine 24+ and Docker Compose v2
- ~200 GB free disk space (first build)
- 8+ CPU cores and 16 GB RAM recommended

---

## Quick Start

### Step 1 — Build the Docker image

```bash
# Clone this repo
git clone <your-repo-url>
cd visionsom-yocto-docker

# Copy and edit the environment file
cp .env.example .env
nano .env

# Build the Docker image (~5 min, one-time)
docker compose build
```

### Step 2 — Configure `.env`

If you haven't already, copy the template and edit for your machine:

```bash
# Match to your Linux user: id -u && id -g
HOST_UID=1000
HOST_GID=1000

# Choose your VisionSOM variant:
MACHINE=mp157a-hdmi-lt-emmc-mx    # HDMI
# MACHINE=mp157a-dsi-rvt-emmc-mx  # DSI display

# Adjust to your CPU core count
BB_NUMBER_THREADS=8
PARALLEL_MAKE=-j8
```

### Step 3 — Initialise the workspace (first time only)

This fetches ~10 GB of sources. Takes 20–60 min depending on your connection.

```bash
docker compose run --rm yocto-build /home/yocto/scripts/init.sh
```

### Step 4 — Build the image

First build: **4–8 hours**. Subsequent builds: **5–30 min** (sstate-cache).

```bash
docker compose run --rm yocto-build /home/yocto/scripts/build.sh
```

### Step 5 — Flash to VisionSOM eMMC

```bash
# Set BOOT jumpers to 000, connect USB-OTG, then:
STM32_Programmer_CLI -c port=usb1 \
  -w workspace/st-yocto/build-openstlinuxweston-mp157a-hdmi-lt-emmc-mx/\
tmp-glibc/deploy/images/mp157a-hdmi-lt-emmc-mx/\
flashlayout_st-image-weston/optee/FlashLayout_emmc_mp157a-hdmi-lt-emmc-mx-optee.tsv

# Set BOOT jumpers to 010 to boot from eMMC
```

---

## Using on Multiple Machines (Team Setup)

The build is designed to be shared across machines via a shared cache:

```
Machine A (builder)              NAS / shared storage
┌─────────────────┐             ┌────────────────────────────┐
│  Docker build   │────writes──▶│  /nas/yocto/sstate-cache   │
│  workspace/     │             │  /nas/yocto/downloads      │
└─────────────────┘             └────────────────────────────┘
                                          │
Machine B (another builder)               │
┌─────────────────┐             reads ◀──┘
│  Docker build   │─────────────────────────
│  workspace/     │   (hits sstate, skips rebuild)
└─────────────────┘
```

On each machine, point `.env` to the shared NFS mount:

```bash
SSTATE_CACHE=/mnt/nas/yocto/sstate-cache
DL_DIR=/mnt/nas/yocto/downloads
```

---

## Useful Commands

```bash
# Interactive shell with BitBake env sourced
docker compose run --rm yocto-build /home/yocto/scripts/shell.sh

# Build a single recipe
docker compose run --rm yocto-build bash -c "
  source /yocto/st-yocto/layers/meta-st/scripts/envsetup.sh &&
  bitbake basicstation
"

# Clean a recipe
docker compose run --rm yocto-build bash -c "
  source /yocto/st-yocto/layers/meta-st/scripts/envsetup.sh &&
  bitbake -c cleansstate basicstation && bitbake basicstation
"

# Check layer compatibility
docker compose run --rm yocto-build bash -c "
  source /yocto/st-yocto/layers/meta-st/scripts/envsetup.sh &&
  bitbake-layers show-layers
"

# Manual BitBake invocation (useful for debugging)
docker compose run --rm yocto-build bash -c "
  cd /yocto/st-yocto
  export MACHINE=mp157a-dsi-rvt-emmc-mx
  export DISTRO=openstlinux-weston
  export META_LAYER_ROOT=layers/meta-st
  set +euo pipefail
  source layers/meta-st/scripts/envsetup.sh
  cd \${BUILDDIR}
  bitbake st-image-weston
"
```

---

## Post-Boot: Provision Azure IoT Edge

```bash
# SSH into the VisionSOM
ssh root@<device-ip>

# Edit provisioning config
nano /etc/aziot/config.toml

# Apply and start
iotedge config apply
systemctl restart aziot-edged

# Verify
iotedge check
iotedge list
```

## Post-Boot: Start LoRaWAN Gateway

```bash
# Copy your station.conf from the example
cp /etc/basicstation/station.conf.example /etc/basicstation/station.conf
nano /etc/basicstation/station.conf   # Set your LNS/CUPS URI and keys

# Enable and start
systemctl enable basicstation
systemctl start basicstation
journalctl -fu basicstation
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `LAYERSERIES_COMPAT` warning | Check `conf/layer.conf` has `scarthgap` |
| `RDEPENDS_xxx` syntax error | Run the bulk sed in the porting guide |
| IoT Edge TLS cert errors | Add `CFLAGS:remove:arm = "-D_TIME_BITS=64"` to `local.conf` |
| `aziot-tpmd` fails to start | The `.bbappend` disables it — check it's in the layer |
| `do_fetch` network error | Check proxy settings in `.env` |
| Build dir path too long | Move `workspace/` closer to filesystem root |
| Docker permission denied | Run `sg docker -c "docker compose ..."` or log out/in after `usermod -aG docker` |
