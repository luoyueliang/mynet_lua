-- mynet/zone.lua  — 区域管理模块
-- 获取用户区域列表、读写当前选中区域。
-- 对应 Go 项目 internal/application/zone_app_service.go

local M    = {}
local api  = require("luci.model.mynet.api")
local auth = require("luci.model.mynet.auth")
local cfg  = require("luci.model.mynet.config")
local util = require("luci.model.mynet.util")

-- ─────────────────────────────────────────────────────────────
-- 获取用户可访问的区域列表
-- 对应 Go: GET /user/zones
-- 返回: (zones_array, nil) 或 (nil, error_string)
-- ─────────────────────────────────────────────────────────────
function M.get_zones()
    local current, err = auth.ensure_valid()
    if err then return nil, err end

    local data, api_err = api.get_json(cfg.get_api_url(), "/user/zones", current.token)
    if api_err then return nil, api_err end
    if not data or not data.success then
        return nil, (data and data.message) or "failed to get zones"
    end

    return data.data or {}, nil
end

-- ─────────────────────────────────────────────────────────────
-- 获取当前选中区域（本地存储）
-- 返回: { zone_id, zone_name } 或 nil
-- ─────────────────────────────────────────────────────────────
function M.get_current_zone()
    return cfg.load_current_zone()
end

-- ─────────────────────────────────────────────────────────────
-- 设置当前区域
-- ─────────────────────────────────────────────────────────────
function M.set_current_zone(zone_id, zone_name)
    return cfg.save_current_zone(zone_id, zone_name)
end

-- ─────────────────────────────────────────────────────────────
-- 在区域列表中查找指定 zone_id 的区域对象
-- ─────────────────────────────────────────────────────────────
function M.find_zone(zones, zone_id)
    for _, z in ipairs(zones or {}) do
        local zid = z.zone_id or z.id
        if util.int_str(zid) == util.int_str(zone_id) then
            return z
        end
    end
    return nil
end

return M
