#!/bin/sh
# eth_debug.sh
# Direct laptop-to-gateway Ethernet debug mode on end0.
# Intended for long button hold of 20-45 seconds.
#
# Details:
#   IFACE    : end0
#   IP       : 192.168.200.1
#   DHCP     : 192.168.200.10 – 192.168.200.50
#   Use case : Plug laptop directly into gateway for SSH/debug

IFACE="end0"
DEBUG_IP="192.168.200.1"
DHCP_RANGE_START="192.168.200.10"
DHCP_RANGE_END="192.168.200.50"
DHCP_LEASE_TIME="12h"

LOG_TAG="eth-debug"
LOG_DIR="/usr/local/gateway_conf/logs"
LOG_FILE="$LOG_DIR/eth_debug.log"
DNSMASQ_CONF="/tmp/dnsmasq_eth_debug.conf"
DNSMASQ_PID="/tmp/dnsmasq_eth_debug.pid"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 664 "$LOG_FILE" 2>/dev/null || true
exec >> "$LOG_FILE" 2>&1

log_info() { logger -t "$LOG_TAG" -p user.info "$1"; echo "[INFO]  $1"; }
log_warn() { logger -t "$LOG_TAG" -p user.warning "$1"; echo "[WARN]  $1"; }
log_err()  { logger -t "$LOG_TAG" -p user.err "$1"; echo "[ERROR] $1"; }

cleanup() {
    log_info "Stopping Ethernet debug mode..."
    if [ -f "$DNSMASQ_PID" ]; then
        kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
        rm -f "$DNSMASQ_PID"
    fi
    ip addr flush dev "$IFACE" 2>/dev/null || true
    ip link set "$IFACE" down 2>/dev/null || true
    ip link set "$IFACE" up 2>/dev/null || true
    systemctl start dnsmasq 2>/dev/null || true
    systemctl start systemd-networkd.service 2>/dev/null || true
    rm -f "$DNSMASQ_CONF"
    log_info "Ethernet debug mode stopped"
}

trap cleanup EXIT INT TERM

write_dnsmasq_conf() {
    cat > "$DNSMASQ_CONF" << CONF
interface=${IFACE}
bind-interfaces
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE_TIME}
dhcp-option=option:router,${DEBUG_IP}
dhcp-option=option:dns-server,${DEBUG_IP}
no-resolv
log-dhcp
CONF
}

main() {
    log_info "Starting Ethernet debug mode"
    log_info "IP: ${DEBUG_IP} | SSH target: ${DEBUG_IP}"

    systemctl stop dnsmasq 2>/dev/null || true
    killall dnsmasq 2>/dev/null || true
    pkill -x dnsmasq 2>/dev/null || true
    sleep 2

    systemctl stop systemd-networkd.service 2>/dev/null || true

    ip addr flush dev "$IFACE" 2>/dev/null || true
    ip link set "$IFACE" down 2>/dev/null || true
    sleep 1
    ip link set "$IFACE" up
    ip addr add "${DEBUG_IP}/24" dev "$IFACE"

    log_info "Current interface state:"
    ip addr show dev "$IFACE"

    write_dnsmasq_conf
    log_info "Starting dnsmasq"
    dnsmasq --conf-file="$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID" --bind-interfaces || {
        log_err "dnsmasq failed to start"
        exit 1
    }

    sleep 2
    log_info "Ethernet debug mode active"
    log_info "Connect laptop to $IFACE, get DHCP, then SSH to ${DEBUG_IP}"

    while true; do
        sleep 5
    done
}

main "$@"
