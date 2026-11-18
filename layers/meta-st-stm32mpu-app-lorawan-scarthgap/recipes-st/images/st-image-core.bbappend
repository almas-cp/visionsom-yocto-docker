# recipes-st/images/st-image-weston.bbappend
#
# Extend the base ST Weston image with LoRaWAN + Azure IoT Edge packages.
# This file lives in meta-st-stm32mpu-app-lorawan and is picked up automatically.
#
# IMPORTANT — Package naming in Yocto vs Debian:
#   Yocto name    Debian equivalent
#   openssh       openssh-client + openssh-server
#   openssh-sshd  openssh-server (daemon only)
#   (not 'openssh-server' — that is a Debian package name, unknown in Yocto)
#
# NOTE on moby-engine:
#   moby-engine (Docker Engine) only supports 64-bit hosts (x86_64, aarch64).
#   VisionSOM-STM32MP157 is 32-bit Cortex-A7 (armhf). moby-engine is
#   COMPATIBLE_HOST-excluded on armhf — do NOT add it here.
#   A stub RPROVIDES it via moby-engine-stub_1.0.bb to satisfy meta-iotedge deps.

# Use OpenSSH instead of Dropbear to avoid package conflicts (the base image sets ssh-server-dropbear by default)
IMAGE_FEATURES:remove = "ssh-server-dropbear"
IMAGE_FEATURES:append = " ssh-server-openssh"

# Headless & Soundless Gateway - Strip display, UI, and audio features/packages
IMAGE_FEATURES:remove = "splash x11 x11-base x11-sato hwcodecs"
IMAGE_INSTALL:remove = "st-hostname alsa-state-stm32mp alsa-utils alsa-states alsa-state pulseaudio weston weston-init weston-examples"

# Set default factory hostname to 'admin' (before azure_device_id is configured)
hostname:pn-base-files = "admin"


# ── User Account: 'onesense' (admin) with default password 'admin' ───────────
# Hash generated with: openssl passwd -6 -salt onesense admin
# Result: $6$onesense$4TkVaPxTIKpZujENpwu6Hfyuxkko1CDo39GQfM6VGIwFTWYFII9ZvmslOo3Z6HGUetYMgNw.08Z5fha1Wshw10
inherit extrausers
EXTRA_USERS_PARAMS = " \
    useradd -p '\$6\$onesense\$4TkVaPxTIKpZujENpwu6Hfyuxkko1CDo39GQfM6VGIwFTWYFII9ZvmslOo3Z6HGUetYMgNw.08Z5fha1Wshw10' -d /home/onesense -m -s /bin/bash -G sudo,wheel,adm onesense; \
    usermod -p '\$6\$onesense\$4TkVaPxTIKpZujENpwu6Hfyuxkko1CDo39GQfM6VGIwFTWYFII9ZvmslOo3Z6HGUetYMgNw.08Z5fha1Wshw10' root; \
"


# ── LoRaWAN ──────────────────────────────────────────────────────────────────
IMAGE_INSTALL:append = " \
    basicstation \
"

# ── Azure IoT Edge ───────────────────────────────────────────────────────────
# iotedge and aziot-edged come from meta-iotedge.
# docker-moby provides the real container daemon for arm32.
IMAGE_INSTALL:append = " \
    iotedge \
    aziot-edged \
    docker-moby \
"

# ── Supporting packages & Developer Tools ────────────────────────────────────
# openssh      = correct Yocto name (includes sshd + client + sftp)
# ca-certificates, curl, jq = standard IoT Edge utilities
EXTRA_IMAGE_FEATURES:append = " package-management"

IMAGE_INSTALL:append = " \
    openssh \
    ca-certificates \
    curl \
    wget \
    jq \
    nano \
    vim \
    sudo \
    python3-flask \
    net-tools \
    i2c-tools \
    iproute2 \
    ethtool \
    usbutils \
    pciutils \
    htop \
    tcpdump \
    apt \
    dpkg \
    strace \
    lsof \
    bind-utils \
    iputils-ping \
    traceroute \
    less \
    tree \
    zip \
    unzip \
    tar \
    gzip \
    findutils \
"



# ── Clock Management (no RTC battery on VisionSOM-STM32MP1) ──────────────────
# fake-hwclock: saves the system clock to eMMC every hour and on shutdown.
#               On boot, restores the saved time BEFORE aziot-edged starts,
#               ensuring SSL certificate validation never fails due to clock=1970.
# chrony:       NTP client with aggressive 'makestep' config to instantly snap
#               the clock to the correct date on first NTP response.
# Together they allow removing the insecure ServerCertificateValidation__Enable
# workaround from config.toml.
IMAGE_INSTALL:append = " \
    fake-hwclock \
    chrony \
"

# ── OpenVPN / TUN ────────────────────────────────────────────────────────────
# openvpn       = OpenVPN daemon (from meta-openembedded/meta-networking)
# TUN support is built into the kernel (CONFIG_TUN=y) via the kernel config
# fragment in recipes-kernel/linux/linux-stm32mp/tun-openvpn.cfg.
# /dev/net/tun is available at boot — no kernel module needed.
IMAGE_INSTALL:append = " \
    openvpn \
"


# ── Cellular Modem ───────────────────────────────────────────────────────────
#
# Modem 1: Telit FN990A28 — 5G Sub-6 GHz, USB (MBIM / QMI / NCM)
#   - modemmanager     : unified modem management daemon (AT + MBIM + QMI)
#   - usb-modeswitch   : switches USB composite devices to modem mode on plug-in
#   - usb-modeswitch-data : udev rules + modem database for usb-modeswitch
#   - libmbim          : MBIM protocol library + mbimcli tool (FN990A28 primary)
#   - libqmi           : QMI protocol library + qmicli tool (alternative mode)
#
# Modem 2: SIM7600 — 4G LTE (NOTE: SIM7600 is LTE-A, not 5G)
#   Connected via UART (/dev/ttySTM*)
#   - ppp              : PPP daemon + chat script tool (both in ppp package)
#   - ppp-dialin       : helper scripts for PPP dial-in
#   - minicom          : serial terminal for AT command debugging
#
# Kernel config (cellular-modem.cfg) provides:
#   CONFIG_USB_NET_CDC_MBIM, CONFIG_USB_NET_QMI_WWAN, CONFIG_USB_WDM,
#   CONFIG_USB_SERIAL_OPTION, CONFIG_PPP, CONFIG_PPP_ASYNC, etc.
IMAGE_INSTALL:append = " \
    modemmanager \
    usb-modeswitch \
    usb-modeswitch-data \
    libmbim \
    libqmi \
    ppp \
    ppp-dialin \
    minicom \
    picocom \
    screen \
    libgpiod-tools \
    can-utils \
"


# ── Morse Micro Wi-Fi HaLow (RD09v4 USB Dongle) ──────────────────────────────
#   - morse-driver   : Out-of-tree kernel driver modules (morse.ko, dot11ah.ko)
#   - morse-firmware : Firmware binaries and default board configuration files (BCFs)
#   - morse-cli      : morsectrl CLI utility to configure/manage HaLow links
IMAGE_INSTALL:append = " \
    morse-driver \
    morse-firmware \
    morse-cli \
"

# ── NXP EdgeLock SE050E HSM ──────────────────────────────────────────────────
#   - se05x-mw           : NXP Plug & Trust Middleware libraries and tools (includes libsssapisw.so)
#   - se05x-pkcs11       : NXP Standalone PKCS#11 library (libsss_pkcs11.so)
#   - gateway-secrets    : store/read/verify gateway credentials in SE050
#   - opensc / libp11    : pkcs11-tool for testing and enumerating HSM objects
IMAGE_INSTALL:append = " \
    se05x-mw \
    se05x-pkcs11 \
    gateway-secrets \
    gateway-config \
    gateway-multiwan \
    sx1302-hal \
    opensc \
    python3-difflib \
    lrzsz \
    procps \
"

# ── Kernel features ──────────────────────────────────────────────────────────
MACHINE_FEATURES:append = " vfat ext2 ext3"

# Increase maximum rootfs image size to accommodate docker and supporting packages
IMAGE_ROOTFS_MAXSIZE = "1500000"
IMAGE_INSTALL:append = " docker-preload-modules"
