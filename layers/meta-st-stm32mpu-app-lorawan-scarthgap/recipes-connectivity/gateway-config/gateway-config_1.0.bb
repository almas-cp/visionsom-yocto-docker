SUMMARY = "Gateway configuration scripts and button monitoring service"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
PR = "r8"



SRC_URI = " \
    file://ble.py \
    file://main.py \
    file://app.py \
    file://app_eth.py \
    file://ble_provision.sh \
    file://button-check.sh \
    file://eth_ap.sh \
    file://eth_debug.sh \
    file://factory_reset.sh \
    file://wifi_ap.sh \
    file://service/button-check.service \
    file://service/gateway-config.service \
    file://portal/change_password.html \
    file://portal/done.html \
    file://portal/index.html \
    file://portal/login.html \
    file://portal/sidebarLogo.png \
    file://store_to_hsm \
    file://apply_wifi.sh \
    file://apply_halow.sh \
    file://apply_gateway_config.sh \
    file://gateway-hostname-sync.sh \
    file://reset_lgw.sh \
    file://setup_openvpn \
    file://enable_swap.sh \
    file://service/gateway-hostname.service \
    file://service/gateway-firstboot-hsm.service \
    file://service/enable-swap.service \
    file://daemon.json \
    file://docker-mount.conf \
    file://aziot-keyd-root.conf \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "gateway-hostname.service gateway-firstboot-hsm.service button-check.service enable-swap.service gateway-config.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# Runtime dependencies for scripts and services
RDEPENDS:${PN} += " \
    libgpiod-tools \
    python3-core \
    python3-asyncio \
    python3-dbus-next \
    python3-datetime \
    python3-json \
    python3-netclient \
    python3-flask \
    python3-werkzeug \
    python3-jinja2 \
    bluez5 \
    rfkill \
    hostapd \
    dnsmasq \
    bash \
"

do_install() {
    # Install scripts and assets to /usr/share/gateway_conf/
    install -d ${D}/usr/share/gateway_conf
    install -m 0755 ${WORKDIR}/ble_provision.sh ${D}/usr/share/gateway_conf/
    install -m 0755 ${WORKDIR}/button-check.sh ${D}/usr/share/gateway_conf/
    install -m 0755 ${WORKDIR}/eth_ap.sh ${D}/usr/share/gateway_conf/
    install -m 0755 ${WORKDIR}/eth_debug.sh ${D}/usr/share/gateway_conf/
    install -m 0755 ${WORKDIR}/factory_reset.sh ${D}/usr/share/gateway_conf/
    install -m 0755 ${WORKDIR}/wifi_ap.sh ${D}/usr/share/gateway_conf/
    install -m 0755 ${WORKDIR}/reset_lgw.sh ${D}/usr/share/gateway_conf/
    install -d ${D}${bindir}
    ln -sf ../share/gateway_conf/reset_lgw.sh ${D}${bindir}/reset_lgw.sh
    
    install -m 0644 ${WORKDIR}/ble.py ${D}/usr/share/gateway_conf/
    install -m 0644 ${WORKDIR}/main.py ${D}/usr/share/gateway_conf/
    install -m 0644 ${WORKDIR}/app.py ${D}/usr/share/gateway_conf/
    install -m 0644 ${WORKDIR}/app_eth.py ${D}/usr/share/gateway_conf/
    
    # Install portal files
    install -d ${D}/usr/share/gateway_conf/portal
    install -m 0644 ${WORKDIR}/portal/change_password.html ${D}/usr/share/gateway_conf/portal/
    install -m 0644 ${WORKDIR}/portal/done.html ${D}/usr/share/gateway_conf/portal/
    install -m 0644 ${WORKDIR}/portal/index.html ${D}/usr/share/gateway_conf/portal/
    install -m 0644 ${WORKDIR}/portal/login.html ${D}/usr/share/gateway_conf/portal/
    install -m 0644 ${WORKDIR}/portal/sidebarLogo.png ${D}/usr/share/gateway_conf/portal/

    # Install binaries and helper tools to /usr/bin/
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/store_to_hsm ${D}${bindir}/
    install -m 0755 ${WORKDIR}/apply_wifi.sh ${D}${bindir}/
    install -m 0755 ${WORKDIR}/apply_halow.sh ${D}${bindir}/
    install -m 0755 ${WORKDIR}/apply_gateway_config.sh ${D}${bindir}/
    install -m 0755 ${WORKDIR}/gateway-hostname-sync.sh ${D}${bindir}/
    install -m 0755 ${WORKDIR}/setup_openvpn ${D}${bindir}/

    # Install docker daemon config
    install -d ${D}${sysconfdir}/docker
    install -m 0644 ${WORKDIR}/daemon.json ${D}${sysconfdir}/docker/daemon.json

    # Install swap enabler script
    install -m 0755 ${WORKDIR}/enable_swap.sh ${D}${bindir}/

    # Create gateway OS version tag for hardware capability detection and first-boot HSM wipe trigger
    install -d ${D}${sysconfdir}/gateway
    echo "v2.0" > ${D}${sysconfdir}/gateway/os_version
    touch ${D}${sysconfdir}/gateway/.first_boot_hsm_wipe

    # Install systemd service
    if ${@bb.utils.contains('DISTRO_FEATURES', 'systemd', 'true', 'false', d)}; then
        install -d ${D}${systemd_system_unitdir}
        install -m 0644 ${WORKDIR}/service/gateway-hostname.service ${D}${systemd_system_unitdir}
        install -m 0644 ${WORKDIR}/service/gateway-firstboot-hsm.service ${D}${systemd_system_unitdir}
        install -m 0644 ${WORKDIR}/service/button-check.service ${D}${systemd_system_unitdir}
        install -m 0644 ${WORKDIR}/service/enable-swap.service ${D}${systemd_system_unitdir}
        install -m 0644 ${WORKDIR}/service/gateway-config.service ${D}${systemd_system_unitdir}
        
        install -d ${D}${sysconfdir}/systemd/system/aziot-keyd.service.d
        install -m 0644 ${WORKDIR}/aziot-keyd-root.conf ${D}${sysconfdir}/systemd/system/aziot-keyd.service.d/override.conf

        install -d ${D}${sysconfdir}/systemd/system/docker.service.d
        install -m 0644 ${WORKDIR}/docker-mount.conf ${D}${sysconfdir}/systemd/system/docker.service.d/override.conf
    fi

    # Sudoers permissions for onesense
    install -d ${D}${sysconfdir}/sudoers.d
    echo "onesense ALL=(ALL) NOPASSWD: ALL" > ${D}${sysconfdir}/sudoers.d/onesense
    chmod 0440 ${D}${sysconfdir}/sudoers.d/onesense

    # OpenSSH configuration: require password, allow onesense and root
    install -d ${D}${sysconfdir}/ssh/sshd_config.d
    echo "PermitRootLogin yes" > ${D}${sysconfdir}/ssh/sshd_config.d/onesense.conf
    echo "PasswordAuthentication yes" >> ${D}${sysconfdir}/ssh/sshd_config.d/onesense.conf
    echo "PermitEmptyPasswords no" >> ${D}${sysconfdir}/ssh/sshd_config.d/onesense.conf
    # Global PATH profile drop-in to ensure /usr/sbin and /sbin are in PATH for all shells
    install -d ${D}${sysconfdir}/profile.d
    echo 'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"' > ${D}${sysconfdir}/profile.d/00-default-path.sh
    chmod 0755 ${D}${sysconfdir}/profile.d/00-default-path.sh
}

FILES:${PN} += " \
    /usr/share/gateway_conf/* \
    /usr/bin/* \
    /etc/docker/* \
    ${sysconfdir}/sudoers.d/* \
    ${sysconfdir}/ssh/sshd_config.d/* \
    ${sysconfdir}/profile.d/* \
"


