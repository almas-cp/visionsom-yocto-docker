#!/bin/sh
# gsm_setbaud.sh TARGET_BAUD
# Uses pppd (which supports BOTHER for non-standard baud) to probe and switch
# modem baud rate. Works where Python termios/ctypes/stty cannot.
TARGET=${1:-4000000}
PORT=/dev/ttySTM5
LOCK=/var/run/pppd/lock/ttySTM5

cat > /tmp/gsm_switch.chat << CHATEOF
TIMEOUT 3
"" "AT"
"OK" "AT+IPR=${TARGET}"
"" ""
CHATEOF

for PROBE in ${TARGET} 115200 921600; do
    rm -f "$LOCK" 2>/dev/null
    rm -f /tmp/gsm_chat_${PROBE}.log
    echo "Trying modem at ${PROBE} baud -> switch to ${TARGET}..."
    # pppd logs "Serial connection established." to syslog, not stderr, so use
    # its own logfile option; otherwise success is never detected and every
    # probe rate is tried needlessly.
    timeout 5 pppd $PORT $PROBE nocrtscts noauth local nodetach \
        logfile /tmp/gsm_chat_${PROBE}.log \
        connect "chat -v -f /tmp/gsm_switch.chat" \
        >/dev/null 2>&1 || true
    rm -f "$LOCK" 2>/dev/null
    sleep 0.3
    if grep -q "Serial connection established" /tmp/gsm_chat_${PROBE}.log 2>/dev/null; then
        echo "Modem found at ${PROBE}, switched to ${TARGET}."
        exit 0
    fi
done

echo "WARNING: Could not find modem at any probe rate. Continuing anyway."
exit 0
