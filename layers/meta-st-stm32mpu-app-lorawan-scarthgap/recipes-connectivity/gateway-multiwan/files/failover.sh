#!/bin/sh
# 5-way WAN failover: Ethernet > WiFi > 4G > 5G > HaLow
# Strict priority failover — keeps secondary interfaces OFF/disabled
# unless higher-priority links do not have internet.

PING_COUNT=3
PING_TIMEOUT=3
CHECK_INTERVAL=30
STATE_FILE="/var/run/wan-failover.state"
TEST_IP="8.8.8.8"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

get_ip() {
    ip -4 addr show "$1" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1
}

# Robust gateway lookup (checks routes, systemd DHCP leases, networkctl, and subnet fallback)
get_gateway() {
    iface="$1"
    [ -z "$iface" ] && return 1

    # 1. Existing route with via (ignoring test IPs and default)
    _gw=$(ip route show dev "$iface" 2>/dev/null | awk '
    $1 ~ /^(8\.8\.8\.8|1\.1\.1\.1|9\.9\.9\.9|8\.8\.4\.4|208\.67\.222\.222)$/ { next }
    /via/ {
        for (i=1; i<=NF; i++) {
            if ($i == "via") {
                print $(i+1)
                exit
            }
        }
    }
    !/\// && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $1 != "default" {
        print $1
        exit
    }
    ')
    if [ -n "$_gw" ]; then
        echo "$_gw" | tr -d ')'
        return 0
    fi

    # 2. Check systemd-networkd lease file by interface index
    if [ -f "/sys/class/net/$iface/ifindex" ]; then
        _idx=$(cat "/sys/class/net/$iface/ifindex" 2>/dev/null)
        if [ -n "$_idx" ] && [ -f "/run/systemd/netif/leases/$_idx" ]; then
            _gw=$(grep '^ROUTER=' "/run/systemd/netif/leases/$_idx" 2>/dev/null | head -1 | cut -d= -f2)
            if [ -n "$_gw" ]; then
                echo "$_gw"
                return 0
            fi
        fi
    fi

    # 3. Check networkctl status
    _gw=$(networkctl status "$iface" 2>/dev/null | awk '/via [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {
        for (i=1; i<=NF; i++) {
            if ($i == "via") {
                sub(/\).*/, "", $(i+1))
                print $(i+1)
                exit
            }
        }
    }')
    if [ -n "$_gw" ]; then
        echo "$_gw"
        return 0
    fi

    # 4. Standard IPv4 /24 gateway heuristic (.1) for broadcast networks (never for ppp/cellular)
    case "$iface" in
        ppp*|wwan*|cdc*) ;;
        *)
            _cur_ip=$(get_ip "$iface")
            if [ -n "$_cur_ip" ]; then
                echo "${_cur_ip%.*}.1"
                return 0
            fi
            ;;
    esac
}

check_internet() {
    iface="$1"
    gw="$2"

    [ -z "$iface" ] && return 1

    # Temporarily add a specific route to TEST_IP via this interface
    # Required because ping -I fails if there is no route via the interface
    if [ -n "$gw" ]; then
        ip route add "$TEST_IP" via "$gw" dev "$iface" 2>/dev/null
    else
        ip route add "$TEST_IP" dev "$iface" 2>/dev/null
    fi

    ping -c 2 -W 2 -I "$iface" "$TEST_IP" >/dev/null 2>&1
    res=$?

    if [ -n "$gw" ]; then
        ip route del "$TEST_IP" via "$gw" dev "$iface" 2>/dev/null
    else
        ip route del "$TEST_IP" dev "$iface" 2>/dev/null
    fi

    return $res
}

# wait_for_ppp_dns: polls /etc/ppp/resolv.conf up to $1 seconds for nameservers
wait_for_ppp_dns() {
    max_wait="${1:-15}"
    elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if awk '/nameserver/ {print $2}' /etc/ppp/resolv.conf 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1  # timed out — no nameservers found
}

# inject_dns_resolv: write nameservers directly into /etc/resolv.conf
# bypasses systemd-resolved stub race on carrier switch
inject_dns_resolv() {
    dns_list="$1"  # space-separated nameserver IPs
    {
        echo "# Written by wan-failover on $(date '+%Y-%m-%d %H:%M:%S')"
        for ns in $dns_list; do
            echo "nameserver $ns"
        done
        echo "options timeout:2 attempts:3"
    } > /etc/resolv.conf
    log "DNS injected into /etc/resolv.conf: $dns_list"
}

# patch_container_dns: overwrite /etc/resolv.conf inside a running container
patch_container_dns() {
    container="$1"
    dns_list="$2"  # space-separated IPs
    if docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
        dns_block=$(printf 'nameserver %s\n' $dns_list)
        docker exec "$container" sh -c "printf '%s\n' '$dns_block' > /etc/resolv.conf" 2>/dev/null && \
            log "DNS patched inside container $container" || \
            log "WARNING: Could not patch DNS inside container $container"
    fi
}

switch_to() {
    name="$1"
    iface="$2"
    ip="$3"

    current=$(cat "$STATE_FILE" 2>/dev/null)
    has_default=$(ip route show default 2>/dev/null | grep -q "$iface" && echo 1 || echo 0)

    if [ "$current" = "$name" ] && [ "$has_default" -eq 1 ]; then
        return 0
    fi

    log "Switching active WAN to $name ($iface, IP: $ip)"

    # Look up gateway BEFORE deleting existing default routes
    gw=$(get_gateway "$iface")

    while ip route show default | grep -q default; do
        ip route del default 2>/dev/null || break
    done

    if [ -n "$gw" ]; then
        ip route add default via "$gw" dev "$iface"
        log "  -> via $gw dev $iface"
    else
        ip route add default dev "$iface" scope link
        log "  -> dev $iface (no gateway, point-to-point)"
    fi

    echo "$name" > "$STATE_FILE"
    log "Active WAN is now $name ($iface)"

    # -------------------------------------------------------
    # DNS resolution fix for cellular (ppp0 / 4G / 5G):
    # pppd writes nameservers to /etc/ppp/resolv.conf but
    # systemd-resolved (127.0.0.53) may not have them yet.
    # We directly overwrite /etc/resolv.conf AND patch inside
    # running containers to guarantee immediate DNS resolution.
    # -------------------------------------------------------
    if [ "$iface" = "ppp0" ] || [ "$name" = "4g" ] || [ "$name" = "5g" ]; then
        log "Cellular WAN active — waiting up to 15s for PPP nameservers..."
        if wait_for_ppp_dns 15; then
            PPP_DNS=$(awk '/nameserver/ {print $2}' /etc/ppp/resolv.conf 2>/dev/null | tr '\n' ' ')
            FULL_DNS="$PPP_DNS 8.8.8.8 1.1.1.1"
        else
            log "WARNING: No PPP nameservers found — using public fallback only."
            FULL_DNS="8.8.8.8 1.1.1.1 8.8.4.4"
        fi

        # 1. Overwrite host /etc/resolv.conf directly (fastest fix)
        inject_dns_resolv "$FULL_DNS"

        # 2. Configure systemd-resolved for the interface
        if command -v resolvectl >/dev/null 2>&1; then
            resolvectl dns "$iface" $FULL_DNS 2>/dev/null || true
            resolvectl default-route "$iface" true 2>/dev/null || true
            resolvectl domain "$iface" "~." 2>/dev/null || true
            resolvectl flush-caches 2>/dev/null || true
        fi

        # 3. Patch DNS inside running containers (Docker bridge mode isolation)
        for ct in basicstation edgeAgent edgeHub; do
            patch_container_dns "$ct" "$FULL_DNS"
        done

        # 4. TCP MTU / MSS Clamping & Kernel Keepalive for Cellular
        # Eliminates packet drops for large payloads (e.g. edgeAgent twin reported properties)
        # and prevents dead NAT sockets from hanging for 2 hours.
        sysctl -w net.ipv4.tcp_keepalive_time=30 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_keepalive_intvl=10 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_keepalive_probes=3 >/dev/null 2>&1 || true

        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

        iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

        # 5. Restart basicstation, edgeAgent, and edgeHub so all IoT/LoRaWAN
        # services drop stale sockets and establish fresh connections on the new WAN
        sleep 2  # brief pause so resolv.conf is stable before restart
        if systemctl is-active --quiet basicstation 2>/dev/null; then
            log "Restarting basicstation systemd service for fresh DNS startup..."
            systemctl restart basicstation 2>/dev/null
        elif docker inspect -f '{{.State.Running}}' basicstation 2>/dev/null | grep -q true; then
            log "Restarting basicstation Docker container for fresh DNS startup..."
            docker restart basicstation 2>/dev/null
        fi

        if docker inspect -f '{{.State.Running}}' edgeAgent 2>/dev/null | grep -q true; then
            log "Restarting edgeAgent for clean connection on cellular WAN ($name)..."
            docker restart edgeAgent 2>/dev/null || true
        fi
        if docker inspect -f '{{.State.Running}}' edgeHub 2>/dev/null | grep -q true; then
            log "Restarting edgeHub for clean connection on cellular WAN ($name)..."
            docker restart edgeHub 2>/dev/null || true
        fi

    else
        # Non-cellular WAN (Ethernet/WiFi/HaLow) — restore systemd-resolved managed resolv.conf
        if [ -f /run/systemd/resolve/stub-resolv.conf ]; then
            ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
        fi
        if command -v resolvectl >/dev/null 2>&1; then
            resolvectl default-route "$iface" true 2>/dev/null || true
            resolvectl flush-caches 2>/dev/null || true
        fi

        # Restart services on non-cellular switch too
        if systemctl is-active --quiet basicstation 2>/dev/null; then
            log "Restarting basicstation systemd service due to network switch..."
            systemctl restart basicstation 2>/dev/null
        elif docker inspect -f '{{.State.Running}}' basicstation 2>/dev/null | grep -q true; then
            log "Restarting basicstation Docker container due to network switch..."
            docker restart basicstation 2>/dev/null
        fi

        if docker inspect -f '{{.State.Running}}' edgeAgent 2>/dev/null | grep -q true; then
            log "Restarting edgeAgent for clean connection on $name..."
            docker restart edgeAgent 2>/dev/null || true
        fi
        if docker inspect -f '{{.State.Running}}' edgeHub 2>/dev/null | grep -q true; then
            log "Restarting edgeHub for clean connection on $name..."
            docker restart edgeHub 2>/dev/null || true
        fi
    fi
}

set_leds() {
    active_wan="$1"
    
    wifi_val=0
    gsm_val=0
    halow_val=0
    
    case "$active_wan" in
        "wifi")
            wifi_val=1
            ;;
        "4g"|"5g")
            gsm_val=1
            ;;
        "halow")
            halow_val=1
            ;;
    esac
    
    [ -e "/sys/class/leds/wifi-led/brightness" ] && echo "$wifi_val" > /sys/class/leds/wifi-led/brightness
    [ -e "/sys/class/leds/gsm-led/brightness" ] && echo "$gsm_val" > /sys/class/leds/gsm-led/brightness
    [ -e "/sys/class/leds/halow-led/brightness" ] && echo "$halow_val" > /sys/class/leds/halow-led/brightness

    if docker inspect -f '{{.State.Running}}' basicstation 2>/dev/null | grep -q true; then
        [ -e "/sys/class/leds/lora-led/brightness" ] && echo "1" > /sys/class/leds/lora-led/brightness
    else
        [ -e "/sys/class/leds/lora-led/brightness" ] && echo "0" > /sys/class/leds/lora-led/brightness
    fi
}

set_interface_state() {
    name="$1"
    iface="$2"
    state="$3" # "UP" or "DOWN"

    case "$name" in
        "ethernet")
            if [ "$state" = "UP" ]; then
                ip link set dev "$iface" up 2>/dev/null
            else
                # CRITICAL FIX: Never shut down Ethernet even if it's lower priority.
                # Shutting down Ethernet kills local LAN access and SSH.
                # We just ignore the DOWN request for Ethernet.
                : 
            fi
            ;;
        "wifi")
            if [ "$state" = "UP" ]; then
                systemctl is-active --quiet wifi-wlan0.service || {
                    log "Activating WiFi connection..."
                    systemctl start wifi-wlan0.service 2>/dev/null
                }
            else
                # CRITICAL FIX: Never shut down Wi-Fi even if it's lower priority.
                # Shutting down Wi-Fi kills local wireless SSH/config access.
                # We just ignore the DOWN request for Wi-Fi.
                :
            fi
            ;;
        "4g")
            if [ "$state" = "UP" ]; then
                systemctl is-active --quiet 4g-ppp.service || {
                    log "Activating 4G connection..."
                    systemctl start 4g-ppp.service 2>/dev/null
                }
            else
                systemctl is-active --quiet 4g-ppp.service && {
                    log "Deactivating 4G connection (lower priority)..."
                    systemctl stop 4g-ppp.service 2>/dev/null
                    ip link set dev "$iface" down 2>/dev/null
                }
            fi
            ;;
        "5g")
            if [ "$state" = "UP" ]; then
                systemctl is-active --quiet 5g-wwu1i2.service || {
                    log "Activating 5G connection..."
                    systemctl start 5g-wwu1i2.service 2>/dev/null
                }
            else
                systemctl is-active --quiet 5g-wwu1i2.service && {
                    log "Deactivating 5G connection (lower priority)..."
                    systemctl stop 5g-wwu1i2.service 2>/dev/null
                    ip link set dev "$iface" down 2>/dev/null
                }
            fi
            ;;
        "halow")
            if [ "$state" = "UP" ]; then
                systemctl is-active --quiet halow-wlu1.service || {
                    log "Activating HaLow connection..."
                    systemctl start halow-wlu1.service 2>/dev/null
                }
            else
                systemctl is-active --quiet halow-wlu1.service && {
                    log "Deactivating HaLow connection (lower priority)..."
                    systemctl stop halow-wlu1.service 2>/dev/null
                    ip link set dev "$iface" down 2>/dev/null
                }
            fi
            ;;
    esac
}

log "WAN failover monitor started (Strict Priority with Interface Shutdowns)"

# Make sure all interfaces start in a known state
# (will be brought up as needed in the loop)
systemctl stop wifi-wlan0.service 4g-ppp.service 5g-wwu1i2.service halow-wlu1.service 2>/dev/null || true

while true; do
    if [ -f "/tmp/ap_mode_active" ]; then
        log "Wi-Fi AP configuration mode is active. Suspending wan-failover until AP is torn down..."
        sleep "$CHECK_INTERVAL"
        continue
    fi

    ETH=$(ip -o link show | awk '{print $2}' | tr -d ':' | grep '^end' | head -1)
    WIFI=$(ip -o link show | awk '{print $2}' | tr -d ':' | grep '^wlan' | head -1)
    G4=$(ip -o link show | awk '{print $2}' | tr -d ':' | grep '^ppp' | head -1)
    G5=$(ip -o link show | awk '{print $2}' | tr -d ':' | grep '^wwu' | head -1)
    HALOW=$(ip -o link show | awk '{print $2}' | tr -d ':' | grep '^wlu' | head -1)

    # Dynamic interface names
    IF_ETH="${ETH:-end0}"
    IF_WIFI="${WIFI:-wlan0}"
    IF_G4="${G4:-ppp0}"
    IF_G5="${G5:-wwu1i2}"
    IF_HALOW="${HALOW:-wlu1}"

    # Read priority
    PRIORITY=$(cat /etc/gateway/network_priority 2>/dev/null | tr -d ' \n\r' | tr 'a-z' 'A-Z')
    [ -z "$PRIORITY" ] && PRIORITY="AUTO"

    case "$PRIORITY" in
        "WIFI")
            NET_LIST="wifi:$IF_WIFI ethernet:$IF_ETH 5g:$IF_G5 4g:$IF_G4 halow:$IF_HALOW"
            ;;
        "4G")
            NET_LIST="4g:$IF_G4 5g:$IF_G5 ethernet:$IF_ETH wifi:$IF_WIFI halow:$IF_HALOW"
            ;;
        "5G")
            NET_LIST="5g:$IF_G5 4g:$IF_G4 ethernet:$IF_ETH wifi:$IF_WIFI halow:$IF_HALOW"
            ;;
        "GSM")
            NET_LIST="4g:$IF_G4 5g:$IF_G5 ethernet:$IF_ETH wifi:$IF_WIFI halow:$IF_HALOW"
            ;;
        "HALOW")
            NET_LIST="halow:$IF_HALOW 5g:$IF_G5 4g:$IF_G4 ethernet:$IF_ETH wifi:$IF_WIFI"
            ;;
        *) # ETHERNET or AUTO
            NET_LIST="ethernet:$IF_ETH wifi:$IF_WIFI 5g:$IF_G5 4g:$IF_G4 halow:$IF_HALOW"
            ;;
    esac

    active_found=0
    target_wan_name=""
    target_wan_iface=""
    target_wan_ip=""

    for entry in $NET_LIST; do
        name=$(echo "$entry" | cut -d: -f1)
        iface=$(echo "$entry" | cut -d: -f2)

        if [ "$active_found" -eq 1 ]; then
            # Turn OFF lower priority interfaces to prevent connection/resource usage
            set_interface_state "$name" "$iface" "DOWN"
            continue
        fi

        # Ensure the interface is ON to test/use it
        set_interface_state "$name" "$iface" "UP"

        ip=$(get_ip "$iface")
        gw=$(get_gateway "$iface")

        if [ -n "$ip" ] && check_internet "$iface" "$gw"; then
            active_found=1
            target_wan_name="$name"
            target_wan_iface="$iface"
            target_wan_ip="$ip"
        else
            log "Interface $name ($iface) has no internet access."
        fi
    done

    switched=0
    if [ -n "$target_wan_name" ]; then
        switch_to "$target_wan_name" "$target_wan_iface" "$target_wan_ip"
        set_leds "$target_wan_name"
        switched=1
    fi

    if [ "$switched" -eq 0 ]; then
        log "WARNING: No interface has working internet"
        set_leds "none"
    fi

    sleep "$CHECK_INTERVAL"
done
