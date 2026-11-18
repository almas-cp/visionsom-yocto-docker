# recipes-kernel/linux/linux-stm32mp_6.6.bbappend
# Appends kernel config fragments and a custom board DTS overlay for:
#   - TUN/TAP (OpenVPN)
#   - Cellular modem support (Telit FN990A28 5G USB + SIM7600 4G LTE UART)
#   - Custom board peripherals (USART6/GSM, USART3/GPS, SPI5/LoRa, I2C4/HSM, LEDs, GPIOs)
# Works alongside the somlabs bbappend — Yocto merges all bbappends in priority order.

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += " \
    file://tun-openvpn.cfg \
    file://cellular-modem.cfg \
    file://halow.cfg \
    file://ext4-security.cfg \
    file://adc.cfg \
    file://custom-board.dts \
"

KERNEL_CONFIG_FRAGMENTS:append:stm32mp1common = " \
    ${WORKDIR}/tun-openvpn.cfg \
    ${WORKDIR}/cellular-modem.cfg \
    ${WORKDIR}/halow.cfg \
    ${WORKDIR}/ext4-security.cfg \
    ${WORKDIR}/adc.cfg \
"

# Install the custom board DTS overlay alongside the board kernel image.
# The overlay is applied by U-Boot at runtime via the fdtoverlays environment variable,
# or it can be compiled into the DTB using dtc -@ and U-Boot overlay loading.
do_install:append() {
    install -d ${D}/boot/overlays
    install -m 0644 ${WORKDIR}/custom-board.dts ${D}/boot/overlays/
    # Preprocess the overlay using the kernel's preprocessor to resolve #includes and macros
    ${KERNEL_CC} -E -nostdinc -I${S}/include -I${S}/arch/arm/boot/dts -I${S}/arch/arm/boot/dts/include -x assembler-with-cpp -o ${WORKDIR}/custom-board.pre.dts ${WORKDIR}/custom-board.dts
    # Compile the preprocessed DTS to .dtbo
    ${B}/scripts/dtc/dtc -@ -I dts -O dtb -o ${D}/boot/overlays/custom-board.dtbo \
        ${WORKDIR}/custom-board.pre.dts
}

FILES:${KERNEL_PACKAGE_NAME}-devicetree += "/boot/overlays/custom-board.dtbo"

# Suppress harmless QA buildpaths warning in generated kernel source package
INSANE_SKIP:${PN}-src += "buildpaths"

