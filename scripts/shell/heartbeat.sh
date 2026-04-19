#!/bin/sh
# mynet-heartbeat — cron 包装器（主逻辑在 Lua）
#
# 调用 system.run_daemon_heartbeat()：
#   - 读取节点公钥 → HMAC-SHA256 签名 → POST /api/v1/monitor/heartbeat
#   - 认证头：X-Node-Id + X-Timestamp + X-Node-Signature（无 JWT token）
#   - 与 Go mynetd 完全对齐，永不过期
#
# cron（postinst 自动写入）：
#   */5 * * * * /usr/bin/mynet-heartbeat
#
# 依赖：lua, curl, sha256sum(busybox), base64(busybox)

MYNET_HOME="${MYNET_HOME:-/etc/mynet}"
LOG="${MYNET_HOME}/var/logs/heartbeat.log"
LOCK="/var/run/mynet_heartbeat.lock"

# 防重入
if [ -f "$LOCK" ]; then
    old_pid=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        exit 0
    fi
fi
mkdir -p "$(dirname "$LOCK")"
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# 日志（保留最后 500 行）
mkdir -p "$(dirname "$LOG")"
_log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
    cnt=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    [ "$cnt" -gt 500 ] && tail -200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

# Lua 路径（OpenWrt LuCI 标准位置）
export LUA_PATH="/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;;"

lua -e "
    local sys = require('luci.model.mynet.system')
    local ok, err = sys.run_daemon_heartbeat()
    if ok then
        io.stdout:write('ok\n')
    else
        io.stderr:write('ERROR: ' .. tostring(err) .. '\n')
        os.exit(1)
    end
" >> "$LOG" 2>&1
rc=$?

if [ $rc -eq 0 ]; then
    _log "✓ ok"
else
    _log "✗ failed (see above)"
fi
