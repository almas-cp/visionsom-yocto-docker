#!/usr/bin/env bash
# =============================================================================
# init.sh — First-time workspace initialisation
# Run this ONCE to fetch all sources and set up the build environment.
# Subsequent builds use build.sh.
# =============================================================================
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
OPENSTLINUX_TAG="${OPENSTLINUX_TAG:-openstlinux-6.6-yocto-scarthgap-mpu-v24.12.05}"
WORKSPACE="/yocto"
SRC_DIR="${WORKSPACE}/st-yocto"
LAYERS_DIR="${SRC_DIR}/layers"

echo "============================================================"
echo " VisionSOM-STM32MP1 Yocto Scarthgap — Workspace Init"
echo " Tag: ${OPENSTLINUX_TAG}"
echo " Workspace: ${WORKSPACE}"
echo "============================================================"

# ── 1. Fetch ST Distribution Package via repo ─────────────────────────────────
if [ ! -d "${SRC_DIR}/.repo" ]; then
    echo "[1/6] Initialising repo workspace..."
    mkdir -p "${SRC_DIR}"
    cd "${SRC_DIR}"
    repo init \
        -u https://github.com/STMicroelectronics/oe-manifest \
        -b "refs/tags/${OPENSTLINUX_TAG}" \
        --depth=1
else
    echo "[1/6] repo already initialised, syncing..."
    cd "${SRC_DIR}"
fi

echo "[2/6] Syncing all ST layers (this will take a while on first run)..."
repo sync --force-sync -j"$(nproc)" --no-clone-bundle --optimized-fetch

# ── 2. Clone VisionSOM BSP layer ─────────────────────────────────────────────
SOMLABS_DIR="${LAYERS_DIR}/meta-st/meta-somlabs"
if [ ! -d "${SOMLABS_DIR}" ]; then
    echo "[3/6] Cloning meta-somlabs (scarthgap)..."
    git clone -b scarthgap \
        https://github.com/SoMLabs/openst-meta-somlabs.git \
        "${SOMLABS_DIR}"
else
    echo "[3/6] meta-somlabs already present, pulling..."
    git -C "${SOMLABS_DIR}" pull --ff-only
fi

# ── 3. Copy ported LoRaWAN layer ─────────────────────────────────────────────
LORAWAN_SRC="/home/yocto/layers/meta-st-stm32mpu-app-lorawan"
LORAWAN_DST="${LAYERS_DIR}/meta-st/meta-st-stm32mpu-app-lorawan"
if [ ! -d "${LORAWAN_DST}" ]; then
    echo "[4/6] Installing LoRaWAN layer (scarthgap port)..."
    cp -r "${LORAWAN_SRC}" "${LORAWAN_DST}"
else
    echo "[4/6] LoRaWAN layer already present (update manually if needed)."
fi

# ── 4. Clone Azure IoT Edge layer ────────────────────────────────────────────
IOTEDGE_DIR="${LAYERS_DIR}/meta-iotedge"
if [ ! -d "${IOTEDGE_DIR}" ]; then
    echo "[5/6] Cloning meta-iotedge (main = scarthgap)..."
    git clone -b main \
        https://github.com/Azure/meta-iotedge.git \
        "${IOTEDGE_DIR}"
else
    echo "[5/6] meta-iotedge already present, pulling..."
    git -C "${IOTEDGE_DIR}" pull --ff-only
fi

# ── 4.5. Clone meta-virtualization layer (required by meta-iotedge) ───────────
VIRT_DIR="${LAYERS_DIR}/meta-virtualization"
if [ ! -d "${VIRT_DIR}" ]; then
    echo "[5.2/6] Cloning meta-virtualization (scarthgap)..."
    git clone -b scarthgap \
        https://git.yoctoproject.org/meta-virtualization \
        "${VIRT_DIR}"
else
    echo "[5.2/6] meta-virtualization already present, pulling..."
    git -C "${VIRT_DIR}" pull --ff-only
fi

# ── 5. Clone meta-security layer (for tpm2-tss dependency) ───────────────────
SECURITY_DIR="${LAYERS_DIR}/meta-security"
if [ ! -d "${SECURITY_DIR}" ]; then
    echo "[5.5/6] Cloning meta-security (scarthgap)..."
    git clone -b scarthgap \
        https://git.yoctoproject.org/meta-security \
        "${SECURITY_DIR}"
else
    echo "[5.5/6] meta-security already present, pulling..."
    git -C "${SECURITY_DIR}" pull --ff-only
fi

# ── 5.6. Clone meta-clang layer (for clang-native compiler) ──────────────────
CLANG_DIR="${LAYERS_DIR}/meta-clang"
if [ ! -d "${CLANG_DIR}" ]; then
    echo "[5.6/6] Cloning meta-clang (scarthgap)..."
    git clone -b scarthgap \
        https://github.com/kraj/meta-clang.git \
        "${CLANG_DIR}"
else
    echo "[5.6/6] meta-clang already present, pulling..."
    git -C "${CLANG_DIR}" pull --ff-only
fi

# ── 5. Configure shared cache paths ──────────────────────────────────────────
echo "[6/6] Configuring shared download/sstate cache..."
# These will be written into local.conf after envsetup is run (see build.sh)

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " Workspace initialised successfully!"
echo ""
echo " Next step: run build.sh to configure and build the image."
echo "   docker compose run --rm yocto-build /home/yocto/scripts/build.sh"
echo ""
echo " Or for an interactive shell:"
echo "   docker compose run --rm yocto-build bash"
echo "   cd /yocto/st-yocto"
echo "   DISTRO=openstlinux-weston MACHINE=\${MACHINE} \\"
echo "     source layers/meta-st/scripts/envsetup.sh"
echo "============================================================"
