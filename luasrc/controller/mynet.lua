-- luci/controller/mynet.lua  — LuCI 路由与 Action 控制器
-- 注册所有 URL 入口，处理页面渲染和 AJAX 接口。
-- 对应 Go 项目 cmd/ 下各命令的 Web 版等价实现。

module("luci.controller.mynet", package.seeall)

local http   = require("luci.http")
local tmpl   = require("luci.template")
local disp   = require("luci.dispatcher")
local cred_m = require("luci.model.mynet.credential")
local auth_m = require("luci.model.mynet.auth")
local cfg_m  = require("luci.model.mynet.config")
local zone_m = require("luci.model.mynet.zone")
local node_m = require("luci.model.mynet.node")
local util   = require("luci.model.mynet.util")

-- ─────────────────────────────────────────────────────────────
-- 路由注册
-- ─────────────────────────────────────────────────────────────

function index()
    -- 顶级菜单项（管理 → MyNet VPN）
    entry({"admin", "mynet"},
        alias("admin", "mynet", "index"),
        _("MyNet VPN"), 60
    ).dependent = false

    -- 控制台
    entry({"admin", "mynet", "index"},
        call("action_index"),
        _("Dashboard"), 10
    ).dependent = false

    -- 认证
    entry({"admin", "mynet", "login"},
        call("action_login"),
        nil
    ).dependent = false

    entry({"admin", "mynet", "logout"},
        call("action_logout"),
        nil
    ).dependent = false

    -- 区域
    entry({"admin", "mynet", "zones"},
        call("action_zones"),
        _("Zones"), 20
    )
    entry({"admin", "mynet", "zones", "select"},
        call("action_zones_select"),
        nil
    )

    -- 节点
    entry({"admin", "mynet", "nodes"},
        call("action_nodes"),
        _("Nodes"), 30
    )
    entry({"admin", "mynet", "nodes", "detail"},
        call("action_node_detail"),
        nil
    )
    entry({"admin", "mynet", "nodes", "refresh_config"},
        call("action_node_refresh_config"),
        nil
    )

    -- 状态
    entry({"admin", "mynet", "status"},
        call("action_status"),
        _("Status"), 40
    )

    -- 设置
    entry({"admin", "mynet", "settings"},
        call("action_settings"),
        _("Settings"), 50
    )
    entry({"admin", "mynet", "settings", "save"},
        call("action_settings_save"),
        nil
    )

    -- AJAX / JSON API
    entry({"admin", "mynet", "api", "status"},      call("api_get_status")        ).dependent = false
    entry({"admin", "mynet", "api", "nodes"},        call("api_get_nodes")         ).dependent = false
    entry({"admin", "mynet", "api", "zones"},        call("api_get_zones")         ).dependent = false
    entry({"admin", "mynet", "api", "vpn_start"},    call("api_vpn_start")         ).dependent = false
    entry({"admin", "mynet", "api", "vpn_stop"},     call("api_vpn_stop")          ).dependent = false
    entry({"admin", "mynet", "api", "vpn_restart"},  call("api_vpn_restart")       ).dependent = false
    entry({"admin", "mynet", "api", "node_config"},  call("api_node_refresh_config")).dependent = false
end

-- ─────────────────────────────────────────────────────────────
-- 私有辅助函数
-- ─────────────────────────────────────────────────────────────

-- 确保已登录；未登录则重定向 login，返回 nil
local function require_auth()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then
        -- 尝试自动刷新
        local refreshed = auth_m.refresh_token()
        if refreshed then return refreshed end
        http.redirect(disp.build_url("admin/mynet/login"))
        return nil
    end
    return c
end

-- 输出 JSON 响应
local function json_ok(data)
    http.prepare_content("application/json")
    http.write(util.json_encode(data) or "{}")
end

local function json_err(msg, code)
    http.status(code or 400, "Error")
    http.prepare_content("application/json")
    http.write(util.json_encode({ success = false, message = msg }) or "{}")
end

-- 获取当前区域上下文（模板公共数据）
local function zone_ctx()
    return cfg_m.load_current_zone() or { zone_id = 0, zone_name = "" }
end

-- ─────────────────────────────────────────────────────────────
-- 页面 Actions
-- ─────────────────────────────────────────────────────────────

-- 控制台
function action_index()
    local c = require_auth()
    if not c then return end

    local zone       = zone_ctx()
    local vpn_status = node_m.get_vpn_service_status()
    local vpn_iface  = node_m.get_vpn_interface_status()
    local node_id    = cfg_m.get_node_id()

    tmpl.render("mynet/index", {
        user_email = c.user_email,
        zone       = zone,
        node_id    = node_id,
        vpn_status = vpn_status,
        vpn_iface  = vpn_iface,
        vpn_type   = cfg_m.get_vpn_type(),
    })
end

-- 登录页（GET 显示，POST 处理）
function action_login()
    -- 已登录则跳转控制台
    local c = cred_m.load()
    if c and cred_m.is_valid(c) and http.getenv("REQUEST_METHOD") ~= "POST" then
        http.redirect(disp.build_url("admin/mynet/index"))
        return
    end

    local err_msg  = nil
    local prefill  = ""

    if http.getenv("REQUEST_METHOD") == "POST" then
        local email    = util.trim(http.formvalue("email")    or "")
        local password = util.trim(http.formvalue("password") or "")
        prefill = email

        local new_cred, login_err = auth_m.login(email, password)
        if login_err then
            err_msg = login_err
        else
            http.redirect(disp.build_url("admin/mynet/index"))
            return
        end
    end

    tmpl.render("mynet/login", {
        error      = err_msg,
        prefill_email = prefill,
    })
end

-- 登出
function action_logout()
    auth_m.logout()
    http.redirect(disp.build_url("admin/mynet/login"))
end

-- 区域列表
function action_zones()
    local c = require_auth()
    if not c then return end

    local zones, err = zone_m.get_zones()
    tmpl.render("mynet/zones", {
        zones      = zones or {},
        error      = err,
        cur_zone   = zone_ctx(),
        user_email = c.user_email,
    })
end

-- 选择区域（POST）
function action_zones_select()
    local c = require_auth()
    if not c then return end

    local zone_id   = http.formvalue("zone_id")
    local zone_name = http.formvalue("zone_name") or ""

    if not zone_id or zone_id == "" then
        http.redirect(disp.build_url("admin/mynet/zones"))
        return
    end

    zone_m.set_current_zone(tonumber(zone_id) or 0, zone_name)
    http.redirect(disp.build_url("admin/mynet/nodes"))
end

-- 节点列表
function action_nodes()
    local c = require_auth()
    if not c then return end

    local zone = zone_ctx()
    if zone.zone_id == 0 then
        http.redirect(disp.build_url("admin/mynet/zones"))
        return
    end

    local page = tonumber(http.formvalue("page")) or 1
    local nodes_data, err = node_m.get_nodes(page, 20)

    tmpl.render("mynet/nodes", {
        nodes_data      = nodes_data or {},
        error           = err,
        zone            = zone,
        page            = page,
        current_node_id = cfg_m.get_node_id(),
        user_email      = c.user_email,
    })
end

-- 节点详情
function action_node_detail()
    local c = require_auth()
    if not c then return end

    local node_id = tonumber(http.formvalue("id"))
    if not node_id then
        http.redirect(disp.build_url("admin/mynet/nodes"))
        return
    end

    local conf_text,  conf_err  = node_m.get_node_config_rendered(node_id)
    local route_text, route_err = node_m.get_route_config_rendered(node_id)

    tmpl.render("mynet/node_detail", {
        node_id      = node_id,
        zone         = zone_ctx(),
        vpn_status   = node_m.get_vpn_service_status(),
        vpn_iface    = node_m.get_vpn_interface_status(),
        conf_text    = conf_text  or "",
        route_text   = route_text or "",
        conf_err     = conf_err,
        route_err    = route_err,
        user_email   = c.user_email,
        status_names = node_m.STATUS_NAMES,
    })
end

-- 刷新节点配置（POST → 重定向节点详情）
function action_node_refresh_config()
    local c = require_auth()
    if not c then return end

    local node_id = tonumber(http.formvalue("node_id"))
    if not node_id then
        http.redirect(disp.build_url("admin/mynet/nodes"))
        return
    end

    node_m.refresh_configs(node_id)
    http.redirect(disp.build_url("admin/mynet/nodes/detail?id=" .. tostring(node_id)))
end

-- 状态页
function action_status()
    local c = require_auth()
    if not c then return end

    local uptime  = util.trim(util.exec("awk '{print $1}' /proc/uptime 2>/dev/null") or "")
    local loadavg = util.trim(util.exec("cat /proc/loadavg 2>/dev/null") or "")

    -- 获取接口 RX/TX 统计
    local iface       = cfg_m.get_vpn_interface()
    local rx_bytes    = util.trim(util.exec("cat /sys/class/net/" .. iface .. "/statistics/rx_bytes 2>/dev/null") or "0")
    local tx_bytes    = util.trim(util.exec("cat /sys/class/net/" .. iface .. "/statistics/tx_bytes 2>/dev/null") or "0")

    tmpl.render("mynet/status", {
        zone       = zone_ctx(),
        vpn_status = node_m.get_vpn_service_status(),
        vpn_iface  = node_m.get_vpn_interface_status(),
        vpn_type   = cfg_m.get_vpn_type(),
        node_id    = cfg_m.get_node_id(),
        uptime     = uptime,
        loadavg    = loadavg,
        rx_bytes   = tonumber(rx_bytes) or 0,
        tx_bytes   = tonumber(tx_bytes) or 0,
        user_email = c.user_email,
    })
end

-- 设置页
function action_settings()
    local c = require_auth()
    if not c then return end

    tmpl.render("mynet/settings", {
        api_url    = cfg_m.get_api_url(),
        user_email = c.user_email,
    })
end

-- 保存设置（POST）
function action_settings_save()
    local c = require_auth()
    if not c then return end

    local api_url = util.trim(http.formvalue("api_url") or "")
    if api_url ~= "" then
        cfg_m.save_server_config(api_url)
    end
    http.redirect(disp.build_url("admin/mynet/settings"))
end

-- ─────────────────────────────────────────────────────────────
-- AJAX / JSON API Actions
-- ─────────────────────────────────────────────────────────────

function api_get_status()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    json_ok({
        success    = true,
        vpn_status = node_m.get_vpn_service_status(),
        vpn_iface  = node_m.get_vpn_interface_status(),
        zone       = cfg_m.load_current_zone(),
        node_id    = cfg_m.get_node_id(),
    })
end

function api_get_nodes()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local page     = tonumber(http.formvalue("page"))     or 1
    local per_page = tonumber(http.formvalue("per_page")) or 20
    local data, err = node_m.get_nodes(page, per_page)
    if err then json_err(err); return end

    json_ok({ success = true, data = data })
end

function api_get_zones()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local zones, err = zone_m.get_zones()
    if err then json_err(err); return end
    json_ok({ success = true, data = zones })
end

function api_vpn_start()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local ok, code = node_m.start_vpn()
    json_ok({ success = ok, message = ok and "VPN started" or ("start failed: code=" .. tostring(code)) })
end

function api_vpn_stop()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local ok, code = node_m.stop_vpn()
    json_ok({ success = ok, message = ok and "VPN stopped" or ("stop failed: code=" .. tostring(code)) })
end

function api_vpn_restart()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local ok, code = node_m.restart_vpn()
    json_ok({ success = ok, message = ok and "VPN restarted" or ("restart failed: code=" .. tostring(code)) })
end

function api_node_refresh_config()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local node_id = tonumber(http.formvalue("node_id"))
    if not node_id then json_err("node_id required"); return end

    local results = node_m.refresh_configs(node_id)
    json_ok({ success = results.ok, files = results.files, errors = results.errors })
end
