#!/bin/sh
set -eu
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

LOG_DIR="/tmp/logs"
LOG_FILE="$LOG_DIR/ble_provision.log"
BLE_SCRIPT="/usr/share/gateway_conf/ble.py"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1

echo "=================================================="
echo "$(date '+%Y-%m-%d %H:%M:%S') BLE provisioning starting"
echo "=================================================="

cleanup_ble() {
    echo "Stopping BLE provisioning and powering down Bluetooth radio..."
    bluetoothctl discoverable off >/dev/null 2>&1 || true
    hciconfig hci0 noscan >/dev/null 2>&1 || true
    hciconfig hci0 down >/dev/null 2>&1 || true
    exit 0
}
trap cleanup_ble INT TERM

rfkill unblock bluetooth 2>/dev/null || true
hciconfig hci0 up 2>/dev/null || true
bluetoothctl power on >/dev/null 2>&1 || true
bluetoothctl discoverable on >/dev/null 2>&1 || true
bluetoothctl pairable on >/dev/null 2>&1 || true

# Reset Waveshare SX1302 LoRa concentrator
/usr/share/gateway_conf/reset_lgw.sh start || true

if [ ! -f "$BLE_SCRIPT" ]; then
    echo "BLE script not found: $BLE_SCRIPT"
    exit 1
fi

while true; do
    python3 "$BLE_SCRIPT" || true

    # Exit if device is configured
    if python3 -c "import sys; sys.path.insert(0, '/usr/share/gateway_conf'); from main import is_gateway_configured; sys.exit(0 if is_gateway_configured() else 1)" 2>/dev/null; then
        echo "Device is configured — BLE provisioning finished."
        cleanup_ble
    fi

    # Exit if user switched setup mode via button
    CURRENT_MODE=$(cat /tmp/gateway_setup_mode 2>/dev/null || echo "ble")
    if [ "$CURRENT_MODE" != "ble" ]; then
        echo "Setup mode changed to '$CURRENT_MODE' — exiting BLE provisioning."
        cleanup_ble
    fi

    echo "Gateway is still unconfigured. Restarting BLE provisioning in 2 seconds..."
    sleep 2
done
