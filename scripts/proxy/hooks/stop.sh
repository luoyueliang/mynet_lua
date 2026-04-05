#!/bin/sh
#
# Proxy plugin — stop hook
# Called by rc.mynet when GNB stops.
# Unconditionally stops proxy + cleans GNB route.conf markers.
#

ROLE_CONF="$MYNET_HOME/conf/proxy/proxy_role.conf"
PROXY_SH="$MYNET_HOME/scripts/proxy/proxy.sh"

# Marker constants (must match proxy.lua and pre_start/post_start)
MARKER_START="#----proxy start----"
MARKER_END="#----proxy end----"

log_proxy() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [proxy/stop] $1"; }

if [ -z "$MYNET_HOME" ] || [ ! -d "$MYNET_HOME" ]; then
    exit 0
fi

# 1. Stop proxy.sh (policy routing + DNS) — unconditional
if [ -f "$PROXY_SH" ]; then
    log_proxy "stopping proxy.sh..."
    MYNET_HOME="$MYNET_HOME" bash "$PROXY_SH" stop 2>&1 || true
fi

# 2. Clean GNB route.conf marker section
#    Find all node route.conf files under driver/gnb/conf/*/route.conf
GNB_CONF_DIR="$MYNET_HOME/driver/gnb/conf"
if [ -d "$GNB_CONF_DIR" ]; then
    for rc in "$GNB_CONF_DIR"/*/route.conf; do
        [ -f "$rc" ] || continue
        if grep -q "$MARKER_START" "$rc" 2>/dev/null; then
            log_proxy "cleaning markers from $rc"
            sed -i "/$MARKER_START/,/$MARKER_END/d" "$rc" 2>/dev/null || true
        fi
    done
fi

# 3. Clear proxy state
rm -f "$MYNET_HOME/var/proxy_state.json" 2>/dev/null || true

log_proxy "proxy stopped"
exit 0
