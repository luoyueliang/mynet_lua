-- mynet/node.lua  — 节点管理模块
-- 节点列表、配置下载、状态上报、VPN 服务控制。
-- 对应 Go 项目 internal/application/node_app_service.go +
--              internal/application/status_app_service.go

local M    = {}
local api  = require("luci.model.mynet.api")
local auth = require("luci.model.mynet.auth")
local cfg  = require("luci.model.mynet.config")
local util = require("luci.model.mynet.util")

-- ─────────────────────────────────────────────────────────────
-- 节点状态码（与 Go 项目保持一致）
-- ─────────────────────────────────────────────────────────────
M.STATUS = {
    OFFLINE     = 0,
    ONLINE      = 1,
    CONNECTING  = 2,
    STOPPED     = 3,
    RUNNING     = 4,
    ACTIVE      = 5,
    STARTING    = 6,
    STOPPING    = 7,
    MAINTENANCE = 8,
}

M.STATUS_NAMES = {
    [0] = "offline",
    [1] = "online",
    [2] = "connecting",
    [3] = "stopped",
    [4] = "running",
    [5] = "active",
    [6] = "starting",
    [7] = "stopping",
    [8] = "maintenance",
}

-- ─────────────────────────────────────────────────────────────
-- 获取节点列表（分页）
-- 对应 Go: GET /nodes?page=N&per_page=N
-- 返回: (nodes_data_table, nil) 或 (nil, error_string)
-- nodes_data_table 含 .data (节点数组)、.total、.current_page、.last_page
-- ─────────────────────────────────────────────────────────────
function M.get_nodes(page, per_page)
    local current, err = auth.ensure_valid()
    if err then return nil, err end

    local zone = cfg.load_current_zone()
    if not zone or not zone.zone_id or zone.zone_id == 0 then
        return nil, "no zone selected"
    end

    local endpoint = string.format("/nodes?page=%d&per_page=%d",
        page or 1, per_page or 20)
    local data, api_err = api.get_json(cfg.get_api_url(), endpoint,
        current.token, zone.zone_id)
    if api_err then return nil, api_err end
    if not data or not data.success then
        return nil, (data and data.message) or "failed to get nodes"
    end

    -- 返回分页结构：{ data=[...], total, per_page, current_page, last_page }
    return (data.data and data.data.nodes) or {}, nil
end

-- ─────────────────────────────────────────────────────────────
-- 获取渲染后的节点配置文本（text/plain）
-- 对应 Go: GET /nodes/{id}/config?render_conf=1
-- 直接返回可写入 node.conf 的文本
-- ─────────────────────────────────────────────────────────────
function M.get_node_config_rendered(node_id)
    local current, err = auth.ensure_valid()
    if err then return nil, err end

    local zone    = cfg.load_current_zone()
    local zone_id = zone and zone.zone_id or 0
    local endpoint = string.format("/nodes/%s/config?render_conf=1", tostring(node_id))

    return api.get_text(cfg.get_api_url(), endpoint, current.token, zone_id)
end

-- ─────────────────────────────────────────────────────────────
-- 获取渲染后的路由配置文本（text/plain）
-- 对应 Go: GET /route/node/{id}?render_conf=1
-- ─────────────────────────────────────────────────────────────
function M.get_route_config_rendered(node_id)
    local current, err = auth.ensure_valid()
    if err then return nil, err end

    local zone    = cfg.load_current_zone()
    local zone_id = zone and zone.zone_id or 0
    local endpoint = string.format("/route/node/%s?render_conf=1", tostring(node_id))

    return api.get_text(cfg.get_api_url(), endpoint, current.token, zone_id)
end

-- ─────────────────────────────────────────────────────────────
-- 获取渲染后的服务地址索引（text/plain）
-- 对应 Go: GET /zones/services/indexes?render_conf=1
-- ─────────────────────────────────────────────────────────────
function M.get_services_index()
    local current, err = auth.ensure_valid()
    if err then return nil, err end

    local zone    = cfg.load_current_zone()
    local zone_id = zone and zone.zone_id or 0

    return api.get_text(cfg.get_api_url(),
        "/zones/services/indexes?render_conf=1", current.token, zone_id)
end

-- ─────────────────────────────────────────────────────────────
-- 更新节点状态（上报到服务端）
-- 对应 Go: PATCH /nodes/{id}/status
-- ─────────────────────────────────────────────────────────────
function M.update_node_status(node_id, status_code)
    local current, err = auth.ensure_valid()
    if err then return nil, err end

    local zone    = cfg.load_current_zone()
    local zone_id = zone and zone.zone_id or 0
    local endpoint = string.format("/nodes/%s/status", tostring(node_id))

    local data, api_err = api.patch_json(cfg.get_api_url(), endpoint,
        { status = status_code }, current.token, zone_id)
    if api_err then return nil, api_err end
    if not data or not data.success then
        return nil, (data and data.message) or "status update failed"
    end
    return true, nil
end

-- ─────────────────────────────────────────────────────────────
-- 刷新配置：下载并写入 node.conf、route.conf、address.conf
-- 对应 Go: cmd/refresh_config.go 的核心流程
-- 返回: { ok, files=[], errors=[] }
-- ─────────────────────────────────────────────────────────────
function M.refresh_configs(node_id)
    local results = { ok = true, files = {}, errors = {} }

    local vpn_type = cfg.get_vpn_type()

    -- 1. node.conf
    local node_conf_path = string.format("%s/driver/%s/conf/%s/node.conf",
        util.MYNET_HOME, vpn_type, tostring(node_id))
    local node_text, err1 = M.get_node_config_rendered(node_id)
    if err1 then
        results.ok = false
        results.errors[#results.errors+1] = "node.conf: " .. err1
    elseif node_text and node_text ~= "" then
        local ok, we = util.write_file(node_conf_path, node_text .. "\n")
        if ok then
            results.files[#results.files+1] = node_conf_path
        else
            results.ok = false
            results.errors[#results.errors+1] = "write node.conf: " .. (we or "")
        end
    end

    -- 2. route.conf
    local route_path = util.CONF_DIR .. "/route.conf"
    local route_text, err2 = M.get_route_config_rendered(node_id)
    if err2 then
        results.ok = false
        results.errors[#results.errors+1] = "route.conf: " .. err2
    elseif route_text and route_text ~= "" then
        local ok, we = util.write_file(route_path, route_text .. "\n")
        if ok then
            results.files[#results.files+1] = route_path
        else
            results.ok = false
            results.errors[#results.errors+1] = "write route.conf: " .. (we or "")
        end
    end

    -- 3. address.conf（非致命，部分区域无服务地址）
    local addr_path = util.CONF_DIR .. "/address.conf"
    local svc_text, err3 = M.get_services_index()
    if err3 then
        util.log_warn("refresh_configs: address.conf: " .. err3)
    elseif svc_text and svc_text ~= "" then
        local ok, we = util.write_file(addr_path, svc_text .. "\n")
        if ok then
            results.files[#results.files+1] = addr_path
        else
            util.log_warn("refresh_configs: write address.conf: " .. (we or ""))
        end
    end

    return results
end

-- ─────────────────────────────────────────────────────────────
-- VPN 服务控制（/etc/init.d/mynet）
-- ─────────────────────────────────────────────────────────────

function M.get_vpn_service_status()
    local out, code = util.exec_status("/etc/init.d/mynet status 2>/dev/null")
    if code == 0 then return "running" end
    if out and (out:lower():match("running") or out:lower():match("active")) then
        return "running"
    end
    return "stopped"
end

function M.start_vpn()
    local _, code = util.exec_status("/etc/init.d/mynet start")
    return code == 0, code
end

function M.stop_vpn()
    local _, code = util.exec_status("/etc/init.d/mynet stop")
    return code == 0, code
end

function M.restart_vpn()
    local _, code = util.exec_status("/etc/init.d/mynet restart")
    return code == 0, code
end

-- ─────────────────────────────────────────────────────────────
-- 获取 VPN 网络接口状态（ip link）
-- 返回: { interface, state, mtu, flags } 或 nil
-- ─────────────────────────────────────────────────────────────
function M.get_vpn_interface_status()
    local iface = cfg.get_vpn_interface()
    if not iface or iface == "" then return nil end

    local out = util.exec("ip link show " .. iface .. " 2>/dev/null")
    if not out or out == "" then return nil end

    return {
        interface = iface,
        state     = out:match("state%s+(%w+)") or "unknown",
        mtu       = tonumber(out:match("mtu%s+(%d+)")),
        flags     = out:match("<(.-)>"),
        rx_bytes  = nil,  -- 可通过 /sys/class/net/{iface}/statistics/ 获取
        tx_bytes  = nil,
    }
end

return M
