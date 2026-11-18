#!/bin/sh
# fake-hwclock — Save and restore the system clock on boards without RTC battery.
# Based on the Debian fake-hwclock package (GPL-2.0).
#
# Usage:
#   fake-hwclock save    — write current UTC time to data file
#   fake-hwclock load    — restore system clock from data file
#   fake-hwclock        — same as 'load' (default)

DATA_FILE="/var/lib/fake-hwclock/fake-hwclock.data"

save() {
    mkdir -p "$(dirname "$DATA_FILE")"
    date -u "+%Y-%m-%d %H:%M:%S" > "$DATA_FILE"
    echo "fake-hwclock: saved $(cat "$DATA_FILE") to $DATA_FILE"
}

load() {
    if [ -f "$DATA_FILE" ]; then
        SAVED="$(cat "$DATA_FILE")"
        if [ -z "$SAVED" ]; then
            echo "fake-hwclock: data file is empty, skipping clock restore."
            return
        fi

        # Only restore if saved time is NEWER than the current system time.
        # This avoids going backwards if the kernel/firmware has already set
        # a reasonable clock (e.g., from a hardware RTC if one exists).
        NOW=$(date -u "+%s")
        SAVED_EPOCH=$(date -u -d "$SAVED" "+%s" 2>/dev/null || echo 0)

        if [ "$SAVED_EPOCH" -gt "$NOW" ]; then
            date -u -s "$SAVED"
            echo "fake-hwclock: restored clock to $SAVED (was behind)"
        else
            echo "fake-hwclock: current clock ($NOW) >= saved ($SAVED_EPOCH), skipping restore."
        fi
    else
        echo "fake-hwclock: no saved timestamp found at $DATA_FILE, skipping."
    fi
}

case "${1:-load}" in
    save) save ;;
    load) load ;;
    *)
        echo "Usage: fake-hwclock {save|load}"
        exit 1
        ;;
esac
