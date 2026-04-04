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

# ─── 日志捕获 ───
# 所有输出同时写入日志文件
MYNET_LOG_DIR="${MYNET_HOME:-/etc/mynet}/logs"
mkdir -p "$MYNET_LOG_DIR" 2>/dev/null || true
MYNET_SCRIPT_LOG="$MYNET_LOG_DIR/proxy.log"
exec > >(tee -a "$MYNET_SCRIPT_LOG") 2>&1
echo "[$(date '+%Y-%m-%d %H:%M:%S')] proxy.sh $*"

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
STATE_DIR="$MYNET_HOME/var"

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

# ─────────────────────────────────────────────────────────
# 原子回滚框架（Phase 8.3）
# proxy 启动是多层操作，任一层失败回退已成功的层
# ─────────────────────────────────────────────────────────

rollback() {
    local layers_done="$1"
    log_warning "回滚: 已完成 $layers_done 层"

    if [[ "$layers_done" -ge 3 ]]; then
        MYNET_HOME="$MYNET_HOME" "$ROUTE_SCRIPT" dns_stop 2>/dev/null || true
        log_info "  ✓ DNS 劫持已回滚"
    fi
    if [[ "$layers_done" -ge 2 ]]; then
        MYNET_HOME="$MYNET_HOME" "$ROUTE_SCRIPT" stop 2>/dev/null || true
        log_info "  ✓ 策略路由已回滚"
    fi
    if [[ "$layers_done" -ge 1 ]]; then
        log_info "  ✓ route.conf 回滚由 Lua 层处理"
    fi
}

# 启动策略路由（含原子回滚）
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

    # 读取 proxy 配置
    local role_conf="$MYNET_HOME/conf/proxy/proxy_role.conf"
    local proxy_mode="client"
    local dns_mode="none"
    local dns_server=""
    if [[ -f "$role_conf" ]]; then
        proxy_mode=$(grep "^PROXY_MODE=" "$role_conf" 2>/dev/null | cut -d'"' -f2 | head -1)
        dns_mode=$(grep "^DNS_MODE=" "$role_conf" 2>/dev/null | cut -d'"' -f2 | head -1)
        dns_server=$(grep "^DNS_SERVER=" "$role_conf" 2>/dev/null | cut -d'"' -f2 | head -1)
    fi
    [[ -z "$proxy_mode" ]] && proxy_mode="client"
    [[ -z "$dns_mode" ]] && dns_mode="none"

    mkdir -p "$STATE_DIR"
    local layers_done=0

    # Layer 1: route.conf 注入（已迁移到 Lua proxy.lua，由 LuCI 预执行）
    layers_done=1

    # Layer 2: ipset + fwmark 策略路由
    log_info "Layer 2/3: 策略路由..."
    if MYNET_HOME="$MYNET_HOME" "$ROUTE_SCRIPT" start; then
        layers_done=2
        log_success "Layer 2: 策略路由启动成功"
    else
        log_error "Layer 2: 策略路由启动失败 — 回滚"
        rollback $layers_done
        return 1
    fi

    # Server 模式额外操作
    if [[ "$proxy_mode" == "server" ]]; then
        log_info "Layer 2+: Server 模式..."
        MYNET_HOME="$MYNET_HOME" "$ROUTE_SCRIPT" server_start || log_warning "Server 模式启动失败"
    fi

    # Layer 3: DNS 劫持
    if [[ "$dns_mode" != "none" ]] && [[ -n "$dns_server" ]]; then
        log_info "Layer 3/3: DNS 劫持 ($dns_mode → $dns_server)..."
        if MYNET_HOME="$MYNET_HOME" "$ROUTE_SCRIPT" dns_start "$dns_mode" "$dns_server"; then
            layers_done=3
            log_success "Layer 3: DNS 劫持启动成功"
        else
            log_error "Layer 3: DNS 劫持失败 — 回滚"
            rollback $layers_done
            return 1
        fi
    else
        log_info "Layer 3/3: DNS 劫持未启用，跳过"
        layers_done=3
    fi

    # 记录层数
    echo "$layers_done" > "$STATE_DIR/proxy_layers"
    log_success "策略路由已启动（$layers_done 层）"
    return 0
}

# 停止策略路由（按层反序清理）
stop_route() {
    log_info "停止策略路由..."

    # 读取已启动的层数
    local layers_done=3
    if [[ -f "$STATE_DIR/proxy_layers" ]]; then
        layers_done=$(cat "$STATE_DIR/proxy_layers" 2>/dev/null)
    fi

    if [[ ! -f "$ROUTE_SCRIPT" ]]; then
        log_warning "策略路由脚本不存在，跳过"
        return 0
    fi

    # 反序关闭
    if MYNET_HOME="$MYNET_HOME" "$ROUTE_SCRIPT" stop; then
        log_success "策略路由已停止"
    else
        log_warning "停止策略路由失败（可能未运行）"
    fi

    # 恢复注入的路由
    if [[ -f "$INJECT_SCRIPT" ]]; then
        MYNET_HOME="$MYNET_HOME" bash "$INJECT_SCRIPT" restore 2>/dev/null || true
    fi

    # 清除状态
    rm -f "$STATE_DIR/proxy_layers"
    return 0
}

# 重启策略路由
restart_route() {
    stop_route
    sleep 1
    start_route
}

# 查看状态
status_route() {
    local json_mode=false
    if [[ "${1:-}" == "--json" ]]; then
        json_mode=true
    fi

    if [[ "$json_mode" == "true" ]]; then
        status_json
        return $?
    fi

    log_info "查看代理状态..."
    
    # 使用 mynet_proxy status
    if MYNET_HOME="$MYNET_HOME" "$MYNET_PROXY_BIN" status; then
        return 0
    else
        return 1
    fi
}

# JSON 结构化状态输出（供 LuCI API 消费）
status_json() {
    local running=false
    local mode="client"
    local region="domestic"
    local dns_mode="none"
    local ipset_count=0
    local peer_count=0
    local uptime_seconds=0
    local layer_route_inject=false
    local layer_policy_routing=false
    local layer_dns_intercept=false

    # 检测防火墙类型
    local fw_type="unknown"
    if command -v nft >/dev/null 2>&1 && nft list tables 2>/dev/null | grep -q .; then
        fw_type="nftables"
    elif command -v iptables >/dev/null 2>&1 && command -v ipset >/dev/null 2>&1; then
        fw_type="iptables"
    fi

    # 检测路由表 ID
    local table_id=0
    if [ -f /etc/iproute2/rt_tables ]; then
        table_id=$(grep -E "^[[:space:]]*[0-9]+[[:space:]]+mynet_proxy" /etc/iproute2/rt_tables | awk '{print $1}' | head -1)
    fi
    [ -z "$table_id" ] && table_id=0

    # 读取 proxy_role.conf
    local role_conf="$MYNET_HOME/conf/proxy/proxy_role.conf"
    if [ -f "$role_conf" ]; then
        mode=$(grep "^PROXY_MODE=" "$role_conf" 2>/dev/null | cut -d'"' -f2 | head -1)
        region=$(grep "^NODE_REGION=" "$role_conf" 2>/dev/null | cut -d'"' -f2 | head -1)
        dns_mode=$(grep "^DNS_MODE=" "$role_conf" 2>/dev/null | cut -d'"' -f2 | head -1)
        local peers_str=$(grep "^PROXY_PEERS=" "$role_conf" 2>/dev/null | cut -d'"' -f2 | head -1)
        if [ -n "$peers_str" ]; then
            peer_count=$(echo "$peers_str" | tr ',' '\n' | grep -c '.')
        fi
    fi
    [ -z "$mode" ] && mode="client"
    [ -z "$region" ] && region="domestic"
    [ -z "$dns_mode" ] && dns_mode="none"

    # 检测是否运行中
    case "$fw_type" in
        iptables)
            if ipset list mynet_proxy >/dev/null 2>&1; then
                ipset_count=$(ipset list mynet_proxy 2>/dev/null | grep "Number of entries" | awk '{print $NF}')
                [ -n "$ipset_count" ] && [ "$ipset_count" -gt 0 ] 2>/dev/null && running=true
                layer_policy_routing=true
            fi
            ;;
        nftables)
            if nft list set inet mynet_proxy mynet_proxy >/dev/null 2>&1; then
                ipset_count=$(nft list set inet mynet_proxy mynet_proxy 2>/dev/null | grep -c "elements")
                running=true
                layer_policy_routing=true
            fi
            ;;
    esac

    # 检测策略路由规则
    if ip rule list 2>/dev/null | grep -q "lookup mynet_proxy"; then
        layer_policy_routing=true
    fi

    # 检测 DNS 劫持
    if [ "$dns_mode" != "none" ] && [ "$running" = true ]; then
        case "$fw_type" in
            nftables)
                if nft list chain inet mynet_proxy dns_intercept 2>/dev/null | grep -q "dport 53"; then
                    layer_dns_intercept=true
                fi
                ;;
            iptables)
                if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "dpt:53"; then
                    layer_dns_intercept=true
                fi
                ;;
        esac
    fi

    # 检测 route inject
    local node_id=""
    if [ -f "$MYNET_HOME/conf/mynet.conf" ]; then
        node_id=$(grep "^# Node:" "$MYNET_HOME/conf/mynet.conf" | sed -n 's/.*ID: \([0-9]*\).*/\1/p')
    fi
    if [ -n "$node_id" ]; then
        local route_bak="$MYNET_HOME/driver/gnb/conf/$node_id/route.conf.proxy_bak"
        [ -f "$route_bak" ] && layer_route_inject=true
    fi

    # uptime（从 state file）
    local state_file="$MYNET_HOME/var/proxy_state.json"
    if [ -f "$state_file" ] && command -v python3 >/dev/null 2>&1; then
        local start_ts=$(python3 -c "import json,sys; d=json.load(open('$state_file')); print(d.get('start_ts',0))" 2>/dev/null)
        if [ -n "$start_ts" ] && [ "$start_ts" -gt 0 ] 2>/dev/null; then
            uptime_seconds=$(( $(date +%s) - start_ts ))
            [ "$uptime_seconds" -lt 0 ] && uptime_seconds=0
        fi
    fi

    # 输出 JSON
    cat <<EOF
{
  "running": $running,
  "mode": "$mode",
  "region": "$region",
  "dns_mode": "$dns_mode",
  "layers": {
    "route_inject": $layer_route_inject,
    "policy_routing": $layer_policy_routing,
    "dns_intercept": $layer_dns_intercept
  },
  "stats": {
    "ipset_count": ${ipset_count:-0},
    "route_table_id": ${table_id:-0},
    "peer_count": ${peer_count:-0},
    "uptime_seconds": ${uptime_seconds:-0}
  }
}
EOF
}

# 刷新配置（下载远程IP列表 → ipconfig → apply → 重启）
refresh_config() {
    log_info "刷新代理配置..."
    echo ""
    
    # 步骤 1: 下载远程 IP 列表
    log_info "步骤 1/4: 下载远程 IP 列表"
    
    local sources_dir="$MYNET_HOME/conf/proxy/proxy_sources"
    mkdir -p "$sources_dir"
    
    local base_url="https://download.mynet.club/mynet/plugins/mp"
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
            status_route "$2"
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
