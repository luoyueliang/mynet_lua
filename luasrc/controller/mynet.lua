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

    -- 节点（单菜单，内含 Config / Node List 标签页）
    entry({"admin", "services", "mynet", "node"},
        call("action_node"),
        _("Node"), 30
    ).dependent = false

    -- 兼容旧子路径
    entry({"admin", "services", "mynet", "node", "config"},
        call("action_node"),
        nil
    ).dependent = false

    entry({"admin", "services", "mynet", "node", "manager"},
        call("action_node_manager"),
        nil
    ).dependent = false

    -- 兼容旧链接
    entry({"admin", "services", "mynet", "nodes"},
        call("action_nodes"),
        nil
    ).dependent = false

    -- 状态（从菜单移除，保留路由兼容）
    entry({"admin", "services", "mynet", "status"},
        call("action_status"),
        nil
    ).dependent = false

    -- 日志（已合并到 Operations tab=log，保留路由兼容）
    entry({"admin", "services", "mynet", "log"},
        call("action_log"),
        nil
    ).dependent = false

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

    -- 诊断（已合并到 Operations tab=diagnose，保留路由兼容）
    entry({"admin", "services", "mynet", "diagnose"},
        call("action_diagnose"),
        nil
    ).dependent = false
    entry({"admin", "services", "mynet", "api", "diagnose"},
        call("api_diagnose"), nil
    ).dependent = false

    -- 运维管理（合并 Service + Network + GNB Monitor）
    entry({"admin", "services", "mynet", "service"},
        call("action_service"),
        _("Operations"), 45
    ).dependent = false
    entry({"admin", "services", "mynet", "service", "op"},
        call("action_service_op"),
        nil
    ).dependent = false

    -- 网络管理（已合并到 Service 页，保留路由）
    entry({"admin", "services", "mynet", "network"},
        call("action_network"),
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
    entry({"admin", "services", "mynet", "api", "node_save_conf"}, call("api_node_save_config")    ).dependent = false
    -- 服务控制 API
    entry({"admin", "services", "mynet", "api", "svc_start"},      call("api_svc_start")           ).dependent = false
    entry({"admin", "services", "mynet", "api", "svc_stop"},       call("api_svc_stop")            ).dependent = false
    entry({"admin", "services", "mynet", "api", "svc_restart"},    call("api_svc_restart")         ).dependent = false
    entry({"admin", "services", "mynet", "api", "mynetd_start"},   call("api_mynetd_start")        ).dependent = false
    entry({"admin", "services", "mynet", "api", "mynetd_stop"},    call("api_mynetd_stop")         ).dependent = false
    entry({"admin", "services", "mynet", "api", "mynetd_restart"}, call("api_mynetd_restart")      ).dependent = false

    -- GNB Monitor（已合并到 Service 页，保留路由）
    entry({"admin", "services", "mynet", "gnb"},
        call("action_gnb_monitor"),
        nil
    ).dependent = false
    entry({"admin", "services", "mynet", "api", "gnb_nodes"}, call("api_gnb_monitor_data")).dependent = false
    -- GNB 自动安装
    entry({"admin", "services", "mynet", "api", "gnb_auto_install"}, call("api_gnb_auto_install")).dependent = false
    entry({"admin", "services", "mynet", "api", "gnb_install_status"}, call("api_gnb_install_status")).dependent = false
    -- GNB 直接启停（节点页 Start/Stop/Restart 按鈕）
    entry({"admin", "services", "mynet", "api", "gnb_start"},   call("api_gnb_start")  ).dependent = false
    entry({"admin", "services", "mynet", "api", "gnb_stop"},    call("api_gnb_stop")   ).dependent = false
    entry({"admin", "services", "mynet", "api", "gnb_restart"}, call("api_gnb_restart")).dependent = false
    -- Pre-flight 校验 + 服务状态
    entry({"admin", "services", "mynet", "api", "preflight"},   call("api_preflight")  ).dependent = false
    entry({"admin", "services", "mynet", "api", "svc_state"},   call("api_svc_state")  ).dependent = false
    -- Heartbeat + Dashboard 统计
    entry({"admin", "services", "mynet", "api", "heartbeat"},       call("api_heartbeat")      ).dependent = false
    entry({"admin", "services", "mynet", "api", "dashboard_stats"}, call("api_dashboard_stats") ).dependent = false
    -- Service detail（日志 + 进程信息）
    entry({"admin", "services", "mynet", "api", "service_detail"},  call("api_service_detail")  ).dependent = false
    entry({"admin", "services", "mynet", "api", "logs_tail"},       call("api_logs_tail")       ).dependent = false
    -- 配置校验
    entry({"admin", "services", "mynet", "api", "validate_config"},  call("api_validate_config")  ).dependent = false
    entry({"admin", "services", "mynet", "api", "auto_repair"},      call("api_auto_repair")      ).dependent = false
    -- 系统依赖（kmod-tun / bash / curl-tls）自动安装
    entry({"admin", "services", "mynet", "api", "install_system_deps"}, call("api_install_system_deps")).dependent = false
    -- 防火墙管理
    entry({"admin", "services", "mynet", "api", "fw_setup"},      call("api_fw_setup")     ).dependent = false
    entry({"admin", "services", "mynet", "api", "fw_teardown"},   call("api_fw_teardown")  ).dependent = false
    entry({"admin", "services", "mynet", "api", "fw_apply_masq"}, call("api_fw_apply_masq")).dependent = false

    -- 插件（Proxy/远程监控等，需登录）
    entry({"admin", "services", "mynet", "proxy"},
        call("action_proxy"),
        _("Plugins"), 56
    ).dependent = false
    entry({"admin", "services", "mynet", "api", "proxy_status"},   call("api_proxy_status")   ).dependent = false
    entry({"admin", "services", "mynet", "api", "proxy_start"},    call("api_proxy_start")    ).dependent = false
    entry({"admin", "services", "mynet", "api", "proxy_stop"},     call("api_proxy_stop")     ).dependent = false
    entry({"admin", "services", "mynet", "api", "proxy_reload"},   call("api_proxy_reload")   ).dependent = false
    entry({"admin", "services", "mynet", "api", "proxy_diagnose"}, call("api_proxy_diagnose") ).dependent = false
    entry({"admin", "services", "mynet", "api", "proxy_config"},   call("api_proxy_config")   ).dependent = false

    -- GNB 离线（Guest）模式（不在菜单显示，Dashboard 入口访问）
    entry({"admin", "services", "mynet", "guest"},
        call("action_guest"),
        nil
    ).dependent = false
    entry({"admin", "services", "mynet", "api", "guest_init"},     call("api_guest_init")     ).dependent = false
    entry({"admin", "services", "mynet", "api", "guest_nodes"},    call("api_guest_nodes")    ).dependent = false
    entry({"admin", "services", "mynet", "api", "guest_add"},      call("api_guest_add_node") ).dependent = false
    entry({"admin", "services", "mynet", "api", "guest_delete"},   call("api_guest_delete")   ).dependent = false
    entry({"admin", "services", "mynet", "api", "guest_export"},   call("api_guest_export")   ).dependent = false
    entry({"admin", "services", "mynet", "api", "guest_use"},      call("api_guest_use")      ).dependent = false
    entry({"admin", "services", "mynet", "api", "guest_start"},    call("api_guest_start")    ).dependent = false
    entry({"admin", "services", "mynet", "api", "guest_stop"},     call("api_guest_stop")     ).dependent = false
    entry({"admin", "services", "mynet", "api", "guest_reset"},    call("api_guest_reset")    ).dependent = false
    entry({"admin", "services", "mynet", "api", "guest_import"},   call("api_guest_import")   ).dependent = false
    entry({"admin", "services", "mynet", "api", "set_mode"},       call("api_set_mode")       ).dependent = false
end

-- ─────────────────────────────────────────────────────────────
-- 私有辅助函数
-- ─────────────────────────────────────────────────────────────

-- ── API Rate Limiting（简单滑动窗口） ──
-- LuCI CGI 每次请求是独立进程，使用文件做持久化。
-- 文件路径: /tmp/mynet_rate/{ip_hash}.json
-- 限制: 登录 10 次/分钟, 普通 API 60 次/分钟
local _RATE_DIR = "/tmp/mynet_rate"

local function _rate_ip_hash(ip)
    -- 简单 hash 避免直接用 IP 做文件名
    local h = 0
    for i = 1, #ip do h = (h * 31 + ip:byte(i)) % 2147483647 end
    return string.format("%x", h)
end

local function check_rate_limit(max_per_min, category)
    local ip = http.getenv("REMOTE_ADDR") or "unknown"
    local key = _rate_ip_hash(ip) .. "_" .. (category or "api")
    util.ensure_dir(_RATE_DIR)
    local fpath = _RATE_DIR .. "/" .. key
    local now = os.time()

    -- 读取现有记录
    local data = util.load_json_file(fpath)
    if not data or type(data.ts) ~= "table" then
        data = { ts = {} }
    end

    -- 清理超过 60 秒的时间戳
    local fresh = {}
    for _, t in ipairs(data.ts) do
        if now - t < 60 then fresh[#fresh + 1] = t end
    end

    if #fresh >= max_per_min then
        return false  -- 超限
    end

    fresh[#fresh + 1] = now
    data.ts = fresh
    util.save_json_file(fpath, data)
    return true
end

-- 确保已登录；未登录则重定向 login，返回 nil
local function require_auth()
    -- Guest 模式无需 MyNet 认证，返回伪凭证让页面正常渲染
    if cfg_m.get_mode() == "guest" then
        return { guest = true, user_email = "Guest" }
    end
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

-- 宽松认证：未登录时以"本地模式"继续渲染（不重定向登录）
local function auth_or_local()
    if cfg_m.get_mode() == "guest" then
        return { guest = true, local_mode = true, user_email = "Guest" }
    end
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then
        local refreshed = auth_m.refresh_token()
        if refreshed then return refreshed end
        return { guest = true, local_mode = true, user_email = "" }
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

-- API 认证 + 频率限制（JSON API 入口统一使用）
-- 返回 credential 或 nil（已输出 JSON 错误）
local function require_api_auth(max_per_min)
    if not check_rate_limit(max_per_min or 60, "api") then
        http.status(429, "Too Many Requests")
        http.prepare_content("application/json")
        http.write(util.json_encode({ success = false, message = "rate limit exceeded" }) or "{}")
        return nil
    end
    -- Guest 模式跳过 MyNet 认证
    if cfg_m.get_mode() == "guest" then
        return { guest = true }
    end
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then
        json_err("not authenticated", 401)
        return nil
    end
    return c
end

-- ─────────────────────────────────────────────────────────────
-- 页面 Actions
-- ─────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────
-- Dashboard
-- ─────────────────────────────────────────────────────────────
function action_index()
    local c = auth_or_local()

    local is_guest      = c.guest == true
    local is_local      = c.local_mode == true
    local zone          = zone_ctx()
    local vpn_status    = node_m.get_vpn_service_status()
    local vpn_iface     = node_m.get_vpn_interface_status()
    local node_id       = cfg_m.get_node_id()
    local enable_out    = util.trim(util.exec("/etc/init.d/mynet enabled 2>/dev/null && echo enabled || echo disabled") or "")
    local router_info   = sys_m.collect_router_info(node_id)

    -- GNB 详细信息（路径、版本、启动时间）
    local gnb_bin_path  = cfg_m.get_gnb_bin()
    local gnb_version   = ""
    if util.file_exists(gnb_bin_path) then
        -- GNB 无参数运行时第一行输出: "GNB version Dev X.Y.Z  protocol version X.Y.Z"
        gnb_version = util.trim(util.exec(gnb_bin_path .. " 2>&1 | head -1") or "")
    end
    local gnb_uptime = ""
    if node_id and router_info and router_info.gnb_pid then
        -- BusyBox 兼容：通过 /proc 计算进程运行时间
        local pid = tostring(router_info.gnb_pid)
        local uptime_raw = util.read_file("/proc/uptime") or ""
        local stat_raw = util.read_file("/proc/" .. pid .. "/stat") or ""
        local sys_uptime = tonumber(uptime_raw:match("^(%S+)"))
        -- /proc/PID/stat 第22字段 = starttime (ticks since boot)
        local starttime
        local after_comm = stat_raw:match("^%d+ %b() (.+)$")
        if after_comm then
            local idx = 0
            for f in after_comm:gmatch("%S+") do
                idx = idx + 1
                if idx == 20 then starttime = tonumber(f); break end  -- field 22 minus pid,comm
            end
        end
        if sys_uptime and starttime then
            local secs = math.floor(sys_uptime - starttime / 100)
            if secs >= 0 then
                local d = math.floor(secs / 86400)
                local h = math.floor((secs % 86400) / 3600)
                local m = math.floor((secs % 3600) / 60)
                local s = secs % 60
                if d > 0 then
                    gnb_uptime = string.format("%dd %02d:%02d:%02d", d, h, m, s)
                else
                    gnb_uptime = string.format("%02d:%02d:%02d", h, m, s)
                end
            end
        end
    end

    -- 节点详细信息（IP, 网卡, 防火墙zone）
    local node_info = nil
    local node_err  = nil
    if node_id and util.int_str(node_id) ~= "0" and not is_guest then
        node_info, node_err = node_m.get_single_node(node_id)
    end

    -- 防火墙信息 + 依赖 + 健康检查
    local fw_info = (router_info and router_info.firewall) and router_info.firewall or sys_m.collect_firewall_info()
    local deps = sys_m.check_deps(node_id)
    local health_issues = sys_m.run_health_check(node_id, vpn_status, fw_info, deps)

    tmpl.render("mynet/index", {
        user_email    = c.user_email,
        is_guest      = is_guest,
        is_local      = is_local,
        zone          = zone,
        node_id       = node_id,
        vpn_status    = vpn_status,
        vpn_iface     = vpn_iface,
        vpn_type      = cfg_m.get_vpn_type(),
        enable_status = enable_out,
        router_info   = router_info,
        gnb_bin_path  = gnb_bin_path,
        gnb_version   = gnb_version,
        gnb_uptime    = gnb_uptime,
        node_info     = node_info,
        node_err      = node_err,
        health_issues = health_issues,
    })
end

-- 登录页（GET 显示，POST 处理）
function action_login()
    -- 已登录（非 guest 模式）且是 GET → 跳转控制台
    local c = cred_m.load()
    local is_guest = cfg_m.get_mode() == "guest"
    if c and cred_m.is_valid(c) and not is_guest and http.getenv("REQUEST_METHOD") ~= "POST" then
        http.redirect(disp.build_url("admin/services/mynet/index"))
        return
    end

    local err_msg  = nil
    local prefill  = ""

    if http.getenv("REQUEST_METHOD") == "POST" then
        -- 登录频率限制: 10 次/分钟
        if not check_rate_limit(10, "login") then
            err_msg = "Too many login attempts. Please wait a moment."
            tmpl.render("mynet/login", { login_error = err_msg, prefill_email = prefill })
            return
        end

        local email    = util.trim(http.formvalue("email")    or "")
        local password = util.trim(http.formvalue("password") or "")
        prefill = email

        local new_cred, login_err = auth_m.login(email, password)
        if login_err then
            err_msg = login_err
        else
            -- 如果之前是 guest 模式，切换回在线模式
            if is_guest then
                cfg_m.set_mode("online")
            end
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

    local is_guest   = c.guest == true
    local zone = zone_ctx()

    local node_id    = cfg_m.get_node_id()

    -- 节点未配置且非手动配置模式 → 跳转向导
    local tab_param = http.formvalue("tab")
    if (not node_id or util.int_str(node_id) == "0") and tab_param ~= "config" then
        http.redirect(disp.build_url("admin/services/mynet/wizard"))
        return
    end
    local node_info  = nil
    local node_err   = nil
    local local_cfgs = {}
    local priv_key   = nil
    local peer_keys  = {}
    local peer_count = 0
    local active_count = 0

    -- 当前节点详情
    if node_id and util.int_str(node_id) ~= "0" then
        if not is_guest then
            node_info, node_err = node_m.get_single_node(node_id)
        end
        local_cfgs           = node_m.read_local_configs(node_id)
        priv_key             = node_m.get_private_key(node_id)
        peer_keys            = node_m.get_peer_keys(node_id)
        peer_count           = #peer_keys

        -- 获取活跃对端数量
        local gnb_ctl = util.GNB_DRIVER_ROOT .. "/bin/gnb_ctl"
        local gnb_map = util.GNB_CONF_DIR .. "/" .. util.int_str(node_id) .. "/gnb.map"
        if util.file_exists(gnb_ctl) and util.file_exists(gnb_map) then
            local cmd = "cd '" .. util.GNB_DRIVER_ROOT .. "' && ./bin/gnb_ctl -s -b 'conf/"
                .. util.int_str(node_id) .. "/gnb.map' 2>&1"
            local output = util.exec(cmd) or ""
            local gnb_nodes = sys_m.parse_gnb_nodes(output)
            for _, n in ipairs(gnb_nodes) do
                if not n.is_local and (n.conn_status == "Direct" or n.conn_status == "InDirect") then
                    active_count = active_count + 1
                end
            end
        end
    end

    -- 获取 VPN 接口信息
    local router_info = sys_m.collect_router_info(node_id)

    -- Tab 切换 (config / list)
    local node_tab = http.formvalue("tab") or "config"
    local local_peers = nil
    if node_tab == "list" and node_id and util.int_str(node_id) ~= "0" then
        local_peers = node_m.get_local_peers(node_id)
    end

    tmpl.render("mynet/node", {
        zone         = zone,
        node_id      = node_id,
        node_info    = node_info,
        node_err     = node_err,
        local_cfgs   = local_cfgs,
        priv_key     = priv_key,
        peer_keys    = peer_keys,
        peer_count   = peer_count,
        active_count = active_count,
        vpn_status   = node_m.get_vpn_service_status(),
        user_email   = c.user_email,
        is_guest     = is_guest,
        router_info  = router_info,
        node_tab     = node_tab,
        local_peers  = local_peers,
    })
end

-- 节点管理页（已合并到 node 页 tab=list，保留向后兼容）
function action_node_manager()
    http.redirect(disp.build_url("admin/services/mynet/node") .. "?tab=list")
end

-- 兼容旧链接
function action_nodes()
    http.redirect(disp.build_url("admin/services/mynet/node") .. "?tab=list")
end

-- 状态页（已移除，重定向到 Dashboard）
function action_status()
    http.redirect(disp.build_url("admin/services/mynet/index"))
end

-- 设置页（简化：只有 use_system_gnb 开关）
function action_settings()
    local c = require_auth()
    if not c then return end

    local is_guest = c.guest == true
    local gnb = cfg_m.load_gnb_config()
    local system_gnb_exists = util.file_exists(gnb.system_gnb_path)
    local bundled_gnb_exists = util.file_exists(gnb.gnb_bin_path)

    -- 获取各 GNB 二进制版本
    local bundled_gnb_version = ""
    if bundled_gnb_exists then
        bundled_gnb_version = util.trim(util.exec(gnb.gnb_bin_path .. " 2>&1 | head -1") or "")
    end
    local system_gnb_version = ""
    if system_gnb_exists then
        system_gnb_version = util.trim(util.exec(gnb.system_gnb_path .. " 2>&1 | head -1") or "")
    end

    tmpl.render("mynet/settings", {
        user_email           = c.user_email,
        is_guest             = is_guest,
        app_version          = util.APP_VERSION,
        mynet_home           = util.MYNET_HOME,
        use_system_gnb       = gnb.use_system_gnb,
        system_gnb_path      = gnb.system_gnb_path,
        gnb_bin_path         = gnb.gnb_bin_path,
        system_gnb_exists    = system_gnb_exists,
        bundled_gnb_exists   = bundled_gnb_exists,
        bundled_gnb_version  = bundled_gnb_version,
        system_gnb_version   = system_gnb_version,
    })
end

-- 保存设置（POST）— 简化版
function action_settings_save()
    local c = require_auth()
    if not c then return end

    local use_system_gnb = http.formvalue("use_system_gnb") == "1"
    local gnb = cfg_m.load_gnb_config()
    cfg_m.save_gnb_config(
        gnb.gnb_root,
        gnb.gnb_bin_path,
        gnb.system_gnb_path,
        use_system_gnb
    )
    http.redirect(disp.build_url("admin/services/mynet/settings"))
end

-- 诊断页
function action_diagnose()
    local lines = http.formvalue("lines") or ""
    http.redirect(disp.build_url("admin/services/mynet/service") .. "?tab=diagnose")
end

-- 向导页（首次配置引导）
function action_wizard()
    local node_id = cfg_m.get_node_id()
    local has_node = node_id and util.int_str(node_id) ~= "0"

    -- 如果没有节点且没有登录凭证 → 显示模式选择首页
    local c = cred_m.load()
    local has_cred = c and cred_m.is_valid(c)

    -- 显式请求 landing 页（或无凭证时自动显示）
    local req_tab = http.formvalue("tab")
    if req_tab == "landing" or (not has_cred and not has_node) then
        local gnb_bin = cfg_m.get_gnb_bin()
        tmpl.render("mynet/wizard", {
            active_tab    = "landing",
            gnb_installed = util.file_exists(gnb_bin),
        })
        return
    end

    -- Guest 模式跳转 Guest 页
    if cfg_m.get_mode() == "guest" then
        http.redirect(disp.build_url("admin/services/mynet/guest"))
        return
    end

    -- 在线模式需要登录
    if not has_cred then
        http.redirect(disp.build_url("admin/services/mynet/login"))
        return
    end

    local zone    = cfg_m.load_current_zone()
    local node_id = cfg_m.get_node_id()
    local has_zone = zone and tostring(zone.zone_id) ~= "0"

    -- 加载 zones（永远需要）
    local zones, zone_err = zone_m.get_zones()

    -- 单 zone 自动选择：如果只有 1 个 zone 且尚未选择，自动写入
    if not has_zone and zones and #zones == 1 and not zone_err then
        local z = zones[1]
        local zid = z.zone_id or z.id or 0
        local zname = z.zone_name or z.name or ""
        cfg_m.save_current_zone(zid, zname)
        zone = cfg_m.load_current_zone()
        has_zone = zone and tostring(zone.zone_id) ~= "0"
    end

    -- 加载 nodes（仅当 zone 已选择时）
    local nodes_data, node_err
    if has_zone then
        local pg = tonumber(http.formvalue("page")) or 1
        nodes_data, node_err = node_m.get_nodes(pg, 20)
    end

    -- 自动跳到第一个未完成步骤（用户未显式指定 tab 时）
    local has_node = (node_id ~= nil and node_id ~= 0)
    local active_tab = http.formvalue("tab")
    if not active_tab or active_tab == "" then
        if not has_zone then
            active_tab = "zone"
        elseif not has_node then
            active_tab = "node"
        else
            active_tab = "account"
        end
    end

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

    -- 写入完整 mynet.conf（含 NODE_ID + 所有路径配置）
    cfg_m.generate_mynet_conf(node_id_num)
    -- 下载节点配置文件（优先 bundle API）
    node_m.refresh_configs_bundle(node_id_num)

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

-- 读取 mynet 防火墙 NAT 状态
local function read_nat_state()
    local fw_dump = util.exec("uci show firewall 2>/dev/null") or ""
    local nat_out, nat_in = false, false

    -- 出站NAT: mynet zone 的 masq 标志
    local zone_sec = fw_dump:match("(firewall%.@zone%[%d+%])%.name='mynet'")
    if zone_sec then
        local masq_pat = zone_sec:gsub("([%[%]])", "%%%1") .. "%.masq='(%d)'"
        nat_out = (fw_dump:match(masq_pat) == "1")
    end

    -- 入站NAT: 检查 mynet→lan 转发规则
    local fwd_map = {}
    for sec, key, val in fw_dump:gmatch("(firewall%.@forwarding%[%d+%])%.(%w+)='([^']+)'") do
        fwd_map[sec] = fwd_map[sec] or {}
        fwd_map[sec][key] = val
    end
    for _, f in pairs(fwd_map) do
        if f.src == "mynet" and f.dest == "lan" then
            nat_in = true
            break
        end
    end

    return nat_out, nat_in
end

-- 查找 service-manager.sh 路径
local function find_svc_mgr()
    local paths = {
        util.MYNET_HOME .. "/scripts/_src/openwrt/service-manager.sh",
        util.MYNET_HOME .. "/scripts/service-manager.sh",
        "/usr/share/mynet/service-manager.sh",
    }
    for _, p in ipairs(paths) do
        if util.file_exists(p) then return p end
    end
    return nil
end



function action_service()
    local c = auth_or_local()

    local is_guest = c.guest == true
    local enable_out      = util.trim(util.exec("/etc/init.d/mynet enabled 2>/dev/null && echo enabled || echo disabled") or "")

    local valid_tabs = { status=true, network=true, peers=true, log=true, diagnose=true }
    local active_tab = http.formvalue("tab") or "status"
    -- 兼容旧 tab 名
    if active_tab == "route" or active_tab == "firewall" then active_tab = "network" end
    if not valid_tabs[active_tab] then active_tab = "status" end

    -- 网络相关数据（network 标签按需加载：路由 + NAT 状态 + 防火墙区域）
    local route_conf, ip_route, nat_outbound, nat_inbound, fw_info
    if active_tab == "network" then
        route_conf = util.trim(util.read_file(util.CONF_DIR .. "/route.conf") or "")
        ip_route   = util.trim(util.exec("ip route show 2>/dev/null") or "")
        nat_outbound, nat_inbound = read_nat_state()
        fw_info = sys_m.collect_firewall_info()
    end

    -- GNB Peers 数据（peers 标签按需加载）
    local gnb_nodes, gnb_err, gnb_raw, gnb_ctl_path, gnb_map_path
    if active_tab == "peers" then
        local node_id  = cfg_m.get_node_id()
        local gnb_root = util.GNB_DRIVER_ROOT
        gnb_ctl_path   = gnb_root .. "/bin/gnb_ctl"
        gnb_map_path   = (node_id and util.int_str(node_id) ~= "0")
            and gnb_root .. "/conf/" .. util.int_str(node_id) .. "/gnb.map" or nil

        if not util.file_exists(gnb_ctl_path) then
            gnb_err = "gnb_ctl not found: " .. gnb_ctl_path
        elseif not gnb_map_path or not util.file_exists(gnb_map_path) then
            gnb_err = gnb_map_path and ("gnb.map not found: " .. gnb_map_path) or "No node_id configured"
        else
            local cmd = "cd '" .. gnb_root .. "' && ./bin/gnb_ctl -s -b 'conf/" .. util.int_str(node_id) .. "/gnb.map' 2>&1"
            gnb_raw   = util.exec(cmd) or ""
            gnb_nodes = sys_m.parse_gnb_nodes(gnb_raw)
        end
    end

    -- Log 数据（log 标签按需加载）
    local log_content, log_path, log_lines
    if active_tab == "log" then
        log_lines   = tonumber(http.formvalue("lines")) or 200
        if log_lines > 1000 then log_lines = 1000 end
        log_path    = util.MYNET_HOME .. "/logs/luci.log"
        log_content = util.trim(util.exec("tail -" .. tostring(log_lines) .. " " .. log_path .. " 2>/dev/null") or "")
    end

    -- Diagnose 数据
    local diag_node_id
    if active_tab == "diagnose" then
        diag_node_id = cfg_m.get_node_id()
    end

    tmpl.render("mynet/service", {
        active_tab         = active_tab,
        vpn_status         = node_m.get_vpn_service_status(),
        vpn_iface          = node_m.get_vpn_interface_status(),
        enable_status      = enable_out,
        user_email         = c.user_email,
        is_guest           = is_guest,
        -- 网络数据
        route_conf          = route_conf,
        ip_route            = ip_route,
        nat_outbound        = nat_outbound,
        nat_inbound         = nat_inbound,
        fw_info             = fw_info,
        -- GNB Peers 数据
        gnb_nodes           = gnb_nodes,
        gnb_err             = gnb_err,
        gnb_raw             = gnb_raw,
        gnb_ctl             = gnb_ctl_path,
        gnb_map             = gnb_map_path,
        gnb_ts              = os.time(),
        -- Log 数据
        log_content         = log_content,
        log_path            = log_path,
        log_lines           = log_lines,
        -- Diagnose 数据
        diag_node_id        = diag_node_id,
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
        local valid_ops = { start=true, stop=true, restart=true, enable=true, disable=true }
        if not valid_ops[op] then
            err_msg = "invalid operation: " .. (op or "nil")
        else
            -- 联动：启动/重启前自动确保防火墙 zone 存在
            if op == "start" or op == "restart" then
                local fw_ok, fw_msg = sys_m.ensure_firewall_zone()
                if not fw_ok then
                    -- 不阻断启动，仅记录警告
                    ok_msg = "⚠ 防火墙自动配置失败: " .. (fw_msg or "") .. "\n"
                end
            end
            local res, code = util.exec_status("/etc/init.d/mynet " .. op .. " 2>&1")
            if op == "enable" or op == "disable" then
                ok_msg = (ok_msg or "") .. "mynet " .. op .. " ok"
            else
                local detail = util.trim(res or "") ~= "" and util.trim(res) or "ok"
                ok_msg = (ok_msg or "") .. "mynet " .. op .. ": " .. detail
                if code ~= 0 then err_msg = ok_msg; ok_msg = nil end
            end
        end
    -- 网络操作（从原 network_op 合并）
    elseif service == "network" then
        if op == "reload_route" then
            local script = find_svc_mgr()
            if script then
                local out, code = util.exec_status("sh " .. script .. " restart 2>&1")
                ok_msg = "route apply: " .. (util.trim(out or "") ~= "" and util.trim(out) or "ok")
                if code ~= 0 then err_msg = ok_msg; ok_msg = nil end
            else
                err_msg = "service-manager.sh not found"
            end
        elseif op == "reload_fw" then
            local fw_script = "/etc/mynet/scripts/firewall.mynet"
            if util.file_exists(fw_script) then
                local out, code = util.exec_status("sh " .. fw_script .. " 2>&1")
                ok_msg = "firewall apply: " .. (util.trim(out or "") ~= "" and util.trim(out) or "ok")
                if code ~= 0 then err_msg = ok_msg; ok_msg = nil end
            else
                err_msg = "firewall.mynet not found"
            end
        elseif op == "reload_fw_commit" then
            local out, code = util.exec_status("uci commit firewall && /etc/init.d/firewall reload 2>&1")
            ok_msg = "fw reload: " .. (util.trim(out or "") ~= "" and util.trim(out) or "ok")
            if code ~= 0 then err_msg = ok_msg; ok_msg = nil end
        elseif op == "initd_enable" then
            util.exec_status("/etc/init.d/mynet enable 2>&1")
            ok_msg = "autostart enabled"
        elseif op == "initd_disable" then
            util.exec_status("/etc/init.d/mynet disable 2>&1")
            ok_msg = "autostart disabled"
        elseif op == "set_nat" then
            local nat_type = http.formvalue("nat_type") or ""
            local val = (http.formvalue("value") == "1") and "1" or "0"

            if nat_type == "outbound" then
                local fw_dump = util.exec("uci show firewall 2>/dev/null") or ""
                local zone_sec = fw_dump:match("(firewall%.@zone%[%d+%])%.name='mynet'")
                if zone_sec then
                    util.exec("uci set " .. zone_sec .. ".masq=" .. val .. " 2>/dev/null")
                    util.exec("uci commit firewall && /etc/init.d/firewall reload 2>/dev/null")
                    ok_msg = "出站NAT " .. (val == "1" and "已启用" or "已禁用")
                else
                    err_msg = "未找到 mynet 防火墙区域"
                end
            elseif nat_type == "inbound" then
                if val == "1" then
                    -- 添加 mynet→lan 转发（如不存在）
                    local _, cur_in = read_nat_state()
                    if not cur_in then
                        util.exec("uci add firewall forwarding 2>/dev/null")
                        util.exec("uci set firewall.@forwarding[-1].src='mynet' 2>/dev/null")
                        util.exec("uci set firewall.@forwarding[-1].dest='lan' 2>/dev/null")
                    end
                else
                    -- 删除 mynet→lan 转发
                    for i = 20, 0, -1 do
                        local src  = util.trim(util.exec("uci -q get firewall.@forwarding[" .. i .. "].src 2>/dev/null") or "")
                        local dest = util.trim(util.exec("uci -q get firewall.@forwarding[" .. i .. "].dest 2>/dev/null") or "")
                        if src == "mynet" and dest == "lan" then
                            util.exec("uci delete firewall.@forwarding[" .. i .. "] 2>/dev/null")
                        end
                    end
                end
                util.exec("uci commit firewall && /etc/init.d/firewall reload 2>/dev/null")
                ok_msg = "入站NAT " .. (val == "1" and "已启用" or "已禁用")
            else
                err_msg = "未知的 NAT 类型"
            end
        elseif op == "svc_status" or op == "svc_start" or op == "svc_stop" or op == "svc_restart" then
            local mgr = find_svc_mgr()
            if mgr then
                local cmd_map = { svc_status="status", svc_start="start", svc_stop="stop", svc_restart="restart" }
                local out, code = util.exec_status("sh " .. mgr .. " " .. cmd_map[op] .. " 2>&1")
                ok_msg = util.trim(out or "")
                if code ~= 0 then err_msg = ok_msg; ok_msg = nil end
            else
                err_msg = "service-manager.sh not found"
            end
        elseif op == "fw_setup" then
            local fw_ok, fw_msg = sys_m.ensure_firewall_zone()
            if fw_ok then
                ok_msg = "防火墙配置完成: " .. (fw_msg or "")
            else
                err_msg = "防火墙配置失败: " .. (fw_msg or "")
            end
        elseif op == "fw_teardown" then
            local fw_ok, fw_msg = sys_m.remove_firewall_zone()
            if fw_ok then
                ok_msg = "防火墙已清除: " .. (fw_msg or "")
            else
                err_msg = "防火墙清除失败: " .. (fw_msg or "")
            end
        elseif op == "fw_apply_masq" then
            local fw_ok, fw_msg = sys_m.apply_firewall_masq()
            if fw_ok then
                ok_msg = "Masq 规则已应用: " .. (fw_msg or "")
            else
                err_msg = "Masq 应用失败: " .. (fw_msg or "")
            end
        end
    end

    -- 短暂等待让进程状态更新
    os.execute("sleep 1")

    -- AJAX 请求返回 JSON
    if http.formvalue("_ajax") == "1" then
        if err_msg then
            json_err(err_msg)
        else
            json_ok({ message = ok_msg or "ok" })
        end
        return
    end

    -- 按需加载网络数据
    local route_conf, ip_route, nat_outbound, nat_inbound, fw_info
    if tab == "network" or tab == "route" or tab == "firewall" then
        tab = "network"  -- 兼容旧 tab 名
        route_conf      = util.trim(util.read_file(util.CONF_DIR .. "/route.conf") or "")
        ip_route        = util.trim(util.exec("ip route show 2>/dev/null") or "")
        nat_outbound, nat_inbound = read_nat_state()
        fw_info = sys_m.collect_firewall_info()
    end

    tmpl.render("mynet/service", {
        active_tab         = tab,
        vpn_status         = node_m.get_vpn_service_status(),
        vpn_iface          = node_m.get_vpn_interface_status(),
        enable_status      = util.trim(util.exec("/etc/init.d/mynet enabled 2>/dev/null && echo enabled || echo disabled") or ""),
        op_result          = { ok = (err_msg == nil), msg = err_msg or ok_msg or "" },
        user_email         = c.user_email,
        is_guest           = (c.guest == true),
        -- 网络数据
        route_conf          = route_conf,
        ip_route            = ip_route,
        nat_outbound        = nat_outbound,
        nat_inbound         = nat_inbound,
        fw_info             = fw_info,
    })
end

-- 网络管理页（重定向到 Operations 页）
function action_network()
    local c = require_auth()
    if not c then return end
    local tab = http.formvalue("tab") or "route"
    http.redirect(disp.build_url("admin/services/mynet/service") .. "?tab=" .. tab)
end

-- 日志页（从 Operations 提取为独立页面）
function action_log()
    local lines = http.formvalue("lines") or ""
    local qs = "tab=log"
    if lines ~= "" then qs = qs .. "&lines=" .. lines end
    http.redirect(disp.build_url("admin/services/mynet/service") .. "?" .. qs)
end

-- ─────────────────────────────────────────────────────────────
-- AJAX / JSON API Actions
-- ─────────────────────────────────────────────────────────────

function api_get_status()
    if not require_api_auth() then return end

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
    if not require_api_auth() then return end

    local ok, code = node_m.start_vpn()
    json_ok({ success = ok, message = ok and "VPN started" or ("start failed: code=" .. tostring(code)) })
end

function api_vpn_stop()
    if not require_api_auth() then return end

    local ok, code = node_m.stop_vpn()
    json_ok({ success = ok, message = ok and "VPN stopped" or ("stop failed: code=" .. tostring(code)) })
end

function api_vpn_restart()
    if not require_api_auth() then return end

    local ok, code = node_m.restart_vpn()
    json_ok({ success = ok, message = ok and "VPN restarted" or ("restart failed: code=" .. tostring(code)) })
end

-- GNB 直接启停（node 页 Start/Stop/Restart 按鈕）
function api_gnb_start()
    if not require_api_auth() then return end
    local raw_nid = http.formvalue("node_id") or ""
    if not util.validate_node_id(raw_nid) then json_err("invalid node_id"); return end
    local node_id = tonumber(raw_nid)
    if not node_id then json_err("node_id required"); return end
    local ok, err = node_m.start_gnb(node_id)
    if ok then
        json_ok({ success = true, message = "GNB started" })
    else
        json_ok({ success = false, message = err or "start failed" })
    end
end

function api_gnb_stop()
    if not require_api_auth() then return end
    local raw_nid = http.formvalue("node_id") or ""
    if not util.validate_node_id(raw_nid) then json_err("invalid node_id"); return end
    local node_id = tonumber(raw_nid)
    if not node_id then json_err("node_id required"); return end
    node_m.stop_gnb(node_id)
    json_ok({ success = true, message = "GNB stopped" })
end

function api_gnb_restart()
    if not require_api_auth() then return end
    local raw_nid = http.formvalue("node_id") or ""
    if not util.validate_node_id(raw_nid) then json_err("invalid node_id"); return end
    local node_id = tonumber(raw_nid)
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

    local raw_nid = http.formvalue("node_id") or ""
    if not util.validate_node_id(raw_nid) then json_err("invalid node_id"); return end
    local node_id     = tonumber(raw_nid)
    local config_type = http.formvalue("type") or "all"
    if not node_id then json_err("node_id required"); return end

    if config_type == "all" then
        -- 优先 bundle API，自动 fallback
        local results = node_m.refresh_configs_bundle(node_id)
        json_ok({ success = results.ok, files = results.files, errors = results.errors, method = results.method })
    else
        local res = node_m.refresh_single_config(node_id, config_type)
        json_ok({ success = res.ok, file = res.file, error = res.error })
    end
end

-- 保存私钥 API（POST: node_id, key_hex）
function api_node_save_key()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local raw_nid = http.formvalue("node_id") or ""
    if not util.validate_node_id(raw_nid) then json_err("invalid node_id"); return end
    local node_id = tonumber(raw_nid)
    local key_hex = util.trim(http.formvalue("key_hex") or "")
    if not node_id then json_err("node_id required"); return end
    if not util.validate_hex(key_hex, 128) then json_err("key_hex must be 128 hex chars"); return end

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

    local raw_nid = http.formvalue("node_id") or ""
    if not util.validate_node_id(raw_nid) then json_err("invalid node_id"); return end
    local node_id = tonumber(raw_nid)
    if not node_id then json_err("node_id required"); return end

    cfg_m.generate_mynet_conf(node_id)
    node_m.refresh_configs_bundle(node_id)
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

    local raw_nid = http.formvalue("node_id") or ""
    if not util.validate_node_id(raw_nid) then json_err("invalid node_id"); return end
    local node_id = tonumber(raw_nid)
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

-- 保存节点配置文件（address.conf / route.conf / node.conf）
function api_node_save_config()
    if not require_api_auth() then return end

    local config_type = http.formvalue("config_type") or ""
    local content     = http.formvalue("content") or ""

    local valid_types = { address = true, route = true, node = true }
    if not valid_types[config_type] then
        json_err("invalid config_type: must be address, route, or node"); return
    end

    local node_id = cfg_m.get_node_id()
    local has_node = node_id and util.int_str(node_id) ~= "0"

    -- node.conf 特殊处理：从内容中提取 nodeid，支持无节点时的初始化
    if config_type == "node" then
        local extracted_nid = content:match("^%s*nodeid%s+(%d+)")
                           or content:match("\n%s*nodeid%s+(%d+)")
        if not extracted_nid or extracted_nid == "" then
            json_err("node.conf must contain a 'nodeid' line"); return
        end
        local extracted_num = tonumber(extracted_nid)
        if not extracted_num or extracted_num <= 0 then
            json_err("invalid nodeid value"); return
        end

        if not has_node then
            -- 首次设置：创建目录并写入 node.conf，然后设为当前节点
            local nid_str = util.int_str(extracted_num)
            local conf_dir = util.GNB_CONF_DIR .. "/" .. nid_str
            util.exec("mkdir -p " .. conf_dir)
            local target = conf_dir .. "/node.conf"
            local ok, werr = util.write_file(target, content)
            if not ok then
                json_err("write failed: " .. (werr or "unknown")); return
            end
            cfg_m.generate_mynet_conf(extracted_num)
            json_ok({ success = true, message = "node.conf saved, node set to #" .. nid_str,
                       path = target, node_id_set = nid_str })
            return
        else
            -- 已有节点：检查 nodeid 一致性
            local cur_nid_str = util.int_str(node_id)
            local ext_nid_str = util.int_str(extracted_num)
            local warning = nil
            if cur_nid_str ~= ext_nid_str then
                warning = "node.conf nodeid (" .. ext_nid_str .. ") does not match current node (" .. cur_nid_str .. ")"
            end
            -- 仍然保存到当前节点目录
            local cfgs = node_m.read_local_configs(node_id)
            local target = cfgs.node_conf_path
            if not target then
                json_err("cannot resolve node.conf path"); return
            end
            local ok, werr = util.write_file(target, content)
            if not ok then
                json_err("write failed: " .. (werr or "unknown")); return
            end
            local resp = { success = true, message = "node.conf saved", path = target }
            if warning then resp.warning = warning end
            json_ok(resp)
            return
        end
    end

    -- address.conf / route.conf 需要已有节点
    if not has_node then
        json_err("no node configured – save node.conf first"); return
    end

    local cfgs = node_m.read_local_configs(node_id)
    local path_map = {
        address = cfgs.addr_path,
        route   = cfgs.route_path,
    }
    local target_path = path_map[config_type]
    if not target_path then
        json_err("cannot resolve config path"); return
    end

    -- route.conf 验证：第一条记录的 nodeid 应与当前节点一致
    local warning = nil
    if config_type == "route" then
        local cur_nid_str = util.int_str(node_id)
        for line in content:gmatch("[^\n]+") do
            local stripped = line:gsub("#.*$", ""):match("^%s*(.-)%s*$")
            if stripped ~= "" then
                local first_field = stripped:match("^([^|]+)")
                if first_field then
                    first_field = first_field:match("^%s*(.-)%s*$")
                    if first_field ~= cur_nid_str then
                        warning = "route.conf first record node (" .. first_field .. ") does not match current node (" .. cur_nid_str .. ")"
                    end
                end
                break
            end
        end
    end

    local ok, werr = util.write_file(target_path, content)
    if not ok then
        json_err("write failed: " .. (werr or "unknown")); return
    end

    local resp = { success = true, message = config_type .. ".conf saved", path = target_path }
    if warning then resp.warning = warning end
    json_ok(resp)
end

-- ─────────────────────────────────────────────────────────────
-- 服务控制 API（Dashboard 快速按钮用）
-- ─────────────────────────────────────────────────────────────

function api_svc_start()
    if not require_api_auth() then return end
    local _, code = util.exec_status("/etc/init.d/mynet start 2>&1")
    json_ok({ success = code == 0, message = code == 0 and "mynet started" or ("start failed (code=" .. tostring(code) .. ")") })
end

function api_svc_stop()
    if not require_api_auth() then return end
    local _, code = util.exec_status("/etc/init.d/mynet stop 2>&1")
    json_ok({ success = code == 0, message = code == 0 and "mynet stopped" or ("stop failed (code=" .. tostring(code) .. ")") })
end

function api_svc_restart()
    if not require_api_auth() then return end
    local _, code = util.exec_status("/etc/init.d/mynet restart 2>&1")
    json_ok({ success = code == 0, message = code == 0 and "mynet restarted" or ("restart failed (code=" .. tostring(code) .. ")") })
end

function api_mynetd_start()
    if not require_api_auth() then return end
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
    if not require_api_auth() then return end
    local _, pid = get_mynetd_status()
    if pid then util.exec_status("kill " .. pid .. " 2>/dev/null") end
    util.exec_status("pkill -x mynetd 2>/dev/null")
    json_ok({ success = true, message = "mynetd stopped" })
end

function api_mynetd_restart()
    if not require_api_auth() then return end
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
-- Pre-flight 校验 + 服务状态 API
-- ─────────────────────────────────────────────────────────────

function api_preflight()
    if not require_api_auth() then return end
    local raw_nid = http.formvalue("node_id") or ""
    local node_id
    if raw_nid ~= "" then
        if not util.validate_node_id(raw_nid) then json_err("invalid node_id"); return end
        node_id = tonumber(raw_nid)
    else
        node_id = cfg_m.get_node_id()
    end
    if not node_id then json_err("node_id required"); return end
    local result = node_m.preflight_check(node_id)
    json_ok({ success = true, data = result })
end

function api_svc_state()
    if not require_api_auth() then return end
    local s = node_m.get_svc_state()
    json_ok({ success = true, data = s })
end

-- ─────────────────────────────────────────────────────────────
-- Heartbeat API — 触发一次心跳上报
-- ─────────────────────────────────────────────────────────────

function api_heartbeat()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end
    local raw_nid = http.formvalue("node_id") or ""
    local node_id
    if raw_nid ~= "" then
        if not util.validate_node_id(raw_nid) then json_err("invalid node_id"); return end
        node_id = tonumber(raw_nid)
    else
        node_id = cfg_m.get_node_id()
    end
    if not node_id then json_err("node_id required"); return end
    local ok, err = sys_m.submit_heartbeat(node_id)
    if ok then
        json_ok({ success = true, message = "heartbeat sent" })
    else
        json_ok({ success = false, message = err or "heartbeat failed" })
    end
end

-- ─────────────────────────────────────────────────────────────
-- Dashboard 统计 API（Phase 4.1）
-- ─────────────────────────────────────────────────────────────

function api_dashboard_stats()
    if not require_api_auth() then return end

    local node_id = cfg_m.get_node_id()
    local metrics = sys_m.collect_metrics(node_id)
    local svc     = node_m.get_svc_state()

    -- 快速 gnb peer 查询
    local peer_nodes = {}
    if node_id and util.int_str(node_id) ~= "0" then
        local gnb_ctl = util.GNB_DRIVER_ROOT .. "/bin/gnb_ctl"
        local gnb_map = util.GNB_CONF_DIR .. "/" .. util.int_str(node_id) .. "/gnb.map"
        if util.file_exists(gnb_ctl) and util.file_exists(gnb_map) then
            local cmd = "cd '" .. util.GNB_DRIVER_ROOT .. "' && ./bin/gnb_ctl -s -b 'conf/"
                .. util.int_str(node_id) .. "/gnb.map' 2>&1"
            local output = util.exec(cmd) or ""
            peer_nodes = sys_m.parse_gnb_nodes(output)
        end
    end

    json_ok({
        success   = true,
        metrics   = metrics,
        svc_state = svc,
        peers     = #peer_nodes,
        node_id   = node_id,
    })
end

-- ─────────────────────────────────────────────────────────────
-- Service Detail API（Phase 4.2 — 日志 + 进程信息）
-- ─────────────────────────────────────────────────────────────

function api_service_detail()
    if not require_api_auth() then return end

    local node_id = cfg_m.get_node_id()
    local svc     = node_m.get_svc_state()
    local preflight = nil
    if node_id then
        preflight = node_m.preflight_check(node_id)
    end

    -- gnb 进程信息
    local gnb_info = {}
    if node_id and node_m.gnb_is_running(node_id) then
        local pidfile = util.GNB_CONF_DIR .. "/" .. util.int_str(node_id) .. "/gnb.pid"
        local pid_str = util.trim(util.read_file(pidfile) or "")
        gnb_info.pid = pid_str
        -- 进程运行时长
        local ps_out = util.trim(util.exec("ps -o etime= -p " .. pid_str .. " 2>/dev/null") or "")
        gnb_info.elapsed = ps_out
        -- RSS 内存
        local rss = util.trim(util.exec("ps -o rss= -p " .. pid_str .. " 2>/dev/null") or "0")
        gnb_info.rss_kb = tonumber(rss) or 0
    end

    json_ok({
        success   = true,
        svc_state = svc,
        preflight = preflight,
        gnb_info  = gnb_info,
        mynetd    = { status = (select(1, sys_m.get_mynetd_status())), pid = (select(2, sys_m.get_mynetd_status())) },
    })
end

-- 日志尾部 API
function api_logs_tail()
    if not require_api_auth() then return end
    local lines = tonumber(http.formvalue("lines")) or 100
    if lines > 500 then lines = 500 end
    local log_path = util.MYNET_HOME .. "/logs/luci.log"
    local content = util.trim(util.exec("tail -" .. tostring(lines) .. " " .. log_path .. " 2>/dev/null") or "")
    json_ok({ success = true, log = content, path = log_path })
end

-- ─────────────────────────────────────────────────────────────
-- 配置校验 API（Phase 6）
-- ─────────────────────────────────────────────────────────────

function api_validate_config()
    if not require_api_auth() then return end
    local validator = require("luci.model.mynet.validator")
    local result = validator.validate_config()
    json_ok({ success = true, data = result })
end

function api_auto_repair()
    if not require_api_auth() then return end
    local validator = require("luci.model.mynet.validator")
    local issues = validator.validate_config()
    local repair = validator.auto_repair(issues)
    -- 重新校验修复后的状态
    local after = validator.validate_config()
    json_ok({ success = true, repair = repair, after = after })
end

-- 诊断 API：检查文件完整性、运行测试、GNB 启动状态
function api_diagnose()
    if not require_api_auth() then return end

    local checks = {}
    local node_id = cfg_m.get_node_id()
    local all_ok = true

    local function add(name, ok, detail)
        checks[#checks + 1] = { name = name, ok = ok, detail = detail or "" }
        if not ok then all_ok = false end
    end

    -- 1. node_id 已配置
    local has_nid = node_id and util.int_str(node_id) ~= "0"
    add("node_id", has_nid,
        has_nid and ("Node #" .. util.int_str(node_id)) or "not configured in mynet.conf")

    -- 2. GNB 二进制存在
    local gnb_bin = cfg_m.get_gnb_bin()
    local gnb_exists = util.file_exists(gnb_bin)
    add("gnb_binary", gnb_exists,
        gnb_exists and gnb_bin or ("not found: " .. gnb_bin))

    -- 3. gnb_ctl 存在
    local gnb_ctl = util.GNB_DRIVER_ROOT .. "/bin/gnb_ctl"
    local ctl_exists = util.file_exists(gnb_ctl)
    add("gnb_ctl", ctl_exists,
        ctl_exists and gnb_ctl or ("not found: " .. gnb_ctl))

    if has_nid then
        local n = util.int_str(node_id)

        -- 4. node.conf
        local nc_path = cfg_m.get_gnb_conf_root() .. "/" .. n .. "/node.conf"
        local nc = util.read_file(nc_path) or ""
        add("node.conf", nc ~= "",
            nc ~= "" and nc_path or ("missing: " .. nc_path))

        -- 5. route.conf
        local rc_path = util.GNB_CONF_DIR .. "/" .. n .. "/route.conf"
        local rc = util.read_file(rc_path) or ""
        add("route.conf", rc ~= "",
            rc ~= "" and rc_path or ("missing: " .. rc_path))

        -- 6. address.conf
        local ac_path = util.GNB_CONF_DIR .. "/" .. n .. "/address.conf"
        local ac = util.read_file(ac_path) or ""
        add("address.conf", ac ~= "",
            ac ~= "" and ac_path or ("missing (non-fatal): " .. ac_path))

        -- 7. 私钥
        local pk_path = util.GNB_CONF_DIR .. "/" .. n .. "/security/" .. n .. ".private"
        local pk = util.trim(util.read_file(pk_path) or "")
        local pk_ok = #pk == 128 and pk:match("^[0-9a-fA-F]+$") ~= nil
        add("private_key", pk_ok,
            pk_ok and pk_path or ("missing or invalid: " .. pk_path))

        -- 8. 公钥
        local pub_path = util.GNB_CONF_DIR .. "/" .. n .. "/security/" .. n .. ".public"
        local pub = util.trim(util.read_file(pub_path) or "")
        local pub_ok = #pub == 64 and pub:match("^[0-9a-fA-F]+$") ~= nil
        add("public_key", pub_ok,
            pub_ok and pub_path or ("missing or invalid: " .. pub_path))

        -- 9. peer keys
        local pk_out = util.exec("ls " .. util.GNB_CONF_DIR .. "/" .. n .. "/ed25519/*.public 2>/dev/null | wc -l") or "0"
        local pk_count = tonumber(util.trim(pk_out)) or 0
        add("peer_keys", pk_count > 0,
            pk_count > 0 and (pk_count .. " peer(s)") or "no peer keys")

        -- 10. GNB 进程运行状态
        local running = node_m.gnb_is_running(node_id)
        add("gnb_process", running,
            running and "running" or "not running")

        -- 11. GNB 日志最后几行是否有报错
        local log_path = util.GNB_CONF_DIR .. "/" .. n .. "/gnb.log"
        local log_tail = util.trim(util.exec("tail -20 " .. log_path .. " 2>/dev/null") or "")
        local has_error = log_tail:lower():find("error") or log_tail:lower():find("fatal")
        add("gnb_log", not has_error,
            has_error and "errors found in gnb.log" or (log_tail ~= "" and "no errors in last 20 lines" or "no log file"))
    end

    -- 12. kmod-tun
    local tun_ok = util.file_exists("/dev/net/tun")
    if not tun_ok then
        local lsmod = util.trim(util.exec("lsmod 2>/dev/null | grep -w tun") or "")
        tun_ok = lsmod ~= ""
    end
    add("kmod_tun", tun_ok,
        tun_ok and "ok" or "/dev/net/tun missing")

    -- 13. init.d mynet
    local initd_ok = util.file_exists("/etc/init.d/mynet")
    add("init_script", initd_ok,
        initd_ok and "/etc/init.d/mynet" or "missing")

    -- GNB 日志尾部（供前端显示）
    local gnb_log_tail = ""
    if has_nid then
        local log_path = util.GNB_CONF_DIR .. "/" .. util.int_str(node_id) .. "/gnb.log"
        gnb_log_tail = util.trim(util.exec("tail -30 " .. log_path .. " 2>/dev/null") or "")
    end

    json_ok({
        success  = true,
        all_ok   = all_ok,
        checks   = checks,
        gnb_log  = gnb_log_tail,
    })
end

-- ─────────────────────────────────────────────────────────────
-- GNB Monitor Actions
-- ─────────────────────────────────────────────────────────────

function action_gnb_monitor()
    local c = require_auth()
    if not c then return end
    http.redirect(disp.build_url("admin/services/mynet/service") .. "?tab=peers")
end

function api_gnb_monitor_data()
    if not require_api_auth() then return end

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
    if not require_api_auth() then return end

    local gnb_m  = require("luci.model.mynet.gnb_installer")
    local result = gnb_m.start_auto_install()
    json_ok(result)
end

-- 安装系统依赖：kmod-tun / bash / curl-tls / ca-bundle（不安装 gnb）
function api_install_system_deps()
    if not require_api_auth() then return end

    local gnb_m  = require("luci.model.mynet.gnb_installer")
    local result = gnb_m.check_deps()
    json_ok({ success = true, steps = result.steps, errors = result.errors })
end

-- 防火墙 Zone 一键配置（创建 zone + forwarding + include）
function api_fw_setup()
    if not require_api_auth() then return end
    local ok, msg = sys_m.ensure_firewall_zone()
    json_ok({ success = ok, message = msg or "" })
end

-- 防火墙 Zone 清除
function api_fw_teardown()
    if not require_api_auth() then return end
    local ok, msg = sys_m.remove_firewall_zone()
    json_ok({ success = ok, message = msg or "" })
end

-- 防火墙 masq 规则重新应用
function api_fw_apply_masq()
    if not require_api_auth() then return end
    local ok, msg = sys_m.apply_firewall_masq()
    json_ok({ success = ok, message = msg or "" })
end

-- 查询安装状态（前端轮询用）
function api_gnb_install_status()
    if not require_api_auth() then return end

    local gnb_m = require("luci.model.mynet.gnb_installer")
    json_ok({ success = true, data = gnb_m.get_status() })
end

-- ─────────────────────────────────────────────────────────────
-- Proxy 分流管理 API / Page
-- ─────────────────────────────────────────────────────────────

function action_proxy()
    local c = require_auth()
    if not c then return end

    local is_guest = c.guest == true
    if is_guest then
        -- Guest 模式：渲染插件列表页（只读）
        tmpl.render("mynet/proxy", {
            is_guest     = true,
            proxy_status = {},
            proxy_config = {},
        })
        return
    end

    local proxy_m = require("luci.model.mynet.proxy")
    local status  = proxy_m.get_status()
    local config  = proxy_m.load_config()
    local z       = zone_ctx()
    tmpl.render("mynet/proxy", {
        is_guest     = false,
        proxy_status = status,
        proxy_config = config,
        zone         = z,
    })
end

function api_proxy_status()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local proxy_m = require("luci.model.mynet.proxy")
    local st = proxy_m.get_status()
    json_ok({ success = true, data = st })
end

function api_proxy_start()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local mode      = http.formvalue("mode")     or "client"
    local region    = http.formvalue("region")    or "domestic"
    local dns_mode  = http.formvalue("dns_mode")  or "none"
    local dns_srv   = http.formvalue("dns_server") or ""
    local peers     = http.formvalue("proxy_peers") or ""

    -- 校验 mode / region / dns_mode
    local valid_modes   = { client = true, server = true }
    local valid_regions = { domestic = true, international = true }
    local valid_dns     = { none = true, redirect = true, resolv = true }
    if not valid_modes[mode]     then json_err("invalid mode"); return end
    if not valid_regions[region] then json_err("invalid region"); return end
    if not valid_dns[dns_mode]   then json_err("invalid dns_mode"); return end

    local proxy_m = require("luci.model.mynet.proxy")
    local ok, msg = proxy_m.start({
        mode        = mode,
        region      = region,
        dns_mode    = dns_mode,
        dns_server  = dns_srv,
        proxy_peers = peers,
    })

    if ok then
        json_ok({ success = true, message = msg })
    else
        json_err(msg or "start failed")
    end
end

function api_proxy_stop()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local proxy_m = require("luci.model.mynet.proxy")
    local ok, msg = proxy_m.stop()
    if ok then
        json_ok({ success = true, message = msg })
    else
        json_err(msg or "stop failed")
    end
end

function api_proxy_reload()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local proxy_m = require("luci.model.mynet.proxy")
    local ok, msg = proxy_m.reload()
    if ok then
        json_ok({ success = true, message = msg })
    else
        json_err(msg or "reload failed")
    end
end

function api_proxy_diagnose()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local ip = http.formvalue("ip")
    if not ip or not ip:match("^%d+%.%d+%.%d+%.%d+$") then
        json_err("invalid IPv4 address")
        return
    end

    local proxy_m = require("luci.model.mynet.proxy")
    local result, err = proxy_m.diagnose_ip(ip)
    if result then
        json_ok({ success = true, data = result })
    else
        json_err(err or "diagnose failed")
    end
end

function api_proxy_config()
    local c = cred_m.load()
    if not c or not cred_m.is_valid(c) then json_err("not authenticated", 401); return end

    local proxy_m = require("luci.model.mynet.proxy")
    local method = http.getenv("REQUEST_METHOD")

    if method == "POST" then
        -- 保存配置
        local mode       = http.formvalue("proxy_mode")  or "client"
        local region     = http.formvalue("node_region")  or "domestic"
        local dns_mode   = http.formvalue("dns_mode")     or "none"
        local dns_srv    = http.formvalue("dns_server")   or ""
        local peers      = http.formvalue("proxy_peers")  or ""
        local enabled_s  = http.formvalue("proxy_enabled")

        local valid_modes   = { client = true, server = true }
        local valid_regions = { domestic = true, international = true }
        local valid_dns     = { none = true, redirect = true, resolv = true }
        if not valid_modes[mode]     then json_err("invalid mode"); return end
        if not valid_regions[region] then json_err("invalid region"); return end
        if not valid_dns[dns_mode]   then json_err("invalid dns_mode"); return end

        proxy_m.save_config({
            proxy_enabled = (enabled_s == "1" or enabled_s == "true"),
            proxy_mode    = mode,
            node_region   = region,
            dns_mode      = dns_mode,
            dns_server    = dns_srv,
            proxy_peers   = peers,
        })
        json_ok({ success = true, message = "config saved" })
    else
        -- 返回当前配置
        local cfg = proxy_m.load_config()
        json_ok({ success = true, data = cfg })
    end
end

-- ═════════════════════════════════════════════════════════════
-- GNB 离线（Guest）模式
-- ═════════════════════════════════════════════════════════════

-- Guest 页面（不需要 MyNet 登录）
function action_guest()
    -- 确保访问 /guest 时模式切回 guest（修复从 mynet 模式回不来的 bug）
    if cfg_m.get_mode() ~= "guest" then
        cfg_m.set_mode("guest")
    end

    local guest_m = require("luci.model.mynet.guest")
    local g       = guest_m.load_config()
    local gnb_bin = cfg_m.get_gnb_bin()

    -- GNB 进程状态（pgrep -x 精确匹配二进制名，避免匹配自身）
    local vpn_running = false
    if g and g.local_node_id then
        local ps = util.trim(util.exec("pgrep gnb 2>/dev/null") or "")
        vpn_running = ps ~= ""
    end

    tmpl.render("mynet/guest", {
        mode          = cfg_m.get_mode(),
        guest         = g,
        initialized   = guest_m.is_initialized(),
        gnb_installed = util.file_exists(gnb_bin),
        vpn_running   = vpn_running,
    })
end

-- 初始化 Guest 网络
function api_guest_init()
    if not check_rate_limit(10, "guest") then
        json_err("rate limit", 429); return
    end
    local guest_m = require("luci.model.mynet.guest")

    local count   = tonumber(http.formvalue("node_count"))   or 3
    local name    = http.formvalue("network_name") or "MyNetwork"
    local subnet  = http.formvalue("subnet")       or "10.1.0"
    local port    = tonumber(http.formvalue("listen_port"))   or 9001
    local local_i = tonumber(http.formvalue("local_index"))   or 1
    local start_id = tonumber(http.formvalue("start_id"))

    -- 输入清洁
    name = name:gsub("[^%w%s%-_]", ""):sub(1, 32)

    local result, err = guest_m.init_network({
        node_count   = count,
        network_name = name,
        subnet       = subnet,
        listen_port  = port,
        local_index  = local_i,
        start_id     = start_id,
    })
    if err then json_err(err); return end
    json_ok({ success = true, data = result })
end

-- 获取 Guest 节点列表
function api_guest_nodes()
    local guest_m = require("luci.model.mynet.guest")
    local g = guest_m.load_config()
    if not g then json_err("guest mode not initialized"); return end

    -- 检查 GNB 运行状态（pgrep -x 精确匹配二进制名，避免匹配自身）
    local vpn_running = false
    if g.local_node_id then
        local ps = util.trim(util.exec("pgrep gnb 2>/dev/null") or "")
        vpn_running = ps ~= ""
    end

    json_ok({
        success     = true,
        data        = g,
        vpn_running = vpn_running,
    })
end

-- 新增节点
function api_guest_add_node()
    if not check_rate_limit(20, "guest") then
        json_err("rate limit", 429); return
    end
    local guest_m = require("luci.model.mynet.guest")
    local name = http.formvalue("name")
    if name then name = name:gsub("[^%w%s%-_]", ""):sub(1, 32) end
    local custom_nid = tonumber(http.formvalue("node_id"))

    local node, err = guest_m.add_node(name, custom_nid)
    if err then json_err(err); return end
    -- route.conf 已在 add_node 内更新，同步重新生成 network.conf
    local g = guest_m.load_config()
    if g and g.local_node_id then
        node_m.generate_network_conf(g.local_node_id)
    end
    json_ok({ success = true, data = node })
end

-- 删除节点
function api_guest_delete()
    if not check_rate_limit(20, "guest") then
        json_err("rate limit", 429); return
    end
    local guest_m = require("luci.model.mynet.guest")
    local nid = tonumber(http.formvalue("node_id"))
    if not nid then json_err("missing node_id"); return end

    local ok, err = guest_m.delete_node(nid)
    if err then json_err(err); return end
    -- route.conf 已在 delete_node 内更新，同步重新生成 network.conf
    local g = guest_m.load_config()
    if g and g.local_node_id then
        node_m.generate_network_conf(g.local_node_id)
    end
    json_ok({ success = true })
end

-- 导出节点配置包（下载 tar.gz）
function api_guest_export()
    local guest_m = require("luci.model.mynet.guest")
    local nid = tonumber(http.formvalue("node_id"))
    if not nid then json_err("missing node_id"); return end

    local fpath, err = guest_m.export_node_config(nid)
    if err then json_err(err); return end

    local fname = "gnb_node_" .. tostring(nid) .. ".tar.gz"
    http.header("Content-Disposition", 'attachment; filename="' .. fname .. '"')
    http.prepare_content("application/gzip")

    local f = io.open(fpath, "rb")
    if f then
        http.write(f:read("*a"))
        f:close()
        os.remove(fpath)
    else
        json_err("read export file failed")
    end
end

-- 启动 Guest GNB
-- 切换 Guest 活跃节点（POST: node_id）
function api_guest_use()
    if not check_rate_limit(10, "guest") then
        json_err("rate limit", 429); return
    end
    local guest_m = require("luci.model.mynet.guest")
    local raw_nid = http.formvalue("node_id") or ""
    local node_id = tonumber(raw_nid)
    if not node_id then json_err("node_id required"); return end

    local g = guest_m.load_config()
    if not g or not g.nodes then
        json_err("guest mode not initialized"); return
    end

    -- 验证 node_id 存在于节点列表中
    local found = false
    for _, n in ipairs(g.nodes) do
        if n.node_id == node_id then found = true; break end
    end
    if not found then json_err("node not found in guest config"); return end

    -- 更新 local_node_id 并标记 is_local
    g.local_node_id = node_id
    for _, n in ipairs(g.nodes) do
        n.is_local = (n.node_id == node_id)
    end
    guest_m.save_config(g)

    -- 重新生成 mynet.conf 指向新节点
    cfg_m.generate_mynet_conf(node_id)

    -- 重新生成 route.conf
    guest_m.ensure_route_conf(node_id)

    json_ok({ success = true, message = "已切换到节点 " .. tostring(node_id) })
end

function api_guest_start()
    if not check_rate_limit(10, "guest") then
        json_err("rate limit", 429); return
    end
    local guest_m = require("luci.model.mynet.guest")
    local g = guest_m.load_config()
    if not g or not g.local_node_id then
        json_err("guest mode not initialized"); return
    end

    local gnb_bin = cfg_m.get_gnb_bin()
    if not util.file_exists(gnb_bin) then
        json_err("gnb 未安装，请先安装 GNB"); return
    end

    local conf_dir = util.GNB_CONF_DIR .. "/" .. tostring(g.local_node_id)
    if not util.file_exists(conf_dir .. "/node.conf") then
        json_err("节点配置不存在"); return
    end

    -- 确保 route.conf 与 guest.json 一致（始终重新生成）
    local rok, rerr = guest_m.ensure_route_conf(g.local_node_id)
    if not rok then
        json_err("route.conf 生成失败: " .. (rerr or "unknown")); return
    end

    -- 生成 network.conf（从 route.conf 派生 CIDR 路由）
    node_m.generate_network_conf(g.local_node_id)

    -- 停止已有进程 → 启动 GNB（用 shell 后台 &，不用 -d 避免 daemon fork 问题）
    local log_file = conf_dir .. "/gnb.log"
    local cmd = string.format(
        "killall gnb 2>/dev/null; sleep 1; '%s' -c '%s' >>'%s' 2>&1 &",
        gnb_bin, conf_dir, log_file)
    os.execute(cmd)

    -- 短暂等待确认进程存活
    util.exec("sleep 1")
    local ps = util.trim(util.exec("pgrep gnb 2>/dev/null") or "")
    if ps == "" then
        json_err("GNB 启动失败，请查看日志: " .. log_file); return
    end

    json_ok({ success = true, message = "GNB 已启动" })
end

-- 停止 Guest GNB
function api_guest_stop()
    if not check_rate_limit(10, "guest") then
        json_err("rate limit", 429); return
    end
    os.execute("killall gnb 2>/dev/null")
    json_ok({ success = true, message = "GNB 已停止" })
end

-- 重置 Guest 网络
function api_guest_reset()
    if not check_rate_limit(5, "guest") then
        json_err("rate limit", 429); return
    end
    local guest_m = require("luci.model.mynet.guest")
    -- 先停止 GNB
    os.execute("killall gnb 2>/dev/null")
    guest_m.reset()
    -- 清除当前节点设置（mynet.conf），避免残留 NODE_ID 导致后续保存 node.conf 出错
    os.execute("rm -f '" .. util.VPN_CONF .. "'")
    json_ok({ success = true })
end

-- 导入配置包（两阶段：step=preview 或 step=apply）
function api_guest_import()
    if not check_rate_limit(5, "guest") then
        json_err("rate limit", 429); return
    end
    local guest_m = require("luci.model.mynet.guest")
    local step = http.formvalue("step") or "preview"

    if step == "preview" then
        -- 接收 base64 编码的 tar.gz 文件
        local b64_data = http.formvalue("file_data") or ""
        if b64_data == "" then
            json_err("no file data"); return
        end

        -- 限制大小（base64 最大 ~1MB → 原始 ~750KB，对配置包绰绰有余）
        if #b64_data > 1048576 then
            json_err("file too large (max 1MB)"); return
        end

        -- base64 解码（使用 nixio）
        local nixio = require("nixio")
        local raw = nixio.bin.b64decode(b64_data)
        if not raw or #raw == 0 then
            json_err("base64 decode failed"); return
        end
        local tmp_tar = "/tmp/mynet_import_" .. os.time() .. ".tar.gz"
        util.write_file(tmp_tar, raw)

        local preview, err = guest_m.import_preview(tmp_tar)
        -- 保留 tar.gz 用于 apply 阶段
        if not preview then
            os.execute("rm -f '" .. tmp_tar .. "'")
            json_err(err or "preview failed"); return
        end
        -- 把 tar 路径也存入 preview 供前端回传
        preview.tar_path = tmp_tar
        json_ok(preview)

    elseif step == "apply" then
        local tmp_dir = http.formvalue("tmp_dir") or ""
        local node_id = http.formvalue("node_id") or ""
        local tar_path = http.formvalue("tar_path") or ""

        -- 安全检查：tmp_dir 必须在 /tmp/mynet_import_ 下
        if not tmp_dir:match("^/tmp/mynet_import_%d+$") then
            json_err("invalid tmp_dir"); return
        end
        if not node_id:match("^%d+$") then
            json_err("invalid node_id"); return
        end

        local ok, err = guest_m.import_apply(tmp_dir, node_id)
        -- 清理 tar.gz
        if tar_path:match("^/tmp/mynet_import_%d+%.tar%.gz$") then
            os.execute("rm -f '" .. tar_path .. "'")
        end
        if not ok then
            json_err(err or "import failed"); return
        end
        -- 设置 guest 模式
        cfg_m.set_mode("guest")
        json_ok({ success = true, node_id = node_id })
    else
        json_err("invalid step: must be 'preview' or 'apply'")
    end
end

-- 切换运行模式
function api_set_mode()
    if not check_rate_limit(10, "api") then
        json_err("rate limit", 429); return
    end
    local mode = http.formvalue("mode")
    if mode ~= "mynet" and mode ~= "guest" then
        json_err("invalid mode: must be 'mynet' or 'guest'"); return
    end
    cfg_m.set_mode(mode)
    json_ok({ success = true, mode = mode })
end
