#!/bin/bash
#
# dns_split.sh — DNS 分流配置（dnsmasq + GFW list）
#
# 原理：
#   国内域名 → 国内 DNS（223.5.5.5, 119.29.29.29）→ 国内 CDN
#   海外域名 → 国外 DNS（8.8.8.8, 1.1.1.1）→ 干净 IP
#   国外 DNS 流量通过 GNB 隧道直接到 peer
#
# 用法：
#   ./dns_split.sh setup [domestic_dns] [foreign_dns]   配置 dnsmasq 分流
#   ./dns_split.sh update [foreign_dns]                 更新 GFW list
#   ./dns_split.sh status                               查看状态
#   ./dns_split.sh stop                                 清理配置
#

set -e

MYNET_HOME="${MYNET_HOME:-/etc/mynet}"
GFW_CONF="/etc/dnsmasq.d/gfwlist.conf"
EXTRA_CONF="/etc/dnsmasq.d/extra-domains.conf"

# 默认 DNS 服务器
DEFAULT_DOMESTIC_DNS="223.5.5.5,119.29.29.29"
DEFAULT_FOREIGN_DNS="8.8.8.8"

# ─── setup ─────────────────────────────────────────────────
cmd_setup() {
    local domestic_dns="${1:-$DEFAULT_DOMESTIC_DNS}"
    local foreign_dns="${2:-$DEFAULT_FOREIGN_DNS}"

    echo "[dns-split] 配置 dnsmasq DNS 分流..."
    echo "[dns-split]   国内 DNS: $domestic_dns"
    echo "[dns-split]   国外 DNS: $foreign_dns"

    # 配置 dnsmasq 默认上游为国内 DNS (UCI)
    uci -q del dhcp.@dnsmasq[0].server
    IFS=',' read -ra dns_list <<< "$domestic_dns"
    for dns in "${dns_list[@]}"; do
        dns=$(echo "$dns" | xargs)
        [ -n "$dns" ] && uci add_list dhcp.@dnsmasq[0].server="$dns"
    done
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci set dhcp.@dnsmasq[0].filter_aaaa='1'
    uci -q delete dhcp.@dnsmasq[0].confdir 2>/dev/null || true
    uci add_list dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
    uci commit dhcp

    # 确保 dnsmasq.d 目录存在（OpenWrt dnsmasq init 会自动加载这个目录下的 *.conf）
    mkdir -p /etc/dnsmasq.d

    # 创建 extra-domains.conf（GFW list 未收录的域名）
    cat > "$EXTRA_CONF" << EOF
# GFW list 未收录但需要走代理的域名
# 由 dns_split.sh 自动生成，可手动编辑
server=/npmjs.com/$foreign_dns
server=/npmjs.org/$foreign_dns
server=/pypi.org/$foreign_dns
server=/docker.com/$foreign_dns
server=/docker.io/$foreign_dns
server=/githubusercontent.com/$foreign_dns
server=/cloudflare.com/$foreign_dns
server=/openai.com/$foreign_dns
server=/anthropic.com/$foreign_dns
EOF

    # 下载并解析 GFW list
    cmd_update "$foreign_dns"

    # 重载 dnsmasq（reload 足够，避免中断 in-flight 查询）
    /etc/init.d/dnsmasq reload 2>/dev/null
    echo "[dns-split] ✓ dnsmasq split DNS 配置完成"
}

# ─── update ─────────────────────────────────────────────────
cmd_update() {
    local foreign_dns="${1:-$DEFAULT_FOREIGN_DNS}"
    local gfw_tmp="/tmp/gfwlist.txt"

    echo "[dns-split] 下载 GFW list..."
    curl -s --max-time 60 -o "$gfw_tmp" \
        'https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt' 2>/dev/null
    if [ ! -s "$gfw_tmp" ]; then
        curl -s --max-time 60 -o "$gfw_tmp" \
            'https://ghproxy.net/https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt' 2>/dev/null
    fi
    if [ ! -s "$gfw_tmp" ]; then
        echo "[dns-split] GFW list 下载失败"
        if [ -s "$GFW_CONF" ]; then
            local cnt
            cnt=$(wc -l < "$GFW_CONF")
            echo "[dns-split] ⚠ 使用已有本地 gfwlist.conf (${cnt} 条)"
            return 0
        fi
        echo "[dns-split] ERROR: 无本地缓存，split DNS 无法配置"
        return 1
    fi

    # 解析 GFW list（内联 Python）
    python3 - "$gfw_tmp" "$GFW_CONF" "$foreign_dns" << 'PYTHON'
import base64, re, sys

gfw_file, out_file, dns_server = sys.argv[1], sys.argv[2], sys.argv[3]

with open(gfw_file) as f:
    text = f.read()

decoded = base64.b64decode(text).decode("utf-8", errors="ignore")
domains = set()

for line in decoded.split("\n"):
    line = line.strip()
    if not line or line[0] in ("!", "@", "["):
        continue
    line = line.lstrip("||").lstrip("|").lstrip(".")
    m = re.match(r"([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}", line)
    if m:
        d = m.group(0).lower()
        if d.endswith(".cn") or d.endswith(".com.cn"):
            continue
        parts = d.split(".")
        for i in range(len(parts) - 1):
            sub = ".".join(parts[i:])
            if len(sub.split(".")) >= 2:
                domains.add(sub)

with open(out_file, "w") as f:
    for d in sorted(domains):
        f.write(f"server=/{d}/{dns_server}\n")

print(f"[dns-split] GFW list: {len(domains)} domains → {dns_server}")
PYTHON

    rm -f "$gfw_tmp"
    echo "[dns-split] ✓ GFW list 已更新"
}

# ─── status ─────────────────────────────────────────────────
cmd_status() {
    echo "=== dnsmasq DNS 分流状态 ==="

    echo ""
    echo "--- dnsmasq 上游配置 ---"
    uci show dhcp.@dnsmasq[0].server 2>/dev/null || echo "未配置"

    echo ""
    echo "--- confdir 配置 ---"
    uci show dhcp.@dnsmasq[0].confdir 2>/dev/null || echo "未配置"

    echo ""
    echo "--- GFW list 规则 ---"
    if [ -f "$GFW_CONF" ]; then
        local count
        count=$(wc -l < "$GFW_CONF")
        echo "文件: $GFW_CONF ($count 条)"
        echo "前 5 条:"
        head -5 "$GFW_CONF"
    else
        echo "未配置"
    fi

    echo ""
    echo "--- extra-domains 规则 ---"
    if [ -f "$EXTRA_CONF" ]; then
        local count
        count=$(grep -c "^server=" "$EXTRA_CONF" 2>/dev/null || echo 0)
        echo "文件: $EXTRA_CONF ($count 条)"
    else
        echo "未配置"
    fi

    echo ""
    echo "--- DNS 解析测试 ---"
    echo -n "  百度 (www.baidu.com): "
    nslookup -type=A www.baidu.com 127.0.0.1 2>/dev/null | grep 'Address:' | tail -1 || echo "解析失败"
    echo -n "  Google (www.google.com): "
    nslookup -type=A www.google.com 127.0.0.1 2>/dev/null | grep 'Address:' | tail -1 || echo "解析失败"
}

# ─── stop ─────────────────────────────────────────────────
cmd_stop() {
    echo "[dns-split] 清理 DNS 分流配置..."

    # 删除 GFW list 配置
    rm -f "$GFW_CONF" 2>/dev/null
    rm -f "$EXTRA_CONF" 2>/dev/null

    # 恢复 dnsmasq 配置
    uci -q delete dhcp.@dnsmasq[0].confdir 2>/dev/null || true
    uci set dhcp.@dnsmasq[0].noresolv='0' 2>/dev/null || true
    uci set dhcp.@dnsmasq[0].filter_aaaa='0' 2>/dev/null || true
    uci -q del dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server='223.5.5.5'
    uci add_list dhcp.@dnsmasq[0].server='119.29.29.29'
    uci commit dhcp

    # 清理可能存在的旧版 dnsmasq.conf 注入段（升级兼容）
    local dnsmasq_conf="/etc/dnsmasq.conf"
    if [ -f "$dnsmasq_conf" ]; then
        sed -i '/^# mynet-dns-split-begin/,/^# mynet-dns-split-end/d' "$dnsmasq_conf"
    fi

    # 重载 dnsmasq
    /etc/init.d/dnsmasq reload 2>/dev/null
    echo "[dns-split] ✓ DNS 分流配置已清理"
}

# ─── 主入口 ─────────────────────────────────────────────────
case "${1:-}" in
    setup)  cmd_setup "$2" "$3" ;;
    update) cmd_update "$2" ;;
    status) cmd_status ;;
    stop)   cmd_stop ;;
    *)
        echo "用法: $0 {setup|update|status|stop}"
        echo ""
        echo "  setup [domestic_dns] [foreign_dns]   配置 dnsmasq DNS 分流"
        echo "  update [foreign_dns]                 更新 GFW list"
        echo "  status                               查看状态"
        echo "  stop                                 清理配置"
        echo ""
        echo "默认: 国内 DNS = $DEFAULT_DOMESTIC_DNS"
        echo "      国外 DNS = $DEFAULT_FOREIGN_DNS"
        exit 1
        ;;
esac
