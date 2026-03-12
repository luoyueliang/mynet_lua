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

# 保存架构信息供 start.sh 读取
echo "$HOST_ARCH" > "$SCRIPT_DIR/.host_arch"
echo "$IMG" > "$SCRIPT_DIR/.img_name"

echo ""
echo "[setup] 完成！目标架构: $TARGET，镜像：$SCRIPT_DIR/$IMG"
echo "        现在可以运行: bash debug/start.sh"
