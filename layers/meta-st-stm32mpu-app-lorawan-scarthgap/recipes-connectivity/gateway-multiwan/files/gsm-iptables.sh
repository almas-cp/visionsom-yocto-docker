#!/bin/sh
# /usr/bin/gsm-iptables.sh
# Apply TCP MSS clamping for PPP (ppp0) interface.
# Called by gsm-iptables.service at boot — baked into Yocto.
# Prevents "IP fragmentation needed" issues on GSM/4G connections.

# Wait for ppp0 to appear (up to 120s)
count=0
while ! ip link show ppp0 > /dev/null 2>&1; do
    if [ "$count" -ge 120 ]; then
        echo "gsm-iptables: ppp0 not found after 120s, applying rules anyway"
        break
    fi
    sleep 1
    count=$((count + 1))
done

# Flush any existing MSS rules to avoid duplicates
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -D OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# Apply clamping — reduces TCP MSS to PMTU (typically ~1450 for PPP)
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

echo "gsm-iptables: TCP MSS clamping rules applied on ppp0"
