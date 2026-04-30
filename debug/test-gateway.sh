#!/usr/bin/env bash
# test-gateway.sh - Test if VM (192.168.101.2) can forward traffic
#
# Does NOT change default gateway. Adds a specific route for one test IP,
# tests connectivity, then cleans up.
#
# Usage: bash debug/test-gateway.sh

set -euo pipefail

VM_LAN="192.168.101.2"
TEST_IP="8.8.8.8"
WIFI_IFACE="en0"
WIFI_GW="$(ipconfig getoption "$WIFI_IFACE" router 2>/dev/null || echo "192.168.0.1")"

cleanup() {
    echo ""
    echo "[cleanup] Removing test route for $TEST_IP..."
    sudo route -n delete "$TEST_IP" >/dev/null 2>&1 || true
    echo "[cleanup] Done."
}
trap cleanup EXIT

echo "========================================="
echo "  VM Gateway Test"
echo "========================================="
echo ""

# Step 1: Check VM reachability
echo "[1/5] Checking VM reachability ($VM_LAN)..."
if ping -c2 -t3 "$VM_LAN" &>/dev/null; then
    echo "  OK - VM is reachable"
else
    echo "  FAIL - VM not reachable. Is QEMU running?"
    exit 1
fi

# Step 2: Check VM can reach the internet
echo ""
echo "[2/5] Checking VM internet access..."
VM_INTERNET="$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 openwrt-qemu \
    "ping -c2 -W3 8.8.8.8 >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null)"
if [ "$VM_INTERNET" = "OK" ]; then
    echo "  OK - VM can reach 8.8.8.8"
else
    echo "  FAIL - VM cannot reach internet. Check WAN config."
    exit 1
fi

# Step 3: Add specific route for test IP via VM
echo ""
echo "[3/5] Adding route: $TEST_IP via $VM_LAN..."
sudo route -n delete "$TEST_IP" >/dev/null 2>&1 || true
sudo route -n add "$TEST_IP" "$VM_LAN"
echo "  Route added."

# Step 4: Test connectivity through VM
echo ""
echo "[4/5] Testing traffic through VM..."
echo ""

echo "  --- ping $TEST_IP ---"
if ping -c3 -t5 "$TEST_IP"; then
    echo "  PING OK"
else
    echo "  PING FAIL"
fi

echo ""
echo "  --- traceroute to $TEST_IP ---"
traceroute -m5 -w2 "$TEST_IP" || true

echo ""
echo "  --- curl api.ipify.org (check egress IP) ---"
EGRESS_IP="$(curl -4s --max-time 10 https://api.ipify.org 2>/dev/null)" || EGRESS_IP="(timeout)"
echo "  Egress IP: $EGRESS_IP"
echo "  WiFi IP:   $(ipconfig getifaddr "$WIFI_IFACE" 2>/dev/null)"
if [ "$EGRESS_IP" != "(timeout)" ] && [ "$EGRESS_IP" != "$(ipconfig getifaddr "$WIFI_IFACE" 2>/dev/null)" ]; then
    echo "  -> Traffic went through a different path (likely VM)"
else
    echo "  -> Same as WiFi IP or timeout"
fi

echo ""
echo "========================================="
echo "  Test complete. Cleanup will run automatically."
echo "========================================="
