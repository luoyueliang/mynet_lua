-- mynet/config.lua  — 配置文件管理
-- 读写 config.json（API地址）、zone.json（当前区域）、mynet.conf（VPN参数）。
-- 对应 Go 项目 internal/common/ 中的路径管理与 config 相关 infrastructure。

local M    = {}
local util = require("luci.model.mynet.util")

M.DEFAULT_API_URL = "http://localhost:8000/api/v1"

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

-- 保存服务端配置
function M.save_server_config(api_url, timeout, retry_count)
    return util.save_json_file(util.CONFIG_FILE, {
        server_config = {
            api_base_url = api_url      or M.DEFAULT_API_URL,
            timeout      = timeout      or 30,
            retry_count  = retry_count  or 3,
        }
    })
end

-- 快捷：获取 API base URL
function M.get_api_url()
    return M.load_server_config().api_base_url
end

-- ─────────────────────────────────────────────────────────────
-- Zone Config (zone.json)
-- ─────────────────────────────────────────────────────────────

-- 加载当前区域
-- 返回: { zone_id, zone_name } 或 nil
function M.load_current_zone()
    return util.load_json_file(util.ZONE_FILE)
end

-- 保存当前区域选择
function M.save_current_zone(zone_id, zone_name)
    return util.save_json_file(util.ZONE_FILE, {
        zone_id    = zone_id    or 0,
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

return M
