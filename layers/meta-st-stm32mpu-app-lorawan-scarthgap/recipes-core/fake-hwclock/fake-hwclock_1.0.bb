SUMMARY = "fake-hwclock: Save/restore the system clock on systems without a battery-backed RTC"
DESCRIPTION = "\
    fake-hwclock saves the current UTC clock to a file on eMMC at regular intervals \
    and on shutdown. On boot (before any network is available), it restores this \
    saved timestamp so that the system clock is roughly correct — preventing SSL \
    certificate validation failures in aziot-edged when NTP has not yet synced."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

# All source files are local — no network fetch needed
SRC_URI = " \
    file://fake-hwclock.sh \
    file://fake-hwclock.service \
    file://fake-hwclock-save.service \
    file://fake-hwclock-save.timer \
"

S = "${WORKDIR}"

RDEPENDS:${PN} = "bash"

inherit systemd

SYSTEMD_SERVICE:${PN} = " \
    fake-hwclock.service \
    fake-hwclock-save.timer \
"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    # Install the main script
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/fake-hwclock.sh ${D}${sbindir}/fake-hwclock

    # Create the data directory (clock will be saved here on first shutdown)
    install -d ${D}${localstatedir}/lib/fake-hwclock

    # Install systemd units
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/fake-hwclock.service       ${D}${systemd_system_unitdir}/fake-hwclock.service
    install -m 0644 ${WORKDIR}/fake-hwclock-save.service  ${D}${systemd_system_unitdir}/fake-hwclock-save.service
    install -m 0644 ${WORKDIR}/fake-hwclock-save.timer    ${D}${systemd_system_unitdir}/fake-hwclock-save.timer
}

FILES:${PN} = " \
    ${sbindir}/fake-hwclock \
    ${localstatedir}/lib/fake-hwclock \
    ${systemd_system_unitdir}/fake-hwclock.service \
    ${systemd_system_unitdir}/fake-hwclock-save.service \
    ${systemd_system_unitdir}/fake-hwclock-save.timer \
"
