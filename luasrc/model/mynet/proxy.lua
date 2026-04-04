-- mynet/proxy.lua — Proxy 分流模块管理
-- 对齐 client proxy 插件：start/stop/status/diagnose
-- 通过调用 shell 脚本实现，提供结构化 JSON 接口给 LuCI

local M    = {}
local util = require("luci.model.mynet.util")

-- ─────────────────────────────────────────────────────────────
-- 路径常量
-- ─────────────────────────────────────────────────────────────

local PROXY_SCRIPT_DIR = util.MYNET_HOME .. "/scripts/proxy"
local PROXY_SH         = PROXY_SCRIPT_DIR .. "/proxy.sh"
local ROUTE_POLICY_SH  = PROXY_SCRIPT_DIR .. "/openwrt/route_policy.sh"
local PROXY_CONF_DIR   = util.CONF_DIR .. "/proxy"
local PROXY_ROLE_CONF  = PROXY_CONF_DIR .. "/proxy_role.conf"
local PROXY_STATE_FILE = util.MYNET_HOME .. "/var/proxy_state.json"

-- ─────────────────────────────────────────────────────────────
-- 配置读写
-- ─────────────────────────────────────────────────────────────

-- 读取 proxy_role.conf (bash KEY=VALUE 格式)
function M.load_config()
    local content = util.read_file(PROXY_ROLE_CONF)
    if not content then
        return {
            proxy_enabled = false,
            proxy_mode    = "client",
            node_region   = "domestic",
            dns_mode      = "none",
            dns_server    = "",
            proxy_peers   = "",
        }
    end
    local result = {}
    for line in content:gmatch("[^\n]+") do
        line = util.trim(line)
        if line ~= "" and not line:match("^#") then
            local k, v = line:match('^([%w_]+)%s*=%s*"?(.-)"?%s*$')
            if k then result[k:lower()] = v end
        end
    end
    return {
        proxy_enabled = (result.proxy_enabled == "1" or result.proxy_enabled == "true"),
        proxy_mode    = result.proxy_mode  or "client",
        node_region   = result.node_region or "domestic",
        dns_mode      = result.dns_mode    or "none",
        dns_server    = result.dns_server  or "",
        proxy_peers   = result.proxy_peers or "",
    }
end

-- 保存 proxy 配置
function M.save_config(opts)
    util.ensure_dir(PROXY_CONF_DIR)
    local lines = {
        '# MyNet Proxy Configuration',
        '# Updated: ' .. util.format_time(util.time_now()),
        'PROXY_ENABLED="' .. (opts.proxy_enabled and "1" or "0") .. '"',
        'PROXY_MODE="'    .. (opts.proxy_mode  or "client")   .. '"',
        'NODE_REGION="'   .. (opts.node_region or "domestic")  .. '"',
        'DNS_MODE="'      .. (opts.dns_mode    or "none")      .. '"',
        'DNS_SERVER="'    .. (opts.dns_server  or "")          .. '"',
        'PROXY_PEERS="'   .. (opts.proxy_peers or "")          .. '"',
    }
    return util.write_file(PROXY_ROLE_CONF, table.concat(lines, "\n") .. "\n")
end

-- ─────────────────────────────────────────────────────────────
-- 状态查询（解析 JSON 输出或 fallback 到进程检测）
-- ─────────────────────────────────────────────────────────────

function M.get_status()
    -- 尝试 proxy.sh status --json
    if util.file_exists(PROXY_SH) then
        local out = util.exec("MYNET_HOME=" .. util.shell_escape(util.MYNET_HOME)
            .. " bash " .. util.shell_escape(PROXY_SH)
            .. " status --json 2>/dev/null")
        if out then
            local data = util.json_decode(out)
            if data then return data end
        end
    end

    -- Fallback: 通过系统状态检测
    local running = false
    local ipset_count = 0
    local route_table_id = nil

    -- 检查 ipset 是否存在
    local ipset_out = util.trim(util.exec(
        "ipset list mynet_proxy 2>/dev/null | grep 'Number of entries' | awk '{print $NF}'") or "")
    if ipset_out ~= "" then
        ipset_count = tonumber(ipset_out) or 0
        running = ipset_count > 0
    end

    -- 检测 nftables set
    if not running then
        local nft_out = util.trim(util.exec(
            "nft list set inet mynet_proxy mynet_proxy 2>/dev/null | grep 'elements' | wc -l") or "")
        if tonumber(nft_out) and tonumber(nft_out) > 0 then
            running = true
        end
    end

    -- 获取路由表 ID
    local rt_out = util.trim(util.exec(
        "grep -E '^[[:space:]]*[0-9]+[[:space:]]+mynet_proxy' /etc/iproute2/rt_tables 2>/dev/null | awk '{print $1}'") or "")
    if rt_out ~= "" then route_table_id = tonumber(rt_out) end

    -- 获取配置
    local cfg = M.load_config()

    -- 检查 ip rule 是否有 fwmark 规则
    local has_rule = false
    if route_table_id then
        local rule_out = util.trim(util.exec(
            "ip rule list 2>/dev/null | grep 'lookup mynet_proxy'") or "")
        has_rule = rule_out ~= ""
    end

    -- 计算 uptime（从 state file）
    local uptime_sec = 0
    local state_data = util.load_json_file(PROXY_STATE_FILE)
    if state_data and state_data.start_ts then
        uptime_sec = os.time() - (state_data.start_ts or os.time())
        if uptime_sec < 0 then uptime_sec = 0 end
    end

    -- peer 数量
    local peer_count = 0
    if cfg.proxy_peers ~= "" then
        for _ in cfg.proxy_peers:gmatch("[^,]+") do
            peer_count = peer_count + 1
        end
    end

    return {
        running         = running,
        mode            = cfg.proxy_mode,
        region          = cfg.node_region,
        dns_mode        = cfg.dns_mode,
        layers          = {
            route_inject    = false,  -- set by start/stop
            policy_routing  = running,
            dns_intercept   = cfg.dns_mode ~= "none" and running,
        },
        stats           = {
            ipset_count     = ipset_count,
            route_table_id  = route_table_id,
            peer_count      = peer_count,
            uptime_seconds  = uptime_sec,
            has_rule        = has_rule,
        },
    }
end

-- ─────────────────────────────────────────────────────────────
-- 启动 proxy（含原子回滚）
-- ─────────────────────────────────────────────────────────────

function M.start(opts)
    opts = opts or {}
    local mode      = opts.mode     or "client"
    local region    = opts.region   or "domestic"
    local dns_mode  = opts.dns_mode or "none"

    -- 校验参数
    local valid_modes   = { client = true, server = true }
    local valid_regions = { domestic = true, international = true }
    local valid_dns     = { none = true, redirect = true, resolv = true }
    if not valid_modes[mode]     then return nil, "invalid mode: " .. mode end
    if not valid_regions[region] then return nil, "invalid region: " .. region end
    if not valid_dns[dns_mode]   then return nil, "invalid dns_mode: " .. dns_mode end

    -- 保存配置
    M.save_config({
        proxy_enabled = true,
        proxy_mode    = mode,
        node_region   = region,
        dns_mode      = dns_mode,
        dns_server    = opts.dns_server or "",
        proxy_peers   = opts.proxy_peers or "",
    })

    -- 启动 proxy.sh
    if not util.file_exists(PROXY_SH) then
        return nil, "proxy.sh not found: " .. PROXY_SH
    end

    -- Route inject (Lua): 在 proxy.sh 之前注入
    local inj_ok, inj_msg = M.route_inject()
    if not inj_ok then
        util.log_warn("route_inject skipped: " .. (inj_msg or ""))
    end

    local out, code = util.exec_status(
        "MYNET_HOME=" .. util.shell_escape(util.MYNET_HOME)
        .. " bash " .. util.shell_escape(PROXY_SH) .. " start 2>&1")

    if code ~= 0 then
        return nil, "proxy start failed: " .. util.trim(out or "")
    end

    -- 记录启动时间
    util.ensure_dir(util.MYNET_HOME .. "/var")
    util.save_json_file(PROXY_STATE_FILE, {
        start_ts  = os.time(),
        mode      = mode,
        region    = region,
        dns_mode  = dns_mode,
    })

    return true, util.trim(out or "started")
end

-- ─────────────────────────────────────────────────────────────
-- 停止 proxy
-- ─────────────────────────────────────────────────────────────

function M.stop()
    if not util.file_exists(PROXY_SH) then
        return nil, "proxy.sh not found"
    end
    local out, code = util.exec_status(
        "MYNET_HOME=" .. util.shell_escape(util.MYNET_HOME)
        .. " bash " .. util.shell_escape(PROXY_SH) .. " stop 2>&1")

    -- Route restore (Lua): 在 proxy.sh 之后恢复
    M.route_restore()

    -- 清除状态
    os.remove(PROXY_STATE_FILE)
    if code ~= 0 then
        return nil, "proxy stop: " .. util.trim(out or "")
    end
    return true, util.trim(out or "stopped")
end

-- ─────────────────────────────────────────────────────────────
-- 重载 IP 列表
-- ─────────────────────────────────────────────────────────────

function M.reload()
    if not util.file_exists(PROXY_SH) then
        return nil, "proxy.sh not found"
    end
    local out, code = util.exec_status(
        "MYNET_HOME=" .. util.shell_escape(util.MYNET_HOME)
        .. " bash " .. util.shell_escape(PROXY_SH) .. " refresh 2>&1")
    if code ~= 0 then
        return nil, "proxy reload: " .. util.trim(out or "")
    end
    return true, util.trim(out or "reloaded")
end

-- ─────────────────────────────────────────────────────────────
-- 诊断指定 IP 的路由路径
-- ─────────────────────────────────────────────────────────────

function M.diagnose_ip(ip)
    if not ip or not ip:match("^%d+%.%d+%.%d+%.%d+$") then
        return nil, "invalid IPv4 address"
    end

    local result = { ip = ip, checks = {} }

    -- 1. ip route get
    local route_out = util.trim(util.exec(
        "ip route get " .. util.shell_escape(ip) .. " 2>/dev/null") or "")
    result.checks[#result.checks + 1] = {
        name = "ip_route_get",
        output = route_out,
    }

    -- 2. ipset test
    local ipset_out, ipset_code = util.exec_status(
        "ipset test mynet_proxy " .. util.shell_escape(ip) .. " 2>&1")
    result.checks[#result.checks + 1] = {
        name    = "ipset_test",
        matched = ipset_code == 0,
        output  = util.trim(ipset_out or ""),
    }

    -- 3. nftables lookup
    local nft_out = util.trim(util.exec(
        "nft get element inet mynet_proxy mynet_proxy '{ "
        .. ip .. " }' 2>/dev/null") or "")
    result.checks[#result.checks + 1] = {
        name    = "nft_lookup",
        matched = nft_out ~= "",
        output  = nft_out,
    }

    -- 4. traceroute (quick, 3 hops max)
    local trace = util.trim(util.exec(
        "traceroute -n -m 3 -w 1 " .. util.shell_escape(ip) .. " 2>/dev/null") or "")
    result.checks[#result.checks + 1] = {
        name   = "traceroute",
        output = trace,
    }

    return result, nil
end

-- ─────────────────────────────────────────────────────────────
-- Route Inject（原 route_inject.sh 迁移为 Lua）
-- 向 GNB route.conf 自动注入 proxy peer 的 /8 路由块
-- ─────────────────────────────────────────────────────────────

local INJECT_MARKER_BEGIN = "# === MyNet Proxy Routes (auto-injected) ==="
local INJECT_MARKER_END   = "# === End Proxy Routes ==="

-- 保留的 /8 段不注入（10, 127, 172, 192, 224-255）
local function is_reserved_block(first_octet)
    if first_octet == 0 or first_octet == 10 or first_octet == 127 then return true end
    if first_octet == 172 or first_octet == 192 then return true end
    if first_octet >= 224 then return true end
    return false
end

-- 获取 route.conf 路径
local function get_route_conf_path()
    local cfg_m = require("luci.model.mynet.config")
    local node_id = cfg_m.get_node_id()
    if not node_id then return nil, "node_id not configured" end
    local nid_str = util.int_str(node_id)
    local conf_root = cfg_m.get_gnb_conf_root()
    return conf_root .. "/" .. nid_str .. "/route.conf", nid_str
end

-- 解析 route.conf 中已有的 /8 段
local function parse_existing_blocks(content)
    local existing = {}
    for line in content:gmatch("[^\n]+") do
        local octet = line:match("^(%d+)%.0%.0%.0/8")
        if octet then existing[tonumber(octet)] = true end
    end
    return existing
end

-- 注入 proxy 路由
function M.route_inject()
    local route_conf, nid_str = get_route_conf_path()
    if not route_conf then return nil, nid_str end

    if not util.file_exists(route_conf) then
        return nil, "route.conf not found: " .. route_conf
    end

    local cfg = M.load_config()
    local proxy_peers = cfg.proxy_peers or ""
    if proxy_peers == "" then
        return nil, "no proxy peers configured"
    end

    -- 备份
    local backup_path = route_conf .. ".proxy_bak"
    local orig = util.read_file(route_conf) or ""
    util.write_file(backup_path, orig)

    -- 解析已存在的 /8 块
    local existing = parse_existing_blocks(orig)

    -- 生成新路由
    local lines = { "" }
    lines[#lines + 1] = INJECT_MARKER_BEGIN
    lines[#lines + 1] = "# Injected at: " .. os.date("%Y-%m-%d %H:%M:%S")

    local total = 0
    for peer_nid in proxy_peers:gmatch("[^,]+") do
        peer_nid = util.trim(peer_nid)
        if peer_nid ~= "" then
            lines[#lines + 1] = "# Peer: " .. peer_nid
            for octet = 1, 223 do
                if not is_reserved_block(octet) and not existing[octet] then
                    lines[#lines + 1] = string.format("%d.0.0.0/8 via %s", octet, peer_nid)
                    total = total + 1
                end
            end
        end
    end
    lines[#lines + 1] = INJECT_MARKER_END

    -- 追加到 route.conf
    util.write_file(route_conf, orig .. table.concat(lines, "\n") .. "\n")

    util.log_info("route_inject: injected " .. total .. " routes for node " .. nid_str)
    return { injected = total, backup = backup_path }
end

-- 恢复 route.conf
function M.route_restore()
    local route_conf = get_route_conf_path()
    if not route_conf then return nil, "node_id not configured" end

    local backup_path = route_conf .. ".proxy_bak"
    if util.file_exists(backup_path) then
        local backup = util.read_file(backup_path)
        util.write_file(route_conf, backup)
        os.remove(backup_path)
        util.log_info("route_inject: restored route.conf from backup")
        return true, "restored from backup"
    end

    -- 无备份：删除注入段
    local content = util.read_file(route_conf) or ""
    if content:find(INJECT_MARKER_BEGIN, 1, true) then
        local before = content:match("^(.-)\n?" .. INJECT_MARKER_BEGIN:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
        local after  = content:match(INJECT_MARKER_END:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. "\n?(.*)")
        util.write_file(route_conf, (before or "") .. (after or ""))
        util.log_info("route_inject: removed injected routes (no backup)")
        return true, "removed injected section"
    end

    return true, "nothing to restore"
end

-- 注入状态查询
function M.route_inject_status()
    local route_conf = get_route_conf_path()
    if not route_conf then return { injected = false, error = "node_id not configured" } end
    if not util.file_exists(route_conf) then
        return { injected = false, error = "route.conf not found" }
    end

    local content = util.read_file(route_conf) or ""
    local backup_path = route_conf .. ".proxy_bak"
    local has_marker = content:find(INJECT_MARKER_BEGIN, 1, true) ~= nil
    local count = 0
    if has_marker then
        local section = content:match(INJECT_MARKER_BEGIN .. "(.-)" .. INJECT_MARKER_END:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
        if section then
            for _ in section:gmatch("%d+%.0%.0%.0/8") do count = count + 1 end
        end
    end

    return {
        injected    = has_marker,
        route_count = count,
        has_backup  = util.file_exists(backup_path),
    }
end

return M
