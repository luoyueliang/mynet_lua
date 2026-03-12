#!/usr/bin/env bash
# setup.sh — 一次性初始化：安装 QEMU、下载 OpenWrt 镜像并解压
# 用法: bash debug/setup.sh
#
# 自动检测宿主机架构：
#   Apple Silicon (arm64) → armvirt-64 镜像 + qemu-system-aarch64 + HVF 硬件加速
#   Intel Mac  (x86_64)  → x86-64    镜像 + qemu-system-x86_64

set -euo pipefail

OPENWRT_VERSION="23.05.5"

# 检测宿主机架构
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" == "arm64" ]]; then
    # Apple Silicon — 使用 armsr-armv8（OpenWrt 23.05+ ARM64 正式目标）+ HVF 加速
    TARGET="armsr-armv8"
    IMG_GZ="openwrt-${OPENWRT_VERSION}-armsr-armv8-generic-ext4-combined.img.gz"
    IMG="openwrt-${OPENWRT_VERSION}-armsr-armv8-generic-ext4-combined.img"
    BASE_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/armsr/armv8"
    echo "[setup] 检测到 Apple Silicon (arm64)，使用 armsr-armv8 镜像 + HVF 加速"
else
    # Intel Mac — 使用 x86-64
    TARGET="x86-64"
    IMG_GZ="openwrt-${OPENWRT_VERSION}-x86-64-generic-ext4-combined.img.gz"
    IMG="openwrt-${OPENWRT_VERSION}-x86-64-generic-ext4-combined.img"
    BASE_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64"
    echo "[setup] 检测到 Intel Mac (x86_64)，使用 x86-64 镜像"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── 1. 安装 QEMU ──────────────────────────────────────────────
if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "[setup] 安装 qemu ..."
    brew install qemu
else
    echo "[setup] qemu-system-x86_64 已存在，跳过安装"
fi

# ── 2. 下载镜像 ───────────────────────────────────────────────
if [[ -f "$IMG" ]]; then
    echo "[setup] 镜像已存在: $IMG，跳过下载"
elif [[ -f "$IMG_GZ" ]]; then
    echo "[setup] 压缩包已存在，跳过下载"
else
    echo "[setup] 下载 OpenWrt ${OPENWRT_VERSION} x86/64 镜像 ..."
    curl -L --progress-bar -o "$IMG_GZ" "${BASE_URL}/${IMG_GZ}"
fi

# ── 3. 解压镜像 ───────────────────────────────────────────────
if [[ ! -f "$IMG" ]]; then
    echo "[setup] 解压镜像 ..."
    gunzip -k "$IMG_GZ"
fi

# ── 4. 扩展磁盘（可选，256MB → 512MB，方便安装额外包）────────
if command -v qemu-img &>/dev/null; then
    echo "[setup] 扩展镜像至 512MB ..."
    qemu-img resize "$IMG" 512M 2>/dev/null || true
fi

# ── 5. 预写入网络配置（无人值守，不再需要进控制台手动设 IP）──
# 使用 e2fsprogs 的 debugfs 直接修改 ext4 镜像内的 UCI 配置
if ! command -v debugfs &>/dev/null; then
    echo "[setup] 安装 e2fsprogs（提供 debugfs）..."
    brew install e2fsprogs
fi

echo "[setup] 预配置 OpenWrt 网络（10.0.2.15/24, gw=10.0.2.2）..."

# OpenWrt UCI 网络配置，适配 QEMU SLIRP（10.0.2.0/24）
NETWORK_UCI="config interface 'loopback'
\toption device 'lo'
\toption proto 'static'
\toption ipaddr '127.0.0.1'
\toption netmask '255.0.0.0'

config globals 'globals'
\toption ula_prefix 'fd0b:1c3b:ad07::/48'

config interface 'lan'
\toption device 'br-lan'
\toption proto 'static'
\toption ipaddr '10.0.2.15'
\toption netmask '255.255.255.0'
\toption gateway '10.0.2.2'
\toption dns '10.0.2.3'
\toption ip6assign '60'
"

TMP_NET="$(mktemp)"
printf '%s' "$NETWORK_UCI" > "$TMP_NET"

# 获取第二分区（rootfs ext4）的起始扇区，计算字节偏移
PART2_START=$(fdisk -l "$IMG" 2>/dev/null | awk '/^[^ ]*2 /{print $2}' | head -1)
if [[ -n "$PART2_START" ]]; then
    OFFSET=$(( PART2_START * 512 ))
    echo "[setup] rootfs 分区偏移: ${PART2_START} sectors (${OFFSET} bytes)"
    debugfs -w -o offset=$OFFSET "$IMG" -R "write $TMP_NET /etc/config/network" 2>/dev/null && \
        echo "[setup] 网络配置已写入镜像 ✓" || \
        echo "[setup] debugfs 写入失败，首次启动后需手动运行 bash debug/fix-network.sh"
else
    echo "[setup] 无法解析分区表，跳过预配置（首次启动后运行 bash debug/fix-network.sh）"
fi

rm -f "$TMP_NET"

# ── 6. 保存架构信息供 start.sh 读取 ──────────────────────────
echo "$HOST_ARCH" > "$SCRIPT_DIR/.host_arch"
echo "$IMG" > "$SCRIPT_DIR/.img_name"

echo ""
echo "[setup] 完成！目标架构: $TARGET，镜像：$SCRIPT_DIR/$IMG"
echo "        现在可以运行: bash debug/start.sh"
