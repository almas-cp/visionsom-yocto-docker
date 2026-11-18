SUMMARY = "Multi-WAN Failover and Interface Configuration Scripts"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
PR = "r2"

SRC_URI = " \
    file://failover.sh \
    file://openvpn-client.conf.template \
    file://pon-4g \
    file://modem_set_baud.py \
    file://gsm_setbaud.sh \
    file://sim7600_power.sh \
    file://start-5g.sh \
    file://start-halow.sh \
    file://start-wifi.sh \
    file://4g-ppp.service \
    file://5g-wwu1i2.service \
    file://gsm-iptables.service \
    file://gsm-iptables.sh \
    file://halow-wlu1.service \
    file://wan-failover.service \
    file://wifi-wlan0.service \
    file://add-google-dns \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = " \
    4g-ppp.service \
    5g-wwu1i2.service \
    gsm-iptables.service \
    halow-wlu1.service \
    wan-failover.service \
    wifi-wlan0.service \
"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# Runtime dependencies
RDEPENDS:${PN} += " \
    bash \
    ppp \
    openvpn \
    python3-core \
    python3-pyserial \
    iptables \
"

do_install() {
    # Install etc failover scripts
    install -d ${D}${sysconfdir}/wan-failover
    install -m 0755 ${WORKDIR}/failover.sh ${D}${sysconfdir}/wan-failover/
    install -m 0755 ${WORKDIR}/start-5g.sh ${D}${sysconfdir}/wan-failover/
    install -m 0755 ${WORKDIR}/start-halow.sh ${D}${sysconfdir}/wan-failover/
    install -m 0755 ${WORKDIR}/start-wifi.sh ${D}${sysconfdir}/wan-failover/

    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/pon-4g ${D}${bindir}/
    install -m 0755 ${WORKDIR}/sim7600_power.sh ${D}${bindir}/
    install -m 0755 ${WORKDIR}/modem_set_baud.py ${D}${bindir}/
    install -m 0755 ${WORKDIR}/gsm_setbaud.sh ${D}${bindir}/
    install -m 0755 ${WORKDIR}/gsm-iptables.sh ${D}${bindir}/

    # Install PPP ip-up hook for DNS persistence
    install -d ${D}${sysconfdir}/ppp/ip-up.d
    install -m 0755 ${WORKDIR}/add-google-dns ${D}${sysconfdir}/ppp/ip-up.d/

    # Install OpenVPN config template
    install -d ${D}${sysconfdir}/openvpn
    install -m 0644 ${WORKDIR}/openvpn-client.conf.template ${D}${sysconfdir}/openvpn/client.conf.template

    # Install systemd services
    if ${@bb.utils.contains('DISTRO_FEATURES', 'systemd', 'true', 'false', d)}; then
        install -d ${D}${systemd_system_unitdir}
        install -m 0644 ${WORKDIR}/4g-ppp.service ${D}${systemd_system_unitdir}/
        install -m 0644 ${WORKDIR}/5g-wwu1i2.service ${D}${systemd_system_unitdir}/
        install -m 0644 ${WORKDIR}/gsm-iptables.service ${D}${systemd_system_unitdir}/
        install -m 0644 ${WORKDIR}/halow-wlu1.service ${D}${systemd_system_unitdir}/
        install -m 0644 ${WORKDIR}/wan-failover.service ${D}${systemd_system_unitdir}/
        install -m 0644 ${WORKDIR}/wifi-wlan0.service ${D}${systemd_system_unitdir}/
    fi
}

FILES:${PN} += " \
    ${sysconfdir}/wan-failover \
    ${sysconfdir}/openvpn \
    ${sysconfdir}/ppp/ip-up.d \
"
