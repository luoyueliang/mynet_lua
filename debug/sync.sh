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

ROUTER="root@localhost"
PORT=2222
SSH_OPTS="-p $PORT -o StrictHostKeyChecking=no -o ConnectTimeout=5"
SCP_OPTS="-P $PORT -o StrictHostKeyChecking=no"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 检查连通性
if ! ssh $SSH_OPTS $ROUTER "true" 2>/dev/null; then
    echo "[sync] 无法连接 $ROUTER:$PORT"
    echo "       请先运行: bash debug/start.sh"
    exit 1
fi

sync_controller() {
    echo "[sync] controller ..."
    scp $SCP_OPTS \
        "$PROJECT_DIR/luasrc/controller/mynet.lua" \
        $ROUTER:/usr/lib/lua/luci/controller/
}

sync_model() {
    echo "[sync] model ..."
    ssh $SSH_OPTS $ROUTER "mkdir -p /usr/lib/lua/luci/model/mynet"
    scp $SCP_OPTS \
        "$PROJECT_DIR/luasrc/model/mynet/"*.lua \
        $ROUTER:/usr/lib/lua/luci/model/mynet/
}

sync_view() {
    echo "[sync] view ..."
    ssh $SSH_OPTS $ROUTER "mkdir -p /usr/share/luci/view/mynet"
    scp $SCP_OPTS \
        "$PROJECT_DIR/luasrc/view/mynet/"*.htm \
        $ROUTER:/usr/share/luci/view/mynet/
}

sync_static() {
    echo "[sync] static (css/js) ..."
    ssh $SSH_OPTS $ROUTER \
        "mkdir -p /www/luci-static/resources/mynet/css \
                  /www/luci-static/resources/mynet/js"
    scp $SCP_OPTS \
        "$PROJECT_DIR/htdocs/luci-static/resources/mynet/css/mynet.css" \
        $ROUTER:/www/luci-static/resources/mynet/css/
    scp $SCP_OPTS \
        "$PROJECT_DIR/htdocs/luci-static/resources/mynet/js/mynet.js" \
        $ROUTER:/www/luci-static/resources/mynet/js/
}

sync_config() {
    echo "[sync] config.json ..."
    ssh $SSH_OPTS $ROUTER "mkdir -p /etc/mynet/conf"
    scp $SCP_OPTS \
        "$PROJECT_DIR/root/etc/mynet/conf/config.json" \
        $ROUTER:/etc/mynet/conf/
}

clear_cache() {
    echo "[sync] 清理 LuCI 缓存 ..."
    ssh $SSH_OPTS $ROUTER "rm -rf /tmp/luci-*"
}

install_luci() {
    echo "[sync] 安装 LuCI（首次部署）..."
    ssh $SSH_OPTS $ROUTER \
        "opkg update && opkg install luci luci-base luci-lib-jsonc curl 2>&1 | tail -5"
}

TARGET="${1:-all}"

case "$TARGET" in
    all)
        sync_controller
        sync_model
        sync_view
        sync_static
        sync_config
        clear_cache
        ;;
    controller)  sync_controller; clear_cache ;;
    model)       sync_model;      clear_cache ;;
    view)        sync_view;       clear_cache ;;
    static)      sync_static ;;
    config)      sync_config ;;
    install)     install_luci; sync_controller; sync_model; sync_view; sync_static; sync_config; clear_cache ;;
    *)
        echo "用法: $0 [all|controller|model|view|static|config|install]"
        exit 1
        ;;
esac

echo ""
echo "[sync] 完成！访问: http://localhost:8080/cgi-bin/luci/admin/mynet"
