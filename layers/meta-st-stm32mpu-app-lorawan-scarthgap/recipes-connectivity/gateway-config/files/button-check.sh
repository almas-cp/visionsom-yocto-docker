#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
LOG_TAG="button-check"


# Check if running inside container or on host
IN_CONTAINER=0
if [ -f /.dockerenv ] || grep -qE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; then
    IN_CONTAINER=1
fi


if [ "$IN_CONTAINER" -eq 1 ]; then
    NSENTER="nsenter -t 1 -m -u -n -i"
    echo "ConfigModule container active — disabling host-level button-check.service..."
    $NSENTER /usr/bin/systemctl stop button-check.service >/dev/null 2>&1 || true

    cleanup() {
        echo "ConfigModule stopping — restoring host-level button-check.service..."
        $NSENTER /usr/bin/systemctl start button-check.service >/dev/null 2>&1 || true
        exit 0
    }
    trap cleanup SIGINT SIGTERM EXIT
fi

# Determine gpiochip for PD11
GPIOCHIP="gpiochip3"
GPIO_LINE=11

# Find gpio line dynamically if gpiofind is available
if command -v gpiofind >/dev/null 2>&1; then
    FOUND=$(gpiofind PD11 2>/dev/null)
    if [ -n "$FOUND" ]; then
        GPIOCHIP=$(echo "$FOUND" | awk '{print $1}')
        GPIO_LINE=$(echo "$FOUND" | awk '{print $2}')
    fi
fi

# Active state (1 = pressed if active high, 0 = pressed if active low)
ACTIVE_STATE="1"
CHECK_INTERVAL=0.1

read_gpio() {
    # Try libgpiod v2 syntax first (Yocto Scarthgap / modern Linux)
    val=$(gpioget --numeric -c "$GPIOCHIP" "$GPIO_LINE" 2>/dev/null)
    if [ -n "$val" ]; then
        echo "$val"
        return
    fi
    # Fallback to libgpiod v1 syntax (legacy)
    val=$(gpioget "$GPIOCHIP" "$GPIO_LINE" 2>/dev/null)
    echo "$val"
}

MAIN_PY="/usr/share/gateway_conf/main.py"
if [ "$IN_CONTAINER" -eq 1 ] && [ -f /app/main.py ]; then
    MAIN_PY="/app/main.py"
fi

echo "Button check service started on $GPIOCHIP line $GPIO_LINE (active=$ACTIVE_STATE)..."

# ── FIRST-BOOT CHECK: Automatically start BLE if gateway is unconfigured ──
if [ -f "$MAIN_PY" ]; then
    echo "Running first-boot configuration check..."
    python3 -u "$MAIN_PY" check-first-boot
fi

# ── HOSTNAME SYNC: Set hostname to azure_device_id if configured, else default to 'admin' ──
AZ_DEV_FILE="/etc/gateway/azure_device_id"
[ -f "/app/config/azure_device_id" ] && AZ_DEV_FILE="/app/config/azure_device_id"
if [ -f "$AZ_DEV_FILE" ]; then
    DEV_ID=$(cat "$AZ_DEV_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$DEV_ID" ] && [ "$DEV_ID" != "NOT FOUND" ]; then
        if [ "$(hostname 2>/dev/null)" != "$DEV_ID" ]; then
            echo "Setting hostname to Azure DeviceId: $DEV_ID"
            echo "$DEV_ID" > /etc/hostname
            hostnamectl set-hostname "$DEV_ID" 2>/dev/null || hostname "$DEV_ID" 2>/dev/null || true
        fi
    fi
elif [ ! -s /etc/hostname ]; then
    echo "admin" > /etc/hostname
    hostnamectl set-hostname "admin" 2>/dev/null || hostname "admin" 2>/dev/null || true
fi


while true; do
    VALUE=$(read_gpio)

    if [ "$VALUE" = "$ACTIVE_STATE" ]; then
        echo "Button press detected on $GPIOCHIP line $GPIO_LINE. Measuring duration..."
        start_time=$(date +%s)

        while [ "$(read_gpio)" = "$ACTIVE_STATE" ]; do
            sleep $CHECK_INTERVAL
        done

        end_time=$(date +%s)
        elapsed_time=$((end_time - start_time))

        echo "Button was pressed for $elapsed_time seconds."

        if [ -f "$MAIN_PY" ]; then
            python3 -u "$MAIN_PY" button "$elapsed_time"
        else
            if [ "$elapsed_time" -gt 20 ]; then
                /usr/share/gateway_conf/factory_reset.sh
            fi
        fi

        sleep 1
    fi
    sleep $CHECK_INTERVAL
done