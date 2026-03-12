#!/bin/bash
# 部署 proxy 修复到 192.168.8.1

set -e

TARGET_HOST="${1:-root@192.168.8.1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

echo "========================================="
echo "  部署 proxy.sh 修复"
echo "  目标: $TARGET_HOST"
echo "========================================="
echo ""

# 检查 SSH 连接
log_info "检查 SSH 连接..."
if ! ssh -o ConnectTimeout=5 "$TARGET_HOST" "echo ok" >/dev/null 2>&1; then
    log_error "无法连接到 $TARGET_HOST"
    exit 1
fi
log_success "SSH 连接正常"

# 备份远程文件
log_info "备份远程文件..."
ssh "$TARGET_HOST" "
    mkdir -p /root/backup/proxy_fix_$(date +%Y%m%d_%H%M%S)
    [ -f /etc/mynet/scripts/proxy/route_policy.sh ] && cp -f /etc/mynet/scripts/proxy/route_policy.sh /root/backup/proxy_fix_*/route_policy.sh.bak
    echo '备份完成'
"
log_success "备份已创建"

# 上传修复后的文件
log_info "上传修复后的 route_policy.sh..."
scp -O "${SCRIPT_DIR}/openwrt/route_policy.sh" "$TARGET_HOST:/tmp/route_policy.sh"
log_success "文件已上传"

# 部署到正确位置
log_info "部署到目标位置..."
ssh "$TARGET_HOST" "
    # 确保目录存在
    mkdir -p /etc/mynet/scripts/proxy
    mkdir -p /etc/mynet/scripts
    mkdir -p /usr/local/mynet/scripts/proxy

    # 复制到多个可能的位置
    cp -f /tmp/route_policy.sh /etc/mynet/scripts/proxy/route_policy.sh
    cp -f /tmp/route_policy.sh /etc/mynet/scripts/proxy.sh           # 旧位置 (兼容)
    cp -f /tmp/route_policy.sh /usr/local/mynet/scripts/proxy/route_policy.sh

    # 设置可执行权限
    chmod +x /etc/mynet/scripts/proxy/route_policy.sh
    chmod +x /etc/mynet/scripts/proxy.sh
    chmod +x /usr/local/mynet/scripts/proxy/route_policy.sh

    # 清理临时文件
    rm -f /tmp/route_policy.sh

    echo '部署完成'
"
log_success "部署完成"

echo ""
log_info "测试修复后的 proxy.sh status..."
echo "--- 输出开始 ---"
echo ""

ssh "$TARGET_HOST" "export MYNET_HOME=/usr/local/mynet && /etc/mynet/scripts/proxy.sh status" || {
    log_warn "proxy.sh status 仍有问题，查看详细输出"
}

echo ""
echo "--- 输出结束 ---"
echo ""

echo "========================================="
log_success "修复部署完成!"
echo "========================================="
echo ""
echo "后续步骤:"
echo "  1. 如果仍有问题，运行诊断:"
echo "     ./scripts/proxy/run_diagnose_remote.sh"
echo ""
echo "  2. 检查配置:"
echo "     ssh $TARGET_HOST"
echo "     export MYNET_HOME=/usr/local/mynet"
echo "     /etc/mynet/scripts/proxy.sh status"
echo ""
echo "  3. 如需回滚:"
echo "     ssh $TARGET_HOST 'ls -lt /root/backup/proxy_fix_*'"
echo ""
