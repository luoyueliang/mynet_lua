#!/bin/sh
#
# Proxy plugin — post_start hook
# Called by rc.mynet after GNB starts.
# If PROXY_ENABLED=1, starts proxy via Lua proxy.start().
#

ROLE_CONF="$MYNET_HOME/conf/proxy/proxy_role.conf"
PROXY_SH="$MYNET_HOME/scripts/proxy/proxy.sh"

log_proxy() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [proxy/post_start] $1"; }

if [ -z "$MYNET_HOME" ] || [ ! -d "$MYNET_HOME" ]; then
    exit 0
fi

if [ ! -f "$ROLE_CONF" ]; then
    log_proxy "proxy_role.conf not found — skipping"
    exit 0
fi

# Source bash K=V config
. "$ROLE_CONF"

if [ "$PROXY_ENABLED" != "1" ]; then
    log_proxy "PROXY_ENABLED != 1 — skipping"
    exit 0
fi

# 统一走 Lua 入口，避免 shell hook 与 proxy.sh/route_policy.sh 协议漂移。
if ! command -v lua >/dev/null 2>&1; then
    log_proxy "ERROR: lua runtime not found"
    exit 1
fi

log_proxy "starting proxy (mode=$PROXY_MODE region=$NODE_REGION)"
MYNET_HOME="$MYNET_HOME" lua <<'LUA' 2>&1 || {
local proxy = require("luci.model.mynet.proxy")
local ok, err = proxy.start()
if not ok then
    io.stderr:write((err or "proxy.start failed") .. "\n")
    os.exit(1)
end
LUA
    log_proxy "ERROR: proxy.start failed (exit $?)"
    exit 1
}

log_proxy "proxy started successfully"
exit 0
