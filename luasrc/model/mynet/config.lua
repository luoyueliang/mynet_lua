-- mynet/config.lua  — 配置文件管理
-- 读写 config.json（API地址）、zone.json（当前区域）、mynet.conf（VPN参数）。
-- 对应 Go 项目 internal/common/ 中的路径管理与 config 相关 infrastructure。

local M    = {}
local util = require("luci.model.mynet.util")

M.DEFAULT_API_URL         = "https://api.mynet.club/api/v2"
M.DEFAULT_CTL_URL         = "https://ctl.mynet.club"
M.DEFAULT_WWW_URL         = "https://www.mynet.club"
M.DEFAULT_GNB_ROOT        = util.GNB_DRIVER_ROOT
M.DEFAULT_GNB_BIN_PATH    = util.GNB_BIN_DIR .. "/gnb"
M.DEFAULT_SYSTEM_GNB_PATH = "/usr/sbin/gnb"
M.DEFAULT_MYNETD_BIN      = "/usr/bin/mynetd"
M.MYNETD_JSON             = util.CONF_DIR .. "/mynetd.json"

-- ─────────────────────────────────────────────────────────────
-- Server Config (config.json)
-- ─────────────────────────────────────────────────────────────

-- 加载服务端配置
-- 返回: { api_base_url, timeout, retry_count }
function M.load_server_config()
    local data = util.load_json_file(util.CONFIG_FILE)
    local sc   = data and data.server_config or {}
    return {
        api_base_url = sc.api_base_url or M.DEFAULT_API_URL,
        timeout      = sc.timeout      or 30,
        retry_count  = sc.retry_count  or 3,
    }
end

-- 保存服务端配置（仅更新 server_config 字段，保留其他配置不变）
function M.save_server_config(api_url, timeout, retry_count)
    local data = util.load_json_file(util.CONFIG_FILE) or {}
    data.server_config = {
        api_base_url = api_url      or M.DEFAULT_API_URL,
        timeout      = timeout      or 30,
        retry_count  = retry_count  or 3,
    }
    return util.save_json_file(util.CONFIG_FILE, data)
end

-- 快捷：获取 API base URL
function M.get_api_url()
    return M.load_server_config().api_base_url
end

-- ─────────────────────────────────────────────────────────────
-- GNB Config (config.json → gnb 字段)
-- 管理 gnb 二进制路径与配置根目录
-- ─────────────────────────────────────────────────────────────

-- 加载 gnb 配置
-- 返回: { gnb_root, gnb_bin_path, system_gnb_path, use_system_gnb }
function M.load_gnb_config()
    local data = util.load_json_file(util.CONFIG_FILE)
    local g    = data and data.gnb or {}
    return {
        gnb_root        = g.gnb_root        or M.DEFAULT_GNB_ROOT,
        gnb_bin_path    = g.gnb_bin_path    or M.DEFAULT_GNB_BIN_PATH,
        system_gnb_path = g.system_gnb_path or M.DEFAULT_SYSTEM_GNB_PATH,
        use_system_gnb  = g.use_system_gnb  or false,
    }
end

-- 保存 gnb 配置（仅更新 gnb 字段，保留其他配置不变）
function M.save_gnb_config(gnb_root, gnb_bin_path, system_gnb_path, use_system_gnb)
    local data = util.load_json_file(util.CONFIG_FILE) or {}
    data.gnb = {
        gnb_root        = gnb_root        or M.DEFAULT_GNB_ROOT,
        gnb_bin_path    = gnb_bin_path    or M.DEFAULT_GNB_BIN_PATH,
        system_gnb_path = system_gnb_path or M.DEFAULT_SYSTEM_GNB_PATH,
        use_system_gnb  = use_system_gnb  or false,
    }
    return util.save_json_file(util.CONFIG_FILE, data)
end

-- 获取当前有效的 gnb 可执行文件路径
-- use_system_gnb=true → system_gnb_path；否则 → gnb_bin_path
function M.get_gnb_bin()
    local gc = M.load_gnb_config()
    if gc.use_system_gnb then
        return gc.system_gnb_path
    end
    return gc.gnb_bin_path
end

-- 获取 gnb 节点配置根目录（即 gnb_root/conf）
function M.get_gnb_conf_root()
    return M.load_gnb_config().gnb_root .. "/conf"
end

-- ─────────────────────────────────────────────────────────────
-- Zone Config (zone.json)
-- ─────────────────────────────────────────────────────────────

-- 加载当前区域
-- 返回: { zone_id, zone_name } 或 nil
function M.load_current_zone()
    local d = util.load_json_file(util.ZONE_FILE)
    if not d then return nil end
    d.zone_id = util.int_str(d.zone_id or 0)
    return d
end

-- 保存当前区域选择
function M.save_current_zone(zone_id, zone_name)
    return util.save_json_file(util.ZONE_FILE, {
        zone_id    = util.int_str(zone_id or 0),
        zone_name  = zone_name  or "",
        updated_at = util.format_time(util.time_now()),
    })
end

-- ─────────────────────────────────────────────────────────────
-- VPN Runtime Config (mynet.conf)
-- bash-style KEY="VALUE" 格式
-- ─────────────────────────────────────────────────────────────

-- 加载 mynet.conf → { KEY = value, ... }
function M.load_vpn_conf()
    local content = util.read_file(util.VPN_CONF)
    if not content then return {} end
    local result = {}
    for line in content:gmatch("[^\n]+") do
        line = util.trim(line)
        if line ~= "" and not line:match("^#") then
            -- 匹配 KEY="value" 或 KEY=value
            local k, v = line:match('^([%w_]+)%s*=%s*"?(.-)"?%s*$')
            if k then result[k] = v end
        end
    end
    return result
end

-- 快捷：VPN 类型（gnb 或 wireguard）
function M.get_vpn_type()
    return M.load_vpn_conf().VPN_TYPE or "gnb"
end

-- 快捷：VPN 网络接口名
function M.get_vpn_interface()
    return M.load_vpn_conf().VPN_INTERFACE or "gnb_tun"
end

-- 快捷：mynet.conf 中配置的 NODE_ID（int64 或 nil）
function M.get_node_id()
    local v = M.load_vpn_conf().NODE_ID
    if not v or v == "" then return nil end
    return tonumber(v)
end

-- 写入 mynet.conf 中的 NODE_ID（保留其余行不变）
function M.save_node_id(node_id)
    local id_str = util.int_str(node_id or 0)
    local content = util.read_file(util.VPN_CONF) or ""
    local found = false
    local lines = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^NODE_ID=") then
            lines[#lines+1] = 'NODE_ID="' .. id_str .. '"'
            found = true
        elseif line ~= "" or found then
            lines[#lines+1] = line
        end
    end
    if not found then
        lines[#lines+1] = 'NODE_ID="' .. id_str .. '"'
    end
    util.ensure_dir(util.CONF_DIR)
    return util.write_file(util.VPN_CONF, table.concat(lines, "\n") .. "\n")
end

-- ─────────────────────────────────────────────────────────────
-- Monitor Config (config.json → monitor 字段 + mynetd.json)
-- 管理 mynetd 守护进程的运行参数
-- ─────────────────────────────────────────────────────────────

-- 加载 mynetd 监控配置
-- 返回: { mynetd_bin_path, heartbeat_interval, log_level, auto_refresh_nodes, daemon_mode }
function M.load_monitor_config()
    local data = util.load_json_file(util.CONFIG_FILE)
    local m    = data and data.monitor or {}
    return {
        mynetd_bin_path    = m.mynetd_bin_path    or M.DEFAULT_MYNETD_BIN,
        heartbeat_interval = m.heartbeat_interval or 300,
        log_level          = m.log_level          or "info",
        auto_refresh_nodes = m.auto_refresh_nodes == true,
        daemon_mode        = m.daemon_mode ~= false,
    }
end

-- 保存 mynetd 监控配置
-- 同时更新 config.json monitor 字段和 mynetd.json（供 mynetd 二进制读取）
function M.save_monitor_config(mynetd_bin_path, heartbeat_interval, log_level, auto_refresh_nodes, daemon_mode)
    local data = util.load_json_file(util.CONFIG_FILE) or {}
    local interval = tonumber(heartbeat_interval) or 300
    if interval < 10  then interval = 10  end
    if interval > 3600 then interval = 3600 end
    data.monitor = {
        mynetd_bin_path    = mynetd_bin_path or M.DEFAULT_MYNETD_BIN,
        heartbeat_interval = interval,
        log_level          = log_level or "info",
        auto_refresh_nodes = auto_refresh_nodes == true,
        daemon_mode        = daemon_mode ~= false,
    }
    -- 同步写入 mynetd.json，供 mynetd 二进制直接读取
    local mynetd_cfg = {
        mynet_conf_path    = util.CONF_DIR .. "/mynet.conf",
        log_dir            = util.MYNET_HOME .. "/var/logs",
        pid_file           = "/var/run/mynetd.pid",
        heartbeat_interval = interval,
        log_level          = log_level or "info",
        daemon_mode        = daemon_mode ~= false,
        auto_refresh_nodes = auto_refresh_nodes == true,
    }
    util.save_json_file(M.MYNETD_JSON, mynetd_cfg)
    return util.save_json_file(util.CONFIG_FILE, data)
end

-- 获取当前有效的 mynetd 可执行文件路径
function M.get_mynetd_bin()
    return M.load_monitor_config().mynetd_bin_path
end

return M
