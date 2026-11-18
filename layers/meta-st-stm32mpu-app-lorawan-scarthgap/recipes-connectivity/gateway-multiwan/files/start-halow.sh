#!/bin/sh
# Brings up Wi-Fi HaLow (Morse Micro MM8108, RD09v4 USB dongle).
#
# Key points:
# - country=AU is passed as a MODULE parameter (not global `iw reg set`),
#   because the Linux wireless regulatory domain is global/system-wide,
#   not per-radio. If WiFi's own config ever sets a different country,
#   it will silently override HaLow's region and break it (BCF mismatch,
#   endless "Country code X not found in BCF" firmware reload loop).
# - channelization_scheme=1 (IEEE802.11-2020) is required for AU; scheme=0
#   is explicitly rejected by the driver for this region.
# - Interface name drifts across reboots (wlu1, wlu1u2, wlan1u2, ...),
#   so it's detected dynamically every time.
# - A lightweight background watchdog re-asserts `iw reg set AU` every 20s
#   as a defensive safety net against future regdomain drift.

# Ensure BCF firmware files are in /lib/firmware/morse so driver never enters failsafe mode
if [ ! -e /lib/firmware/morse/bcf_boardtype_0804.bin ]; then
    ln -sf morsemicro/bcf_boardtype_0804.bin /lib/firmware/morse/bcf_boardtype_0804.bin 2>/dev/null
    ln -sf morsemicro/bcf_mf15457.bin /lib/firmware/morse/bcf_mf15457.bin 2>/dev/null
fi

rmmod morse 2>/dev/null
rmmod dot11ah 2>/dev/null
sync; echo 3 > /proc/sys/vm/drop_caches
modprobe dot11ah channelization_scheme=1
modprobe morse country=AU
sleep 5

IFACE=$(ip -o link show | awk '{print $2}' | tr -d ':' | grep '^wlu' | head -1)
if [ -z "$IFACE" ]; then
    echo "HaLow interface not found. Potential ENOMEM boot crash detected."
    # Attempt to dynamically locate and reset the Morse Micro USB interface
    HALOW_USB_DIR=$(grep -l 325b /sys/bus/usb/devices/*/idVendor 2>/dev/null | cut -d/ -f1-6 | head -1)
    if [ -n "$HALOW_USB_DIR" ] && [ -w "$HALOW_USB_DIR/authorized" ]; then
        echo "Resetting HaLow USB port ($HALOW_USB_DIR) to force re-probe..."
        echo 0 > "$HALOW_USB_DIR/authorized"
        sleep 2
        sync; echo 3 > /proc/sys/vm/drop_caches
        echo 1 > "$HALOW_USB_DIR/authorized"
        sleep 5
        # Re-attempt interface detection
        IFACE=$(ip -o link show | awk '{print $2}' | tr -d ':' | grep '^wlu' | head -1)
    fi
    
    # Final check
    [ -z "$IFACE" ] && { echo "HaLow interface recovery failed."; exit 1; }
    echo "HaLow interface successfully recovered."
fi
echo "Using interface: $IFACE"

iw reg set AU
ip link set "$IFACE" up

HALOW_BW=4
if [ -s /etc/gateway/halow_bandwidth ]; then
    HALOW_BW=$(cat /etc/gateway/halow_bandwidth | tr -d ' \n\r')
fi
echo "Starting HaLow with bandwidth: ${HALOW_BW}MHz"
morsectrl -i "$IFACE" channel -c 924000 -o "$HALOW_BW"

# Build wpa.conf from gateway config files (or fall back to existing values)
HALOW_SSID="INTHINGS-HALOW"
if [ -s /etc/gateway/halow_ssid ]; then
    HALOW_SSID=$(cat /etc/gateway/halow_ssid | tr -d ' \n\r')
fi

# Securely read HaLow password from HSM
echo "Reading HaLow password from HSM..."
SECRETS=$(cat /run/gateway_secrets/raw_secrets 2>/dev/null)
HALOW_PSK=$(echo "$SECRETS" | grep "^halow_password:" | cut -d' ' -f2-)
if [ -n "$HALOW_PSK" ] && [ "$HALOW_PSK" != "NOT FOUND" ]; then
    HALOW_PSK=$(echo "$HALOW_PSK" | base64 -d 2>/dev/null || echo "$HALOW_PSK")
else
    echo "ERROR: halow_password not found in HSM. HaLow cannot start." >&2
    exit 1
fi

cat > /run/halow_wpa.conf << WPAEOF
ctrl_interface=DIR=/var/run/wpa_supplicant
update_config=1
country=AU
sae_pwe=2

network={
        ssid="$HALOW_SSID"
        psk="$HALOW_PSK"
        sae_password="$HALOW_PSK"
        key_mgmt=WPA-PSK SAE
        ieee80211w=1
}
WPAEOF

pkill -f "wpa_supplicant.*$IFACE" 2>/dev/null || true
rm -f "/var/run/wpa_supplicant/$IFACE"
wpa_supplicant -B -i "$IFACE" -c /run/halow_wpa.conf
for i in $(seq 1 15); do
    if wpa_cli -i "$IFACE" status 2>/dev/null | grep -q "wpa_state=COMPLETED"; then
        break
    fi
    sleep 1
done
UDHCPC_OUT=$(udhcpc -i "$IFACE" -n -q 2>&1)
echo "$UDHCPC_OUT"

GW_IP=$(echo "$UDHCPC_OUT" | awk '
/obtained from/ {
    for (i=1; i<=NF; i++) {
        if ($i == "from") {
            gw = $(i+1)
            gsub(/[^0-9.]/, "", gw)
            print gw
            exit
        }
    }
}
')

ip route del default dev "$IFACE" 2>/dev/null
if [ -n "$GW_IP" ]; then
    ip route replace "$GW_IP" dev "$IFACE" scope link 2>/dev/null
fi

# Watchdog: re-force AU every 20s if the global regdomain drifts
(
  while true; do
    sleep 20
    CUR=$(iw reg get | awk '/country/{print $2}' | head -1 | cut -d: -f1)
    if [ "$CUR" != "AU" ]; then
      logger -t start-halow "Regulatory drifted to $CUR — forcing back to AU" 2>/dev/null
      iw reg set AU
    fi
  done
) >/dev/null 2>&1 &
