# =============================================================================
# moby-engine-stub_1.0.bb
#
# Stub recipe for VisionSOM-STM32MP1 (Cortex-A7 / ARMv7):
#
# moby-engine (Docker Engine) is COMPATIBLE_HOST-excluded on 32-bit ARM.
# meta-iotedge's aziot-edged RDEPENDS on the 'docker' virtual package which
# moby-engine provides. This stub satisfies that virtual RPROVIDE with an
# empty package so the image builds cleanly on armhf.
#
# Note: Container workloads via Docker are NOT supported on 32-bit ARM.
# Use IoT Edge in 'offline/manual' or 'external' container mode.
# =============================================================================

SUMMARY = "Stub moby-engine satisfier for ARM32 — Docker Engine is 64-bit only"
DESCRIPTION = "Empty package that RPROVIDES moby-engine and docker on ARMv7 \
targets where Docker Engine (moby) does not support the host architecture. \
This allows meta-iotedge packages to satisfy their RDEPENDS chain without \
pulling in the real (incompatible) moby-engine recipe."
HOMEPAGE = "https://aka.ms/iotedge"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# This stub must have higher BBFILE_PRIORITY than meta-virtualization (6).
# Our layer has priority 9 — so this recipe wins.

# Satisfy the 'docker' and 'moby-engine' virtual package requirements
PROVIDES += "moby-engine docker"
RPROVIDES:${PN} += "moby-engine docker"

# Pin to machine arch so it is considered a machine-specific override
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Empty package — no sources, no network, no compilation
SRC_URI = ""

do_configure[noexec] = "1"
do_compile[noexec] = "1"
do_install[noexec] = "1"
