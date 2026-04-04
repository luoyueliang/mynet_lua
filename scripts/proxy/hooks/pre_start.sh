#!/bin/sh
#
# Proxy 插件预启动钩子
# 在 GNB 启动前执行
#
# 功能：
#   1. 检查代理配置完整性
#   2. 验证必需文件存在
#   3. 提示配置状态
#
# 注意：
#   v0.9.9+ 版本中，GNB route.conf 由 mynet_proxy setup 直接写入
#   不再需要在启动时合并 route_gnb_proxy.conf
#
# 兼容性：
#   使用 POSIX shell 语法，兼容 bash/sh/ash(OpenWrt)
#

set -e

# 日志捕获
if [ -n "$MYNET_HOME" ]; then
    mkdir -p "$MYNET_HOME/logs" 2>/dev/null || true
    exec >> "$MYNET_HOME/logs/hooks.log" 2>&1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] pre_start.sh"
fi

# 检查 MYNET_HOME 必须设置
if [ -z "$MYNET_HOME" ]; then
    echo "错误: MYNET_HOME 环境变量未设置"
    exit 1
fi

if [ ! -d "$MYNET_HOME" ]; then
    echo "错误: MYNET_HOME 目录不存在: $MYNET_HOME"
    exit 1
fi

ROLE_CONF="$MYNET_HOME/conf/proxy/proxy_role.conf"
PEERS_CONF="$MYNET_HOME/conf/proxy/proxy_peers.conf"
ROUTE_CONF="$MYNET_HOME/conf/proxy/proxy_route.conf"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[Proxy Pre-Start]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[Proxy Pre-Start]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[Proxy Pre-Start]${NC} $1"
}

log_error() {
    echo -e "${RED}[Proxy Pre-Start]${NC} $1"
}

# 解析 Section 格式的配置文件 (POSIX 兼容版本)
parse_section_config() {
    conf_file="$1"
    section="$2"
    in_section=0
    
    while IFS= read -r line || [ -n "$line" ]; do
        # 去除首尾空格 (POSIX 兼容)
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 跳过空行和注释
        [ -z "$line" ] && continue
        case "$line" in \#*) continue;; esac
        
        # 检测 Section 标记
        case "$line" in
            \[*\])
                current_section=$(echo "$line" | sed 's/^\[\(.*\)\]$/\1/')
                if [ "$current_section" = "$section" ]; then
                    in_section=1
                else
                    in_section=0
                fi
                continue
                ;;
        esac
        
        # 如果在目标 Section 中，导出变量
        if [ "$in_section" -eq 1 ]; then
            case "$line" in
                *=*)
                    key=$(echo "$line" | cut -d= -f1)
                    value=$(echo "$line" | cut -d= -f2-)
                    export "$key=$value"
                    ;;
            esac
        fi
    done < "$conf_file"
}

# 检查角色配置
if [ ! -f "$ROLE_CONF" ]; then
    log_warn "未找到角色配置，跳过代理检查"
    exit 0
fi

# 检测配置并读取任一启用的 Section
PROXY_ENABLED=""
PROXY_DIRECTION=""
ACTIVE_ROLE=""

# 先尝试读取 [CLIENT] section
parse_section_config "$ROLE_CONF" "CLIENT"
if [ "$PROXY_ENABLED" = "true" ]; then
    ACTIVE_ROLE="client"
else
    # 如果 CLIENT 未启用，尝试 [SERVER] section
    unset PROXY_ENABLED PROXY_DIRECTION NODE_REGION
    parse_section_config "$ROLE_CONF" "SERVER"
    if [ "$PROXY_ENABLED" = "true" ]; then
        ACTIVE_ROLE="server"
    fi
fi

# 检查是否启用
if [ "$PROXY_ENABLED" != "true" ]; then
    log_info "代理未启用，跳过"
    exit 0
fi

log_info "代理已启用 - 角色: $ACTIVE_ROLE, 方向: $PROXY_DIRECTION"

# ========================================
# 检查配置文件完整性
# ========================================

# 检查 proxy_peers.conf
if [ ! -f "$PEERS_CONF" ]; then
    log_error "代理节点配置不存在: proxy_peers.conf"
    log_error "请运行: mynet_proxy setup --role $ACTIVE_ROLE ..."
    exit 1
fi

# 检查 IP 列表文件（仅 Client outbound 需要）
case "$PROXY_DIRECTION" in
    outbound)
        if [ ! -f "$MYNET_HOME/conf/proxy/proxy_outbound.txt" ]; then
            log_error "proxy_outbound.txt 不存在"
            log_error "请运行: mynet_proxy ipconfig"
            exit 1
        fi
        log_info "✓ IP 列表: proxy_outbound.txt"
        ;;
    inbound)
        # Server inbound 模式：不需要 whitelist 文件
        # 放行规则通过 route.conf 从 node peers 自动生成
        log_info "✓ Server 模式：无需 whitelist 文件（自动生成放行规则）"
        ;;
    both)
        # Both 模式：只检查 outbound 文件
        if [ ! -f "$MYNET_HOME/conf/proxy/proxy_outbound.txt" ]; then
            log_error "proxy_outbound.txt 不存在"
            log_error "请运行: mynet_proxy ipconfig"
            exit 1
        fi
        log_info "✓ IP 列表: proxy_outbound.txt"
        ;;
esac

# 检查策略路由配置（Client 模式需要）
if [ "$ACTIVE_ROLE" = "client" ] || [ "$ACTIVE_ROLE" = "both" ]; then
    if [ ! -f "$ROUTE_CONF" ]; then
        log_warn "策略路由配置不存在: proxy_route.conf"
        log_info "将在服务启动后自动生成"
    else
        route_count=$(grep -v "^#" "$ROUTE_CONF" | grep -v "^$" | wc -l | tr -d ' ')
        log_info "✓ 策略路由: proxy_route.conf ($route_count 条)"
    fi
fi

# 检查 GNB route.conf 中的代理路由标记
LOCAL_NODE_ID=""
if [ -f "$MYNET_HOME/conf/mynet.conf" ]; then
    # 从 mynet.conf 注释中提取节点 ID
    LOCAL_NODE_ID=$(grep "^# Node:" "$MYNET_HOME/conf/mynet.conf" 2>/dev/null | \
                    sed -n 's/.*ID: \([0-9]*\).*/\1/p' | head -1)
fi

if [ -n "$LOCAL_NODE_ID" ]; then
    gnb_route_conf="$MYNET_HOME/driver/gnb/conf/$LOCAL_NODE_ID/route.conf"
    
    if [ -f "$gnb_route_conf" ]; then
        # 检查是否有代理路由标记
        if grep -q "#---------proxy start" "$gnb_route_conf" 2>/dev/null; then
            proxy_node_count=$(grep -c "#---------proxy start" "$gnb_route_conf" 2>/dev/null || echo "0")
            log_info "✓ GNB 路由: 已配置 $proxy_node_count 个代理节点的放行路由"
        else
            log_warn "GNB route.conf 中未找到代理路由标记"
            
            # 检查是否存在 proxy_peers.conf（已配置代理节点）
            if [ -f "$MYNET_HOME/conf/proxy/proxy_peers.conf" ]; then
                log_info "检测到 proxy_peers.conf 存在，自动应用 GNB 固定放行路由..."
                
                # 调用 mynet_proxy apply-routes 自动插入路由（使用绝对路径）
                mynet_proxy_bin="$MYNET_HOME/bin/mynet_proxy"
                if [ -x "$mynet_proxy_bin" ]; then
                    if "$mynet_proxy_bin" apply-routes --no-backup; then
                        log_success "✓ 已自动应用 GNB 固定放行路由"
                    else
                        log_error "❌ 应用路由失败，请手动运行: $mynet_proxy_bin apply-routes"
                        exit 1
                    fi
                else
                    log_error "❌ mynet_proxy 命令未找到: $mynet_proxy_bin"
                    log_info "请手动运行: mynet_proxy apply-routes"
                    exit 1
                fi
            else
                log_info "未找到 proxy_peers.conf，这可能是首次配置"
                log_info "请先运行: mynet_proxy setup --role client/server ..."
            fi
        fi
    else
        log_warn "GNB route.conf 不存在: $gnb_route_conf"
    fi
else
    log_warn "无法确定本地节点 ID，跳过 GNB 路由检查"
fi

# ========================================
# 配置检查完成
# ========================================

log_success "配置检查完成，准备启动 GNB"

exit 0
