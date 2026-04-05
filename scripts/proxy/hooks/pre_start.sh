#!/bin/sh
#
# Proxy plugin — pre_start hook
# Called by rc.mynet before GNB starts.
# Non-blocking: just logs config readiness.
#

ROLE_CONF="$MYNET_HOME/conf/proxy/proxy_role.conf"
PROXY_SH="$MYNET_HOME/scripts/proxy/proxy.sh"

log_proxy() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [proxy/pre_start] $1"; }

if [ -z "$MYNET_HOME" ] || [ ! -d "$MYNET_HOME" ]; then
    echo "[proxy/pre_start] MYNET_HOME not set or missing"
    exit 0
fi

if [ ! -f "$ROLE_CONF" ]; then
    log_proxy "proxy_role.conf not found — proxy disabled"
    exit 0
fi

# Source bash K=V config
. "$ROLE_CONF"

if [ "$PROXY_ENABLED" != "1" ]; then
    log_proxy "PROXY_ENABLED != 1 — skipping"
    exit 0
fi

if [ -z "$PROXY_PEERS" ]; then
    log_proxy "WARNING: PROXY_ENABLED=1 but PROXY_PEERS is empty"
    exit 0
fi

if [ ! -x "$PROXY_SH" ] && [ ! -f "$PROXY_SH" ]; then
    log_proxy "WARNING: proxy.sh not found at $PROXY_SH"
    exit 0
fi

log_proxy "proxy config OK: mode=$PROXY_MODE region=$NODE_REGION peers=$PROXY_PEERS"
exit 0
