#!/bin/bash
#
# NFT 策略路由调试脚本
# 用于诊断为什么某个 IP 没有走预期的代理路由
#
# 用法:
#   ./debug_route.sh <目标IP>
#   例如: ./debug_route.sh 199.16.158.182

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
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

log_result() {
    echo -e "${MAGENTA}[结果]${NC} $1"
}

# 检查参数
if [[ $# -lt 1 ]]; then
    echo "用法: $0 <目标IP> [源IP]"
    echo ""
    echo "示例:"
    echo "  $0 199.16.158.182"
    echo "  $0 199.16.158.182 192.168.4.100"
    echo ""
    echo "说明:"
    echo "  目标IP: 要测试的目标地址"
    echo "  源IP:   (可选) 指定源地址，用于测试特定客户端"
    exit 1
fi

TARGET_IP="$1"
SOURCE_IP="${2:-}"

echo ""
echo "========================================"
echo "  NFT 策略路由调试工具"
echo "========================================"
echo ""
log_info "目标 IP: $TARGET_IP"
if [[ -n "$SOURCE_IP" ]]; then
    log_info "源 IP:   $SOURCE_IP"
fi
echo ""

# ============================================================
# 步骤 1: 检查 nftables 规则集
# ============================================================
echo "========================================"
log_step "步骤 1: 检查 nftables 规则集"
echo "========================================"
echo ""

# 1.1 查找包含该 IP 的 set
log_info "1.1 查找包含目标 IP 的 nft set..."
echo ""

nft list sets 2>/dev/null | grep -E "^[[:space:]]*(table|set)" | while read line; do
    if [[ "$line" =~ ^[[:space:]]*table ]]; then
        current_table=$(echo "$line" | awk '{print $2, $3}')
    elif [[ "$line" =~ ^[[:space:]]*set ]]; then
        set_name=$(echo "$line" | awk '{print $2}')
        full_name="$current_table $set_name"
        
        # 检查该 set 是否包含目标 IP 或其所属网段
        if nft list set $full_name 2>/dev/null | grep -q "elements"; then
            echo "检查 set: $full_name"
        fi
    fi
done

echo ""
log_info "直接搜索包含目标 IP 或其网段的 set..."
echo ""

# 提取目标 IP 的前缀用于匹配网段
IP_PREFIX=$(echo "$TARGET_IP" | cut -d. -f1-2)

nft list ruleset 2>/dev/null | grep -B 2 "$IP_PREFIX" | grep -E "set.*\{" | head -5

echo ""
log_warning "如果上面没有输出，说明该 IP 可能不在任何 nft set 中！"
echo ""

# 1.2 查看完整的代理相关 set
log_info "1.2 查看代理相关的 nft set..."
echo ""

for set_name in proxy_ips proxy_ipv4 proxy_whitelist mynet_proxy china_ip inter_ip; do
    for table in "inet fw4" "ip fw4" "inet filter"; do
        if nft list set $table $set_name 2>/dev/null | head -20; then
            echo ""
            log_success "找到 set: $table $set_name"
            echo ""
            
            # 检查元素数量
            if nft list set $table $set_name 2>/dev/null | grep -q "elements"; then
                log_info "该 set 包含元素"
            else
                log_warning "该 set 为空！"
            fi
            echo ""
            break
        fi
    done
done

# ============================================================
# 步骤 2: 检查 nftables 规则链
# ============================================================
echo "========================================"
log_step "步骤 2: 检查 nftables 规则链"
echo "========================================"
echo ""

log_info "2.1 查看 mangle prerouting 链（用于打标记）..."
echo ""

for chain in mangle_prerouting prerouting; do
    for table in "inet fw4" "ip fw4" "inet filter"; do
        if nft list chain $table $chain 2>/dev/null; then
            log_success "找到 chain: $table $chain"
            echo ""
            break
        fi
    done
done

echo ""
log_info "2.2 查看 mynet_proxy table 的完整规则..."
echo ""

nft list table inet mynet_proxy 2>/dev/null || log_warning "mynet_proxy table 不存在"

echo ""
log_info "2.3 检查 fw4 mangle_prerouting 是否调用了 mynet_proxy..."
echo ""

nft -a list chain inet fw4 mangle_prerouting 2>/dev/null | grep -E "(jump|goto|mynet)" || log_warning "fw4 未调用 mynet_proxy 规则"

echo ""
log_info "2.4 查找所有与代理相关的规则..."
echo ""

nft list ruleset 2>/dev/null | grep -i -E "(proxy|mark|0x1|0xc8)" | head -30

# ============================================================
# 步骤 3: 检查策略路由规则
# ============================================================
echo ""
echo "========================================"
log_step "步骤 3: 检查策略路由规则"
echo "========================================"
echo ""

log_info "3.1 查看所有路由规则 (ip rule)..."
echo ""

ip rule list

echo ""
log_info "3.2 查找代理相关的路由规则..."
echo ""

ip rule list | grep -E "(mark|0x1|100|101|102)" | while read rule; do
    log_result "$rule"
done

if ! ip rule list | grep -q "mark"; then
    echo ""
    log_error "未找到基于 mark 的策略路由规则！"
    log_warning "这可能是问题所在：即使 nft 打了标记，也没有对应的路由规则"
fi

# ============================================================
# 步骤 4: 检查路由表
# ============================================================
echo ""
echo "========================================"
log_step "步骤 4: 检查路由表"
echo "========================================"
echo ""

log_info "4.1 查看所有自定义路由表..."
echo ""

if [[ -f /etc/iproute2/rt_tables ]]; then
    grep -v "^#" /etc/iproute2/rt_tables | grep -v "^$" | tail -10
fi

echo ""
log_info "4.2 查看代理路由表（table 100-102 和 mynet_proxy）..."
echo ""

# 检查常见的路由表
for table_id in 100 101 102 200; do
    echo "--- Table $table_id ---"
    if ip route show table $table_id 2>/dev/null | grep -q .; then
        ip route show table $table_id
        echo ""
    else
        log_warning "路由表 $table_id 为空"
        echo ""
    fi
done

# 检查 mynet_proxy 路由表
echo "--- Table mynet_proxy ---"
if ip route show table mynet_proxy 2>/dev/null | grep -q .; then
    ip route show table mynet_proxy
    log_success "mynet_proxy 路由表有配置"
    echo ""
else
    log_warning "路由表 mynet_proxy 为空"
    echo ""
fi

# ============================================================
# 步骤 5: 测试路由决策
# ============================================================
echo ""
echo "========================================"
log_step "步骤 5: 测试路由决策"
echo "========================================"
echo ""

log_info "5.1 查看默认路由决策..."
echo ""

if [[ -n "$SOURCE_IP" ]]; then
    ip route get "$TARGET_IP" from "$SOURCE_IP" 2>/dev/null || log_error "路由查询失败"
else
    ip route get "$TARGET_IP" 2>/dev/null || log_error "路由查询失败"
fi

echo ""
log_info "5.2 测试带 mark 的路由决策（模拟 nft 打标记后）..."
echo ""

# 测试常见的 mark 值
for mark_val in 0x1 0xc8 200; do
    echo "测试 mark $mark_val:"
    if [[ -n "$SOURCE_IP" ]]; then
        ip route get "$TARGET_IP" from "$SOURCE_IP" mark $mark_val 2>/dev/null || log_warning "无法测试 mark $mark_val"
    else
        ip route get "$TARGET_IP" mark $mark_val 2>/dev/null || log_warning "无法测试 mark $mark_val"
    fi
    echo ""
done

# ============================================================
# 步骤 6: 查看 proxy.sh 状态
# ============================================================
echo ""
echo "========================================"
log_step "步骤 6: 查看 proxy.sh 状态"
echo "========================================"
echo ""

if [[ -f /etc/mynet/scripts/proxy.sh ]]; then
    /etc/mynet/scripts/proxy.sh status 2>/dev/null || log_warning "无法获取 proxy.sh 状态"
else
    log_warning "未找到 /etc/mynet/scripts/proxy.sh"
fi

# ============================================================
# 步骤 7: 实时流量测试
# ============================================================
echo ""
echo "========================================"
log_step "步骤 7: 实时流量测试"
echo "========================================"
echo ""

log_info "7.1 监控 nft 计数器（10秒）..."
echo ""

# 获取初始计数
echo "初始状态:"
nft list table inet mynet_proxy 2>/dev/null | grep "counter packets"

echo ""
log_info "等待 10 秒，期间请从客户端访问 $TARGET_IP..."
sleep 10

echo ""
echo "10秒后状态:"
nft list table inet mynet_proxy 2>/dev/null | grep "counter packets"

echo ""
log_info "7.2 检查接口流量..."
echo ""

log_info "gnb_tun 接口统计（发送方向）:"
ip -s link show gnb_tun 2>/dev/null | grep -A 1 "TX:" || log_warning "无法获取接口统计"

echo ""
log_info "是否进行抓包测试？"
read -p "按 Enter 跳过，或输入 'yes' 开始抓包: " do_capture

if [[ "$do_capture" == "yes" ]]; then
    log_info "开始抓包，请从客户端访问 $TARGET_IP..."
    log_info "按 Ctrl+C 停止抓包"
    echo ""
    
    timeout 30 tcpdump -i any -n host "$TARGET_IP" 2>/dev/null || log_info "抓包结束"
fi

# ============================================================
# 步骤 8: 诊断总结
# ============================================================
echo ""
echo "========================================"
log_step "步骤 8: 诊断总结"
echo "========================================"
echo ""

# 检查点 1: nft set
echo "✓ 检查点 1: NFT Set"

# 检查 mynet_proxy set 是否为空
set_empty=false
if nft list set inet mynet_proxy mynet_proxy 2>/dev/null | grep -q "elements = { }"; then
    set_empty=true
    log_error "mynet_proxy set 为空！这是核心问题！"
    echo "  → 原因: proxy_route.conf 可能没有正确加载到 nft set"
    echo "  → 检查配置文件:"
    if [[ -f /etc/mynet/conf/proxy/proxy_route.conf ]]; then
        line_count=$(wc -l < /etc/mynet/conf/proxy/proxy_route.conf 2>/dev/null || echo "0")
        echo "     /etc/mynet/conf/proxy/proxy_route.conf: $line_count 行"
        if [[ "$line_count" -gt 0 ]]; then
            echo "  → 配置文件有内容，但未加载到 nft set"
            echo "  → 解决方法: /etc/mynet/scripts/proxy.sh start"
        else
            echo "  → 配置文件为空！"
            echo "  → 解决方法: MYNET_HOME=/etc/mynet /etc/mynet/bin/mynet_proxy config --force"
        fi
    else
        echo "     配置文件不存在！"
        echo "  → 解决方法: MYNET_HOME=/etc/mynet /etc/mynet/bin/mynet_proxy config --force"
    fi
elif nft list ruleset 2>/dev/null | grep -q "$IP_PREFIX"; then
    log_success "目标 IP 网段存在于 nft set 中"
else
    log_warning "目标 IP 网段不在 nft set 中，但 set 不为空"
    echo "  → 可能原因: 该网段不在代理列表中"
    echo "  → 解决方法: 检查 proxy_outbound.txt 或 proxy_whitelist.txt 是否包含该网段"
fi

# 检查点 2: nft 规则
echo ""
echo "✓ 检查点 2: NFT 标记规则"
if nft list ruleset 2>/dev/null | grep -q "mark set"; then
    log_success "存在 nft 标记规则"
    
    # 检查 PREROUTING 和 OUTPUT 链
    echo ""
    echo "  检查规则链配置:"
    
    if nft list table inet mynet_proxy 2>/dev/null | grep -q "chain PREROUTING"; then
        log_success "  ✓ PREROUTING 链存在（处理客户端流量）"
    else
        log_error "  ✗ PREROUTING 链不存在"
    fi
    
    if nft list table inet mynet_proxy 2>/dev/null | grep -q "chain OUTPUT"; then
        log_success "  ✓ OUTPUT 链存在（处理路由器本地流量）"
    else
        log_warning "  ! OUTPUT 链不存在"
    fi
    
    # 关键检查：fw4 是否调用了 mynet_proxy
    echo ""
    echo "  检查链调用关系:"
    if nft list chain inet fw4 mangle_prerouting 2>/dev/null | grep -qE "(jump|goto).*mynet"; then
        log_success "  ✓ fw4 mangle_prerouting 调用了 mynet_proxy"
    else
        log_error "  ✗ fw4 mangle_prerouting 未调用 mynet_proxy"
        echo "     → 这是关键问题！客户端流量不会被标记！"
        echo "     → 解决方法: 在 fw4 mangle_prerouting 中添加:"
        echo "        nft add rule inet fw4 mangle_prerouting jump mynet_proxy_PREROUTING"
    fi
else
    log_error "未找到 nft 标记规则"
    echo "  → 解决方法: 检查 nft 规则是否正确应用"
fi

# 检查点 3: 策略路由
echo ""
echo "✓ 检查点 3: 策略路由规则"
if ip rule list | grep -q "mark"; then
    log_success "存在基于 mark 的策略路由规则"
else
    log_error "未找到策略路由规则"
    echo "  → 解决方法: 执行 'ip rule add fwmark 0x1 table 100'"
fi

# 检查点 4: 路由表
echo ""
echo "✓ 检查点 4: 代理路由表"
has_route=false

# 检查多个可能的路由表
for table_id in 100 101 102 200 mynet_proxy; do
    if ip route show table $table_id 2>/dev/null | grep -q .; then
        has_route=true
        log_success "路由表 $table_id 包含路由"
        break
    fi
done

if [[ "$has_route" == "false" ]]; then
    log_error "所有代理路由表都为空"
    echo "  → 解决方法: 添加路由 'ip route add default via <VPN_GATEWAY> dev gnb_tun table mynet_proxy'"
fi

# ============================================================
# 快速修复建议
# ============================================================
echo ""
echo "========================================"
log_step "快速修复建议"
echo "========================================"
echo ""

log_info "如果上述检查发现问题，可以尝试以下修复："
echo ""
echo "1. 重新生成配置:"
echo "   MYNET_HOME=/etc/mynet /etc/mynet/bin/mynet_proxy config --force"
echo ""
echo "2. 重新应用策略路由:"
echo "   MYNET_HOME=/etc/mynet /etc/mynet/scripts/proxy.sh restart"
echo ""
echo "3. 手动添加策略路由规则（针对 mynet_proxy）:"
echo "   ip rule add fwmark 0xc8 table mynet_proxy prio 31800"
echo ""
echo "4. 手动添加路由表（gnb_tun 接口）:"
echo "   ip route add default dev gnb_tun table mynet_proxy"
echo "   # 或指定网关:"
echo "   # ip route add default via 10.182.236.1 dev gnb_tun table mynet_proxy"
echo ""
echo "5. 检查 nft set 是否为空（关键问题）:"
echo "   nft list set inet mynet_proxy mynet_proxy"
echo "   # 如果为空，检查配置文件:"
echo "   cat /etc/mynet/conf/proxy/proxy_route.conf | wc -l"
echo ""
echo "6. 在 fw4 mangle_prerouting 中调用 mynet_proxy（关键修复）:"
echo "   nft add rule inet fw4 mangle_prerouting jump mynet_proxy_PREROUTING"
echo "   # 或者在 OUTPUT 链调用:"
echo "   nft add rule inet fw4 mangle_output jump mynet_proxy_OUTPUT"
echo ""
echo "7. 检查防火墙规则优先级:"
echo "   nft -a list chain inet fw4 mangle_prerouting"
echo "   nft list table inet mynet_proxy"
echo ""
echo "8. 实时监控流量标记:"
echo "   watch -n 1 'nft list table inet mynet_proxy | grep counter'"
echo ""
echo "9. 查看 proxy.sh 状态:"
echo "   /etc/mynet/scripts/proxy.sh status"
echo ""
echo "10. 查看完整日志:"
echo "   logread | grep -i proxy"
echo ""

log_success "诊断完成！"
echo ""
