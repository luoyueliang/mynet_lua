#!/bin/sh
#
# Proxy plugin — post_start hook
# Called by rc.mynet after GNB starts.
# If PROXY_ENABLED=1, starts proxy (route_inject + proxy.sh start).
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

# GNB route.conf inject is handled by Lua (proxy.lua route_inject)
# via node.lua refresh_configs re-inject logic.
# Here we only start the OS-level proxy (policy routing + DNS).

if [ ! -f "$PROXY_SH" ]; then
    log_proxy "ERROR: proxy.sh not found at $PROXY_SH"
    exit 1
fi

log_proxy "starting proxy (mode=$PROXY_MODE region=$NODE_REGION)"
MYNET_HOME="$MYNET_HOME" bash "$PROXY_SH" start 2>&1 || {
    log_proxy "ERROR: proxy.sh start failed (exit $?)"
    exit 1
}

log_proxy "proxy started successfully"
exit 0
