#!/usr/bin/env bash
# sync.sh — 构建 ipk 并安装到 QEMU OpenWrt 虚拟机
#
# 用法:
#   bash debug/sync.sh              # 构建 ipk + 上传 + 安装（默认）
#   bash debug/sync.sh build        # 仅本地构建 ipk
#   bash debug/sync.sh quick        # 快速 scp 同步（不走 ipk，开发迭代用）
#   bash debug/sync.sh bootstrap    # 首次：安装 LuCI 依赖 + 安装 ipk

set -euo pipefail

ROUTER="openwrt-qemu"
SSH_OPTS="-o ConnectTimeout=5"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

PKG_NAME="luci-app-mynet"
PKG_VERSION="2.1.5"
PKG_RELEASE="1"
BUILD_DIR="$PROJECT_DIR/build"
IPK_FILE="$BUILD_DIR/${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_all.ipk"

# 打包 ipk（OpenWrt 23.05 的 ipk = tar.gz, 不是 ar/deb）
_build_ipk_archive() {
    local output="$1"
    local build="$2"
    (cd "$build" && tar czf "$output" ./debian-binary ./data.tar.gz ./control.tar.gz)
}

# ─── ipk 构建 ────────────────────────────────────────────────

build_ipk() {
    echo "[build] 构建 $PKG_NAME ipk ..."

    rm -rf "$BUILD_DIR"
    local data_dir="$BUILD_DIR/data"
    local ctrl_dir="$BUILD_DIR/control"

    # --- LuCI controller ---
    install -d "$data_dir/usr/lib/lua/luci/controller"
    install -m 0644 "$PROJECT_DIR/luasrc/controller/mynet.lua" \
        "$data_dir/usr/lib/lua/luci/controller/"

    # --- LuCI model ---
    install -d "$data_dir/usr/lib/lua/luci/model/mynet"
    install -m 0644 "$PROJECT_DIR/luasrc/model/mynet/"*.lua \
        "$data_dir/usr/lib/lua/luci/model/mynet/"

    # --- LuCI view ---
    install -d "$data_dir/usr/lib/lua/luci/view/mynet"
    install -m 0644 "$PROJECT_DIR/luasrc/view/mynet/"*.htm \
        "$data_dir/usr/lib/lua/luci/view/mynet/"

    # --- Static assets ---
    install -d "$data_dir/www/luci-static/resources/mynet/css"
    install -m 0644 "$PROJECT_DIR/htdocs/luci-static/resources/mynet/css/mynet.css" \
        "$data_dir/www/luci-static/resources/mynet/css/"
    install -d "$data_dir/www/luci-static/resources/mynet/js"
    install -m 0644 "$PROJECT_DIR/htdocs/luci-static/resources/mynet/js/mynet.js" \
        "$data_dir/www/luci-static/resources/mynet/js/"

    # --- Default config (conffiles 保护) ---
    install -d "$data_dir/etc/mynet/conf"
    install -m 0644 "$PROJECT_DIR/root/etc/mynet/conf/config.json" \
        "$data_dir/etc/mynet/conf/"

    # --- Init script ---
    install -d "$data_dir/etc/init.d"
    install -m 0755 "$PROJECT_DIR/scripts/runtime/rc.mynet" \
        "$data_dir/etc/init.d/mynet"

    # --- Proxy scripts ---
    install -d "$data_dir/etc/mynet/scripts/proxy/hooks"
    install -m 0755 "$PROJECT_DIR/scripts/proxy/proxy.sh" \
        "$data_dir/etc/mynet/scripts/proxy/"
    install -m 0755 "$PROJECT_DIR/scripts/proxy/hooks/pre_start.sh" \
        "$data_dir/etc/mynet/scripts/proxy/hooks/"
    install -m 0755 "$PROJECT_DIR/scripts/proxy/hooks/post_start.sh" \
        "$data_dir/etc/mynet/scripts/proxy/hooks/"
    install -m 0755 "$PROJECT_DIR/scripts/proxy/hooks/stop.sh" \
        "$data_dir/etc/mynet/scripts/proxy/hooks/"
    install -m 0755 "$PROJECT_DIR/scripts/proxy/route_policy.sh" \
        "$data_dir/etc/mynet/scripts/proxy/"

    # --- Tools ---
    install -d "$data_dir/etc/mynet/scripts/tools"
    install -m 0755 "$PROJECT_DIR/scripts/tools/check_openwrt_masq.sh" \
        "$data_dir/etc/mynet/scripts/tools/"
    install -m 0755 "$PROJECT_DIR/scripts/tools/diagnose_network.sh" \
        "$data_dir/etc/mynet/scripts/tools/"
    install -m 0755 "$PROJECT_DIR/scripts/tools/optimize_gnb_conntrack.sh" \
        "$data_dir/etc/mynet/scripts/tools/"

    # --- curl TLS fix ---
    install -d "$data_dir/usr/sbin"
    install -m 0755 "$PROJECT_DIR/root/usr/sbin/mynet-fix-curl" \
        "$data_dir/usr/sbin/"

    # --- heartbeat cron script (替代 mynetd) ---
    install -d "$data_dir/usr/bin"
    install -m 0755 "$PROJECT_DIR/scripts/shell/heartbeat.sh" \
        "$data_dir/usr/bin/mynet-heartbeat"

    # --- Deploy route.mynet / firewall.mynet to scripts/ (fixed path) ---
    install -m 0755 "$PROJECT_DIR/scripts/runtime/route.mynet" \
        "$data_dir/etc/mynet/scripts/"
    install -m 0755 "$PROJECT_DIR/scripts/runtime/firewall.mynet" \
        "$data_dir/etc/mynet/scripts/"

    # --- Runtime directories ---
    install -d "$data_dir/etc/mynet/logs"
    install -d "$data_dir/etc/mynet/driver/gnb"

    # --- i18n translations (.po → .lmo) ---
    install -d "$data_dir/usr/lib/lua/luci/i18n"
    for pofile in "$PROJECT_DIR"/po/*/mynet.po; do
        [ -f "$pofile" ] || continue
        lang="$(basename "$(dirname "$pofile")")"
        python3 "$PROJECT_DIR/tools/po2lmo.py" "$pofile" \
            "$data_dir/usr/lib/lua/luci/i18n/mynet.${lang}.lmo"
    done

    # ── control 文件 ──
    mkdir -p "$ctrl_dir"

    cat > "$ctrl_dir/control" <<EOF
Package: $PKG_NAME
Version: ${PKG_VERSION}-${PKG_RELEASE}
Depends: luci-base, curl, luci-lib-jsonc, bash, kmod-tun
Architecture: all
Maintainer: MyNet
Section: luci
Description: MyNet VPN management interface for OpenWrt
EOF

    cat > "$ctrl_dir/conffiles" <<EOF
/etc/mynet/conf/config.json
EOF

    cat > "$ctrl_dir/postinst" <<'POSTINST'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
# Clean up legacy _src directory from older versions
rm -rf /etc/mynet/scripts/_src
# Stop and disable Go mynetd (replaced by cron heartbeat)
pkill -x mynetd 2>/dev/null || true
# Enable and load tun module
modprobe tun 2>/dev/null
# Install firewall zone (creates network.mynet + zone + forwarding, no device binding yet)
MYNET_HOME=/etc/mynet sh /etc/mynet/scripts/firewall.mynet install 2>/dev/null
# Clear LuCI cache
rm -rf /tmp/luci-*
# Enable mynet service (don't start — user needs to configure first)
/etc/init.d/mynet enable 2>/dev/null
# Setup heartbeat cron (every 5 minutes, replaces mynetd)
mkdir -p /etc/crontabs
if ! grep -q 'mynet-heartbeat' /etc/crontabs/root 2>/dev/null; then
    echo '*/5 * * * * /usr/bin/mynet-heartbeat' >> /etc/crontabs/root
fi
/etc/init.d/cron reload 2>/dev/null || true
exit 0
POSTINST
    chmod +x "$ctrl_dir/postinst"

    cat > "$ctrl_dir/prerm" <<'PRERM'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/mynet stop 2>/dev/null
/etc/init.d/mynet disable 2>/dev/null
# Remove heartbeat cron entry
if [ -f /etc/crontabs/root ]; then
    sed -i '/mynet-heartbeat/d' /etc/crontabs/root
    /etc/init.d/cron reload 2>/dev/null || true
fi
exit 0
PRERM
    chmod +x "$ctrl_dir/prerm"

    # ── 打包 ipk（手工构造 ar 格式，macOS ar 不兼容）──
    echo "2.0" > "$BUILD_DIR/debian-binary"

    # data.tar.gz (COPYFILE_DISABLE prevents macOS ._* resource fork files)
    xattr -cr "$data_dir" 2>/dev/null || true
    (cd "$data_dir" && COPYFILE_DISABLE=1 tar czf "$BUILD_DIR/data.tar.gz" .)

    # control.tar.gz
    (cd "$ctrl_dir" && COPYFILE_DISABLE=1 tar czf "$BUILD_DIR/control.tar.gz" .)

    # 手工构造 ar 归档（ipk = ar archive）
    _build_ipk_archive "$IPK_FILE" "$BUILD_DIR"

    local size
    size=$(wc -c < "$IPK_FILE" | tr -d ' ')
    echo "[build] 完成: $IPK_FILE  (${size} bytes)"
}

# ─── 上传 + 安装 ─────────────────────────────────────────────

upload_install() {
    echo "[sync] 上传 ipk 到 $ROUTER ..."
    scp -O $SSH_OPTS "$IPK_FILE" "$ROUTER:/tmp/"

    local remote_ipk="/tmp/$(basename "$IPK_FILE")"
    echo "[sync] 安装 $PKG_NAME ..."
    ssh $SSH_OPTS $ROUTER "opkg install --force-reinstall '$remote_ipk' 2>&1 && rm -f '$remote_ipk'"
    echo "[sync] LuCI 缓存已由 postinst 自动清理"
}

# ─── 快速同步（scp, 开发迭代用）───────────────────────────────

# 上传单个文件（使用旧协议 SCP，不依赖 sftp-server）
ssh_put() {
    local src="$1" dst="$2"
    scp -O $SSH_OPTS "$src" "$ROUTER:$dst"
}

quick_sync() {
    echo "[quick] scp 快速同步 ..."
    ssh $SSH_OPTS $ROUTER "mkdir -p /usr/lib/lua/luci/model/mynet \
        /usr/lib/lua/luci/view/mynet \
        /www/luci-static/resources/mynet/css \
        /www/luci-static/resources/mynet/js"

    ssh_put "$PROJECT_DIR/luasrc/controller/mynet.lua" \
            "/usr/lib/lua/luci/controller/mynet.lua"

    for f in "$PROJECT_DIR/luasrc/model/mynet/"*.lua; do
        ssh_put "$f" "/usr/lib/lua/luci/model/mynet/$(basename "$f")"
    done

    for f in "$PROJECT_DIR/luasrc/view/mynet/"*.htm; do
        ssh_put "$f" "/usr/lib/lua/luci/view/mynet/$(basename "$f")"
    done

    ssh_put "$PROJECT_DIR/htdocs/luci-static/resources/mynet/css/mynet.css" \
            "/www/luci-static/resources/mynet/css/mynet.css"
    ssh_put "$PROJECT_DIR/htdocs/luci-static/resources/mynet/js/mynet.js" \
            "/www/luci-static/resources/mynet/js/mynet.js"

    # --- i18n ---
    for pofile in "$PROJECT_DIR"/po/*/mynet.po; do
        [ -f "$pofile" ] || continue
        lang="$(basename "$(dirname "$pofile")")"
        local lmo_tmp="/tmp/mynet.${lang}.lmo"
        python3 "$PROJECT_DIR/tools/po2lmo.py" "$pofile" "$lmo_tmp"
        ssh $SSH_OPTS $ROUTER "mkdir -p /usr/lib/lua/luci/i18n"
        ssh_put "$lmo_tmp" "/usr/lib/lua/luci/i18n/mynet.${lang}.lmo"
        rm -f "$lmo_tmp"
    done

    ssh $SSH_OPTS $ROUTER "rm -rf /tmp/luci-*"
    echo "[quick] 完成"
}

# ─── Argon 主题安装 ──────────────────────────────────────────

ARGON_THEME_IPK="https://github.com/jerrykuku/luci-theme-argon/releases/download/v2.3.2/luci-theme-argon_2.3.2-r20250207_all.ipk"
ARGON_CONFIG_IPK="https://github.com/jerrykuku/luci-app-argon-config/releases/download/v0.9/luci-app-argon-config_0.9_all.ipk"
ARGON_I18N_IPK="https://github.com/jerrykuku/luci-app-argon-config/releases/download/v0.9/luci-i18n-argon-config-zh-cn_git-22.114.24542-d1474ba_all.ipk"

install_argon() {
    # 检查是否已安装
    local current_theme
    current_theme=$(ssh $SSH_OPTS $ROUTER "uci get luci.main.mediaurlbase 2>/dev/null" || echo "")
    if [[ "$current_theme" == */argon* ]]; then
        echo "[argon] Argon 主题已安装，跳过"
        return 0
    fi

    echo "[argon] 安装 Argon 主题 ..."
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # 在 Mac 端下载 ipk（VM 可能无法访问 GitHub）
    echo "[argon] 下载 ipk ..."
    curl -sL -o "$tmp_dir/theme.ipk"  "$ARGON_THEME_IPK"  || { echo "[argon] 下载主题失败"; rm -rf "$tmp_dir"; return 1; }
    curl -sL -o "$tmp_dir/config.ipk" "$ARGON_CONFIG_IPK" || { echo "[argon] 下载配置工具失败"; rm -rf "$tmp_dir"; return 1; }
    curl -sL -o "$tmp_dir/i18n.ipk"   "$ARGON_I18N_IPK"   || { echo "[argon] 下载中文包失败"; rm -rf "$tmp_dir"; return 1; }

    # 上传到 VM
    echo "[argon] 上传到 $ROUTER ..."
    scp -O $SSH_OPTS "$tmp_dir/theme.ipk" "$tmp_dir/config.ipk" "$tmp_dir/i18n.ipk" "$ROUTER:/tmp/"

    # 安装依赖 + 主题 + 设置默认
    echo "[argon] opkg install ..."
    ssh $SSH_OPTS $ROUTER "opkg install luci-compat luci-lib-ipkg 2>/dev/null; \
        opkg install /tmp/theme.ipk 2>&1 | tail -3; \
        opkg install /tmp/config.ipk 2>&1 | tail -3; \
        opkg install /tmp/i18n.ipk 2>&1 | tail -3; \
        uci set luci.main.mediaurlbase='/luci-static/argon'; \
        uci commit luci; \
        rm -f /tmp/theme.ipk /tmp/config.ipk /tmp/i18n.ipk /tmp/luci-indexcache* /tmp/luci-modulecache*"

    rm -rf "$tmp_dir"
    echo "[argon] 安装完成"
}

# ─── 首次 bootstrap ──────────────────────────────────────────

bootstrap() {
    echo "[bootstrap] 安装 LuCI 依赖 ..."
    ssh $SSH_OPTS $ROUTER \
        "opkg update && opkg install luci luci-base luci-lib-jsonc luci-lua-runtime luci-compat curl bash kmod-tun 2>&1 | tail -12"
    build_ipk
    upload_install
    install_argon
}

# ─── 入口 ────────────────────────────────────────────────────

TARGET="${1:-all}"

# build 不需要 VM 连接
if [[ "$TARGET" == "build" ]]; then
    build_ipk
    exit 0
fi

# 其余命令需要 VM 可达
if ! ssh $SSH_OPTS $ROUTER "true" 2>/dev/null; then
    echo "[sync] 无法连接 $ROUTER"
    echo "       请先运行: bash debug/start.sh"
    exit 1
fi

case "$TARGET" in
    all)
        build_ipk
        upload_install
        ;;
    quick)
        quick_sync
        ;;
    bootstrap)
        bootstrap
        ;;
    argon)
        install_argon
        ;;
    *)
        echo "用法: $0 [all|build|quick|bootstrap|argon]"
        echo ""
        echo "  all        构建 ipk + 上传 + opkg install（默认）"
        echo "  build      仅本地构建 ipk（不上传）"
        echo "  quick      scp 快速同步 Lua/CSS/JS（开发迭代用）"
        echo "  bootstrap  首次部署：安装 LuCI 依赖 + 构建 + 安装 + Argon 主题"
        echo "  argon      仅安装 Argon 主题（如未安装）"
        exit 1
        ;;
esac

echo ""
echo "[sync] 完成！浏览器访问: http://192.168.101.2/cgi-bin/luci/admin/services/mynet"
