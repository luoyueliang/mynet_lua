#!/bin/bash
#
# Peer 节点公网IP监控脚本 (proxy_ex_monitor.sh)
# 定期检查 peer 节点的公网IP变化，动态更新防火墙排除规则
#
# 用法:
#   ./proxy_ex_monitor.sh start   # 启动监控
#   ./proxy_ex_monitor.sh stop    # 停止监控
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MYNET_HOME="$(dirname "$SCRIPT_DIR")"

# 配置
PID_FILE="$MYNET_HOME/var/run/proxy_ex_monitor.pid"
CACHE_FILE="$MYNET_HOME/var/cache/proxy_exclude_ips.txt"
LOG_FILE="$MYNET_HOME/var/log/proxy_ex_monitor.log"
CHECK_INTERVAL=30  # 检查间隔（秒）
IPSET_NAME="mynet_proxy"
NFT_SET_NAME="mynet_proxy"

# 确保目录存在
mkdir -p "$(dirname "$PID_FILE")"
mkdir -p "$(dirname "$CACHE_FILE")"
mkdir -p "$(dirname "$LOG_FILE")"

# 检测防火墙类型
detect_firewall() {
    if command -v nft >/dev/null 2>&1 && nft list tables 2>/dev/null | grep -q .; then
        echo "nftables"
    elif command -v iptables >/dev/null 2>&1 && command -v ipset >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "unknown"
    fi
}

FW_TYPE=$(detect_firewall)

# 获取需要排除的peer节点公网IP列表（不包括索引服务器 - 仅对GNB生效）
get_peer_exclude_ips() {
    local exclude_ips=""

    # 检查VPN类型
    local vpn_type=$(grep "^VPN_TYPE=" "$MYNET_HOME/conf/mynet.conf" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | head -1)
    if [ "$vpn_type" != "gnb" ]; then
        echo ""
        return 0
    fi

    # 获取本地节点ID
    local node_id=""
    if [ -f "$MYNET_HOME/conf/mynet.conf" ]; then
        node_id=$(grep "^# Node:" "$MYNET_HOME/conf/mynet.conf" | sed -n 's/.*ID: \([0-9]*\).*/\1/p')
    fi

    if [ -z "$node_id" ]; then
        return 1
    fi

    # 使用 gnb_ctl 获取 peer 节点的公网IP（不包括索引服务器）
    local gnb_ctl="$MYNET_HOME/driver/gnb/bin/gnb_ctl"
    local gnb_map="$MYNET_HOME/driver/gnb/conf/$node_id/gnb.map"

    if [ -x "$gnb_ctl" ] && [ -f "$gnb_map" ]; then
        local gnb_output=$("$gnb_ctl" -s -b "$gnb_map" 2>/dev/null)

        if [ $? -eq 0 ] && [ -n "$gnb_output" ]; then
            while read -r line; do
                if [[ "$line" =~ ^wan_ipv4[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+): ]]; then
                    local peer_ip="${BASH_REMATCH[1]}"

                    # 排除本机IP和私有IP段
                    if [ "$peer_ip" != "0.0.0.0" ] && \
                       ! [[ "$peer_ip" =~ ^10\. ]] && \
                       ! [[ "$peer_ip" =~ ^172\.1[6-9]\. ]] && \
                       ! [[ "$peer_ip" =~ ^172\.2[0-9]\. ]] && \
                       ! [[ "$peer_ip" =~ ^172\.3[0-1]\. ]] && \
                       ! [[ "$peer_ip" =~ ^192\.168\. ]]; then

                        if [[ ",$exclude_ips," != *",$peer_ip,"* ]]; then
                            if [ -z "$exclude_ips" ]; then
                                exclude_ips="$peer_ip"
                            else
                                exclude_ips="$exclude_ips,$peer_ip"
                            fi
                        fi
                    fi
                fi
            done <<< "$gnb_output"
        fi
    fi

    echo "$exclude_ips"
}

# 应用 iptables 排除规则
apply_iptables_rules() {
    local new_ips="$1"
    local old_ips="$2"

    # 转换为数组
    IFS=',' read -ra new_array <<< "$new_ips"
    IFS=',' read -ra old_array <<< "$old_ips"

    # 找出需要删除的IP（在旧列表中但不在新列表中）
    for old_ip in "${old_array[@]}"; do
        old_ip=$(echo "$old_ip" | xargs)
        [ -z "$old_ip" ] && continue

        if [[ ",$new_ips," != *",$old_ip,"* ]]; then
            # 删除规则（可能有多条，循环删除）
            while iptables -w 5 -t mangle -D PREROUTING -d "$old_ip" -j ACCEPT 2>/dev/null; do
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已删除过期IP排除规则: $old_ip"
            done
        fi
    done

    # 找出需要添加的IP（在新列表中但不在旧列表中）
    for new_ip in "${new_array[@]}"; do
        new_ip=$(echo "$new_ip" | xargs)
        [ -z "$new_ip" ] && continue

        if [[ ",$old_ips," != *",$new_ip,"* ]]; then
            # 检查规则是否已存在
            if ! iptables -w 5 -t mangle -C PREROUTING -d "$new_ip" -j ACCEPT 2>/dev/null; then
                iptables -w 5 -t mangle -I PREROUTING -d "$new_ip" -j ACCEPT
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已添加新IP排除规则: $new_ip"
            fi
        fi
    done
}

# 应用 nftables 排除规则（使用 nft set 增量更新）
apply_nftables_rules() {
    local new_ips="$1"
    local old_ips="$2"

    # 计算需要添加和删除的IP
    IFS=',' read -ra new_array <<< "$new_ips"
    IFS=',' read -ra old_array <<< "$old_ips"

    # 删除不再存在的IP（从exclude_ips set中移除）
    for old_ip in "${old_array[@]}"; do
        old_ip=$(echo "$old_ip" | xargs)
        [ -z "$old_ip" ] && continue

        # 检查是否在新列表中
        local found=0
        for new_ip in "${new_array[@]}"; do
            new_ip=$(echo "$new_ip" | xargs)
            if [ "$old_ip" = "$new_ip" ]; then
                found=1
                break
            fi
        done

        # 如果不在新列表中，从set中删除
        if [ $found -eq 0 ]; then
            nft delete element inet mynet_proxy exclude_ips { "$old_ip" } 2>/dev/null
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 从exclude_ips set删除: $old_ip"
        fi
    done

    # 添加新出现的IP（添加到exclude_ips set）
    for new_ip in "${new_array[@]}"; do
        new_ip=$(echo "$new_ip" | xargs)
        [ -z "$new_ip" ] && continue

        # 检查是否在旧列表中
        local found=0
        for old_ip in "${old_array[@]}"; do
            old_ip=$(echo "$old_ip" | xargs)
            if [ "$new_ip" = "$old_ip" ]; then
                found=1
                break
            fi
        done

        # 如果是新IP，添加到set
        if [ $found -eq 0 ]; then
            nft add element inet mynet_proxy exclude_ips { "$new_ip" } 2>/dev/null
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 添加到exclude_ips set: $new_ip"
        fi
    done

    if [ -n "$new_ips" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已更新 nftables exclude_ips set: $new_ips"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 清空所有 peer排除规则"
    fi
}

# 监控主循环
monitor_loop() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 启动 Peer 节点公网IP监控"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检查间隔: ${CHECK_INTERVAL}秒"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 防火墙类型: $FW_TYPE"

    local old_ips=""
    local first_run=1

    # 首次运行不加载缓存，强制重新添加所有规则（因为代理重启后规则会被清空）
    # 后续运行才从缓存加载

    while true; do
        # 获取当前的peer节点公网IP列表（不包括索引服务器）
        local new_ips=$(get_peer_exclude_ips)

        if [ -n "$new_ips" ]; then
            # 首次运行或检测到变化时更新规则
            if [ $first_run -eq 1 ] || [ "$new_ips" != "$old_ips" ]; then
                if [ $first_run -eq 1 ]; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 首次运行，初始化peer IP规则（强制添加）"
                    first_run=0
                else
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测到IP列表变化"
                fi
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 旧列表: $old_ips"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 新列表: $new_ips"

                # 更新防火墙规则
                case "$FW_TYPE" in
                    iptables)
                        apply_iptables_rules "$new_ips" "$old_ips"
                        ;;
                    nftables)
                        apply_nftables_rules "$new_ips" "$old_ips"
                        ;;
                esac

                # 保存到缓存
                echo "$new_ips" > "$CACHE_FILE"
                old_ips="$new_ips"
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# 启动监控
start_monitor() {
    # 检查是否已在运行
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "[ERROR] 监控进程已在运行 (PID: $old_pid)"
            return 1
        else
            rm -f "$PID_FILE"
        fi
    fi

    # 后台启动监控
    monitor_loop >> "$LOG_FILE" 2>&1 &
    local pid=$!

    echo "$pid" > "$PID_FILE"
    echo "[INFO] ✓ 监控进程已启动 (PID: $pid)"
    echo "[INFO]   日志文件: $LOG_FILE"
}

# 停止监控
stop_monitor() {
    if [ ! -f "$PID_FILE" ]; then
        echo "[INFO] 监控进程未运行"
        return 0
    fi

    local pid=$(cat "$PID_FILE")

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        echo "[INFO] ✓ 监控进程已停止 (PID: $pid)"
    else
        echo "[INFO] 监控进程不存在 (PID: $pid)"
    fi

    rm -f "$PID_FILE"
}

# 主命令处理
case "${1:-}" in
    start)
        start_monitor
        ;;
    stop)
        stop_monitor
        ;;
    restart)
        stop_monitor
        sleep 1
        start_monitor
        ;;
    status)
        if [ -f "$PID_FILE" ]; then
            pid=$(cat "$PID_FILE")
            if kill -0 "$pid" 2>/dev/null; then
                echo "监控进程运行中 (PID: $pid)"
                if [ -f "$CACHE_FILE" ]; then
                    echo "当前排除IP: $(cat "$CACHE_FILE")"
                fi
            else
                echo "监控进程未运行 (PID文件存在但进程不存在)"
            fi
        else
            echo "监控进程未运行"
        fi
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
