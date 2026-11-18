# Copyright (C) 2026 - Released under the MIT license
#
# gateway-secrets — SE050 HSM credential storage utilities
#
# Builds and installs three tools:
#   /usr/bin/store-gateway-secrets  <i2c-dev> <wifi_pw> <azure_cs> <ttn_key>
#   /usr/bin/read-gateway-secrets   [<i2c-dev>]
#   /usr/bin/verify-gateway-secrets [<i2c-dev>]
#
# These tools use the NXP Plug & Trust middleware (se05x-mw) to store and
# retrieve gateway credentials (WiFi password, Azure IoT connection string,
# TTN API key) securely inside the SE050 Hardware Security Module.
#
# Object IDs used inside the SE050:
#   0x7FFF0211 — wifi_password
#   0x7FFF0212 — azure_connection_string
#   0x7FFF0213 — ttn_api_key
#
SUMMARY = "Gateway credential storage utilities for NXP SE050 HSM"
DESCRIPTION = "Command-line tools to store, read and verify gateway secrets \
(WiFi password, Azure IoT connection string, TTN API key) in the SE050 \
secure element via the Plug & Trust middleware."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
PR = "r4"

# Source files live alongside this recipe in the gateway-secrets/ subdirectory
SRC_URI = " \
    file://CMakeLists.txt \
    file://store_gateway_secrets.c \
    file://read_gateway_secrets.c \
    file://verify_gateway_secrets.c \
    file://sign_gateway_archive.c \
"

S = "${WORKDIR}"

inherit cmake

# Must build after se05x-mw so its headers and .so files are in the sysroot
DEPENDS = "se05x-mw openssl"

# These binaries are runtime dependencies of the se05x-mw shared libs
RDEPENDS:${PN} = "se05x-mw"

FILES:${PN} = "${bindir}/store-gateway-secrets \
               ${bindir}/read-gateway-secrets \
               ${bindir}/verify-gateway-secrets \
               ${bindir}/sign-gateway-archive"
