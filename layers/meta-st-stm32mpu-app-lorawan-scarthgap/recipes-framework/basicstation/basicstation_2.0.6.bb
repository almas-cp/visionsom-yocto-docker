# recipes-framework/basicstation/basicstation_2.0.6.bb
# LoRa Basics Station — ported for Yocto Scarthgap
# Replaces the legacy lora-gateway + packet_forwarder from the dunfell layer.

SUMMARY = "LoRa Basics Station — the modern LoRaWAN gateway software"
HOMEPAGE = "https://github.com/lorabasics/basicstation"
LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=a00b6155c30853bb390ec59ba94e2b06"

SRC_URI = " \
    git://github.com/lorabasics/basicstation.git;protocol=https;branch=master \
    file://basicstation.service \
    file://station.conf.example \
"
SRCREV = "ba4f85d80a438a5c2b659e568cd2d0f0de08e5a7"
PV = "2.0.6+git${SRCPV}"

S = "${WORKDIR}/git"

# ── Concentrator platform selection ──────────────────────────────────────────
# Override in local.conf:
#   BASICSTATION_PLATFORM = "corecell"   # SX1302 / SX1303 (SPI or USB)
#   BASICSTATION_PLATFORM = "linux"      # SX1301 (needs lora_gateway kernel mod)
BASICSTATION_PLATFORM ?= "corecell"
BASICSTATION_VARIANT  ?= "std"

# ── Dependencies ─────────────────────────────────────────────────────────────
DEPENDS = "openssl mbedtls libloragw"

# libloragw is part of sx1302_hal for corecell platform
# For linux platform, use lora-gateway instead
DEPENDS:append = "${@' sx1302-hal' if d.getVar('BASICSTATION_PLATFORM') == 'corecell' else ' lora-gateway'}"

# The upstream Makefile has a parallel make race condition: it compiles basicstation
# source files (s-all) and dependencies (deps/mbedtls) in parallel. The s-all target
# needs mbedtls headers which may not be generated yet, causing a compilation failure.
# Disable parallel compilation for this recipe to ensure sequential building of deps.
PARALLEL_MAKE = ""

inherit systemd

EXTRA_OEMAKE = " \
    platform=${BASICSTATION_PLATFORM} \
    variant=${BASICSTATION_VARIANT} \
    CROSS_COMPILE=${TARGET_PREFIX} \
    CC='${CC}' \
    AR='${AR}' \
    xLDFLAGS='${LDFLAGS}' \
"

do_configure:prepend() {
    # Replace relative path `./reset_lgw.sh` with system PATH query `reset_lgw.sh`
    find ${S} -type f -exec sed -i 's|\./reset_lgw\.sh|reset_lgw.sh|g' {} +
}

do_compile[network] = "1"
do_compile() {
    # 1. Run prep scripts manually to clone dependencies
    cd ${S}/deps/mbedtls
    platform=${BASICSTATION_PLATFORM} variant=${BASICSTATION_VARIANT} ./prep.sh
    
    cd ${S}/deps/lgw1302
    platform=${BASICSTATION_PLATFORM} variant=${BASICSTATION_VARIANT} lgwversion=2.1.0 ./prep.sh

    # 2. Apply our I2C replacement on the freshly cloned dependency sources
    find ${S} -type f -exec sed -i 's|/dev/i2c-1|/dev/i2c-0|g' {} +

    # 3. Run the standard compile
    cd ${S}
    oe_runmake
}

do_install() {
    # Binary
    install -d ${D}${bindir}
    install -m 0755 \
        ${S}/build-${BASICSTATION_PLATFORM}-${BASICSTATION_VARIANT}/bin/station \
        ${D}${bindir}/station

    # Config directory & placeholder files (prevents Docker bind mounts from creating empty directories)
    install -d ${D}${sysconfdir}/basicstation
    install -m 0644 ${WORKDIR}/station.conf.example \
        ${D}${sysconfdir}/basicstation/station.conf.example
    touch ${D}${sysconfdir}/basicstation/station.conf
    touch ${D}${sysconfdir}/basicstation/tc.uri
    touch ${D}${sysconfdir}/basicstation/tc.key
    chmod 0600 ${D}${sysconfdir}/basicstation/station.conf
    chmod 0600 ${D}${sysconfdir}/basicstation/tc.key
    chmod 0644 ${D}${sysconfdir}/basicstation/tc.uri

    # systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/basicstation.service \
        ${D}${systemd_system_unitdir}/basicstation.service
}

SYSTEMD_SERVICE:${PN} = "basicstation.service"
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

FILES:${PN} = " \
    ${bindir}/station \
    ${sysconfdir}/basicstation \
    ${systemd_system_unitdir}/basicstation.service \
"

RDEPENDS:${PN} = "bash"

# Safeguard in case sub-components ignore LDFLAGS and fail GNU_HASH QA check
INSANE_SKIP:${PN} = "ldflags"
