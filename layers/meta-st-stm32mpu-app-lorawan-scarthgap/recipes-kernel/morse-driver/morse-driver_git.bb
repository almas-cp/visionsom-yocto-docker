SUMMARY = "Morse Micro Wi-Fi HaLow out-of-tree kernel driver"
DESCRIPTION = "Kernel driver modules (morse.ko and dot11ah.ko) for Morse Micro MM6108 and MM8108 Wi-Fi HaLow hardware."
HOMEPAGE = "https://github.com/MorseMicro/morse_driver"
SECTION = "kernel/modules"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://LICENSE;md5=b234ee4d69f5fce4486a80fdaf4a4263"

inherit module

SRC_URI = "gitsm://github.com/MorseMicro/morse_driver.git;protocol=https;branch=main"
SRCREV = "${AUTOREV}"

S = "${WORKDIR}/git"

# CONFIG_MORSE_USB=y is needed for the RD09v4 USB dongle.
# Disable SDIO and SPI since the dongle connects via USB.
EXTRA_OEMAKE += " \
    CONFIG_WLAN_VENDOR_MORSE=m \
    CONFIG_MORSE_USB=y \
    CONFIG_MORSE_SDIO=n \
    CONFIG_MORSE_SPI=n \
    CONFIG_MORSE_USER_ACCESS=y \
    CONFIG_MORSE_VENDOR_COMMAND=y \
"

# Package both morse.ko and dot11ah.ko
KERNEL_MODULE_AUTOLOAD += "dot11ah morse"
