#!/bin/sh
# STM32MP157 SX1302 Reset Script for VisionSOM Gateway
# Uses libgpiod v2.1 (gpioset) - confirmed mapping via gpioinfo:
#   PG8  = gpiochip6 line 8   (D23 - Reset)
#   PD12 = gpiochip3 line 12  (D18 - Power enable)
#
# NOTE: gpioset without -z holds the line and BLOCKS until killed.
# We use -z (daemonize) for every set so the script doesn't hang.
# Each gpio_set call kills any PREVIOUS holder of that exact chip+line
# before requesting it again, otherwise the chip reports "busy".

RESET_CHIP=gpiochip6
RESET_LINE=8

POWER_CHIP=gpiochip3
POWER_LINE=12

WAIT_GPIO() {
    sleep 0.1
}

gpio_set() {
    # $1=chip $2=line $3=value
    ps aux | grep "gpioset -c $1 -z $2" | grep -v grep | awk '{print $1}' | xargs -r kill -9 2>/dev/null
    sleep 0.05
    gpioset -c "$1" -z "$2"="$3"
    sleep 0.05
}

init() {
    echo "Initializing GPIO lines..."
    gpio_set $RESET_CHIP $RESET_LINE 0
}

reset() {
    echo "CoreCell power enable through $POWER_CHIP line $POWER_LINE..."
    gpio_set $POWER_CHIP $POWER_LINE 1
    WAIT_GPIO

    echo "CoreCell reset through $RESET_CHIP line $RESET_LINE..."
    gpio_set $RESET_CHIP $RESET_LINE 1
    WAIT_GPIO
    gpio_set $RESET_CHIP $RESET_LINE 0
    WAIT_GPIO
}

term() {
    echo "Resetting Pins..."
    gpio_set $RESET_CHIP $RESET_LINE 0
    ps aux | grep "gpioset -c $POWER_CHIP -z $POWER_LINE" | grep -v grep | awk '{print $1}' | xargs -r kill -9 2>/dev/null
    echo "Resetting Done..."
}

case "$1" in
    start)
        term
        init
        reset
        ;;
    stop)
        reset
        term
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac

exit 0
