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
local sys_m  = require("luci.model.mynet.system")

-- ─────────────────────────────────────────────────────────────
-- 路由注册
-- ─────────────────────────────────────────────────────────────

function index()
    entry({"admin", "services", "mynet"},
        alias("admin", "services", "mynet", "index"),
        _("MyNet"), 60
    ).dependent = false

    -- 控制台
    entry({"admin", "services", "mynet", "index"},
        call("action_index"),
        _("Dashboard"), 10
    ).dependent = false

    -- 认证
    entry({"admin", "services", "mynet", "login"},
        call("action_login"),
        nil
    ).dependent = false

    entry({"admin", "services", "mynet", "logout"},
        call("action_logout"),
        nil
    ).dependent = false

    -- 区域（已从菜单移除，保留路由以兼容旧链接和 wizard）
    entry({"admin", "services", "mynet", "zones"},
        call("action_zones"),
        nil
    ).dependent = false
    entry({"admin", "services", "mynet", "zones", "select"},
        call("action_zones_select"),
        nil
    ).dependent = false

    -- 节点配置页（主菜单）
    entry({"admin", "services", "mynet", "node"},
        call("action_node"),
        _("Node"), 30
    ).dependent = false

    -- 节点列表（已从菜单移除，重定向到 node 页）
    entry({"admin", "services", "mynet", "nodes"},
        call("action_nodes"),
        nil
    ).dependent = false

    -- 状态
    entry({"admin", "services", "mynet", "status"},
        call("action_status"),
        _("Status"), 40
    )

    -- 向导
    entry({"admin", "services", "mynet", "wizard"},
        call("action_wizard"),
        nil
    ).dependent = false

    entry({"admin", "services", "mynet", "wizard", "select_node"},
        call("action_wizard_select_node"),
        nil
    ).dependent = false

    -- 设置
    entry({"admin", "services", "mynet", "settings"},
        call("action_settings"),
        _("Settings"), 50
    )
    entry({"admin", "services", "mynet", "settings", "save"},
        call("action_settings_save"),
        nil
    )

    -- 服务管理
    entry({"admin", "services", "mynet", "service"},
        call("action_service"),
        _("Service"), 55
    ).dependent = false
    entry({"admin", "services", "mynet", "service", "op"},
        call("action_service_op"),
        nil
    ).dependent = false

    -- 网络管理（路由/防火墙）
    entry({"admin", "services", "mynet", "network"},
        call("action_network"),
        _("Network"), 58
    ).dependent = false
    entry({"admin", "services", "mynet", "network", "op"},
        call("action_network_op"),
        nil
    ).dependent = false

    -- AJAX / JSON API
    entry({"admin", "services", "mynet", "api", "status"},        call("api_get_status")         ).dependent = false
    entry({"admin", "services", "mynet", "api", "nodes"},          call("api_get_nodes")           ).dependent = false
    entry({"admin", "services", "mynet", "api", "zones"},          call("api_get_zones")           ).dependent = false
    entry({"admin", "services", "mynet", "api", "vpn_start"},      call("api_vpn_start")           ).dependent = false
    entry({"admin", "services", "mynet", "api", "vpn_stop"},       call("api_vpn_stop")            ).dependent = false
    entry({"admin", "services", "mynet", "api", "vpn_restart"},    call("api_vpn_restart")         ).dependent = false
    entry({"admin", "services", "mynet", "api", "node_config"},    call("api_node_refresh_config") ).dependent = false
    entry({"admin", "services", "mynet", "api", "node_save_key"},  call("api_node_save_key")       ).dependent = false
    entry({"admin", "services", "mynet", "api", "node_switch"},    call("api_node_switch")         ).dependent = false
    entry({"admin", "services", "mynet", "api", "node_gen_key"},   call("api_node_gen_key")        ).dependent = false
    -- 服务控制 API
    entry({"admin", "services", "mynet", "api", "svc_start"},      call("api_svc_start")           ).dependent = false
    entry({"admin", "services", "mynet", "api", "svc_stop"},       call("api_svc_stop")            ).dependent = false
    entry({"admin", "services", "mynet", "api", "svc_restart"},    call("api_svc_restart")         ).dependent = false
    entry({"admin", "services", "mynet", "api", "mynetd_start"},   call("api_mynetd_start")        ).dependent = false
    entry({"admin", "services", "mynet", "api", "mynetd_stop"},    call("api_mynetd_stop")         ).dependent = false
    entry({"admin", "services", "mynet", "api", "mynetd_restart"}, call("api_mynetd_restart")      ).dependent = false

    -- GNB Monitor
    entry({"admin", "services", "mynet", "gnb"},
        call("action_gnb_monitor"),
        _("GNB Monitor"), 45
    ).dependent = false
    entry({"admin", "services", "mynet", "api", "gnb_nodes"}, call("api_gnb_monitor_data")).dependent = false
    -- GNB 自动安装
    entry({"admin", "services", "mynet", "api", "gnb_auto_install"}, call("api_gnb_auto_install")).dependent = false
    entry({"admin", "services", "mynet", "api", "gnb_install_status"}, call("api_gnb_install_status")).dependent = false
    -- GNB 直接启停（节点页 Start/Stop/Restart 按鈕）
    entry({"admin", "services", "mynet", "api", "gnb_start"},   call("api_gnb_start")  ).dependent = false
    entry({"admin", "services", "mynet", "api", "gnb_stop"},    call("api_gnb_stop")   ).dependent = false
    entry({"admin", "services", "mynet", "api", "gnb_restart"}, call("api_gnb_restart")).dependent = false
    -- 系统依赖（kmod-tun / bash / curl-tls）自动安装
    entry({"admin", "services", "mynet", "api", "install_system_deps"}, call("api_install_system_deps")).dependent = false
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
        http.redirect(disp.build_url("admin/services/mynet/login"))
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
    return cfg_m.load_current_zone() or { zone_id = "0", zone_name = "" }
end

-- get_mynetd_status → 委托给 system_m
local function get_mynetd_status()
    return sys_m.get_mynetd_status()
end

-- ─────────────────────────────────────────────────────────────
-- 页面 Actions
-- ─────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────
-- Dashboard
-- ─────────────────────────────────────────────────────────────
function action_index()
    local c = require_auth()
    if not c then return end

    local zone          = zone_ctx()
    local vpn_status    = node_m.get_vpn_service_status()
    local vpn_iface     = node_m.get_vpn_interface_status()
    local node_id       = cfg_m.get_node_id()
    local mynetd_st, _  = sys_m.get_mynetd_status()
    local enable_out    = util.trim(util.exec("/etc/init.d/mynet enabled 2>/dev/null && echo enabled || echo disabled") or "")
    local router_info   = sys_m.collect_router_info(node_id)

    tmpl.render("mynet/index", {
        user_email    = c.user_email,
        zone          = zone,
        node_id       = node_id,
        vpn_status    = vpn_status,
        vpn_iface     = vpn_iface,
        vpn_type      = cfg_m.get_vpn_type(),
        mynetd_status = mynetd_st,
        enable_status = enable_out,
        router_info   = router_info,
    })
end

-- 登录页（GET 显示，POST 处理）
function action_login()
    -- 已登录则跳转控制台
    local c = cred_m.load()
    if c and cred_m.is_valid(c) and http.getenv("REQUEST_METHOD") ~= "POST" then
        http.redirect(disp.build_url("admin/services/mynet/index"))
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
            http.redirect(disp.build_url("admin/services/mynet/wizard"))
            return
        end
    end

    tmpl.render("mynet/login", {
        login_error   = err_msg,
        prefill_email = prefill,
    })
end

-- 登出
function action_logout()
    auth_m.logout()
    http.redirect(disp.build_url("admin/services/mynet/login"))
end

-- 区域列表（已移除菜单，重定向到 node 页）
function action_zones()
    local c = require_auth()
    if not c then return end
    http.redirect(disp.build_url("admin/services/mynet/node"))
end

-- 选择区域（POST）
function action_zones_select()
    local c = require_auth()
    if not c then return end

    local zone_id     = http.formvalue("zone_id")
    local zone_name   = http.formvalue("zone_name") or ""
    local redirect_to = http.formvalue("redirect_to") or ""

    if not zone_id or zone_id == "" then
        http.redirect(disp.build_url("admin/services/mynet/zones"))
        return
    end

    zone_m.set_current_zone(zone_id, zone_name)

    if redirect_to ~= "" then
        -- 简单whitelist：只允许跳转到本站 /cgi-bin/luci/ 路径
        if redirect_to:match("^/cgi%-bin/luci/") then
            http.redirect(redirect_to)
            return
        end
    end
    http.redirect(disp.build_url("admin/services/mynet/nodes"))
end

-- 节点配置页（主菜单 Node）
function action_node()
    local c = require_auth()
    if not c then return end

    local zone = zone_ctx()

    local node_id    = cfg_m.get_node_id()
    local node_info  = nil
    local node_err   = nil
    local local_cfgs = {}
    local priv_key   = nil
    local peer_keys  = {}
    local nodes_data = {}

    -- 当前节点详情
    if node_id and util.int_str(node_id) ~= "0" then
        node_info, node_err  = node_m.get_single_node(node_id)
        local_cfgs           = node_m.read_local_configs(node_id)
        priv_key             = node_m.get_private_key(node_id)
        peer_keys            = node_m.get_peer_keys(node_id)
    end

    -- 节点列表（用于切换）
    local page    = tonumber(http.formvalue("page")) or 1
    nodes_data, _ = node_m.get_nodes(page, 20)

    tmpl.render("mynet/node", {
        zone         = zone,
        node_id      = node_id,
        node_info    = node_info,
        node_err     = node_err,
        local_cfgs   = local_cfgs,
        priv_key     = priv_key,
        peer_keys    = peer_keys,
        nodes_data   = nodes_data or {},
        page         = page,
        vpn_status   = node_m.get_vpn_service_status(),
        user_email   = c.user_email,
        status_names = node_m.STATUS_NAMES,
    })
end

-- 节点列表（已移除，重定向到 node 页）
function action_nodes()
    local c = require_auth()
    if not c then return end
    http.redirect(disp.build_url("admin/services/mynet/node"))
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

    local gnb = cfg_m.load_gnb_config()
    local mon = cfg_m.load_monitor_config()
    tmpl.render("mynet/settings", {
        api_url            = cfg_m.get_api_url(),
        user_email         = c.user_email,
        gnb_root           = gnb.gnb_root,
        gnb_bin_path       = gnb.gnb_bin_path,
        system_gnb_path    = gnb.system_gnb_path,
        use_system_gnb     = gnb.use_system_gnb,
        mynetd_bin_path    = mon.mynetd_bin_path,
        heartbeat_interval = mon.heartbeat_interval,
        log_level          = mon.log_level,
        auto_refresh_nodes = mon.auto_refresh_nodes,
        daemon_mode        = mon.daemon_mode,
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

    local gnb_root        = util.trim(http.formvalue("gnb_root")        or "")
    local gnb_bin_path    = util.trim(http.formvalue("gnb_bin_path")    or "")
    local system_gnb_path = util.trim(http.formvalue("system_gnb_path") or "")
    local use_system_gnb  = http.formvalue("use_system_gnb") == "1"
    cfg_m.save_gnb_config(
        gnb_root        ~= "" and gnb_root        or nil,
        gnb_bin_path    ~= "" and gnb_bin_path    or nil,
        system_gnb_path ~= "" and system_gnb_path or nil,
        use_system_gnb
    )

    local mynetd_bin_path    = util.trim(http.formvalue("mynetd_bin_path")    or "")
    local heartbeat_interval = http.formvalue("heartbeat_interval")
    local log_level          = util.trim(http.formvalue("log_level")          or "info")
    local auto_refresh_nodes = http.formvalue("auto_refresh_nodes") == "1"
    local daemon_mode        = http.formvalue("daemon_mode") == "1"
    cfg_m.save_monitor_config(
        mynetd_bin_path ~= "" and mynetd_bin_path or nil,
        heartbeat_interval,
        log_level ~= "" and log_level or nil,
        auto_refresh_nodes,
        daemon_mode
    )

    http.redirect(disp.build_url("admin/services/mynet/settings"))
end

-- 向导页（首次配置引导）
function action_wizard()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then
        http.redirect(disp.build_url("admin/services/mynet/login"))
        return
    end

    local zone    = cfg_m.load_current_zone()
    local node_id = cfg_m.get_node_id()
    local has_zone = zone and tostring(zone.zone_id) ~= "0"

    -- 加载 zones（永远需要）
    local zones, zone_err = zone_m.get_zones()

    -- 加载 nodes（仅当 zone 已选择时）
    local nodes_data, node_err
    if has_zone then
        local pg = tonumber(http.formvalue("page")) or 1
        nodes_data, node_err = node_m.get_nodes(pg, 20)
    end

    local active_tab = http.formvalue("tab") or "account"

    tmpl.render("mynet/wizard", {
        active_tab      = active_tab,
        user_email      = c.user_email,
        zone            = zone or { zone_id = "0", zone_name = "" },
        zones           = zones or {},
        zone_fetch_error = zone_err,
        node_id         = node_id,
        nodes_data      = nodes_data or {},
        node_fetch_error = node_err,
        all_done        = has_zone,
    })
end

-- 向导：选择节点并写入配置（POST）
function action_wizard_select_node()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then
        http.redirect(disp.build_url("admin/services/mynet/login"))
        return
    end

    local node_id_str = http.formvalue("node_id") or ""
    local redirect_to = http.formvalue("redirect_to") or ""
    local node_id_num = tonumber(node_id_str)
    if not node_id_num then
        http.redirect(disp.build_url("admin/services/mynet/wizard") .. "?tab=node")
        return
    end

    -- 写入 mynet.conf NODE_ID
    cfg_m.save_node_id(node_id_num)
    -- 下载节点配置文件
    node_m.refresh_configs(node_id_num)

    -- 支持自定义跳转（仅限本站路径）
    if redirect_to ~= "" and redirect_to:match("^/cgi%-bin/luci/") then
        http.redirect(redirect_to)
        return
    end
    http.redirect(disp.build_url("admin/services/mynet/wizard") .. "?tab=node")
end

-- ─────────────────────────────────────────────────────────────
-- 服务管理 Actions
-- ─────────────────────────────────────────────────────────────

-- 检查 /etc/init.d/mynet 是否已启用自启
local function mynet_initd_enabled()
    local out, code = util.exec_status("ls /etc/rc.d/S*mynet 2>/dev/null")
    return code == 0 and (out or "") ~= ""
end

-- 查找 service-manager.sh 路径
local function find_svc_mgr()
    local paths = {
        util.MYNET_HOME .. "/scripts/_src/platforms/openwrt/service-manager.sh",
        util.MYNET_HOME .. "/scripts/service-manager.sh",
        "/usr/share/mynet/service-manager.sh",
    }
    for _, p in ipairs(paths) do
        if util.file_exists(p) then return p end
    end
    return nil
end

-- 构建 Install 标签状态
local function get_install_status()
    local fw_cfg = util.read_file("/etc/config/firewall") or ""
    return {
        mynetd_initd   = util.file_exists("/etc/init.d/mynetd"),
        mynetd_enabled = mynet_initd_enabled(),
        fw_script      = util.file_exists("/etc/mynet/scripts/firewall.mynet"),
        route_script   = util.file_exists("/etc/mynet/scripts/route.mynet"),
        fw_config_ok   = fw_cfg:find("firewall%.mynet") ~= nil,
    }
end

function action_service()
    local c = require_auth()
    if not c then return end

    local mon             = cfg_m.load_monitor_config()
    local mynetd_st, mpid = get_mynetd_status()
    local enable_out      = util.trim(util.exec("/etc/init.d/mynet enabled 2>/dev/null && echo enabled || echo disabled") or "")

    -- 读取最后 200 行日志
    local log_path    = util.MYNET_HOME .. "/logs/luci.log"
    local log_content = util.trim(util.exec("tail -200 " .. log_path .. " 2>/dev/null") or "")

    local active_tab = http.formvalue("tab") or "status"
    if active_tab ~= "status" and active_tab ~= "mynetd" and active_tab ~= "log" and active_tab ~= "install" then
        active_tab = "status"
    end

    tmpl.render("mynet/service", {
        active_tab         = active_tab,
        vpn_status         = node_m.get_vpn_service_status(),
        vpn_iface          = node_m.get_vpn_interface_status(),
        enable_status      = enable_out,
        mynetd_status      = mynetd_st,
        mynetd_pid         = mpid,
        mynetd_bin         = mon.mynetd_bin_path,
        heartbeat_interval = mon.heartbeat_interval,
        log_level          = mon.log_level,
        log_path           = log_path,
        log_content        = log_content,
        install_status     = get_install_status(),
        user_email         = c.user_email,
    })
end

-- 服务操作（POST）
function action_service_op()
    local c = require_auth()
    if not c then return end

    local service = http.formvalue("service") or "mynet"
    local op      = http.formvalue("op")      or ""
    local tab     = http.formvalue("tab")     or "status"
    local ok_msg, err_msg

    if service == "mynet" then
        local res, code = util.exec_status("/etc/init.d/mynet " .. op .. " 2>&1")
        if op == "enable" or op == "disable" then
            ok_msg = "mynet " .. op .. " ok"
        else
            ok_msg = "mynet " .. op .. ": " .. (util.trim(res or "") ~= "" and util.trim(res) or "ok")
            if code ~= 0 then err_msg = ok_msg; ok_msg = nil end
        end
    elseif service == "mynetd" then
        local mon = cfg_m.load_monitor_config()
        local _, mpid = get_mynetd_status()
        if op == "stop" or op == "restart" then
            if mpid then util.exec_status("kill " .. mpid .. " 2>/dev/null") end
            util.exec_status("pkill -x mynetd 2>/dev/null")
        end
        if op == "start" or op == "restart" then
            local bin = mon.mynetd_bin_path
            if util.file_exists(bin) then
                local cmd = bin .. " -c " .. util.CONF_DIR
                    .. " -interval " .. tostring(mon.heartbeat_interval)
                    .. " -log-level " .. (mon.log_level or "info")
                if mon.daemon_mode then cmd = cmd .. " -d" end
                util.exec(cmd .. " &")
                ok_msg = "mynetd started"
            else
                err_msg = "mynetd binary not found: " .. bin
            end
        else
            ok_msg = "mynetd " .. op .. " ok"
        end
    -- install / uninstall ops
    elseif service == "install" then
        if op == "install_mynetd" then
            local mgr = find_svc_mgr()
            if mgr then
                local out, code = util.exec_status("sh " .. mgr .. " install 2>&1")
                ok_msg = util.trim(out or "ok")
                if code ~= 0 then err_msg = ok_msg; ok_msg = nil end
            else
                err_msg = "service-manager.sh not found"
            end
        elseif op == "uninstall_mynetd" then
            local mgr = find_svc_mgr()
            if mgr then
                local out, code = util.exec_status("sh " .. mgr .. " uninstall 2>&1")
                ok_msg = util.trim(out or "ok")
                if code ~= 0 then err_msg = ok_msg; ok_msg = nil end
            else
                err_msg = "service-manager.sh not found"
            end
        elseif op == "enable_mynetd" then
            local out, code = util.exec_status("/etc/init.d/mynetd enable 2>&1")
            ok_msg = "mynetd autostart enabled"
            if code ~= 0 then err_msg = util.trim(out or "enable failed"); ok_msg = nil end
        elseif op == "disable_mynetd" then
            local out, code = util.exec_status("/etc/init.d/mynetd disable 2>&1")
            ok_msg = "mynetd autostart disabled"
            if code ~= 0 then err_msg = util.trim(out or "disable failed"); ok_msg = nil end
        elseif op == "install_fw_script" then
            local src = util.MYNET_HOME .. "/scripts/_src/platforms/openwrt/firewall.mynet"
            local dst = "/etc/mynet/scripts/firewall.mynet"
            util.ensure_dir("/etc/mynet/scripts")
            if util.file_exists(src) then
                local out, code = util.exec_status("cp " .. src .. " " .. dst .. " && chmod +x " .. dst .. " 2>&1")
                ok_msg = "firewall.mynet installed"
                if code ~= 0 then err_msg = util.trim(out or "copy failed"); ok_msg = nil end
            else
                err_msg = "source not found: " .. src
            end
        elseif op == "uninstall_fw_script" then
            local dst = "/etc/mynet/scripts/firewall.mynet"
            if util.file_exists(dst) then
                os.remove(dst)
                ok_msg = "firewall.mynet removed"
            else
                ok_msg = "file not present"
            end
        elseif op == "install_route_script" then
            local src = util.MYNET_HOME .. "/scripts/_src/platforms/openwrt/route.mynet"
            local dst = "/etc/mynet/scripts/route.mynet"
            util.ensure_dir("/etc/mynet/scripts")
            if util.file_exists(src) then
                local out, code = util.exec_status("cp " .. src .. " " .. dst .. " && chmod +x " .. dst .. " 2>&1")
                ok_msg = "route.mynet installed"
                if code ~= 0 then err_msg = util.trim(out or "copy failed"); ok_msg = nil end
            else
                err_msg = "source not found: " .. src
            end
        elseif op == "uninstall_route_script" then
            local dst = "/etc/mynet/scripts/route.mynet"
            if util.file_exists(dst) then
                os.remove(dst)
                ok_msg = "route.mynet removed"
            else
                ok_msg = "file not present"
            end
        end
    end

    -- 短暂等待让进程状态更新
    os.execute("sleep 1")
    local mon = cfg_m.load_monitor_config()
    local mynetd_st, mpid = get_mynetd_status()
    tmpl.render("mynet/service", {
        active_tab         = tab,
        vpn_status         = node_m.get_vpn_service_status(),
        vpn_iface          = node_m.get_vpn_interface_status(),
        enable_status      = util.trim(util.exec("/etc/init.d/mynet enabled 2>/dev/null && echo enabled || echo disabled") or ""),
        mynetd_status      = mynetd_st,
        mynetd_pid         = mpid,
        mynetd_bin         = mon.mynetd_bin_path,
        heartbeat_interval = mon.heartbeat_interval,
        log_level          = mon.log_level,
        log_path           = util.MYNET_HOME .. "/logs/luci.log",
        log_content        = util.trim(util.exec("tail -200 " .. util.MYNET_HOME .. "/logs/luci.log 2>/dev/null") or ""),
        install_status     = get_install_status(),
        op_result          = { ok = (err_msg == nil), msg = err_msg or ok_msg or "" },
        user_email         = c.user_email,
    })
end

-- ─────────────────────────────────────────────────────────────
-- 网络管理 Actions（路由 / 防火墙 / 启动脚本）
-- ─────────────────────────────────────────────────────────────

-- 构建脚本模块列表 { name, path, exists }
local function build_script_list()
    local home = util.MYNET_HOME
    local items = {
        { name = "service-manager.sh", path = home .. "/scripts/_src/platforms/openwrt/service-manager.sh" },
        { name = "route.sh",           path = home .. "/scripts/_src/platforms/openwrt/runtime/modules/route.sh" },
        { name = "firewall.sh",        path = home .. "/scripts/_src/platforms/openwrt/runtime/modules/firewall.sh" },
        { name = "common.sh",          path = home .. "/scripts/_src/common/common.sh" },
        { name = "vpn.sh",             path = home .. "/scripts/_src/common/vpn.sh" },
        { name = "install.sh",         path = home .. "/scripts/install/install.sh" },
    }
    for _, s in ipairs(items) do
        s.exists = util.file_exists(s.path)
    end
    return items
end

-- 网络管理页
function action_network()
    local c = require_auth()
    if not c then return end

    local fw_ver = util.trim(util.exec("command -v fw4 2>/dev/null && fw4 --version 2>/dev/null || echo fw3") or "fw3")

    local active_tab = http.formvalue("tab") or "route"

    tmpl.render("mynet/network", {
        active_tab          = active_tab,
        route_conf          = util.trim(util.read_file(util.CONF_DIR .. "/route.conf")  or ""),
        ip_route            = util.trim(util.exec("ip route show 2>/dev/null") or ""),
        fw_version          = fw_ver,
        fw_zones            = util.trim(util.exec("uci show firewall 2>/dev/null | grep '=zone'") or ""),
        fw_rules            = util.trim(util.exec("uci show firewall 2>/dev/null | grep '=rule'") or ""),
        mynet_initd_enabled = mynet_initd_enabled(),
        svc_mgr_path        = find_svc_mgr(),
        svc_mgr_status      = nil,
        script_list         = build_script_list(),
        user_email          = c.user_email,
    })
end

-- 网络操作（POST）
function action_network_op()
    local c = require_auth()
    if not c then return end

    local op  = http.formvalue("op")  or ""
    local tab = http.formvalue("tab") or "route"
    local ok_msg, err_msg

    if op == "reload_route" then
        local script = find_svc_mgr()
        if script then
            local out, code = util.exec_status("sh " .. script .. " restart 2>&1")
            ok_msg = "route apply: " .. (util.trim(out or "") ~= "" and util.trim(out) or "ok")
            if code ~= 0 then err_msg = ok_msg; ok_msg = nil end
        else
            -- fallback: 直接重启 mynet
            local _, code = util.exec_status("/etc/init.d/mynet restart 2>&1")
            ok_msg = code == 0 and "mynet restarted" or nil
            if code ~= 0 then err_msg = "restart failed" end
        end

    elseif op == "reload_fw" then
        local out, code = util.exec_status("uci commit firewall 2>&1; /etc/init.d/firewall restart 2>&1")
        ok_msg = util.trim(out or "") ~= "" and util.trim(out) or "firewall reloaded"
        if code ~= 0 then err_msg = ok_msg; ok_msg = nil end

    elseif op == "reload_fw_commit" then
        local out, code = util.exec_status("uci commit firewall 2>&1 && fw4 reload 2>&1 || fw3 reload 2>&1")
        ok_msg = util.trim(out or "") ~= "" and util.trim(out) or "firewall committed"
        if code ~= 0 then err_msg = ok_msg; ok_msg = nil end

    elseif op == "initd_enable" then
        util.exec_status("/etc/init.d/mynet enable 2>&1")
        ok_msg = "autostart enabled"

    elseif op == "initd_disable" then
        util.exec_status("/etc/init.d/mynet disable 2>&1")
        ok_msg = "autostart disabled"

    elseif op == "svc_status" or op == "svc_start" or op == "svc_stop" or op == "svc_restart" then
        local mgr = find_svc_mgr()
        if mgr then
            local cmd_map = {
                svc_status  = "status",
                svc_start   = "start",
                svc_stop    = "stop",
                svc_restart = "restart",
            }
            local out, code = util.exec_status("sh " .. mgr .. " " .. cmd_map[op] .. " 2>&1")
            ok_msg = util.trim(out or "")
            if code ~= 0 then err_msg = ok_msg; ok_msg = nil end
        else
            err_msg = "service-manager.sh not found"
        end
    end

    local svc_st = (op == "svc_status" or op == "svc_start" or op == "svc_stop" or op == "svc_restart")
        and ok_msg or nil

    tmpl.render("mynet/network", {
        active_tab          = tab,
        route_conf          = util.trim(util.read_file(util.CONF_DIR .. "/route.conf") or ""),
        ip_route            = util.trim(util.exec("ip route show 2>/dev/null") or ""),
        fw_version          = util.trim(util.exec("command -v fw4 2>/dev/null && fw4 --version 2>/dev/null || echo fw3") or "fw3"),
        fw_zones            = util.trim(util.exec("uci show firewall 2>/dev/null | grep '=zone'") or ""),
        fw_rules            = util.trim(util.exec("uci show firewall 2>/dev/null | grep '=rule'") or ""),
        mynet_initd_enabled = mynet_initd_enabled(),
        svc_mgr_path        = find_svc_mgr(),
        svc_mgr_status      = svc_st,
        script_list         = build_script_list(),
        op_result           = { ok = (err_msg == nil), msg = err_msg or ok_msg or "" },
        user_email          = c.user_email,
    })
end

-- ─────────────────────────────────────────────────────────────
-- AJAX / JSON API Actions
-- ─────────────────────────────────────────────────────────────

function api_get_status()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local node_id = cfg_m.get_node_id()
    -- 状态优先检测 gnb 进程（直接启动模式），其次回落到 init.d 服务
    local gnb_running = node_id and node_id ~= 0 and node_m.gnb_is_running(node_id)
    local vpn_status
    if gnb_running then
        vpn_status = "running"
    else
        vpn_status = node_m.get_vpn_service_status()
    end

    json_ok({
        success    = true,
        vpn_status = vpn_status,
        vpn_iface  = node_m.get_vpn_interface_status(),
        zone       = cfg_m.load_current_zone(),
        node_id    = node_id,
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

-- GNB 直接启停（node 页 Start/Stop/Restart 按鈕）
function api_gnb_start()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end
    local node_id = tonumber(http.formvalue("node_id"))
    if not node_id then json_err("node_id required"); return end
    local ok, err = node_m.start_gnb(node_id)
    if ok then
        json_ok({ success = true, message = "GNB started" })
    else
        json_ok({ success = false, message = err or "start failed" })
    end
end

function api_gnb_stop()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end
    local node_id = tonumber(http.formvalue("node_id"))
    if not node_id then json_err("node_id required"); return end
    node_m.stop_gnb(node_id)
    json_ok({ success = true, message = "GNB stopped" })
end

function api_gnb_restart()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end
    local node_id = tonumber(http.formvalue("node_id"))
    if not node_id then json_err("node_id required"); return end
    local ok, err = node_m.restart_gnb(node_id)
    if ok then
        json_ok({ success = true, message = "GNB restarted" })
    else
        json_ok({ success = false, message = err or "restart failed" })
    end
end

function api_node_refresh_config()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local node_id     = tonumber(http.formvalue("node_id"))
    local config_type = http.formvalue("type") or "all"
    if not node_id then json_err("node_id required"); return end

    if config_type == "all" then
        local results = node_m.refresh_configs(node_id)
        json_ok({ success = results.ok, files = results.files, errors = results.errors })
    else
        local res = node_m.refresh_single_config(node_id, config_type)
        json_ok({ success = res.ok, file = res.file, error = res.error })
    end
end

-- 保存私钥 API（POST: node_id, key_hex）
function api_node_save_key()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local node_id = tonumber(http.formvalue("node_id"))
    local key_hex = util.trim(http.formvalue("key_hex") or "")
    if not node_id then json_err("node_id required"); return end
    if key_hex == "" then json_err("key_hex required"); return end

    -- 1. 写入私钥
    local ok, err = node_m.save_private_key(node_id, key_hex)
    if not ok then json_err(err or "save private key failed"); return end

    -- 2. 从服务器下载并写入公钥
    local pub_hex, pub_err = node_m.fetch_server_public_key(node_id)
    if not pub_hex then
        -- 公钥拉取失败不阻断，返回警告信息
        json_ok({ success = true,
                  message = "private key saved; could not fetch public key from server: " .. (pub_err or "unknown"),
                  pub_warn = true })
        return
    end

    json_ok({ success = true,
              message = "private key saved; public key fetched from server",
              pub_hex = pub_hex })
end

-- 切换节点 API（POST: node_id）
function api_node_switch()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local node_id = tonumber(http.formvalue("node_id"))
    if not node_id then json_err("node_id required"); return end

    cfg_m.save_node_id(node_id)
    node_m.refresh_configs(node_id)
    json_ok({ success = true, message = "node switched to " .. util.int_str(node_id),
              redirect = disp.build_url("admin/services/mynet/node") })
end

-- 生成 GNB 密钥对 API（POST: node_id）
-- 使用 gnb_crypto 生成新密钥对，同时：
-- 1. 将私钥保存到本地 {node_id}.key
-- 2. 将公钥上传到服务器 PUT /nodes/{id}/keys
function api_node_gen_key()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local node_id = tonumber(http.formvalue("node_id"))
    if not node_id then json_err("node_id required"); return end

    -- 生成密钥对
    local kp, gen_err = node_m.generate_key_pair()
    if gen_err then json_err("keygen failed: " .. gen_err); return end

    -- 保存私钥到本地
    local ok_priv, err_priv = node_m.save_private_key(node_id, kp.priv_hex)
    if not ok_priv then json_err("save private key failed: " .. (err_priv or "")); return end

    -- 保存公钥到 security/ 和 ed25519/ 目录
    local ok_spub, err_spub = node_m.save_public_key(node_id, kp.pub_hex)
    if not ok_spub then
        util.log_warn("api_node_gen_key: save_public_key failed: " .. (err_spub or ""))
    end

    -- 上传公钥到服务器
    local ok_pub, err_pub = node_m.upload_public_key(node_id, kp.pub_hex)
    if not ok_pub then
        json_err("private key saved locally, but upload public key failed: " .. (err_pub or "")); return
    end

    json_ok({
        success  = true,
        message  = "key pair generated and uploaded",
        pub_hex  = kp.pub_hex,
    })
end

-- ─────────────────────────────────────────────────────────────
-- 服务控制 API（Dashboard 快速按钮用）
-- ─────────────────────────────────────────────────────────────

function api_svc_start()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end
    local _, code = util.exec_status("/etc/init.d/mynet start 2>&1")
    json_ok({ success = code == 0, message = code == 0 and "mynet started" or ("start failed (code=" .. tostring(code) .. ")") })
end

function api_svc_stop()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end
    local _, code = util.exec_status("/etc/init.d/mynet stop 2>&1")
    json_ok({ success = code == 0, message = code == 0 and "mynet stopped" or ("stop failed (code=" .. tostring(code) .. ")") })
end

function api_svc_restart()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end
    local _, code = util.exec_status("/etc/init.d/mynet restart 2>&1")
    json_ok({ success = code == 0, message = code == 0 and "mynet restarted" or ("restart failed (code=" .. tostring(code) .. ")") })
end

function api_mynetd_start()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end
    local mon = cfg_m.load_monitor_config()
    local bin = mon.mynetd_bin_path
    if not util.file_exists(bin) then
        json_ok({ success = false, message = "mynetd binary not found: " .. tostring(bin) })
        return
    end
    local _, pid = get_mynetd_status()
    if pid then
        json_ok({ success = true, message = "mynetd already running (pid " .. pid .. ")" })
        return
    end
    local cmd = bin .. " -c " .. util.CONF_DIR
        .. " -interval " .. tostring(mon.heartbeat_interval)
        .. " -log-level " .. (mon.log_level or "info")
    if mon.daemon_mode then cmd = cmd .. " -d" end
    util.exec(cmd .. " &")
    json_ok({ success = true, message = "mynetd started" })
end

function api_mynetd_stop()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end
    local _, pid = get_mynetd_status()
    if pid then util.exec_status("kill " .. pid .. " 2>/dev/null") end
    util.exec_status("pkill -x mynetd 2>/dev/null")
    json_ok({ success = true, message = "mynetd stopped" })
end

function api_mynetd_restart()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end
    local _, pid = get_mynetd_status()
    if pid then util.exec_status("kill " .. pid .. " 2>/dev/null") end
    util.exec_status("pkill -x mynetd 2>/dev/null")
    local mon = cfg_m.load_monitor_config()
    local bin = mon.mynetd_bin_path
    if util.file_exists(bin) then
        local cmd = bin .. " -c " .. util.CONF_DIR
            .. " -interval " .. tostring(mon.heartbeat_interval)
            .. " -log-level " .. (mon.log_level or "info")
        if mon.daemon_mode then cmd = cmd .. " -d" end
        util.exec(cmd .. " &")
    end
    json_ok({ success = true, message = "mynetd restarted" })
end

-- ─────────────────────────────────────────────────────────────
-- GNB Monitor Actions
-- ─────────────────────────────────────────────────────────────

function action_gnb_monitor()
    local c = require_auth()
    if not c then return end

    local node_id = cfg_m.get_node_id()
    local gnb_root = util.GNB_DRIVER_ROOT
    local gnb_ctl  = gnb_root .. "/bin/gnb_ctl"
    local gnb_map  = (node_id and util.int_str(node_id) ~= "0")
        and gnb_root .. "/conf/" .. util.int_str(node_id) .. "/gnb.map" or nil

    local nodes, gnb_err, gnb_raw
    if not util.file_exists(gnb_ctl) then
        gnb_err = "gnb_ctl not found: " .. gnb_ctl
    elseif not gnb_map or not util.file_exists(gnb_map) then
        gnb_err = gnb_map and ("gnb.map not found: " .. gnb_map) or "No node_id configured"
    else
        local cmd = "cd '" .. gnb_root .. "' && ./bin/gnb_ctl -s -b 'conf/" .. util.int_str(node_id) .. "/gnb.map' 2>&1"
        gnb_raw = util.exec(cmd) or ""
        nodes   = sys_m.parse_gnb_nodes(gnb_raw)
    end

    local active_tab = http.formvalue("tab") or "peers"
    tmpl.render("mynet/gnb_monitor", {
        active_tab = active_tab,
        node_id    = node_id,
        nodes      = nodes or {},
        gnb_err    = gnb_err,
        gnb_raw    = gnb_raw,
        gnb_ctl    = gnb_ctl,
        gnb_map    = gnb_map,
        user_email = c.user_email,
        ts         = os.time(),
    })
end

function api_gnb_monitor_data()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local node_id = cfg_m.get_node_id()
    local gnb_root = util.GNB_DRIVER_ROOT
    local gnb_ctl  = gnb_root .. "/bin/gnb_ctl"

    if not node_id or util.int_str(node_id) == "0" then
        json_ok({ success = false, message = "No node_id configured" })
        return
    end
    if not util.file_exists(gnb_ctl) then
        json_ok({ success = false, message = "gnb_ctl not found" })
        return
    end

    local cmd = "cd '" .. gnb_root .. "' && ./bin/gnb_ctl -s -b 'conf/" .. util.int_str(node_id) .. "/gnb.map' 2>&1"
    local output = util.exec(cmd) or ""
    local nodes  = sys_m.parse_gnb_nodes(output)

    -- 序列化供 JSON（latency 转 ms）
    local result = {}
    for _, n in ipairs(nodes) do
        local lat = n.ipv4_latency > 0 and n.ipv4_latency or n.ipv6_latency
        table.insert(result, {
            node_id      = n.node_id,
            tun_ipv4     = n.tun_ipv4,
            tun_ipv6     = n.tun_ipv6,
            wan_ipv4     = n.wan_ipv4,
            wan_ipv6     = n.wan_ipv6,
            latency_ms   = lat > 0 and string.format("%.1f", lat / 1000.0) or nil,
            conn_status  = n.conn_status,
            in_bytes     = n.in_bytes,
            out_bytes    = n.out_bytes,
            avail_addrs  = n.avail_addrs,
            detect_count = n.detect_count,
            is_local     = n.is_local,
        })
    end
    json_ok({ success = true, ts = os.time(), nodes = result })
end

-- ─────────────────────────────────────────────────────────────
-- GNB 自动安装 API
-- ─────────────────────────────────────────────────────────────

-- 触发后台自动安装（防重入）
function api_gnb_auto_install()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local gnb_m  = require("luci.model.mynet.gnb_installer")
    local result = gnb_m.start_auto_install()
    json_ok(result)
end

-- 安装系统依赖：kmod-tun / bash / curl-tls / ca-bundle（不安装 gnb）
function api_install_system_deps()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local gnb_m  = require("luci.model.mynet.gnb_installer")
    local result = gnb_m.check_deps()
    json_ok({ success = true, steps = result.steps, errors = result.errors })
end

-- 查询安装状态（前端轮询用）
function api_gnb_install_status()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local gnb_m = require("luci.model.mynet.gnb_installer")
    json_ok({ success = true, data = gnb_m.get_status() })
end
