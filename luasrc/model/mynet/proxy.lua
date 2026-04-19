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

-- 参数校验常量（controller/model 共用，避免重复定义）
local VALID_MODES   = { client = true, server = true, both = true }
local VALID_REGIONS = { domestic = true, international = true }
local VALID_DNS     = { none = true, redirect = true, resolv = true }

-- ─────────────────────────────────────────────────────────────
-- 配置读写
-- ─────────────────────────────────────────────────────────────

-- 校验 proxy 参数（mode/region/dns_mode）
function M.validate_params(opts)
    if opts.mode and not VALID_MODES[opts.mode] then
        return nil, "invalid mode: " .. tostring(opts.mode)
    end
    if opts.region and not VALID_REGIONS[opts.region] then
        return nil, "invalid region: " .. tostring(opts.region)
    end
    if opts.dns_mode and not VALID_DNS[opts.dns_mode] then
        return nil, "invalid dns_mode: " .. tostring(opts.dns_mode)
    end
    return true
end

-- 读取 proxy_role.conf (bash KEY=VALUE 格式)
function M.load_config()
    local defaults = {
        proxy_enabled = false,
        proxy_mode    = "client",
        node_region   = "domestic",
        dns_mode      = "none",
        dns_server    = "",
        proxy_peers   = "",
    }
    local result = util.parse_bash_conf(PROXY_ROLE_CONF, { lower_keys = true })
    if not result then return defaults end
    return {
        proxy_enabled = (result.proxy_enabled == "1" or result.proxy_enabled == "true"),
        proxy_mode    = result.proxy_mode  or "client",
        node_region   = result.node_region or "domestic",
        dns_mode      = result.dns_mode    or "none",
        dns_server    = result.dns_server  or "",
        proxy_peers   = result.proxy_peers or "",
    }
end

-- 合并更新配置（load → merge → save，避免调用方重复 load+save）
function M.update_config(partial)
    local cfg = M.load_config()
    for k, v in pairs(partial) do cfg[k] = v end
    return M.save_config(cfg)
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
            "nft list set inet mynet_proxy mynet_proxy 2>/dev/null | tr ',' '\n' | grep -c '[0-9]'") or "")
        local nft_cnt = tonumber(nft_out) or 0
        if nft_cnt > 0 then
            ipset_count = nft_cnt
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

    -- proxy_route.conf 中的 CIDR 条目数（已配置的规则数）
    local route_conf_count = 0
    local route_conf_path = PROXY_CONF_DIR .. "/proxy_route.conf"
    if util.file_exists(route_conf_path) then
        local cnt_out = util.trim(util.exec(
            "grep -cv '^#\\|^$' " .. util.shell_escape(route_conf_path) .. " 2>/dev/null") or "")
        route_conf_count = tonumber(cnt_out) or 0
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
            ipset_count      = ipset_count,
            route_conf_count = route_conf_count,
            route_table_id   = route_table_id,
            peer_count       = peer_count,
            uptime_seconds   = uptime_sec,
            has_rule         = has_rule,
        },
    }
end

-- ─────────────────────────────────────────────────────────────
-- Enable/Disable（自启开关，与 start/stop 分离）
-- enable  = PROXY_ENABLED=1 + 若 GNB 已运行则立即 start
-- disable = PROXY_ENABLED=0 + 若 proxy 运行中则立即 stop + route_restore
-- ─────────────────────────────────────────────────────────────

function M.enable(opts)
    opts = opts or {}
    local fields = { proxy_enabled = true }
    if opts.mode        then fields.proxy_mode  = opts.mode end
    if opts.region      then fields.node_region  = opts.region end
    if opts.dns_mode    then fields.dns_mode     = opts.dns_mode end
    if opts.dns_server  then fields.dns_server   = opts.dns_server end
    if opts.proxy_peers then fields.proxy_peers  = opts.proxy_peers end
    M.update_config(fields)

    -- 安装 plugin hook symlink / 部署
    M.install_plugin_hooks()

    -- 若 GNB 已运行，立即启动 proxy
    local cfg_m = require("luci.model.mynet.config")
    local node_id = cfg_m.get_node_id()
    local node_m = require("luci.model.mynet.node")
    if node_id and node_m.gnb_is_running(node_id) then
        local ok, msg = M.start(opts)
        if not ok then
            return nil, "enabled but start failed: " .. (msg or "")
        end
        return true, "enabled and started"
    end

    return true, "enabled (GNB not running, will auto-start with GNB)"
end

function M.disable()
    -- 若 proxy 运行中，先停止
    local st = M.get_status()
    if st and st.running then
        M.stop()
    end

    -- 删除 GNB route.conf 中的注入段
    M.route_restore()

    -- 设 PROXY_ENABLED=0
    M.update_config({ proxy_enabled = false })

    -- 移除 plugin hooks
    M.remove_plugin_hooks()

    return true, "disabled"
end

-- ─────────────────────────────────────────────────────────────
-- Plugin hook 管理
-- ─────────────────────────────────────────────────────────────

local PLUGIN_PROXY_DIR = util.MYNET_HOME .. "/scripts/plugin/proxy"

function M.install_plugin_hooks()
    util.ensure_dir(PLUGIN_PROXY_DIR)
    local hooks_src = PROXY_SCRIPT_DIR .. "/hooks"
    for _, hook in ipairs({ "pre_start.sh", "post_start.sh", "stop.sh" }) do
        local src = hooks_src .. "/" .. hook
        local dst = PLUGIN_PROXY_DIR .. "/" .. hook
        if util.file_exists(src) then
            util.exec("cp -f " .. util.shell_escape(src) .. " " .. util.shell_escape(dst)
                .. " && chmod +x " .. util.shell_escape(dst))
        end
    end
end

function M.remove_plugin_hooks()
    if util.file_exists(PLUGIN_PROXY_DIR) then
        util.exec("rm -rf " .. util.shell_escape(PLUGIN_PROXY_DIR))
    end
end

-- ─────────────────────────────────────────────────────────────
-- 启动 proxy（即时控制，不改 PROXY_ENABLED）
-- ─────────────────────────────────────────────────────────────

function M.start(opts)
    opts = opts or {}
    local mode      = opts.mode     or "client"
    local region    = opts.region   or "domestic"
    local dns_mode  = opts.dns_mode or "none"

    -- 前置检查：GNB 必须已运行
    local cfg_m = require("luci.model.mynet.config")
    local node_id = cfg_m.get_node_id()
    if not node_id then
        return nil, "node_id not configured"
    end
    local node_m = require("luci.model.mynet.node")
    if not node_m.gnb_is_running(node_id) then
        return nil, "GNB is not running — start GNB first"
    end

    -- 校验参数（使用模块级常量）
    local ok, err = M.validate_params({ mode = mode, region = region, dns_mode = dns_mode })
    if not ok then return nil, err end

    -- 保存运行参数（不改 proxy_enabled）
    local fields = { proxy_mode = mode, node_region = region, dns_mode = dns_mode }
    if opts.dns_server  then fields.dns_server  = opts.dns_server end
    if opts.proxy_peers then fields.proxy_peers  = opts.proxy_peers end
    M.update_config(fields)

    -- 启动 proxy.sh
    if not util.file_exists(PROXY_SH) then
        return nil, "proxy.sh not found: " .. PROXY_SH
    end

    -- Route inject (Lua): 在 proxy.sh 之前注入 GNB 数据层路由
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

    -- 注册防火墙 include（防火墙重启后恢复策略路由）
    M.register_firewall_include()

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

    -- 清除状态 + 防火墙 include
    os.remove(PROXY_STATE_FILE)
    M.unregister_firewall_include()

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
-- 防火墙 include 注册/注销（防火墙重启后恢复策略路由）
-- ─────────────────────────────────────────────────────────────

local FW_INCLUDE_SCRIPT = util.SCRIPTS_DIR .. "/proxy.firewall.include"
local FW_INCLUDE_NAME   = "mynet_proxy"

function M.register_firewall_include()
    -- 生成 include 脚本：检查 proxy_state.json 存在 → 幂等启动 route_policy.sh
    local script = table.concat({
        "#!/bin/sh",
        "# Auto-generated by mynet proxy — do not edit",
        'STATE="' .. PROXY_STATE_FILE .. '"',
        'ROUTE_POLICY="' .. ROUTE_POLICY_SH .. '"',
        '[ -f "$STATE" ] || exit 0',
        '[ -f "$ROUTE_POLICY" ] || exit 0',
        'MYNET_HOME="' .. util.MYNET_HOME .. '" bash "$ROUTE_POLICY" start 2>/dev/null || true',
    }, "\n") .. "\n"
    util.write_file(FW_INCLUDE_SCRIPT, script)
    util.exec("chmod +x " .. util.shell_escape(FW_INCLUDE_SCRIPT))

    -- 注册 UCI firewall include
    util.exec(string.format(
        "uci -q delete firewall.%s 2>/dev/null; "
        .. "uci set firewall.%s=include; "
        .. "uci set firewall.%s.path='%s'; "
        .. "uci set firewall.%s.reload='1'; "
        .. "uci commit firewall 2>/dev/null",
        FW_INCLUDE_NAME, FW_INCLUDE_NAME, FW_INCLUDE_NAME,
        FW_INCLUDE_SCRIPT, FW_INCLUDE_NAME))
end

function M.unregister_firewall_include()
    util.exec("uci -q delete firewall." .. FW_INCLUDE_NAME .. " 2>/dev/null; uci commit firewall 2>/dev/null")
    os.remove(FW_INCLUDE_SCRIPT)
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
-- Route Inject — 向 GNB route.conf 注入 proxy peer 的 /8 路由
-- GNB daemon 需要 route.conf 声明才会转发对应网段的流量（数据层放行）
-- 注入使用 GNB pipe 格式: peer_nid|network|netmask
-- OS 层路由由 route_policy.sh 独立路由表 + fwmark 处理，此处不触发 generate_network_conf
-- ─────────────────────────────────────────────────────────────

-- Marker（与 scripts/proxy/hooks/stop.sh 统一）
M.INJECT_MARKER_BEGIN = "#----proxy start----"
M.INJECT_MARKER_END   = "#----proxy end----"

-- 保留的 /8 段不注入（0, 10, 127, 172, 192, 224-255）
local function is_reserved_block(first_octet)
    if first_octet == 0 or first_octet == 10 or first_octet == 127 then return true end
    if first_octet == 172 or first_octet == 192 then return true end
    if first_octet >= 224 then return true end
    return false
end

-- 获取 GNB route.conf 路径（driver/gnb/conf/{nid}/route.conf）
local function get_route_conf_path()
    local cfg_m = require("luci.model.mynet.config")
    local node_id = cfg_m.get_node_id()
    if not node_id then return nil, "node_id not configured" end
    local nid_str = util.int_str(node_id)
    local conf_root = cfg_m.get_gnb_conf_root()
    return conf_root .. "/" .. nid_str .. "/route.conf", nid_str
end

-- 从文件内容中移除 marker 段（含 marker 行本身）
local function strip_marker_section(content)
    if not content or not content:find(M.INJECT_MARKER_BEGIN, 1, true) then
        return content
    end
    local result = {}
    local skipping = false
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        if line:find(M.INJECT_MARKER_BEGIN, 1, true) then
            skipping = true
        elseif line:find(M.INJECT_MARKER_END, 1, true) then
            skipping = false
        elseif not skipping then
            result[#result + 1] = line
        end
    end
    -- 移除末尾多余空行
    while #result > 0 and result[#result] == "" do
        result[#result] = nil
    end
    return table.concat(result, "\n") .. "\n"
end

-- 注入 proxy 路由到 GNB route.conf（幂等：先清旧段再追加）
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

    -- 读取并清除旧注入段
    local orig = util.read_file(route_conf) or ""
    local clean = strip_marker_section(orig)

    -- 生成新路由（GNB pipe 格式: peer_nid|network|netmask）
    local lines = {}
    lines[#lines + 1] = M.INJECT_MARKER_BEGIN
    lines[#lines + 1] = "# Injected at: " .. os.date("%Y-%m-%d %H:%M:%S")

    local total = 0
    for peer_nid in proxy_peers:gmatch("[^,]+") do
        peer_nid = util.trim(peer_nid)
        if peer_nid ~= "" then
            lines[#lines + 1] = "# Peer: " .. peer_nid
            for octet = 1, 223 do
                if not is_reserved_block(octet) then
                    lines[#lines + 1] = string.format(
                        "%s|%d.0.0.0|255.0.0.0", peer_nid, octet)
                    total = total + 1
                end
            end
        end
    end
    lines[#lines + 1] = M.INJECT_MARKER_END

    -- 追加到 route.conf（不触发 generate_network_conf）
    util.write_file(route_conf, clean .. table.concat(lines, "\n") .. "\n")

    util.log_info("route_inject: injected " .. total .. " pipe routes for node " .. nid_str)
    return { injected = total }
end

-- 从 GNB route.conf 移除 proxy 注入段
function M.route_restore()
    local route_conf = get_route_conf_path()
    if not route_conf then return nil, "node_id not configured" end

    local content = util.read_file(route_conf) or ""
    if not content:find(M.INJECT_MARKER_BEGIN, 1, true) then
        return true, "nothing to restore"
    end

    local clean = strip_marker_section(content)
    util.write_file(route_conf, clean)
    util.log_info("route_restore: removed proxy marker section")
    return true, "removed injected section"
end

-- 注入状态查询
function M.route_inject_status()
    local route_conf = get_route_conf_path()
    if not route_conf then return { injected = false, error = "node_id not configured" } end
    if not util.file_exists(route_conf) then
        return { injected = false, error = "route.conf not found" }
    end

    local content = util.read_file(route_conf) or ""
    local has_marker = content:find(M.INJECT_MARKER_BEGIN, 1, true) ~= nil
    local count = 0
    if has_marker then
        for line in content:gmatch("[^\n]+") do
            if line:match("^%d+|%d+%.0%.0%.0|255%.0%.0%.0$") then
                count = count + 1
            end
        end
    end

    return {
        injected    = has_marker,
        route_count = count,
    }
end

-- ─────────────────────────────────────────────────────────────
-- 网络检测（从 controller 移入 model，统一业务逻辑层）
-- ─────────────────────────────────────────────────────────────

function M.net_detect(dtype)
    local cmd
    if dtype == "domestic" then
        cmd = "curl -s --connect-timeout 5 --max-time 10 'https://myip.ipip.net' 2>/dev/null"
            .. " || curl -s --connect-timeout 5 --max-time 10 'https://ip.cn/api/index?type=0' 2>/dev/null"
    elseif dtype == "proxy" then
        cmd = "curl -s --connect-timeout 8 --max-time 15 'https://api.ipify.org?format=json' 2>/dev/null"
            .. " || curl -s --connect-timeout 8 --max-time 15 'https://ifconfig.me/ip' 2>/dev/null"
    else
        return nil, "invalid type: " .. tostring(dtype)
    end
    local out = util.trim(util.exec(cmd) or "")
    if out ~= "" then
        return { ip = out:match("%d+%.%d+%.%d+%.%d+") or out, raw = out }
    end
    return nil, dtype .. " IP detection failed"
end

function M.net_check(host)
    if not host or host == "" or not host:match("^[%w%.%-]+$") then
        return nil, "invalid host"
    end
    local cmd = string.format(
        "curl -s -o /dev/null -w '%%{http_code} %%{time_total} %%{remote_ip}' "
        .. "--connect-timeout 8 --max-time 15 'https://%s/' 2>/dev/null",
        util.shell_escape(host):gsub("'", ""))
    local out = util.trim(util.exec(cmd) or "")
    local code, time_s, ip = out:match("^(%d+)%s+([%d%.]+)%s+([%d%.]+)")
    if code then
        return {
            host      = host,
            reachable = tonumber(code) > 0 and tonumber(code) < 500,
            http_code = tonumber(code),
            time_ms   = math.floor(tonumber(time_s) * 1000),
            ip        = ip,
        }
    end
    return {
        host      = host,
        reachable = false,
        error     = out ~= "" and out or "connection failed",
    }
end

return M
