# =============================================================================
# sx1302-hal_2.1.0.bb
#
# Semtech SX1302/SX1303 Hardware Abstraction Layer (HAL)
# https://github.com/Lora-net/sx1302_hal
#
# Required by basicstation when BASICSTATION_PLATFORM = "corecell".
# PROVIDES libloragw so basicstation's DEPENDS = "libloragw" is satisfied.
# =============================================================================

SUMMARY = "Semtech SX1302/SX1303 LoRa concentrator HAL library"
DESCRIPTION = "Hardware Abstraction Layer for the SX1302 and SX1303 LoRa \
concentrators. Provides libloragw used by LoRa Basics Station (basicstation) \
in corecell mode."
HOMEPAGE = "https://github.com/Lora-net/sx1302_hal"
LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE.TXT;md5=d2119120bd616e725f4580070bd9ee19"

# Commit hash for tag V02.01.00 on github.com/Lora-net/sx1302_hal
SRC_URI = "git://github.com/Lora-net/sx1302_hal.git;protocol=https;branch=master;nobranch=1"
SRCREV = "${AUTOREV}"
PV = "2.1.0+git${SRCPV}"

S = "${WORKDIR}/git"

# PROVIDES libloragw so basicstation's DEPENDS = "openssl mbedtls libloragw" resolves here
PROVIDES += "libloragw"

DEPENDS = "libusb1"

inherit pkgconfig

do_configure:prepend() {
    # Replace relative path `./reset_lgw.sh` with system PATH query `reset_lgw.sh`
    find ${S} -type f -exec sed -i 's|\./reset_lgw\.sh|reset_lgw.sh|g' {} +
    # Replace hardcoded I2C device path `/dev/i2c-1` with `/dev/i2c-0`
    find ${S} -type f -exec sed -i 's|/dev/i2c-1|/dev/i2c-0|g' {} +
}

do_compile() {
    # 1. Compile libtools first (provides libtinymt32.a, libparson.a, libbase64.a)
    cd ${S}/libtools
    oe_runmake \
        CC="${CC}" \
        AR="${AR}" \
        CFLAGS="${CFLAGS} -std=c99 -Iinc -I." \
        LDFLAGS="${LDFLAGS}"

    # 2. Compile libloragw
    cd ${S}/libloragw
    oe_runmake \
        CC="${CC}" \
        AR="${AR}" \
        CFLAGS="${CFLAGS} -std=c99 -Iinc -I. -I../libtools/inc" \
        LDFLAGS="${LDFLAGS}"

    # 3. Compile util_chip_id
    cd ${S}/util_chip_id
    oe_runmake \
        CC="${CC}" \
        AR="${AR}" \
        CFLAGS="${CFLAGS} -std=c99 -Iinc -I. -I../libloragw/inc -I../libtools/inc" \
        LDFLAGS="${LDFLAGS} -L../libloragw -L../libtools"
}

do_install() {
    # Install libloragw headers
    install -d ${D}${includedir}/libloragw
    install -m 0644 ${S}/libloragw/inc/*.h \
        ${D}${includedir}/libloragw/

    # Install libtools headers (needed for tinymt32.h etc)
    install -m 0644 ${S}/libtools/inc/*.h \
        ${D}${includedir}/libloragw/

    # Install static libraries
    install -d ${D}${libdir}
    install -m 0644 ${S}/libloragw/libloragw.a \
        ${D}${libdir}/
    install -m 0644 ${S}/libtools/libtinymt32.a \
        ${D}${libdir}/
    install -m 0644 ${S}/libtools/libparson.a \
        ${D}${libdir}/
    install -m 0644 ${S}/libtools/libbase64.a \
        ${D}${libdir}/

    # Install pkgconfig config file
    install -d ${D}${libdir}/pkgconfig
    cat > ${D}${libdir}/pkgconfig/libloragw.pc << PKGEOF
prefix=${prefix}
exec_prefix=\${prefix}
libdir=${libdir}
includedir=${includedir}/libloragw

Name: libloragw
Description: SX1302 LoRa concentrator HAL library
Version: 2.1.0
Libs: -L\${libdir} -lloragw -ltinymt32 -lparson -lbase64
Cflags: -I\${includedir}/libloragw
PKGEOF

    # Install chip_id utility
    install -d ${D}${bindir}
    install -m 0755 ${S}/util_chip_id/chip_id ${D}${bindir}/
}

FILES:${PN} = " \
    ${bindir}/chip_id \
"
FILES:${PN}-dev = " \
    ${includedir}/libloragw/*.h \
    ${libdir}/pkgconfig/libloragw.pc \
"
FILES:${PN}-staticdev = " \
    ${libdir}/*.a \
"

PACKAGES = "${PN} ${PN}-dev ${PN}-staticdev ${PN}-dbg"
ALLOW_EMPTY:${PN} = "1"
