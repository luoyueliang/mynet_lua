#!/bin/bash
#
# Proxy 插件后启动钩子
# 在 GNB 启动后执行
#
# 功能：
#   启动策略路由（仅 client/both 角色）
#

set -e

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
PROXY_SCRIPT="$MYNET_HOME/scripts/proxy.sh"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[Proxy Post-Start]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[Proxy Post-Start]${NC} $1"
}

log_error() {
    echo -e "${RED}[Proxy Post-Start]${NC} $1"
}

# 解析 Section 格式的配置文件
# 参数: $1=配置文件路径, $2=Section名称([CLIENT]或[SERVER])
parse_section_config() {
    local conf_file="$1"
    local section="$2"
    local in_section=false
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 去除首尾空格
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        # 检测 Section 标记
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            local current_section="${BASH_REMATCH[1]}"
            if [[ "$current_section" == "$section" ]]; then
                in_section=true
            else
                in_section=false
            fi
            continue
        fi
        
        # 如果在目标 Section 中，导出变量
        if [[ "$in_section" == true && "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            export "$key=$value"
        fi
    done < "$conf_file"
}

# 加载角色配置
if [[ ! -f "$ROLE_CONF" ]]; then
    log_warn "未找到角色配置，跳过"
    exit 0
fi

# 检测配置并收集所有启用的角色
ACTIVE_ROLES=""

# 检查 [CLIENT] section
unset PROXY_ENABLED PROXY_DIRECTION NODE_REGION
parse_section_config "$ROLE_CONF" "CLIENT"
if [[ "$PROXY_ENABLED" == "true" ]]; then
    ACTIVE_ROLES="client"
fi

# 检查 [SERVER] section
unset PROXY_ENABLED PROXY_DIRECTION NODE_REGION
parse_section_config "$ROLE_CONF" "SERVER"
if [[ "$PROXY_ENABLED" == "true" ]]; then
    ACTIVE_ROLES="$ACTIVE_ROLES server"
fi

# 去除前导空格
ACTIVE_ROLES=$(echo "$ACTIVE_ROLES" | xargs)

# 检查是否有启用的角色
if [[ -z "$ACTIVE_ROLES" ]]; then
    log_info "代理未启用，跳过"
    exit 0
fi

log_info "启用的角色: $ACTIVE_ROLES"

# 处理每个启用的角色
for role in $ACTIVE_ROLES; do
    # 重新解析当前角色的配置
    unset PROXY_ENABLED PROXY_DIRECTION NODE_REGION
    
    if [[ "$role" == "client" ]]; then
        parse_section_config "$ROLE_CONF" "CLIENT"
    elif [[ "$role" == "server" ]]; then
        parse_section_config "$ROLE_CONF" "SERVER"
    fi
    
    log_info "处理角色: $role (方向: $PROXY_DIRECTION, 区域: ${NODE_REGION:-未设置})"
    
    # 根据角色决定行为
    case "$role" in
        client)
            # Client 角色需要启动策略路由（将流量导向对端代理节点）
            log_info "Client 角色：启动策略路由..."
            
            # 检查 proxy.sh 是否存在
            if [[ ! -x "$PROXY_SCRIPT" ]]; then
                log_error "proxy.sh 不存在或不可执行: $PROXY_SCRIPT"
                exit 1
            fi
            
            # 等待 GNB 完全启动（tun 设备和路由就绪）
            log_info "等待 GNB 初始化..."
            sleep 2
            
            # 启动策略路由
            log_info "启动策略路由..."
            if "$PROXY_SCRIPT" start; then
                log_info "✓ 策略路由已启动"
            else
                log_error "✗ 策略路由启动失败"
                exit 1
            fi
            ;;
        server)
            # Server 角色只提供代理服务，不需要策略路由
            # GNB 路由放行已在 pre_start.sh 中处理
            log_info "Server 角色：仅提供代理服务，无需策略路由"
            log_info "✓ GNB 路由已启动，等待客户端连接"
            ;;
        *)
            log_error "未知角色: $role"
            exit 1
            ;;
    esac
done

log_info "✓ Proxy 插件启动完成"
exit 0
