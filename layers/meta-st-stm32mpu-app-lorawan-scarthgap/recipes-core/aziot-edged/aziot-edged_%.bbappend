# =============================================================================
# aziot-edged_%.bbappend
# VisionSOM-STM32MP1 (Cortex-A7 / armhf) fixup:
#
# The upstream aziot-edged.inc adds 'docker' to RDEPENDS, which is satisfied
# by moby-engine. However, moby-engine (Docker Engine) only supports 64-bit
# hosts (x86_64, aarch64) — it is COMPATIBLE_HOST-excluded on armhf.
#
# Azure IoT Edge 1.5.x can operate on ARM32 without a local container runtime
# by using the 'external' provisioning mode or by running edgeAgent in a
# lightweight mode. Remove the moby-engine/docker RDEPEND so the image builds.
# =============================================================================

# Remove the 'docker' virtual package RDEPEND (provided by moby-engine,
# which is incompatible with ARMv7 / 32-bit hosts).
RDEPENDS:${PN}:remove = "docker"

# =============================================================================
# Clock ordering: ensure fake-hwclock restores the saved time BEFORE
# aziot-edged starts. Without this, aziot-edged may start while the clock
# is still at epoch (1970) and fail SSL certificate validation against Azure.
# =============================================================================
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://10-fake-hwclock.conf"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}/aziot-edged.service.d
    install -m 0644 ${WORKDIR}/10-fake-hwclock.conf \
        ${D}${systemd_system_unitdir}/aziot-edged.service.d/10-fake-hwclock.conf
}

FILES:${PN} += "${systemd_system_unitdir}/aziot-edged.service.d/10-fake-hwclock.conf"
