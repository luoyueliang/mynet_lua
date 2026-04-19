#!/bin/bash
#
# 代理路由脚本 - Linux/OpenWrt 统一版本
# mynet_proxy 插件
#
# 功能：读取 conf/proxy/proxy_route.conf 创建系统代理路由
# 格式：network/prefix via gateway[,gateway2,...]
#
# 支持:
#   - iptables + ipset (fw3 / 传统 Linux)
#   - nftables (fw4 / 现代 Linux)
#
# 用法:
#   ./route_policy.sh start   # 启动代理路由
#   ./route_policy.sh stop    # 停止代理路由
#   ./route_policy.sh restart # 重启代理路由
#   ./route_policy.sh status  # 查看状态
#   ./route_policy.sh refresh # 刷新IP列表并重新应用 (v0.9.9+)
#   ./route_policy.sh setup   # 重新配置代理节点 (v0.9.9+)
#

set -e

# 检测 MYNET_HOME
# 优先使用调用方传入的环境变量（proxy.sh 会设置 MYNET_HOME=...）
# 否则从脚本路径推导：scripts/proxy/openwrt/route_policy.sh → 上溯 3 级
if [ -z "${MYNET_HOME:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    MYNET_HOME="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

# ─── 日志捕获 ───
MYNET_LOG_DIR="$MYNET_HOME/logs"
mkdir -p "$MYNET_LOG_DIR" 2>/dev/null || true
MYNET_SCRIPT_LOG="$MYNET_LOG_DIR/route_policy.log"
exec > >(tee -a "$MYNET_SCRIPT_LOG") 2>&1
echo "[$(date '+%Y-%m-%d %H:%M:%S')] route_policy.sh $*"

# 验证 MYNET_HOME
if [ ! -f "$MYNET_HOME/conf/mynet.conf" ]; then
    echo "[ERROR] 无法找到 mynet.conf: $MYNET_HOME/conf/mynet.conf"
    echo "[INFO] 请确保脚本在正确的位置: \$MYNET_HOME/scripts/proxy.sh"
    exit 1
fi

ROUTE_CONFIG="$MYNET_HOME/conf/proxy/proxy_route.conf"
IPSET_NAME="mynet_proxy"
NFT_SET_NAME="mynet_proxy"
TABLE_NAME="mynet_proxy"

# 智能分配路由表ID（避免冲突）
find_available_table_id() {
    local base_id=200
    local step=10
    local max_id=250

    # 优先查找已注册的 mynet_proxy 表
    if [ -f /etc/iproute2/rt_tables ]; then
        local existing_id=$(grep -E "^[[:space:]]*[0-9]+[[:space:]]+$TABLE_NAME" /etc/iproute2/rt_tables | awk '{print $1}' | head -1)
        if [ -n "$existing_id" ]; then
            echo "$existing_id"
            return 0
        fi
    fi

    for ((id=base_id; id<=max_id; id+=step)); do
        # 检查 rt_tables 是否已使用（且不是 mynet_proxy 的旧条目）
        if [ -f /etc/iproute2/rt_tables ]; then
            if ! grep -qE "^[[:space:]]*$id[[:space:]]+[^[:space:]]" /etc/iproute2/rt_tables; then
                # 检查实际路由表是否为空
                if ! ip route show table $id 2>/dev/null | grep -q '.'; then
                    echo "$id"
                    return 0
                fi
            fi
        else
            echo "$id"
            return 0
        fi
    done

    # 降级：使用 200（覆盖模式）
    echo "200"
}

TABLE_ID=$(find_available_table_id)
# FWMARK 与 TABLE_ID 保持一致（十六进制）
FWMARK="0x$(printf '%x' $TABLE_ID)"
# 策略路由优先级（避免与系统默认规则冲突）
RULE_PRIORITY="31800"

# 检测防火墙类型
detect_firewall() {
    # 优先检测 nftables (fw4)
    if command -v nft >/dev/null 2>&1 && nft list tables 2>/dev/null | grep -q .; then
        echo "nftables"
    # 检测 iptables + ipset (fw3)
    elif command -v iptables >/dev/null 2>&1 && command -v ipset >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "unknown"
    fi
}

FW_TYPE=$(detect_firewall)

# 检查配置文件
check_config() {
    if [ ! -f "$ROUTE_CONFIG" ]; then
        echo "[ERROR] 配置文件不存在: $ROUTE_CONFIG"
        echo "[INFO] 请先运行: mynet_proxy apply"
        exit 1
    fi
}

# 启动代理路由
start() {
    echo "[INFO] 启动代理路由..."
    echo "[INFO] MYNET_HOME: $MYNET_HOME"
    echo "[INFO] 防火墙类型: $FW_TYPE"
    echo "[INFO] 路由表: $TABLE_NAME (ID: $TABLE_ID, MARK: $FWMARK)"

    # 从 mynet.conf 读取正确的接口名
    GNB_INTERFACE=""
    if [ -f "$MYNET_HOME/conf/mynet.conf" ]; then
        GNB_INTERFACE=$(grep "^VPN_INTERFACE=" "$MYNET_HOME/conf/mynet.conf" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi

    # 如果配置文件中没有，尝试动态检测（但优先使用配置）
    if [ -z "$GNB_INTERFACE" ]; then
        GNB_INTERFACE=$(ip link show | grep -o 'gnb_tun[^:]*' | head -1)
    fi

    if [ -n "$GNB_INTERFACE" ]; then
        echo "[INFO] GNB接口: $GNB_INTERFACE (来自配置文件)"
        # 验证接口是否真实存在
        if ! ip link show "$GNB_INTERFACE" >/dev/null 2>&1; then
            echo "[ERROR] 接口 $GNB_INTERFACE 不存在，请确保 GNB 服务已启动"
            return 1
        fi
    else
        echo "[ERROR] 无法确定GNB接口名，请确保 GNB 服务已启动"
        return 1
    fi

    check_config

    case "$FW_TYPE" in
        nftables)
            start_nftables
            ;;
        iptables)
            start_iptables
            ;;
        *)
            echo "[ERROR] 不支持的防火墙类型"
            exit 1
            ;;
    esac

    echo "[INFO] ✓ 代理路由已启动"
}

# iptables + ipset 模式 (fw3 / 传统 Linux)
start_iptables() {
    echo "[INFO] 使用 iptables + ipset 模式"

    # 创建 ipset
    ipset create $IPSET_NAME hash:net 2>/dev/null || ipset flush $IPSET_NAME

    # 从 proxy_route.conf 读取网关列表（从注释行提取）
    local first_gateways=""
    if [ -f "$ROUTE_CONFIG" ]; then
        first_gateways=$(grep "^# Gateway:" "$ROUTE_CONFIG" | head -1 | sed 's/^# Gateway: //')
    fi

    if [ -z "$first_gateways" ]; then
        echo "[ERROR] 无法从 $ROUTE_CONFIG 读取网关列表"
        return 1
    fi

    echo "[INFO] 网关列表: $first_gateways"

    # 查找 IP 列表文件
    local ip_list_file=""
    for possible_file in \
        "$MYNET_HOME/conf/proxy/proxy_outbound.txt" \
        "$MYNET_HOME/conf/proxy/proxy_inbound.txt" \
        "$MYNET_HOME/conf/proxy/proxy_whitelist.txt"; do
        if [ -f "$possible_file" ]; then
            ip_list_file="$possible_file"
            break
        fi
    done

    if [ -z "$ip_list_file" ]; then
        echo "[ERROR] 未找到 IP 列表文件"
        return 1
    fi

    echo "[INFO] 使用 IP 列表: $(basename "$ip_list_file")"

    # 使用 ipset restore 批量添加（比逐条添加快 10 倍以上）
    local count=0
    local temp_restore="/tmp/ipset_restore_$$"

    # 生成 ipset restore 格式的文件
    echo "create $IPSET_NAME hash:net -exist" > "$temp_restore"
    while read -r ip; do
        [[ "$ip" =~ ^# ]] && continue
        [[ -z "$ip" ]] && continue

        echo "add $IPSET_NAME $ip" >> "$temp_restore"
        count=$((count+1))
    done < "$ip_list_file"

    # 批量加载
    local restore_error=$(ipset restore -file "$temp_restore" 2>&1)
    local restore_status=$?

    if [ $restore_status -eq 0 ]; then
        echo "[INFO] ✓ ipset 规则已批量加载: $count 条"
    else
        echo "[WARN] 批量加载失败，回退到逐条添加"
        echo "[DEBUG] 失败原因: $restore_error"
        echo "[DEBUG] 临时文件: $temp_restore (前5行)"
        head -5 "$temp_restore" 2>/dev/null

        # 回退到原来的方法
        count=0
        while read -r ip; do
            [[ "$ip" =~ ^# ]] && continue
            [[ -z "$ip" ]] && continue

            if ipset add $IPSET_NAME "$ip" 2>/dev/null; then
                count=$((count+1))
            fi
        done < "$ip_list_file"
        echo "[INFO] ✓ ipset 规则已添加: $count 条"
    fi

    # 清理临时文件
    rm -f "$temp_restore"

    # 确保路由表存在（安全检查）
    if ! grep -qE "^[[:space:]]*$TABLE_ID[[:space:]]+$TABLE_NAME" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "$TABLE_ID $TABLE_NAME" >> /etc/iproute2/rt_tables
        echo "[INFO] ✓ 已注册路由表 $TABLE_NAME ($TABLE_ID)"
    fi

    # 检查路由表是否已有路由（避免重复添加）
    if ip route show table $TABLE_ID 2>/dev/null | grep -q '.'; then
        echo "[WARN] 路由表 $TABLE_NAME 已有路由，跳过添加"
    else
        # 分割网关列表
        IFS=',' read -ra gw_array <<< "$first_gateways"
        local gw_count=${#gw_array[@]}

        if [ $gw_count -eq 1 ]; then
            # 单网关：智能检测网关所在的接口 (BusyBox 兼容)
            local gw="${gw_array[0]}"
            local gw_dev=""

            # 方法1: 使用 ip route get 查询到达网关的路由
            gw_dev=$(ip route get "$gw" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)

            # 方法2: 如果方法1失败，从路由表中查找网关所在网段的接口
            if [ -z "$gw_dev" ]; then
                local gw_prefix=$(echo "$gw" | cut -d. -f1-3)
                gw_dev=$(ip route show | grep -E "^${gw_prefix}\.[0-9]+/[0-9]+ dev " | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
            fi

            # 方法3: 精确匹配 scope link (直连网络)
            if [ -z "$gw_dev" ]; then
                local gw_prefix=$(echo "$gw" | cut -d. -f1-3)
                gw_dev=$(ip route show | grep "scope link" | grep -E "^${gw_prefix}\." | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
            fi

            if [ -n "$gw_dev" ]; then
                echo "[DEBUG] 检测到网关接口: $gw_dev (通过路由表查询)"
                echo "[DEBUG] 执行命令: ip route add default via $gw dev $gw_dev table $TABLE_ID"
                local route_error=$(ip route add default via "$gw" dev "$gw_dev" table $TABLE_ID 2>&1)
            else
                echo "[WARN] 未检测到网关接口，尝试 onlink 模式（可能失败）"
                echo "[DEBUG] 执行命令: ip route add default via $gw onlink table $TABLE_ID"
                local route_error=$(ip route add default via "$gw" onlink table $TABLE_ID 2>&1)
            fi

            local route_status=$?

            echo "[DEBUG] 命令退出码: $route_status"
            if [ -n "$route_error" ]; then
                echo "[DEBUG] 命令输出: $route_error"
            fi

            # 验证路由是否添加成功
            if ip route show table $TABLE_ID 2>/dev/null | grep -q 'default'; then
                if [ -n "$gw_dev" ]; then
                    echo "[INFO] ✓ 路由表已配置（单网关: $gw via $gw_dev）"
                else
                    echo "[INFO] ✓ 路由表已配置（单网关: $gw, onlink模式）"
                fi
            else
                echo "[ERROR] 路由添加失败：路由表中未找到 default 路由"
                echo "[ERROR] 退出码: $route_status"
                echo "[ERROR] 错误信息: ${route_error:-无}"
                echo "[INFO] 当前路由表内容 (table $TABLE_ID):"
                ip route show table $TABLE_ID 2>&1 || echo "  (空)"
                echo "[INFO] 诊断信息:"
                echo "  - 网关地址: $gw"
                echo "  - 检测到的接口: ${gw_dev:-无}"
                echo "  - 路由表ID: $TABLE_ID"
                echo "[INFO] 相关路由规则:"
                ip route show | grep -E "$(echo "$gw" | cut -d. -f1-3)\." || echo "  (无匹配)"
            fi
        else
            # 多网关 ECMP 负载均衡：检测每个网关的接口 (BusyBox 兼容)
            local nexthops=""
            local has_dev=false

            for gw in "${gw_array[@]}"; do
                gw=$(echo "$gw" | xargs)  # 去除空格
                local gw_dev=$(ip route get "$gw" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)

                if [ -n "$gw_dev" ]; then
                    nexthops="$nexthops nexthop via $gw dev $gw_dev weight 1"
                    has_dev=true
                else
                    nexthops="$nexthops nexthop via $gw onlink weight 1"
                fi
            done

            echo "[DEBUG] 执行命令: ip route add default table $TABLE_ID $nexthops"

            local route_error=$(ip route add default table $TABLE_ID $nexthops 2>&1)
            local route_status=$?

            echo "[DEBUG] 命令退出码: $route_status"
            if [ -n "$route_error" ]; then
                echo "[DEBUG] 命令输出: $route_error"
            fi

            # 验证路由是否添加成功
            if ip route show table $TABLE_ID 2>/dev/null | grep -q 'default'; then
                if [ "$has_dev" = true ]; then
                    echo "[INFO] ✓ 路由表已配置（多网关负载均衡: ${first_gateways}, ${gw_count}个网关, 自动检测接口）"
                else
                    echo "[INFO] ✓ 路由表已配置（多网关负载均衡: ${first_gateways}, ${gw_count}个网关, onlink模式）"
                fi
            else
                echo "[ERROR] 路由添加失败：路由表中未找到 default 路由"
                echo "[ERROR] 退出码: $route_status"
                echo "[ERROR] 错误信息: ${route_error:-无}"
                echo "[INFO] 当前路由表内容 (table $TABLE_ID):"
                ip route show table $TABLE_ID 2>&1 || echo "  (空)"
            fi
        fi
    fi

    # 等待 xtables 锁释放（避免并发冲突）
    if [ -e /run/xtables.lock ]; then
        echo "[INFO] 等待 xtables.lock 释放..."
        local wait_count=0
        while [ -e /run/xtables.lock ] && [ $wait_count -lt 10 ]; do
            sleep 0.5
            wait_count=$((wait_count+1))
        done
    fi

    # 防火墙规则（使用 -w 等待锁，FWMARK 与 TABLE_ID 一致）
    # 使用全局变量GNB_INTERFACE（在start()函数中已检测）

    # PREROUTING: 处理转发流量，但排除从VPN接口进来的包（避免代理回包循环）
    iptables -w 5 -t mangle -C PREROUTING ! -i "$GNB_INTERFACE" -m set --match-set $IPSET_NAME dst -j MARK --set-mark $FWMARK 2>/dev/null || \
        iptables -w 5 -t mangle -A PREROUTING ! -i "$GNB_INTERFACE" -m set --match-set $IPSET_NAME dst -j MARK --set-mark $FWMARK

    echo "[INFO] ✓ iptables 规则已配置（PREROUTING 转发流量，排除 $GNB_INTERFACE）"

    echo "[INFO] ℹ️  注意：暂不支持路由器本机代理（OUTPUT链会导致 GNB 循环）"

    # 配置策略路由
    # 1. fwmark策略：处理PREROUTING标记的包（来自局域网和GNB隧道的转发流量）
    if ! ip rule list | grep -q "fwmark $FWMARK"; then
        ip rule add fwmark $FWMARK table $TABLE_ID prio $RULE_PRIORITY 2>/dev/null || true
        echo "[INFO] ✓ 策略路由已配置（fwmark for PREROUTING）"
    else
        echo "[INFO] ✓ fwmark策略路由已存在"
    fi

    # 2. 源地址策略：处理本地OUTPUT的包（路由器本机发出的流量）
    # 由于nftables的OUTPUT链mark无法触发路由重查询，改用源地址匹配
    # 使用全局变量GNB_INTERFACE（在start()函数中已检测）
    local src_ip=$(ip addr show "$GNB_INTERFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
    if [ -n "$src_ip" ]; then
        if ! ip rule list | grep -q "from $src_ip.*lookup $TABLE_NAME"; then
            ip rule add from $src_ip table $TABLE_ID prio $((RULE_PRIORITY - 1)) 2>/dev/null || true
            echo "[INFO] ✓ 策略路由已配置（from $src_ip for OUTPUT）"
        else
            echo "[INFO] ✓ 源地址策略路由已存在"
        fi
    fi
}

# nftables 模式 (fw4 / 现代 Linux)
start_nftables() {
    echo "[INFO] 使用 nftables 模式"

    local index_exclude_ips=""  # 保留变量声明，避免后续代码报错

    # 检查配置文件
    if [ ! -f "$ROUTE_CONFIG" ]; then
        echo "[ERROR] 配置文件不存在: $ROUTE_CONFIG"
        return 1
    fi

    # 从 proxy_route.conf 读取网关列表（从注释行提取）
    local first_gateways=""
    first_gateways=$(grep "^# Gateway:" "$ROUTE_CONFIG" | head -1 | sed 's/^# Gateway: //')

    if [ -z "$first_gateways" ]; then
        echo "[ERROR] 无法从 $ROUTE_CONFIG 读取网关列表"
        return 1
    fi

    echo "[INFO] 网关列表: $first_gateways"

    # 统计规则数量（排除注释和空行）
    local count=$(grep -v "^#" "$ROUTE_CONFIG" | grep -v "^$" | grep "^add element" | wc -l)
    echo "[INFO] 准备加载 $count 条 IP 规则..."

    # 创建 table 和 set（如果不存在）
    nft add table inet mynet_proxy 2>/dev/null || true

    # 检查set是否存在，如果存在则flush，否则创建
    if nft list set inet mynet_proxy $NFT_SET_NAME >/dev/null 2>&1; then
        echo "[INFO] 清空现有 nft set..."
        nft flush set inet mynet_proxy $NFT_SET_NAME 2>/dev/null || true
    else
        echo "[INFO] 创建 nft set..."
        nft add set inet mynet_proxy $NFT_SET_NAME { type ipv4_addr\; flags interval\; auto-merge\; } 2>/dev/null || true
    fi

    # 直接用 nft -f 批量加载 proxy_route.conf
    echo "[INFO] 使用 nft -f 批量加载配置文件..."
    if nft -f "$ROUTE_CONFIG" 2>/dev/null; then
        echo "[INFO] ✓ nft set 规则已添加: $count 条"
    else
        echo "[ERROR] nft 批量加载失败"
        return 1
    fi

    # 确保路由表存在
    if ! grep -qE "^[[:space:]]*$TABLE_ID[[:space:]]+$TABLE_NAME" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "$TABLE_ID $TABLE_NAME" >> /etc/iproute2/rt_tables
        echo "[INFO] ✓ 已注册路由表 $TABLE_NAME ($TABLE_ID)"
    fi

    # 配置默认路由（多网关支持）
    if ! ip route show table $TABLE_ID 2>/dev/null | grep -q '.'; then
        IFS=',' read -ra gw_array <<< "$first_gateways"
        local gw_count=${#gw_array[@]}

        if [ $gw_count -eq 1 ]; then
            # 单网关：智能检测网关所在的接口 (BusyBox 兼容)
            local gw="${gw_array[0]}"
            local gw_dev=""

            # 方法1: 使用 ip route get 查询到达网关的路由
            gw_dev=$(ip route get "$gw" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)

            # 方法2: 如果方法1失败，从路由表中查找网关所在网段的接口
            if [ -z "$gw_dev" ]; then
                local gw_prefix=$(echo "$gw" | cut -d. -f1-3)
                gw_dev=$(ip route show | grep -E "^${gw_prefix}\.[0-9]+/[0-9]+ dev " | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
            fi

            # 方法3: 精确匹配 scope link (直连网络)
            if [ -z "$gw_dev" ]; then
                local gw_prefix=$(echo "$gw" | cut -d. -f1-3)
                gw_dev=$(ip route show | grep "scope link" | grep -E "^${gw_prefix}\." | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
            fi

            if [ -n "$gw_dev" ]; then
                echo "[DEBUG] 检测到网关接口: $gw_dev (通过路由表查询)"
                echo "[DEBUG] 执行命令: ip route add default via $gw dev $gw_dev table $TABLE_ID"
                local route_error=$(ip route add default via "$gw" dev "$gw_dev" table $TABLE_ID 2>&1)
            else
                echo "[WARN] 未检测到网关接口，尝试 onlink 模式（可能失败）"
                echo "[DEBUG] 执行命令: ip route add default via $gw onlink table $TABLE_ID"
                local route_error=$(ip route add default via "$gw" onlink table $TABLE_ID 2>&1)
            fi

            local route_status=$?

            echo "[DEBUG] 命令退出码: $route_status"
            if [ -n "$route_error" ]; then
                echo "[DEBUG] 命令输出: $route_error"
            fi

            # 验证路由是否添加成功
            if ip route show table $TABLE_ID 2>/dev/null | grep -q 'default'; then
                if [ -n "$gw_dev" ]; then
                    echo "[INFO] ✓ 路由表已配置（单网关: $gw via $gw_dev）"
                else
                    echo "[INFO] ✓ 路由表已配置（单网关: $gw, onlink模式）"
                fi
            else
                echo "[ERROR] 路由添加失败：路由表中未找到 default 路由"
                echo "[ERROR] 退出码: $route_status"
                echo "[ERROR] 错误信息: ${route_error:-无}"
                echo "[INFO] 当前路由表内容 (table $TABLE_ID):"
                ip route show table $TABLE_ID 2>&1 || echo "  (空)"
                echo "[INFO] 诊断信息:"
                echo "  - 网关地址: $gw"
                echo "  - 检测到的接口: ${gw_dev:-无}"
                echo "  - 路由表ID: $TABLE_ID"
                echo "[INFO] 相关路由规则:"
                ip route show | grep -E "$(echo "$gw" | cut -d. -f1-3)\." || echo "  (无匹配)"
            fi
        else
            # 多网关 ECMP 负载均衡：检测每个网关的接口 (BusyBox 兼容)
            local nexthops=""
            local has_dev=false

            for gw in "${gw_array[@]}"; do
                gw=$(echo "$gw" | xargs)  # 去除空格
                local gw_dev=$(ip route get "$gw" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)

                if [ -n "$gw_dev" ]; then
                    nexthops="$nexthops nexthop via $gw dev $gw_dev weight 1"
                    has_dev=true
                else
                    nexthops="$nexthops nexthop via $gw onlink weight 1"
                fi
            done

            echo "[DEBUG] 执行命令: ip route add default table $TABLE_ID $nexthops"

            local route_error=$(ip route add default table $TABLE_ID $nexthops 2>&1)
            local route_status=$?

            echo "[DEBUG] 命令退出码: $route_status"
            if [ -n "$route_error" ]; then
                echo "[DEBUG] 命令输出: $route_error"
            fi

            # 验证路由是否添加成功
            if ip route show table $TABLE_ID 2>/dev/null | grep -q 'default'; then
                if [ "$has_dev" = true ]; then
                    echo "[INFO] ✓ 路由表已配置（多网关负载均衡: ${first_gateways}, ${gw_count}个网关, 自动检测接口）"
                else
                    echo "[INFO] ✓ 路由表已配置（多网关负载均衡: ${first_gateways}, ${gw_count}个网关, onlink模式）"
                fi
            else
                echo "[ERROR] 路由添加失败：路由表中未找到 default 路由"
                echo "[ERROR] 退出码: $route_status"
                echo "[ERROR] 错误信息: ${route_error:-无}"
                echo "[INFO] 当前路由表内容 (table $TABLE_ID):"
                ip route show table $TABLE_ID 2>&1 || echo "  (空)"
            fi
        fi
    fi

    # 配置 nft 规则（标记数据包）
    echo "[DEBUG] 配置 nft 规则: NFT_SET_NAME=$NFT_SET_NAME, FWMARK=$FWMARK"
    echo "[DEBUG] 网关列表: $first_gateways"

    # 提取所有网关IP用于排除（避免循环路由）
    IFS=',' read -ra gw_array <<< "$first_gateways"
    local gateway_exclusions=""
    for gw in "${gw_array[@]}"; do
        gw=$(echo "$gw" | xargs)
        if [ -n "$gateway_exclusions" ]; then
            gateway_exclusions="$gateway_exclusions, $gw"
        else
            gateway_exclusions="$gw"
        fi
    done
    echo "[DEBUG] 排除网关IP: $gateway_exclusions"

    # PREROUTING: 处理经过路由器转发的流量（来自局域网设备和 GNB 隧道）
    # 使用 priority mangle 在路由决策前标记数据包
    # 对于established/related连接，从ct恢复mark（但排除从VPN回来的包，避免循环路由）；对于新连接，设置mark并保存到ct
    nft delete chain inet mynet_proxy mangle_prerouting 2>/dev/null || true
    echo "[DEBUG] 创建 PREROUTING 链..."
    nft add chain inet mynet_proxy mangle_prerouting { type filter hook prerouting priority mangle\; } || echo "[ERROR] 创建 PREROUTING 链失败"

    # 创建排除IP的nft set（用于高效匹配）
    echo "[DEBUG] 创建排除IP set..."
    nft add set inet mynet_proxy exclude_ips { type ipv4_addr\; flags interval\; } 2>/dev/null || echo "[WARN] 排除IP set已存在"

    # 添加索引服务器IP到排除set
    if [ -n "$index_exclude_ips" ]; then
        IFS=',' read -ra ip_array <<< "$index_exclude_ips"
        for ip in "${ip_array[@]}"; do
            ip=$(echo "$ip" | xargs)
            nft add element inet mynet_proxy exclude_ips { "$ip" } 2>/dev/null
        done
        echo "[DEBUG] 已添加 ${#ip_array[@]} 个索引服务器IP到排除set"
    fi

    # 使用全局变量GNB_INTERFACE（在start()函数中已检测）
    echo "[DEBUG] 添加 PREROUTING 规则: restore ct mark + set new mark (exclude $GNB_INTERFACE input)"
    # 排除规则：索引服务器和peer节点IP不代理
    nft add rule inet mynet_proxy mangle_prerouting ip daddr @exclude_ips return || echo "[ERROR] 添加排除规则失败"
    # 只对非VPN接口的established连接恢复mark，避免VPN回包被重新路由到VPN（循环）
    # 排除ICMP协议（ip protocol != icmp），避免ping延迟奇偶交替问题
    nft add rule inet mynet_proxy mangle_prerouting iifname != "$GNB_INTERFACE" ip protocol != icmp ct state established,related meta mark set ct mark return || echo "[ERROR] 添加ct restore规则失败"
    nft add rule inet mynet_proxy mangle_prerouting ip daddr @$NFT_SET_NAME meta mark set $FWMARK counter || echo "[ERROR] 添加mark规则失败"
    nft add rule inet mynet_proxy mangle_prerouting ip daddr @$NFT_SET_NAME ct mark set meta mark || echo "[ERROR] 添加ct save规则失败"

    echo "[INFO] ✓ nft 规则已配置（PREROUTING 转发流量）"
    echo "[INFO] ℹ️  注意：暂不支持路由器本机代理（OUTPUT链会导致 GNB 循环）"

    # 配置单层策略路由规则（只处理转发流量）
    if ! ip rule list | grep -q "fwmark $FWMARK.*lookup $TABLE_NAME"; then
        ip rule add fwmark $FWMARK table $TABLE_ID prio $RULE_PRIORITY 2>/dev/null || true
        echo "[INFO] ✓ 转发流量策略路由已配置（fwmark $FWMARK → $TABLE_NAME）"
    else
        echo "[INFO] ✓ 转发流量策略路由已存在"
    fi

    echo "[INFO] ✓ 策略路由已启用（仅转发流量）"
    echo "[INFO]    - PREROUTING: 转发流量标记 $FWMARK → $TABLE_NAME"
    echo "[INFO]    - 本机流量: 走默认路由（不代理）"
}

# ─────────────────────────────────────────────────────────
# Server 模式支持（Phase 8.1）
# OpenWrt 作为 proxy server — 出口节点 NAT + FORWARD
# ─────────────────────────────────────────────────────────

start_server_mode() {
    echo "[INFO] 启动 Server 模式..."

    # 1. 启用 ip_forward
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

    # 检测 WAN 接口
    local wan_iface=""
    wan_iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    if [ -z "$wan_iface" ]; then
        echo "[ERROR] 无法检测 WAN 接口"
        return 1
    fi
    echo "[INFO] WAN 接口: $wan_iface"

    # 检测 VPN 接口
    local tun_iface=""
    if [ -f "$MYNET_HOME/conf/mynet.conf" ]; then
        tun_iface=$(grep "^VPN_INTERFACE=" "$MYNET_HOME/conf/mynet.conf" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi
    if [ -z "$tun_iface" ]; then
        tun_iface=$(ip link show | grep -o 'gnb_tun[^:]*' | head -1)
    fi
    if [ -z "$tun_iface" ]; then
        echo "[ERROR] 无法检测 VPN 接口"
        return 1
    fi
    echo "[INFO] VPN 接口: $tun_iface"

    case "$FW_TYPE" in
        nftables)
            nft add table inet mynet_proxy 2>/dev/null || true
            # MASQUERADE — VPN 子网流量 NAT 到 WAN
            nft delete chain inet mynet_proxy server_postrouting 2>/dev/null || true
            nft add chain inet mynet_proxy server_postrouting { type nat hook postrouting priority srcnat\; }
            nft add rule inet mynet_proxy server_postrouting oifname "$wan_iface" masquerade
            # FORWARD — 允许 VPN→WAN 转发
            nft delete chain inet mynet_proxy server_forward 2>/dev/null || true
            nft add chain inet mynet_proxy server_forward { type filter hook forward priority filter\; }
            nft add rule inet mynet_proxy server_forward iifname "$tun_iface" oifname "$wan_iface" accept
            nft add rule inet mynet_proxy server_forward iifname "$wan_iface" oifname "$tun_iface" ct state established,related accept
            # 可选：加载白名单
            local whitelist="$MYNET_HOME/conf/proxy/proxy_whitelist.txt"
            if [ -f "$whitelist" ]; then
                nft add set inet mynet_proxy server_whitelist { type ipv4_addr\; } 2>/dev/null || true
                while read -r ip; do
                    [[ "$ip" =~ ^# ]] && continue
                    [[ -z "$ip" ]] && continue
                    nft add element inet mynet_proxy server_whitelist { "$ip" } 2>/dev/null
                done < "$whitelist"
                # 仅允许白名单 peer 使用 server
                nft insert rule inet mynet_proxy server_forward iifname "$tun_iface" ip saddr != @server_whitelist drop
                echo "[INFO] ✓ 白名单已加载"
            fi
            ;;
        iptables)
            # MASQUERADE
            iptables -w 5 -t nat -C POSTROUTING -o "$wan_iface" -j MASQUERADE 2>/dev/null || \
                iptables -w 5 -t nat -A POSTROUTING -o "$wan_iface" -j MASQUERADE
            # FORWARD
            iptables -w 5 -C FORWARD -i "$tun_iface" -o "$wan_iface" -j ACCEPT 2>/dev/null || \
                iptables -w 5 -A FORWARD -i "$tun_iface" -o "$wan_iface" -j ACCEPT
            iptables -w 5 -C FORWARD -i "$wan_iface" -o "$tun_iface" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                iptables -w 5 -A FORWARD -i "$wan_iface" -o "$tun_iface" -m state --state ESTABLISHED,RELATED -j ACCEPT
            ;;
    esac

    echo "[INFO] ✓ Server 模式已启动 ($tun_iface → $wan_iface)"
}

stop_server_mode() {
    echo "[INFO] 停止 Server 模式..."
    case "$FW_TYPE" in
        nftables)
            nft delete chain inet mynet_proxy server_postrouting 2>/dev/null || true
            nft delete chain inet mynet_proxy server_forward 2>/dev/null || true
            nft delete set inet mynet_proxy server_whitelist 2>/dev/null || true
            ;;
        iptables)
            local wan_iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
            local tun_iface=""
            if [ -f "$MYNET_HOME/conf/mynet.conf" ]; then
                tun_iface=$(grep "^VPN_INTERFACE=" "$MYNET_HOME/conf/mynet.conf" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
            fi
            [ -z "$tun_iface" ] && tun_iface=$(ip link show | grep -o 'gnb_tun[^:]*' | head -1)
            if [ -n "$wan_iface" ] && [ -n "$tun_iface" ]; then
                iptables -w 5 -t nat -D POSTROUTING -o "$wan_iface" -j MASQUERADE 2>/dev/null || true
                iptables -w 5 -D FORWARD -i "$tun_iface" -o "$wan_iface" -j ACCEPT 2>/dev/null || true
                iptables -w 5 -D FORWARD -i "$wan_iface" -o "$tun_iface" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
            fi
            ;;
    esac
    echo "[INFO] ✓ Server 模式已停止"
}

# ─────────────────────────────────────────────────────────
# DNS 劫持（Phase 8.2）
# 三种模式: redirect (DNAT 53) / resolv (修改 resolv.conf) / none
# ─────────────────────────────────────────────────────────

start_dns_intercept() {
    local dns_mode="${1:-none}"
    local dns_server="${2:-}"

    if [ "$dns_mode" = "none" ] || [ -z "$dns_mode" ]; then
        echo "[INFO] DNS 劫持: 未启用"
        return 0
    fi

    if [ -z "$dns_server" ]; then
        echo "[ERROR] DNS 劫持需要指定 DNS 服务器地址"
        return 1
    fi

    echo "[INFO] DNS 劫持模式: $dns_mode → $dns_server"

    case "$dns_mode" in
        redirect)
            # DNAT — LAN 设备 DNS 请求重定向到 VPN 侧 DNS
            case "$FW_TYPE" in
                nftables)
                    nft add table inet mynet_proxy 2>/dev/null || true
                    nft delete chain inet mynet_proxy dns_intercept 2>/dev/null || true
                    nft add chain inet mynet_proxy dns_intercept { type nat hook prerouting priority dstnat\; }
                    nft add rule inet mynet_proxy dns_intercept iifname "br-lan" udp dport 53 dnat ip to "$dns_server:53"
                    nft add rule inet mynet_proxy dns_intercept iifname "br-lan" tcp dport 53 dnat ip to "$dns_server:53"
                    ;;
                iptables)
                    iptables -w 5 -t nat -C PREROUTING -i br-lan -p udp --dport 53 -j DNAT --to-destination "$dns_server:53" 2>/dev/null || \
                        iptables -w 5 -t nat -A PREROUTING -i br-lan -p udp --dport 53 -j DNAT --to-destination "$dns_server:53"
                    iptables -w 5 -t nat -C PREROUTING -i br-lan -p tcp --dport 53 -j DNAT --to-destination "$dns_server:53" 2>/dev/null || \
                        iptables -w 5 -t nat -A PREROUTING -i br-lan -p tcp --dport 53 -j DNAT --to-destination "$dns_server:53"
                    ;;
            esac
            echo "[INFO] ✓ DNS 劫持已启用 (redirect → $dns_server)"
            ;;
        resolv)
            # 修改 resolv.conf
            local resolv_file="/tmp/resolv.conf.d/resolv.conf.auto"
            if [ -f "$resolv_file" ]; then
                cp "$resolv_file" "${resolv_file}.proxy_bak"
                echo "nameserver $dns_server" > "$resolv_file"
                echo "[INFO] ✓ DNS 劫持已启用 (resolv → $dns_server)"
            else
                echo "[WARN] resolv.conf 不存在: $resolv_file"
                return 1
            fi
            ;;
        *)
            echo "[ERROR] 未知 DNS 模式: $dns_mode"
            return 1
            ;;
    esac
}

stop_dns_intercept() {
    echo "[INFO] 停止 DNS 劫持..."
    case "$FW_TYPE" in
        nftables)
            nft delete chain inet mynet_proxy dns_intercept 2>/dev/null || true
            ;;
        iptables)
            # 清除所有 dport 53 DNAT 规则（按 interface+protocol 删除）
            iptables -w 5 -t nat -D PREROUTING -i br-lan -p udp --dport 53 -j DNAT 2>/dev/null || true
            iptables -w 5 -t nat -D PREROUTING -i br-lan -p tcp --dport 53 -j DNAT 2>/dev/null || true
            ;;
    esac
    # 恢复 resolv.conf
    local resolv_bak="/tmp/resolv.conf.d/resolv.conf.auto.proxy_bak"
    if [ -f "$resolv_bak" ]; then
        mv "$resolv_bak" "/tmp/resolv.conf.d/resolv.conf.auto"
        echo "[INFO] ✓ resolv.conf 已恢复"
    fi
    echo "[INFO] ✓ DNS 劫持已停止"
}

# 停止代理路由
stop() {
    echo "[INFO] 停止代理路由..."

    # 停止 DNS 劫持
    stop_dns_intercept

    # 停止 Server 模式
    stop_server_mode

    echo "[INFO] 防火墙类型: $FW_TYPE"

    case "$FW_TYPE" in
        nftables)
            stop_nftables
            ;;
        iptables)
            stop_iptables
            ;;
        *)
            echo "[WARN] 未知防火墙类型，尝试清理所有"
            stop_iptables
            stop_nftables
            ;;
    esac

    # 清理所有与 mynet_proxy 相关的策略路由（循环删除）
    local cleaned=0

    # 清理 fwmark 规则
    while ip rule list | grep -q "lookup $TABLE_NAME"; do
        local rule_line=$(ip rule list | grep "lookup $TABLE_NAME" | head -n 1)
        if [[ "$rule_line" =~ fwmark[[:space:]]+([x0-9a-f]+) ]]; then
            local fwmark="${BASH_REMATCH[1]}"
            ip rule del fwmark "$fwmark" 2>/dev/null || true
            cleaned=$((cleaned+1))
        elif [[ "$rule_line" =~ from[[:space:]]+([0-9.]+) ]]; then
            local from_ip="${BASH_REMATCH[1]}"
            ip rule del from "$from_ip" table $TABLE_ID 2>/dev/null || true
            cleaned=$((cleaned+1))
        else
            break
        fi
    done

    # 清理已注册的 mynet_proxy 路由表
    if [ -f /etc/iproute2/rt_tables ]; then
        local table_ids=$(grep -E "^[[:space:]]*[0-9]+[[:space:]]+$TABLE_NAME" /etc/iproute2/rt_tables | awk '{print $1}')
        for id in $table_ids; do
            if [ -n "$id" ]; then
                ip route flush table $id 2>/dev/null || true
                echo "[INFO] ✓ 清理路由表 $TABLE_NAME (ID: $id)"
            fi
        done
    fi

    echo "[INFO] ✓ 策略路由已清理 (删除 $cleaned 条规则)"
    echo "[INFO] ✓ 代理路由已停止"
}

# 停止 iptables 模式
stop_iptables() {
    # 等待 xtables 锁释放
    if [ -e /run/xtables.lock ]; then
        echo "[INFO] 等待 xtables.lock 释放..."
        local wait_count=0
        while [ -e /run/xtables.lock ] && [ $wait_count -lt 10 ]; do
            sleep 0.5
            wait_count=$((wait_count+1))
        done
    fi

    # 清理 iptables
    iptables -w 5 -t mangle -D OUTPUT -m set --match-set $IPSET_NAME dst -j MARK --set-mark $FWMARK 2>/dev/null || true
    iptables -w 5 -t mangle -D PREROUTING -m set --match-set $IPSET_NAME dst -j MARK --set-mark $FWMARK 2>/dev/null || true
    echo "[INFO] ✓ iptables 规则已清理"

    # 清理 ipset
    ipset destroy $IPSET_NAME 2>/dev/null || true
    echo "[INFO] ✓ ipset 已清理"
}

# 停止 nftables 模式
stop_nftables() {
    # 删除 nft 规则和 table
    nft delete table inet mynet_proxy 2>/dev/null || true
    echo "[INFO] ✓ nft 规则已清理"
}

# 显示状态
status() {
    echo "==================== 代理路由状态 ===================="
    echo "MYNET_HOME: $MYNET_HOME"
    echo "防火墙类型: $FW_TYPE"
    echo "路由表: $TABLE_NAME (ID: $TABLE_ID, MARK: $FWMARK)"
    echo ""

    # 检查配置文件
    if [ -f "$ROUTE_CONFIG" ]; then
        local total_entries=$(grep -v "^#" "$ROUTE_CONFIG" | grep -v "^$" | wc -l)
        echo "配置文件: $ROUTE_CONFIG"
        echo "路由条目: $total_entries"
    else
        echo "配置文件: 不存在"
        echo "====================================================="
        return
    fi

    echo ""

    # 统计代理的网络和主机
    local total_hosts=0
    local net24_count=0
    local net16_count=0
    local net8_count=0
    local gateways_list=""
    declare -A gateway_usage
    local networks_list=""

    while read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^([0-9./]+)[[:space:]]+via[[:space:]]+([0-9.,]+) ]]; then
            local network="${BASH_REMATCH[1]}"
            local gateways="${BASH_REMATCH[2]}"

            # 解析网络和掩码
            if [[ "$network" =~ /([0-9]+)$ ]]; then
                local mask="${BASH_REMATCH[1]}"
            else
                local mask=32
            fi

            case "$mask" in
                24) net24_count=$((net24_count + 1)) ;;
                16) net16_count=$((net16_count + 1)) ;;
                8) net8_count=$((net8_count + 1)) ;;
            esac
            # 计算主机数
            local hosts=$((1 << (32 - mask)))
            total_hosts=$((total_hosts + hosts))

            # 收集网络列表用于测试
            networks_list="$networks_list $network"

            # 收集网关
            IFS=',' read -ra gw_array <<< "$gateways"
            for gw in "${gw_array[@]}"; do
                gw=$(echo "$gw" | xargs)
                if [ -n "$gw" ]; then
                    if [[ "$gateways_list" != *"$gw"* ]]; then
                        gateways_list="$gateways_list $gw"
                    fi
                    gateway_usage["$gw"]=$((gateway_usage["$gw"] + 1))
                fi
            done
        fi
    done < "$ROUTE_CONFIG"

    echo "代理统计:"
    echo "  总主机数: $total_hosts"
    echo "  /24网段: $net24_count 个"
    echo "  /16网段: $net16_count 个"
    echo "  /8网段: $net8_count 个"

    echo ""

    # 网关统计
    local unique_gateways=$(echo "$gateways_list" | tr ' ' '\n' | sort | uniq | wc -l)
    echo "出口网关统计:"
    echo "  总网关数: $unique_gateways"

    for gw in "${!gateway_usage[@]}"; do
        local usage=${gateway_usage["$gw"]}
        # 检查网关活跃情况 (ping一次，超时1秒)
        if ping -c 1 -W 1 "$gw" >/dev/null 2>&1; then
            echo "  $gw: 活跃 (使用 $usage 次)"
        else
            echo "  $gw: 不活跃 (使用 $usage 次)"
        fi
    done

    echo ""

    # 单位转换函数 (K=千, M=百万, G=十亿)
    convert_unit() {
        local value="$1"
        # 移除所有非数字和单位字符
        local num=$(echo "$value" | sed 's/[^0-9KMG.]//g')

        if [[ "$num" =~ ([0-9.]+)G$ ]]; then
            # 十亿 (Giga)
            local base=$(echo "${BASH_REMATCH[1]}" | sed 's/G$//')
            echo "$(awk "BEGIN {printf \"%.0f\", $base * 1000000000}")"
        elif [[ "$num" =~ ([0-9.]+)M$ ]]; then
            # 百万 (Million)
            local base=$(echo "${BASH_REMATCH[1]}" | sed 's/M$//')
            echo "$(awk "BEGIN {printf \"%.0f\", $base * 1000000}")"
        elif [[ "$num" =~ ([0-9.]+)K$ ]]; then
            # 千 (Kilo)
            local base=$(echo "${BASH_REMATCH[1]}" | sed 's/K$//')
            echo "$(awk "BEGIN {printf \"%.0f\", $base * 1000}")"
        else
            # 纯数字或无法识别，返回原值（移除非数字）
            echo "${num%%[!0-9]*}"
        fi
    }

    # 检查规则集
    case "$FW_TYPE" in
        iptables)
            if ipset list $IPSET_NAME >/dev/null 2>&1; then
                local count=$(ipset list $IPSET_NAME | grep -c "^[0-9]" || echo "0")
                echo "ipset: 活动 ($count 条)"

                # 统计初始包数量 (正确转换 K/M/G 单位)
                local raw_output=$(iptables -t mangle -L OUTPUT -v -n 2>/dev/null | grep "mynet_proxy" | awk '{print $1}' | head -1 || echo "0")
                local raw_prerouting=$(iptables -t mangle -L PREROUTING -v -n 2>/dev/null | grep "mynet_proxy" | awk '{print $1}' | head -1 || echo "0")
                local packets_output_initial=$(convert_unit "$raw_output")
                local packets_prerouting_initial=$(convert_unit "$raw_prerouting")
                [ -z "$packets_output_initial" ] && packets_output_initial=0
                [ -z "$packets_prerouting_initial" ] && packets_prerouting_initial=0
                local total_packets_initial=$((packets_output_initial + packets_prerouting_initial))
                echo "包统计: $total_packets_initial 个包被标记"

                # 策略生效测试：随机选择10个网络进行ping测试
                if [ -n "$networks_list" ]; then
                    echo ""
                    echo "策略生效测试: 正在生成测试流量..."
                    local test_networks=()
                    IFS=' ' read -ra test_networks <<< "$networks_list"
                    local num_networks=${#test_networks[@]}
                    local test_count=10
                    [ $num_networks -lt $test_count ] && test_count=$num_networks

                    for ((i=0; i<test_count; i++)); do
                        local rand_index=$((RANDOM % num_networks))
                        local test_net=${test_networks[$rand_index]}

                        # 如果是网络地址，尝试ping网关；如果是主机地址，直接ping
                        if [[ "$test_net" == */* ]]; then
                            # 网络地址，提取网关进行ping测试
                            local network_part=$(echo "$test_net" | cut -d'/' -f1)
                            # 简单推导一个可ping的IP（对于私有网络）
                            if [[ "$network_part" =~ ^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
                                # 私有网络，取网络的第一个IP
                                local ip_parts=($network_part)
                                IFS='.' read -r a b c d <<< "$network_part"
                                local test_ip="${a}.${b}.${c}.1"
                                ping -c 1 -W 1 "$test_ip" >/dev/null 2>&1 &
                            fi
                        else
                            # 主机地址，直接ping
                            ping -c 1 -W 1 "$test_net" >/dev/null 2>&1 &
                        fi
                    done
                    wait

                    # 统计测试后的包数量 (正确转换 K/M/G 单位)
                    local raw_output_final=$(iptables -t mangle -L OUTPUT -v -n 2>/dev/null | grep "mynet_proxy" | awk '{print $1}' | head -1 || echo "0")
                    local raw_prerouting_final=$(iptables -t mangle -L PREROUTING -v -n 2>/dev/null | grep "mynet_proxy" | awk '{print $1}' | head -1 || echo "0")
                    local packets_output_final=$(convert_unit "$raw_output_final")
                    local packets_prerouting_final=$(convert_unit "$raw_prerouting_final")
                    [ -z "$packets_output_final" ] && packets_output_final=0
                    [ -z "$packets_prerouting_final" ] && packets_prerouting_final=0
                    local total_packets_final=$((packets_output_final + packets_prerouting_final))
                    local test_packets=$((total_packets_final - total_packets_initial))

                    echo "测试结果: 生成 $test_packets 个测试包"
                    if [ "$test_packets" -gt 0 ]; then
                        echo "策略生效: 是 (测试包被标记)"
                    else
                        echo "策略生效: 否 (测试包未被标记)"
                    fi
                else
                    if [ "$total_packets_initial" -gt 0 ]; then
                        echo "策略生效: 是"
                    else
                        echo "策略生效: 否 (无包被标记)"
                    fi
                fi
            else
                echo "ipset: 未运行"
                echo "策略生效: 否"
            fi
            ;;
        nftables)
            if nft list set inet mynet_proxy $NFT_SET_NAME >/dev/null 2>&1; then
                echo "nft set: 活动"

                # 统计初始包数量
                local packets_output_initial=$(nft list chain inet mynet_proxy mangle_output 2>/dev/null | grep -o "counter packets [0-9]*" | awk '{sum += $3} END {print sum+0}' || echo "0")
                local packets_prerouting_initial=$(nft list chain inet mynet_proxy mangle_prerouting 2>/dev/null | grep -o "counter packets [0-9]*" | awk '{sum += $3} END {print sum+0}' || echo "0")
                local total_packets_initial=$((packets_output_initial + packets_prerouting_initial))
                echo "包统计: $total_packets_initial 个包被标记"

                # 策略生效测试
                if [ -n "$networks_list" ]; then
                    echo ""
                    echo "策略生效测试: 正在生成测试流量..."
                    local test_networks=()
                    IFS=' ' read -ra test_networks <<< "$networks_list"
                    local num_networks=${#test_networks[@]}
                    local test_count=10
                    [ $num_networks -lt $test_count ] && test_count=$num_networks

                    for ((i=0; i<test_count; i++)); do
                        local rand_index=$((RANDOM % num_networks))
                        local test_net=${test_networks[$rand_index]}
                        if [[ "$test_net" =~ /([0-9]+)$ ]]; then
                            local base_ip=$(echo "$test_net" | cut -d'/' -f1)
                            local mask="${BASH_REMATCH[1]}"
                            if [ $mask -lt 32 ]; then
                                local ip_parts=(${base_ip//./ })
                                local host_ip="${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.1"
                                ping -c 3 -W 1 "$host_ip" >/dev/null 2>&1 &
                            else
                                ping -c 3 -W 1 "$base_ip" >/dev/null 2>&1 &
                            fi
                        else
                            ping -c 3 -W 1 "$test_net" >/dev/null 2>&1 &
                        fi
                    done
                    wait

                    # 统计测试后的包数量
                    local packets_output_final=$(nft list chain inet mynet_proxy mangle_output 2>/dev/null | grep -o "counter packets [0-9]*" | awk '{sum += $3} END {print sum+0}' || echo "0")
                    local packets_prerouting_final=$(nft list chain inet mynet_proxy mangle_prerouting 2>/dev/null | grep -o "counter packets [0-9]*" | awk '{sum += $3} END {print sum+0}' || echo "0")
                    local total_packets_final=$((packets_output_final + packets_prerouting_final))
                    local test_packets=$((total_packets_final - total_packets_initial))

                    echo "测试结果: 生成 $test_packets 个测试包"
                    if [ "$test_packets" -gt 0 ]; then
                        echo "策略生效: 是 (测试包被标记)"
                    else
                        echo "策略生效: 否 (测试包未被标记)"
                    fi
                else
                    if [ "$total_packets_initial" -gt 0 ]; then
                        echo "策略生效: 是"
                    else
                        echo "策略生效: 否 (无包被标记)"
                    fi
                fi
            else
                echo "nft set: 未运行"
                echo "策略生效: 否"
            fi
            ;;
    esac

    # 检查策略路由
    if ip rule list | grep -q "fwmark $FWMARK"; then
        echo "策略路由: 已配置"
    else
        echo "策略路由: 未配置"
    fi

    # 检查路由表
    if ip route show table $TABLE_ID | grep -q '.'; then
        echo "路由表 $TABLE_NAME: 已配置"
    else
        echo "路由表 $TABLE_NAME: 未配置"
    fi

    echo "====================================================="
}

# 刷新配置（v0.9.9+）
refresh() {
    echo "[INFO] 刷新代理配置..."
    echo ""

    # 步骤 1: 下载远程 IP 列表
    echo "[INFO] 步骤 1/3: 下载远程 IP 列表"

    local sources_dir="$MYNET_HOME/conf/proxy/proxy_sources"
    mkdir -p "$sources_dir"

    local base_url="${CTL_BASE_URL:-https://ctl.mynet.club}/d/plugins/mp"
    local download_ok=true

    # 下载 interip.txt
    echo "[INFO]   下载 interip.txt..."
    if curl -fsSL -o "$sources_dir/interip.txt" "$base_url/interip.txt"; then
        local count=$(wc -l < "$sources_dir/interip.txt" 2>/dev/null || echo "0")
        echo "[INFO]   ✓ interip.txt ($count 条)"
    else
        echo "[WARN]   ! 下载 interip.txt 失败（将使用本地缓存）"
        download_ok=false
    fi

    # 下载 chinaip.txt
    echo "[INFO]   下载 chinaip.txt..."
    if curl -fsSL -o "$sources_dir/chinaip.txt" "$base_url/chinaip.txt"; then
        local count=$(wc -l < "$sources_dir/chinaip.txt" 2>/dev/null || echo "0")
        echo "[INFO]   ✓ chinaip.txt ($count 条)"
    else
        echo "[WARN]   ! 下载 chinaip.txt 失败（将使用本地缓存）"
        download_ok=false
    fi

    if [[ "$download_ok" == "true" ]]; then
        echo "[INFO] ✓ 远程 IP 列表已更新"
    else
        echo "[WARN] 部分下载失败，将使用本地缓存继续"
    fi

    echo ""

    # 步骤 2: 重新生成路由配置（调用 proxy.sh 的 generate_proxy_config）
    echo "[INFO] 步骤 2/3: 重新生成路由配置"

    local proxy_sh="$MYNET_HOME/scripts/proxy/proxy.sh"
    if [[ -f "$proxy_sh" ]]; then
        if MYNET_HOME="$MYNET_HOME" bash "$proxy_sh" generate_config --force; then
            echo "[INFO] ✓ 路由配置已重新生成"
        else
            echo "[ERROR] 生成路由配置失败"
            return 1
        fi
    else
        echo "[ERROR] proxy.sh 不存在: $proxy_sh"
        return 1
    fi

    echo ""

    # 步骤 3: 重启策略路由
    echo "[INFO] 步骤 3/3: 重启策略路由"

    stop
    sleep 1
    start

    echo ""
    echo "[INFO] ✓ 配置刷新完成！"
    echo ""
}

# 重新配置代理节点（v0.9.9+）
setup_proxy() {
    echo "[INFO] 重新配置代理节点..."
    echo ""

    echo "[WARN] 此操作将重新配置代理节点"
    echo "[INFO] 建议在配置变更时才运行此命令"
    echo ""

    # 检查是否有现有配置
    local role_conf="$MYNET_HOME/conf/proxy/proxy_role.conf"
    if [[ -f "$role_conf" ]]; then
        echo "[INFO] 检测到现有配置："
        grep -E "PROXY_ENABLED|NODE_REGION" "$role_conf" 2>/dev/null | head -5 || true
        echo ""
    fi

    echo "[INFO] 请通过 LuCI 界面 (admin/services/mynet/proxy) 修改配置"
    echo "[INFO] 或直接编辑: $role_conf"
    echo ""

    return 0
}

# 主函数
case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        stop
        sleep 1
        start
        ;;
    status)
        status
        ;;
    refresh)
        refresh
        ;;
    setup)
        setup_proxy
        ;;
    server_start)
        start_server_mode
        ;;
    server_stop)
        stop_server_mode
        ;;
    dns_start)
        start_dns_intercept "$2" "$3"
        ;;
    dns_stop)
        stop_dns_intercept
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status|refresh|setup|server_start|server_stop|dns_start|dns_stop}"
        echo ""
        echo "命令说明："
        echo "  start        - 启动代理路由"
        echo "  stop         - 停止代理路由"
        echo "  restart      - 重启代理路由"
        echo "  status       - 查看代理状态"
        echo "  refresh      - 刷新 IP 列表并重新应用配置 (v0.9.9+)"
        echo "  setup        - 重新配置代理节点 (v0.9.9+)"
        echo "  server_start - 启动 Server 模式 (NAT + FORWARD)"
        echo "  server_stop  - 停止 Server 模式"
        echo "  dns_start    - 启动 DNS 劫持 (dns_start <mode> <dns_server>)"
        echo "  dns_stop     - 停止 DNS 劫持"
        exit 1
        ;;
esac
