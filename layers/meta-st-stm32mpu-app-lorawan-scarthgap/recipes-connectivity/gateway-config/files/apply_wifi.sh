#!/bin/sh
# /usr/bin/apply_wifi.sh
# Applies WiFi credentials retrieved securely from the SE050E HSM on I2C4
# Supports both OPEN (non-secure) and SECURED networks.
# Features an Automatic Security Exploration & Debugging engine that dynamically
# probes and selects the appropriate security mode (WPA3-SAE, WPA2-PSK, WPA-PSK, or OPEN).

WIFI_CRED_FILE="/etc/gateway/wifi_credentials"
[ ! -f "$WIFI_CRED_FILE" ] && WIFI_CRED_FILE="/app/config/wifi_credentials"
WPA_SUPPLICANT_CONF="/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

if [ ! -f "$WIFI_CRED_FILE" ]; then
    echo "ERROR: wifi_credentials file missing" >&2
    exit 1
fi

# Read non-sensitive SSID and explicit security setting if set
SSID=$(grep "^WIFI_SSID=" "$WIFI_CRED_FILE" | cut -d"'" -f2)
WIFI_SECURITY=$(grep "^WIFI_SECURITY=" "$WIFI_CRED_FILE" 2>/dev/null | cut -d"'" -f2)

if [ -z "$SSID" ]; then
    echo "ERROR: WIFI_SSID not found in credentials file" >&2
    exit 1
fi

# Read Wi-Fi password from HSM
echo "Checking Wi-Fi credentials for SSID '$SSID'..."
SECRETS=$(/usr/bin/read-gateway-secrets /dev/i2c-0 2>/dev/null)
PASSWORD=$(echo "$SECRETS" | grep "^wifi_password:" | cut -d' ' -f2-)

if [ "$PASSWORD" = "NOT FOUND" ] || [ "$PASSWORD" = "NONE" ] || [ "$PASSWORD" = "OPEN" ]; then
    PASSWORD=""
else
    [ -n "$PASSWORD" ] && PASSWORD=$(echo -n "$PASSWORD" | base64 -d)
fi

# Detect dynamic interface (wlan0 or wlan1)
IFACE=$(ip -o link show | awk -F': ' '/wlan/{print $2}' | head -1)
IFACE="${IFACE:-wlan0}"

mkdir -p /etc/wpa_supplicant

write_wpa_conf() {
    profile_type="$1"
    
    case "$profile_type" in
        "OPEN")
            cat << EOF > "$WPA_SUPPLICANT_CONF"
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
    ssid="$SSID"
    key_mgmt=NONE
}
EOF
            ;;
            
        "WPA_AUTO")
            # Universal auto-negotiate profile: WPA3 SAE, WPA2-PSK (AES/CCMP & SHA256), WPA-PSK
            cat << EOF > "$WPA_SUPPLICANT_CONF"
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
    ssid="$SSID"
    psk="$PASSWORD"
    key_mgmt=WPA-PSK WPA-PSK-SHA256 SAE
    proto=RSN WPA
    pairwise=CCMP TKIP
    group=CCMP TKIP
    ieee80211w=1
}
EOF
            ;;
            
        "WPA2_STANDARD")
            # Standard WPA2-PSK (AES-CCMP, PMF disabled for legacy APs)
            cat << EOF > "$WPA_SUPPLICANT_CONF"
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
    ssid="$SSID"
    psk="$PASSWORD"
    key_mgmt=WPA-PSK
    proto=RSN
    pairwise=CCMP
    group=CCMP
    ieee80211w=0
}
EOF
            ;;
            
        "WPA_LEGACY")
            # Legacy mixed WPA/WPA2 with TKIP support
            cat << EOF > "$WPA_SUPPLICANT_CONF"
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
    ssid="$SSID"
    psk="$PASSWORD"
    key_mgmt=WPA-PSK
    proto=WPA RSN
    pairwise=TKIP CCMP
    group=TKIP CCMP
    ieee80211w=0
}
EOF
            ;;
            
        "WPA3_STRICT")
            # Strict WPA3-Personal SAE profile
            cat << EOF > "$WPA_SUPPLICANT_CONF"
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
    ssid="$SSID"
    psk="$PASSWORD"
    key_mgmt=SAE
    proto=RSN
    pairwise=CCMP
    group=CCMP
    ieee80211w=2
}
EOF
            ;;
    esac
    
    chmod 600 "$WPA_SUPPLICANT_CONF"
}

check_association() {
    max_wait="${1:-6}"
    elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
        sleep 1
        elapsed=$((elapsed + 1))
        state=$(wpa_cli -i "$IFACE" status 2>/dev/null | grep "^wpa_state=" | cut -d= -f2)
        if [ "$state" = "COMPLETED" ]; then
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# Connection Execution & Auto-Exploration Flow
# -----------------------------------------------------------------------------

# If explicitly set to NONE or no password exists in HSM, use OPEN network mode
if [ "$WIFI_SECURITY" = "NONE" ] || [ -z "$PASSWORD" ]; then
    echo "Configuring OPEN (non-secure) Wi-Fi network: '$SSID'..."
    write_wpa_conf "OPEN"
else
    echo "Configuring SECURED Wi-Fi network: '$SSID'..."
    echo "Starting Automatic Security Exploration Engine..."
    
    # Profile 1: Universal Auto-negotiate
    echo "[Profile 1/4] Probing Universal Auto-negotiate (WPA3-SAE / WPA2-PSK)..."
    write_wpa_conf "WPA_AUTO"
fi

# Ensure previous instances are stopped and interface is ready
systemctl stop "wpa_supplicant@${IFACE}.service" 2>/dev/null || true
pkill -f "wpa_supplicant -B -i $IFACE" 2>/dev/null || true
ip link set "$IFACE" down 2>/dev/null || true
sleep 1
ip link set "$IFACE" up
wpa_supplicant -B -i "$IFACE" -c "$WPA_SUPPLICANT_CONF"

# For secured networks, probe and automatically explore fallback profiles if needed
if [ -n "$PASSWORD" ] && [ "$WIFI_SECURITY" != "NONE" ]; then
    if ! check_association 6; then
        echo "[Profile 1 failed] Access point rejected or timed out on auto-negotiation."
        echo "[Profile 2/4] Exploring Fallback Profile 2 (Standard WPA2-PSK AES-CCMP)..."
        write_wpa_conf "WPA2_STANDARD"
        wpa_cli -i "$IFACE" reconfigure >/dev/null 2>&1
        
        if ! check_association 5; then
            echo "[Profile 2 failed] Exploring Fallback Profile 3 (Mixed WPA/WPA2 TKIP/CCMP)..."
            write_wpa_conf "WPA_LEGACY"
            wpa_cli -i "$IFACE" reconfigure >/dev/null 2>&1
            
            if ! check_association 5; then
                echo "[Profile 3 failed] Exploring Fallback Profile 4 (Strict WPA3-SAE)..."
                write_wpa_conf "WPA3_STRICT"
                wpa_cli -i "$IFACE" reconfigure >/dev/null 2>&1
                
                if ! check_association 5; then
                    echo "WARNING: All secured profiles failed to associate. Reverting to auto-profile for background retries."
                    write_wpa_conf "WPA_AUTO"
                    wpa_cli -i "$IFACE" reconfigure >/dev/null 2>&1
                else
                    echo "Successfully associated using Profile 4 (WPA3-SAE)!"
                fi
            else
                echo "Successfully associated using Profile 3 (Mixed WPA/WPA2)!"
            fi
        else
            echo "Successfully associated using Profile 2 (Standard WPA2-PSK)!"
        fi
    else
        echo "Successfully associated using Universal Auto-negotiation!"
    fi
else
    if check_association 5; then
        echo "Successfully associated with OPEN Wi-Fi network!"
    else
        echo "Associating with OPEN network in background..."
    fi
fi

# Request DHCP IP lease
echo "Requesting DHCP lease on $IFACE..."
udhcpc -b -i "$IFACE" -n -q >/dev/null 2>&1 || true

# Securely remove cleartext temporary password files
rm -f /etc/gateway/wifi_password /app/config/wifi_password

echo "WiFi configuration applied successfully!"
