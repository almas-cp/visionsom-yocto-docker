SUMMARY = "Preload Docker images on first boot"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://preload-docker-images.sh \
    file://docker-preload.service \
"

# --- AUTO GENERATED MODULES START ---
SRC_URI += "file://azureiotedge-agent_1.5.tar;unpack=false"
SRC_URI += "file://azureiotedge-hub_1.5.tar;unpack=false"
SRC_URI += "file://basicstation_0.0.2-arm32v7.tar;unpack=false"
SRC_URI += "file://chirpstack-gateway-bridge_4.0.6.tar;unpack=false"
SRC_URI += "file://configmodule_0.0.2-arm32v7.tar;unpack=false"
SRC_URI += "file://edge-health-monitor_0.0.2-arm32v7.tar;unpack=false"
SRC_URI += "file://loggingmodule_0.0.2-arm32v7.tar;unpack=false"
SRC_URI += "file://managementmodule_0.0.2-arm32v7.tar;unpack=false"
SRC_URI += "file://networkmodule_0.0.2-arm32v7.tar;unpack=false"
# --- AUTO GENERATED MODULES END ---

# ----------------------------------------------------------------------

inherit systemd

SYSTEMD_SERVICE:${PN} = "docker-preload.service"
SYSTEMD_AUTO_ENABLE = "enable"

# Depend on docker to ensure the loading commands work
RDEPENDS:${PN} += "docker bash"

do_install() {
    # Install the loader script
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/preload-docker-images.sh ${D}${bindir}/

    # Install the systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/docker-preload.service ${D}${systemd_system_unitdir}/

    # Install the .tar files to /opt/preloaded-modules
    install -d ${D}/opt/preloaded-modules

    # Loop through anything in WORKDIR that ends in .tar and install it
    for tarfile in ${WORKDIR}/*.tar; do
        if [ -f "$tarfile" ]; then
            install -m 0644 "$tarfile" ${D}/opt/preloaded-modules/
        fi
    done
}

FILES:${PN} += " \
    ${bindir}/preload-docker-images.sh \
    ${systemd_system_unitdir}/docker-preload.service \
    /opt/preloaded-modules \
    /opt/preloaded-modules/* \
"
