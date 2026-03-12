#!/bin/bash
# mynet-common.sh - MyNet通用配置和管理模块
# 包含所有平台通用的MyNet相关功能
#
# 变量命名标准:
#   MYNET_HOME - MyNet 安装根目录,所有平台统一使用此变量名
#                包含 bin/, conf/, driver/, scripts/ 等子目录
#   禁止使用: MYNET_ROOT, MYNET_INSTALL_PATH (已废弃)

# MyNet配置文件名
MYNET_CONFIG_FILES=(
    "mynet.conf"
    "config.json"
    "node.conf"
    "vpn.conf" 
    "route.conf"
)

# VPN类型定义
VPN_TYPES=(
    "gnb"
    "wireguard"
    "openvpn"
    "auto"
)

# 路由模式定义
ROUTER_MODES=(
    "gateway"
    "bypass"
    "auto"
)

# 日志级别
LOG_LEVELS=(
    "DEBUG"
    "INFO"
    "WARN"
    "ERROR"
)

# =====================================================
# 颜色输出工具函数
# =====================================================

# 检测是否使用颜色输出
use_colors() {
    # 如果设置了NO_COLOR环境变量或TERM=dumb,禁用颜色
    if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ]; then
        return 1
    fi
    return 0
}

# 信息输出
print_info() { 
    if use_colors; then
        echo -e "\033[32m[INFO]\033[0m $*"
    else
        echo "[INFO] $*"
    fi
}

# 警告输出
print_warn() { 
    if use_colors; then
        echo -e "\033[33m[WARN]\033[0m $*"
    else
        echo "[WARN] $*"
    fi
}

# 错误输出
print_error() { 
    if use_colors; then
        echo -e "\033[31m[ERROR]\033[0m $*"
    else
        echo "[ERROR] $*"
    fi
}

# 成功输出
print_success() { 
    if use_colors; then
        echo -e "\033[1;32m[SUCCESS]\033[0m $*"
    else
        echo "[SUCCESS] $*"
    fi
}

# =====================================================
# 平台检测
# =====================================================

# 检测操作系统平台类型
# 返回: openwrt | linux | macos | unknown
detect_platform() {
    if [ -f /etc/openwrt_release ]; then
        echo "openwrt"
    elif [ "$(uname -s)" = "Linux" ]; then
        echo "linux"
    elif [ "$(uname -s)" = "Darwin" ]; then
        echo "macos"
    else
        echo "unknown"
    fi
}

# =====================================================
# MyNet路径管理
# =====================================================

# 获取 MyNet 安装根目录
# 说明: MYNET_HOME 是所有平台统一使用的变量名,表示 MyNet 安装根目录
# 优先级: 1.参数 2.环境变量 3.错误(不允许猜测路径)
# 返回: MyNet 安装根目录的绝对路径
get_mynet_home() {
    local home_path="$1"
    
    # 1. 如果传入参数，使用参数
    if [ -n "$home_path" ]; then
        if [ -d "$home_path" ]; then
            echo "$home_path"
            return 0
        else
            echo "ERROR: Specified MYNET_HOME does not exist: $home_path" >&2
            return 1
        fi
    fi
    
    # 2. 如果有环境变量，使用环境变量
    if [ -n "$MYNET_HOME" ]; then
        if [ -d "$MYNET_HOME" ]; then
            echo "$MYNET_HOME"
            return 0
        else
            echo "ERROR: MYNET_HOME env var points to non-existent directory: $MYNET_HOME" >&2
            return 1
        fi
    fi
    
    # 3. 错误：必须通过参数或环境变量指定
    echo "ERROR: MYNET_HOME not specified. Set via parameter or MYNET_HOME environment variable" >&2
    return 1
}

# 获取MyNet配置目录
# 优先级: 1.参数 2.环境变量 3.推导(home/conf)
get_mynet_config_dir() {
    local config_dir="$1"
    
    # 1. 如果传入参数，使用参数
    if [ -n "$config_dir" ]; then
        echo "$config_dir"
        return 0
    fi
    
    # 2. 如果有环境变量，使用环境变量
    if [ -n "$MYNET_CONFIG_DIR" ]; then
        echo "$MYNET_CONFIG_DIR"
        return 0
    fi
    
    # 3. 从 MYNET_HOME 推导
    local mynet_home=$(get_mynet_home)
    if [ $? -eq 0 ]; then
        echo "$mynet_home/conf"
        return 0
    fi
    
    return 1
}

# 查找MyNet配置文件
# 优先级: 1.参数指定完整路径 2.环境变量 3.配置目录+文件名
find_mynet_config() {
    local config_name="$1"
    
    # 1. 如果是完整路径，直接使用
    if [ -n "$config_name" ] && [ -f "$config_name" ]; then
        echo "$config_name"
        return 0
    fi
    
    # 2. 如果有环境变量指定配置文件，使用环境变量
    if [ -n "$MYNET_CONFIG_FILE" ] && [ -f "$MYNET_CONFIG_FILE" ]; then
        echo "$MYNET_CONFIG_FILE"
        return 0
    fi
    
    # 3. 从配置目录查找
    local config_dir=$(get_mynet_config_dir)
    if [ $? -ne 0 ]; then
        echo "ERROR: Cannot determine config directory" >&2
        return 1
    fi
    
    # 使用默认文件名
    if [ -z "$config_name" ]; then
        config_name="mynet.conf"
    fi
    
    local config_path="$config_dir/$config_name"
    if [ -f "$config_path" ]; then
        echo "$config_path"
        return 0
    fi
    
    # 配置文件不存在
    echo "ERROR: Config file not found: $config_path" >&2
    return 1
    
    # 检查当前目录
    if [ -f "./$config_name" ]; then
        echo "./$config_name"
        return 0
    fi
    
    return 1
}

# 创建MyNet目录结构
create_mynet_directories() {
    local mynet_home="$1"
    
    if [ -z "$mynet_home" ]; then
        mynet_home=$(get_mynet_home)
    fi
    
    # 创建主要目录
    local dirs=(
        "$mynet_home"
        "$mynet_home/conf"
        "$mynet_home/script"
        "$mynet_home/log"
        "$mynet_home/tmp"
        "$mynet_home/driver"
        "$mynet_home/driver/gnb"
        "$mynet_home/driver/wireguard"
    )
    
    for dir in "${dirs[@]}"; do
        if ! mkdir -p "$dir" 2>/dev/null; then
            log_message "ERROR" "无法创建目录: $dir"
            return 1
        fi
    done
    
    log_message "INFO" "MyNet目录结构创建完成: $mynet_home"
    return 0
}

# =====================================================
# MyNet配置文件管理
# =====================================================

# 解析配置文件中的值
parse_config_value() {
    local config_file="$1"
    local key="$2"
    local default_value="$3"
    
    if [ ! -f "$config_file" ]; then
        echo "$default_value"
        return 1
    fi
    
    # 支持多种配置格式
    local value=""
    
    # Shell变量格式: KEY=value 或 KEY="value"
    if grep -q "^[[:space:]]*$key[[:space:]]*=" "$config_file"; then
        value=$(grep "^[[:space:]]*$key[[:space:]]*=" "$config_file" | head -n1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^["'"'"']//;s/["'"'"']$//')
    
    # JSON格式: "key": "value"
    elif grep -q "\"$key\"" "$config_file"; then
        value=$(grep "\"$key\"" "$config_file" | head -n1 | sed 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi
    
    # 返回值或默认值
    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default_value"
    fi
}

# 加载MyNet主配置
load_mynet_config() {
    local config_file="$1"
    
    if [ -z "$config_file" ]; then
        config_file=$(find_mynet_config "mynet.conf")
    fi
    
    if [ ! -f "$config_file" ]; then
        log_message "WARN" "MyNet配置文件不存在: $config_file"
        return 1
    fi
    
    log_message "INFO" "加载MyNet配置: $config_file"
    
    # 导出主要配置变量
    export MYNET_VPN_TYPE=$(parse_config_value "$config_file" "VPN_TYPE" "auto")
    export MYNET_ROUTER_MODE=$(parse_config_value "$config_file" "ROUTER_MODE" "auto")
    export MYNET_VPN_ZONE=$(parse_config_value "$config_file" "VPN_ZONE" "mynet")
    export MYNET_LAN_INTERFACE=$(parse_config_value "$config_file" "LAN_INTERFACE" "")
    export MYNET_WAN_INTERFACE=$(parse_config_value "$config_file" "WAN_INTERFACE" "")
    export MYNET_LOG_LEVEL=$(parse_config_value "$config_file" "LOG_LEVEL" "INFO")
    export MYNET_DEBUG=$(parse_config_value "$config_file" "DEBUG" "0")
    
    return 0
}

# 保存配置值到文件
save_config_value() {
    local config_file="$1"
    local key="$2"
    local value="$3"
    
    if [ ! -f "$config_file" ]; then
        touch "$config_file"
    fi
    
    # 创建备份
    cp "$config_file" "$config_file.bak" 2>/dev/null
    
    # 更新或添加配置项
    if grep -q "^[[:space:]]*$key[[:space:]]*=" "$config_file"; then
        # 更新现有配置
        sed -i "s|^[[:space:]]*$key[[:space:]]*=.*|$key=\"$value\"|" "$config_file"
    else
        # 添加新配置
        echo "$key=\"$value\"" >> "$config_file"
    fi
    
    log_message "INFO" "配置已保存: $key=$value"
}

# =====================================================
# VPN类型检测和管理
# =====================================================

# 检测可用的VPN类型
detect_available_vpn_types() {
    local available_types=()
    local mynet_home=$(get_mynet_home)
    
    # 检测GNB - 优先使用MYNET_HOME路径
    if [ -f "$mynet_home/driver/gnb/bin/gnb" ]; then
        available_types+=("gnb")
    elif command -v gnb >/dev/null 2>&1; then
        available_types+=("gnb")
    fi
    
    # 检测WireGuard - 优先使用MYNET_HOME路径  
    if [ -f "$mynet_home/driver/wireguard/bin/wg" ]; then
        available_types+=("wireguard")
    elif command -v wg >/dev/null 2>&1; then
        available_types+=("wireguard")
    fi
    
    # 检测OpenVPN - 优先使用MYNET_HOME路径
    if [ -f "$mynet_home/driver/openvpn/bin/openvpn" ]; then
        available_types+=("openvpn")
    elif command -v openvpn >/dev/null 2>&1; then
        available_types+=("openvpn")
    fi
    
    printf '%s\n' "${available_types[@]}"
}

# 获取VPN二进制文件路径
get_vpn_binary() {
    local vpn_type="$1"
    local mynet_home=$(get_mynet_home)
    
    case "$vpn_type" in
        "gnb")
            # 优先使用MYNET_HOME中的二进制文件
            if [ -f "$mynet_home/driver/gnb/bin/gnb" ]; then
                echo "$mynet_home/driver/gnb/bin/gnb"
            elif command -v gnb >/dev/null 2>&1; then
                command -v gnb
            fi
            ;;
        "wireguard")
            # 优先使用MYNET_HOME中的二进制文件
            if [ -f "$mynet_home/driver/wireguard/bin/wg-quick" ]; then
                echo "$mynet_home/driver/wireguard/bin/wg-quick"
            elif command -v wg-quick >/dev/null 2>&1; then
                command -v wg-quick
            fi
            ;;
        "openvpn")
            # 优先使用MYNET_HOME中的二进制文件
            if [ -f "$mynet_home/driver/openvpn/bin/openvpn" ]; then
                echo "$mynet_home/driver/openvpn/bin/openvpn"
            elif command -v openvpn >/dev/null 2>&1; then
                command -v openvpn
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

# 检测VPN接口模式
detect_vpn_interface_pattern() {
    local vpn_type="$1"
    
    case "$vpn_type" in
        "gnb")
            echo "gnb_tun*"
            ;;
        "wireguard")
            echo "wg*"
            ;;
        "openvpn")
            echo "tun*"
            ;;
        *)
            echo "*"
            ;;
    esac
}

# 获取VPN配置目录
get_vpn_config_dir() {
    local vpn_type="$1"
    local node_id="$2"
    local mynet_home=$(get_mynet_home)
    
    case "$vpn_type" in
        "gnb")
            if [ -n "$node_id" ]; then
                echo "$mynet_home/driver/gnb/$node_id"
            else
                echo "$mynet_home/driver/gnb"
            fi
            ;;
        "wireguard")
            if [ -n "$node_id" ]; then
                echo "$mynet_home/driver/wireguard/$node_id"
            else
                echo "$mynet_home/driver/wireguard"
            fi
            ;;
        *)
            echo "$mynet_home/driver/$vpn_type"
            ;;
    esac
}

# =====================================================
# MyNet接口检测
# =====================================================

# 检测MyNet VPN接口
detect_mynet_vpn_interfaces() {
    local vpn_type="$1"
    local interfaces=()

    # 组装匹配模式
    local patterns=()
    if [ -z "$vpn_type" ] || [ "$vpn_type" = "auto" ]; then
        # 仅关注 MyNet 相关接口命名
        patterns=("gnb_tun*" "WG*" "wg*")
    else
        patterns=("$(detect_vpn_interface_pattern "$vpn_type")")
    fi

    # macOS 兼容：WireGuard/隧道通常为 utunX（不可自定义命名）
    if [ "$(detect_platform)" = "macos" ]; then
        patterns+=("utun*")
    fi

    # 如果配置文件中指定了 VPN_INTERFACE，优先包含
    local cfg=$(find_mynet_config "mynet.conf" 2>/dev/null)
    if [ -n "$cfg" ] && [ -f "$cfg" ]; then
        local cfg_iface=$(parse_config_value "$cfg" "VPN_INTERFACE" "")
        if [ -n "$cfg_iface" ] && interface_exists "$cfg_iface" && interface_is_up "$cfg_iface"; then
            interfaces+=("$cfg_iface")
        fi
    fi

    # 遍历实际存在的接口进行模式匹配
    for netdir in /sys/class/net/*; do
        [ -d "$netdir" ] || continue
        local name=$(basename "$netdir")
        # 逐个模式匹配
        for pat in "${patterns[@]}"; do
            case "$name" in
                $pat)
                    if interface_is_up "$name"; then
                        interfaces+=("$name")
                    fi
                    ;;
            esac
        done
    done

    # 去重并输出
    printf '%s\n' "${interfaces[@]}" | sort | uniq
}

# 检测MyNet接口状态
get_mynet_interface_status() {
    local interface="$1"
    
    if ! interface_exists "$interface"; then
        echo "not_found"
        return 1
    fi
    
    if interface_is_up "$interface"; then
        echo "up"
        return 0
    else
        echo "down"
        return 1
    fi
}

# 判断接口名是否为 MyNet 接口
is_mynet_interface() {
    local name="$1"
    case "$name" in
        gnb_tun*|WG*|wg*) return 0 ;;
    esac
    if [ "$(detect_platform)" = "macos" ]; then
        case "$name" in utun*) return 0 ;; esac
    fi
    return 1
}

# 选择一个主 MyNet 接口（优先配置项，其次 gnb_tun*，再 wg*）
detect_primary_mynet_interface() {
    # 优先配置项
    local cfg=$(find_mynet_config "mynet.conf" 2>/dev/null)
    if [ -n "$cfg" ] && [ -f "$cfg" ]; then
        local cfg_iface=$(parse_config_value "$cfg" "VPN_INTERFACE" "")
        if [ -n "$cfg_iface" ] && interface_exists "$cfg_iface" && interface_is_up "$cfg_iface"; then
            echo "$cfg_iface"; return 0
        fi
    fi

    # 其次 gnb_tun* 再 wg* / WG*
    for netdir in /sys/class/net/gnb_tun* /sys/class/net/WG* /sys/class/net/wg*; do
        [ -d "$netdir" ] || continue
        local name=$(basename "$netdir")
        if interface_is_up "$name"; then
            echo "$name"; return 0
        fi
    done

    # macOS 追加 utun*
    if [ "$(detect_platform)" = "macos" ]; then
        for netdir in /sys/class/net/utun*; do
            [ -d "$netdir" ] || continue
            local name=$(basename "$netdir")
            if interface_is_up "$name"; then
                echo "$name"; return 0
            fi
        done
    fi

    return 1
}

# =====================================================
# MyNet节点管理
# =====================================================

# 解析节点ID
parse_node_id() {
    local source="$1"
    
    # 从配置文件解析
    if [ -f "$source" ]; then
        local node_id=$(parse_config_value "$source" "NODE_ID" "")
        if [ -z "$node_id" ]; then
            node_id=$(parse_config_value "$source" "nodeId" "")
        fi
        if [ -z "$node_id" ]; then
            node_id=$(parse_config_value "$source" "node_id" "")
        fi
        echo "$node_id"
    else
        # 直接返回输入值
        echo "$source"
    fi
}

# 验证节点ID格式
validate_node_id() {
    local node_id="$1"
    
    if [ -z "$node_id" ]; then
        return 1
    fi
    
    # 检查长度和格式（通常是16位数字）
    if echo "$node_id" | grep -qE '^[0-9]{16}$'; then
        return 0
    fi
    
    # 检查其他可能的格式
    if echo "$node_id" | grep -qE '^[a-zA-Z0-9]{8,32}$'; then
        return 0
    fi
    
    return 1
}

# =====================================================
# MyNet路由管理
# =====================================================

# 解析路由配置文件
parse_route_config() {
    local route_file="$1"
    
    if [ ! -f "$route_file" ]; then
        log_message "WARN" "路由配置文件不存在: $route_file"
        return 1
    fi
    
    log_message "INFO" "解析路由配置: $route_file"
    
    # 支持多种路由格式
    while IFS= read -r line; do
        # 跳过空行和注释
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        
        # 格式1: nodeId|network|netmask
        if echo "$line" | grep -q '|'; then
            local node_id=$(echo "$line" | cut -d'|' -f1)
            local network=$(echo "$line" | cut -d'|' -f2)
            local netmask=$(echo "$line" | cut -d'|' -f3)
            
            if validate_node_id "$node_id" && validate_ip "$network"; then
                # 转换为CIDR格式
                local cidr=$(netmask_to_cidr "$netmask")
                echo "$node_id:$network/$cidr"
            fi
        
        # 格式2: network/cidr via gateway
        elif echo "$line" | grep -q " via "; then
            echo "$line"
        
        # 格式3: 简单的network/cidr
        elif validate_network "$line"; then
            echo "$line"
        fi
        
    done < "$route_file"
}

# 转换子网掩码为CIDR
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

# =====================================================
# MyNet服务管理
# =====================================================

# 检测MyNet服务状态
check_mynet_service_status() {
    local service_name="${1:-mynet}"
    local status="unknown"
    
    # 检测不同的init系统
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active "$service_name" >/dev/null 2>&1; then
            status="running"
        elif systemctl is-enabled "$service_name" >/dev/null 2>&1; then
            status="stopped"
        else
            status="disabled"
        fi
    elif [ -f "/etc/init.d/$service_name" ]; then
        if "/etc/init.d/$service_name" status >/dev/null 2>&1; then
            status="running"
        else
            status="stopped"
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if rc-service "$service_name" status >/dev/null 2>&1; then
            status="running"
        else
            status="stopped"
        fi
    fi
    
    echo "$status"
}

# 生成MyNet默认配置
generate_default_mynet_config() {
    local config_file="$1"
    local vpn_type="${2:-auto}"
    local router_mode="${3:-auto}"
    
    if [ -z "$config_file" ]; then
        config_file="$(get_mynet_config_dir)/mynet.conf"
    fi
    
    # 创建目录
    mkdir -p "$(dirname "$config_file")"
    
    cat > "$config_file" << EOF
# MyNet 主配置文件
# 生成时间: $(date)

# VPN 配置
VPN_TYPE="$vpn_type"                # auto, gnb, wireguard
ROUTER_MODE="$router_mode"          # auto, bypass, gateway

# 网络配置
VPN_ZONE="mynet"                    # VPN防火墙区域
LAN_INTERFACE=""                    # LAN接口（自动检测）
WAN_INTERFACE=""                    # WAN接口（自动检测）

# 路径配置
MYNET_HOME="$(get_mynet_home)"
LOG_FILE="/var/log/mynet.log"

# 日志配置
LOG_LEVEL="INFO"                    # DEBUG, INFO, WARN, ERROR
DEBUG="0"                           # 调试模式

# 服务配置
STARTUP_DELAY="0"                   # 启动延迟（秒）
INTERFACE_TIMEOUT="30"              # 接口创建超时（秒）
VPN_STARTUP_TIMEOUT="60"            # VPN启动超时（秒）

# 高级配置
ENABLE_IPV6="auto"                  # IPv6支持
MTU_SIZE="1420"                     # MTU大小
FIREWALL_VERSION="auto"             # 防火墙版本
ENABLE_MASQUERADE="auto"            # 启用NAT伪装
EOF
    
    log_message "INFO" "默认配置已生成: $config_file"
    return 0
}

# =====================================================
# MyNet信息显示
# =====================================================

# 显示MyNet系统信息
show_mynet_info() {
    echo "🔍 MyNet 系统信息"
    echo "=================="
    
    # 基本信息
    echo "📁 路径信息:"
    echo "  MyNet主目录: $(get_mynet_home)"
    echo "  配置目录: $(get_mynet_config_dir)"
    echo "  主配置文件: $(find_mynet_config 'mynet.conf' 2>/dev/null || echo '未找到')"
    echo ""
    
    # VPN信息
    echo "🔌 VPN 信息:"
    local available_vpns=$(detect_available_vpn_types)
    if [ -n "$available_vpns" ]; then
        echo "  可用VPN类型: $available_vpns"
        for vpn in $available_vpns; do
            local binary=$(get_vpn_binary "$vpn")
            echo "    $vpn: $binary"
        done
    else
        echo "  ❌ 未检测到可用的VPN"
    fi
    echo ""
    
    # 接口信息
    echo "🌐 网络接口:"
    local mynet_interfaces=$(detect_mynet_vpn_interfaces)
    if [ -n "$mynet_interfaces" ]; then
        echo "  MyNet接口:"
        for iface in $mynet_interfaces; do
            local status=$(get_mynet_interface_status "$iface")
            echo "    $iface: $status"
        done
    else
        echo "  ❌ 未检测到MyNet接口"
    fi
    echo ""
    
    # 服务状态
    echo "⚙️ 服务状态:"
    local service_status=$(check_mynet_service_status)
    echo "  MyNet服务: $service_status"
    echo ""
    
    # 配置状态
    echo "📋 配置状态:"
    local main_config=$(find_mynet_config "mynet.conf")
    if [ -f "$main_config" ]; then
        echo "  ✅ 主配置存在: $main_config"
        local vpn_type=$(parse_config_value "$main_config" "VPN_TYPE" "未设置")
        local router_mode=$(parse_config_value "$main_config" "ROUTER_MODE" "未设置")
        echo "    VPN类型: $vpn_type"
        echo "    路由模式: $router_mode"
    else
        echo "  ❌ 主配置不存在"
    fi
}

# 如果脚本被直接执行，显示信息
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # 加载依赖的网络通用模块
    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    if [ -f "$SCRIPT_DIR/network-common.sh" ]; then
        source "$SCRIPT_DIR/network-common.sh"
    fi
    
    show_mynet_info
fi