#!/usr/bin/env bash
# sync.sh — 将项目文件同步到 QEMU OpenWrt 虚拟机
#
# 用法:
#   bash debug/sync.sh           # 同步所有文件
#   bash debug/sync.sh controller  # 只同步 controller
#   bash debug/sync.sh model       # 只同步 model
#   bash debug/sync.sh view        # 只同步 view
#   bash debug/sync.sh static      # 只同步 CSS/JS
#   bash debug/sync.sh config      # 只同步 config.json

set -euo pipefail

ROUTER="openwrt-qemu"
SSH_OPTS="-o ConnectTimeout=5"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 上传单个文件（使用旧协议 SCP ，不依赖 sftp-server）
# 用法: ssh_put <本地路径> <远端路径>
ssh_put() {
    local src="$1" dst="$2"
    scp -O $SSH_OPTS "$src" "$ROUTER:$dst"
}

# 检查连通性
if ! ssh $SSH_OPTS $ROUTER "true" 2>/dev/null; then
    echo "[sync] 无法连接 $ROUTER"
    echo "       请先运行: bash debug/start.sh"
    exit 1
fi

sync_controller() {
    echo "[sync] controller ..."
    ssh_put "$PROJECT_DIR/luasrc/controller/mynet.lua" \
            "/usr/lib/lua/luci/controller/mynet.lua"
}

sync_model() {
    echo "[sync] model ..."
    ssh $SSH_OPTS $ROUTER "mkdir -p /usr/lib/lua/luci/model/mynet"
    for f in "$PROJECT_DIR/luasrc/model/mynet/"*.lua; do
        ssh_put "$f" "/usr/lib/lua/luci/model/mynet/$(basename "$f")"
    done
}

sync_view() {
    echo "[sync] view ..."
    ssh $SSH_OPTS $ROUTER "mkdir -p /usr/lib/lua/luci/view/mynet"
    for f in "$PROJECT_DIR/luasrc/view/mynet/"*.htm; do
        ssh_put "$f" "/usr/lib/lua/luci/view/mynet/$(basename "$f")"
    done
}

sync_static() {
    echo "[sync] static (css/js) ..."
    ssh $SSH_OPTS $ROUTER \
        "mkdir -p /www/luci-static/resources/mynet/css /www/luci-static/resources/mynet/js"
    ssh_put "$PROJECT_DIR/htdocs/luci-static/resources/mynet/css/mynet.css" \
            "/www/luci-static/resources/mynet/css/mynet.css"
    ssh_put "$PROJECT_DIR/htdocs/luci-static/resources/mynet/js/mynet.js" \
            "/www/luci-static/resources/mynet/js/mynet.js"
}

sync_config() {
    echo "[sync] config.json ..."
    ssh $SSH_OPTS $ROUTER "mkdir -p /etc/mynet/conf"
    ssh_put "$PROJECT_DIR/root/etc/mynet/conf/config.json" \
            "/etc/mynet/conf/config.json"
}

sync_scripts() {
    echo "[sync] scripts (usr/sbin) ..."
    ssh $SSH_OPTS $ROUTER "mkdir -p /usr/sbin"
    for f in "$PROJECT_DIR/root/usr/sbin/"*; do
        [ -f "$f" ] || continue
        ssh_put "$f" "/usr/sbin/$(basename "$f")"
        ssh $SSH_OPTS $ROUTER "chmod +x /usr/sbin/$(basename "$f")"
    done
}

clear_cache() {
    echo "[sync] 清理 LuCI 缓存 ..."
    ssh $SSH_OPTS $ROUTER "rm -rf /tmp/luci-*"
}

install_luci() {
    echo "[sync] 安装 LuCI Lua runtime（首次部署）..."
    ssh $SSH_OPTS $ROUTER \
        "opkg update && opkg install luci luci-base luci-lib-jsonc luci-lua-runtime luci-compat curl 2>&1 | tail -8"
}

TARGET="${1:-all}"

case "$TARGET" in
    all)
        sync_controller
        sync_model
        sync_view
        sync_static
        sync_config
        sync_scripts
        clear_cache
        ;;
    controller)  sync_controller; clear_cache ;;
    model)       sync_model;      clear_cache ;;
    view)        sync_view;       clear_cache ;;
    static)      sync_static ;;
    config)      sync_config ;;
    scripts)     sync_scripts ;;
    install)     install_luci; sync_controller; sync_model; sync_view; sync_static; sync_config; sync_scripts; clear_cache ;;
    *)
        echo "用法: $0 [all|controller|model|view|static|config|scripts|install]"
        exit 1
        ;;
esac

echo ""
echo "[sync] 完成！浏览器访问: http://localhost:8080/cgi-bin/luci/admin/services/mynet"
