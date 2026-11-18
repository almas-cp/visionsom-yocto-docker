SUMMARY = "Morse Micro Wi-Fi HaLow userspace control utility"
DESCRIPTION = "Command-line control interface (morsectrl) for Morse Micro Wi-Fi HaLow hardware."
HOMEPAGE = "https://github.com/MorseMicro/morse_cli"
LICENSE = "CLOSED"

SRC_URI = "git://github.com/MorseMicro/morse_cli.git;protocol=https;branch=main"
SRCREV = "${AUTOREV}"

S = "${WORKDIR}/git"

DEPENDS = "libusb1 libnl"

inherit pkgconfig

# Override CFLAGS variables on the command line to append -Wno-error,
# while explicitly passing the required version and interface macro definitions.
EXTRA_OEMAKE = " \
    CC='${CC}' \
    CFLAGS='${CFLAGS}' \
    LDFLAGS='${LDFLAGS}' \
    PKG_CONFIG='pkg-config' \
    CONFIG_MORSE_TRANS_NL80211='1' \
    MORSECTRL_CFLAGS='${CFLAGS} -I${STAGING_INCDIR}/libnl3 -Wall -Wno-error -DMORSECTRL_VERSION_STRING=\"rel_1_17_8_2026_Mar_24\" -DDEFAULT_INTERFACE_NAME=\"wlan0\"' \
    MORSE_CLI_CFLAGS='${CFLAGS} -I${STAGING_INCDIR}/libnl3 -Wall -Wno-error -DMORSECTRL_VERSION_STRING=\"rel_1_17_8_2026_Mar_24\" -DDEFAULT_INTERFACE_NAME=\"wlan0\" -DMORSE_CLIENT' \
"

do_compile() {
    oe_runmake morse_cli
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 morse_cli ${D}${bindir}/morsectrl
}
