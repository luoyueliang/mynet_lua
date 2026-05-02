#!/usr/bin/env bash
# dns-split.sh — 在 OpenWrt VM 上配置 dnsmasq DNS 分流
#
# 原理：
#   国内域名 → 114.114.114.114 / 223.5.5.5（直连，拿到国内 CDN）
#   海外域名 → 10.182.236.180（GNB peer，干净 DNS）
#
# 数据来源：
#   - gfwlist（被墙域名，~4000 条）→ 自动下载解析
#   - extra-domains.conf（gfwlist 未收录的）→ 手动维护
#
# 用法：
#   bash debug/dns-split.sh setup    首次配置
#   bash debug/dns-split.sh update   更新 gfwlist
#   bash debug/dns-split.sh status   查看状态

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER="openwrt-qemu"
PEER_DNS="10.182.236.180"
DOMESTIC_DNS="114.114.114.114 223.5.5.5"
PARSER="$SCRIPT_DIR/parse_gfwlist.py"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

ssh_vm() {
    ssh $SSH_OPTS "$ROUTER" "$@"
}

# ── setup ────────────────────────────────────────────────

cmd_setup() {
    echo "[dns-split] 安装依赖..."
    ssh_vm "opkg update >/dev/null 2>&1; opkg install python3-light curl >/dev/null 2>&1 || true"

    echo "[dns-split] 上传解析器..."
    scp $SSH_OPTS "$PARSER" "$ROUTER:/tmp/parse_gfwlist.py" 2>/dev/null

    echo "[dns-split] 配置 dnsmasq..."
    ssh_vm "
        # 默认走国内 DNS
        uci -q delete dhcp.@dnsmasq[0].server
        for dns in $DOMESTIC_DNS; do
            uci add_list dhcp.@dnsmasq[0].server=\"\$dns\"
        done
        uci set dhcp.@dnsmasq[0].noresolv='1'
        uci add_list dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
        uci commit dhcp

        mkdir -p /etc/dnsmasq.d
    "

    echo "[dns-split] 创建 extra-domains.conf..."
    ssh_vm "
        cat > /etc/dnsmasq.d/extra-domains.conf << 'EXTRA'
# gfwlist 未收录但需要走代理的域名
server=/npmjs.com/$PEER_DNS
server=/npmjs.org/$PEER_DNS
server=/pypi.org/$PEER_DNS
EXTRA
    "

    echo "[dns-split] 下载并解析 gfwlist..."
    cmd_update

    echo "[dns-split] 配置 cron 每日更新..."
    ssh_vm "
        cat > /usr/bin/update-gfwlist << 'CRON'
#!/bin/sh
LOG=/var/log/gfwlist-update.log
echo \"\$(date) updating gfwlist...\" >> \$LOG
curl -s --max-time 60 -o /tmp/gfwlist.txt 'https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt' 2>/dev/null
[ -s /tmp/gfwlist.txt ] || curl -s --max-time 60 -o /tmp/gfwlist.txt 'https://ghproxy.net/https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt' 2>/dev/null
[ -s /tmp/gfwlist.txt ] || { echo \"  download failed\" >> \$LOG; exit 1; }
python3 /tmp/parse_gfwlist.py >> \$LOG 2>&1
/etc/init.d/dnsmasq restart 2>/dev/null
echo \"  done\" >> \$LOG
CRON
        chmod +x /usr/bin/update-gfwlist
        echo '0 2 * * * /usr/bin/update-gfwlist' > /etc/cron.d/gfwlist-update
        /etc/init.d/cron restart 2>/dev/null
    "

    echo "[dns-split] 完成 ✓"
}

# ── update ───────────────────────────────────────────────

cmd_update() {
    echo "[dns-split] 下载 gfwlist..."
    ssh_vm "
        curl -s --max-time 60 -o /tmp/gfwlist.txt 'https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt' 2>/dev/null
        if [ ! -s /tmp/gfwlist.txt ]; then
            curl -s --max-time 60 -o /tmp/gfwlist.txt 'https://ghproxy.net/https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt' 2>/dev/null
        fi
        [ -s /tmp/gfwlist.txt ] || { echo '下载失败'; exit 1; }
    "

    echo "[dns-split] 解析并生成 dnsmasq 配置..."
    scp $SSH_OPTS "$PARSER" "$ROUTER:/tmp/parse_gfwlist.py" 2>/dev/null
    local count
    count=$(ssh_vm "python3 /tmp/parse_gfwlist.py 2>&1")
    echo "[dns-split] $count"

    echo "[dns-split] 重启 dnsmasq..."
    ssh_vm "/etc/init.d/dnsmasq restart 2>/dev/null"
    echo "[dns-split] 更新完成 ✓"
}

# ── status ───────────────────────────────────────────────

cmd_status() {
    echo "=== dnsmasq 配置 ==="
    ssh_vm "uci show dhcp.@dnsmasq[0].server 2>/dev/null; echo ''; cat /tmp/etc/dnsmasq.conf.* 2>/dev/null | grep -E 'server|conf-dir' | head -5 || cat /var/etc/dnsmasq.conf.* 2>/dev/null | grep -E 'server|conf-dir' | head -5"

    echo ""
    echo "=== gfwlist 规则数 ==="
    ssh_vm "wc -l /etc/dnsmasq.d/gfwlist.conf 2>/dev/null; wc -l /etc/dnsmasq.d/extra-domains.conf 2>/dev/null"

    echo ""
    echo "=== 测试解析 ==="
    echo -n "  百度: "
    ssh_vm "nslookup -type=A www.baidu.com 127.0.0.1 2>&1 | grep 'Address:' | tail -1"
    echo -n "  Google: "
    ssh_vm "nslookup -type=A www.google.com 127.0.0.1 2>&1 | grep 'Address:' | tail -1"

    echo ""
    echo "=== cron ==="
    ssh_vm "cat /etc/cron.d/gfwlist-update 2>/dev/null || echo '未配置'"
}

# ── main ─────────────────────────────────────────────────

case "${1:-}" in
    setup)  cmd_setup ;;
    update) cmd_update ;;
    status) cmd_status ;;
    *)
        echo "用法: bash debug/dns-split.sh [setup|update|status]"
        echo "  setup   首次配置 dnsmasq DNS 分流"
        echo "  update  更新 gfwlist"
        echo "  status  查看状态"
        exit 1
        ;;
esac
