#!/bin/sh
# mynet heartbeat — POSIX sh cron script for OpenWrt
# Sends periodic heartbeat to mynet_back via HMAC-SHA256 signed POST.
#
# Install: add to /etc/crontabs/root
#   */5 * * * * /etc/mynet/scripts/heartbeat.sh >/dev/null 2>&1
#
# Dependencies: curl, openssl (opkg install openssl-util if missing)

set -e

MYNET_HOME="/etc/mynet"
CONF_DIR="$MYNET_HOME/conf"
GNB_ROOT="$MYNET_HOME/driver/gnb"
LOG_FILE="$MYNET_HOME/logs/heartbeat.log"
HEARTBEAT_PATH="/api/v1/monitor/heartbeat"

# ── Logging ────────────────────────────────────────────────────────────────────

log_msg() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$(date)")
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$ts] $1" >> "$LOG_FILE"
    # Rotate log (keep last 200 lines)
    if [ "$(wc -l < "$LOG_FILE" 2>/dev/null)" -gt 500 ]; then
        tail -200 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

# ── Read config ────────────────────────────────────────────────────────────────

get_json_val() {
    # Minimal JSON value extractor (no jq on OpenWrt by default)
    # Usage: get_json_val '{"key":"val"}' key
    echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

get_json_num() {
    echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p" | head -1
}

# Load API base URL
load_api_url() {
    local cfg=""
    [ -f "$CONF_DIR/config.json" ] && cfg=$(cat "$CONF_DIR/config.json")
    local url
    url=$(get_json_val "$cfg" "api_base_url")
    # Strip /api/v2 to get domain
    echo "${url%/api/v*}"
}

# Load current node_id
load_node_id() {
    local node_json=""
    [ -f "$CONF_DIR/node.json" ] && node_json=$(cat "$CONF_DIR/node.json")
    get_json_num "$node_json" "node_id"
}

# Load shared key (hex) from security dir
load_shared_key() {
    local nid="$1"
    local keyfile="$GNB_ROOT/conf/$nid/security/$nid.public"
    [ -f "$keyfile" ] && cat "$keyfile" | tr -d '[:space:]'
}

# ── System metrics ─────────────────────────────────────────────────────────────

get_cpu_usage() {
    # /proc/stat based (delta impossible in single invocation, use 1s sample)
    if [ -f /proc/stat ]; then
        local c1 c2
        c1=$(head -1 /proc/stat | awk '{print $2+$3+$4, $5}')
        sleep 1
        c2=$(head -1 /proc/stat | awk '{print $2+$3+$4, $5}')
        local busy1 idle1 busy2 idle2
        busy1=$(echo "$c1" | awk '{print $1}')
        idle1=$(echo "$c1" | awk '{print $2}')
        busy2=$(echo "$c2" | awk '{print $1}')
        idle2=$(echo "$c2" | awk '{print $2}')
        local db di
        db=$((busy2 - busy1))
        di=$((idle2 - idle1))
        local total=$((db + di))
        if [ "$total" -gt 0 ]; then
            echo "$db $total" | awk '{printf "%.1f", ($1/$2)*100}'
            return
        fi
    fi
    echo "0"
}

get_memory_usage() {
    if [ -f /proc/meminfo ]; then
        awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{if(t>0) printf "%.1f",(1-a/t)*100; else print "0"}' /proc/meminfo
    else
        echo "0"
    fi
}

get_disk_usage() {
    df -k / 2>/dev/null | tail -1 | awk '{if($3+$4>0) printf "%.1f",($3/($3+$4))*100; else print "0"}'
}

get_connection_count() {
    # Count GNB process connections (best-effort)
    local pid
    pid=$(pgrep -x gnb 2>/dev/null | head -1)
    if [ -n "$pid" ] && [ -d "/proc/$pid/fd" ]; then
        ls /proc/"$pid"/fd 2>/dev/null | wc -l
    else
        echo "0"
    fi
}

get_vpn_interface() {
    local ifname="gnb0"
    local status="down"
    local ip=""

    # Check if gnb tun interface exists
    if ip link show "$ifname" >/dev/null 2>&1; then
        status="up"
        ip=$(ip -4 addr show "$ifname" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    fi

    # JSON fragment (no quotes needed for status/type since they're known-safe strings)
    printf '{"type":"gnb","ifname":"%s","status":"%s","ip":"%s"}' "$ifname" "$status" "$ip"
}

# ── HMAC-SHA256 signing ───────────────────────────────────────────────────────

hmac_sign() {
    # Args: method path timestamp body_json shared_key_hex
    local method="$1" path="$2" ts="$3" body="$4" key_hex="$5"
    local message="${method}|${path}|${ts}|${body}"

    # Use openssl for HMAC-SHA256, output raw binary then base64
    printf '%s' "$message" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${key_hex}" -binary | openssl base64 -A
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
    local base_url node_id shared_key

    base_url=$(load_api_url)
    node_id=$(load_node_id)

    if [ -z "$node_id" ] || [ "$node_id" = "0" ]; then
        log_msg "ERROR: no node_id configured"
        exit 1
    fi

    shared_key=$(load_shared_key "$node_id")
    if [ -z "$shared_key" ]; then
        log_msg "ERROR: shared key not found for node $node_id"
        exit 1
    fi

    if [ -z "$base_url" ]; then
        base_url="${MYNET_API_URL:-https://api.mynet.club}"
    fi

    local url="${base_url}${HEARTBEAT_PATH}"
    local timestamp
    timestamp=$(date +%s)

    # Collect metrics
    local cpu mem disk conn vpn_iface
    cpu=$(get_cpu_usage)
    mem=$(get_memory_usage)
    disk=$(get_disk_usage)
    conn=$(get_connection_count)
    vpn_iface=$(get_vpn_interface)

    # Build JSON body (without node_monitor)
    local body
    body=$(printf '{"node_id":%s,"timestamp":%s,"cpu_usage":%s,"memory_usage":%s,"disk_usage":%s,"connection_count":%s,"vpn_interface":%s}' \
        "$node_id" "$timestamp" "$cpu" "$mem" "$disk" "$conn" "$vpn_iface")

    # Sign
    local signature
    signature=$(hmac_sign "POST" "$HEARTBEAT_PATH" "$timestamp" "$body" "$shared_key")

    if [ -z "$signature" ]; then
        log_msg "ERROR: HMAC signing failed (is openssl-util installed?)"
        exit 1
    fi

    # Send
    local resp http_code
    resp=$(curl -s -w '\n__STATUS:%{http_code}' -m 30 \
        -X POST "$url" \
        -H "Content-Type: application/json" \
        -H "X-Node-Id: $node_id" \
        -H "X-Timestamp: $timestamp" \
        -H "X-Node-Signature: $signature" \
        -H "User-Agent: mynet-luci/1.0.0" \
        --data "$body" 2>/dev/null)

    http_code=$(echo "$resp" | sed -n 's/.*__STATUS:\([0-9]*\).*/\1/p')
    local resp_body
    resp_body=$(echo "$resp" | sed 's/\n*__STATUS:[0-9]*$//')

    if [ "$http_code" = "200" ]; then
        log_msg "OK node=$node_id cpu=$cpu mem=$mem disk=$disk"

        # Check for commands in response
        local action
        action=$(echo "$resp_body" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        local cmd_id
        cmd_id=$(echo "$resp_body" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

        if [ -n "$action" ] && [ -n "$cmd_id" ]; then
            log_msg "COMMAND action=$action id=$cmd_id"
            execute_command "$action" "$cmd_id" "$node_id" "$shared_key" "$base_url"
        fi
    else
        log_msg "FAIL http=$http_code node=$node_id"
    fi
}

# ── Command execution ──────────────────────────────────────────────────────────

execute_command() {
    local action="$1" cmd_id="$2" node_id="$3" key_hex="$4" base_url="$5"
    local success="true" message=""

    case "$action" in
        config.refresh)
            # Trigger config resync via init script
            if [ -x /etc/init.d/mynet ]; then
                /etc/init.d/mynet reload 2>&1 && message="Config reloaded" || { success="false"; message="Reload failed"; }
            else
                success="false"; message="init script not found"
            fi
            ;;
        service.restart)
            if [ -x /etc/init.d/mynet ]; then
                /etc/init.d/mynet restart 2>&1 && message="Service restarted" || { success="false"; message="Restart failed"; }
            else
                success="false"; message="init script not found"
            fi
            ;;
        gnb.start)
            if [ -x /etc/init.d/mynet ]; then
                /etc/init.d/mynet start 2>&1 && message="GNB started" || { success="false"; message="Start failed"; }
            else
                success="false"; message="init script not found"
            fi
            ;;
        gnb.stop)
            if [ -x /etc/init.d/mynet ]; then
                /etc/init.d/mynet stop 2>&1 && message="GNB stopped" || { success="false"; message="Stop failed"; }
            else
                success="false"; message="init script not found"
            fi
            ;;
        *)
            success="false"; message="Unknown action: $action"
            ;;
    esac

    log_msg "EXEC action=$action success=$success msg=$message"

    # Report result
    report_result "$cmd_id" "$node_id" "$success" "$message" "$key_hex" "$base_url"
}

report_result() {
    local cmd_id="$1" node_id="$2" success="$3" message="$4" key_hex="$5" base_url="$6"
    local url_path="/api/v1/monitor/commands/${cmd_id}/result"
    local url="${base_url}${url_path}"
    local timestamp
    timestamp=$(date +%s)

    local body
    body=$(printf '{"success":%s,"message":"%s"}' "$success" "$message")

    local signature
    signature=$(hmac_sign "PATCH" "$url_path" "$timestamp" "$body" "$key_hex")

    curl -s -m 15 -X PATCH "$url" \
        -H "Content-Type: application/json" \
        -H "X-Node-Id: $node_id" \
        -H "X-Timestamp: $timestamp" \
        -H "X-Node-Signature: $signature" \
        -H "User-Agent: mynet-luci/1.0.0" \
        --data "$body" >/dev/null 2>&1 || true
}

# ── Entry point ────────────────────────────────────────────────────────────────

main "$@"
