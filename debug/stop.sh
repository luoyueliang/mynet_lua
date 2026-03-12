#!/usr/bin/env bash
# stop.sh — 停止 QEMU 虚拟机

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/qemu.pid"

if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        echo "[stop] QEMU 已停止 (PID=$PID)"
    else
        echo "[stop] 进程不存在，清理 pid 文件"
    fi
    rm -f "$PID_FILE"
else
    echo "[stop] 未找到运行中的 QEMU 实例"
fi
