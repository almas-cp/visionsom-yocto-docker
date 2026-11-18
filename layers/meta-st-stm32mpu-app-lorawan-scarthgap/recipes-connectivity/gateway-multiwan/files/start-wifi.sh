#!/bin/sh
# Wi-Fi starter with automatic AP security detection.
# Supports Open, WEP, WPA/WPA2-Personal, WPA3-Personal and WPA2/WPA3 transition mode.
# The Wi-Fi password is retrieved from the HSM and is never logged.

IFACE=$(ip -o link show | awk '{print $2}' | tr -d ':' | grep '^wlan' | head -1)
[ -z "$IFACE" ] && { echo "WiFi interface not found"; exit 1; }

CREDENTIALS_FILE="/etc/gateway/wifi_credentials"
WPA_CONF="/run/wpa_supplicant-wlan0.conf"
SCAN_FILE="/tmp/wifi-scan-$IFACE.txt"

SSID=""
PASSWORD=""
WIFI_SECURITY="AUTO"

[ -f "$CREDENTIALS_FILE" ] && SSID=$(grep '^WIFI_SSID=' "$CREDENTIALS_FILE" | cut -d"'" -f2)
[ -f "$CREDENTIALS_FILE" ] && WIFI_SECURITY=$(grep '^WIFI_SECURITY=' "$CREDENTIALS_FILE" 2>/dev/null | cut -d"'" -f2)

# Read the Wi-Fi secret only when a secured AP is detected.
read_wifi_password() {
    SECRETS=$(cat /run/gateway_secrets/raw_secrets 2>/dev/null) || return 1
    PASSWORD=$(printf '%s\n' "$SECRETS" | sed -n 's/^wifi_password:[[:space:]]*//p' | head -1)
    if [ -n "$PASSWORD" ] && [ "$PASSWORD" != "NOT FOUND" ] && [ "$PASSWORD" != "NONE" ] && [ "$PASSWORD" != "OPEN" ]; then
        # The HSM tool outputs base64 strings to avoid shell escape issues, so we decode it
        PASSWORD=$(echo "$PASSWORD" | base64 -d 2>/dev/null || echo "$PASSWORD")
    fi
    [ -n "$PASSWORD" ] && [ "$PASSWORD" != "NOT FOUND" ] && [ "$PASSWORD" != "NONE" ] && [ "$PASSWORD" != "OPEN" ]
}

# Extract the scan block belonging to the requested SSID.
# iw scan prints one BSS block beginning with "BSS <BSSID>".
find_ssid_block() {
    awk -v target="$SSID" '
        /^BSS / {
            if (in_block && found) exit
            in_block=1
            found=0
            block=""
        }
        in_block {
            block = block $0 "\n"
            if ($0 ~ /^[[:space:]]*SSID:/) {
                line=$0
                sub(/^[[:space:]]*SSID:[[:space:]]*/, "", line)
                if (line == target) found=1
            }
        }
        END { if (found) printf "%s", block }
    ' "$SCAN_FILE"
}

# Escape a string for use inside a quoted wpa_supplicant value.
wpa_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Detect security from the AP's advertised capabilities.
# Return value:
#   OPEN, WEP, WPA2, WPA3, TRANSITION, UNKNOWN
#
detect_security() {
    BLOCK="$1"
    HAS_RSN=0
    HAS_WPA=0
    HAS_PSK=0
    HAS_SAE=0
    HAS_PRIVACY=0

    printf '%s\n' "$BLOCK" | grep -Eq '^[[:space:]]*RSN:' && HAS_RSN=1
    printf '%s\n' "$BLOCK" | grep -Eq '^[[:space:]]*WPA:' && HAS_WPA=1
    printf '%s\n' "$BLOCK" | grep -Eq 'Authentication suites:.*PSK' && HAS_PSK=1
    printf '%s\n' "$BLOCK" | grep -Eq 'Authentication suites:.*SAE' && HAS_SAE=1
    printf '%s\n' "$BLOCK" | grep -Eq 'capability:.*Privacy' && HAS_PRIVACY=1

    if [ "$HAS_RSN" -eq 0 ] && [ "$HAS_WPA" -eq 0 ] && [ "$HAS_PRIVACY" -eq 0 ]; then
        echo "OPEN"
    elif [ "$HAS_RSN" -eq 0 ] && [ "$HAS_WPA" -eq 0 ] && [ "$HAS_PRIVACY" -eq 1 ]; then
        echo "WEP"
    elif [ "$HAS_SAE" -eq 1 ] && [ "$HAS_PSK" -eq 1 ]; then
        echo "TRANSITION"
    elif [ "$HAS_SAE" -eq 1 ]; then
        echo "WPA3"
    elif [ "$HAS_PSK" -eq 1 ] || [ "$HAS_WPA" -eq 1 ]; then
        echo "WPA2"
    else
        echo "UNKNOWN"
    fi
}

# Remove stale profile before every fresh connection attempt.
rm -f "$WPA_CONF"

if [ -z "$SSID" ]; then
    echo "ERROR: No Wi-Fi SSID configured in $CREDENTIALS_FILE"
    exit 1
fi

# Bring the interface up so that an active scan can be performed.
ip link set "$IFACE" up 2>/dev/null || true

# Stop any previous supplicant instance before scanning.
ps aux | grep "[w]pa_supplicant.*-i[[:space:]]*$IFACE" | awk '{print $1}' | xargs kill -9 2>/dev/null || true
rm -f "/var/run/wpa_supplicant/$IFACE"
sleep 1

if command -v iw >/dev/null 2>&1; then
    echo "Scanning Wi-Fi APs to detect security for configured SSID..."
    if ! iw dev "$IFACE" scan > "$SCAN_FILE" 2>/dev/null; then
        echo "WARNING: Wi-Fi scan failed; will use configured security hint if available."
        : > "$SCAN_FILE"
    fi
else
    echo "WARNING: 'iw' is not available; automatic AP security detection cannot be performed."
    : > "$SCAN_FILE"
fi

BLOCK=$(find_ssid_block)

# A hidden SSID may not appear in a normal scan. Ask the AP directly for the
# configured SSID before giving up on automatic detection.
if [ -z "$BLOCK" ] && command -v iw >/dev/null 2>&1; then
    echo "SSID '$SSID' not found in normal scan; trying directed scan for hidden SSID..."
    if iw dev "$IFACE" scan ssid "$SSID" > "$SCAN_FILE" 2>/dev/null; then
        BLOCK=$(find_ssid_block)
    fi
fi

DETECTED_SECURITY=""
[ -n "$BLOCK" ] && DETECTED_SECURITY=$(detect_security "$BLOCK")

# If the scan cannot see the SSID, fall back only to an explicit stored mode.
# AUTO without scan information is not guessed as WPA because that can create
# repeated authentication failures and misleading failover behavior.
if [ -z "$DETECTED_SECURITY" ]; then
    case "$WIFI_SECURITY" in
        NONE|OPEN) DETECTED_SECURITY="OPEN" ;;
        WEP) DETECTED_SECURITY="WEP" ;;
        WPA3|SAE) DETECTED_SECURITY="WPA3" ;;
        WPA-PSK|WPA2|WPA) DETECTED_SECURITY="WPA2" ;;
        *) DETECTED_SECURITY="UNKNOWN" ;;
    esac
    echo "SSID '$SSID' was not found in scan; configured security hint: $WIFI_SECURITY"
fi

echo "Detected Wi-Fi security for '$SSID': $DETECTED_SECURITY"

SSID_ESC=$(wpa_escape "$SSID")

case "$DETECTED_SECURITY" in
    OPEN)
        echo "Generating OPEN Wi-Fi profile..."
        cat > "$WPA_CONF" <<EOF2
ctrl_interface=/var/run/wpa_supplicant
update_config=1
p2p_disabled=1

network={
    ssid="$SSID_ESC"
    scan_ssid=1
    key_mgmt=NONE
}
EOF2
        ;;

    WEP)
        if ! read_wifi_password; then
            echo "ERROR: WEP network detected but no Wi-Fi password is available from HSM."
            rm -f "$WPA_CONF" "$SCAN_FILE"
            exit 1
        fi
        PASSWORD_ESC=$(wpa_escape "$PASSWORD")
        echo "Generating WEP Wi-Fi profile..."
        cat > "$WPA_CONF" <<EOF2
ctrl_interface=/var/run/wpa_supplicant
update_config=1
p2p_disabled=1

network={
    ssid="$SSID_ESC"
    scan_ssid=1
    key_mgmt=NONE
    wep_key0="$PASSWORD_ESC"
    wep_tx_keyidx=0
}
EOF2
        ;;

    WPA2)
        if ! read_wifi_password; then
            echo "ERROR: Secured Wi-Fi detected but no Wi-Fi password is available from HSM."
            rm -f "$WPA_CONF" "$SCAN_FILE"
            exit 1
        fi
        echo "Generating WPA/WPA2-Personal profile..."
        wpa_passphrase "$SSID" "$PASSWORD" > "$WPA_CONF" 2>/dev/null || {
            echo "ERROR: Failed to generate WPA profile."
            rm -f "$WPA_CONF" "$SCAN_FILE"
            exit 1
        }
        sed -i '1s/^/ctrl_interface=\/var\/run\/wpa_supplicant\nupdate_config=1\np2p_disabled=1\n\n/' "$WPA_CONF"
        sed -i '/^[[:space:]]*ssid=/a\    scan_ssid=1\n    key_mgmt=WPA-PSK' "$WPA_CONF"
        ;;

    WPA3|TRANSITION)
        if ! read_wifi_password; then
            echo "ERROR: WPA3/Transition network detected but no Wi-Fi password is available from HSM."
            rm -f "$WPA_CONF" "$SCAN_FILE"
            exit 1
        fi
        PASSWORD_ESC=$(wpa_escape "$PASSWORD")
        echo "Hardware (VisionSOM) does not support WPA3-SAE. Forcing WPA2 profile for compatibility..."
        cat > "$WPA_CONF" <<EOF2
ctrl_interface=/var/run/wpa_supplicant
update_config=1
p2p_disabled=1

network={
    ssid="$SSID_ESC"
    scan_ssid=1
    psk="$PASSWORD_ESC"
    key_mgmt=WPA-PSK
}
EOF2
        ;;

    *)
        echo "ERROR: Could not determine security for SSID '$SSID'."
        echo "Refusing to guess WPA security in AUTO mode."
        rm -f "$WPA_CONF" "$SCAN_FILE"
        exit 1
        ;;
esac

chmod 600 "$WPA_CONF"
rm -f "$SCAN_FILE"
echo "Generated $WPA_CONF successfully."

# Start supplicant and verify association before DHCP.
wpa_supplicant -B -i "$IFACE" -c "$WPA_CONF" || {
    echo "ERROR: wpa_supplicant failed to start."
    exit 1
}

CONNECTED=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if wpa_cli -i "$IFACE" status 2>/dev/null | grep -q '^wpa_state=COMPLETED$'; then
        CONNECTED=1
        break
    fi
    sleep 1
done

if [ "$CONNECTED" -ne 1 ]; then
    echo "ERROR: Wi-Fi association/authentication did not complete."
    wpa_cli -i "$IFACE" status 2>/dev/null | grep -E '^(wpa_state|ssid|key_mgmt|ip_address)=' || true
    exit 1
fi

echo "Wi-Fi association successful. Requesting DHCP..."
UDHCPC_OUT=$(udhcpc -i "$IFACE" -n -q 2>&1)
UDHCPC_RC=$?
echo "$UDHCPC_OUT"

[ "$UDHCPC_RC" -eq 0 ] || {
    echo "ERROR: DHCP failed on $IFACE."
    exit 1
}

if [ -z "$IP_ADDR" ]; then
    IP_ADDR=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
fi

if [ -z "$IP_ADDR" ]; then
    echo "ERROR: DHCP completed but no IPv4 address was assigned."
    exit 1
fi

echo "Wi-Fi connected successfully: $IFACE / $IP_ADDR"
exit 0
