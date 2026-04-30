#!/usr/bin/env bash
# start.sh — 启动 OpenWrt QEMU 虚拟机
#
# 网络模式：vmnet（需要 sudo）
#   LAN (eth0): vmnet-host   — 管理口 192.168.101.0/24
#   WAN (eth1): vmnet-bridged — 桥接到 WiFi(en0)，直接接入家庭路由器，自动获取 IP
#
# 访问方式（直连 VM IP）：
#   SSH:  ssh openwrt-qemu          （~/.ssh/config: 192.168.101.2）
#   Web:  http://192.168.101.2/cgi-bin/luci/
#
# 用法:
#   bash debug/start.sh          # 后台运行（-daemonize）
#   bash debug/start.sh -fg      # 前台运行（输出到终端）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/qemu.pid"
VM_IP="192.168.101.2"

# 读取 setup.sh 记录的镜像名
if [[ -f "$SCRIPT_DIR/.img_name" ]]; then
    IMG=$(cat "$SCRIPT_DIR/.img_name")
else
    echo "[start] 未找到镜像信息，请先运行: bash debug/setup.sh"
    exit 1
fi

if [[ ! -f "$SCRIPT_DIR/$IMG" ]]; then
    echo "[start] 镜像不存在: $IMG，请先运行: bash debug/setup.sh"
    exit 1
fi

# 检查是否已在运行
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if sudo kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[start] QEMU 已经在运行 (PID=$OLD_PID)"
        echo "        SSH:  ssh openwrt-qemu"
        echo "        Web:  http://$VM_IP/cgi-bin/luci/"
        exit 0
    else
        rm -f "$PID_FILE"
    fi
fi

# EFI 固件（armsr-armv8 必需）
EFI_CODE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
if [[ ! -f "$EFI_CODE" ]]; then
    echo "[start] 找不到 EFI 固件: $EFI_CODE"
    echo "        请先运行: brew install qemu"
    exit 1
fi

echo "[start] qemu-system-aarch64 + HVF + vmnet (Apple Silicon)"

QEMU_ARGS=(
    qemu-system-aarch64
    -machine virt,accel=hvf
    -cpu host
    -smp 2
    -m 128M
    -drive "if=pflash,file=${EFI_CODE},format=raw,readonly=on"
    -drive "file=$SCRIPT_DIR/$IMG,format=qcow2,if=virtio"
    -device virtio-rng-pci
    -serial "tcp::4444,server,nowait"
    -monitor "unix:$SCRIPT_DIR/qemu-mon.sock,server,nowait"
    # LAN: vmnet-host（管理口，固定子网 192.168.101.0/24）
    # 放在第一张网卡，确保 OpenWrt 中为 eth0，更符合惯例
    -device virtio-net-pci,netdev=lan
    -netdev vmnet-host,id=lan,start-address=192.168.101.1,end-address=192.168.101.254,subnet-mask=255.255.255.0
    # WAN: vmnet-bridged（桥接 WiFi en0，VM 直接接入家庭 192.168.0.0/24）
    # MAC 固定，方便路由器按 MAC 绑定静态 IP
    -device virtio-net-pci,netdev=wan,mac=52:54:00:12:34:56
    -netdev vmnet-bridged,id=wan,ifname=en0
)

if [[ "${1:-}" == "-fg" ]]; then
    echo "[start] 前台启动 OpenWrt QEMU ..."
    echo "        SSH:  ssh openwrt-qemu"
    echo "        Web:  http://$VM_IP/cgi-bin/luci/"
    echo "        退出: Ctrl-A X"
    exec sudo env OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES "${QEMU_ARGS[@]}" -nographic
else
    echo "[start] 后台启动 OpenWrt QEMU ..."
    # vmnet-bridged 使用 Objective-C 框架，-daemonize 的 fork() 需要关闭 fork 安全检查
    sudo env OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES "${QEMU_ARGS[@]}" \
        -display none \
        -daemonize \
        -pidfile "$PID_FILE" \
        2> "$SCRIPT_DIR/qemu.log"
    echo "[start] 日志: debug/qemu.log"
    echo "        等待 20 秒让系统启动完成 ..."
    sleep 20
    echo ""
    echo "[start] 就绪！"
    echo "        SSH:  ssh openwrt-qemu"
    echo "        Web:  http://$VM_IP/cgi-bin/luci/"
    echo "        停止: bash debug/stop.sh"
fi
