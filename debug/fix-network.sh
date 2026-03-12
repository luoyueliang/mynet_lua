#!/usr/bin/env bash
# fix-network.sh — 通过 serial console 将 OpenWrt 网络配置修复为 SLIRP 兼容地址
#
# 适用场景：
#   - 使用新镜像首次启动，IP 还是默认 192.168.1.1
#   - setup.sh 的 debugfs 预写入失败时
#
# 用法：
#   bash debug/fix-network.sh        （虚拟机需已在运行）

set -euo pipefail

CONSOLE_PORT=4444

# 检查 console 是否可达
if ! nc -z localhost $CONSOLE_PORT 2>/dev/null; then
    echo "[fix-network] serial console 不可达 (localhost:$CONSOLE_PORT)"
    echo "              请先运行: bash debug/start.sh"
    exit 1
fi

echo "[fix-network] 通过 serial console 写入网络配置..."

(
printf "\r"
sleep 1
printf "uci set network.lan.ipaddr='10.0.2.15'\r"
printf "uci set network.lan.gateway='10.0.2.2'\r"
printf "uci set network.lan.dns='10.0.2.3'\r"
printf "uci commit network\r"
printf "service network restart\r"
sleep 6
printf "ip addr show br-lan | grep 'inet '\r"
sleep 2
) | nc 127.0.0.1 $CONSOLE_PORT 2>&1 | \
    cat -v | grep -Ev "^$|^\^M$" | grep -E "inet |uci |gateway|10\.0\.2|error" | head -10

echo ""
echo "[fix-network] 完成，等待网络就绪..."
sleep 3

# 验证 SSH
if printf "SSH-2.0-probe\r\n" | nc -w 5 127.0.0.1 2222 | grep -q "SSH"; then
    echo "[fix-network] SSH 已通 ✓"
    echo "              ssh root@localhost -p 2222"
else
    echo "[fix-network] SSH 暂未响应，稍候再试"
fi
