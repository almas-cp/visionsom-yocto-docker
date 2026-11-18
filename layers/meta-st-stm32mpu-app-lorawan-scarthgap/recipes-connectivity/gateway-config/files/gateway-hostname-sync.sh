#!/bin/sh
# /usr/bin/gateway-hostname-sync.sh
# Ensures hostname is dynamically set from /etc/gateway/azure_device_id if present,
# otherwise falls back to the default factory hostname 'admin'.

CONFIG_DIR="/etc/gateway"
AZ_DEV_FILE="$CONFIG_DIR/azure_device_id"
[ -f "/app/config/azure_device_id" ] && AZ_DEV_FILE="/app/config/azure_device_id"

TARGET_HN="admin"
if [ -f "$AZ_DEV_FILE" ]; then
    DEV_ID=$(cat "$AZ_DEV_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$DEV_ID" ] && [ "$DEV_ID" != "NOT FOUND" ] && [ "$DEV_ID" != "ERROR"* ]; then
        TARGET_HN="$DEV_ID"
    fi
fi

CURRENT_HN=$(hostname 2>/dev/null)
if [ "$CURRENT_HN" != "$TARGET_HN" ]; then
    echo "Gateway Hostname Sync: Setting hostname to '$TARGET_HN'"
    echo "$TARGET_HN" > /etc/hostname 2>/dev/null || true
    hostname "$TARGET_HN" 2>/dev/null || hostnamectl set-hostname "$TARGET_HN" 2>/dev/null || true
fi

# Ensure 127.0.0.1 resolves for both 'admin' and TARGET_HN in /etc/hosts
for h in "admin" "$TARGET_HN"; do
    if [ -n "$h" ] && ! grep -qw "$h" /etc/hosts 2>/dev/null; then
        echo "127.0.0.1 $h" >> /etc/hosts 2>/dev/null || true
    fi
done
