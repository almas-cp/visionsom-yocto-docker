SUMMARY = "NXP EdgeLock SE05x Plug & Trust Middleware"
DESCRIPTION = "Middleware libraries and CLI tools for NXP EdgeLock SE050 secure elements."
HOMEPAGE = "https://github.com/foundriesio/plug-and-trust-seteec"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://README.First.txt;md5=6a257602f7dbb070481a822f4d33fc02"

SRC_URI = "gitsm://github.com/foundriesio/plug-and-trust-seteec.git;protocol=https;branch=main"
SRCREV = "f9df65c413b64784fc096bb19b2b25c3b37b498c"

S = "${WORKDIR}/git"

inherit cmake python3native

DEPENDS = "openssl"

# CMake option names for this source revision (foundriesio/plug-and-trust-seteec).
# NOTE: This source uses bare-name flags, NOT the PTMW_-prefixed variants.
# Reference: scripts/yocto/v03.01.00/se05x_3.1.0.bb inside the upstream source tree.
#
#   Host=iMXLinux     — user-space Linux i2c (no RTOS, no OP-TEE)
#   SMCOM=T1oI2C      — T=1 over I2C physical link (standard SE050 wiring)
#   Applet=SE05X_C    — SE050C/SE050E applet family
#   SE05X_Ver=03_XX   — SE050 v3.x applet (only 03_XX and 06_00 valid in this fork)
#   HostCrypto=OPENSSL — use host OpenSSL for crypto ops
#   SE05X_Auth=None   — plain open session, no SCP03
#   WithSharedLIB=ON  — build .so shared libraries
#   WithSETEEC=OFF    — direct user-space i2c (no OP-TEE)
EXTRA_OECMAKE = " \
    -DHost=iMXLinux \
    -DSMCOM=T1oI2C \
    -DApplet=SE05X_C \
    -DSE05X_Ver=03_XX \
    -DHostCrypto=OPENSSL \
    -DSE05X_Auth=None \
    -DWithSharedLIB=ON \
    -DWithSETEEC=OFF \
    -DOPENSSL_ROOT_DIR=${STAGING_DIR_TARGET}/usr \
"

# Allow unversioned .so symlinks in the runtime package (needed for dlopen)
INSANE_SKIP:${PN} += "dev-so"

# Prevent the dev package from stealing the unversioned .so libraries
FILES_SOLIBSDEV = ""

FILES:${PN} += " \
    ${libdir}/*.so \
    ${libdir}/*.so.* \
    ${bindir}/* \
"

FILES:${PN}-dev += " \
    ${includedir}/* \
    ${libdir}/cmake/* \
    ${datadir}/* \
"

do_install:append() {
    install -d ${D}${libdir}
    install -d ${D}${includedir}/se05x
    install -m 0644 ${S}/hostlib/hostLib/libCommon/log/nxLog*.h ${D}${includedir}/se05x/
}
