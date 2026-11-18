#!/usr/bin/env bash
# =============================================================================
# shell.sh — Drop into an interactive BitBake-ready shell
# Useful for running individual bitbake commands, devshell, etc.
# =============================================================================
set -euo pipefail

MACHINE="${MACHINE:-mp157a-hdmi-lt-emmc-mx}"
DISTRO="openstlinux-weston"
SRC_DIR="/yocto/st-yocto"

if [ ! -d "${SRC_DIR}/.repo" ]; then
    echo "ERROR: Workspace not initialised. Run init.sh first."
    exit 1
fi

cd "${SRC_DIR}"
DISTRO="${DISTRO}" MACHINE="${MACHINE}" \
    source layers/meta-st/scripts/envsetup.sh

echo ""
echo "BitBake environment ready. Examples:"
echo "  bitbake st-image-weston"
echo "  bitbake basicstation"
echo "  bitbake -c devshell basicstation"
echo "  bitbake-layers show-layers"
echo "  bitbake -e | grep ^MACHINE"
echo ""
exec bash
