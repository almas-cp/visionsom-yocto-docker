#!/bin/sh
# /etc/wan-failover/start-5g.sh
# Brings up the Telit FN990A28 5G modem over QMI.
# Accepts optional resolved APN and PDP context parameters.

DEV="/dev/cdc-wdm0"
PERSIST_APN_FILE="/etc/gateway/last_working_5g_apn"

# Parse CLI arguments if provided by sim_manager.py
if [ -n "$1" ]; then
    APN="$1"
    IP_TYPE="${2:-IPV4V6}"
    echo "Using sim_manager parameters: APN='$APN', IP_TYPE='$IP_TYPE'"
else
    # Fallback to brute-force try loop if no parameters passed
    BASE_APNS="auto airtelgprs.com telstra.internet yesinternet live.vodafone.com internet telstra.wap jionet www bsnlnet"
    LAST_APN=""
    if [ -f "$PERSIST_APN_FILE" ]; then
        LAST_APN=$(cat "$PERSIST_APN_FILE" | tr -d ' \n\r')
    fi

    APNS=""
    if [ -n "$LAST_APN" ]; then
        APNS="$LAST_APN"
        for A in $BASE_APNS; do
            if [ "$A" != "$LAST_APN" ]; then
                APNS="$APNS $A"
            fi
        done
    else
        APNS="$BASE_APNS"
    fi
fi

systemctl stop ModemManager 2>/dev/null || true

# Determine interface name dynamically
IFACE=""
for dev_path in /sys/class/net/ww*; do
    if [ -e "$dev_path" ]; then
        IFACE=$(basename "$dev_path")
        break
    fi
done

if [ -z "$IFACE" ]; then
    echo "No QMI network interface (ww*) found."
    exit 1
fi

echo "Using interface: $IFACE"

MODE=$(qmicli -d "$DEV" --dms-get-operating-mode 2>/dev/null | grep -o "online\|offline")
if [ "$MODE" != "online" ]; then
    qmicli -d "$DEV" --dms-set-operating-mode=online 2>/dev/null
    sleep 5
fi

ip link set "$IFACE" down 2>/dev/null
sleep 1
echo Y > /sys/class/net/$IFACE/qmi/raw_ip

connect_5g() {
    local try_apn="$1"
    local try_iptype="$2"

    local wds_v4=""
    local wds_v6=""

    if [ "$try_apn" = "auto" ]; then
        wds_v4="ip-type=4"
        wds_v6="ip-type=6"
    else
        wds_v4="apn='$try_apn',ip-type=4"
        wds_v6="apn='$try_apn',ip-type=6"
    fi

    # Determine which context types to request based on IP_TYPE
    local req_v4=0
    local req_v6=0
    if [ "$try_iptype" = "IPV4" ]; then
        req_v4=1
    elif [ "$try_iptype" = "IPV6" ]; then
        req_v6=1
    else
        req_v4=1
        req_v6=1
    fi

    echo "Trying 5G APN: $try_apn ($try_iptype)..."
    
    local handle_v4=""
    local cid_v4=""
    if [ "$req_v4" -eq 1 ]; then
        # Start IPv4 network connection
        qmicli -d "$DEV" --device-open-net='net-raw-ip|net-no-qos-header' \
          --wds-start-network="$wds_v4" \
          --client-no-release-cid > /tmp/qmi_net_v4.log 2>&1 || true
          
        handle_v4=$(grep "Packet data handle" /tmp/qmi_net_v4.log | sed -E "s/.*'([0-9]+)'.*/\1/")
        cid_v4=$(grep "Connection client kept alive" /tmp/qmi_net_v4.log | sed -E "s/.*\(CID: ([0-9]+)\).*/\1/")
    fi
      
    local handle_v6=""
    local cid_v6=""
    if [ "$req_v6" -eq 1 ]; then
        # Start IPv6 network connection (allocating CID and setting family=6 first to prevent PolicyMismatch)
        local cid_temp
        cid_temp=$(qmicli -d "$DEV" --wds-noop --client-no-release-cid 2>/dev/null | grep "CID:" | sed -E "s/.*CID: '([0-9]+)'.*/\1/")
        if [ -n "$cid_temp" ]; then
            qmicli -d "$DEV" --wds-set-ip-family=6 --client-cid="$cid_temp" --client-no-release-cid >/dev/null 2>&1 || true
            qmicli -d "$DEV" --device-open-net='net-raw-ip|net-no-qos-header' \
              --wds-start-network="$wds_v6" \
              --client-cid="$cid_temp" --client-no-release-cid > /tmp/qmi_net_v6.log 2>&1 || true
        fi
          
        handle_v6=$(grep "Packet data handle" /tmp/qmi_net_v6.log | sed -E "s/.*'([0-9]+)'.*/\1/")
        cid_v6=$(grep "Connection client kept alive" /tmp/qmi_net_v6.log | sed -E "s/.*\(CID: ([0-9]+)\).*/\1/")
    fi
    
    if [ -n "$handle_v4" ] || [ -n "$handle_v6" ]; then
        echo "Network started (V4 Handle: $handle_v4, V6 Handle: $handle_v6). Bringing interface $IFACE up..."
        ip link set "$IFACE" up
        sleep 2
        
        local v4_ok=0
        if [ -n "$handle_v4" ]; then
            if udhcpc -i "$IFACE" -n -q -T 5; then
                v4_ok=1
            fi
        fi
        
        # Check if we got at least one connection type working
        if [ "$v4_ok" -eq 1 ] || [ -n "$handle_v6" ]; then
            echo "Successfully connected to 5G using APN: $try_apn"
            # Save working APN to eMMC persistent config directory
            mkdir -p /etc/gateway
            echo "$try_apn" > "$PERSIST_APN_FILE"
            
            # Delete default route from dev so failover service handles it
            ip route del default dev "$IFACE" 2>/dev/null || true
            return 0
        else
            echo "Failed to obtain DHCP lease. Releasing..."
            if [ -n "$cid_v4" ]; then
                qmicli -d "$DEV" --wds-stop-network="$handle_v4" --client-cid="$cid_v4" >/dev/null 2>&1 || true
            fi
            if [ -n "$cid_v6" ]; then
                qmicli -d "$DEV" --wds-stop-network="$handle_v6" --client-cid="$cid_v6" >/dev/null 2>&1 || true
            fi
            ip link set "$IFACE" down 2>/dev/null
            return 1
        fi
    else
        echo "QMI network registration failed for APN '$try_apn'."
        return 1
    fi
}

if [ -n "$APN" ]; then
    # Run with sim_manager settings
    if connect_5g "$APN" "$IP_TYPE"; then
        exit 0
    else
        echo "ERROR: Dynamic 5G APN connection failed. Falling back to default list..."
        # If dynamic fails, try default try loop as fallback
        APN=""
    fi
fi

# Run brute-force loop if no APN is set or if dynamic query failed
if [ -z "$APN" ]; then
    for A in $APNS; do
        if connect_5g "$A" "IPV4V6"; then
            exit 0
        else
            echo "Failed to connect using APN: $A"
            sleep 2
        fi
    done
fi

echo "ERROR: All 5G APNs failed to connect." >&2
exit 1
