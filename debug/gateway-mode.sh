#!/usr/bin/env bash
# gateway-mode.sh - Route all traffic through OpenWrt VM via /8 routes
#
# Strategy: all /8 routes (0-223) point to VM.
# Only the local /24 subnet goes via en0 (more specific than /8).
# This bypasses macOS's en0 cloning route issue.
#
# Usage:
#   bash debug/gateway-mode.sh on
#   bash debug/gateway-mode.sh off
#   bash debug/gateway-mode.sh check
#   bash debug/gateway-mode.sh status

set -euo pipefail

VM_LAN="192.168.101.2"
WIFI_IFACE="en0"
MARKER_FILE="/tmp/.gateway-mode-active"

detect_local_subnet() {
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

add_routes() {
    local_subnet="$(detect_local_subnet)" || { echo "[gateway] Cannot detect local subnet"; exit 1; }
    echo "[gateway] Local subnet: $local_subnet"

    # All /8 routes to VM (0-126, 128-223)
    echo "[gateway] Adding 223 /8 routes to VM ($VM_LAN)..."
    for i in $(seq 0 126) $(seq 128 223); do
        sudo route -n add -net "${i}.0.0.0/8" "$VM_LAN" >/dev/null 2>&1 || true
    done

    # 内网段走 VM（用于访问 GNB peer 的局域网）
    # 先删掉 en0 上的克隆路由（/16），再加我们的
    echo "[gateway] Adding 192.168.0.0/16 via VM (for GNB peer LANs)..."
    sudo route -n delete -net 192.168.0.0/16 -interface "$WIFI_IFACE" >/dev/null 2>&1 || true
    sudo route -n add -net 192.168.0.0/16 "$VM_LAN" >/dev/null 2>&1 || true

    # Local subnet via en0 (more specific than /16, overrides)
    echo "[gateway] Adding $local_subnet via $WIFI_IFACE..."
    sudo route -n add -net "$local_subnet" -interface "$WIFI_IFACE" >/dev/null 2>&1 || true

    # 清除 bridge100 上的 REJECT 克隆路由缓存
    sudo route -n flush 2>/dev/null || true
}

delete_routes() {
    echo "[gateway] Removing routes..."
    for i in $(seq 0 126) $(seq 128 223); do
        sudo route -n delete -net "${i}.0.0.0/8" "$VM_LAN" >/dev/null 2>&1 || true
    done
    sudo route -n delete -net 192.168.0.0/16 "$VM_LAN" >/dev/null 2>&1 || true
}

usage() {
    echo "Usage: bash debug/gateway-mode.sh [on|off|check|status]"
    echo "  on      Route all traffic through VM (GNB tunnel)"
    echo "  off     Remove /8 routes, restore normal routing"
    echo "  check   Test connectivity through VM"
    echo "  status  Show current routing state"
    exit 1
}

case "${1:-status}" in
on)
    echo "[gateway] Enabling gateway mode..."
    add_routes
    touch "$MARKER_FILE"
    echo ""
    echo "[gateway] Done. All traffic -> $VM_LAN (VM -> GNB tunnel)"
    echo "[gateway] Restore: bash debug/gateway-mode.sh off"
    ;;

off)
    echo "[gateway] Disabling gateway mode..."
    delete_routes
    rm -f "$MARKER_FILE"
    echo "[gateway] Done."
    ;;

check)
    echo "=== Connectivity Test ==="
    echo ""

    echo "--- VM reachability ---"
    if ping -c1 -t3 "$VM_LAN" &>/dev/null; then
        echo "  $VM_LAN  OK"
    else
        echo "  $VM_LAN  FAIL"
        exit 1
    fi

    echo ""
    echo "--- route get for public IP ---"
    route -n get 9.9.9.9 | grep -E 'interface|gateway'

    echo ""
    echo "--- ping 9.9.9.9 (via VM) ---"
    ping -c2 -t5 9.9.9.9 2>&1 || true

    echo ""
    echo "--- traceroute to 9.9.9.9 ---"
    traceroute -m3 -w2 9.9.9.9 2>&1 || true

    echo ""
    echo "--- curl egress IP ---"
    EGRESS="$(curl -4s --max-time 10 https://api.ipify.org 2>/dev/null)" || EGRESS="(timeout)"
    echo "  Egress IP: $EGRESS"
    WIFI_IP="$(ipconfig getifaddr "$WIFI_IFACE" 2>/dev/null || echo 'N/A')"
    echo "  WiFi IP:   $WIFI_IP"
    if [ "$EGRESS" != "(timeout)" ] && [ "$EGRESS" != "$WIFI_IP" ]; then
        echo "  -> Traffic routed through VM/tunnel"
    else
        echo "  -> Same as WiFi or timeout"
    fi

    echo ""
    echo "--- LAN connectivity ---"
    ping -c1 -t3 192.168.10.1 &>/dev/null && echo "  192.168.10.1  OK" || echo "  192.168.10.1  FAIL"
    ;;

status)
    echo "=== Gateway Mode Status ==="
    if [ -f "$MARKER_FILE" ]; then
        echo "  Mode: ACTIVE (routes to VM)"
    else
        echo "  Mode: INACTIVE (normal routing)"
    fi
    echo ""
    echo "=== Default Route ==="
    netstat -rn | grep '^default' | head -3
    echo ""
    echo "=== /8 routes to VM ==="
    netstat -rn | grep "$VM_LAN" | head -5
    TOTAL=$(netstat -rn | grep "$VM_LAN" | wc -l | tr -d ' ')
    echo "  ... total: $TOTAL routes"
    ;;

*)
    usage
    ;;
esac
