#!/bin/sh
# /usr/bin/enable_swap.sh
# Creates and activates swap file on /usr/local

SWAPFILE="/usr/local/swapfile"

# Wait up to 10s for /usr/local filesystem to be mounted read-write
for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -d "/usr/local" ] && touch /usr/local/.mount_test 2>/dev/null && rm -f /usr/local/.mount_test && break
    sleep 1
done

if [ ! -f "$SWAPFILE" ]; then
    # Check available free space on /usr/local in MB
    FREE_MB=$(df -m /usr/local 2>/dev/null | awk 'NR==2 {print $4}')
    TARGET_MB=512
    if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt 550 ]; then
        # If userfs partition is small, safely adapt swap size
        TARGET_MB=$((FREE_MB - 30))
        [ "$TARGET_MB" -lt 32 ] && TARGET_MB=32
        echo "Warning: /usr/local has only ${FREE_MB}MB free. Sizing swap to ${TARGET_MB}MB..."
    else
        echo "Creating ${TARGET_MB}MB swap file at $SWAPFILE..."
    fi

    fallocate -l "${TARGET_MB}M" "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count="$TARGET_MB"
    chmod 0600 "$SWAPFILE"
    mkswap "$SWAPFILE"
fi

if ! swapon --show | grep -q "$SWAPFILE"; then
    echo "Activating swap file at $SWAPFILE..."
    chmod 0600 "$SWAPFILE" 2>/dev/null || true
    swapon "$SWAPFILE"
fi

echo "Current memory and swap status:"
free -m
