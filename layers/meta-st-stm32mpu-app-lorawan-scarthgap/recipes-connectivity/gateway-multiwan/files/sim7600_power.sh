#!/bin/sh
# SIM7600 4G modem power control via GPIO reset pin (PB6 -> gpiochip1, line 6
# on this board). Uses `gpioset -c` (chip+offset) rather than by-name lookup,
# since this board has a PIN NAME COLLISION: PB6 is also claimed by the
# HDMI CEC controller (40016000.cec) under the same name, so gpioset by
# name alone will fail with "pin PB6 already requested by 40016000.cec".

case "$1" in
    off)
        echo "Turning OFF modem..."
        pkill -9 gpioset 2>/dev/null || true
        gpioset -t 0ms -c 1 6=1
        echo "Modem OFF"
        ;;
    on)
        echo "Turning ON modem..."
        pkill -9 gpioset 2>/dev/null || true
        sleep 0.1
        gpioset -t 0ms -c 1 6=0
        echo "Modem power ON - Waiting 30 seconds for boot..."
        sleep 30
        echo "Modem should be ready for AT commands"
        ;;
    reset)
        echo "Resetting modem..."
        pkill -9 gpioset 2>/dev/null || true
        gpioset -t 0ms -c 1 6=1
        sleep 1
        gpioset -t 0ms -c 1 6=0
        echo "Modem reset - Waiting 30 seconds for boot..."
        sleep 30
        echo "Modem ready"
        ;;
    *)
        echo "Usage: $0 {on|off|reset}"
        ;;
esac
