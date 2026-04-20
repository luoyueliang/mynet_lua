#!/bin/bash
#
# route_policy.sh — 纯系统命令层：策略路由 / 防火墙规则管理
# 所有业务决策由 proxy.lua 预计算并写入 params 文件
#
# 用法:
#   ./route_policy.sh start|stop|restart
#   ./route_policy.sh server_start|server_stop
#   ./route_policy.sh dns_start <mode> <server>|dns_stop
#

set -e

MYNET_HOME="${MYNET_HOME:-/etc/mynet}"

# ─── 日志 ───
MYNET_LOG_DIR="$MYNET_HOME/logs"
mkdir -p "$MYNET_LOG_DIR" 2>/dev/null || true
MYNET_SCRIPT_LOG="$MYNET_LOG_DIR/route_policy.log"
exec > >(tee -a "$MYNET_SCRIPT_LOG") 2>&1
echo "[$(date '+%Y-%m-%d %H:%M:%S')] route_policy.sh $*"

# ─── 加载运行参数（由 proxy.lua write_policy_params 写入）───
PARAMS_FILE="$MYNET_HOME/var/proxy_policy_params.env"
if [ -f "$PARAMS_FILE" ]; then
    . "$PARAMS_FILE"
else
    case "$1" in
        stop) echo "[INFO] 参数文件不存在，尝试 fallback 清理" ;;
        *)    echo "[ERROR] 参数文件不存在: $PARAMS_FILE"; exit 1 ;;
    esac
fi

# 变量 fallback（stop 时 params 可能不存在）
TABLE_NAME="${TABLE_NAME:-mynet_proxy}"
TABLE_ID="${TABLE_ID:-200}"
FWMARK="${FWMARK:-0xc8}"
RULE_PRIORITY="${RULE_PRIORITY:-31800}"
ROUTE_CONFIG="${ROUTE_CONFIG:-$MYNET_HOME/conf/proxy/proxy_route.conf}"
IPSET_NAME="mynet_proxy"
NFT_SET_NAME="mynet_proxy"
IP_LIST_FILE="$MYNET_HOME/conf/proxy/proxy_outbound.txt"

# ─── 共用函数 ───

ensure_route_table() {
    if ! grep -qE "^[[:space:]]*${TABLE_ID}[[:space:]]+${TABLE_NAME}" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "$TABLE_ID $TABLE_NAME" >> /etc/iproute2/rt_tables
        echo "[INFO] 已注册路由表 $TABLE_NAME ($TABLE_ID)"
    fi
}

add_default_routes() {
    if ip route show table "$TABLE_ID" 2>/dev/null | grep -q '.'; then
        echo "[INFO] 路由表已有路由，跳过"
        return 0
    fi
    IFS=',' read -ra gw_array <<< "$PROXY_GATEWAYS"
    if [ ${#gw_array[@]} -eq 1 ]; then
        ip route add default via "${gw_array[0]}" dev "$GNB_INTERFACE" table "$TABLE_ID" 2>&1 || true
    else
        local nexthops=""
        for gw in "${gw_array[@]}"; do
            gw=$(echo "$gw" | xargs)
            nexthops="$nexthops nexthop via $gw dev $GNB_INTERFACE weight 1"
        done
        eval ip route add default table "$TABLE_ID" $nexthops 2>&1 || true
    fi
    if ip route show table "$TABLE_ID" 2>/dev/null | grep -q 'default'; then
        echo "[INFO] ✓ 路由表已配置 (gw=${PROXY_GATEWAYS}, dev=$GNB_INTERFACE)"
    else
        echo "[ERROR] 路由添加失败"
        return 1
    fi
}

add_ip_rules() {
    if ! ip rule list | grep -q "fwmark $FWMARK"; then
        ip rule add fwmark "$FWMARK" table "$TABLE_ID" prio "$RULE_PRIORITY" 2>/dev/null || true
        echo "[INFO] ✓ fwmark 策略路由已配置"
    fi
}

# ─── start ───

start() {
    echo "[INFO] 启动代理路由 (FW=$FW_TYPE, TABLE=$TABLE_ID, MARK=$FWMARK)"

    if [ -z "$GNB_INTERFACE" ] || ! ip link show "$GNB_INTERFACE" >/dev/null 2>&1; then
        echo "[ERROR] GNB 接口 ${GNB_INTERFACE:-未配置} 不存在"
        return 1
    fi
    [ ! -f "$ROUTE_CONFIG" ] && { echo "[ERROR] 配置文件不存在: $ROUTE_CONFIG"; return 1; }

    ensure_route_table

    case "$FW_TYPE" in
        nftables) start_nftables ;;
        iptables) start_iptables ;;
        *)        echo "[ERROR] 不支持的防火墙类型: $FW_TYPE"; return 1 ;;
    esac

    add_default_routes
    add_ip_rules
    echo "[INFO] ✓ 代理路由已启动"
}

start_iptables() {
    echo "[INFO] iptables + ipset 模式"

    # ipset 创建 + 批量加载
    ipset create $IPSET_NAME hash:net 2>/dev/null || ipset flush $IPSET_NAME
    [ ! -f "$IP_LIST_FILE" ] && { echo "[ERROR] IP 列表不存在: $IP_LIST_FILE"; return 1; }

    local temp="/tmp/ipset_restore_$$"
    {
        echo "create $IPSET_NAME hash:net -exist"
        grep -v '^#' "$IP_LIST_FILE" | grep -v '^$' | sed "s/^/add $IPSET_NAME /"
    } > "$temp"
    if ipset restore -file "$temp" 2>/dev/null; then
        echo "[INFO] ✓ ipset 批量加载完成"
    else
        echo "[WARN] 批量失败，逐条添加"
        grep -v '^#' "$IP_LIST_FILE" | grep -v '^$' | while IFS= read -r ip; do
            ipset add $IPSET_NAME "$ip" 2>/dev/null || true
        done
    fi
    rm -f "$temp"

    # iptables mangle PREROUTING（排除 VPN 接口入方向，避免回包循环）
    iptables -w 5 -t mangle -C PREROUTING ! -i "$GNB_INTERFACE" \
        -m set --match-set $IPSET_NAME dst -j MARK --set-mark "$FWMARK" 2>/dev/null || \
    iptables -w 5 -t mangle -A PREROUTING ! -i "$GNB_INTERFACE" \
        -m set --match-set $IPSET_NAME dst -j MARK --set-mark "$FWMARK"
    echo "[INFO] ✓ iptables mangle 规则已配置"

    # 源地址策略路由（本机流量可选）
    local src_ip
    src_ip=$(ip addr show "$GNB_INTERFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
    if [ -n "$src_ip" ]; then
        ip rule list | grep -q "from $src_ip.*lookup $TABLE_NAME" || \
            ip rule add from "$src_ip" table "$TABLE_ID" prio $((RULE_PRIORITY - 1)) 2>/dev/null || true
    fi
}

start_nftables() {
    echo "[INFO] nftables 模式"

    # 创建 table + set
    nft add table inet mynet_proxy 2>/dev/null || true
    if nft list set inet mynet_proxy $NFT_SET_NAME >/dev/null 2>&1; then
        nft flush set inet mynet_proxy $NFT_SET_NAME 2>/dev/null || true
    else
        nft add set inet mynet_proxy $NFT_SET_NAME \
            '{ type ipv4_addr; flags interval; auto-merge; }' 2>/dev/null || true
    fi

    # 批量加载 IP set
    if nft -f "$ROUTE_CONFIG" 2>/dev/null; then
        local count
        count=$(grep -c "^add element" "$ROUTE_CONFIG" 2>/dev/null || echo 0)
        echo "[INFO] ✓ nft set 已加载 ($count 条)"
    else
        echo "[ERROR] nft 批量加载失败"
        return 1
    fi

    # PREROUTING mangle chain
    nft delete chain inet mynet_proxy mangle_prerouting 2>/dev/null || true
    nft add chain inet mynet_proxy mangle_prerouting \
        '{ type filter hook prerouting priority mangle; }'
    nft add set inet mynet_proxy exclude_ips \
        '{ type ipv4_addr; flags interval; }' 2>/dev/null || true
    nft add rule inet mynet_proxy mangle_prerouting ip daddr @exclude_ips return
    nft add rule inet mynet_proxy mangle_prerouting \
        iifname != "$GNB_INTERFACE" ip protocol != icmp \
        ct state established,related meta mark set ct mark return
    nft add rule inet mynet_proxy mangle_prerouting \
        ip daddr @$NFT_SET_NAME meta mark set "$FWMARK" counter
    nft add rule inet mynet_proxy mangle_prerouting \
        ip daddr @$NFT_SET_NAME ct mark set meta mark
    echo "[INFO] ✓ nft PREROUTING 规则已配置"
}

# ─── server mode ───

start_server_mode() {
    echo "[INFO] 启动 Server 模式..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

    local wan_iface
    wan_iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    [ -z "$wan_iface" ] && { echo "[ERROR] 无法检测 WAN 接口"; return 1; }
    local tun_iface="${GNB_INTERFACE:-}"
    [ -z "$tun_iface" ] && { echo "[ERROR] VPN 接口未配置"; return 1; }
    echo "[INFO] $tun_iface → $wan_iface"

    case "$FW_TYPE" in
        nftables)
            nft add table inet mynet_proxy 2>/dev/null || true
            nft delete chain inet mynet_proxy server_postrouting 2>/dev/null || true
            nft add chain inet mynet_proxy server_postrouting \
                '{ type nat hook postrouting priority srcnat; }'
            nft add rule inet mynet_proxy server_postrouting oifname "$wan_iface" masquerade
            nft delete chain inet mynet_proxy server_forward 2>/dev/null || true
            nft add chain inet mynet_proxy server_forward \
                '{ type filter hook forward priority filter; }'
            nft add rule inet mynet_proxy server_forward \
                iifname "$tun_iface" oifname "$wan_iface" accept
            nft add rule inet mynet_proxy server_forward \
                iifname "$wan_iface" oifname "$tun_iface" ct state established,related accept
            # 白名单（可选）
            local whitelist="$MYNET_HOME/conf/proxy/proxy_whitelist.txt"
            if [ -f "$whitelist" ]; then
                nft add set inet mynet_proxy server_whitelist \
                    '{ type ipv4_addr; }' 2>/dev/null || true
                while IFS= read -r ip; do
                    case "$ip" in '#'*|'') continue ;; esac
                    nft add element inet mynet_proxy server_whitelist "{ $ip }" 2>/dev/null
                done < "$whitelist"
                nft insert rule inet mynet_proxy server_forward \
                    iifname "$tun_iface" ip saddr != @server_whitelist drop
                echo "[INFO] ✓ 白名单已加载"
            fi
            ;;
        iptables)
            iptables -w 5 -t nat -C POSTROUTING -o "$wan_iface" -j MASQUERADE 2>/dev/null || \
                iptables -w 5 -t nat -A POSTROUTING -o "$wan_iface" -j MASQUERADE
            iptables -w 5 -C FORWARD -i "$tun_iface" -o "$wan_iface" -j ACCEPT 2>/dev/null || \
                iptables -w 5 -A FORWARD -i "$tun_iface" -o "$wan_iface" -j ACCEPT
            iptables -w 5 -C FORWARD -i "$wan_iface" -o "$tun_iface" \
                -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                iptables -w 5 -A FORWARD -i "$wan_iface" -o "$tun_iface" \
                -m state --state ESTABLISHED,RELATED -j ACCEPT
            ;;
    esac
    echo "[INFO] ✓ Server 模式已启动"
}

stop_server_mode() {
    echo "[INFO] 停止 Server 模式..."
    case "${FW_TYPE:-}" in
        nftables)
            nft delete chain inet mynet_proxy server_postrouting 2>/dev/null || true
            nft delete chain inet mynet_proxy server_forward 2>/dev/null || true
            nft delete set inet mynet_proxy server_whitelist 2>/dev/null || true
            ;;
        iptables)
            local wan_iface
            wan_iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
            local tun_iface="${GNB_INTERFACE:-}"
            if [ -n "$wan_iface" ] && [ -n "$tun_iface" ]; then
                iptables -w 5 -t nat -D POSTROUTING -o "$wan_iface" -j MASQUERADE 2>/dev/null || true
                iptables -w 5 -D FORWARD -i "$tun_iface" -o "$wan_iface" -j ACCEPT 2>/dev/null || true
                iptables -w 5 -D FORWARD -i "$wan_iface" -o "$tun_iface" \
                    -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
            fi
            ;;
    esac
    echo "[INFO] ✓ Server 模式已停止"
}

# ─── DNS intercept ───

start_dns_intercept() {
    local dns_mode="${1:-none}"
    local dns_server="${2:-}"
    [ "$dns_mode" = "none" ] || [ -z "$dns_mode" ] && return 0
    [ -z "$dns_server" ] && { echo "[ERROR] DNS 需要指定服务器地址"; return 1; }
    echo "[INFO] DNS 劫持: $dns_mode → $dns_server"

    case "$dns_mode" in
        redirect)
            case "$FW_TYPE" in
                nftables)
                    nft add table inet mynet_proxy 2>/dev/null || true
                    nft delete chain inet mynet_proxy dns_intercept 2>/dev/null || true
                    nft add chain inet mynet_proxy dns_intercept \
                        '{ type nat hook prerouting priority dstnat; }'
                    nft add rule inet mynet_proxy dns_intercept \
                        iifname "br-lan" udp dport 53 dnat ip to "$dns_server:53"
                    nft add rule inet mynet_proxy dns_intercept \
                        iifname "br-lan" tcp dport 53 dnat ip to "$dns_server:53"
                    ;;
                iptables)
                    iptables -w 5 -t nat -C PREROUTING -i br-lan -p udp --dport 53 \
                        -j DNAT --to-destination "$dns_server:53" 2>/dev/null || \
                    iptables -w 5 -t nat -A PREROUTING -i br-lan -p udp --dport 53 \
                        -j DNAT --to-destination "$dns_server:53"
                    iptables -w 5 -t nat -C PREROUTING -i br-lan -p tcp --dport 53 \
                        -j DNAT --to-destination "$dns_server:53" 2>/dev/null || \
                    iptables -w 5 -t nat -A PREROUTING -i br-lan -p tcp --dport 53 \
                        -j DNAT --to-destination "$dns_server:53"
                    ;;
            esac
            ;;
        resolv)
            local f="/tmp/resolv.conf.d/resolv.conf.auto"
            [ -f "$f" ] && cp "$f" "${f}.proxy_bak" && echo "nameserver $dns_server" > "$f"
            ;;
    esac
    echo "[INFO] ✓ DNS 劫持已启用"
}

stop_dns_intercept() {
    echo "[INFO] 停止 DNS 劫持..."
    case "${FW_TYPE:-}" in
        nftables) nft delete chain inet mynet_proxy dns_intercept 2>/dev/null || true ;;
        iptables)
            iptables -w 5 -t nat -D PREROUTING -i br-lan -p udp --dport 53 -j DNAT 2>/dev/null || true
            iptables -w 5 -t nat -D PREROUTING -i br-lan -p tcp --dport 53 -j DNAT 2>/dev/null || true
            ;;
    esac
    local bak="/tmp/resolv.conf.d/resolv.conf.auto.proxy_bak"
    [ -f "$bak" ] && mv "$bak" "/tmp/resolv.conf.d/resolv.conf.auto"
    echo "[INFO] ✓ DNS 劫持已停止"
}

# ─── stop ───

stop() {
    echo "[INFO] 停止代理路由..."
    stop_dns_intercept
    stop_server_mode

    case "${FW_TYPE:-}" in
        nftables)
            nft delete table inet mynet_proxy 2>/dev/null || true
            ;;
        iptables)
            iptables-save -t mangle 2>/dev/null | grep -- "--match-set $IPSET_NAME " | \
            while IFS= read -r rule; do
                iptables -w 5 -t mangle ${rule/-A /-D } 2>/dev/null || true
            done
            ipset destroy $IPSET_NAME 2>/dev/null || true
            ;;
        "")
            # FW_TYPE 未知 — fallback 两种都清理
            nft delete table inet mynet_proxy 2>/dev/null || true
            iptables-save -t mangle 2>/dev/null | grep -- "--match-set mynet_proxy " | \
            while IFS= read -r rule; do
                iptables -w 5 -t mangle ${rule/-A /-D } 2>/dev/null || true
            done
            ipset destroy mynet_proxy 2>/dev/null || true
            ;;
    esac

    # 清理所有 mynet_proxy 策略路由规则
    while ip rule list 2>/dev/null | grep -q "lookup $TABLE_NAME"; do
        local line
        line=$(ip rule list | grep "lookup $TABLE_NAME" | head -1)
        if [[ "$line" =~ fwmark[[:space:]]+([x0-9a-f]+) ]]; then
            ip rule del fwmark "${BASH_REMATCH[1]}" 2>/dev/null || break
        elif [[ "$line" =~ from[[:space:]]+([0-9.]+) ]]; then
            ip rule del from "${BASH_REMATCH[1]}" table "$TABLE_ID" 2>/dev/null || break
        else
            break
        fi
    done

    # 清理路由表
    if [ -f /etc/iproute2/rt_tables ]; then
        grep -E "^[[:space:]]*[0-9]+[[:space:]]+$TABLE_NAME" /etc/iproute2/rt_tables 2>/dev/null | \
        awk '{print $1}' | while read -r id; do
            ip route flush table "$id" 2>/dev/null || true
        done
    fi

    echo "[INFO] ✓ 代理路由已停止"
}

# ─── 主入口 ───
case "${1:-}" in
    start)         start ;;
    stop)          stop ;;
    restart)       stop; sleep 1; start ;;
    server_start)  start_server_mode ;;
    server_stop)   stop_server_mode ;;
    dns_start)     start_dns_intercept "$2" "$3" ;;
    dns_stop)      stop_dns_intercept ;;
    *)
        echo "用法: $0 {start|stop|restart|server_start|server_stop|dns_start|dns_stop}"
        exit 1
        ;;
esac
