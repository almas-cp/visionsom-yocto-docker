SUMMARY = "NXP EdgeLock SE05x PKCS#11 Standalone Library"
DESCRIPTION = "Standalone PKCS#11 library for NXP EdgeLock SE050 secure elements."
HOMEPAGE = "https://github.com/NXPPlugNTrust/se05x-pkcs11"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE.txt;md5=3b83ef96387f14655fc854ddc3c6bd57"

SRC_URI = "gitsm://github.com/NXPPlugNTrust/se05x-pkcs11.git;protocol=https;branch=main"
SRCREV = "40f19e33ca4e27ee1450a3f02c9427beed430a09"

S = "${WORKDIR}/git"

inherit cmake python3native

DEPENDS = "openssl"

EXTRA_OECMAKE = " \
    -DPTMW_Host=iMXLinux \
    -DPTMW_SMCOM=T1oI2C \
    -DPTMW_Applet=SE05X_C \
    -DPTMW_SE05X_Ver=03_XX \
    -DPTMW_HostCrypto=OPENSSL \
    -DPTMW_SE05X_Auth=None \
    -DOPENSSL_ROOT_DIR=${STAGING_DIR_TARGET}/usr \
"

# Allow unversioned .so symlinks in the runtime package
INSANE_SKIP:${PN} += "dev-so"

FILES_SOLIBSDEV = ""

FILES:${PN} += " \
    ${libdir}/libsss_pkcs11.so \
"

do_install:append() {
    install -d ${D}${libdir}
    if [ -f ${B}/libsss_pkcs11.so ]; then
        install -m 0755 ${B}/libsss_pkcs11.so ${D}${libdir}/libsss_pkcs11.so
    elif [ -f ${B}/lib/libsss_pkcs11.so ]; then
        install -m 0755 ${B}/lib/libsss_pkcs11.so ${D}${libdir}/libsss_pkcs11.so
    fi
}
