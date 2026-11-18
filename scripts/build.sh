#!/usr/bin/env bash
set -euo pipefail

MACHINE="${MACHINE:-mp157a-dsi-rvt-emmc-mx}"
TARGET_MACHINE="${MACHINE}"
DISTRO="openstlinux-weston"
IMAGE="st-image-core"
SRC_DIR="/yocto/st-yocto"
BB_NUMBER_THREADS="${BB_NUMBER_THREADS:-16}"
PARALLEL_MAKE="${PARALLEL_MAKE:--j16}"

echo "============================================================"
echo " VisionSOM-STM32MP1 Yocto Scarthgap — Build"
echo " MACHINE:  ${MACHINE}"
echo " DISTRO:   ${DISTRO}"
echo " IMAGE:    ${IMAGE}"
echo " THREADS:  ${BB_NUMBER_THREADS}"
echo "============================================================"

if [ ! -d "${SRC_DIR}/.repo" ]; then
    echo "ERROR: Workspace not initialised. Run init.sh first."
    exit 1
fi

cd "${SRC_DIR}"

export MACHINE="${MACHINE}"
export DISTRO="${DISTRO}"
export META_LAYER_ROOT="layers/meta-st"
export _ENABLE_UI=0

# Sync custom base DTS file into meta-somlabs BSP layer if present
SOMLABS_DTS="${SRC_DIR}/layers/meta-st/meta-somlabs/mx/stm32mp157a-dsi-rvt70hsmnwc00-emmc-mx/kernel/stm32mp157a-dsi-rvt70hsmnwc00-emmc-mx.dts"
CUSTOM_DTS="${SRC_DIR}/layers/meta-st/meta-st-stm32mpu-app-lorawan/recipes-kernel/linux/linux-stm32mp/stm32mp157a-dsi-rvt70hsmnwc00-emmc-mx.dts"
if [ -f "${CUSTOM_DTS}" ] && [ -d "$(dirname "${SOMLABS_DTS}")" ]; then
    echo "Syncing custom base DTS file into meta-somlabs..."
    cp "${CUSTOM_DTS}" "${SOMLABS_DTS}"
fi

# Disable strict mode — envsetup.sh has intentionally unbound variables
set +euo pipefail
source layers/meta-st/scripts/envsetup.sh
BUILDDIR="${BUILDDIR:-${SRC_DIR}/build-openstlinuxweston-${MACHINE}}"
set -euo pipefail

cd "${BUILDDIR}"
echo "Build directory: ${BUILDDIR}"

add_layer() {
    local layer="$1"
    if ! grep -q "/$(basename "${layer}")" conf/bblayers.conf 2>/dev/null; then
        echo "Adding layer: ${layer}"
        bitbake-layers add-layer "${layer}"
    else
        echo "Layer already present: $(basename "${layer}")"
    fi
}

remove_layer() {
    local layer="$1"
    if bitbake-layers show-layers 2>/dev/null | grep -q "$(basename "${layer}")"; then
        echo "Removing layer: $(basename "${layer}")"
        bitbake-layers remove-layer "${layer}" 2>/dev/null || true
    fi
}
add_layer "${SRC_DIR}/layers/meta-openembedded/meta-oe"
add_layer "${SRC_DIR}/layers/meta-openembedded/meta-python"
add_layer "${SRC_DIR}/layers/meta-openembedded/meta-networking"
add_layer "${SRC_DIR}/layers/meta-openembedded/meta-filesystems"
add_layer "${SRC_DIR}/layers/meta-st/meta-st-stm32mp-addons"
add_layer "${SRC_DIR}/layers/meta-st/meta-somlabs"
add_layer "${SRC_DIR}/layers/meta-st/meta-st-stm32mpu-app-lorawan"
# meta-virtualization is required by meta-iotedge (LAYERDEPENDS).
# We include it but do NOT add moby-engine to IMAGE_INSTALL:
# moby-engine only supports 64-bit (x86_64, aarch64); STM32MP157 is ARMv7.
add_layer "${SRC_DIR}/layers/meta-virtualization"
add_layer "${SRC_DIR}/layers/meta-security"
add_layer "${SRC_DIR}/layers/meta-security/meta-tpm"
add_layer "${SRC_DIR}/layers/meta-clang"
add_layer "${SRC_DIR}/layers/meta-iotedge"

LOCAL_CONF="conf/local.conf"

set_conf() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}" "${LOCAL_CONF}"; then
        # Key exists — update it in-place so stale values from previous runs
        # are always replaced with the current correct value
        local escaped_value
        escaped_value=$(printf '%s\n' "${value}" | sed 's/[[\.*^$()+?{|]/\\&/g')
        sed -i "s|^${key}.*|${escaped_value}|" "${LOCAL_CONF}"
        echo "  (updated) ${key}"
    else
        echo "${value}" >> "${LOCAL_CONF}"
        echo "  (added) ${key}"
    fi
}
# Alias for backwards compatibility
patch_conf() { set_conf "$@"; }

echo "Patching local.conf..."
patch_conf "DL_DIR"                'DL_DIR = "/yocto/downloads"'
patch_conf "SSTATE_DIR"            'SSTATE_DIR = "/yocto/sstate-cache"'
patch_conf "BB_NUMBER_THREADS"     "BB_NUMBER_THREADS = \"${BB_NUMBER_THREADS}\""
patch_conf "PARALLEL_MAKE"         "PARALLEL_MAKE = \"${PARALLEL_MAKE}\""
patch_conf "BB_FETCH_RETRIES"      'BB_FETCH_RETRIES = "5"'
patch_conf "BB_FETCH_TIMEOUT"      'BB_FETCH_TIMEOUT = "30"'
patch_conf "FETCHCMD_wget"         'FETCHCMD_wget = "/usr/bin/env wget -t 2 -T 30 --user-agent=Mozilla/5.0"'
# Pre-accept the SoMLabs BSP EULA (otherwise envsetup opens vi interactively)
patch_conf "ACCEPT_EULA_mp157a-dsi-rvt-emmc-mx"  'ACCEPT_EULA_mp157a-dsi-rvt-emmc-mx = "1"'
patch_conf "ACCEPT_EULA_mp157a-hdmi-lt-emmc-mx"  'ACCEPT_EULA_mp157a-hdmi-lt-emmc-mx = "1"'
patch_conf "CFLAGS:remove:arm"     'CFLAGS:remove:arm = "-D_TIME_BITS=64"'
# Enable virtualization distro feature: required by meta-iotedge (LAYERDEPENDS).
# NOTE: moby-engine is NOT added to IMAGE_INSTALL — it only supports 64-bit
# hosts (x86_64, aarch64). STM32MP157 is 32-bit Cortex-A7 (armhf).
patch_conf "DISTRO_FEATURES:append" 'DISTRO_FEATURES:append = " virtualization seccomp"'
# Strip display/graphics (wayland, x11, opengl, vulkan) and sound/audio (alsa, pulseaudio)
patch_conf "DISTRO_FEATURES:remove" 'DISTRO_FEATURES:remove = " wayland x11 opengl vulkan directfb alsa pulseaudio sound"'
patch_conf "MACHINE_FEATURES:remove" 'MACHINE_FEATURES:remove = " splashscreen gpu alsa"'
patch_conf "BASICSTATION_PLATFORM" 'BASICSTATION_PLATFORM ?= "corecell"'
# IMAGE_INSTALL packages are managed in the LoRaWAN layer bbappend:
#   meta-st-stm32mpu-app-lorawan/recipes-st/images/st-image-weston.bbappend
# That file adds: basicstation iotedge aziot-edged openssh ca-certificates curl jq
# Keep an empty local.conf append as a clean override point for ad-hoc additions.
patch_conf "IMAGE_INSTALL:append"  'IMAGE_INSTALL:append = ""'
# Remove debug-tweaks so root account does not have an empty password
patch_conf "EXTRA_IMAGE_FEATURES"  'EXTRA_IMAGE_FEATURES = ""'
patch_conf "hostname:pn-base-files" 'hostname:pn-base-files = "admin"'

# Increase the maximum rootfs image size to 1.5GB to accommodate Docker and support packages
patch_conf "IMAGE_ROOTFS_MAXSIZE"  'IMAGE_ROOTFS_MAXSIZE:pn-st-image-core = "1500000"'
patch_conf "IMAGE_ROOTFS_MAXSIZE:pn-st-image-userfs" 'IMAGE_ROOTFS_MAXSIZE:pn-st-image-userfs = ""'

# Expand userfs partition (/usr/local) to 1GB for 512MB swapfile and Docker runtime data
patch_conf "STM32MP_USERFS_SIZE"   'STM32MP_USERFS_SIZE = "1048576"'


# Pin Azure IoT Edge component versions to 1.5.x as requested by the user
# (This also avoids unstable/broken 1.6.0-rc.1 patches in meta-iotedge)
patch_conf "PREFERRED_VERSION_aziotd"      'PREFERRED_VERSION_aziotd = "1.5.6"'
patch_conf "PREFERRED_VERSION_aziot-keys"  'PREFERRED_VERSION_aziot-keys = "1.5.6"'
patch_conf "PREFERRED_VERSION_aziotctl"      'PREFERRED_VERSION_aziotctl = "1.5.6"'
patch_conf "PREFERRED_VERSION_aziot-edged"  'PREFERRED_VERSION_aziot-edged = "1.5.21"'
patch_conf "PREFERRED_VERSION_iotedge"      'PREFERRED_VERSION_iotedge = "1.5.21"'

echo ""
echo "============================================================"
echo " Starting BitBake: ${IMAGE}"
echo " First build: 4-8 hours. Subsequent builds: much faster."
echo "============================================================"

# Step 1: Force clean the kernel and bootfs caches so that local DTS changes 
# are guaranteed to be recompiled and packaged into the flashable ext4 image.
echo ""
echo ">>> [Step 1/2] Cleaning caches for kernel and bootfs..."
bitbake -c cleansstate virtual/kernel st-image-bootfs
bitbake -m 2>/dev/null || true
sleep 2

echo ""
echo ">>> [Step 2/2] Building target images: st-image-bootfs and ${IMAGE}..."
# st-image-bootfs holds uImage + DTB; it is NOT rebuilt by "${IMAGE}" alone,
# so kernel/DTS changes would otherwise never reach the flashed bootfs partition.
bitbake st-image-bootfs "${IMAGE}"

echo ""
echo "============================================================"
echo " Build complete!"
echo " Images: ${BUILDDIR}/tmp-glibc/deploy/images/${TARGET_MACHINE}/"
echo "============================================================"
