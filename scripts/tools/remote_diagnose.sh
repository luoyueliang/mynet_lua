#!/usr/bin/env bash
# MyNet - 远程诊断助手
# 用于在远程设备上执行网络诊断

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# 检查参数
if [ $# -lt 1 ]; then
    cat << EOF
用法: $0 <host> [action]

远程诊断工具 - 在远程 OpenWrt 设备上执行诊断

参数:
  host     - 远程主机地址 (如: root@192.168.0.2)
  action   - 执行的操作 (默认: all)

操作:
  all              - 执行所有诊断
  masq             - 检查 masquerade 配置
  network          - 检查网络接口状态
  firewall         - 检查防火墙规则
  mynet-status     - 检查 mynet 服务状态
  connectivity     - 测试到目标节点的连通性

示例:
  $0 root@192.168.0.2              # 完整诊断
  $0 root@192.168.0.2 masq         # 仅检查 masq
  $0 root@192.168.0.2 connectivity # 测试连通性
EOF
    exit 1
fi

HOST="$1"
ACTION="${2:-all}"

# SSH 连接测试
print_info "测试 SSH 连接到 $HOST..."
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$HOST" "echo 'SSH OK'" >/dev/null 2>&1; then
    print_error "无法连接到 $HOST"
    print_info "请确保:"
    echo "  1. 主机地址正确"
    echo "  2. SSH 服务正在运行"
    echo "  3. 防火墙允许 SSH 连接"
    echo "  4. SSH 密钥已配置（或使用密码）"
    exit 1
fi
print_success "SSH 连接正常"

# 检查是否为 OpenWrt
print_info "检查系统类型..."
if ssh "$HOST" "[ -f /etc/openwrt_release ]"; then
    print_success "确认为 OpenWrt 系统"
else
    print_error "目标系统不是 OpenWrt"
    exit 1
fi

# 执行诊断
case "$ACTION" in
    all|masq)
        print_info "检查 MASQUERADE 配置..."
        ssh "$HOST" bash << 'ENDSSH'
echo "=== nftables NAT 规则 ==="
nft list table inet fw4 2>/dev/null | grep -A 10 "chain srcnat" || echo "未找到 srcnat 链"
echo ""
echo "=== MASQUERADE 规则 ==="
nft list table inet fw4 2>/dev/null | grep -i masquerade || echo "未找到 masquerade 规则"
echo ""
echo "=== Firewall 配置 ==="
grep -A 3 "option masq" /etc/config/firewall 2>/dev/null || echo "未找到 masq 配置"
ENDSSH
        [ "$ACTION" != "all" ] && exit 0
        ;;& # 继续执行下一个 case（bash 4.0+）

    all|network)
        print_info "检查网络接口..."
        ssh "$HOST" bash << 'ENDSSH'
echo "=== MyNet 接口 ==="
ip addr show | grep -A 5 mynet || echo "未找到 mynet 接口"
echo ""
echo "=== 路由表 ==="
ip route show | grep mynet || echo "未找到 mynet 路由"
ENDSSH
        [ "$ACTION" != "all" ] && exit 0
        ;;&

    all|firewall)
        print_info "检查防火墙规则..."
        ssh "$HOST" bash << 'ENDSSH'
echo "=== Forward 链 ==="
nft list table inet fw4 2>/dev/null | grep -A 10 "chain forward" || echo "未找到 forward 链"
echo ""
echo "=== Zone 配置 ==="
grep -A 5 "config zone" /etc/config/firewall | grep -A 5 "mynet\|lan" || true
ENDSSH
        [ "$ACTION" != "all" ] && exit 0
        ;;&

    all|mynet-status)
        print_info "检查 MyNet 服务状态..."
        ssh "$HOST" bash << 'ENDSSH'
if command -v mynet >/dev/null 2>&1; then
    echo "MyNet 版本:"
    mynet --version 2>&1 || echo "无法获取版本"
    echo ""
    echo "MyNet 状态:"
    mynet status 2>&1 || echo "无法获取状态"
else
    echo "MyNet 未安装"
fi
ENDSSH
        [ "$ACTION" != "all" ] && exit 0
        ;;&

    all|connectivity)
        print_info "测试到 10.182.236.180 的连通性..."
        ssh "$HOST" bash << 'ENDSSH'
echo "=== Ping 测试 ==="
ping -c 5 -W 2 10.182.236.180 2>&1 || echo "Ping 失败"
echo ""
echo "=== 路由追踪 ==="
if command -v traceroute >/dev/null 2>&1; then
    traceroute -m 10 -w 2 10.182.236.180 2>&1 | head -n 15
elif command -v tracepath >/dev/null 2>&1; then
    tracepath 10.182.236.180 2>&1 | head -n 15
else
    echo "traceroute 不可用"
fi
ENDSSH
        [ "$ACTION" != "all" ] && exit 0
        ;;&

    *)
        print_error "未知操作: $ACTION"
        exit 1
        ;;
esac

print_success "诊断完成"
