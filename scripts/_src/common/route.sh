#!/bin/bash
# route.sh - 跨平台路由管理通用模块
# 包含所有平台通用的网络检测和验证功能

# 获取脚本目录并导入通用模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
fi

# 日志函数
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] [$level] $message"
    
    echo "$log_entry"
    
    # 尝试写入日志文件
    local log_file="${LOG_FILE:-/var/log/mynet-network.log}"
    if [ -w "$(dirname "$log_file" 2>/dev/null)" ] 2>/dev/null; then
        echo "$log_entry" >> "$log_file"
    fi
}

# 注意: detect_platform() 现在从 common.sh 导入

# 验证IP地址格式
validate_ip() {
    local ip="$1"
    
    if [ -z "$ip" ]; then
        return 1
    fi
    
    # 简单的IP地址格式验证
    echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

# 验证网络段格式
validate_network() {
    local network="$1"
    
    if [ -z "$network" ]; then
        return 1
    fi
    
    # 验证 CIDR 格式 (例如: 192.168.1.0/24)
    echo "$network" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
}

# 检测网络接口是否存在
interface_exists() {
    local interface="$1"
    
    if [ -z "$interface" ]; then
        return 1
    fi
    
    # 检查接口是否存在 (跨平台方法)
    if [ -d "/sys/class/net/$interface" ]; then
        return 0
    elif command -v ip >/dev/null 2>&1; then
        ip link show "$interface" >/dev/null 2>&1
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$interface" >/dev/null 2>&1
    else
        return 1
    fi
}

# 检测接口是否UP状态
interface_is_up() {
    local interface="$1"
    
    if ! interface_exists "$interface"; then
        return 1
    fi
    
    # 检查接口状态
    if [ -f "/sys/class/net/$interface/operstate" ]; then
        local state=$(cat "/sys/class/net/$interface/operstate")
        if [ "$state" = "up" ]; then
            return 0
        fi
        # 对于 tun/tap/虚拟接口，operstate 可能为 unknown，继续使用其他信号判断
    fi

    if command -v ip >/dev/null 2>&1; then
        # 兼容 ip link 输出：flags 行中的 <...UP...> 或 LOWER_UP/RUNNING 均视为 up
        if ip link show "$interface" 2>/dev/null | grep -qE '<[^>]*\b(UP|LOWER_UP|RUNNING)\b'; then
            return 0
        fi
        # 某些环境只在 state 字段标注，保留原有判断作为补充
        if ip link show "$interface" 2>/dev/null | grep -q "state UP"; then
            return 0
        fi
    fi

    if command -v ifconfig >/dev/null 2>&1; then
        # ifconfig 标志行包含 UP 即认为接口 up
        if ifconfig "$interface" 2>/dev/null | grep -q "UP"; then
            return 0
        fi
    fi

    return 1
}

# 获取接口IP地址
get_interface_ip() {
    local interface="$1"
    
    if ! interface_exists "$interface"; then
        return 1
    fi
    
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip addr show "$interface" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -n1)
    elif command -v ifconfig >/dev/null 2>&1; then
        ip=$(ifconfig "$interface" 2>/dev/null | grep "inet " | awk '{print $2}' | head -n1)
    fi
    
    if [ -n "$ip" ] && validate_ip "$ip"; then
        echo "$ip"
        return 0
    else
        return 1
    fi
}

# 通用VPN接口检测
detect_vpn_interfaces() {
    local vpn_interfaces=""
    
    # 检测常见VPN接口模式
    for pattern in tun tap wg gnb; do
        for iface in /sys/class/net/${pattern}*; do
            if [ -d "$iface" ]; then
                local interface_name=$(basename "$iface")
                if interface_is_up "$interface_name"; then
                    vpn_interfaces="$vpn_interfaces $interface_name"
                fi
            fi
        done
    done
    
    # 规范化输出：一行以空格分隔、去重且去掉结尾多余空格
    echo "$vpn_interfaces" \
        | tr ' ' '\n' \
        | grep -v '^$' \
        | sort \
        | uniq \
        | tr '\n' ' ' \
        | sed 's/[[:space:]]\+$//'
}

# 通用LAN接口检测
detect_lan_interfaces() {
    local lan_interfaces=""
    
    # 常见LAN接口模式
    local patterns="eth br-lan lan"
    
    for pattern in $patterns; do
        for iface in /sys/class/net/${pattern}*; do
            if [ -d "$iface" ]; then
                local interface_name=$(basename "$iface")
                if interface_is_up "$interface_name"; then
                    lan_interfaces="$lan_interfaces $interface_name"
                fi
            fi
        done
    done
    
    # 特别处理以en开头的接口 (现代Linux命名)
    for iface in /sys/class/net/en*; do
        if [ -d "$iface" ]; then
            local interface_name=$(basename "$iface")
            if interface_is_up "$interface_name"; then
                lan_interfaces="$lan_interfaces $interface_name"
            fi
        fi
    done
    
    echo "$lan_interfaces" | tr ' ' '\n' | sort | uniq | tr '\n' ' '
}

# 检测网络冲突
check_network_conflicts() {
    local new_network="$1"
    
    if ! validate_network "$new_network"; then
        echo "❌ 无效的网络格式: $new_network"
        return 1
    fi
    
    log_message "INFO" "检查网络冲突: $new_network"
    
    # 获取新网络的基本信息
    local new_ip=$(echo "$new_network" | cut -d'/' -f1)
    local new_prefix=$(echo "$new_network" | cut -d'/' -f2)
    
    # 检查所有活动接口的网络
    local conflicts=""
    for iface in /sys/class/net/*/; do
        local interface_name=$(basename "$iface")
        local interface_ip=$(get_interface_ip "$interface_name" 2>/dev/null)
        
        if [ -n "$interface_ip" ]; then
            # 简单的网络冲突检测 (这里可以更精确)
            local iface_network="${interface_ip%.*}.0"
            if [ "${new_ip%.*}.0" = "$iface_network" ]; then
                conflicts="$conflicts $interface_name($interface_ip)"
            fi
        fi
    done
    
    if [ -n "$conflicts" ]; then
        echo "⚠️ 检测到潜在网络冲突:"
        for conflict in $conflicts; do
            echo "  - $conflict"
        done
        return 1
    fi
    
    log_message "INFO" "网络冲突检查通过"
    return 0
}

# 注意: parse_config_value() 现在从 common.sh 导入
#      common.sh 版本支持更多格式 (Shell变量 + JSON)

# 生成唯一标识符
generate_unique_id() {
    local prefix="${1:-mynet}"
    local timestamp=$(date +%s)
    local random=$(head -c 4 /dev/urandom | hexdump -e '4/1 "%02x"' 2>/dev/null || echo "$(date +%N | cut -c1-4)")
    echo "${prefix}_${timestamp}_${random}"
}

# 备份文件/配置
backup_file() {
    local file="$1"
    local backup_dir="${2:-/tmp/mynet-backup}"
    
    if [ ! -f "$file" ]; then
        log_message "WARN" "备份文件不存在: $file"
        return 1
    fi
    
    mkdir -p "$backup_dir"
    local backup_file="$backup_dir/$(basename "$file").$(date +%Y%m%d_%H%M%S)"
    
    if cp "$file" "$backup_file" 2>/dev/null; then
        log_message "INFO" "文件已备份: $file -> $backup_file"
        echo "$backup_file"
        return 0
    else
        log_message "ERROR" "文件备份失败: $file"
        return 1
    fi
}

# 恢复文件/配置
restore_file() {
    local backup_file="$1"
    local original_file="$2"
    
    if [ ! -f "$backup_file" ]; then
        log_message "ERROR" "备份文件不存在: $backup_file"
        return 1
    fi
    
    if cp "$backup_file" "$original_file" 2>/dev/null; then
        log_message "INFO" "文件已恢复: $backup_file -> $original_file"
        return 0
    else
        log_message "ERROR" "文件恢复失败: $backup_file -> $original_file"
        return 1
    fi
}

# 显示网络接口信息
show_interface_info() {
    local interface="$1"
    
    if ! interface_exists "$interface"; then
        echo "❌ 接口不存在: $interface"
        return 1
    fi
    
    echo "📡 接口信息: $interface"
    
    # 状态
    if interface_is_up "$interface"; then
        echo "  状态: ✅ UP"
    else
        echo "  状态: ❌ DOWN"
    fi
    
    # IP地址
    local ip=$(get_interface_ip "$interface")
    if [ -n "$ip" ]; then
        echo "  IP地址: $ip"
    else
        echo "  IP地址: 未配置"
    fi
    
    # MAC地址
    if [ -f "/sys/class/net/$interface/address" ]; then
        local mac=$(cat "/sys/class/net/$interface/address")
        echo "  MAC地址: $mac"
    fi
    
    # MTU
    if [ -f "/sys/class/net/$interface/mtu" ]; then
        local mtu=$(cat "/sys/class/net/$interface/mtu")
        echo "  MTU: $mtu"
    fi
}

# 网络连通性测试
test_connectivity() {
    local target="${1:-8.8.8.8}"
    local interface="$2"
    local timeout="${3:-5}"
    
    log_message "INFO" "测试网络连通性: $target"
    
    local ping_cmd="ping -c 1 -W $timeout"
    
    # 如果指定了接口，添加接口参数
    if [ -n "$interface" ] && interface_exists "$interface"; then
        if command -v ip >/dev/null 2>&1; then
            ping_cmd="$ping_cmd -I $interface"
        fi
    fi
    
    if $ping_cmd "$target" >/dev/null 2>&1; then
        echo "✅ 网络连通性正常: $target"
        return 0
    else
        echo "❌ 网络连通性失败: $target"
        return 1
    fi
}

# =====================================================
# 路由配置解析和处理 - 统一入口
# =====================================================

# 路由条目结构体定义
# 格式: node_id:network:netmask:gateway:interface:metric:type
# 示例: 8283289760467957:10.182.236.182:255.255.255.0:::mynet:0:host

# 解析route.conf文件并生成标准化路由条目
parse_route_config_file() {
    local route_file="$1"
    local output_format="${2:-standard}"  # standard, json, uci, iproute2
    local silent="${3:-false}"  # 静默模式，不输出日志
    
    if [ ! -f "$route_file" ]; then
        [ "$silent" != "true" ] && log_message "ERROR" "路由配置文件不存在: $route_file"
        return 1
    fi
    
    [ "$silent" != "true" ] && log_message "INFO" "解析路由配置: $route_file"
    
    local route_count=0
    local valid_routes=0
    
    while IFS= read -r line; do
        route_count=$((route_count + 1))
        
        # 跳过空行和注释
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        
        # 解析路由条目
        local route_entry
        if route_entry=$(parse_route_line "$line" "$silent"); then
            # 转换为指定格式输出
            convert_route_to_format "$route_entry" "$output_format"
            valid_routes=$((valid_routes + 1))
        else
            [ "$silent" != "true" ] && log_message "WARN" "跳过无效路由条目 (行 $route_count): $line"
        fi
        
    done < "$route_file"
    
    [ "$silent" != "true" ] && log_message "INFO" "路由解析完成: 总行数 $route_count, 有效路由 $valid_routes"
    return 0
}

# 解析单个路由行
parse_route_line() {
    local line="$1"
    local silent="${2:-false}"
    
    # 去除首尾空格
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # 移除行内注释（# 之后的内容）
    line=$(echo "$line" | sed 's/[[:space:]]*#.*$//')
    
    # 再次去除空格（移除注释后可能留下的空格）
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # 格式1: nodeId|network|netmask
    if echo "$line" | grep -q '|'; then
        local node_id=$(echo "$line" | cut -d'|' -f1)
        local network=$(echo "$line" | cut -d'|' -f2)
        local netmask=$(echo "$line" | cut -d'|' -f3)
        
        # 验证必要字段
        if ! validate_node_id "$node_id"; then
            [ "$silent" != "true" ] && log_message "WARN" "无效节点ID: $node_id"
            return 1
        fi
        
        if ! validate_ip "$network"; then
            [ "$silent" != "true" ] && log_message "WARN" "无效网络地址: $network"
            return 1
        fi
        
        # 设置默认值
        local gateway=""
        local interface="mynet"
        local metric="0"
        local route_type="host"
        
        # 判断路由类型
        if [ "$netmask" = "255.255.255.255" ]; then
            route_type="host"
        else
            route_type="network"
        fi
        
        # 返回标准格式: node_id:network:netmask:gateway:interface:metric:type
        echo "$node_id:$network:$netmask:$gateway:$interface:$metric:$route_type"
        return 0
    
    # 格式2: network/cidr via gateway [dev interface]
    elif echo "$line" | grep -q " via "; then
        local network_part=$(echo "$line" | awk '{print $1}')
        local gateway=$(echo "$line" | sed 's/.* via \([^ ]*\).*/\1/')
        local interface=""
        
        # 提取接口（如果有）
        if echo "$line" | grep -q " dev "; then
            interface=$(echo "$line" | sed 's/.* dev \([^ ]*\).*/\1/')
        fi
        
        # 验证网络格式
        if ! validate_network "$network_part"; then
            [ "$silent" != "true" ] && log_message "WARN" "无效网络格式: $network_part"
            return 1
        fi
        
        # 验证网关
        if ! validate_ip "$gateway"; then
            [ "$silent" != "true" ] && log_message "WARN" "无效网关地址: $gateway"
            return 1
        fi
        
        # 从CIDR转换为网络和掩码
        local network=$(echo "$network_part" | cut -d'/' -f1)
        local cidr=$(echo "$network_part" | cut -d'/' -f2)
        local netmask=$(cidr_to_netmask "$cidr")
        
        echo ":$network:$netmask:$gateway:$interface:0:network"
        return 0
    
    # 格式3: network/cidr
    elif validate_network "$line"; then
        local network=$(echo "$line" | cut -d'/' -f1)
        local cidr=$(echo "$line" | cut -d'/' -f2)
        local netmask=$(cidr_to_netmask "$cidr")
        
        echo ":$network:$netmask:::0:network"
        return 0
    
    else
        [ "$silent" != "true" ] && log_message "WARN" "不支持的路由格式: $line"
        return 1
    fi
}

# 验证节点ID
validate_node_id() {
    local node_id="$1"
    
    if [ -z "$node_id" ]; then
        return 1
    fi
    
    # 检查是否为数字（支持16位数字ID）
    echo "$node_id" | grep -qE '^[0-9]{1,20}$'
}

# CIDR转子网掩码
cidr_to_netmask() {
    local cidr="$1"
    
    if [ -z "$cidr" ] || [ "$cidr" -lt 0 ] || [ "$cidr" -gt 32 ]; then
        echo "255.255.255.0"  # 默认值
        return 1
    fi
    
    # 计算子网掩码
    local mask=""
    local full_octets=$((cidr / 8))
    local partial_octet=$((cidr % 8))
    
    # 完整的八位组
    for i in $(seq 1 $full_octets); do
        mask="${mask}255."
    done
    
    # 部分八位组
    if [ $partial_octet -gt 0 ]; then
        local partial_value=$((256 - (256 >> partial_octet)))
        mask="${mask}${partial_value}."
    fi
    
    # 填充剩余的零
    local remaining=$((4 - full_octets))
    if [ $partial_octet -gt 0 ]; then
        remaining=$((remaining - 1))
    fi
    
    for i in $(seq 1 $remaining); do
        mask="${mask}0."
    done
    
    # 移除末尾的点
    echo "${mask%.*}"
}

# 转换路由条目为指定格式
convert_route_to_format() {
    local route_entry="$1"
    local format="$2"
    
    # 解析路由条目字段
    local node_id=$(echo "$route_entry" | cut -d':' -f1)
    local network=$(echo "$route_entry" | cut -d':' -f2)
    local netmask=$(echo "$route_entry" | cut -d':' -f3)
    local gateway=$(echo "$route_entry" | cut -d':' -f4)
    local interface=$(echo "$route_entry" | cut -d':' -f5)
    local metric=$(echo "$route_entry" | cut -d':' -f6)
    local route_type=$(echo "$route_entry" | cut -d':' -f7)
    
    # 计算CIDR
    local cidr=$(netmask_to_cidr "$netmask")
    
    case "$format" in
        "standard")
            echo "route:$network/$cidr:$gateway:$interface:$metric:$route_type"
            ;;
        "iproute2")
            local cmd="ip route add $network/$cidr"
            if [ -n "$gateway" ]; then
                cmd="$cmd via $gateway"
            fi
            if [ -n "$interface" ]; then
                cmd="$cmd dev $interface"
            fi
            if [ "$metric" != "0" ]; then
                cmd="$cmd metric $metric"
            fi
            echo "$cmd"
            ;;
        "nettools")
            if [ "$route_type" = "host" ]; then
                if [ -n "$gateway" ]; then
                    echo "route add -host $network gw $gateway"
                else
                    echo "route add -host $network dev $interface"
                fi
            else
                if [ -n "$gateway" ]; then
                    echo "route add -net $network/$cidr gw $gateway"
                else
                    echo "route add -net $network/$cidr dev $interface"
                fi
            fi
            ;;
        "uci")
            if [ -n "$node_id" ]; then
                echo "uci set network.route_$node_id=route"
                echo "uci set network.route_$node_id.target='$network/$cidr'"
                if [ -n "$gateway" ]; then
                    echo "uci set network.route_$node_id.gateway='$gateway'"
                fi
                if [ -n "$interface" ]; then
                    echo "uci set network.route_$node_id.interface='$interface'"
                fi
                if [ "$metric" != "0" ]; then
                    echo "uci set network.route_$node_id.metric='$metric'"
                fi
            fi
            ;;
        "json")
            echo "{\"network\":\"$network/$cidr\",\"gateway\":\"$gateway\",\"interface\":\"$interface\",\"metric\":$metric,\"type\":\"$route_type\"}"
            ;;
        *)
            echo "$route_entry"
            ;;
    esac
}

# 网络掩码转CIDR（已存在，保持不变）
netmask_to_cidr() {
    local netmask="$1"
    local cidr=0
    
    # 简单的掩码转换
    case "$netmask" in
        "255.255.255.255") cidr=32 ;;
        "255.255.255.254") cidr=31 ;;
        "255.255.255.252") cidr=30 ;;
        "255.255.255.248") cidr=29 ;;
        "255.255.255.240") cidr=28 ;;
        "255.255.255.224") cidr=27 ;;
        "255.255.255.192") cidr=26 ;;
        "255.255.255.128") cidr=25 ;;
        "255.255.255.0") cidr=24 ;;
        "255.255.254.0") cidr=23 ;;
        "255.255.252.0") cidr=22 ;;
        "255.255.248.0") cidr=21 ;;
        "255.255.240.0") cidr=20 ;;
        "255.255.224.0") cidr=19 ;;
        "255.255.192.0") cidr=18 ;;
        "255.255.128.0") cidr=17 ;;
        "255.255.0.0") cidr=16 ;;
        "255.254.0.0") cidr=15 ;;
        "255.252.0.0") cidr=14 ;;
        "255.248.0.0") cidr=13 ;;
        "255.240.0.0") cidr=12 ;;
        "255.224.0.0") cidr=11 ;;
        "255.192.0.0") cidr=10 ;;
        "255.128.0.0") cidr=9 ;;
        "255.0.0.0") cidr=8 ;;
        "254.0.0.0") cidr=7 ;;
        "252.0.0.0") cidr=6 ;;
        "248.0.0.0") cidr=5 ;;
        "240.0.0.0") cidr=4 ;;
        "224.0.0.0") cidr=3 ;;
        "192.0.0.0") cidr=2 ;;
        "128.0.0.0") cidr=1 ;;
        "0.0.0.0") cidr=0 ;;
        *) cidr=24 ;;  # 默认值
    esac
    
    echo "$cidr"
}

# 过滤和优化路由规则
filter_route_rules() {
    local input_file="$1"
    local filter_type="${2:-basic}"  # basic, duplicate, optimize
    
    case "$filter_type" in
        "basic")
            # 基本过滤：移除无效条目
            parse_route_config_file "$input_file" "standard"
            ;;
        "duplicate")
            # 去重过滤
            parse_route_config_file "$input_file" "standard" | sort | uniq
            ;;
        "optimize")
            # 优化过滤：去重 + 合并相邻网段
            parse_route_config_file "$input_file" "standard" | sort | uniq | optimize_routes
            ;;
        *)
            log_message "ERROR" "不支持的过滤类型: $filter_type"
            return 1
            ;;
    esac
}

# 路由优化（简单实现）
optimize_routes() {
    # 简单的路由优化，主要是去重
    # 更复杂的优化（如网段合并）可以后续添加
    sort | uniq
}