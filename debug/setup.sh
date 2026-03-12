#!/usr/bin/env bash
# setup.sh — 一次性初始化：安装 QEMU、下载 OpenWrt 镜像并解压
# 用法: bash debug/setup.sh

set -euo pipefail

OPENWRT_VERSION="23.05.5"
IMG_GZ="openwrt-${OPENWRT_VERSION}-x86-64-generic-ext4-combined.img.gz"
IMG="openwrt-${OPENWRT_VERSION}-x86-64-generic-ext4-combined.img"
BASE_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64"

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

echo ""
echo "[setup] 完成！镜像：$SCRIPT_DIR/$IMG"
echo "        现在可以运行: bash debug/start.sh"
