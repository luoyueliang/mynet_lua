#!/usr/bin/env bash
# fix-network.sh — 通过 SSH 将 OpenWrt 网络配置修复为 SLIRP 兼容地址
#                  并将 opkg 源切换为清华镜像（downloads.openwrt.org 在国内被封）
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

echo "[fix-network] 修复网络配置（10.0.2.15/24, gw=10.0.2.2）..."
ssh $SSH_OPTS $ROUTER "
    uci set network.lan.ipaddr='10.0.2.15'
    uci set network.lan.gateway='10.0.2.2'
    uci set network.lan.dns='10.0.2.3'
    uci commit network
    service network restart
" 2>/dev/null
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
echo ""
echo "[fix-network] 全部完成！"
echo "              ssh openwrt-qemu"
echo "              http://localhost:8080/cgi-bin/luci/"
