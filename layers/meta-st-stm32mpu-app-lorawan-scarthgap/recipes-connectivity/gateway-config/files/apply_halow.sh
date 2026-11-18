#!/bin/sh
# /usr/bin/apply_halow.sh
# Applies HaLow credentials retrieved securely from the SE050E HSM.
# Reads halow_ssid from /etc/gateway/halow_ssid (non-sensitive).
# Reads halow_password from HSM (slot 0x7FFF0214).
# Generates /run/halow_wpa.conf and restarts wpa_supplicant on the HaLow interface.

HALOW_SSID_FILE="/etc/gateway/halow_ssid"
HALOW_SECURITY_FILE="/etc/gateway/halow_security"

if [ ! -f "$HALOW_SSID_FILE" ]; then
    echo "HaLow not configured: $HALOW_SSID_FILE missing. Skipping."
    exit 0
fi

HALOW_SSID=$(cat "$HALOW_SSID_FILE" | tr -d ' \n\r')
if [ -z "$HALOW_SSID" ]; then
    echo "ERROR: halow_ssid is empty" >&2
    exit 1
fi

# Read HaLow security mode (defaults to WPA-PSK for compatibility)
HALOW_SECURITY="WPA-PSK"
if [ -f "$HALOW_SECURITY_FILE" ]; then
    HALOW_SECURITY=$(cat "$HALOW_SECURITY_FILE" | tr -d ' \n\r')
fi

if [ "$HALOW_SECURITY" = "NONE" ]; then
    # Open network — no password needed
    cat > /run/halow_wpa.conf << WPAEOF
ctrl_interface=DIR=/var/run/wpa_supplicant
update_config=1
country=AU

network={
        ssid="$HALOW_SSID"
        key_mgmt=NONE
}
WPAEOF
    echo "HaLow wpa.conf written (open network, no password)."
else
    # Read HaLow password from HSM
    echo "Reading HaLow password from HSM..."
    SECRETS=$(/usr/bin/read-gateway-secrets /dev/i2c-0 2>/dev/null)
    PASSWORD=$(echo "$SECRETS" | grep "^halow_password:" | cut -d' ' -f2-)

    if [ -z "$PASSWORD" ] || [ "$PASSWORD" = "NOT FOUND" ]; then
        echo "ERROR: halow_password not found in HSM" >&2
        exit 1
    fi

    PASSWORD=$(echo -n "$PASSWORD" | base64 -d)

    cat > /run/halow_wpa.conf << WPAEOF
ctrl_interface=DIR=/var/run/wpa_supplicant
update_config=1
country=AU

network={
        ssid="$HALOW_SSID"
        psk="$PASSWORD"
        key_mgmt=WPA-PSK
        ieee80211w=1
}
WPAEOF
    chmod 600 /run/halow_wpa.conf
    echo "HaLow wpa.conf written (WPA-PSK from HSM)."
fi

# Detect HaLow interface
IFACE=$(ip -o link show | awk -F': ' '/wlu/{print $2}' | head -1)
if [ -z "$IFACE" ]; then
    echo "HaLow interface not found — wpa.conf written but not applied."
    exit 0
fi

# Restart wpa_supplicant on HaLow interface
echo "Applying HaLow connection on $IFACE..."
rm -f "/var/run/wpa_supplicant/$IFACE"
wpa_cli -i "$IFACE" reconfigure 2>/dev/null || \
    wpa_supplicant -B -i "$IFACE" -c /run/halow_wpa.conf

echo "HaLow configuration applied successfully."
