#!/usr/bin/env bash
# test-gateway-switch.sh - Test VM gateway with auto-restore on failure
#
# Switches default gateway to VM, tests connectivity, restores on failure.
# Safe: auto-restores if anything goes wrong.
#
# Usage: bash debug/test-gateway-switch.sh

set -euo pipefail

VM_LAN="192.168.101.2"
WIFI_IFACE="en0"
WIFI_GW="$(ipconfig getoption "$WIFI_IFACE" router 2>/dev/null || echo "192.168.0.1")"
LAN_NET=""
RESTORED=0

restore_gateway() {
    if [ "$RESTORED" -eq 1 ]; then return; fi
    RESTORED=1
    echo ""
    echo "[restore] Restoring default gateway to $WIFI_GW..."
    sudo route -n delete default >/dev/null 2>&1 || true
    sudo route -n add default "$WIFI_GW"
    if [ -n "$LAN_NET" ]; then
        sudo route -n delete -net "$LAN_NET" >/dev/null 2>&1 || true
    fi
    echo "[restore] Done. Gateway -> $WIFI_GW"
}
trap restore_gateway EXIT

detect_lan_net() {
    local ip mask
    ip="$(ipconfig getifaddr "$WIFI_IFACE" 2>/dev/null)" || return 1
    mask="$(ifconfig "$WIFI_IFACE" 2>/dev/null | grep 'inet ' | sed 's/.*mask 0x\([0-9a-f]*\).*/\1/')" || return 1
    local cidr=0 m=$((16#$mask))
    while (( m > 0 )); do (( cidr += m & 1, m >>= 1 )); done
    local IFS='.'; read -r a b c d <<< "$ip"
    local netmask_dec=$(( (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
    local ip_dec=$(( (a << 24) + (b << 16) + (c << 8) + d ))
    local net_dec=$(( ip_dec & netmask_dec ))
    printf '%d.%d.%d.%d/%d\n' "$(( (net_dec >> 24) & 0xFF ))" "$(( (net_dec >> 16) & 0xFF ))" "$(( (net_dec >> 8) & 0xFF ))" "$(( net_dec & 0xFF ))" "$cidr"
}

echo "========================================="
echo "  VM Gateway Switch Test (with auto-restore)"
echo "========================================="
echo ""

# Step 1: Pre-checks
echo "[1/4] Pre-checks..."
echo "  WiFi GW:   $WIFI_GW"
echo "  VM LAN:    $VM_LAN"

LAN_NET="$(detect_lan_net)" || { echo "  Cannot detect LAN subnet"; exit 1; }
echo "  LAN net:   $LAN_NET"

if ! ping -c1 -t3 "$VM_LAN" &>/dev/null; then
    echo "  VM not reachable! Aborting."
    exit 1
fi
echo "  VM:        reachable"

# Step 2: Switch gateway
echo ""
echo "[2/4] Switching default gateway to $VM_LAN..."

# Keep LAN direct
sudo route -n delete -net "$LAN_NET" >/dev/null 2>&1 || true
sudo route -n add -net "$LAN_NET" -interface "$WIFI_IFACE"

# Switch default
sudo route -n delete default >/dev/null 2>&1 || true
sudo route -n add default "$VM_LAN"

echo "  Done. Checking route:"
route -n get default | grep -E 'gateway|interface'

# Step 3: Test connectivity
echo ""
echo "[3/4] Testing connectivity..."
echo ""

echo "  --- traceroute to 8.8.8.8 (first 3 hops) ---"
traceroute -m3 -w2 8.8.8.8 2>&1 || true

echo ""
echo "  --- ping 8.8.8.8 (3 packets) ---"
if ping -c3 -t5 8.8.8.8; then
    echo "  PING OK"
else
    echo "  PING FAIL"
fi

echo ""
echo "  --- curl api.ipify.org ---"
EGRESS_IP="$(curl -4s --max-time 10 https://api.ipify.org 2>/dev/null)" || EGRESS_IP="(timeout)"
WIFI_IP="$(ipconfig getifaddr "$WIFI_IFACE" 2>/dev/null || echo 'N/A')"
echo "  Egress IP: $EGRESS_IP"
echo "  WiFi IP:   $WIFI_IP"

# Step 4: Summary
echo ""
echo "[4/4] Summary"
echo "  Gateway:    $VM_LAN (via bridge100)"
echo "  Egress IP:  $EGRESS_IP"
echo "  WiFi IP:    $WIFI_IP"

if [ "$EGRESS_IP" != "(timeout)" ] && [ "$EGRESS_IP" != "$WIFI_IP" ]; then
    echo "  Status:     TRAFFIC WENT THROUGH VM"
elif [ "$EGRESS_IP" = "$WIFI_IP" ]; then
    echo "  Status:     TRAFFIC WENT DIRECT (same as WiFi)"
else
    echo "  Status:     TIMEOUT (connectivity issue)"
fi

echo ""
echo "  Auto-restoring gateway..."
# cleanup trap will run
