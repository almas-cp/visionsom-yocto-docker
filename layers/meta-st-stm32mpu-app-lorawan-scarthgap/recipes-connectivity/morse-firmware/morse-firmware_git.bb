SUMMARY = "Morse Micro Wi-Fi HaLow firmware binaries and Board Configuration Files (BCFs)"
DESCRIPTION = "Firmware binaries (e.g. mm6108.bin) and BCF binaries required by the morse-driver for Morse Micro Wi-Fi HaLow hardware."
HOMEPAGE = "https://github.com/MorseMicro/morse-firmware"
LICENSE = "CLOSED"

SRC_URI = "git://github.com/MorseMicro/morse-firmware.git;protocol=https;branch=main"
SRCREV = "${AUTOREV}"

S = "${WORKDIR}/git"

inherit allarch

# Prevent all stripping and debugging tools from running during packaging and sysroot staging
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_SYSROOT_STRIP = "1"
INSANE_SKIP:${PN} = "arch already-stripped"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

do_install() {
    # Respect usrmerge by using ${nonarch_base_libdir}/firmware
    install -d ${D}${nonarch_base_libdir}/firmware/morse
    # Copy firmware binaries
    if [ -d ${S}/firmware ]; then
        cp -r ${S}/firmware/* ${D}${nonarch_base_libdir}/firmware/morse/
    fi
    # Copy BCF binaries
    if [ -d ${S}/bcf ]; then
        cp -r ${S}/bcf/* ${D}${nonarch_base_libdir}/firmware/morse/
    fi

    # Ensure Morse Micro HaLow BCF files/symlinks exist (Patch 11: avoid failsafe mode)
    ln -sf mm6108-ekh01.bcf ${D}${nonarch_base_libdir}/firmware/morse/bcf_boardtype_0804.bin
    ln -sf mm6108-ekh01.bcf ${D}${nonarch_base_libdir}/firmware/morse/bcf_mf15457.bin
}

FILES:${PN} += "${nonarch_base_libdir}/firmware/morse/*"
