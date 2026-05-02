#!/usr/bin/env bash
# fix-network.sh — 通过 SSH 将 OpenWrt 网络配置修复为 vmnet 双网卡模式
#                  并将 opkg 源切换为清华镜像（downloads.openwrt.org 在国内被封）
#
# 网络配置：
#   LAN (eth0): vmnet-host 静态 192.168.101.2（管理口）
#   WAN (eth1): vmnet-bridged DHCP — 直接从家庭路由器获取 IP 和 DNS
#
# 用法：
#   bash debug/fix-network.sh        （虚拟机需已在运行且 SSH 可达）

set -euo pipefail

SSH_OPTS="-o StrictHostKeyChecking=no"
ROUTER="openwrt-qemu"

# 检查 SSH 是否可达
if ! ssh $SSH_OPTS $ROUTER "true" 2>/dev/null; then
    echo "[fix-network] SSH 不可达 ($ROUTER)"
    echo "              请先运行: bash debug/start.sh"
    exit 1
fi

echo "[fix-network] 配置 vmnet 双网卡（LAN=192.168.101.2, WAN=DHCP bridged）..."
ssh $SSH_OPTS $ROUTER '
    # WAN: vmnet-bridged — 直接从家庭路由器获取 IP 和 DNS，无需强制覆盖
    uci set network.wan=interface
    uci set network.wan.device="eth1"
    uci set network.wan.proto="dhcp"
    uci delete network.wan.peerdns 2>/dev/null || true
    uci delete network.wan.dns 2>/dev/null || true

    # WAN6: IPv6
    uci set network.wan6=interface
    uci set network.wan6.device="eth1"
    uci set network.wan6.proto="dhcpv6"

    # LAN: vmnet-host 管理口
    uci set network.lan.device="br-lan"
    uci set network.lan.proto="static"
    uci set network.lan.ipaddr="192.168.101.2"
    uci set network.lan.netmask="255.255.255.0"
    uci delete network.lan.gateway 2>/dev/null || true
    uci delete network.lan.dns 2>/dev/null || true
    uci delete network.lan.ip6assign 2>/dev/null || true

    # br-lan 桥接 eth0
    uci set network.br_lan_dev=device
    uci set network.br_lan_dev.name="br-lan"
    uci set network.br_lan_dev.type="bridge"
    uci delete network.br_lan_dev.ports 2>/dev/null || true
    uci add_list network.br_lan_dev.ports="eth0"

    uci commit network
    service network restart
' 2>/dev/null
sleep 4
echo "[fix-network] 网络配置已写入 ✓"

echo "[fix-network] 切换 opkg 源为清华镜像（TUNA）..."
ssh $SSH_OPTS $ROUTER "
    sed -i 's|https://downloads.openwrt.org|https://mirrors.tuna.tsinghua.edu.cn/openwrt|g' /etc/opkg/distfeeds.conf
    cat /etc/opkg/distfeeds.conf
" 2>/dev/null
echo "[fix-network] opkg 源已切换 ✓"

echo "[fix-network] 验证 opkg update..."
ssh $SSH_OPTS $ROUTER "rm -f /var/lock/opkg.lock && opkg update 2>&1 | grep -E 'Updated|error|Error'" 2>/dev/null

echo "[fix-network] 配置 GNB 隧道 MSS clamping (rt mtu 自动计算)..."
ssh $SSH_OPTS $ROUTER "
    # 检查是否已有 gnb_tun 的 MSS 规则
    nft list chain inet fw4 mangle_postrouting 2>/dev/null | grep -q 'gnb_tun.*maxseg' || \
    nft add rule inet fw4 mangle_postrouting oifname 'gnb_tun' tcp flags \& \(fin \| syn \| rst\) == syn tcp option maxseg size set rt mtu comment '\"!fw4: Zone mynet egress MTU fixing\"'
    # 清理旧的手动 MSS 规则（如有）
    nft delete rule inet fw4 forward handle \$(nft -a list chain inet fw4 forward 2>/dev/null | grep 'tcp option maxseg' | awk '{print \$NF}' | tail -1) 2>/dev/null || true
" 2>/dev/null
echo "[fix-network] MSS clamping (gnb_tun, rt mtu) 已配置 ✓"

echo "[fix-network] 启用 ARP proxy..."
ssh $SSH_OPTS $ROUTER "
    echo 1 > /proc/sys/net/ipv4/conf/br-lan/proxy_arp
    echo 1 > /proc/sys/net/ipv4/conf/all/proxy_arp
" 2>/dev/null
echo "[fix-network] ARP proxy 已启用 ✓"

echo "[fix-network] 配置 dnsmasq DNS 分流（国内走 114，海外走 peer）..."
ssh $SSH_OPTS $ROUTER "
    # 安装依赖
    opkg install python3-light >/dev/null 2>&1 || true

    # dnsmasq 默认走国内 DNS
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server='114.114.114.114'
    uci add_list dhcp.@dnsmasq[0].server='223.5.5.5'
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci add_list dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
    uci commit dhcp

    mkdir -p /etc/dnsmasq.d

    # 下载 gfwlist
    curl -s --max-time 30 -o /tmp/gfwlist.txt 'https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt' 2>/dev/null
    if [ ! -s /tmp/gfwlist.txt ]; then
        curl -s --max-time 30 -o /tmp/gfwlist.txt 'https://ghproxy.net/https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt' 2>/dev/null
    fi

    # 解析 gfwlist -> dnsmasq 配置
    if [ -s /tmp/gfwlist.txt ]; then
        python3 -c '
import base64, re
with open(\"/tmp/gfwlist.txt\") as f:
    text = f.read()
decoded = base64.b64decode(text).decode(\"utf-8\", errors=\"ignore\")
domains = set()
for line in decoded.split(\"\\n\"):
    line = line.strip()
    if not line or line[0] in (\"!\", \"@\", \"[\"):
        continue
    line = line.lstrip(\"||\").lstrip(\"|\").lstrip(\".\")
    m = re.match(r\"[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+(\.[a-zA-Z]{2,})\", line)
    if m:
        d = m.group(0).lower()
        if d.endswith(\".cn\") or d.endswith(\".com.cn\"):
            continue
        parts = d.split(\".\")
        if len(parts) >= 2:
            base = \".\".join(parts[-3:]) if len(parts) > 2 and parts[-2] in (\"com\", \"net\", \"org\", \"gov\", \"edu\", \"co\", \"ac\") else d
            domains.add(base)
with open(\"/etc/dnsmasq.d/gfwlist.conf\", \"w\") as f:
    for d in sorted(domains):
        f.write(f\"server=/{d}/10.182.236.180\\n\")
print(f\"{len(domains)} domains\")
' 2>/dev/null
    fi

    # 补充 gfwlist 遗漏的关键域名
    cat >> /etc/dnsmasq.d/gfwlist.conf << 'EXTRA'
server=/google.com/10.182.236.180
server=/youtube.com/10.182.236.180
server=/ytimg.com/10.182.236.180
server=/ggpht.com/10.182.236.180
server=/gstatic.com/10.182.236.180
server=/googleapis.com/10.182.236.180
server=/googlevideo.com/10.182.236.180
server=/gvt1.com/10.182.236.180
server=/facebook.com/10.182.236.180
server=/fbcdn.net/10.182.236.180
server=/twitter.com/10.182.236.180
server=/x.com/10.182.236.180
server=/twimg.com/10.182.236.180
server=/instagram.com/10.182.236.180
server=/cdninstagram.com/10.182.236.180
server=/whatsapp.com/10.182.236.180
server=/telegram.org/10.182.236.180
server=/t.me/10.182.236.180
server=/github.com/10.182.236.180
server=/github.io/10.182.236.180
server=/githubusercontent.com/10.182.236.180
server=/githubassets.com/10.182.236.180
server=/wikipedia.org/10.182.236.180
server=/wikimedia.org/10.182.236.180
server=/openai.com/10.182.236.180
server=/chatgpt.com/10.182.236.180
server=/cloudflare.com/10.182.236.180
server=/cdnjs.com/10.182.236.180
server=/netflix.com/10.182.236.180
server=/nflxvideo.net/10.182.236.180
server=/nflximg.net/10.182.236.180
server=/reddit.com/10.182.236.180
server=/redditstatic.com/10.182.236.180
server=/redditmedia.com/10.182.236.180
server=/discord.com/10.182.236.180
server=/discordapp.com/10.182.236.180
server=/slack.com/10.182.236.180
server=/amazon.com/10.182.236.180
server=/amazonaws.com/10.182.236.180
server=/cloudfront.net/10.182.236.180
server=/azure.com/10.182.236.180
server=/microsoft.com/10.182.236.180
server=/bing.com/10.182.236.180
server=/linkedin.com/10.182.236.180
server=/medium.com/10.182.236.180
server=/spotify.com/10.182.236.180
server=/apple.com/10.182.236.180
server=/icloud.com/10.182.236.180
server=/pixiv.net/10.182.236.180
server=/twitch.tv/10.182.236.180
server=/twitchcdn.net/10.182.236.180
server=/v2ex.com/10.182.236.180
server=/notion.so/10.182.236.180
server=/notion.site/10.182.236.180
server=/dropbox.com/10.182.236.180
server=/zoom.us/10.182.236.180
server=/docker.com/10.182.236.180
server=/docker.io/10.182.236.180
server=/npmjs.com/10.182.236.180
server=/npmjs.org/10.182.236.180
server=/pypi.org/10.182.236.180
server=/stackoverflow.com/10.182.236.180
EXTRA

    /etc/init.d/dnsmasq restart 2>/dev/null
    echo 'DNS 分流已配置（gfwlist + 关键域名 -> peer, 其余 -> 114/223）'
" 2>/dev/null
echo "[fix-network] DNS 分流已配置 ✓"

echo ""
echo "[fix-network] 全部完成！"
echo "              ssh openwrt-qemu"
echo "              http://192.168.101.2/cgi-bin/luci/"
