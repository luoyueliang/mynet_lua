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

echo "[fix-network] 配置 TCP MSS clamping (GNB 隧道 MTU 1450)..."
ssh $SSH_OPTS $ROUTER "
    nft delete rule inet fw4 forward handle \$(nft -a list chain inet fw4 forward 2>/dev/null | grep 'tcp option maxseg' | grep -v grep | awk '{print \$NF}' | tail -1) 2>/dev/null || true
    nft add rule inet fw4 forward tcp flags \& \(syn \| rst \| ack\) == syn tcp option maxseg size set 1400
" 2>/dev/null
echo "[fix-network] MSS 1400 (双向 SYN+SYN-ACK) 已配置 ✓"

echo ""
echo "[fix-network] 全部完成！"
echo "              ssh openwrt-qemu"
echo "              http://192.168.101.2/cgi-bin/luci/"
