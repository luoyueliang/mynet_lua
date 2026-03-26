#!/bin/bash
#
# MyNet Proxy 管理脚本
# mynet_proxy 插件统一管理脚本
#
# 功能：
#   - 启动/停止/重启策略路由
#   - 刷新远程IP列表并重新应用配置
#   - 重新配置代理节点
#
# 用法:
#   ./proxy.sh start    # 启动代理路由
#   ./proxy.sh stop     # 停止代理路由
#   ./proxy.sh restart  # 重启代理路由
#   ./proxy.sh status   # 查看状态
#   ./proxy.sh refresh  # 刷新IP列表并重新应用
#   ./proxy.sh setup    # 重新配置代理节点
#

set -e

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

# 检测 MYNET_HOME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 判断脚本位置
if [[ "$SCRIPT_DIR" == */scripts/proxy ]]; then
    # 在打包目录中: scripts/proxy/proxy.sh → 根目录
    MYNET_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
elif [[ -f "$SCRIPT_DIR/../../conf/mynet.conf" ]]; then
    # 在源码目录中
    MYNET_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
    # 从环境变量读取
    MYNET_HOME="${MYNET_HOME:-}"
fi

# 验证 MYNET_HOME
if [[ -z "$MYNET_HOME" ]] || [[ ! -f "$MYNET_HOME/conf/mynet.conf" ]]; then
    log_error "无法找到 MYNET_HOME"
    log_info "请设置环境变量: export MYNET_HOME=/path/to/mynet"
    exit 1
fi

MYNET_PROXY_BIN="$MYNET_HOME/bin/mynet_proxy"
ROUTE_SCRIPT="$MYNET_HOME/scripts/proxy/route_policy.sh"

# 检查 mynet_proxy 是否已安装
check_installation() {
    if [[ ! -f "$MYNET_PROXY_BIN" ]]; then
        log_error "mynet_proxy 未安装"
        log_info "请先运行安装脚本: scripts/proxy/install.sh install"
        exit 1
    fi
    
    if [[ ! -f "$ROUTE_SCRIPT" ]]; then
        log_error "策略路由脚本未找到: $ROUTE_SCRIPT"
        exit 1
    fi
}

# 启动策略路由
start_route() {
    log_info "启动策略路由..."
    
    if [[ ! -f "$ROUTE_SCRIPT" ]]; then
        log_error "策略路由脚本不存在: $ROUTE_SCRIPT"
        return 1
    fi
    
    # 检查配置文件
    if [[ ! -f "$MYNET_HOME/conf/proxy/proxy_route.conf" ]]; then
        log_error "策略路由配置不存在"
        log_info "请先运行: MYNET_HOME=$MYNET_HOME $MYNET_PROXY_BIN apply"
        return 1
    fi
    
    # 调用 route_policy.sh start
    if MYNET_HOME="$MYNET_HOME" "$ROUTE_SCRIPT" start; then
        log_success "策略路由已启动"
        return 0
    else
        log_error "启动策略路由失败"
        return 1
    fi
}

# 停止策略路由
stop_route() {
    log_info "停止策略路由..."
    
    if [[ ! -f "$ROUTE_SCRIPT" ]]; then
        log_warning "策略路由脚本不存在，跳过"
        return 0
    fi
    
    if MYNET_HOME="$MYNET_HOME" "$ROUTE_SCRIPT" stop; then
        log_success "策略路由已停止"
        return 0
    else
        log_warning "停止策略路由失败（可能未运行）"
        return 0
    fi
}

# 重启策略路由
restart_route() {
    stop_route
    sleep 1
    start_route
}

# 查看状态
status_route() {
    log_info "查看代理状态..."
    
    # 使用 mynet_proxy status
    if MYNET_HOME="$MYNET_HOME" "$MYNET_PROXY_BIN" status; then
        return 0
    else
        return 1
    fi
}

# 刷新配置（下载远程IP列表 → ipconfig → apply → 重启）
refresh_config() {
    log_info "刷新代理配置..."
    echo ""
    
    # 步骤 1: 下载远程 IP 列表
    log_info "步骤 1/4: 下载远程 IP 列表"
    
    local sources_dir="$MYNET_HOME/conf/proxy/proxy_sources"
    mkdir -p "$sources_dir"
    
    local base_url="${CTL_BASE_URL:-https://ctl.mynet.club}/plugins/mp"
    local download_ok=true
    
    # 下载 interip.txt
    log_info "  下载 interip.txt..."
    if curl -fsSL -o "$sources_dir/interip.txt" "$base_url/interip.txt"; then
        local count=$(wc -l < "$sources_dir/interip.txt" 2>/dev/null || echo "0")
        log_success "  ✓ interip.txt ($count 条)"
    else
        log_warning "  ! 下载 interip.txt 失败（将使用本地缓存）"
        download_ok=false
    fi
    
    # 下载 chinaip.txt
    log_info "  下载 chinaip.txt..."
    if curl -fsSL -o "$sources_dir/chinaip.txt" "$base_url/chinaip.txt"; then
        local count=$(wc -l < "$sources_dir/chinaip.txt" 2>/dev/null || echo "0")
        log_success "  ✓ chinaip.txt ($count 条)"
    else
        log_warning "  ! 下载 chinaip.txt 失败（将使用本地缓存）"
        download_ok=false
    fi
    
    if [[ "$download_ok" == "true" ]]; then
        log_success "远程 IP 列表已更新"
    else
        log_warning "部分下载失败，将使用本地缓存继续"
    fi
    
    echo ""
    
    # 步骤 2: 重新生成 IP 列表
    log_info "步骤 2/4: 重新生成 IP 列表"
    
    if MYNET_HOME="$MYNET_HOME" "$MYNET_PROXY_BIN" ipconfig; then
        log_success "IP 列表已重新生成"
    else
        log_error "生成 IP 列表失败"
        return 1
    fi
    
    echo ""
    
    # 步骤 3: 重新应用策略路由配置
    log_info "步骤 3/4: 重新应用策略路由"
    
    if MYNET_HOME="$MYNET_HOME" "$MYNET_PROXY_BIN" apply; then
        log_success "策略路由配置已更新"
    else
        log_error "应用策略路由失败"
        return 1
    fi
    
    echo ""
    
    # 步骤 4: 重启策略路由（如果正在运行）
    log_info "步骤 4/4: 重启策略路由"
    
    # 检查是否运行中
    if MYNET_HOME="$MYNET_HOME" "$ROUTE_SCRIPT" status >/dev/null 2>&1; then
        log_info "  检测到策略路由正在运行，重启..."
        restart_route
    else
        log_info "  策略路由未运行，启动..."
        start_route
    fi
    
    echo ""
    log_success "配置刷新完成！"
    echo ""
    log_info "配置概要："
    echo "  IP 列表: 已更新为最新版本"
    echo "  策略路由: 已重新生成并应用"
    echo ""
}

# 重新配置代理节点
setup_proxy() {
    log_info "重新配置代理节点..."
    echo ""
    
    log_warning "此操作将重新配置代理节点"
    log_info "建议在配置变更时才运行此命令"
    echo ""
    
    # 检查是否有现有配置
    local role_conf="$MYNET_HOME/conf/proxy/proxy_role.conf"
    if [[ -f "$role_conf" ]]; then
        log_info "检测到现有配置："
        grep -E "PROXY_ENABLED|NODE_REGION" "$role_conf" 2>/dev/null | head -5 || true
        echo ""
    fi
    
    log_error "交互式配置暂未实现"
    log_info "请使用以下方式重新配置："
    echo ""
    echo "  方式 1: 直接调用 mynet_proxy setup"
    echo "    MYNET_HOME=$MYNET_HOME \\"
    echo "      $MYNET_PROXY_BIN setup \\"
    echo "      --role client \\"
    echo "      --node-region domestic \\"
    echo "      --peers \"1,2\""
    echo ""
    echo "  方式 2: 重新运行安装脚本"
    echo "    cd $MYNET_HOME/scripts/proxy"
    echo "    sudo ./install.sh install"
    echo ""
    
    return 1
}

# 主函数
main() {
    case "${1:-}" in
        start)
            check_installation
            start_route
            ;;
        stop)
            check_installation
            stop_route
            ;;
        restart)
            check_installation
            restart_route
            ;;
        status)
            check_installation
            status_route
            ;;
        refresh)
            check_installation
            refresh_config
            ;;
        setup)
            check_installation
            setup_proxy
            ;;
        *)
            echo "用法: $0 {start|stop|restart|status|refresh|setup}"
            echo ""
            echo "命令说明："
            echo "  start   - 启动代理路由"
            echo "  stop    - 停止代理路由"
            echo "  restart - 重启代理路由"
            echo "  status  - 查看代理状态"
            echo "  refresh - 刷新 IP 列表并重新应用配置"
            echo "  setup   - 重新配置代理节点"
            exit 1
            ;;
    esac
}

main "$@"
