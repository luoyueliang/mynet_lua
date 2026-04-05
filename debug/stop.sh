#!/usr/bin/env bash
# stop.sh — 停止 QEMU 虚拟机（vmnet 模式以 root 运行，需要 sudo kill）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/qemu.pid"

if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    if sudo kill -0 "$PID" 2>/dev/null; then
        sudo kill "$PID"
        echo "[stop] QEMU 已停止 (PID=$PID)"
    else
        echo "[stop] 进程不存在，清理 pid 文件"
    fi
    rm -f "$PID_FILE"
else
    # 尝试查找 qemu 进程
    QEMU_PID=$(pgrep -f 'qemu-system-aarch64.*vmnet' 2>/dev/null | head -1 || true)
    if [[ -n "$QEMU_PID" ]]; then
        sudo kill "$QEMU_PID"
        echo "[stop] QEMU 已停止 (PID=$QEMU_PID, 无 pid 文件)"
    else
        echo "[stop] 未找到运行中的 QEMU 实例"
    fi
fi
