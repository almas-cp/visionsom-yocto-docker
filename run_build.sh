#!/usr/bin/env bash
# =============================================================================
# run_build.sh — Automated Master Build Entrypoint
# Run this script on ANY Linux system with Docker installed to pull all dependencies
# and compile the complete VisionSOM-STM32MP1 Yocto image.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "============================================================"
echo " Starting VisionSOM-STM32MP1 Automated Yocto Build Pipeline"
echo "============================================================"

# 1. Verify Docker installation
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed or not available in PATH."
    echo "Please install Docker and Docker Compose before running this script."
    exit 1
fi

# Load .env if present
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
fi

# Ensure workspace and cache directories exist on host with current user permissions
# (prevents Docker from auto-creating them as root:root)
RESOLVED_WORKSPACE="${YOCTO_WORKSPACE:-${SCRIPT_DIR}/workspace}"
RESOLVED_SSTATE="${SSTATE_CACHE:-${SCRIPT_DIR}/cache/sstate}"
RESOLVED_DL="${DL_DIR:-${SCRIPT_DIR}/cache/downloads}"

mkdir -p "${RESOLVED_WORKSPACE}" "${RESOLVED_SSTATE}" "${RESOLVED_DL}"

# 2. Build Docker container environment
echo "[1/4] Building Yocto Docker container image..."
docker compose build

# 3. Initialize workspace and sync upstream ST / SoMLabs / Azure layers
echo "[2/4] Initializing Yocto workspace & fetching upstream layers..."
docker compose run --rm yocto-build /home/yocto/scripts/init.sh

# 4. Synchronize local custom layer into Yocto workspace
echo "[3/4] Synchronizing custom meta-layer into workspace..."
TARGET_LAYER_DIR="${RESOLVED_WORKSPACE}/st-yocto/layers/meta-st/meta-st-stm32mpu-app-lorawan"
if [ -d "${TARGET_LAYER_DIR}" ]; then
    rsync -av --delete "${SCRIPT_DIR}/layers/meta-st-stm32mpu-app-lorawan-scarthgap/" "${TARGET_LAYER_DIR}/"
fi

# 5. Run full BitBake build
echo "[4/4] Starting BitBake image build..."
docker compose run --rm yocto-build /home/yocto/scripts/build.sh

echo ""
echo "============================================================"
echo " Build Complete!"
echo " Flashable images are located in the Yocto deploy directory."
echo "============================================================"
