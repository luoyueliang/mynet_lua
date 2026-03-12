#!/bin/bash
#
# mynet_proxy 增强安装脚本
#
# 用法:
#   ./install.sh install      # 智能安装（包含配置向导）
#   ./install.sh uninstall    # 卸载
#   ./install.sh reinstall    # 重新安装
#   ./install.sh status       # 查看状态

set -e

# 检查 root/sudo 权限
check_root_permission() {
    if [[ $EUID -ne 0 ]]; then
        echo "错误: 此脚本需要 root 权限"
        echo "请使用 sudo 运行:"
        echo "  sudo $0 $*"
        exit 1
    fi
}

# 仅在 install/uninstall/reinstall 时检查权限
case "${1:-}" in
    install|uninstall|reinstall)
        check_root_permission
        ;;
esac

# 项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 检测是在源代码目录还是打包后的目录
if [[ -f "$SCRIPT_DIR/../scripts/proxy/build.sh" ]]; then
    # 在源代码目录 (scripts/proxy/install.sh)
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
    # 在打包后的目录 (mynet_proxy/install.sh)
    PROJECT_ROOT="$SCRIPT_DIR"
fi

# 配置
BINARY_NAME="mynet_proxy"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_step() {
    echo -e "${CYAN}[→]${NC} $1"
}

# 检测平台
detect_platform() {
    local os=$(uname -s | tr 'A-Z' 'a-z')

    case "$os" in
        linux)
            if [[ -f "/etc/openwrt_release" ]] || [[ -f "/etc/opkg.conf" ]]; then
                echo "openwrt"
            else
                echo "linux"
            fi
            ;;
        darwin) echo "darwin" ;;
        *) echo "unknown" ;;
    esac
}

# 查找 mynet 安装目录
find_mynet_home() {
    local platform=$(detect_platform)
    local paths_to_check=()

    # 根据平台确定默认路径
    case "$platform" in
        "openwrt")
            paths_to_check=("/etc/mynet")
            ;;
        "linux")
            paths_to_check=("/usr/local/mynet" "/opt/mynet")
            ;;
        "darwin")
            paths_to_check=("/usr/local/opt/mynet" "/usr/local/mynet" "/opt/mynet")
            ;;
        *)
            paths_to_check=("/opt/mynet" "/usr/local/mynet")
            ;;
    esac

    # 如果设置了 MYNET_HOME 环境变量，优先检查
    if [[ -n "${MYNET_HOME:-}" ]]; then
        paths_to_check=("$MYNET_HOME" "${paths_to_check[@]}")
    fi

    # 遍历可能的路径
    for path in "${paths_to_check[@]}"; do
        if [[ -f "$path/conf/mynet.conf" ]]; then
            echo "$path"
            return 0
        fi
    done

    # 尝试通过 which 命令查找 mynet
    if command -v mynet >/dev/null 2>&1; then
        local mynet_bin=$(which mynet)
        local mynet_dir=$(dirname "$(dirname "$(readlink -f "$mynet_bin" 2>/dev/null || echo "$mynet_bin")")")
        if [[ -f "$mynet_dir/conf/mynet.conf" ]]; then
            echo "$mynet_dir"
            return 0
        fi
    fi

    return 1
}

# 检查 GNB 服务状态
check_gnb_service() {
    local mynet_home="$1"

    log_step "检查 GNB 服务状态..."

    # 检查 gnb 进程
    if pgrep -x gnb >/dev/null 2>&1; then
        log_success "GNB 服务正在运行"
        return 0
    elif pgrep -f "gnb.*gnb.conf" >/dev/null 2>&1; then
        log_success "GNB 服务正在运行"
        return 0
    else
        log_warning "GNB 服务未运行"
        echo ""
        read -p "是否继续安装? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "安装已取消"
            exit 1
        fi
        return 1
    fi
}

# 从 mynet.conf 读取本地节点 ID（增强版）
get_local_node_id() {
    local mynet_home="$1"
    local node_id=""

    # 方法 1: 从 mynet.conf 读取
    local conf_file="$mynet_home/conf/mynet.conf"
    if [[ -f "$conf_file" ]]; then
        node_id=$(grep -E "^local_node_id|^node_id|^local_uuid" "$conf_file" 2>/dev/null | head -1 | awk -F'[=: ]' '{print $NF}' | tr -d ' "')
        if [[ -n "$node_id" && "$node_id" != "unknown" ]]; then
            echo "$node_id"
            return 0
        fi
    fi

    # 方法 2: 从 route.conf 路径推断（路径包含节点 ID）
    local route_dir="$mynet_home/driver/gnb/conf"
    if [[ -d "$route_dir" ]]; then
        for dir in "$route_dir"/*; do
            if [[ -d "$dir" && -f "$dir/route.conf" ]]; then
                node_id=$(basename "$dir")
                if [[ -n "$node_id" && "$node_id" != "unknown" ]]; then
                    echo "$node_id"
                    return 0
                fi
            fi
        done
    fi

    # 方法 3: 从运行的 gnb 进程参数提取
    if command -v pgrep >/dev/null 2>&1; then
        local gnb_pid=$(pgrep -x gnb | head -1)
        if [[ -n "$gnb_pid" ]]; then
            # 从 /proc/<pid>/cmdline 或 ps 命令提取
            if [[ -f "/proc/$gnb_pid/cmdline" ]]; then
                node_id=$(tr '\0' ' ' < "/proc/$gnb_pid/cmdline" | grep -oP '(?<=-n )\d+' | head -1)
            else
                # macOS 使用 ps
                node_id=$(ps -p "$gnb_pid" -o args= | grep -oE '\-n [0-9]+' | awk '{print $2}' | head -1)
            fi

            if [[ -n "$node_id" && "$node_id" != "unknown" ]]; then
                echo "$node_id"
                return 0
            fi
        fi
    fi

    return 1
}

# 查找可用的代理节点
find_available_nodes() {
    local mynet_home="$1"
    local local_node_id="$2"
    local route_dir="$mynet_home/driver/gnb/conf/$local_node_id"

    if [[ ! -d "$route_dir" ]]; then
        return 1
    fi

    # 从 route.conf 提取节点信息
    local route_file="$route_dir/route.conf"
    if [[ ! -f "$route_file" ]]; then
        return 1
    fi

    # 提取所有节点 ID 和 IP（跳过本地节点和注释）
    grep -v "^#" "$route_file" | grep -v "^$" | while IFS='|' read -r node_id ip netmask; do
        # 跳过本地节点
        if [[ "$node_id" == "$local_node_id" ]]; then
            continue
        fi

        # 输出格式：node_id|ip
        echo "$node_id|$ip"
    done | sort -u
}

# 交互式选择代理节点
select_proxy_node() {
    local mynet_home="$1"
    local local_node_id="$2"

    echo ""
    log_step "正在扫描可用的代理节点..."

    # 查找可用节点
    local nodes_file=$(mktemp)
    find_available_nodes "$mynet_home" "$local_node_id" > "$nodes_file"

    if [[ ! -s "$nodes_file" ]]; then
        rm -f "$nodes_file"
        log_error "未找到可用的代理节点"
        log_info "请确保:"
        log_info "  1. GNB 服务正在运行"
        log_info "  2. route.conf 中有其他节点配置"
        return 1
    fi

    # 自动选择第一个可用节点
    local selected=$(head -1 "$nodes_file")
    local total=$(wc -l < "$nodes_file" | tr -d ' ')

    IFS='|' read -r node_id ip <<< "$selected"

    log_success "发现 $total 个可用节点，自动选择第一个:"
    echo "  节点 ID: $node_id"
    echo "  VPN IP:  $ip"

    rm -f "$nodes_file"
    echo "$selected"
    return 0
}

# 生成 proxy_peers.conf
generate_proxy_peers_conf() {
    local mynet_home="$1"
    local proxy_node_id="$2"
    local proxy_vpn_ip="$3"
    local direction="${4:-outbound}"  # 默认 outbound

    local conf_file="$mynet_home/conf/proxy/proxy_peers.conf"

    # 根据方向选择 ip_list_file
    local ip_list_file
    case "$direction" in
        outbound)
            ip_list_file="proxy_outbound.txt"
            ;;
        inbound|both)
            ip_list_file="proxy_whitelist.txt"
            ;;
        *)
            ip_list_file="proxy_outbound.txt"
            ;;
    esac

    cat > "$conf_file" << EOF
# GNB 代理节点配置
# 格式：group_name|node_id|vpn_ip|ip_list_file|priority|status
#
# 注意：node_id 是远端代理节点的ID，不是本地节点

# 默认代理节点（方向: $direction）
default|${proxy_node_id}|${proxy_vpn_ip}|${ip_list_file}|1|active
EOF

    log_success "生成配置: $conf_file (使用 $ip_list_file)"
}

# 生成代理配置文件
generate_proxy_config() {
    local mynet_home="$1"

    log_step "生成代理配置文件..."

    # 设置 MYNET_HOME 环境变量
    export MYNET_HOME="$mynet_home"

    # 执行 config（生成 proxy_outbound.txt 和 proxy_whitelist.txt）
    if "$mynet_home/bin/$BINARY_NAME" config; then
        log_success "代理配置文件生成成功"

        # 显示生成的文件
        if [[ -f "$mynet_home/conf/proxy/proxy_outbound.txt" ]]; then
            local count=$(wc -l < "$mynet_home/conf/proxy/proxy_outbound.txt" 2>/dev/null || echo "0")
            log_info "  ✓ proxy_outbound.txt: $count 条"
        fi

        if [[ -f "$mynet_home/conf/proxy/proxy_whitelist.txt" ]]; then
            local count=$(wc -l < "$mynet_home/conf/proxy/proxy_whitelist.txt" 2>/dev/null || echo "0")
            log_info "  ✓ proxy_whitelist.txt: $count 条"
        fi

        return 0
    else
        log_error "代理配置文件生成失败"
        return 1
    fi
}

# 配置代理角色和方向（自动化版本）
configure_proxy_role() {
    local mynet_home="$1"

    echo ""
    log_step "步骤 5.5/6: 配置代理角色和方向"

    # 自动设置为 client + outbound（最常见场景：国内访问国外）
    local role_name="client"
    local proxy_direction="outbound"

    local role_conf="$mynet_home/conf/proxy/proxy_role.conf"
    cat > "$role_conf" << EOF
# MyNet Proxy 角色配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# 角色: client (发起方，通过代理访问远程网络)
PROXY_ROLE=$role_name

# 方向: outbound (访问国外资源)
PROXY_DIRECTION=$proxy_direction

# IP 列表源文件
PROXY_IP_SOURCES=interip.txt

# 启用代理
PROXY_ENABLED=true
EOF

    log_success "已自动配置:"
    log_success "  角色: $role_name (发起方)"
    log_success "  方向: $proxy_direction (访问国外)"

    # 返回方向值供后续使用
    echo "$proxy_direction"

    # 启用代理
    echo "PROXY_ENABLED=true" >> "$role_conf"

    echo ""
    log_success "角色配置已保存: $role_conf"
}

# 配置代理方向
configure_proxy_direction() {
    local mynet_home="$1"
    local role_name="$2"

    echo ""
    echo "════════════════════════════════════════════════"
    echo "  配置代理流量方向 (角色: $role_name)"
    echo "════════════════════════════════════════════════"
    echo ""
    echo "说明:"
    echo "  • 角色决定你是使用代理还是提供代理"
    echo "  • 方向决定代理什么流量"
    echo ""
    echo "  示例:"
    echo "    - 国内 client + outbound: 通过代理访问国外网站"
    echo "    - 国外 client + inbound:  通过代理访问国内资源"
    echo "    - 国外 server + outbound: 为他人提供访问国外的代理"
    echo "    - 国内 server + inbound:  为他人提供访问国内的代理"
    echo ""
    echo "请选择代理访问方向："
    echo ""
    echo "  1) 出站 (Outbound) - 访问国外资源"
    echo "     • 使用国际IP列表 (interip.txt)"
    echo "     • 适用于: Google, YouTube, GitHub, ChatGPT 等"
    echo ""
    echo "  2) 入站 (Inbound) - 访问国内资源"
    echo "     • 使用国内IP列表 (chinaip.txt)"
    echo "     • 适用于: 国内视频、音乐、购物网站等"
    echo ""
    echo "  3) 双向 (Both) - 同时支持出站和入站"
    echo "     • 同时使用国际IP和国内IP列表"
    echo "     • 适用于: 需要双向访问的场景"
    echo ""
    echo "  4) 不启用策略路由"
    echo "     • 仅转发流量，不做路由策略"
    echo "     • 适用于纯转发场景"
    echo ""
    echo "  5) 自定义"
    echo "     • 手动指定 IP 列表文件"
    echo ""

    local direction
    while true; do
        read -p "请选择 [1-5]: " direction
        case $direction in
            1|2|3|4|5) break ;;
            *) log_error "无效选择，请重新输入" ;;
        esac
    done

    local role_conf="$mynet_home/conf/proxy/proxy_role.conf"
    local ip_sources=""
    local direction_value=""

    case $direction in
        1)
            ip_sources="interip.txt"
            direction_value="outbound"
            echo "PROXY_DIRECTION=outbound" >> "$role_conf"
            log_success "方向: 出站 (Outbound)"
            ;;
        2)
            ip_sources="chinaip.txt"
            direction_value="inbound"
            echo "PROXY_DIRECTION=inbound" >> "$role_conf"
            log_success "方向: 入站 (Inbound)"
            ;;
        3)
            ip_sources="interip.txt,chinaip.txt"
            direction_value="both"
            echo "PROXY_DIRECTION=both" >> "$role_conf"
            log_success "方向: 双向 (Both)"
            ;;
        4)
            ip_sources="none"
            direction_value="none"
            echo "PROXY_DIRECTION=none" >> "$role_conf"
            log_success "方向: 不启用策略路由"
            ;;
        5)
            echo ""
            echo "可用的 IP 列表文件:"
            if [[ -d "$mynet_home/conf/proxy/proxy_sources" ]]; then
                ls -1 "$mynet_home/conf/proxy/proxy_sources/" 2>/dev/null || echo "  (目录为空)"
            fi
            echo ""
            read -p "请输入 IP 列表文件名 (多个用逗号分隔): " ip_sources
            direction_value="custom"
            echo "PROXY_DIRECTION=custom" >> "$role_conf"
            log_success "方向: 自定义 ($ip_sources)"
            ;;
    esac

    echo "PROXY_IP_SOURCES=$ip_sources" >> "$role_conf"

    # 返回 direction 值供后续使用
    echo "$direction_value"
}

# 配置 IP 转发
configure_ip_forward() {
    echo ""
    log_info "配置 IP 转发..."

    local platform=$(detect_platform)

    case $platform in
        linux|openwrt)
            # 检查当前状态
            local current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")

            if [[ "$current" == "0" ]]; then
                echo ""
                log_warning "IP 转发当前未启用"
                echo ""
                read -p "是否启用 IP 转发？[Y/n] " enable_forward

                if [[ "$enable_forward" != "n" && "$enable_forward" != "N" ]]; then
                    # 临时启用
                    sudo sysctl -w net.ipv4.ip_forward=1 2>/dev/null || log_warning "需要 root 权限"

                    # 永久启用
                    if [[ -f /etc/sysctl.conf ]]; then
                        if grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
                            sudo sed -i.bak 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf 2>/dev/null || true
                        else
                            echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf >/dev/null 2>&1 || true
                        fi
                    fi

                    log_success "IP 转发已启用"
                fi
            else
                log_success "IP 转发已启用"
            fi
            ;;
        darwin)
            echo ""
            log_info "macOS 平台，IP 转发需要手动配置"
            log_info "请参考: sudo sysctl -w net.inet.ip.forwarding=1"
            ;;
    esac
}

# 创建插件钩子软链接
create_plugin_hooks() {
    local mynet_home="$1"

    echo ""
    log_step "步骤 5.9/6: 创建插件钩子"

    local plugin_proxy_dir="$mynet_home/scripts/plugin/proxy"
    # hooks 在打包后的位置是 PROJECT_ROOT/scripts/hooks
    local hooks_dir="$PROJECT_ROOT/scripts/hooks"

    # 创建 plugin/proxy 目录
    mkdir -p "$plugin_proxy_dir"

    # 复制钩子脚本到目标目录
    local target_hooks_dir="$mynet_home/scripts/proxy/hooks"
    mkdir -p "$target_hooks_dir"

    # proxy 只需要 3 个钩子: pre_start, post_start, stop
    for hook in pre_start post_start stop; do
        local source="$hooks_dir/${hook}.sh"
        local target="$target_hooks_dir/${hook}.sh"
        local link="$plugin_proxy_dir/${hook}.sh"

        if [[ -f "$source" ]]; then
            # 复制实体文件
            cp -f "$source" "$target"
            chmod +x "$target"

            # 删除旧链接（如果存在）
            rm -f "$link"

            # 创建相对路径软链接
            # plugin/proxy/xxx.sh -> ../../proxy/hooks/xxx.sh
            (cd "$plugin_proxy_dir" && ln -sf "../../proxy/hooks/${hook}.sh" "${hook}.sh")

            log_success "  ✓ 创建钩子: ${hook}.sh"
        else
            log_warning "  ! 钩子文件不存在: $source"
        fi
    done

    log_success "插件钩子已创建"
}

# 主安装流程
install() {
    echo ""
    echo "========================================="
    echo "  MyNet Proxy 智能安装向导"
    echo "========================================="
    echo ""

    # 步骤 1: 查找 mynet 安装目录
    log_step "步骤 1/6: 查找 mynet 安装目录"

    local mynet_home=$(find_mynet_home)
    local platform=$(detect_platform)

    if [[ -z "$mynet_home" ]]; then
        log_warning "无法自动检测 mynet 安装目录"
        echo ""

        # 显示已检查的路径及其状态
        log_info "已检查以下默认路径:"
        local default_paths=()
        case "$platform" in
            "openwrt")
                default_paths=("/etc/mynet")
                ;;
            "linux")
                default_paths=("/usr/local/mynet" "/opt/mynet")
                ;;
            "darwin")
                default_paths=("/usr/local/opt/mynet" "/usr/local/mynet" "/opt/mynet")
                ;;
        esac

        for path in "${default_paths[@]}"; do
            if [[ -d "$path" ]]; then
                if [[ -f "$path/conf/mynet.conf" ]]; then
                    echo "  ✓ $path (有效)"
                else
                    echo "  ✗ $path (目录存在，但缺少 conf/mynet.conf)"
                fi
            else
                echo "  - $path (目录不存在)"
            fi
        done
        echo ""

        # 如果环境变量设置了但无效
        if [[ -n "${MYNET_HOME:-}" ]]; then
            log_warning "环境变量 MYNET_HOME=$MYNET_HOME"
            if [[ ! -f "$MYNET_HOME/conf/mynet.conf" ]]; then
                log_error "该路径无效（缺少 conf/mynet.conf）"
            fi
            echo ""
        fi

        log_error "mynet_proxy 需要安装到已有的 mynet 目录中"
        log_info "请先安装 mynet（VPN 组件），然后再安装 mynet_proxy"
        echo ""
        log_info "如果 mynet 已安装但在其他位置，请设置环境变量："
        echo "  export MYNET_HOME=/path/to/mynet"
        echo "  $0 install"
        exit 1
    fi

    log_success "找到 mynet 安装目录: $mynet_home"
    echo ""

    # 检测已安装
    if [[ -f "$mynet_home/bin/$BINARY_NAME" ]]; then
        log_warning "检测到已安装 mynet_proxy"
        echo ""

        # 显示当前配置详情
        local role_conf="$mynet_home/conf/proxy/proxy_role.conf"
        local peers_conf="$mynet_home/conf/proxy/proxy_peers.conf"

        local has_client=false
        local has_server=false

        if [[ -f "$role_conf" ]]; then
            log_info "当前配置："

            # 检测 Client 配置
            if grep -q "^\[CLIENT\]" "$role_conf" 2>/dev/null; then
                local client_enabled=$(grep "PROXY_ENABLED=" "$role_conf" | head -1 | cut -d= -f2)
                local client_region=$(grep "NODE_REGION=" "$role_conf" | head -1 | cut -d= -f2)
                local client_count=$(grep -A 999 "^\[CLIENT\]" "$peers_conf" 2>/dev/null | grep -v "^\[" | grep -v "^#" | grep -v "^$" | wc -l | tr -d ' ')

                if [[ "$client_enabled" == "true" ]]; then
                    echo "  • Client 模式: 已启用 (节点区域: $client_region, 代理节点: $client_count 个)"
                    has_client=true
                fi
            fi

            # 检测 Server 配置
            if grep -q "^\[SERVER\]" "$role_conf" 2>/dev/null; then
                local server_enabled=$(grep "PROXY_ENABLED=" "$role_conf" | tail -1 | cut -d= -f2)
                local server_region=$(grep "NODE_REGION=" "$role_conf" | tail -1 | cut -d= -f2)

                if [[ "$server_enabled" == "true" ]]; then
                    echo "  • Server 模式: 已启用 (节点区域: $server_region)"
                    has_server=true
                fi
            fi
        else
            log_info "尚未配置代理角色"
        fi

        echo ""
        echo "请选择操作："
        echo "  1) 重新安装（保留配置）"
        echo "  2) 刷新配置文件（--force 重新生成）"

        # 动态显示升级选项
        if [[ "$has_client" == "true" && "$has_server" == "false" ]]; then
            # 只有 Client，提供添加 Server
            echo "  3) 添加 Server 功能（升级为 Both 模式）"
            echo "  4) 完全卸载后重新安装"
            echo "  5) 取消安装"
        elif [[ "$has_client" == "false" && "$has_server" == "true" ]]; then
            # 只有 Server，提供添加 Client
            echo "  3) 添加 Client 功能（升级为 Both 模式）"
            echo "  4) 完全卸载后重新安装"
            echo "  5) 取消安装"
        else
            # Both 模式或未配置
            echo "  3) 完全卸载后重新安装"
            echo "  4) 取消安装"
        fi
        echo ""

        local choice
        local max_choice=4
        if [[ ("$has_client" == "true" && "$has_server" == "false") || ("$has_client" == "false" && "$has_server" == "true") ]]; then
            max_choice=5
        fi

        while true; do
            read -p "请选择 [1-$max_choice]: " choice
            case $choice in
                1)
                    log_info "重新安装（保留配置）..."
                    break
                    ;;
                2)
                    log_info "刷新配置文件（--force 重新生成）..."

                    export MYNET_HOME="$mynet_home"
                    if "$mynet_home/bin/$BINARY_NAME" config --force; then
                        log_success "✓ 配置文件已刷新"

                        # 显示生成的文件
                        if [[ -f "$mynet_home/conf/proxy/proxy_outbound.txt" ]]; then
                            local count=$(wc -l < "$mynet_home/conf/proxy/proxy_outbound.txt" 2>/dev/null || echo "0")
                            log_info "  ✓ proxy_outbound.txt: $count 条"
                        fi

                        if [[ -f "$mynet_home/conf/proxy/proxy_whitelist.txt" ]]; then
                            local count=$(wc -l < "$mynet_home/conf/proxy/proxy_whitelist.txt" 2>/dev/null || echo "0")
                            log_info "  ✓ proxy_whitelist.txt: $count 条"
                        fi
                    else
                        log_error "配置刷新失败"
                    fi

                    echo ""
                    exit 0
                    ;;
                3)
                    # 动态处理升级逻辑
                    if [[ "$has_client" == "true" && "$has_server" == "false" ]]; then
                        # 只有 Client，添加 Server
                        log_info "添加 Server 功能（升级为 Both 模式）..."

                        export MYNET_HOME="$mynet_home"
                        # 获取当前 Client 的 nodeRegion
                        local current_region=$(grep "NODE_REGION=" "$role_conf" | head -1 | cut -d= -f2)

                        echo ""
                        log_info "将使用相同的节点区域: $current_region"
                        log_info "执行 Server 配置..."

                        # 调用 setup 添加 Server 配置（Server 不需要 peers 参数）
                        if MYNET_HOME="$mynet_home" "$mynet_home/bin/$BINARY_NAME" setup --role server --node-region "$current_region"; then
                            log_success "✓ Server 功能添加成功"
                            log_info "当前模式: Both (Client + Server)"
                        else
                            log_error "添加 Server 功能失败"
                        fi

                        echo ""
                        exit 0
                    elif [[ "$has_client" == "false" && "$has_server" == "true" ]]; then
                        # 只有 Server，添加 Client
                        log_info "添加 Client 功能（升级为 Both 模式）..."

                        export MYNET_HOME="$mynet_home"
                        # 获取当前 Server 的 nodeRegion
                        local current_region=$(grep "NODE_REGION=" "$role_conf" | head -1 | cut -d= -f2)

                        echo ""
                        log_info "将使用相同的节点区域: $current_region"

                        # 选择代理节点（Client 必需）
                        log_info "扫描可用的代理节点..."
                        local scan_output=$("$mynet_home/bin/$BINARY_NAME" setup --role client --node-region "$current_region" --peers "all" 2>&1 | grep -A 999 "找到.*个对端节点" | head -20)

                        if echo "$scan_output" | grep -q "个对端节点"; then
                            echo "$scan_output" | grep -E "^\s+[0-9]+\)|找到"

                            echo ""
                            echo "提示: 输入节点编号，多个节点用逗号分隔"
                            echo "      例如: 1,2  (选择节点1和2)"
                            echo "      或输入 'all' 选择全部节点"
                            echo ""

                            local peers_input
                            while true; do
                                read -p "请输入节点编号: " peers_input
                                peers_input=$(echo "$peers_input" | xargs)

                                if [[ -z "$peers_input" ]]; then
                                    log_error "请输入节点编号"
                                    continue
                                fi

                                if [[ "$peers_input" == "all" ]]; then
                                    log_info "已选择: 全部节点"
                                    break
                                elif echo "$peers_input" | grep -qE '^[0-9]+(,[0-9]+)*$'; then
                                    log_info "已选择: 节点 $peers_input"
                                    break
                                else
                                    log_error "无效格式，请输入数字或 'all'"
                                fi
                            done
                        else
                            log_warning "未找到可用的对端节点"
                            peers_input="all"
                        fi

                        # 调用 setup 添加 Client 配置
                        echo ""
                        log_info "执行 Client 配置..."
                        if MYNET_HOME="$mynet_home" "$mynet_home/bin/$BINARY_NAME" setup --role client --node-region "$current_region" --peers "$peers_input"; then
                            log_success "✓ Client 功能添加成功"
                            log_info "当前模式: Both (Client + Server)"
                        else
                            log_error "添加 Client 功能失败"
                        fi

                        echo ""
                        exit 0
                    else
                        # 否则选项3是完全卸载
                        log_info "完全卸载后重新安装..."

                        # 先确定新二进制文件位置（卸载前）
                        local new_binary=""
                        if [[ -f "$PROJECT_ROOT/bin/$BINARY_NAME" ]]; then
                            new_binary="$PROJECT_ROOT/bin/$BINARY_NAME"
                        elif [[ -f "$PROJECT_ROOT/$BINARY_NAME" ]]; then
                            new_binary="$PROJECT_ROOT/$BINARY_NAME"
                        fi

                        if [[ -z "$new_binary" || ! -f "$new_binary" ]]; then
                            log_error "找不到新的二进制文件: $BINARY_NAME"
                            log_error "请确保在发布包目录中运行此脚本"
                            exit 1
                        fi

                        # 执行卸载
                        uninstall
                        echo ""

                        # 卸载后立即复制二进制文件（避免中间状态）
                        log_info "恢复二进制文件..."
                        mkdir -p "$mynet_home/bin"
                        cp -f "$new_binary" "$mynet_home/bin/"
                        chmod +x "$mynet_home/bin/$BINARY_NAME"
                        log_success "✓ 已复制: bin/$BINARY_NAME"
                        echo ""

                        log_info "继续全新安装..."
                        break
                    fi
                    ;;
                4)
                    # 如果只有 Client 或只有 Server，选项4是完全卸载，选项5是取消
                    if [[ ("$has_client" == "true" && "$has_server" == "false") || ("$has_client" == "false" && "$has_server" == "true") ]]; then
                        log_info "完全卸载后重新安装..."

                        # 先确定新二进制文件位置（卸载前）
                        local new_binary=""
                        if [[ -f "$PROJECT_ROOT/bin/$BINARY_NAME" ]]; then
                            new_binary="$PROJECT_ROOT/bin/$BINARY_NAME"
                        elif [[ -f "$PROJECT_ROOT/$BINARY_NAME" ]]; then
                            new_binary="$PROJECT_ROOT/$BINARY_NAME"
                        fi

                        if [[ -z "$new_binary" || ! -f "$new_binary" ]]; then
                            log_error "找不到新的二进制文件: $BINARY_NAME"
                            log_error "请确保在发布包目录中运行此脚本"
                            exit 1
                        fi

                        # 执行卸载
                        uninstall
                        echo ""

                        # 卸载后立即复制二进制文件（避免中间状态）
                        log_info "恢复二进制文件..."
                        mkdir -p "$mynet_home/bin"
                        cp -f "$new_binary" "$mynet_home/bin/"
                        chmod +x "$mynet_home/bin/$BINARY_NAME"
                        log_success "✓ 已复制: bin/$BINARY_NAME"
                        echo ""

                        log_info "继续全新安装..."
                        break
                    else
                        # Both 模式或未配置，选项4是取消
                        log_info "安装已取消"
                        exit 0
                    fi
                    ;;
                5)
                    # 选项5是取消（仅当 Client Only 或 Server Only 时才有）
                    if [[ ("$has_client" == "true" && "$has_server" == "false") || ("$has_client" == "false" && "$has_server" == "true") ]]; then
                        log_info "安装已取消"
                        exit 0
                    else
                        log_error "无效选择，请重新输入"
                    fi
                    ;;
                *)
                    log_error "无效选择，请重新输入"
                    ;;
            esac
        done
        echo ""
    fi

    # 步骤 2: 检查 GNB 服务
    log_step "步骤 2/6: 检查 GNB 服务"
    check_gnb_service "$mynet_home"
    echo ""

    # 步骤 3: 读取本地节点 ID
    log_step "步骤 3/6: 读取本地节点配置"

    local local_node_id=$(get_local_node_id "$mynet_home")
    if [[ -z "$local_node_id" ]]; then
        log_warning "无法从 mynet.conf 读取本地节点 ID"
        log_info "这不影响代理插件的安装，仅影响自动扫描代理节点功能"
        local_node_id="unknown"
    else
        log_success "本地节点 ID: $local_node_id"
    fi
    echo ""

    # 步骤 4: 安装文件
    log_step "步骤 4/6: 安装程序文件"

    # 检查二进制文件
    local binary=""
    if [[ -f "$PROJECT_ROOT/bin/$BINARY_NAME" ]]; then
        binary="$PROJECT_ROOT/bin/$BINARY_NAME"
    elif [[ -f "$PROJECT_ROOT/$BINARY_NAME" ]]; then
        binary="$PROJECT_ROOT/$BINARY_NAME"
    fi

    if [[ -z "$binary" || ! -f "$binary" ]]; then
        log_error "找不到二进制文件: $BINARY_NAME"
        exit 1
    fi

    # 安装二进制
    mkdir -p "$mynet_home/bin"
    cp -f "$binary" "$mynet_home/bin/"
    chmod +x "$mynet_home/bin/$BINARY_NAME"
    log_success "安装: bin/$BINARY_NAME"

    # 安装配置模板和源文件
    mkdir -p "$mynet_home/conf/proxy"
    mkdir -p "$mynet_home/conf/proxy/proxy_sources"

    if [[ -d "$PROJECT_ROOT/conf/proxy" ]]; then
        # 复制根目录下的模板文件
        for template in "$PROJECT_ROOT/conf/proxy"/*.txt; do
            if [[ -f "$template" ]]; then
                local filename=$(basename "$template")
                if [[ ! -f "$mynet_home/conf/proxy/$filename" ]]; then
                    cp "$template" "$mynet_home/conf/proxy/"
                    log_success "安装: conf/proxy/$filename"
                fi
            fi
        done

        # 复制 proxy_sources 目录（完整复制）
        if [[ -d "$PROJECT_ROOT/conf/proxy/proxy_sources" ]]; then
            cp -rf "$PROJECT_ROOT/conf/proxy/proxy_sources/"* "$mynet_home/conf/proxy/proxy_sources/" 2>/dev/null || true
            local source_count=$(find "$mynet_home/conf/proxy/proxy_sources" -name "*.txt" -type f | wc -l | tr -d ' ')
            log_success "安装: conf/proxy/proxy_sources ($source_count 个源文件)"
        fi
    fi

    # 安装平台脚本（Linux/OpenWrt 使用统一脚本）
    local platform=$(detect_platform)
    local script_source=""

    # Linux 和 OpenWrt 使用统一脚本
    if [[ "$platform" == "linux" || "$platform" == "openwrt" ]]; then
        # 优先从打包目录查找（openwrt/或linux/）
        if [[ -f "$PROJECT_ROOT/scripts/openwrt/route_policy.sh" ]]; then
            script_source="$PROJECT_ROOT/scripts/openwrt/route_policy.sh"
        elif [[ -f "$PROJECT_ROOT/scripts/linux/route_policy.sh" ]]; then
            script_source="$PROJECT_ROOT/scripts/linux/route_policy.sh"
        elif [[ -f "$PROJECT_ROOT/scripts/proxy/linux/route_policy.sh" ]]; then
            script_source="$PROJECT_ROOT/scripts/proxy/linux/route_policy.sh"
        fi
    # Darwin 使用专用脚本
    elif [[ "$platform" == "darwin" ]]; then
        if [[ -f "$PROJECT_ROOT/scripts/darwin/route_policy.sh" ]]; then
            script_source="$PROJECT_ROOT/scripts/darwin/route_policy.sh"
        elif [[ -f "$PROJECT_ROOT/scripts/proxy/darwin/route_policy.sh" ]]; then
            script_source="$PROJECT_ROOT/scripts/proxy/darwin/route_policy.sh"
        fi
    fi

    if [[ -n "$script_source" ]]; then
        mkdir -p "$mynet_home/scripts"
        cp -f "$script_source" "$mynet_home/scripts/proxy.sh"
        chmod +x "$mynet_home/scripts/proxy.sh"
        log_success "安装: scripts/proxy.sh (平台: $platform, 统一脚本)"
    else
        log_warning "未找到 $platform 平台的策略路由脚本"
    fi

    echo ""

    # 步骤 5: 配置代理节点（使用 mynet_proxy setup 自动配置）
    log_step "步骤 5/6: 自动配置代理节点"

    # 询问用户角色
    echo ""
    echo "请选择本节点的角色："
    echo ""
    echo "  1) 仅作为发起方 (Client Only)"
    echo "     - 通过代理访问远程网络"
    echo "     - 不为他人提供代理"
    echo ""
    echo "  2) 仅作为代理方 (Server Only)"
    echo "     - 为其他节点提供代理服务"
    echo "     - 不使用代理访问网络"
    echo ""
    echo "  3) 双向代理 (Both)"
    echo "     - 既使用代理，也提供代理"
    echo ""

    local role_choice
    local role
    while true; do
        read -p "请选择 [1-3]: " role_choice
        case $role_choice in
            1)
                role="client"
                break
                ;;
            2)
                role="server"
                break
                ;;
            3)
                role="both"
                break
                ;;
            *)
                log_error "无效选择，请重新输入"
                ;;
        esac
    done

    echo ""
    log_info "角色已选择: $role"

    # 询问节点区域
    echo ""
    if [[ "$role" == "client" ]]; then
        echo "请选择您想访问的目标网络："
        echo ""
        echo "  1) 国际网站 (Google、YouTube、Twitter等)"
        echo "     - 适合国内用户访问国外网站"
        echo ""
        echo "  2) 国内网站 (优酷、B站、爱奇艺等)"
        echo "     - 适合国外用户访问国内网站"
        echo ""
    elif [[ "$role" == "server" ]]; then
        echo "请选择您的节点所在位置："
        echo ""
        echo "  1) 国外节点"
        echo "     - 为国内用户提供访问国外的代理（出国代理）"
        echo ""
        echo "  2) 国内节点"
        echo "     - 为国外用户提供访问国内的代理（回国代理）"
        echo ""
    else
        # Both 模式
        echo "请选择您的节点所在位置："
        echo ""
        echo "  1) 国内节点"
        echo "     - 使用代理访问国外网站（通过国外代理）"
        echo "     - 为国外用户提供访问国内的代理"
        echo ""
        echo "  2) 国外节点"
        echo "     - 使用代理访问国内网站（通过国内代理）"
        echo "     - 为国内用户提供访问国外的代理"
        echo ""
    fi

    local region_choice
    local node_region
    while true; do
        read -p "请选择 [1-2]: " region_choice
        case $region_choice in
            1)
                # Server 模式下：1=国外节点=international，Client/Both 模式下：1=国内节点=domestic
                if [[ "$role" == "server" ]]; then
                    node_region="international"
                else
                    node_region="domestic"
                fi
                break
                ;;
            2)
                # Server 模式下：2=国内节点=domestic，Client/Both 模式下：2=国外节点=international
                if [[ "$role" == "server" ]]; then
                    node_region="domestic"
                else
                    node_region="international"
                fi
                break
                ;;
            *)
                log_error "无效选择，请重新输入"
                ;;
        esac
    done

    echo ""
    log_info "节点区域已选择: $node_region"

    # 如果是 Client 或 Both 模式，需要选择代理节点
    local peers_param=""
    if [[ "$role" == "client" || "$role" == "both" ]]; then
        echo ""
        log_info "扫描可用的代理节点..."

        # 先扫描节点列表
        export MYNET_HOME="$mynet_home"
        local scan_output=$("$mynet_home/bin/$BINARY_NAME" setup --role "$role" --node-region "$node_region" --peers "all" 2>&1 | grep -A 999 "找到.*个对端节点" | head -20)

        if echo "$scan_output" | grep -q "个对端节点"; then
            echo "$scan_output" | grep -E "^\s+[0-9]+\)|找到"

            echo ""
            echo "提示: 输入节点编号，多个节点用逗号分隔"
            echo "      例如: 1,2  (选择节点1和2)"
            echo "      或输入 'all' 选择全部节点"
            echo ""

            local peers_input
            while true; do
                read -p "请输入节点编号: " peers_input
                peers_input=$(echo "$peers_input" | xargs)  # 去除前后空格

                if [[ -z "$peers_input" ]]; then
                    log_error "请输入节点编号"
                    continue
                fi

                # 验证输入格式
                if [[ "$peers_input" == "all" ]]; then
                    peers_param="all"
                    log_info "已选择: 全部节点"
                    break
                elif echo "$peers_input" | grep -qE '^[0-9]+(,[0-9]+)*$'; then
                    peers_param="$peers_input"
                    log_info "已选择: 节点 $peers_input"
                    break
                else
                    log_error "无效格式，请输入数字或 'all'"
                fi
            done
        else
            log_warning "未找到可用的对端节点"
            log_info "您可以稍后使用 'mynet_proxy setup' 重新配置"
            peers_param="all"
        fi
    fi

    # 调用 mynet_proxy setup 自动配置（使用参数，无交互）
    echo ""
    local setup_cmd="MYNET_HOME=\"$mynet_home\" \"$mynet_home/bin/$BINARY_NAME\" setup --role \"$role\" --node-region \"$node_region\""

    if [[ -n "$peers_param" ]]; then
        setup_cmd="$setup_cmd --peers \"$peers_param\""
    fi

    log_info "执行配置命令..."
    if eval "$setup_cmd"; then
        log_success "✓ 代理节点配置完成"
    else
        log_error "配置失败，请检查错误信息"
        exit 1
    fi

    # 创建插件钩子
    create_plugin_hooks "$mynet_home"

    echo ""

    # setup 已经生成了所有配置文件（proxy_outbound.txt, proxy_whitelist.txt, 路由等）
    # 无需再次调用 config
    log_step "步骤 6/6: 验证配置文件"

    # 显示已生成的文件
    if [[ -f "$mynet_home/conf/proxy/proxy_outbound.txt" ]]; then
        local count=$(wc -l < "$mynet_home/conf/proxy/proxy_outbound.txt" 2>/dev/null || echo "0")
        log_info "  ✓ proxy_outbound.txt: $count 条"
    fi

    if [[ -f "$mynet_home/conf/proxy/proxy_whitelist.txt" ]]; then
        local count=$(wc -l < "$mynet_home/conf/proxy/proxy_whitelist.txt" 2>/dev/null || echo "0")
        log_info "  ✓ proxy_whitelist.txt: $count 条"
    fi

    log_success "✓ 配置文件已就绪"

    echo ""

    # 保存安装脚本副本（用于卸载）
    log_step "保存安装脚本副本"
    local script_dir="$mynet_home/scripts/proxy"
    mkdir -p "$script_dir"

    # 复制当前脚本
    if cp -f "$0" "$script_dir/install.sh" 2>/dev/null; then
        chmod +x "$script_dir/install.sh"
        log_success "✓ 安装脚本已保存: $script_dir/install.sh"
    else
        log_warning "! 无法保存安装脚本副本（可能权限不足）"
    fi

    echo ""
    echo "========================================="
    log_success "安装完成！"
    echo "========================================="
    echo ""
    log_info "后续步骤:"
    echo "  1. 编辑配置: $mynet_home/conf/proxy/proxy_role.conf"
    echo "  2. 生成配置: MYNET_HOME=$mynet_home $mynet_home/bin/mynet_proxy config --force"
    echo "  3. 启动服务: mynet service start (hooks 会自动应用策略路由)"
    echo ""
    log_info "⚠️  重要提示:"
    echo "  • 非局域网登录时，重启服务可能导致 SSH 断开"
    echo "  • 建议使用后台命令："
    echo "    nohup /etc/init.d/mynet restart >/dev/null 2>&1 &"
    echo "    sleep 5  # 等待服务完全启动"
    echo ""
    log_info "管理命令:"
    echo "  查看状态: MYNET_HOME=$mynet_home $mynet_home/bin/mynet_proxy status"
    echo "  卸载插件: sudo $script_dir/install.sh uninstall"
    echo ""
    log_info "手动路由管理 (通常不需要):"
    echo "  启动路由: MYNET_HOME=$mynet_home $mynet_home/scripts/proxy.sh start"
    echo "  停止路由: MYNET_HOME=$mynet_home $mynet_home/scripts/proxy.sh stop"
    echo "  查看路由: MYNET_HOME=$mynet_home $mynet_home/scripts/proxy.sh status"
    echo ""
}

# 卸载
uninstall() {
    log_info "开始卸载 mynet_proxy..."

    local mynet_home=$(find_mynet_home)

    if [[ -z "$mynet_home" ]]; then
        log_error "无法找到 mynet 安装目录"
        return 1
    fi

    log_info "卸载目录: $mynet_home"

    # 1. 清理代理路由（在删除二进制文件之前）
    if [[ -f "$mynet_home/bin/$BINARY_NAME" ]]; then
        echo ""
        read -p "是否从 route.conf 清理代理路由? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            export MYNET_HOME="$mynet_home"
            if "$mynet_home/bin/$BINARY_NAME" clean 2>/dev/null; then
                log_success "✓ 已清理代理路由"
            else
                log_warning "! 路由清理失败（可能未配置）"
            fi
        fi
    fi

    # 2. 删除二进制文件
    if [[ -f "$mynet_home/bin/$BINARY_NAME" ]]; then
        rm -f "$mynet_home/bin/$BINARY_NAME"
        log_success "✓ 已删除: bin/$BINARY_NAME"
    fi

    # 3. 删除配置文件（询问用户）
    if [[ -d "$mynet_home/conf/proxy" ]]; then
        echo ""
        read -p "是否删除配置文件? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$mynet_home/conf/proxy"
            log_success "✓ 已删除: conf/proxy"
        else
            log_info "保留配置文件: conf/proxy"
        fi
    fi

    # 4. 删除平台脚本和目录
    if [[ -f "$mynet_home/scripts/proxy.sh" ]]; then
        rm -f "$mynet_home/scripts/proxy.sh"
        log_success "✓ 已删除: scripts/proxy.sh"
    fi

    if [[ -d "$mynet_home/scripts/proxy" ]]; then
        rm -rf "$mynet_home/scripts/proxy"
        log_success "✓ 已删除: scripts/proxy/ 目录"
    fi

    if [[ -d "$mynet_home/scripts/plugin/proxy" ]]; then
        rm -rf "$mynet_home/scripts/plugin/proxy"
        log_success "✓ 已删除: scripts/plugin/proxy/ 目录"
    fi

    echo ""
    log_success "mynet_proxy 卸载完成！"
}

# 重新安装
reinstall() {
    log_info "重新安装 mynet_proxy..."
    uninstall
    echo ""
    install
}

# 显示状态
status() {
    log_info "mynet_proxy 安装状态"
    echo ""

    local mynet_home=$(find_mynet_home)

    if [[ -z "$mynet_home" ]]; then
        log_error "无法找到 mynet 安装目录"
        return 1
    fi

    log_info "mynet 安装目录: $mynet_home"
    echo ""

    # 检查二进制
    if [[ -f "$mynet_home/bin/$BINARY_NAME" ]]; then
        local version=$("$mynet_home/bin/$BINARY_NAME" --version 2>&1 | head -1 || echo "unknown")
        log_success "✓ 二进制: bin/$BINARY_NAME"
        echo "  版本: $version"
    else
        log_error "✗ 二进制: 未安装"
    fi

    echo ""

    # 检查配置
    if [[ -d "$mynet_home/conf/proxy" ]]; then
        log_success "✓ 配置目录: conf/proxy"
        if [[ -f "$mynet_home/conf/proxy/proxy_outbound.txt" ]]; then
            local count=$(grep -v "^#" "$mynet_home/conf/proxy/proxy_outbound.txt" 2>/dev/null | grep -v "^$" | wc -l | tr -d ' ')
            echo "  proxy_outbound.txt: $count 条"
        fi
        if [[ -f "$mynet_home/conf/proxy/proxy_whitelist.txt" ]]; then
            local count=$(grep -v "^#" "$mynet_home/conf/proxy/proxy_whitelist.txt" 2>/dev/null | grep -v "^$" | wc -l | tr -d ' ')
            echo "  proxy_whitelist.txt: $count 条"
        fi
        if [[ -f "$mynet_home/conf/proxy/proxy_peers.conf" ]]; then
            echo "  proxy_peers.conf: 存在"
        fi
    else
        log_error "✗ 配置目录: 未安装"
    fi

    echo ""

    # 检查脚本
    if [[ -f "$mynet_home/scripts/proxy.sh" ]]; then
        log_success "✓ 平台脚本: scripts/proxy.sh"
    else
        log_error "✗ 平台脚本: 未安装"
    fi

    echo ""

    # 检查 GNB 服务
    if pgrep -x gnb >/dev/null 2>&1 || pgrep -f "gnb.*gnb.conf" >/dev/null 2>&1; then
        log_success "✓ GNB 服务: 运行中"
    else
        log_warning "! GNB 服务: 未运行"
    fi
}

# 显示帮助
show_help() {
    cat << EOF
mynet_proxy 智能安装脚本

用法:
    $0 install      # 智能安装（包含配置向导）
    $0 uninstall    # 卸载
    $0 reinstall    # 重新安装
    $0 status       # 查看安装状态

智能安装特性:
    1. 自动查找 mynet 安装目录
    2. 检查 GNB 服务状态
    3. 读取本地节点配置
    4. 扫描可用代理节点并交互选择
    5. 自动生成 proxy_peers.conf
    6. 自动应用代理配置
    7. 生成策略路由脚本

环境变量:
    MYNET_HOME    指定 mynet 安装目录

EOF
}

# 主逻辑
case "${1:-}" in
    install)
        install
        ;;
    uninstall)
        uninstall
        ;;
    reinstall)
        reinstall
        ;;
    status)
        status
        ;;
    --help|-h|help)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac
