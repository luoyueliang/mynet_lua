#!/bin/bash
# mynet-vpn.sh - MyNet VPN管理通用模块
# 包含所有平台通用的VPN管理功能

# 加载依赖模块
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if [ -f "$SCRIPT_DIR/mynet-common.sh" ]; then
    source "$SCRIPT_DIR/mynet-common.sh"
fi
if [ -f "$SCRIPT_DIR/network-common.sh" ]; then
    source "$SCRIPT_DIR/network-common.sh"
fi

# VPN启动超时时间
VPN_STARTUP_TIMEOUT=60
VPN_STOP_TIMEOUT=30

# =====================================================
# VPN进程管理
# =====================================================

# 查找VPN进程
find_vpn_process() {
    local vpn_type="$1"
    local config_path="$2"
    
    case "$vpn_type" in
        "gnb")
            if [ -n "$config_path" ]; then
                pgrep -f "gnb.*$config_path"
            else
                pgrep -f "gnb"
            fi
            ;;
        "wireguard")
            if [ -n "$config_path" ]; then
                pgrep -f "wg-quick.*$(basename "$config_path" .conf)"
            else
                pgrep -f "wg-quick"
            fi
            ;;
        "openvpn")
            if [ -n "$config_path" ]; then
                pgrep -f "openvpn.*$config_path"
            else
                pgrep -f "openvpn"
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

# 检查VPN进程状态
check_vpn_process_status() {
    local vpn_type="$1"
    local config_path="$2"
    
    local pid=$(find_vpn_process "$vpn_type" "$config_path")
    if [ -n "$pid" ]; then
        if kill -0 "$pid" 2>/dev/null; then
            echo "running:$pid"
            return 0
        else
            echo "dead"
            return 1
        fi
    else
        echo "stopped"
        return 1
    fi
}

# 等待VPN进程启动
wait_for_vpn_startup() {
    local vpn_type="$1"
    local config_path="$2"
    local timeout="${3:-$VPN_STARTUP_TIMEOUT}"
    
    log_message "INFO" "等待VPN进程启动: $vpn_type"
    
    local count=0
    while [ $count -lt $timeout ]; do
        local status=$(check_vpn_process_status "$vpn_type" "$config_path")
        if echo "$status" | grep -q "running"; then
            log_message "INFO" "VPN进程已启动: $status"
            return 0
        fi
        
        sleep 1
        count=$((count + 1))
        
        if [ $((count % 10)) -eq 0 ]; then
            log_message "INFO" "等待VPN启动... (${count}s/${timeout}s)"
        fi
    done
    
    log_message "ERROR" "VPN启动超时: $timeout 秒"
    return 1
}

# 等待VPN进程停止
wait_for_vpn_stop() {
    local vpn_type="$1"
    local config_path="$2"
    local timeout="${3:-$VPN_STOP_TIMEOUT}"
    
    log_message "INFO" "等待VPN进程停止: $vpn_type"
    
    local count=0
    while [ $count -lt $timeout ]; do
        local status=$(check_vpn_process_status "$vpn_type" "$config_path")
        if echo "$status" | grep -q "stopped"; then
            log_message "INFO" "VPN进程已停止"
            return 0
        fi
        
        sleep 1
        count=$((count + 1))
    done
    
    log_message "WARN" "VPN停止超时，强制终止进程"
    return 1
}

# =====================================================
# VPN配置管理
# =====================================================

# 验证VPN配置文件
validate_vpn_config() {
    local vpn_type="$1"
    local config_path="$2"
    
    if [ ! -f "$config_path" ]; then
        log_message "ERROR" "VPN配置文件不存在: $config_path"
        return 1
    fi
    
    case "$vpn_type" in
        "gnb")
            # 检查GNB配置基本结构
            if ! grep -q "node\|interface" "$config_path"; then
                log_message "ERROR" "GNB配置文件格式无效: $config_path"
                return 1
            fi
            ;;
        "wireguard")
            # 检查WireGuard配置基本结构
            if ! grep -q "\[Interface\]" "$config_path"; then
                log_message "ERROR" "WireGuard配置文件格式无效: $config_path"
                return 1
            fi
            ;;
        "openvpn")
            # 检查OpenVPN配置
            if ! grep -q "remote\|dev\|proto" "$config_path"; then
                log_message "ERROR" "OpenVPN配置文件格式无效: $config_path"
                return 1
            fi
            ;;
        *)
            log_message "WARN" "未知VPN类型，跳过配置验证: $vpn_type"
            ;;
    esac
    
    log_message "INFO" "VPN配置验证通过: $config_path"
    return 0
}

# 获取VPN配置中的接口名
get_vpn_interface_from_config() {
    local vpn_type="$1"
    local config_path="$2"
    
    if [ ! -f "$config_path" ]; then
        return 1
    fi
    
    case "$vpn_type" in
        "gnb")
            # 从GNB配置中提取接口名
            local interface=$(grep -E "^[[:space:]]*interface[[:space:]]*=" "$config_path" | head -n1 | cut -d'=' -f2 | tr -d ' "'"'"'')
            if [ -z "$interface" ]; then
                interface="gnb_tun"  # 默认接口名
            fi
            echo "$interface"
            ;;
        "wireguard")
            # WireGuard接口名通常是配置文件名
            local interface=$(basename "$config_path" .conf)
            echo "$interface"
            ;;
        "openvpn")
            # 从OpenVPN配置中提取设备名
            local interface=$(grep -E "^[[:space:]]*dev[[:space:]]+" "$config_path" | head -n1 | awk '{print $2}')
            if [ -z "$interface" ]; then
                interface="tun0"  # 默认设备名
            fi
            echo "$interface"
            ;;
        *)
            return 1
            ;;
    esac
}

# =====================================================
# VPN启动管理
# =====================================================

# 启动GNB
start_gnb() {
    local config_dir="$1"
    local node_id="$2"
    local interface="$3"
    
    if [ ! -d "$config_dir" ]; then
        log_message "ERROR" "GNB配置目录不存在: $config_dir"
        return 1
    fi
    
    local gnb_binary=$(get_vpn_binary "gnb")
    if [ -z "$gnb_binary" ]; then
        log_message "ERROR" "GNB二进制文件未找到"
        return 1
    fi
    
    log_message "INFO" "启动GNB: $config_dir"
    
    # 构建启动命令
    local start_cmd="$gnb_binary -c $config_dir"
    if [ -n "$node_id" ]; then
        start_cmd="$start_cmd --nodeid $node_id"
    fi
    
    # 后台启动
    nohup $start_cmd > /var/log/gnb.log 2>&1 &
    local gnb_pid=$!
    
    log_message "INFO" "GNB进程已启动: PID=$gnb_pid"
    
    # 等待接口创建
    if [ -n "$interface" ]; then
        if wait_for_interface_creation "$interface"; then
            log_message "INFO" "GNB接口已创建: $interface"
            return 0
        else
            log_message "ERROR" "GNB接口创建失败: $interface"
            return 1
        fi
    fi
    
    return 0
}

# 启动WireGuard
start_wireguard() {
    local config_file="$1"
    local interface="$2"
    
    if [ ! -f "$config_file" ]; then
        log_message "ERROR" "WireGuard配置文件不存在: $config_file"
        return 1
    fi
    
    local wg_binary=$(get_vpn_binary "wireguard")
    if [ -z "$wg_binary" ]; then
        log_message "ERROR" "WireGuard二进制文件未找到"
        return 1
    fi
    
    # 获取接口名
    if [ -z "$interface" ]; then
        interface=$(basename "$config_file" .conf)
    fi
    
    log_message "INFO" "启动WireGuard: $interface"
    
    # 启动WireGuard
    if "$wg_binary" up "$interface"; then
        log_message "INFO" "WireGuard接口已启动: $interface"
        return 0
    else
        log_message "ERROR" "WireGuard启动失败: $interface"
        return 1
    fi
}

# 启动OpenVPN
start_openvpn() {
    local config_file="$1"
    local interface="$2"
    
    if [ ! -f "$config_file" ]; then
        log_message "ERROR" "OpenVPN配置文件不存在: $config_file"
        return 1
    fi
    
    local ovpn_binary=$(get_vpn_binary "openvpn")
    if [ -z "$ovpn_binary" ]; then
        log_message "ERROR" "OpenVPN二进制文件未找到"
        return 1
    fi
    
    log_message "INFO" "启动OpenVPN: $config_file"
    
    # 后台启动OpenVPN
    nohup "$ovpn_binary" --config "$config_file" --daemon > /var/log/openvpn.log 2>&1
    
    # 等待接口创建
    if [ -n "$interface" ]; then
        if wait_for_interface_creation "$interface"; then
            log_message "INFO" "OpenVPN接口已创建: $interface"
            return 0
        else
            log_message "ERROR" "OpenVPN接口创建失败: $interface"
            return 1
        fi
    fi
    
    return 0
}

# 通用VPN启动函数
start_vpn() {
    local vpn_type="$1"
    local config_path="$2"
    local node_id="$3"
    local interface="$4"
    
    # 验证配置
    if ! validate_vpn_config "$vpn_type" "$config_path"; then
        return 1
    fi
    
    # 获取接口名（如果未指定）
    if [ -z "$interface" ]; then
        interface=$(get_vpn_interface_from_config "$vpn_type" "$config_path")
    fi
    
    # 检查是否已经运行
    local status=$(check_vpn_process_status "$vpn_type" "$config_path")
    if echo "$status" | grep -q "running"; then
        log_message "WARN" "VPN已在运行: $status"
        return 0
    fi
    
    # 根据类型启动VPN
    case "$vpn_type" in
        "gnb")
            start_gnb "$config_path" "$node_id" "$interface"
            ;;
        "wireguard")
            start_wireguard "$config_path" "$interface"
            ;;
        "openvpn")
            start_openvpn "$config_path" "$interface"
            ;;
        *)
            log_message "ERROR" "不支持的VPN类型: $vpn_type"
            return 1
            ;;
    esac
    
    # 等待启动完成
    if wait_for_vpn_startup "$vpn_type" "$config_path"; then
        log_message "INFO" "VPN启动成功: $vpn_type"
        return 0
    else
        log_message "ERROR" "VPN启动失败: $vpn_type"
        return 1
    fi
}

# =====================================================
# VPN停止管理
# =====================================================

# 停止GNB
stop_gnb() {
    local config_dir="$1"
    
    local pid=$(find_vpn_process "gnb" "$config_dir")
    if [ -n "$pid" ]; then
        log_message "INFO" "停止GNB进程: $pid"
        kill "$pid"
        
        if wait_for_vpn_stop "gnb" "$config_dir"; then
            log_message "INFO" "GNB已停止"
            return 0
        else
            log_message "WARN" "强制终止GNB进程"
            kill -9 "$pid" 2>/dev/null
            return 1
        fi
    else
        log_message "INFO" "GNB进程未运行"
        return 0
    fi
}

# 停止WireGuard
stop_wireguard() {
    local config_file="$1"
    local interface="$2"
    
    # 获取接口名
    if [ -z "$interface" ]; then
        interface=$(basename "$config_file" .conf)
    fi
    
    local wg_binary=$(get_vpn_binary "wireguard")
    if [ -z "$wg_binary" ]; then
        log_message "ERROR" "WireGuard二进制文件未找到"
        return 1
    fi
    
    log_message "INFO" "停止WireGuard: $interface"
    
    if "$wg_binary" down "$interface"; then
        log_message "INFO" "WireGuard已停止: $interface"
        return 0
    else
        log_message "ERROR" "WireGuard停止失败: $interface"
        return 1
    fi
}

# 停止OpenVPN
stop_openvpn() {
    local config_file="$1"
    
    local pid=$(find_vpn_process "openvpn" "$config_file")
    if [ -n "$pid" ]; then
        log_message "INFO" "停止OpenVPN进程: $pid"
        kill "$pid"
        
        if wait_for_vpn_stop "openvpn" "$config_file"; then
            log_message "INFO" "OpenVPN已停止"
            return 0
        else
            log_message "WARN" "强制终止OpenVPN进程"
            kill -9 "$pid" 2>/dev/null
            return 1
        fi
    else
        log_message "INFO" "OpenVPN进程未运行"
        return 0
    fi
}

# 通用VPN停止函数
stop_vpn() {
    local vpn_type="$1"
    local config_path="$2"
    local interface="$3"
    
    log_message "INFO" "停止VPN: $vpn_type"
    
    # 检查是否在运行
    local status=$(check_vpn_process_status "$vpn_type" "$config_path")
    if echo "$status" | grep -q "stopped"; then
        log_message "INFO" "VPN未运行: $vpn_type"
        return 0
    fi
    
    # 根据类型停止VPN
    case "$vpn_type" in
        "gnb")
            stop_gnb "$config_path"
            ;;
        "wireguard")
            stop_wireguard "$config_path" "$interface"
            ;;
        "openvpn")
            stop_openvpn "$config_path"
            ;;
        *)
            log_message "ERROR" "不支持的VPN类型: $vpn_type"
            return 1
            ;;
    esac
}

# =====================================================
# VPN自动管理
# =====================================================

# 自动检测并启动VPN
auto_start_vpn() {
    local mynet_home=$(get_mynet_home)
    local config_dir=$(get_mynet_config_dir)
    
    # 加载配置
    load_mynet_config
    
    local vpn_type="$MYNET_VPN_TYPE"
    local node_id=""
    
    # 如果VPN类型是auto，自动检测
    if [ "$vpn_type" = "auto" ] || [ -z "$vpn_type" ]; then
        local available_types=$(detect_available_vpn_types)
        if [ -n "$available_types" ]; then
            vpn_type=$(echo "$available_types" | head -n1)
            log_message "INFO" "自动选择VPN类型: $vpn_type"
        else
            log_message "ERROR" "未检测到可用的VPN类型"
            return 1
        fi
    fi
    
    # 查找配置
    local config_path=""
    case "$vpn_type" in
        "gnb")
            # 查找GNB配置目录
            config_path=$(find_mynet_config "node.conf")
            if [ -f "$config_path" ]; then
                config_path=$(dirname "$config_path")
                node_id=$(parse_node_id "$config_path/node.conf")
            else
                config_path="$mynet_home/driver/gnb"
                if [ ! -d "$config_path" ]; then
                    log_message "ERROR" "GNB配置目录不存在: $config_path"
                    return 1
                fi
            fi
            ;;
        "wireguard")
            # 查找WireGuard配置文件
            config_path=$(find_mynet_config "wg.conf")
            if [ ! -f "$config_path" ]; then
                config_path="$mynet_home/driver/wireguard/wg.conf"
                if [ ! -f "$config_path" ]; then
                    log_message "ERROR" "WireGuard配置文件不存在: $config_path"
                    return 1
                fi
            fi
            ;;
        *)
            log_message "ERROR" "不支持的VPN类型: $vpn_type"
            return 1
            ;;
    esac
    
    # 启动VPN
    start_vpn "$vpn_type" "$config_path" "$node_id"
}

# 自动停止VPN
auto_stop_vpn() {
    # 加载配置
    load_mynet_config
    
    local vpn_type="$MYNET_VPN_TYPE"
    
    # 如果VPN类型是auto，检测当前运行的VPN
    if [ "$vpn_type" = "auto" ] || [ -z "$vpn_type" ]; then
        local running_types=$(detect_available_vpn_types)
        for type in $running_types; do
            local status=$(check_vpn_process_status "$type")
            if echo "$status" | grep -q "running"; then
                vpn_type="$type"
                break
            fi
        done
    fi
    
    if [ -z "$vpn_type" ] || [ "$vpn_type" = "auto" ]; then
        log_message "INFO" "未检测到运行中的VPN"
        return 0
    fi
    
    # 停止VPN
    stop_vpn "$vpn_type"
}

# =====================================================
# 工具函数
# =====================================================

# 等待接口创建
wait_for_interface_creation() {
    local interface="$1"
    local timeout="${2:-30}"
    
    log_message "INFO" "等待接口创建: $interface"
    
    local count=0
    while [ $count -lt $timeout ]; do
        if interface_exists "$interface"; then
            log_message "INFO" "接口已创建: $interface"
            return 0
        fi
        
        sleep 1
        count=$((count + 1))
    done
    
    log_message "ERROR" "接口创建超时: $interface"
    return 1
}

# 重启VPN
restart_vpn() {
    local vpn_type="$1"
    local config_path="$2"
    local node_id="$3"
    local interface="$4"
    
    log_message "INFO" "重启VPN: $vpn_type"
    
    # 停止VPN
    if ! stop_vpn "$vpn_type" "$config_path" "$interface"; then
        log_message "WARN" "VPN停止时出现问题，继续启动"
    fi
    
    # 等待一下
    sleep 2
    
    # 启动VPN
    start_vpn "$vpn_type" "$config_path" "$node_id" "$interface"
}

# 显示VPN状态
show_vpn_status() {
    echo "🔌 MyNet VPN 状态"
    echo "=================="
    
    local available_types=$(detect_available_vpn_types)
    if [ -z "$available_types" ]; then
        echo "❌ 未检测到可用的VPN类型"
        return 1
    fi
    
    for vpn_type in $available_types; do
        echo "📡 $vpn_type VPN:"
        local binary=$(get_vpn_binary "$vpn_type")
        echo "  二进制文件: $binary"
        
        local status=$(check_vpn_process_status "$vpn_type")
        echo "  进程状态: $status"
        
        local interfaces=$(detect_mynet_vpn_interfaces "$vpn_type")
        if [ -n "$interfaces" ]; then
            echo "  接口列表:"
            for iface in $interfaces; do
                local iface_status=$(get_mynet_interface_status "$iface")
                echo "    $iface: $iface_status"
            done
        else
            echo "  接口列表: 无"
        fi
        echo ""
    done
}

# 如果脚本被直接执行，显示VPN状态
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    show_vpn_status
fi