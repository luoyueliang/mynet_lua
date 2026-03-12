#!/bin/bash
# 远程诊断 192.168.8.1 的 proxy.sh 问题

set -e

TARGET_HOST="${1:-root@192.168.8.1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAGNOSE_SCRIPT="${SCRIPT_DIR}/diagnose_proxy.sh"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

echo "========================================="
echo "  proxy.sh 远程诊断"
echo "  目标: $TARGET_HOST"
echo "========================================="
echo ""

# 检查诊断脚本
if [ ! -f "$DIAGNOSE_SCRIPT" ]; then
    log_error "诊断脚本不存在: $DIAGNOSE_SCRIPT"
    exit 1
fi

# 检查 SSH 连接
log_info "检查 SSH 连接..."
if ! ssh -o ConnectTimeout=5 "$TARGET_HOST" "echo ok" >/dev/null 2>&1; then
    log_error "无法连接到 $TARGET_HOST"
    exit 1
fi
log_success "SSH 连接正常"

# 上传并执行诊断脚本
log_info "上传诊断脚本..."
scp -O "$DIAGNOSE_SCRIPT" "$TARGET_HOST:/tmp/diagnose_proxy.sh"
log_success "脚本已上传"

echo ""
log_info "开始执行诊断..."
echo "========================================="
echo ""

ssh "$TARGET_HOST" "chmod +x /tmp/diagnose_proxy.sh && /tmp/diagnose_proxy.sh"

echo ""
echo "========================================="
log_success "诊断完成!"
echo ""
echo "后续步骤:"
echo "  1. 根据诊断结果修复问题"
echo "  2. 如需手动调试，SSH 登录:"
echo "     ssh $TARGET_HOST"
echo ""
