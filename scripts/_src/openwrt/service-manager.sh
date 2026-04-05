#!/bin/bash
# MyNet OpenWrt 服务管理器
# OpenWrt 平台的 MyNet 服务安装、卸载、升级、状态管理
# 前提：mynet 软件已安装并验证通过
# NOTE: 此脚本需要 bash（依赖 common.sh 的 bash 数组语法）
#       ipk 安装模式下不需要此脚本，直接使用 /etc/init.d/mynet

SCRIPT_NAME="MyNet OpenWrt Service Manager"
VERSION="1.0.0"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# 加载通用工具函数
COMMON_SCRIPT="$(dirname "$SCRIPT_DIR")/common/common.sh"
if [ -f "$COMMON_SCRIPT" ]; then
    . "$COMMON_SCRIPT"
else
    echo "错误: 找不到通用脚本 $COMMON_SCRIPT" >&2
    exit 1
fi

show_help() {
    cat << EOF
MyNet OpenWrt 服务管理器 v$VERSION

OpenWrt 平台的 MyNet 服务生命周期管理工具

USAGE:
    $0 <COMMAND> [OPTIONS]

COMMANDS:
    install              安装 MyNet 服务
    uninstall           卸载 MyNet 服务
    upgrade             升级 MyNet 服务
    start               启动 MyNet 服务
    stop                停止 MyNet 服务
    restart             重启 MyNet 服务
    status              查看服务状态
    enable              启用开机自启
    disable             禁用开机自启

REQUIRED OPTIONS (for install):
    --vpn-type <type>     VPN 类型: gnb, wireguard
    --node-id <id>        节点 ID（16位数字，用于配置目录和接口命名）

OPTIONS:
    --mynet-home <path>   MyNet 安装根目录 (默认: /etc/mynet)
    --force               强制模式，跳过所有确认提示（无人值守）
    --auto-yes            自动回答所有提示为 yes
    --verbose             显示详细输出
    --help                显示帮助信息

EXAMPLES:
    # 安装 GNB 服务，节点 ID 为 1234567890123456
    $0 install --vpn-type gnb --node-id 1234567890123456

    # 无人值守安装 WireGuard 服务
    $0 install --vpn-type wireguard --node-id 9876543210987654 --force

    # 查看服务状态
    $0 status

    # 卸载服务（无确认）
    $0 uninstall --force

    # 启动服务
    $0 start

    # 停止服务
    $0 stop

FEATURES:
    ✓ 零侵入部署：不修改系统配置文件
    ✓ 完全动态：运行时创建网络规则
    ✓ 自动检测：VPN类型和路由器模式
    ✓ 完全可逆：停止服务即清理所有动态配置
    ✓ 无人值守：支持自动化部署

PREREQUISITES:
    - OpenWrt 系统
    - mynet 软件已安装并可正常运行
    - 已通过功能验证测试

EOF
}

# 全局变量
COMMAND=""               # 主命令：install/uninstall/start/stop/status等
VPN_TYPE=""             # VPN 类型：gnb/wireguard
NODE_ID=""              # 节点 ID
FORCE_MODE=0            # 强制模式：跳过确认，覆盖现有安装
AUTO_YES=0              # 自动确认模式：所有询问都回答 yes
VERBOSE=0               # 详细输出模式
UNATTENDED=0         # 无人值守模式：组合 FORCE_MODE 和 AUTO_YES
FORCE_MODE=0      # 强制模式，跳过确认
AUTO_YES=0        # 自动回答 yes

# 配置变量
MYNET_HOME=""            # MyNet 安装根目录,必须通过参数指定
MYNET_BIN_PATH=""        # MyNet 二进制文件路径
GNB_DRIVER_PATH=""       # GNB 驱动程序路径
WG_DRIVER_PATH=""        # WireGuard 驱动程序路径

# 验证并设置 OpenWrt 平台的 MyNet 路径
# 注意: 此函数是 OpenWrt 特定的,包含平台相关的路径验证和设置
#      与 common.sh 的 get_mynet_home() 功能不同
detect_mynet_paths() {
    print_info "验证 MyNet 安装路径..."

    # 优先使用 MYNET_EXECUTABLE 环境变量（由 Go 程序传递）
    if [ -n "$MYNET_EXECUTABLE" ] && [ -x "$MYNET_EXECUTABLE" ]; then
        MYNET_BIN_PATH="$MYNET_EXECUTABLE"
        print_info "使用 MYNET_EXECUTABLE: $MYNET_BIN_PATH"
    # 其次检查系统 PATH 中的 mynet
    elif command -v mynet >/dev/null 2>&1; then
        MYNET_BIN_PATH=$(which mynet)
        print_info "检测到 MyNet 二进制: $MYNET_BIN_PATH"
    else
        print_error "未找到 mynet 命令"
        print_error "请确保 mynet 已正确安装并在 PATH 中，或设置 MYNET_EXECUTABLE 环境变量"
        return 1
    fi

    # 必须通过 --mynet-home 参数指定 MYNET_HOME
    if [ -z "$MYNET_HOME" ]; then
        print_error "必须通过 --mynet-home 参数指定 MyNet 安装根目录"
        print_error ""
        print_error "示例:"
        print_error "  $0 install --mynet-home /etc/mynet --vpn-type gnb --node-id 1234567890123456"
        return 1
    fi

    print_info "使用 MyNet 安装根目录: $MYNET_HOME"

    # 验证配置目录存在
    if [ ! -d "$MYNET_HOME" ]; then
        print_warn "安装目录不存在，将在安装时创建: $MYNET_HOME"
    fi

    # 根据 MYNET_HOME 设置驱动程序路径
    GNB_DRIVER_PATH="$MYNET_HOME/driver/gnb"
    WG_DRIVER_PATH="$MYNET_HOME/driver/wireguard"

    # 验证关键路径
    if [ "$VPN_TYPE" = "gnb" ] && [ ! -d "$GNB_DRIVER_PATH" ]; then
        print_warn "GNB 驱动程序目录不存在: $GNB_DRIVER_PATH"
    fi

    if [ "$VPN_TYPE" = "wireguard" ] && [ ! -d "$WG_DRIVER_PATH" ]; then
        print_warn "WireGuard 驱动程序目录不存在: $WG_DRIVER_PATH"
    fi

    print_info "配置路径:"
    print_info "  MYNET_HOME: $MYNET_HOME"
    print_info "  GNB_DRIVER_PATH: $GNB_DRIVER_PATH"
    print_info "  WG_DRIVER_PATH: $WG_DRIVER_PATH"
}

# 清理开发时源文件
cleanup_source_files() {
    [ "$VERBOSE" = "1" ] && print_info "清理开发时源文件..."

    # 删除 conf/_src 目录
    if [ -d "$MYNET_HOME/conf/_src" ]; then
        rm -rf "$MYNET_HOME/conf/_src"
        [ "$VERBOSE" = "1" ] && print_info "✓ 已删除 conf/_src/"
    fi

    # 删除 scripts/_src 目录
    if [ -d "$MYNET_HOME/scripts/_src" ]; then
        rm -rf "$MYNET_HOME/scripts/_src"
        [ "$VERBOSE" = "1" ] && print_info "✓ 已删除 scripts/_src/"
    fi

    [ "$VERBOSE" = "1" ] && print_success "源文件清理完成"
    return 0
}

# 解析命令行参数
parse_arguments() {
    if [ $# -eq 0 ]; then
        show_help
        exit 1
    fi

    # 第一个参数必须是命令，除非是老格式的参数
    case "$1" in
        install|uninstall|upgrade|start|stop|restart|status|enable|disable)
            COMMAND="$1"
            shift
            ;;
        --deploy)
            COMMAND="install"
            shift
            ;;
        --remove)
            COMMAND="uninstall"
            shift
            ;;
        --status)
            COMMAND="status"
            shift
            ;;
        --help|-h|help)
            show_help
            exit 0
            ;;
        *)
            # 检查是否是老格式，如果没有命令但有 --vpn-type，则进入交互模式
            if echo "$*" | grep -q "\-\-vpn-type"; then
                print_warn "检测到老格式参数，建议使用新格式：$0 install --vpn-type ..."
                COMMAND="install"
            else
                print_error "未知命令或参数: $1"
                show_help
                exit 1
            fi
            ;;
    esac

    # 解析选项
    while [ $# -gt 0 ]; do
        case "$1" in
            --mynet-home)
                shift
                MYNET_HOME="$1"
                ;;
            --vpn-type)
                shift
                VPN_TYPE="$1"
                ;;
            --node-id)
                shift
                NODE_ID="$1"
                ;;
            --force)
                FORCE_MODE=1
                AUTO_YES=1  # 强制模式自动包含 auto-yes
                ;;
            --auto-yes)
                AUTO_YES=1
                ;;
            --verbose)
                VERBOSE=1
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            # 兼容老格式参数
            --deploy|--remove|--status)
                print_warn "参数 $1 已废弃，请使用命令格式"
                ;;
            *)
                print_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done

    # 验证必需参数
    if [ "$COMMAND" = "install" ]; then
        if [ -z "$VPN_TYPE" ]; then
            print_error "安装时必须指定 --vpn-type 参数 (gnb|wireguard)"
            exit 1
        fi

        if [ -z "$NODE_ID" ]; then
            print_error "安装时必须指定 --node-id 参数 (16位数字)"
            exit 1
        fi

        # 验证 VPN 类型
        case "$VPN_TYPE" in
            gnb|wireguard) ;;
            *) print_error "不支持的 VPN 类型: $VPN_TYPE (支持: gnb, wireguard)"; exit 1 ;;
        esac

        # 验证节点 ID 格式
        if ! echo "$NODE_ID" | grep -q '^[0-9]\{16\}$'; then
            print_error "节点 ID 格式错误: $NODE_ID (必须是16位数字，如：1234567890123456)"
            exit 1
        fi

        print_info "配置参数 - VPN 类型: $VPN_TYPE, 节点 ID: $NODE_ID"

        if [ "$FORCE_MODE" = "1" ]; then
            print_info "无人值守模式已启用"
        fi
    fi
}

# 检查环境
check_environment() {
    # 检查 root 权限
    if [ "$(id -u)" -ne 0 ]; then
        print_error "需要 root 权限运行部署"
        return 1
    fi

    # 检查 OpenWrt
    if [ ! -f /etc/openwrt_release ]; then
        print_error "此脚本仅支持 OpenWrt 系统"
        return 1
    fi

    # 检查 mynet 是否已安装
    local mynet_cmd=""

    # 优先使用MYNET_EXECUTABLE环境变量（由Go程序传递）
    if [ -n "$MYNET_EXECUTABLE" ] && [ -x "$MYNET_EXECUTABLE" ]; then
        mynet_cmd="$MYNET_EXECUTABLE"
        print_info "使用MYNET_EXECUTABLE: $mynet_cmd"
    # 其次检查系统PATH中的mynet
    elif command -v mynet >/dev/null 2>&1; then
        mynet_cmd="mynet"
    else
        print_error "未找到 mynet 命令，请先安装 mynet 软件"
        print_error ""
        print_error "OpenWrt mynet 安装步骤："
        print_error "1. 下载适用于 OpenWrt 的 mynet 二进制包："
        print_error "   • 对于 x86_64: mynet-<version>-linux-amd64.tar.gz"
        print_error "   • 对于 ARM: mynet-<version>-linux-arm64.tar.gz"
        print_error ""
        print_error "2. 解压并安装 mynet 二进制文件："
        print_error "   tar -xzf mynet-<version>-linux-amd64.tar.gz"
        print_error "   cp mynet /usr/bin/mynet"
        print_error "   chmod +x /usr/bin/mynet"
        print_error ""
        print_error "3. 验证安装："
        print_error "   mynet --version"
        print_error ""
        print_error "4. 如果已安装但不在PATH中，尝试："
        print_error "   find / -name mynet -type f 2>/dev/null"
        print_error "   ln -s /path/to/mynet /usr/bin/mynet"
        print_error ""
        print_error "调试信息："
        print_error "• MYNET_EXECUTABLE: ${MYNET_EXECUTABLE:-未设置}"
        print_error "• PATH: $PATH"
        print_error ""
        return 1
    fi

    # 检查 mynet 版本
    local version
    if ! version=$($mynet_cmd --version 2>/dev/null); then
        print_error "mynet 命令无法正常运行，请检查安装"
        print_error "尝试路径: $mynet_cmd"
        return 1
    fi

    print_info "检测到 mynet: $version (路径: $mynet_cmd)"

    # 检查基础命令
    local missing_commands=""

    # 检查通用命令
    for cmd in uci ip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands="$missing_commands $cmd"
        fi
    done

    # 根据防火墙版本检查对应的命令
    if command -v fw4 >/dev/null 2>&1 && fw4 check >/dev/null 2>&1; then
        # fw4 环境：检查 nft (nftables)
        print_info "检测到 fw4 (nftables) 防火墙"
        if ! command -v nft >/dev/null 2>&1; then
            missing_commands="$missing_commands nft"
        fi
    else
        # fw3 环境：检查 iptables
        print_info "检测到 fw3 (iptables) 防火墙"
        if ! command -v iptables >/dev/null 2>&1; then
            missing_commands="$missing_commands iptables"
        fi
    fi

    if [ -n "$missing_commands" ]; then
        print_error "缺少必要命令:$missing_commands"
        return 1
    fi

    print_info "环境检查通过"
    return 0
}

# 检查服务状态
check_service_status() {
    if [ -f "/etc/init.d/mynet" ]; then
        print_info "MyNet 服务已部署"

        # 检查服务状态
        if /etc/init.d/mynet enabled 2>/dev/null; then
            print_info "服务已启用"
        else
            print_warn "服务未启用"
        fi

        # 检查运行状态
        if /etc/init.d/mynet running 2>/dev/null; then
            print_info "服务正在运行"
        else
            print_warn "服务未运行"
        fi

        return 0
    else
        print_warn "MyNet 服务未部署"
        return 1
    fi
}

# 获取 MyNet 动态服务脚本
get_service_script() {
    local script_dir="$(dirname "$0")"

    # 检查本地 runtime/rc.mynet 脚本
    if [ -f "$script_dir/runtime/rc.mynet" ]; then
        print_info "使用本地 runtime/rc.mynet 脚本"
        cp "$script_dir/runtime/rc.mynet" "/etc/init.d/mynet"
        chmod +x "/etc/init.d/mynet"
        return 0
    fi

    # 如果有在线版本，可以在这里添加下载逻辑
    # wget -O /etc/init.d/mynet https://raw.githubusercontent.com/.../rc.mynet

    print_error "未找到 MyNet 服务脚本"
    print_info "请确保 rc.mynet 脚本在同一目录"
    return 1
}

# 配置网络接口（为防火墙zone准备，但不启用自动启动）
# 参数: $1 - 接口名称（逻辑接口，如 mynet）
#      $2 - 设备名称（物理/虚拟设备，如 gnb_tun, wg0）
configure_network_interface() {
    local interface_name="$1"
    local device_name="$2"

    if [ -z "$interface_name" ]; then
        print_error "configure_network_interface: 缺少接口名称参数"
        return 1
    fi

    if [ -z "$device_name" ]; then
        print_error "configure_network_interface: 缺少设备名称参数"
        return 1
    fi

    print_info "配置网络接口: $interface_name (device: $device_name)"

    # 检查设备是否已被其他接口使用
    local i=0
    while uci get "network.@interface[$i]" >/dev/null 2>&1; do
        local existing_device=$(uci get "network.@interface[$i].device" 2>/dev/null)
        local existing_ifname=$(uci get "network.@interface[$i].ifname" 2>/dev/null)
        local existing_name=$(uci get "network.@interface[$i].name" 2>/dev/null)

        # 跳过自己
        if [ "$existing_name" != "$interface_name" ]; then
            # 检查是否有其他接口使用了这个设备
            if [ "$existing_device" = "$device_name" ] || [ "$existing_ifname" = "$device_name" ]; then
                print_warn "设备 $device_name 已被接口 $existing_name 使用，跳过配置"
                return 0
            fi
        fi
        i=$((i + 1))
    done

    # 检查接口是否已存在
    if uci get "network.$interface_name" >/dev/null 2>&1; then
        print_info "网络接口 $interface_name 已存在，更新设备配置"

        # 检查设备是否需要更新
        local current_device=$(uci get "network.$interface_name.device" 2>/dev/null)
        local current_ifname=$(uci get "network.$interface_name.ifname" 2>/dev/null)
        local need_restart=0

        if [ "$current_device" != "$device_name" ] || [ "$current_ifname" != "$device_name" ]; then
            print_info "设备配置需要更新: $current_device -> $device_name"
            uci set "network.$interface_name.device=$device_name"
            uci set "network.$interface_name.ifname=$device_name"
            need_restart=1
        fi

        uci set "network.$interface_name.auto=0"
        uci commit network

        if [ $need_restart -eq 1 ]; then
            print_warn "⚠️  设备配置已更新，但未立即应用（避免网络中断）"
            print_info "   推荐：安装完成后重启设备以应用变更"
            print_info "   或者：如果通过 LAN 连接，可手动执行 /etc/init.d/network restart"
        fi

        print_info "网络接口 $interface_name 更新完成"
        return 0
    fi

    print_info "创建 $interface_name 网络接口..."
    print_info "  - 接口名称: $interface_name"
    print_info "  - 物理设备: $device_name"
    print_info "  - 接口类型: none (不自动配置IP)"
    print_info "  - 自动启动: 禁用（由VPN服务管理）"

    # 创建网络接口配置
    uci set "network.$interface_name=interface"
    uci set "network.$interface_name.proto=none"

    # OpenWrt 版本兼容性配置
    # 新版 OpenWrt (21.02+): 使用 device 参数
    # 旧版 OpenWrt (19.07-): 使用 ifname 参数
    # 对于虚拟接口（如 gnb_tun, wg0），两个版本都使用 ifname
    # 为了最大兼容性，同时设置两个参数
    uci set "network.$interface_name.device=$device_name"   # 新版 OpenWrt
    uci set "network.$interface_name.ifname=$device_name"   # 旧版 OpenWrt + 虚拟接口

    uci set "network.$interface_name.auto=0"
    uci commit network

    print_info "网络接口配置完成（已设置 device 和 ifname 以兼容新旧版本）"

    # 注意：不在安装阶段重启网络服务
    # 原因：
    #   1. 会导致所有网络接口（WAN/LAN）重启，SSH 连接中断
    #   2. 可能导致安装脚本执行不完整
    #   3. 接口已配置 auto=0，不会自动启动
    #   4. VPN 服务启动时会自己创建设备，防火墙会自动关联
    #
    # 配置将在以下情况生效：
    #   - 设备重启后（推荐）
    #   - 手动执行 /etc/init.d/network restart（仅限 LAN 连接）
    print_info "⚠️  网络接口配置已保存，但需要重启网络服务才能完全生效"
    print_info "   推荐：安装完成后重启设备"
    print_info "   或者：如果通过 LAN 连接，可以手动执行 /etc/init.d/network restart"

    return 0
}

# 部署防火墙模块
# 参数: $1 - 目标脚本目录路径
deploy_firewall_module() {
    local target_script_dir="$1"

    if [ -z "$target_script_dir" ]; then
        print_error "deploy_firewall_module: 缺少目标脚本目录参数"
        return 1
    fi

    print_info "部署防火墙模块到: $target_script_dir"

    local script_dir="$(dirname "$0")"

    # 创建脚本目录
    mkdir -p "$target_script_dir"

    # 检查本地 runtime/firewall.mynet 脚本
    if [ -f "$script_dir/runtime/firewall.mynet" ]; then
        print_info "使用本地 runtime/firewall.mynet 脚本"
        cp "$script_dir/runtime/firewall.mynet" "$target_script_dir/"
        chmod +x "$target_script_dir/firewall.mynet"
        print_info "防火墙模块部署到 $target_script_dir/firewall.mynet"
    else
        print_warn "未找到 runtime/firewall.mynet 脚本"
    fi

    # 部署 runtime/route.mynet 脚本
    if [ -f "$script_dir/runtime/route.mynet" ]; then
        print_info "使用本地 runtime/route.mynet 脚本"
        cp "$script_dir/runtime/route.mynet" "$target_script_dir/"
        chmod +x "$target_script_dir/route.mynet"
        print_info "路由脚本部署到 $target_script_dir/route.mynet"
    else
        print_warn "未找到 runtime/route.mynet 脚本"
    fi

    return 0
}

# 根据 VPN 类型获取接口名称
# 这是一个纯计算函数，不依赖任何外部状态
# 参数: $1 - VPN 类型 (gnb/wireguard)
#      $2 - 节点 ID（wireguard 需要）
# 返回: 接口名称字符串
get_vpn_interface_name() {
    local vpn_type="$1"
    local node_id="$2"

    case "$vpn_type" in
        gnb)
            echo "gnb_tun"
            ;;
        wireguard)
            echo "wg_${node_id}"
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
    return 0
}

# 生成配置文件
# 不返回任何值，配置文件生成后由调用方自己计算接口名
generate_config_files() {
    print_info "生成配置文件..."

    # 使用 MYNET_HOME 下的 conf 目录作为模板源
    local template_dir="$MYNET_HOME/conf/_src/templates"
    local conf_dir="$MYNET_HOME/conf"

    # 创建配置目录结构
    mkdir -p "$conf_dir"
    mkdir -p "$MYNET_HOME"

    # 检查 mynet.conf 是否已存在（由 TUI 生成）
    local mynet_conf="$conf_dir/mynet.conf"
    local route_conf="$conf_dir/route.conf"

    if [ -f "$mynet_conf" ] && [ -f "$route_conf" ]; then
        print_info "✓ 检测到已存在的配置文件，跳过自动生成"
        print_info "  配置文件: $mynet_conf"
        print_info "  路由配置: $route_conf"
        print_info "  （注意：TUI 已在安装前验证配置文件内容）"
        return 0
    fi

    # 配置文件不存在，使用模板生成（兜底机制）
    print_info "配置文件不存在，使用模板生成..."

    # 生成路由配置文件
    generate_route_config "$template_dir" "$conf_dir"

    # 生成 MyNet 配置文件（包含 VPN 配置）
    generate_mynet_config "$template_dir" "$conf_dir"

    return 0
}

# 生成主配置文件（使用动态路径，不硬编码）
generate_main_config() {
    local template_dir="$1"
    local template_file="$template_dir/mynet.conf"
    local config_file="$MYNET_HOME/mynet.conf"

    print_info "生成主配置文件: $config_file"

    if [ -f "$template_file" ]; then
        print_info "使用模板生成主配置: $template_file"
        # 替换模板中的路径变量（使用双花括号匹配模板格式）
        sed -e "s|{{MYNET_HOME}}|$MYNET_HOME|g" \
            "$template_file" > "$config_file"
    else
        print_info "生成默认主配置（模板不存在）"
        cat > "$config_file" << EOF
# MyNet 主配置文件（自动生成）
# 生成时间: $(date)
# 基于检测到的路径配置

# 基础配置
ROUTER_MODE=auto
VPN_ZONE=mynet
LAN_INTERFACE=br-lan
WAN_INTERFACE=wan

# 路径配置
MYNET_HOME=$MYNET_HOME

# 日志配置
LOG_LEVEL=INFO
LOG_FILE=/var/log/mynet.log
DEBUG=0

# 服务配置
STARTUP_DELAY=0
INTERFACE_TIMEOUT=30
VPN_STARTUP_TIMEOUT=60

# 防火墙配置
FIREWALL_VERSION=auto
ENABLE_MASQUERADE=auto

# 网络配置
ENABLE_IPV6=auto
MTU_SIZE=1420

# 性能配置
ENABLE_FASTPATH=auto
ENABLE_FLOW_OFFLOAD=auto
EOF
    fi

    # 设置配置文件权限
    chmod 644 "$config_file"

    print_info "主配置文件已生成: $config_file"
    print_info "  MYNET_HOME: $MYNET_HOME"
}

# 生成 MyNet 配置文件（基于 vpn_type 和 nodeId 参数，使用动态路径）
generate_mynet_config() {
    local template_dir="$1"
    local conf_dir="$2"
    local template_file="$template_dir/mynet.conf.template"
    local config_file="$conf_dir/mynet.conf"

    print_info "生成 MyNet 配置 (VPN: $VPN_TYPE, Node: $NODE_ID): $config_file"

    # 根据参数和检测到的路径生成配置值
    local vpn_interface=""
    local vpn_driver_dir=""
    local vpn_config_dir=""
    local start_cmd=""
    local stop_cmd=""
    local pid_file=""
    local route_config=""
    local gnb_config_dir=""

    # 通用变量
    local platform="openwrt"
    local router_mode="auto"
    local node_ip="auto"  # IP 由 VPN 动态分配

    case "$VPN_TYPE" in
        gnb)
            vpn_interface="gnb_tun"
            vpn_driver_dir="$GNB_DRIVER_PATH"
            vpn_config_dir="$MYNET_HOME/driver/gnb/conf/${NODE_ID}"
            gnb_config_dir="$MYNET_HOME/driver/gnb/conf/${NODE_ID}"

            # GNB 启动命令：必须使用 MYNET_HOME 下的二进制路径
            local gnb_binary="$GNB_DRIVER_PATH/bin/gnb"
            if [ ! -f "$gnb_binary" ]; then
                print_error "未找到 GNB 二进制文件: $gnb_binary" >&2
                print_error "请确保 GNB 已安装到 $GNB_DRIVER_PATH/bin/gnb" >&2
                return 1
            fi
            start_cmd="$gnb_binary -c $MYNET_HOME/driver/gnb/conf/${NODE_ID}"
            stop_cmd="killall gnb"
            pid_file="$MYNET_HOME/driver/gnb/conf/${NODE_ID}/gnb.pid"
            route_config="$MYNET_HOME/driver/gnb/conf/${NODE_ID}/route.conf"
            ;;
        wireguard)
            vpn_interface="wg_${NODE_ID}"
            vpn_driver_dir="$WG_DRIVER_PATH"
            vpn_config_dir="$MYNET_HOME/driver/wireguard/${NODE_ID}"
            start_cmd="wg-quick up wg_${NODE_ID}"
            stop_cmd="wg-quick down wg_${NODE_ID}"
            pid_file="/var/run/wg-wg_${NODE_ID}.pid"
            route_config="$MYNET_HOME/driver/wireguard/${NODE_ID}/route.conf"
            ;;
    esac

    if [ -f "$template_file" ]; then
        print_info "使用模板生成配置: $template_file"
        # 使用 sed 替换模板中的占位符（使用双花括号匹配模板格式）
        sed -e "s|{{MYNET_HOME}}|$MYNET_HOME|g" \
            -e "s|{{PLATFORM}}|$platform|g" \
            -e "s|{{ROUTER_MODE}}|$router_mode|g" \
            -e "s|{{NODE_IP}}|$node_ip|g" \
            -e "s|{{VPN_TYPE}}|$VPN_TYPE|g" \
            -e "s|{{NODE_ID}}|$NODE_ID|g" \
            -e "s|{{VPN_INTERFACE}}|$vpn_interface|g" \
            -e "s|{{VPN_DRIVER_DIR}}|$vpn_driver_dir|g" \
            -e "s|{{VPN_CONFIG_DIR}}|$vpn_config_dir|g" \
            -e "s|{{VPN_PID_FILE}}|$pid_file|g" \
            -e "s|{{ROUTE_CONFIG}}|$route_config|g" \
            -e "s|{{GNB_BIN}}|$gnb_binary|g" \
            -e "s|{{GNB_CONF}}|$vpn_config_dir|g" \
            -e "s|{{VPN_BINARY}}|$gnb_binary|g" \
            -e "s|{{VPN_CONFIG}}|$vpn_config_dir|g" \
            "$template_file" > "$config_file"
    else
        print_info "生成默认配置（模板不存在）"
        cat > "$config_file" << EOF
# MyNet 配置文件（基于参数生成）
# VPN 类型: $VPN_TYPE, 节点 ID: $NODE_ID
# 生成时间: $(date)

# 基础配置
ROUTER_MODE=auto
VPN_ZONE=mynet

# VPN 类型配置
VPN_TYPE=$VPN_TYPE
NODE_ID=$NODE_ID
VPN_INTERFACE=$vpn_interface

# GNB 配置（VPN_TYPE=gnb 时使用）
GNB_BIN=$gnb_binary
GNB_CONF=$vpn_config_dir
VPN_PID_FILE=$pid_file

# WireGuard 配置（VPN_TYPE=wireguard 时使用）
# 通过 netifd 管理，使用 VPN_INTERFACE

# 自定义 VPN 配置（VPN_TYPE=custom 时使用）
# VPN_START_CMD="自定义启动命令"
# VPN_STOP_CMD="自定义停止命令"

# 路径配置
MYNET_HOME=$MYNET_HOME
VPN_DRIVER_DIR=$vpn_driver_dir
VPN_CONFIG_DIR=$vpn_config_dir
ROUTE_CONFIG=$route_config

# Procd 重启配置（仅 GNB）
RESPAWN_THRESHOLD=3600
RESPAWN_TIMEOUT=5
RESPAWN_RETRY=5

# 接口管理
PRECREATE_INTERFACE=1
KEEP_INTERFACE_DOWN=1
REUSE_EXISTING_INTERFACE=1

# 网络配置
NETWORK_CONFIG_ENABLED=1
AUTO_ROUTE_SETUP=1
ROUTE_TABLE_ID=100
ROUTE_PRIORITY=1000

# 监控配置
HEALTH_CHECK_ENABLED=1
HEALTH_CHECK_INTERVAL=60
VPN_TIMEOUT=30

# 服务配置
AUTO_START=1
RELOAD_CONFIG_ON_CHANGE=1
CLEANUP_ON_STOP=1

# 路由处理配置
ROUTE_HANDLER="route.mynet"  # 使用 route.mynet 处理路由配置
ROUTE_CONFIG_FORMAT="standard" # 路由配置格式：standard (network via gateway dev interface)
ENABLE_ROUTE_SCRIPT=1     # 启用外部路由脚本处理
EOF
    fi

    # 设置配置文件权限
    chmod 644 "$config_file"

    print_info "MyNet 配置文件已生成: $config_file"
    print_info "  VPN 接口: $vpn_interface"
    print_info "  配置目录: $vpn_config_dir"
    print_info "  路由配置: $route_config"

    return 0
}



# 生成路由配置文件（标准 ip route 格式，可被 route.mynet 处理）
generate_route_config() {
    local template_dir="$1"
    local conf_dir="$2"
    local template_file="$template_dir/route.conf.template"
    local config_file="$conf_dir/route.conf"

    print_info "生成路由配置: $config_file"

    if [ -f "$template_file" ]; then
        print_info "使用模板生成路由配置: $template_file"
        # 替换模板中的变量（使用双花括号匹配模板格式）
        sed -e "s|{{NODE_ID}}|$NODE_ID|g" \
            -e "s|{{VPN_TYPE}}|$VPN_TYPE|g" \
            "$template_file" > "$config_file"
    else
        print_info "生成默认配置（模板不存在）"
        cat > "$config_file" << EOF
# MyNet Route Configuration
# Generated at: $(date '+%Y-%m-%d %H:%M:%S')
# Node: Node-$NODE_ID
# Format: network via gateway dev interface (标准 ip route 格式)

# 其他节点路由示例（请根据实际网络配置修改）
# Node 7175750762685433 network via 10.244.123.193
# 192.168.6.0/24 via 10.244.123.193 dev tun0
# 8.8.8.0/24 via 10.244.123.193 dev tun0

# Gateway route to Node 1436307089532408 VPN IP
# 10.244.123.192/32 via 10.244.124.194 dev tun0

# Node 2261477463971569 network via 10.244.124.190
# 1.1.1.0/24 via 10.244.124.190 dev tun0
# 192.168.5.0/24 via 10.244.124.190 dev tun0

# 注意：
# 1. 每行一条路由记录
# 2. 格式：network via gateway dev interface
# 3. 标准 ip route 命令格式，直接可执行
# 4. 由 route.mynet 脚本处理
EOF
    fi

    # 设置配置文件权限
    chmod 644 "$config_file"

    print_info "路由配置文件已生成: $config_file"
    print_info "  格式: network via gateway dev interface (标准格式)"
    print_info "  可被 route.mynet 处理应用路由规则"
    print_info "  init.d 服务可调用 route.mynet 处理此文件"
}

# 部署 MyNet 服务
deploy_service() {
    print_info "开始部署 MyNet 服务到 OpenWrt..."

    # 动态检测 MyNet 路径配置
    detect_mynet_paths

    print_info "检测到的路径配置:"
    print_info "  MYNET_HOME: $MYNET_HOME"
    print_info "  GNB驱动: $GNB_DRIVER_PATH"
    print_info "  WireGuard驱动: $WG_DRIVER_PATH"

    # 检查环境
    if ! check_environment; then
        return 1
    fi

    # === 第一步：加载配置文件（整个脚本的基础） ===
    local mynet_conf="$MYNET_HOME/conf/mynet.conf"

    if [ -f "$mynet_conf" ]; then
        # TUI 已经生成配置，直接加载
        print_info "✓ 检测到配置文件: $mynet_conf"
        . "$mynet_conf"
    else
        # 配置文件不存在，兜底生成
        print_info "配置文件不存在，使用兜底方案生成配置..."

        # 创建配置目录
        mkdir -p "$MYNET_HOME/conf"

        # 生成配置文件
        if ! generate_config_files; then
            print_error "配置文件生成失败"
            return 1
        fi

        # 加载刚生成的配置
        . "$mynet_conf"
    fi

    # 复制平台特定的命令配置文件
    print_info "设置命令映射配置..."
    local command_json="$MYNET_HOME/conf/command.json"
    local command_openwrt_json="$MYNET_HOME/conf/_src/platforms/command.openwrt.json"

    if [ -f "$command_openwrt_json" ]; then
        # 如果 command.json 不存在或与 command.openwrt.json 内容不同，则复制
        if [ ! -f "$command_json" ] || ! cmp -s "$command_openwrt_json" "$command_json" 2>/dev/null; then
            cp "$command_openwrt_json" "$command_json"
            print_success "已从 command.openwrt.json 复制到 command.json"
        else
            print_info "✓ command.json 已是最新（无需更新）"
        fi
    else
        print_warn "⚠️ 未找到 command.openwrt.json，命令映射功能可能不可用"
    fi

    # 验证配置文件中的关键变量
    if [ -z "$VPN_INTERFACE" ]; then
        print_error "配置文件中缺少 VPN_INTERFACE，无法继续"
        return 1
    fi

    print_info "配置加载成功:"
    print_info "  VPN_TYPE: $VPN_TYPE"
    print_info "  VPN_INTERFACE: $VPN_INTERFACE"
    print_info "  NODE_ID: $NODE_ID"

    # 检查是否已部署
    if [ -f "/etc/init.d/mynet" ]; then
        if [ "$FORCE_MODE" = "1" ]; then
            print_info "强制模式：重新部署现有服务..."
        else
            print_warn "MyNet 服务已部署，是否重新部署? (y/N)"
            if [ "$AUTO_YES" = "1" ]; then
                print_info "自动回答：是"
                confirm="y"
            else
                read -r confirm
            fi
            case $confirm in
                [Yy]*)
                    print_info "重新部署..."
                    ;;
                *)
                    print_info "部署取消"
                    return 0
                    ;;
            esac
        fi
    fi

    # 创建必要的目录结构
    print_info "创建目录结构..."
    mkdir -p "$MYNET_HOME"

    if [ -n "$GNB_DRIVER_PATH" ]; then
        mkdir -p "$GNB_DRIVER_PATH"
    fi
    if [ -n "$WG_DRIVER_PATH" ]; then
        mkdir -p "$WG_DRIVER_PATH"
    fi

    mkdir -p "/etc/init.d"
    mkdir -p "/var/log"
    mkdir -p "/var/run"

    # 获取服务脚本
    if ! get_service_script; then
        return 1
    fi

    # 部署防火墙模块
    local target_script_dir="$MYNET_HOME/scripts"
    if ! deploy_firewall_module "$target_script_dir"; then
        print_warn "防火墙模块部署失败，服务将使用备用防火墙方法"
    fi

    # 配置网络接口
    # 接口名称固定为 mynet，设备名称从配置中获取（VPN_INTERFACE）
    configure_network_interface "mynet" "$VPN_INTERFACE"

    # 安装防火墙配置（新架构：install 阶段创建 zone/forwarding/include）
    # NOTE: 必须在 configure_network_interface 之后调用，因为需要验证接口存在
    print_info "安装防火墙配置..."
    if [ -x "$target_script_dir/firewall.mynet" ]; then
        if sh "$target_script_dir/firewall.mynet" install --interface "$VPN_INTERFACE"; then
            print_info "✓ 防火墙配置安装成功"
            print_info "  - 验证 network.mynet 接口存在"
            print_info "  - 创建 zone mynet (LAN/WAN forwarding)"
            print_info "  - 创建 include 脚本 (NAT masq 持久化)"
        else
            print_warn "防火墙配置安装失败，服务启动时将尝试添加 masq 规则"
        fi
    else
        print_warn "firewall.mynet 脚本不存在，跳过防火墙安装"
    fi

    # 运行服务自带的安装器
    print_info "运行 MyNet 服务安装器..."
    if /etc/init.d/mynet install; then
        print_info "MyNet 服务部署成功！"

        # 自动启用开机自启
        print_info "启用开机自启..."
        if /etc/init.d/mynet enable; then
            print_info "✓ 开机自启已启用（/etc/rc.d/S99mynet）"
        else
            print_warn "启用开机自启失败，请手动执行: /etc/init.d/mynet enable"
        fi

        echo
        print_info "=== 安装完成 ==="
        print_info "服务脚本: /etc/init.d/mynet"
        print_info "配置文件: $MYNET_HOME/mynet.conf"
        print_info "日志文件: /var/log/mynet.log"
        print_info "开机自启: 已启用（/etc/rc.d/S99mynet）"
        echo

        # 清理源文件
        cleanup_source_files

        print_warn "=== ⚠️  重要提示 ==="
        print_warn "网络接口配置已保存，但需要重启才能完全生效"
        print_warn ""
        print_warn "请根据当前连接方式选择操作："
        print_warn ""
        print_warn "  1. 通过 VPN/WAN/无线 SSH 连接："
        print_warn "     请重启设备（推荐，避免连接中断）"
        print_warn "     reboot"
        print_warn ""
        print_warn "  2. 通过 LAN 有线连接："
        print_warn "     可以重启网络服务（会短暂断网 1-2 秒）"
        print_warn "     /etc/init.d/network restart"
        print_warn ""
        print_warn "重启后，服务将自动启动（已启用开机自启）"
        echo
        print_info "=== 使用方法 ==="
        print_info "启动服务: /etc/init.d/mynet start"
        print_info "查看状态: /etc/init.d/mynet status"
        print_info "停止服务: /etc/init.d/mynet stop"
        print_info "重新加载: /etc/init.d/mynet reload"
        print_info "禁用开机启动: /etc/init.d/mynet disable"
        echo
        print_info "=== 架构特性 ==="
        print_info "✓ 零侵入：不修改 /etc/config/network 和 /etc/config/firewall"
        print_info "✓ 动态配置：运行时创建接口、防火墙规则、路由"
        print_info "✓ 自动检测：VPN 类型（GNB/WireGuard）和路由器模式"
        print_info "✓ 完全可逆：停止服务即清理所有动态配置"
        print_info "✓ 动态路径：自动检测 MyNet 安装路径，无硬编码"
        echo
        return 0
    else
        print_error "服务部署失败"
        return 1
    fi
}

# 移除网络接口配置
# 参数: $1 = interface_name (接口名称，如 "mynet")
remove_network_interface() {
    local interface_name="$1"

    if [ -z "$interface_name" ]; then
        print_error "接口名称不能为空"
        return 1
    fi

    print_info "移除网络接口: $interface_name"

    # 检查接口是否存在
    if ! uci get "network.$interface_name" >/dev/null 2>&1; then
        print_info "网络接口 $interface_name 不存在，跳过"
        return 0
    fi

    # 删除接口配置
    uci delete "network.$interface_name"
    uci commit network

    print_info "⚠️  网络接口配置已删除，但未立即应用（避免网络中断）"
    print_info "   将在卸载完成后提示重启操作"

    return 0
}

# 移除 MyNet 服务
remove_service() {
    print_info "开始移除 MyNet 服务..."

    if [ ! -f "/etc/init.d/mynet" ]; then
        print_warn "MyNet 服务未部署"
        return 0
    fi

    if [ "$FORCE_MODE" = "1" ]; then
        print_info "强制模式：直接移除 MyNet 服务..."
    else
        print_warn "确认移除 MyNet 服务? 这将："
        print_warn "- 停止 MyNet 服务"
        print_warn "- 删除服务脚本"
        print_warn "- 删除配置文件"
        print_warn "- 清理所有动态规则"
        echo
        printf "继续移除? (y/N): "

        if [ "$AUTO_YES" = "1" ]; then
            print_info "自动回答：是"
            confirm="y"
        else
            read -r confirm
        fi

        case $confirm in
            [Yy]*)
                ;;
            *)
                print_info "移除取消"
                return 0
                ;;
        esac
    fi

    # 停止服务
    print_info "停止 MyNet 服务..."
    /etc/init.d/mynet stop 2>/dev/null || true

    # 禁用服务
    print_info "禁用 MyNet 服务..."
    /etc/init.d/mynet disable 2>/dev/null || true

    # 卸载防火墙配置（只清理 zone、forwarding、include，不删除网络接口）
    print_info "卸载防火墙配置..."
    local firewall_script="$MYNET_HOME/runtime/firewall.mynet"
    if [ -x "$firewall_script" ]; then
        if "$firewall_script" uninstall; then
            print_info "✓ 防火墙配置卸载成功"
            print_info "  - 已清理 zone mynet 配置"
            print_info "  - 已删除 include 脚本"
        else
            print_warn "防火墙配置卸载失败，部分配置可能残留"
        fi
    else
        print_warn "firewall.mynet 脚本不存在，跳过防火墙卸载"
    fi

    # 移除网络接口（由 service-manager 负责，与 configure_network_interface 对称）
    print_info "移除网络接口..."
    remove_network_interface "mynet"

    # 删除服务脚本
    print_info "删除服务脚本..."
    rm -f "/etc/init.d/mynet"

    # 删除日志文件
    print_info "删除日志文件..."
    rm -f "/var/log/mynet.log"

    # 清理可能残留的源文件目录
    print_info "检查并清理残留文件..."
    if [ -d "$MYNET_HOME/conf/_src" ]; then
        rm -rf "$MYNET_HOME/conf/_src"
        print_info "✓ 已清理 conf/_src/"
    fi
    if [ -d "$MYNET_HOME/scripts/_src" ]; then
        rm -rf "$MYNET_HOME/scripts/_src"
        print_info "✓ 已清理 scripts/_src/"
    fi

    echo
    print_info "=== 卸载完成 ==="
    print_info "MyNet 服务已成功卸载"
    echo
    print_warn "=== ⚠️  重要提示 ==="
    print_warn "网络接口配置已删除，但需要重启才能完全生效"
    print_warn ""
    print_warn "推荐操作（根据连接方式选择）："
    print_warn ""
    print_warn "  1. 通过 VPN/WAN/无线 SSH 连接："
    print_warn "     请重启设备（避免连接中断）"
    print_warn "     reboot"
    print_warn ""
    print_warn "  2. 通过 LAN 有线连接："
    print_warn "     可以重启网络服务（会短暂断网 1-2 秒）"
    print_warn "     /etc/init.d/network restart"
    print_warn ""
    print_warn "  3. 如果要重新安装："
    print_warn "     建议先重启设备，再执行安装"
    echo
    return 0
}

# 启动服务
start_service() {
    if [ ! -f "/etc/init.d/mynet" ]; then
        print_error "MyNet 服务未安装"
        return 1
    fi

    print_info "启动 MyNet 服务..."
    if /etc/init.d/mynet start; then
        print_info "MyNet 服务启动成功"
        return 0
    else
        print_error "MyNet 服务启动失败"
        return 1
    fi
}

# 停止服务
stop_service() {
    if [ ! -f "/etc/init.d/mynet" ]; then
        print_error "MyNet 服务未安装"
        return 1
    fi

    print_info "停止 MyNet 服务..."
    if /etc/init.d/mynet stop; then
        print_info "MyNet 服务停止成功"
        return 0
    else
        print_error "MyNet 服务停止失败"
        return 1
    fi
}

# 重启服务
restart_service() {
    if [ ! -f "/etc/init.d/mynet" ]; then
        print_error "MyNet 服务未安装"
        return 1
    fi

    print_info "重启 MyNet 服务..."
    if /etc/init.d/mynet restart; then
        print_info "MyNet 服务重启成功"
        return 0
    else
        print_error "MyNet 服务重启失败"
        return 1
    fi
}

# 启用开机自启
enable_service() {
    if [ ! -f "/etc/init.d/mynet" ]; then
        print_error "MyNet 服务未安装"
        return 1
    fi

    print_info "启用 MyNet 服务开机自启..."
    if /etc/init.d/mynet enable; then
        print_info "MyNet 服务开机自启已启用"
        return 0
    else
        print_error "启用开机自启失败"
        return 1
    fi
}

# 禁用开机自启
disable_service() {
    if [ ! -f "/etc/init.d/mynet" ]; then
        print_error "MyNet 服务未安装"
        return 1
    fi

    print_info "禁用 MyNet 服务开机自启..."
    if /etc/init.d/mynet disable; then
        print_info "MyNet 服务开机自启已禁用"
        return 0
    else
        print_error "禁用开机自启失败"
        return 1
    fi
}

# 升级服务（重新安装）
upgrade_service() {
    if [ ! -f "/etc/init.d/mynet" ]; then
        print_error "MyNet 服务未安装，无法升级"
        return 1
    fi

    print_info "升级 MyNet 服务..."
    print_info "升级过程将重新部署服务脚本和配置"

    if [ "$FORCE_MODE" != "1" ]; then
        printf "确认升级 MyNet 服务? (y/N): "
        if [ "$AUTO_YES" = "1" ]; then
            print_info "自动回答：是"
            confirm="y"
        else
            read -r confirm
        fi

        case $confirm in
            [Yy]*) ;;
            *) print_info "升级取消"; return 0 ;;
        esac
    fi

    # 保存当前配置
    local backup_dir="/tmp/mynet-upgrade-backup-$$"
    mkdir -p "$backup_dir"

    if [ -d "$MYNET_HOME" ]; then
        print_info "备份当前配置到 $backup_dir"
        cp -r "$MYNET_HOME" "$backup_dir/"
    fi

    # 停止服务但不删除配置
    print_info "停止服务以进行升级..."
    /etc/init.d/mynet stop 2>/dev/null || true

    # 重新获取服务脚本
    if ! get_service_script; then
        print_error "获取新服务脚本失败"
        return 1
    fi

    # 运行服务安装器
    print_info "运行服务升级..."
    if /etc/init.d/mynet install; then
        print_info "MyNet 服务升级成功"
        print_info "配置备份保存在: $backup_dir"
        return 0
    else
        print_error "MyNet 服务升级失败"
        return 1
    fi
}

# 主程序
main() {
    print_info "=== MyNet OpenWrt 服务管理器 v$VERSION ==="
    print_info "OpenWrt 平台服务生命周期管理工具"
    echo

    # 解析命令行参数
    parse_arguments "$@"

    # 如果没有指定命令，显示交互式菜单
    if [ -z "$COMMAND" ]; then
        print_info "=== MyNet OpenWrt 服务管理器 ==="
        echo
        echo "请选择操作："
        echo "1) 安装 MyNet 服务（需要指定 VPN 类型和节点 ID）"
        echo "2) 检查服务状态"
        echo "3) 卸载 MyNet 服务"
        echo "4) 启动服务"
        echo "5) 停止服务"
        echo "6) 重启服务"
        echo "7) 启用开机自启"
        echo "8) 禁用开机自启"
        echo "9) 升级服务"
        echo "10) 显示帮助"
        echo "11) 退出"
        echo
        printf "请输入选择 (1-11): "
        read -r choice

        case $choice in
            1)
                # 交互式收集参数
                echo
                printf "请输入 VPN 类型 (gnb/wireguard): "
                read -r VPN_TYPE
                printf "请输入节点 ID (16位数字): "
                read -r NODE_ID

                # 验证参数
                case "$VPN_TYPE" in
                    gnb|wireguard) ;;
                    *) print_error "无效的 VPN 类型: $VPN_TYPE"; exit 1 ;;
                esac

                if ! echo "$NODE_ID" | grep -q '^[0-9]\{16\}$'; then
                    print_error "节点 ID 格式错误: $NODE_ID (必须是16位数字)"
                    exit 1
                fi

                print_info "配置参数 - VPN 类型: $VPN_TYPE, 节点 ID: $NODE_ID"
                COMMAND="install"
                ;;
            2) COMMAND="status" ;;
            3) COMMAND="uninstall" ;;
            4) COMMAND="start" ;;
            5) COMMAND="stop" ;;
            6) COMMAND="restart" ;;
            7) COMMAND="enable" ;;
            8) COMMAND="disable" ;;
            9) COMMAND="upgrade" ;;
            10) show_help; exit 0 ;;
            11) exit 0 ;;
            *) print_error "无效选择"; exit 1 ;;
        esac
    fi

    # 根据命令执行相应操作
    case "$COMMAND" in
        install)
            deploy_service
            ;;
        uninstall)
            remove_service
            ;;
        status)
            check_service_status
            ;;
        start)
            start_service
            ;;
        stop)
            stop_service
            ;;
        restart)
            restart_service
            ;;
        enable)
            enable_service
            ;;
        disable)
            disable_service
            ;;
        upgrade)
            upgrade_service
            ;;
        *)
            print_error "未知命令: $COMMAND"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
