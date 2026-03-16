-- mynet/system.lua — 系统环境检测、路由器信息收集、GNB数据解析
-- 从 controller/mynet.lua 拆出，供 controller 调用。

local M = {}
local util = require("luci.model.mynet.util")

-- ─────────────────────────────────────────────────────────────
-- 私有辅助
-- ─────────────────────────────────────────────────────────────

local function uci_get(key)
    return util.trim(util.exec("uci get " .. key .. " 2>/dev/null") or "")
end

local function cmd_exists(name)
    local _, c = util.exec_status("command -v " .. name .. " 2>/dev/null")
    return c == 0
end

-- ─────────────────────────────────────────────────────────────
-- 平台检测
-- ─────────────────────────────────────────────────────────────

function M.is_openwrt()
    local _, c = util.exec_status("test -f /etc/openwrt_release 2>/dev/null")
    if c == 0 then return true end
    return cmd_exists("uci")
end

-- ─────────────────────────────────────────────────────────────
-- mynetd 运行状态  →  (status_str, pid_str)
-- ─────────────────────────────────────────────────────────────

function M.get_mynetd_status()
    local pid_str = util.trim(util.read_file("/var/run/mynetd.pid") or "")
    if pid_str ~= "" then
        local _, code = util.exec_status("kill -0 " .. pid_str .. " 2>/dev/null")
        if code == 0 then return "running", pid_str end
    end
    local out, code = util.exec_status("pgrep -x mynetd 2>/dev/null")
    if code == 0 and util.trim(out or "") ~= "" then
        return "running", util.trim(out):match("^(%d+)")
    end
    return "stopped", nil
end

-- ─────────────────────────────────────────────────────────────
-- 依赖检查
-- ─────────────────────────────────────────────────────────────

-- 检查 kmod-tun 是否加载（/dev/net/tun 或 lsmod）
local function check_kmod_tun()
    local _, c = util.exec_status("test -c /dev/net/tun 2>/dev/null")
    if c == 0 then return true, nil end
    local out = util.trim(util.exec("lsmod 2>/dev/null | grep -w tun") or "")
    if out ~= "" then return true, nil end
    return false, "kmod-tun not loaded (/dev/net/tun missing)"
end

-- 检查 SSL/TLS 支持（curl https）
local function check_ssl()
    if not cmd_exists("curl") then
        return false, "curl not found"
    end
    -- curl --version 检查 https 协议支持
    local out = util.trim(util.exec("curl --version 2>/dev/null | head -2") or "")
    if out:lower():find("https") or out:lower():find("tls") or out:lower():find("ssl") then
        return true, nil
    end
    return false, "curl lacks HTTPS/SSL support (install curl with libopenssl)"
end

-- 检查 gnb_ctl 是否存在
local function check_gnb_ctl(node_id)
    local ctl = util.GNB_DRIVER_ROOT .. "/bin/gnb_ctl"
    if util.file_exists(ctl) then return true, nil, ctl end
    return false, "gnb_ctl not found at " .. ctl, ctl
end

-- 检查 gnb 主进程是否在运行（通过 pid 文件或 pgrep）
local function check_gnb_process(node_id)
    if not node_id or tostring(node_id) == "0" then
        return false, "no node_id configured"
    end
    local pid_file = util.GNB_DRIVER_ROOT .. "/conf/" .. tostring(node_id) .. "/gnb.pid"
    local pid_str = util.trim(util.read_file(pid_file) or "")
    if pid_str ~= "" then
        local _, code = util.exec_status("kill -0 " .. pid_str .. " 2>/dev/null")
        if code == 0 then return true, nil, pid_str end
    end
    local out, code = util.exec_status("pgrep -x gnb 2>/dev/null")
    if code == 0 and util.trim(out or "") ~= "" then
        return true, nil, util.trim(out):match("^(%d+)")
    end
    return false, "gnb process not running"
end

-- 汇总依赖检查结果
function M.check_deps(node_id)
    local deps = {}

    -- curl
    local has_curl = cmd_exists("curl")
    table.insert(deps, {
        name = "curl",
        ok   = has_curl,
        hint = has_curl and nil or "opkg install curl",
    })

    -- SSL
    local ssl_ok, ssl_err = check_ssl()
    table.insert(deps, {
        name = "SSL/HTTPS",
        ok   = ssl_ok,
        hint = ssl_ok and nil or ((ssl_err or "check failed") .. " — opkg install libopenssl"),
    })

    -- kmod-tun
    local tun_ok, tun_err = check_kmod_tun()
    table.insert(deps, {
        name = "kmod-tun",
        ok   = tun_ok,
        hint = tun_ok and nil or ((tun_err or "check failed") .. " — opkg install kmod-tun"),
    })

    -- ip command
    local ip_ok = cmd_exists("ip")
    table.insert(deps, {
        name = "ip",
        ok   = ip_ok,
        hint = ip_ok and nil or "opkg install ip-full",
    })

    -- gnb_ctl
    local gnb_ok, gnb_err = check_gnb_ctl(node_id)
    table.insert(deps, {
        name = "gnb_ctl",
        ok   = gnb_ok,
        hint = gnb_ok and nil or ((gnb_err or "not found") .. " — run mynet install or download gnb driver"),
    })

    -- gnb process
    local gnbp_ok, gnbp_err, gnbp_pid = check_gnb_process(node_id)
    table.insert(deps, {
        name = "gnb process",
        ok   = gnbp_ok,
        hint = gnbp_ok and ("pid=" .. (gnbp_pid or "?")) or gnbp_err,
        pid  = gnbp_pid,
    })

    -- 总体状态
    local all_ok = true
    local critical_ok = true  -- 只统计非 gnb-process 的 critical 依赖
    for _, d in ipairs(deps) do
        if not d.ok then
            all_ok = false
            if d.name ~= "gnb process" then critical_ok = false end
        end
    end
    return deps, all_ok, critical_ok
end

-- ─────────────────────────────────────────────────────────────
-- 防火墙状态（OpenWrt UCI）
-- ─────────────────────────────────────────────────────────────

-- 查找 mynet zone 的 UCI 索引（返回 nil 若不存在）
local function find_mynet_zone_index()
    for i = 0, 15 do
        local name = uci_get(string.format("firewall.@zone[%d].name", i))
        if name == "" then break end
        if name == "mynet" then return i end
    end
    return nil
end

function M.collect_firewall_info()
    local fw = {
        mynet_zone_exists = false,
        mynet_masq        = false,
        forwards          = {},  -- { src, dest, action }
    }

    local zi = find_mynet_zone_index()
    if not zi then return fw end

    fw.mynet_zone_exists = true
    fw.mynet_masq = (uci_get(string.format("firewall.@zone[%d].masq", zi)) == "1")

    -- 收集 forwarding 规则
    local pairs_checked = { lan_mynet=false, mynet_lan=false, wan_mynet=false, mynet_wan=false }
    for i = 0, 30 do
        local src  = uci_get(string.format("firewall.@forwarding[%d].src",  i))
        local dest = uci_get(string.format("firewall.@forwarding[%d].dest", i))
        if src == "" then break end
        local key = src .. "_" .. dest
        if (src == "lan" or src == "wan" or src == "mynet") and
           (dest == "lan" or dest == "wan" or dest == "mynet") then
            -- 避免重复
            if not pairs_checked[key] then
                pairs_checked[key] = true
                table.insert(fw.forwards, { src = src, dest = dest, action = "ACCEPT" })
            end
        end
    end

    return fw
end

-- ─────────────────────────────────────────────────────────────
-- 路由器核心信息收集
-- ─────────────────────────────────────────────────────────────

function M.collect_router_info(node_id)
    local openwrt = M.is_openwrt()
    local info = { openwrt = openwrt }

    -- ── 路由模式 ──
    local wan_iface = ""
    if openwrt then
        wan_iface = uci_get("network.wan.device")
        if wan_iface == "" then wan_iface = uci_get("network.wan.ifname") end
    end
    info.wan_iface = wan_iface ~= "" and wan_iface or nil

    if openwrt then
        info.routing_mode = (wan_iface ~= "") and "主路由 (Gateway)" or "旁路由 (Bypass)"
    else
        info.routing_mode = "Linux"
    end

    -- ── WAN IP ──
    if info.wan_iface then
        info.wan_ip = util.trim(util.exec(
            "ip addr show " .. info.wan_iface
            .. " 2>/dev/null | awk '/inet /{print $2}' | head -1") or "")
    end
    if info.wan_ip == "" then info.wan_ip = nil end

    -- ── LAN ──
    if openwrt then
        info.lan_ip = uci_get("network.lan.ipaddr")
        if info.lan_ip == "" then
            info.lan_ip = util.trim(util.exec(
                "ip addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | head -1") or "")
        end
    end
    if info.lan_ip == "" then info.lan_ip = nil end

    -- ── 默认网关 ──
    info.gateway = util.trim(util.exec(
        "ip route show default 2>/dev/null | head -1"
        .. " | awk '{for(i=1;i<NF;i++){if($i==\"via\") print $(i+1)}}'") or "")
    if info.gateway == "" then info.gateway = nil end

    -- ── VPN 接口 ──
    if openwrt then
        info.vpn_iface = uci_get("network.mynet.device")
        if info.vpn_iface == "" then info.vpn_iface = uci_get("network.mynet.ifname") end
    end
    if not info.vpn_iface or info.vpn_iface == "" then
        info.vpn_iface = util.trim(util.exec(
            "ip addr 2>/dev/null | awk '/^[0-9]+:.*gnb_tun/{gsub(\":\",\"\",$2); print $2}' | head -1") or "")
    end
    if info.vpn_iface == "" then info.vpn_iface = nil end

    -- ── VPN 接口 IP（tun 地址）──
    if info.vpn_iface then
        info.vpn_ip = util.trim(util.exec(
            "ip addr show " .. info.vpn_iface
            .. " 2>/dev/null | awk '/inet /{print $2}' | head -1") or "")
        if info.vpn_ip == "" then info.vpn_ip = nil end
    end

    -- ── 路由计数 ──
    local routes_out = util.exec("ip route show 2>/dev/null") or ""
    local total, vpn_routes = 0, 0
    local vpn_dev = info.vpn_iface or "__none__"
    for line in (routes_out .. "\n"):gmatch("([^\n]+)\n") do
        if line:match("%S") then
            total = total + 1
            if line:find("dev mynet") or line:find("dev wg0")
               or line:find("dev " .. vpn_dev) then
                vpn_routes = vpn_routes + 1
            end
        end
    end
    info.total_routes = total
    info.vpn_routes   = vpn_routes

    -- ── 防火墙 ──
    if openwrt then
        info.firewall = M.collect_firewall_info()
    end

    -- ── 依赖检查 ──
    info.deps, info.deps_all_ok, info.deps_critical_ok = M.check_deps(node_id)

    -- ── gnb 进程运行状态 ──
    local gnbp_ok, gnbp_err, gnbp_pid = check_gnb_process(node_id)
    info.gnb_running = gnbp_ok
    info.gnb_pid     = gnbp_pid
    info.gnb_err     = gnbp_err

    return info
end

-- ─────────────────────────────────────────────────────────────
-- 解析 gnb_ctl 输出
-- ─────────────────────────────────────────────────────────────

function M.parse_gnb_nodes(output)
    local nodes = {}
    local cur = nil
    local in_avail = false

    for raw_line in (output .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw_line:match("^%s*(.-)%s*$")
        if line ~= "" then
            local node_id_str = line:match("^node (%d+)$")
            if node_id_str then
                if cur then table.insert(nodes, cur) end
                cur = {
                    node_id      = tonumber(node_id_str),
                    tun_ipv4     = "", tun_ipv6 = "",
                    wan_ipv4     = "", wan_ipv6 = "",
                    detect_count = 0,
                    ipv4_latency = 0,  ipv6_latency = 0,
                    conn_status  = "unknown",
                    in_bytes     = 0,  out_bytes = 0,
                    avail_addrs  = 0,  avail_ips = {},
                    is_local     = false,
                }
                in_avail = false
            elseif cur then
                if line == "available_address4:" then
                    in_avail = true
                elseif in_avail then
                    local ip_port = line:match("^address (.+)$")
                    if ip_port then
                        cur.avail_addrs = cur.avail_addrs + 1
                        local ip = ip_port:match("^([%d%.]+)")
                        if ip then table.insert(cur.avail_ips, ip) end
                    elseif line:match(":$") then
                        in_avail = false
                    end
                else
                    local k, v = line:match("^(%S+) (.+)$")
                    if k and v then
                        if     k == "tun_ipv4"                then cur.tun_ipv4     = v
                        elseif k == "tun_ipv6"                then cur.tun_ipv6     = v
                        elseif k == "wan_ipv4"                then cur.wan_ipv4     = v
                        elseif k == "wan_ipv6"                then cur.wan_ipv6     = v
                        elseif k == "detect_count"            then cur.detect_count = tonumber(v) or 0
                        elseif k == "addr4_ping_latency_usec" then cur.ipv4_latency = tonumber(v) or 0
                        elseif k == "addr6_ping_latency_usec" then cur.ipv6_latency = tonumber(v) or 0
                        elseif k == "in" then
                            -- format: "in  2350576454 (2.189G bytes)" — take raw count before '('
                            cur.in_bytes = tonumber(v:match("^%s*(%d+)")) or 0
                        elseif k == "out" then
                            cur.out_bytes = tonumber(v:match("^%s*(%d+)")) or 0
                        elseif k == "ipv4" then
                            if     v:find("Direct Point to Point") then cur.conn_status = "Direct"
                            elseif v:find("InDirect")              then cur.conn_status = "InDirect"
                            elseif v:find("Local node")            then cur.conn_status = "Local"; cur.is_local = true
                            end
                        end
                    end
                end
            end
        end
    end
    if cur then table.insert(nodes, cur) end
    return nodes
end

return M
