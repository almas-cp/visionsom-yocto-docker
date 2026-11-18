# recipes-kernel/linux/aziot-edged_%.bbappend
# Placed in the LoRaWAN layer since it's project-specific config.
# Disables aziot-tpmd on VisionSOM machines (no TPM hardware).
# See: https://github.com/Azure/meta-iotedge/issues/149

SYSTEMD_SERVICE:${PN}:remove:mp157a-hdmi-lt-emmc-mx = "aziot-tpmd.service"
SYSTEMD_SERVICE:${PN}:remove:mp157a-dsi-rvt-emmc-mx  = "aziot-tpmd.service"
