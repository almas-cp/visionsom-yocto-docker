FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://fallback-dns.conf"

do_install:append() {
    install -d ${D}${sysconfdir}/systemd/resolved.conf.d
    install -m 0644 ${WORKDIR}/fallback-dns.conf ${D}${sysconfdir}/systemd/resolved.conf.d/fallback-dns.conf

    # Ensure /etc/resolv.conf is a symlink to the systemd-resolved upstream resolver
    # so Docker and Azure IoT Edge inherit DNS seamlessly on all networks.
    ln -sf ../run/systemd/resolve/resolv.conf ${D}${sysconfdir}/resolv.conf
}

FILES:${PN} += "${sysconfdir}/resolv.conf"

