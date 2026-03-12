#!/usr/bin/env bash
# start.sh — 启动 OpenWrt QEMU 虚拟机
#
# 端口映射（宿主机 → 虚拟机）：
#   localhost:2222  →  22   (SSH)
#   localhost:8080  →  80   (LuCI Web)
#
# 用法:
#   bash debug/start.sh          # 后台运行（nohup）
#   bash debug/start.sh -fg      # 前台运行（输出到终端）

set -euo pipefail

OPENWRT_VERSION="23.05.5"
IMG="openwrt-${OPENWRT_VERSION}-x86-64-generic-ext4-combined.img"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/qemu.pid"

if [[ ! -f "$SCRIPT_DIR/$IMG" ]]; then
    echo "[start] 镜像不存在，请先运行: bash debug/setup.sh"
    exit 1
fi

# 检查是否已在运行
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "[start] QEMU 已经在运行 (PID=$(cat "$PID_FILE"))"
    echo "        SSH:  ssh root@localhost -p 2222"
    echo "        Web:  http://localhost:8080/cgi-bin/luci/"
    exit 0
fi

QEMU_ARGS=(
    qemu-system-x86_64
    -drive "file=$SCRIPT_DIR/$IMG,format=raw,if=virtio"
    -m 256M
    -nographic
    -serial mon:stdio
    -net nic,model=virtio
    -net "user,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:80"
)

if [[ "${1:-}" == "-fg" ]]; then
    echo "[start] 前台启动 OpenWrt QEMU ..."
    echo "        SSH:  ssh root@localhost -p 2222"
    echo "        Web:  http://localhost:8080/cgi-bin/luci/"
    echo "        退出: Ctrl-A X"
    exec "${QEMU_ARGS[@]}"
else
    echo "[start] 后台启动 OpenWrt QEMU ..."
    nohup "${QEMU_ARGS[@]}" > "$SCRIPT_DIR/qemu.log" 2>&1 &
    echo $! > "$PID_FILE"
    echo "[start] PID=$(cat "$PID_FILE")，日志: debug/qemu.log"
    echo "        等待 20 秒让系统启动完成 ..."
    sleep 20
    echo ""
    echo "[start] 就绪！"
    echo "        SSH:  ssh root@localhost -p 2222"
    echo "        Web:  http://localhost:8080/cgi-bin/luci/"
    echo "        停止: bash debug/stop.sh"
fi
