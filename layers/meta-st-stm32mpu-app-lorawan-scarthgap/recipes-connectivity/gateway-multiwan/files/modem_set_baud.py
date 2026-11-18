#!/usr/bin/env python3
"""
modem_set_baud.py — Set SIM7600 UART baud rate to 460800 baud.

This script is called by pon-4g before launching pppd.
It negotiates the baud rate change over AT commands so that all
subsequent PPP data runs at 460800 instead of 115200, giving ~4x
faster Docker image pulls over cellular.

Flash-and-forget: baked into Yocto via gateway-multiwan recipe.
"""

import serial
import time
import sys

TTY = "/dev/ttySTM5"
TARGET_BAUD = 460800
INITIAL_BAUDS = [115200, 460800, 9600, 57600]


def send_at(port, cmd, wait=0.3):
    """Send an AT command and return the response."""
    port.write((cmd + "\r\n").encode())
    time.sleep(wait)
    resp = port.read(port.in_waiting or 256).decode(errors="ignore").strip()
    return resp


def try_open(baud, timeout=2):
    """Try to open the serial port at the given baud."""
    try:
        s = serial.Serial(TTY, baud, timeout=timeout)
        time.sleep(0.1)
        return s
    except Exception:
        return None


def check_at(port):
    """Returns True if modem responds to AT."""
    resp = send_at(port, "AT")
    return "OK" in resp


def set_baud_460800():
    # Step 1: Find the current working baud
    current_port = None
    current_baud = None
    for baud in INITIAL_BAUDS:
        port = try_open(baud)
        if port is None:
            continue
        if check_at(port):
            current_baud = baud
            current_port = port
            print(f"Modem responding at {baud} baud")
            break
        port.close()

    if current_port is None:
        print("ERROR: Modem not responding on any baud", file=sys.stderr)
        sys.exit(1)

    # Already at target?
    if current_baud == TARGET_BAUD:
        print(f"Modem already at {TARGET_BAUD} baud — nothing to do")
        current_port.close()
        sys.exit(0)

    # Step 2: Ask modem to switch to 460800
    print(f"Sending AT+IPR={TARGET_BAUD} ...")
    resp = send_at(current_port, f"AT+IPR={TARGET_BAUD}", wait=0.5)
    print(f"  Response: {resp!r}")

    if "ERROR" in resp:
        print("ERROR: Modem rejected baud change command", file=sys.stderr)
        current_port.close()
        sys.exit(1)

    current_port.close()
    time.sleep(0.3)

    # Step 3: Verify modem now responds at 460800
    verify_port = try_open(TARGET_BAUD)
    if verify_port is None:
        print("ERROR: Could not re-open port at 460800", file=sys.stderr)
        sys.exit(1)

    if check_at(verify_port):
        print(f"SUCCESS: Modem confirmed running at {TARGET_BAUD} baud")
        verify_port.close()
        sys.exit(0)
    else:
        print("ERROR: Modem did not respond at 460800 after switch", file=sys.stderr)
        verify_port.close()
        sys.exit(1)


if __name__ == "__main__":
    set_baud_460800()
