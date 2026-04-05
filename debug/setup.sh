#!/usr/bin/env bash
# setup.sh — 一次性初始化：安装 QEMU、下载 OpenWrt 镜像并转换为 qcow2
# 用法: bash debug/setup.sh
#
# 仅支持 Apple Silicon (arm64)：armsr-armv8 镜像 + qemu-system-aarch64 + HVF 加速
# 网络模式：vmnet（WAN=vmnet-shared 上网, LAN=vmnet-host 管理口 192.168.101.2）

set -euo pipefail

OPENWRT_VERSION="23.05.5"

# 仅支持 Apple Silicon
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" != "arm64" ]]; then
    echo "[setup] 错误：仅支持 Apple Silicon (arm64)，当前架构: $HOST_ARCH"
    exit 1
fi

TARGET="armsr-armv8"
IMG_GZ="openwrt-${OPENWRT_VERSION}-armsr-armv8-generic-ext4-combined.img.gz"
IMG_RAW="openwrt-${OPENWRT_VERSION}-armsr-armv8-generic-ext4-combined.img"
IMG_QCOW2="openwrt-${OPENWRT_VERSION}-armsr-armv8.qcow2"
BASE_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/armsr/armv8"
echo "[setup] Apple Silicon (arm64) — armsr-armv8 + HVF + vmnet"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── 1. 安装 QEMU ──────────────────────────────────────────────
if ! command -v qemu-system-aarch64 &>/dev/null; then
    echo "[setup] 安装 qemu ..."
    brew install qemu
else
    echo "[setup] qemu-system-aarch64 已存在，跳过安装"
fi

# ── 2. 下载镜像 ───────────────────────────────────────────────
if [[ -f "$IMG_QCOW2" ]]; then
    echo "[setup] qcow2 镜像已存在: ${IMG_QCOW2}，跳过下载"
elif [[ -f "$IMG_RAW" ]]; then
    echo "[setup] raw 镜像已存在: ${IMG_RAW}，稍后转换为 qcow2"
elif [[ -f "$IMG_GZ" ]]; then
    echo "[setup] 压缩包已存在，跳过下载"
else
    echo "[setup] 下载 OpenWrt ${OPENWRT_VERSION} armsr-armv8 镜像 ..."
    curl -L --progress-bar -o "$IMG_GZ" "${BASE_URL}/${IMG_GZ}"
fi

# ── 3. 解压镜像 ───────────────────────────────────────────────
if [[ ! -f "$IMG_RAW" ]] && [[ ! -f "$IMG_QCOW2" ]]; then
    echo "[setup] 解压镜像 ..."
    gunzip -k "$IMG_GZ"
fi

# ── 4. 预写入网络配置（在 raw 镜像上操作，转换前）──────────────
# 使用 e2fsprogs 的 debugfs 直接修改 ext4 镜像内的 UCI 配置
if [[ ! -f "$IMG_QCOW2" ]] && [[ -f "$IMG_RAW" ]]; then
    # debugfs 来自 e2fsprogs（macOS 上是 keg-only，需要用完整路径）
    DEBUGFS="$(command -v debugfs 2>/dev/null || echo /opt/homebrew/opt/e2fsprogs/sbin/debugfs)"
    if [[ ! -x "$DEBUGFS" ]]; then
        echo "[setup] 安装 e2fsprogs（提供 debugfs）..."
        brew install e2fsprogs
        DEBUGFS="/opt/homebrew/opt/e2fsprogs/sbin/debugfs"
    fi

    echo "[setup] 预配置 OpenWrt 网络（vmnet: WAN=DHCP, LAN=192.168.101.2）..."

    # OpenWrt UCI 网络配置：
    #   WAN (eth0): vmnet-shared DHCP 上网
    #   LAN (eth1): vmnet-host 静态 192.168.101.2（管理口）
    NETWORK_UCI="config interface 'loopback'
\toption device 'lo'
\toption proto 'static'
\toption ipaddr '127.0.0.1'
\toption netmask '255.0.0.0'

config globals 'globals'
\toption ula_prefix 'fd0b:1c3b:ad07::/48'

config device 'br_lan_dev'
\toption name 'br-lan'
\toption type 'bridge'
\tlist ports 'eth1'

config interface 'lan'
\toption device 'br-lan'
\toption proto 'static'
\toption ipaddr '192.168.101.2'
\toption netmask '255.255.255.0'

config interface 'wan'
\toption device 'eth0'
\toption proto 'dhcp'
\toption peerdns '0'
\tlist dns '8.8.8.8'
\tlist dns '8.8.4.4'

config interface 'wan6'
\toption device 'eth0'
\toption proto 'dhcpv6'
"

    TMP_NET="$(mktemp)"
    printf '%s' "$NETWORK_UCI" > "$TMP_NET"

    # 获取第二分区（rootfs ext4）的起始扇区，计算字节偏移
    # armsr-armv8 使用 GPT 分区表，macOS fdisk 不支持 -l，用 Python 解析
    PART2_START=$(python3 -c "
import struct
with open('$IMG_RAW', 'rb') as f:
    f.seek(512 + 72)
    pe_start = struct.unpack('<Q', f.read(8))[0]
    num = struct.unpack('<I', f.read(4))[0]
    esz = struct.unpack('<I', f.read(4))[0]
    f.seek(pe_start * 512 + esz)  # second entry
    e = f.read(esz)
    if e[0:16] != b'\\x00'*16:
        print(struct.unpack('<Q', e[32:40])[0])
" 2>/dev/null)
    if [[ -n "$PART2_START" ]]; then
        OFFSET=$(( PART2_START * 512 ))
        echo "[setup] rootfs 分区偏移: ${PART2_START} sectors (${OFFSET} bytes)"
        "$DEBUGFS" -w -o offset=$OFFSET "$IMG_RAW" -R "write $TMP_NET /etc/config/network" 2>/dev/null && \
            echo "[setup] 网络配置已写入镜像 ✓" || \
            echo "[setup] debugfs 写入失败，首次启动后需手动运行 bash debug/fix-network.sh"
    else
        echo "[setup] 无法解析分区表，跳过预配置（首次启动后运行 bash debug/fix-network.sh）"
    fi

    rm -f "$TMP_NET"

    # ── 5. 预写入 opkg 清华镜像源（downloads.openwrt.org 在国内被封）──
    echo "[setup] 预写入 opkg 清华镜像配置..."

    PKG_ARCH="aarch64_generic"
    TUNA="https://mirrors.tuna.tsinghua.edu.cn/openwrt"
    OPKG_FEEDS="src/gz openwrt_core ${TUNA}/releases/${OPENWRT_VERSION}/targets/armsr/armv8/packages
src/gz openwrt_base ${TUNA}/releases/${OPENWRT_VERSION}/packages/${PKG_ARCH}/base
src/gz openwrt_luci ${TUNA}/releases/${OPENWRT_VERSION}/packages/${PKG_ARCH}/luci
src/gz openwrt_packages ${TUNA}/releases/${OPENWRT_VERSION}/packages/${PKG_ARCH}/packages
src/gz openwrt_routing ${TUNA}/releases/${OPENWRT_VERSION}/packages/${PKG_ARCH}/routing
src/gz openwrt_telephony ${TUNA}/releases/${OPENWRT_VERSION}/packages/${PKG_ARCH}/telephony
"
    TMP_FEEDS="$(mktemp)"
    printf '%s' "$OPKG_FEEDS" > "$TMP_FEEDS"

    if [[ -n "$PART2_START" ]]; then
        "$DEBUGFS" -w -o offset=$OFFSET "$IMG_RAW" \
            -R "write $TMP_FEEDS /etc/opkg/distfeeds.conf" 2>/dev/null && \
            echo "[setup] opkg 清华镜像源已写入镜像 ✓" || \
            echo "[setup] opkg 预写入失败，首次启动后运行 bash debug/fix-network.sh"
    fi
    rm -f "$TMP_FEEDS"
fi

# ── 6. 转换为 qcow2 格式 ─────────────────────────────────────
if [[ ! -f "$IMG_QCOW2" ]]; then
    echo "[setup] 转换 raw → qcow2 ..."
    qemu-img convert -f raw -O qcow2 "$IMG_RAW" "$IMG_QCOW2"
    echo "[setup] 扩展 qcow2 镜像至 512MB ..."
    qemu-img resize "$IMG_QCOW2" 512M 2>/dev/null || true
    echo "[setup] qcow2 转换完成 ✓"
    # 保留 raw 镜像以免需要重新预写入
else
    echo "[setup] qcow2 已存在，跳过转换"
fi

# ── 7. 保存镜像名供 start.sh 读取 ────────────────────────────
echo "$IMG_QCOW2" > "$SCRIPT_DIR/.img_name"

echo ""
echo "[setup] 完成！镜像：${SCRIPT_DIR}/${IMG_QCOW2}"
echo "        网络模式: vmnet（需要 sudo）"
echo "        LAN 地址: 192.168.101.2（SSH/HTTP 直连）"
echo "        现在可以运行: bash debug/start.sh"
