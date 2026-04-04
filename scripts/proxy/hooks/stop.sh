#!/bin/bash
#
# Proxy 插件停止钩子
# 在 GNB 停止时执行
#
# 功能：
#   1. 停止策略路由（仅 client/both 角色）
#   2. 清理 route.conf 中的代理路由标记
#

set -e

# 日志捕获
if [ -n "$MYNET_HOME" ]; then
    mkdir -p "$MYNET_HOME/logs" 2>/dev/null || true
    exec >> "$MYNET_HOME/logs/hooks.log" 2>&1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] stop.sh"
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
ROUTE_CONF="$MYNET_HOME/conf/route.conf"
PROXY_SCRIPT="$MYNET_HOME/scripts/proxy.sh"

# 标记常量
MARKER_START="#----proxy start----"
MARKER_END="#----proxy end----"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[Proxy Stop]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[Proxy Stop]${NC} $1"
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
    log_warn "未找到角色配置"
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

log_info "停止角色: $ACTIVE_ROLES"

# 处理每个启用的角色
for role in $ACTIVE_ROLES; do
    case "$role" in
        client)
            # Client 角色需要停止策略路由
            if [[ -x "$PROXY_SCRIPT" ]]; then
                log_info "Client 角色：停止策略路由..."
                "$PROXY_SCRIPT" stop || true
                log_info "✓ 策略路由已停止"
            else
                log_warn "proxy.sh 不存在，跳过"
            fi
            ;;
        server)
            # Server 角色没有启动策略路由，无需停止
            log_info "Server 角色：无策略路由需要停止"
            ;;
        *)
            log_warn "未知角色: $role"
            ;;
    esac
done

# 清理 route.conf 中的代理路由标记
if [[ -f "$ROUTE_CONF" ]] && grep -q "$MARKER_START" "$ROUTE_CONF" 2>/dev/null; then
    log_info "清理 route.conf 中的代理路由标记..."
    
    # 使用 sed 删除标记之间的内容（包括标记行）
    sed -i.bak "/$MARKER_START/,/$MARKER_END/d" "$ROUTE_CONF"
    
    log_info "✓ 已清理代理路由标记"
fi

log_info "✓ 代理插件已停止"
exit 0
