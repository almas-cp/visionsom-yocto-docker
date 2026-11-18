#!/bin/sh

LOG_TAG="factory-reset"
CONFIG_DIR="/etc/gateway"

log_info() {
    logger -t "$LOG_TAG" -p user.info "$1"
    echo "[INFO] $1"
}

log_warn() {
    logger -t "$LOG_TAG" -p user.warning "$1"
    echo "[WARN] $1"
}

log_err() {
    logger -t "$LOG_TAG" -p user.err "$1"
    echo "[ERROR] $1" >&2
}

remove_if_exists() {
    if [ -e "$1" ]; then
        rm -f "$1" || {
            log_err "Failed to remove $1"
            return 1
        }
        log_info "Removed $1"
    else
        log_warn "Not found, skipping $1"
    fi
    return 0
}

main() {
    log_info "Factory reset started: clearing saved gateway configuration"

    FAILED=0

    log_info "Clearing secure credentials stored inside HSM..."
    /usr/bin/store-gateway-secrets /dev/i2c-0 --clear >/dev/null 2>&1 || {
        log_warn "Failed to clear HSM slots (HSM might be busy or uninitialized)"
    }

    for f in \
        "$CONFIG_DIR/api_key" \
        "$CONFIG_DIR/azure_connection_string" \
        "$CONFIG_DIR/gateway_id" \
        "$CONFIG_DIR/log_level" \
        "$CONFIG_DIR/log_settings" \
        "$CONFIG_DIR/network_priority" \
        "$CONFIG_DIR/network_server" \
        "$CONFIG_DIR/portal_auth.json" \
        "$CONFIG_DIR/portal_sessions.json" \
        "$CONFIG_DIR/portal_suggestions.json" \
        "$CONFIG_DIR/region_profile" \
        "$CONFIG_DIR/ttn_api_key" \
        "$CONFIG_DIR/wifi_credentials" \
        "$CONFIG_DIR/wifi_password" \
        "$CONFIG_DIR/wifi_ssid" \
        "$CONFIG_DIR/zip_password" \
        "$CONFIG_DIR/azure_hostname" \
        "$CONFIG_DIR/azure_device_id" \
        "$CONFIG_DIR/.last_azure_hash" \
        "/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" \
        "/etc/wpa_supplicant/wpa_supplicant.conf" \
        "/etc/basicstation/station.conf" \
        "/etc/basicstation/tc.uri" \
        "/etc/basicstation/tc.key" \
        "/etc/basicstation/tc.trust"
    do
        remove_if_exists "$f" || FAILED=1
    done

    if [ "$FAILED" -ne 0 ]; then
        log_err "Factory reset completed with errors"
        exit 1
    fi

    # Reset system hostname to default 'admin'
    echo "admin" > /etc/hostname
    hostnamectl set-hostname "admin" 2>/dev/null || hostname "admin" 2>/dev/null || true

    sync
    log_info "Saved config cleared successfully; rebooting"
    sleep 2
    reboot
}

main "$@"
