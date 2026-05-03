#!/bin/bash
# check-proxy.sh — Check MyNet Proxy configuration and running status on 192.168.101.2
# Usage: bash debug/check-proxy.sh [host]

set -euo pipefail

HOST="${1:-192.168.101.2}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ssh_exec() {
    ssh $SSH_OPTS root@"$HOST" "$@" 2>/dev/null
}

print_header() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_kv() {
    printf "  %-24s %s\n" "$1" "$2"
}

print_status() {
    local label="$1"
    local value="$2"
    local color="$NC"
    case "$value" in
        running|active|enabled|up|true|yes) color="$GREEN" ;;
        stopped|inactive|disabled|down|false|no) color="$RED" ;;
        *) color="$YELLOW" ;;
    esac
    printf "  %-24s ${color}%s${NC}\n" "$label" "$value"
}

# ─────────────────────────────────────────────────────────────
# 1. Service Status
# ─────────────────────────────────────────────────────────────
print_header "1. SERVICE STATUS"

echo -e "${YELLOW}[GNB VPN]${NC}"
gnb_status=$(ssh_exec "/etc/init.d/mynet status 2>/dev/null | head -20" || echo "ERROR")
if echo "$gnb_status" | grep -q "Process:.*Running"; then
    print_status "Status" "running"
    node_id=$(echo "$gnb_status" | grep "Node ID:" | awk '{print $NF}')
    vpn_ip=$(echo "$gnb_status" | grep "inet " | awk '{print $2}')
    print_kv "Node ID" "$node_id"
    print_kv "VPN IP" "$vpn_ip"
else
    print_status "Status" "stopped"
fi

echo ""
echo -e "${YELLOW}[dnsmasq]${NC}"
dns_proc=$(ssh_exec "ps | grep -E '/usr/sbin/dnsmasq' | grep -v grep | head -1" || echo "")
if [ -n "$dns_proc" ]; then
    print_status "Status" "running"
    dns_pid=$(echo "$dns_proc" | awk '{print $1}')
    print_kv "PID" "$dns_pid"
else
    print_status "Status" "stopped"
fi

# ─────────────────────────────────────────────────────────────
# 2. Proxy Configuration
# ─────────────────────────────────────────────────────────────
print_header "2. PROXY CONFIGURATION (proxy_role.conf)"

proxy_conf=$(ssh_exec "cat /etc/mynet/conf/proxy/proxy_role.conf 2>/dev/null" || echo "ERROR")

if [ "$proxy_conf" = "ERROR" ]; then
    echo -e "  ${RED}proxy_role.conf not found${NC}"
else
    # Parse config values
    proxy_enabled=$(echo "$proxy_conf" | grep "^PROXY_ENABLED=" | cut -d'"' -f2)
    proxy_mode=$(echo "$proxy_conf" | grep "^PROXY_MODE=" | cut -d'"' -f2)
    node_region=$(echo "$proxy_conf" | grep "^NODE_REGION=" | cut -d'"' -f2)
    dns_mode=$(echo "$proxy_conf" | grep "^DNS_MODE=" | cut -d'"' -f2)
    dns_server=$(echo "$proxy_conf" | grep "^DNS_SERVER=" | cut -d'"' -f2)
    dns_domestic=$(echo "$proxy_conf" | grep "^DNS_DOMESTIC_SERVER=" | cut -d'"' -f2)
    proxy_peers=$(echo "$proxy_conf" | grep "^PROXY_PEERS=" | cut -d'"' -f2)

    # Enabled status
    if [ "$proxy_enabled" = "1" ]; then
        print_status "Proxy Enabled" "enabled"
    else
        print_status "Proxy Enabled" "disabled"
    fi

    # Mode
    case "$proxy_mode" in
        client) print_kv "Proxy Mode" "CLIENT (traffic routed via proxy peer)" ;;
        server) print_kv "Proxy Mode" "SERVER (accept proxied traffic)" ;;
        both)   print_kv "Proxy Mode" "BOTH (client + server)" ;;
        *)      print_kv "Proxy Mode" "$proxy_mode (unknown)" ;;
    esac

    # Region / Traffic Policy
    case "$node_region" in
        domestic)
            print_kv "Node Region" "DOMESTIC"
            print_kv "Traffic Policy" "International traffic → proxy, Domestic traffic → direct"
            ;;
        international)
            print_kv "Node Region" "INTERNATIONAL"
            print_kv "Traffic Policy" "Domestic traffic → proxy, International traffic → direct"
            ;;
        non_domestic)
            print_kv "Node Region" "NON_DOMESTIC"
            print_kv "Traffic Policy" "All non-domestic traffic → proxy (inverted match)"
            ;;
        *)
            print_kv "Node Region" "$node_region (unknown)"
            ;;
    esac

    # DNS Mode
    case "$dns_mode" in
        none)
            print_kv "DNS Mode" "NONE (no DNS interception)"
            ;;
        redirect)
            print_kv "DNS Mode" "REDIRECT (all DNS → foreign server via proxy)"
            ;;
        resolv)
            print_kv "DNS Mode" "RESOLV (use custom resolv.conf)"
            ;;
        split)
            print_kv "DNS Mode" "SPLIT (domestic domains → domestic DNS, others → foreign DNS)"
            ;;
        *)
            print_kv "DNS Mode" "$dns_mode (unknown)"
            ;;
    esac

    # DNS Servers
    if [ -n "$dns_server" ]; then
        print_kv "Foreign DNS" "$dns_server"
    fi
    if [ -n "$dns_domestic" ]; then
        print_kv "Domestic DNS" "$dns_domestic"
    fi

    # Peers
    if [ -n "$proxy_peers" ]; then
        peer_count=$(echo "$proxy_peers" | tr ',' '\n' | wc -l | tr -d ' ')
        print_kv "Proxy Peers" "$proxy_peers ($peer_count peer(s))"
    else
        print_kv "Proxy Peers" "(none)"
    fi
fi

# ─────────────────────────────────────────────────────────────
# 3. Runtime State
# ─────────────────────────────────────────────────────────────
print_header "3. RUNTIME STATE"

# Check nftables set
nft_count=$(ssh_exec "nft list set inet mynet_proxy mynet_proxy 2>/dev/null | grep -c 'element' || echo 0")
print_kv "nft set elements" "$nft_count"

# Check route table
route_table=$(ssh_exec "grep mynet_proxy /etc/iproute2/rt_tables 2>/dev/null | awk '{print \$1}'" || echo "")
if [ -n "$route_table" ]; then
    print_kv "Route Table ID" "$route_table"
else
    print_kv "Route Table ID" "(not configured)"
fi

# Check ip rule
ip_rule=$(ssh_exec "ip rule list 2>/dev/null | grep mynet_proxy" || echo "")
if [ -n "$ip_rule" ]; then
    print_status "ip rule" "active"
    print_kv "Rule" "$ip_rule"
else
    print_status "ip rule" "inactive"
fi

# Check proxy state file
state_file=$(ssh_exec "cat /etc/mynet/var/proxy_state.json 2>/dev/null" || echo "")
if [ -n "$state_file" ]; then
    start_ts=$(echo "$state_file" | grep -o '"start_ts":[0-9]*' | cut -d: -f2)
    if [ -n "$start_ts" ]; then
        now=$(date +%s)
        uptime=$((now - start_ts))
        hours=$((uptime / 3600))
        minutes=$(( (uptime % 3600) / 60 ))
        seconds=$((uptime % 60))
        print_kv "Uptime" "${hours}h ${minutes}m ${seconds}s"
    fi
fi

# ─────────────────────────────────────────────────────────────
# 4. DNS Status
# ─────────────────────────────────────────────────────────────
print_header "4. DNS STATUS"

# Check dnsmasq listening
dns_listeners=$(ssh_exec "netstat -tlnp 2>/dev/null | grep ':53 ' | awk '{print \$4, \$7}' | head -5" || echo "")
if [ -n "$dns_listeners" ]; then
    print_status "DNS Listening" "yes"
    echo "$dns_listeners" | while read -r addr proc; do
        print_kv "  Listen" "$addr ($proc)"
    done
else
    # Fallback: check with ss
    dns_listeners_ss=$(ssh_exec "ss -tlnp 2>/dev/null | grep ':53 ' | head -5" || echo "")
    if [ -n "$dns_listeners_ss" ]; then
        print_status "DNS Listening" "yes (via ss)"
    else
        print_status "DNS Listening" "no"
    fi
fi

# Check DNS redirect rules (iptables/nftables)
dns_redirect=$(ssh_exec "iptables -t nat -L PREROUTING 2>/dev/null | grep -E 'REDIRECT.*53|DNAT.*53' | head -3" || echo "")
if [ -n "$dns_redirect" ]; then
    print_status "DNS Redirect (iptables)" "active"
    echo "$dns_redirect" | while read -r rule; do
        print_kv "  Rule" "$rule"
    done
else
    # Check nftables
    dns_redirect_nft=$(ssh_exec "nft list ruleset 2>/dev/null | grep -E 'redirect.*53|dnat.*53' | head -3" || echo "")
    if [ -n "$dns_redirect_nft" ]; then
        print_status "DNS Redirect (nftables)" "active"
    else
        print_status "DNS Redirect" "inactive"
    fi
fi

# Test DNS resolution
echo ""
echo -e "${YELLOW}[DNS Resolution Test]${NC}"
dns_test_domestic=$(ssh_exec "nslookup baidu.com 2>/dev/null | grep -A1 'Name:' | grep 'Address:' | awk '{print \$2}' | head -1" || echo "failed")
dns_test_foreign=$(ssh_exec "nslookup google.com 8.8.8.8 2>/dev/null | grep -A1 'Name:' | grep 'Address:' | awk '{print \$2}' | head -1" || echo "failed")
print_kv "baidu.com (local)" "$dns_test_domestic"
print_kv "google.com (8.8.8.8)" "$dns_test_foreign"

# ─────────────────────────────────────────────────────────────
# 5. Routing & Firewall
# ─────────────────────────────────────────────────────────────
print_header "5. ROUTING & FIREWALL"

# Check GNB tunnel routes
gnb_routes=$(ssh_exec "ip route show dev gnb_tun 2>/dev/null | head -10" || echo "")
if [ -n "$gnb_routes" ]; then
    route_count=$(echo "$gnb_routes" | wc -l | tr -d ' ')
    print_status "GNB Tunnel Routes" "active ($route_count routes)"
else
    print_status "GNB Tunnel Routes" "inactive"
fi

# Check foreign DNS routes
echo ""
echo -e "${YELLOW}[Foreign DNS Routing]${NC}"
for dns in 8.8.8.8 8.8.4.4 1.1.1.1 9.9.9.9; do
    route_via=$(ssh_exec "ip route get $dns 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print \$2}'" || echo "unreachable")
    if [ "$route_via" = "gnb_tun" ]; then
        print_status "  $dns" "via gnb_tun ✓"
    else
        print_status "  $dns" "via $route_via ✗"
    fi
done

# ─────────────────────────────────────────────────────────────
# 6. Processes
# ─────────────────────────────────────────────────────────────
print_header "6. RELATED PROCESSES"

procs=$(ssh_exec "ps | grep -E 'gnb|dnsmasq|proxy' | grep -v grep" || echo "")
if [ -n "$procs" ]; then
    echo "$procs" | while read -r line; do
        echo "  $line"
    done
else
    echo -e "  ${RED}No related processes found${NC}"
fi

# ─────────────────────────────────────────────────────────────
# 7. Quick Connectivity Test
# ─────────────────────────────────────────────────────────────
print_header "7. CONNECTIVITY TEST"

echo -e "${YELLOW}[Domestic IP]${NC}"
domestic_ip=$(ssh_exec "curl -s --connect-timeout 5 --max-time 10 'https://ipinfo.io/ip' 2>/dev/null || curl -s --connect-timeout 5 --max-time 10 'https://ifconfig.me' 2>/dev/null || echo 'failed'")
print_kv "Your IP" "$domestic_ip"

echo ""
echo -e "${YELLOW}[Proxy IP (if routed)]${NC}"
proxy_ip=$(ssh_exec "curl -s --connect-timeout 8 --max-time 15 'https://api.ipify.org' 2>/dev/null || echo 'failed/not routed'")
print_kv "Proxy Exit IP" "$proxy_ip"

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
print_header "SUMMARY"

echo -e "  Proxy:       ${GREEN}$proxy_mode${NC} mode, region=${CYAN}$node_region${NC}"
echo -e "  DNS:         ${CYAN}$dns_mode${NC} mode"
echo -e "  Traffic:     International → proxy, Domestic → direct"
if [ "$proxy_enabled" = "1" ]; then
    echo -e "  Status:      ${GREEN}ENABLED${NC}"
else
    echo -e "  Status:      ${RED}DISABLED${NC}"
fi
echo ""
