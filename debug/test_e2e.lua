#!/usr/bin/env lua
-- ═══════════════════════════════════════════════════════════════
-- MyNet 端到端测试脚本
-- 用法: ssh root@192.168.0.2 "lua /usr/lib/lua/luci/test_e2e.lua"
-- 或  : ssh root@192.168.0.2 "lua /path/to/test_e2e.lua [category]"
-- category: auth|keys|gnb|routes|firewall|scripts|vpn|proxy|all (默认 all)
-- ═══════════════════════════════════════════════════════════════
package.path = "/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;" .. package.path

-- ─── 测试框架 ─────────────────────────────────────────────────
local pass_count, fail_count, skip_count = 0, 0, 0
local current_category = ""
local category_stats = {}

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass_count = pass_count + 1
        category_stats[current_category].pass = (category_stats[current_category].pass or 0) + 1
        io.write(string.format("  ✓ %s\n", name))
    else
        fail_count = fail_count + 1
        category_stats[current_category].fail = (category_stats[current_category].fail or 0) + 1
        io.write(string.format("  ✗ %s — %s\n", name, tostring(err)))
    end
end

local function skip(name, reason)
    skip_count = skip_count + 1
    category_stats[current_category].skip = (category_stats[current_category].skip or 0) + 1
    io.write(string.format("  ⊘ %s — SKIP: %s\n", name, reason))
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %q, got %q", msg or "assert_eq", tostring(b), tostring(a)))
    end
end

local function assert_true(v, msg)
    if not v then error(msg or "expected true") end
end

local function assert_match(s, pattern, msg)
    if not s or not s:match(pattern) then
        error(string.format("%s: %q !~ /%s/", msg or "assert_match", tostring(s), pattern))
    end
end

local function category(name)
    current_category = name
    category_stats[name] = { pass = 0, fail = 0, skip = 0 }
    print(string.format("\n══ %s ══", name))
end

local function shell(cmd)
    local p = io.popen(cmd .. " 2>/dev/null", "r")
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    return out:gsub("^%s+", ""):gsub("%s+$", "")
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end

-- ─── 模块加载 ─────────────────────────────────────────────────
local cfg  = require("luci.model.mynet.config")
local util = require("luci.model.mynet.util")
local auth = require("luci.model.mynet.auth")
local cred = require("luci.model.mynet.credential")
local node = require("luci.model.mynet.node")
local sys  = require("luci.model.mynet.system")
local val  = require("luci.model.mynet.validator")

local NODE_ID   = cfg.get_node_id()
local IFACE     = cfg.get_vpn_interface() or "gnb_tun"
local NID_STR   = util.int_str(NODE_ID)
local CONF_DIR  = string.format("%s/%s", util.GNB_CONF_DIR, NID_STR)

-- 选定要运行的类别
local run_category = (arg and arg[1]) or "all"
local function should_run(cat)
    return run_category == "all" or run_category == cat
end

print("═══════════════════════════════════════════════════════")
print("  MyNet E2E Test Suite")
print(string.format("  Node: %s  Interface: %s", NID_STR, IFACE))
print(string.format("  API:  %s", cfg.get_api_url()))
print("═══════════════════════════════════════════════════════")

-- ═══════════════════════════════════════════════════════════════
-- T1: Auth & Config
-- ═══════════════════════════════════════════════════════════════
if should_run("auth") then
    category("T1: Auth & Config")

    test("load_vpn_conf", function()
        local c = cfg.load_vpn_conf()
        assert_true(c, "load_vpn_conf returned nil")
    end)

    test("get_node_id is integer", function()
        assert_true(NODE_ID and NODE_ID ~= 0, "node_id is 0 or nil")
        assert_match(NID_STR, "^%d+$", "node_id not pure digits")
    end)

    test("get_vpn_interface", function()
        assert_true(IFACE and IFACE ~= "", "interface empty")
    end)

    test("credential load", function()
        local c = cred.load()
        assert_true(c, "no credential")
        assert_true(c.token and c.token ~= "", "empty token")
    end)

    test("auth.ensure_valid", function()
        local current, err = auth.ensure_valid()
        assert_true(current ~= nil, "not logged in: " .. tostring(err))
    end)

    test("check_config", function()
        local r = node.check_config(NODE_ID)
        assert_true(r.ok, "check_config: " .. table.concat(r.errors or {}, "; "))
    end)

    test("validate_config", function()
        local r = val.validate_config()
        assert_true(r.ok, "validate: " .. table.concat(r.errors or {}, "; "))
    end)

    test("system.check_deps", function()
        local r = sys.check_deps(NODE_ID)
        assert_true(r, "check_deps returned nil")
    end)

    test("refresh_configs (bundle)", function()
        local r = node.refresh_configs_bundle(NODE_ID)
        -- node.conf API 405 是已知服务端问题，不算致命
        -- 只要 route.conf 和 address.conf 写入成功即可
        if not r.ok then
            local fatal = false
            for _, e in ipairs(r.errors or {}) do
                if not e:match("node%.conf") then fatal = true end
            end
            assert_true(not fatal, "refresh: " .. table.concat(r.errors or {}, "; "))
        end
    end)

    test("node.conf exists after refresh", function()
        assert_true(file_exists(CONF_DIR .. "/node.conf"), "node.conf missing")
    end)

    test("route.conf exists after refresh", function()
        assert_true(file_exists(CONF_DIR .. "/route.conf"), "route.conf missing")
    end)

    test("generate_route_conf", function()
        local path, err = node.generate_route_conf(NODE_ID)
        assert_true(path or not err, "route.conf: " .. tostring(err))
    end)

    -- 服务端已知问题 — 标记为 skip 而非 fail
    test("refresh_single_config(route)", function()
        local r = node.refresh_single_config(NODE_ID, "route")
        assert_true(r.ok, "route refresh: " .. tostring(r.error))
    end)

    skip("refresh_single_config(node)", "API 405 — server不支持 render_conf=1")
    skip("update_node_status", "API 500 — server bug")
end

-- ═══════════════════════════════════════════════════════════════
-- T2: Key Management
-- ═══════════════════════════════════════════════════════════════
if should_run("keys") then
    category("T2: Key Management")

    local priv_path = string.format("%s/security/%s.private", CONF_DIR, NID_STR)
    local pub_path  = string.format("%s/ed25519/%s.public", CONF_DIR, NID_STR)

    test("private key file exists", function()
        assert_true(file_exists(priv_path), "private key missing: " .. priv_path)
    end)

    test("public key file exists", function()
        assert_true(file_exists(pub_path), "public key missing: " .. pub_path)
    end)

    test("private key = 128 hex chars", function()
        local k = (read_file(priv_path) or ""):gsub("%s+", "")
        assert_eq(#k, 128, "private key length")
        assert_match(k, "^%x+$", "private key hex")
    end)

    test("public key = 64 hex chars", function()
        local k = (read_file(pub_path) or ""):gsub("%s+", "")
        assert_eq(#k, 64, "public key length")
        assert_match(k, "^%x+$", "public key hex")
    end)

    test("upload_public_key", function()
        local ok, err = node.upload_public_key(NODE_ID)
        assert_true(ok, "upload: " .. tostring(err))
    end)

    test("fetch_server_public_key (self)", function()
        local key, err = node.fetch_server_public_key(NODE_ID)
        -- 429 rate limit is transient — allow retry
        if err and err:find("429") then
            skip("fetch_server_public_key", "API 429 rate limit")
            return
        end
        assert_true(key, "fetch: " .. tostring(err))
    end)

    test("ed25519 peer keys exist", function()
        local ed_dir = CONF_DIR .. "/ed25519"
        local count = 0
        local p = io.popen("ls " .. ed_dir .. "/*.public 2>/dev/null | wc -l")
        if p then count = tonumber(p:read("*a")) or 0; p:close() end
        assert_true(count >= 2, "expected ≥2 peer public keys, got " .. count)
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- T3: GNB Process Lifecycle
-- ═══════════════════════════════════════════════════════════════
if should_run("gnb") then
    category("T3: GNB Lifecycle")

    -- 确保 GNB 先停止
    node.stop_gnb(NODE_ID)
    shell("sleep 2")

    test("initial state: stopped", function()
        assert_eq(node.get_vpn_service_status(), "stopped", "status")
    end)

    test("gnb_is_running = false when stopped", function()
        assert_true(not node.gnb_is_running(NODE_ID), "should not be running")
    end)

    test("start_gnb", function()
        local ok, err = node.start_gnb(NODE_ID)
        assert_true(ok, "start: " .. tostring(err))
    end)

    test("gnb_is_running after start", function()
        assert_true(node.gnb_is_running(NODE_ID), "not running after start")
    end)

    test("status = running", function()
        assert_eq(node.get_vpn_service_status(), "running", "status")
    end)

    test("pidfile contains valid PID", function()
        local pf = string.format("%s/gnb.pid", CONF_DIR)
        local pid = (read_file(pf) or ""):gsub("%s+", "")
        assert_match(pid, "^%d+$", "pidfile content")
        local cmdline = read_file("/proc/" .. pid .. "/cmdline") or ""
        assert_true(cmdline:find("gnb", 1, true), "process is not gnb")
    end)

    test("cmdline contains conf dir (multi-instance safe)", function()
        local pf = string.format("%s/gnb.pid", CONF_DIR)
        local pid = (read_file(pf) or ""):gsub("%s+", "")
        local cmdline = read_file("/proc/" .. pid .. "/cmdline") or ""
        assert_true(cmdline:find(CONF_DIR, 1, true), "cmdline missing conf dir")
    end)

    test("tun interface UP after start", function()
        local link = shell("ip link show " .. IFACE)
        assert_true(link ~= "", "interface not found")
    end)

    test("stop_gnb", function()
        local ok, err = node.stop_gnb(NODE_ID)
        assert_true(ok, "stop: " .. tostring(err))
    end)

    test("gnb_is_running = false after stop", function()
        shell("sleep 1")
        assert_true(not node.gnb_is_running(NODE_ID), "still running after stop")
    end)

    test("gnb_es cleaned up after stop_gnb", function()
        -- stop_gnb 应精确清理本实例的 gnb_es（等待自然退出 + 超时 kill）
        local out = shell("pidof gnb_es")
        assert_true(out == "", "gnb_es still running: " .. out)
    end)

    test("tun interface persists after stop", function()
        -- 接口在 install 时创建，stop 不应删除
        local uci = shell("uci get network.mynet.device")
        assert_eq(uci, IFACE, "UCI network.mynet.device")
    end)

    -- 二次启动
    test("start_gnb (2nd time)", function()
        local ok, err = node.start_gnb(NODE_ID)
        assert_true(ok, "2nd start: " .. tostring(err))
    end)

    test("restart_gnb", function()
        local ok, err = node.restart_gnb(NODE_ID)
        assert_true(ok, "restart: " .. tostring(err))
    end)

    test("running after restart", function()
        assert_true(node.gnb_is_running(NODE_ID), "not running after restart")
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- T4: Route Management
-- ═══════════════════════════════════════════════════════════════
if should_run("routes") then
    category("T4: Routes")

    -- 确保 GNB 在运行
    if not node.gnb_is_running(NODE_ID) then
        node.start_gnb(NODE_ID)
        shell("sleep 2")
    end

    test("apply_routes", function()
        local r = node.apply_routes(NODE_ID)
        assert_true(r.ok, "apply: " .. table.concat(r.errors or {}, "; "))
    end)

    test("routes visible in OS", function()
        local out = shell("ip route show dev " .. IFACE)
        assert_true(out ~= "", "no routes on " .. IFACE)
    end)

    test("clear_routes", function()
        node.clear_routes(NODE_ID)
        local out = shell("ip route show dev " .. IFACE)
        -- 只应剩下 connected route (10.x.x.0/24)，不应有其他远端路由
        local non_local = 0
        for line in (out .. "\n"):gmatch("([^\n]+)\n") do
            if not line:match("proto kernel") then non_local = non_local + 1 end
        end
        assert_eq(non_local, 0, "remaining non-local routes")
    end)

    -- 重新 apply 以保持功能完整
    node.apply_routes(NODE_ID)
end

-- ═══════════════════════════════════════════════════════════════
-- T5: Firewall/NAT
-- ═══════════════════════════════════════════════════════════════
if should_run("firewall") then
    category("T5: Firewall/NAT")

    test("apply_firewall", function()
        local r = node.apply_firewall(NODE_ID)
        assert_true(r.ok, "apply: " .. table.concat(r.errors or {}, "; "))
    end)

    test("mynet zone exists in UCI", function()
        local name = shell("uci get firewall.@zone[3].name 2>/dev/null || echo ''")
        -- zone 可能不在 index 3, 用循环查找
        local found = false
        for i = 0, 15 do
            local n = shell(string.format("uci get firewall.@zone[%d].name 2>/dev/null", i))
            if n == "mynet" then found = true; break end
        end
        assert_true(found, "mynet zone not found")
    end)

    test("lan->mynet forwarding", function()
        local found = false
        for i = 0, 30 do
            local src = shell(string.format("uci get firewall.@forwarding[%d].src 2>/dev/null", i))
            local dst = shell(string.format("uci get firewall.@forwarding[%d].dest 2>/dev/null", i))
            if src == "" then break end
            if src == "lan" and dst == "mynet" then found = true; break end
        end
        assert_true(found, "no lan→mynet forwarding")
    end)

    test("ip_forward enabled", function()
        local v = shell("sysctl -n net.ipv4.ip_forward")
        assert_eq(v, "1", "ip_forward")
    end)

    test("NAT rule present (fullcone or masquerade)", function()
        -- ImmortalWrt 使用 fullcone (zone masq=1), 标准 OpenWrt 用 masquerade
        local nft = shell("nft list chain inet fw4 srcnat 2>/dev/null")
        local has_gnb = nft:find(IFACE) ~= nil
        assert_true(has_gnb, "no NAT rule referencing " .. IFACE)
    end)

    test("device binding in UCI zone", function()
        local found = false
        for i = 0, 15 do
            local name = shell(string.format("uci get firewall.@zone[%d].name 2>/dev/null", i))
            if name == "mynet" then
                local dev = shell(string.format("uci get firewall.@zone[%d].device 2>/dev/null", i))
                if dev == IFACE then found = true end
                break
            end
        end
        assert_true(found, "zone device not set to " .. IFACE)
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- T6: Scripts (init.d / route.mynet / firewall.mynet)
-- ═══════════════════════════════════════════════════════════════
if should_run("scripts") then
    category("T6: Scripts")

    test("init.d script exists", function()
        assert_true(file_exists("/etc/init.d/mynet"), "/etc/init.d/mynet missing")
    end)

    test("route.mynet exists", function()
        assert_true(file_exists(util.ROUTE_SCRIPT), util.ROUTE_SCRIPT .. " missing")
    end)

    test("firewall.mynet exists", function()
        assert_true(file_exists(util.FIREWALL_SCRIPT), util.FIREWALL_SCRIPT .. " missing")
    end)

    test("init.d is enabled", function()
        local out = shell("ls -la /etc/rc.d/S*mynet 2>/dev/null")
        assert_true(out ~= "", "mynet not enabled in rc.d")
    end)

    -- init.d start/stop 完整流程
    -- stop_gnb 会精确清理 gnb + gnb_es
    node.stop_gnb(NODE_ID)
    shell("rm -f " .. CONF_DIR .. "/gnb.pid")

    test("init.d start", function()
        local out, code = node.start_vpn()
        -- init.d start 可能返回 0 即使已经 running
        assert_true(code == 0 or code == nil, "init.d start failed: " .. tostring(out))
    end)

    -- 等待 init.d 完成启动
    shell("sleep 5")

    test("gnb running after init.d start", function()
        assert_true(node.gnb_is_running(NODE_ID), "not running after init.d start")
    end)

    test("init.d stop", function()
        local out, code = node.stop_vpn()
        assert_true(code == 0 or code == nil, "init.d stop failed: " .. tostring(out))
    end)

    shell("sleep 3")

    test("gnb stopped after init.d stop", function()
        assert_true(not node.gnb_is_running(NODE_ID), "still running after init.d stop")
    end)

    -- 恢复 GNB 运行状态
    node.start_gnb(NODE_ID)
    shell("sleep 2")
end

-- ═══════════════════════════════════════════════════════════════
-- T7: VPN Connectivity
-- ═══════════════════════════════════════════════════════════════
if should_run("vpn") then
    category("T7: VPN Connectivity")

    -- 确保 GNB 运行中 + 路由已应用
    -- stop_gnb 会精确清理 gnb + gnb_es（PPID 匹配，不用 killall）
    node.stop_gnb(NODE_ID)
    shell("rm -f " .. CONF_DIR .. "/gnb.pid")
    node.start_gnb(NODE_ID)
    shell("sleep 3")
    -- 验证 GNB 确实启动了
    if not node.gnb_is_running(NODE_ID) then
        io.write("  WARNING: GNB failed to start, retrying...\n")
        node.stop_gnb(NODE_ID)  -- 再次精确清理
        node.start_gnb(NODE_ID)
        shell("sleep 3")
    end
    node.apply_routes(NODE_ID)
    -- P2P 连接建立需要时间（打洞可能需要 1-2 分钟）
    -- 智能等待：每 5s 尝试 ping peer，有一个可达就提前结束
    do
        local max_wait = 120
        local probe_interval = 5
        -- 从 route.conf 提取一些 peer IP 作为探测目标
        local rc = read_file(CONF_DIR .. "/route.conf") or ""
        local self_ip = shell("ip -4 addr show " .. IFACE .. " | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1")
        local probe_ips = {}
        for line in rc:gmatch("[^\n]+") do
            local ip = line:match("^%d+|(%d+%.%d+%.%d+%.%d+)|")
            if ip and ip ~= self_ip and #probe_ips < 5 then
                probe_ips[#probe_ips + 1] = ip
            end
        end
        io.write(string.format("  (waiting up to %ds for P2P hole-punching, probing %d peers every %ds...)\n",
            max_wait, #probe_ips, probe_interval))
        local elapsed = 0
        local early = false
        while elapsed < max_wait do
            shell("sleep " .. probe_interval)
            elapsed = elapsed + probe_interval
            for _, ip in ipairs(probe_ips) do
                local out = shell("ping -c 1 -W 2 " .. ip)
                if out:find("1 packets received") or out:find("1 received") then
                    io.write(string.format("  (peer %s reachable after %ds, continuing)\n", ip, elapsed))
                    early = true
                    break
                end
            end
            if early then break end
            io.write(string.format("  (%ds/%ds ...)\n", elapsed, max_wait))
        end
        if not early then
            io.write(string.format("  (full %ds elapsed, no early peer found)\n", max_wait))
        end
    end

    test("vpn_status = running", function()
        assert_eq(node.get_vpn_service_status(), "running", "status")
    end)

    test("interface gnb_tun exists", function()
        local link = shell("ip link show " .. IFACE)
        assert_true(link ~= "", "interface missing")
        assert_true(link:find("UP") or link:find("up"), "interface not UP")
    end)

    test("mtu = 1450", function()
        local link = shell("ip link show " .. IFACE)
        assert_true(link:find("mtu 1450"), "mtu not 1450")
    end)

    -- 动态获取 VPN IP
    local vpn_ip = shell("ip -4 addr show " .. IFACE .. " | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1")

    test("ping self VPN IP", function()
        assert_true(vpn_ip ~= "", "no VPN IP on " .. IFACE)
        local out = shell("ping -c 1 -W 2 " .. vpn_ip)
        assert_true(out:find("1 packets received") or out:find("1 received"), "ping self failed")
    end)

    -- Peer 连通性测试 — 从 route.conf 动态读取对端 IP
    local route_conf = read_file(CONF_DIR .. "/route.conf") or ""
    local peers = {}
    for line in route_conf:gmatch("[^\n]+") do
        local peer_ip = line:match("^%d+|(%d+%.%d+%.%d+%.%d+)|")
        if peer_ip and peer_ip ~= vpn_ip then
            peers[peer_ip] = true
        end
    end

    local reachable_count = 0
    local total_peers = 0
    for ip, _ in pairs(peers) do
        total_peers = total_peers + 1
        test("ping peer " .. ip, function()
            local out = shell("ping -c 1 -W 3 " .. ip)
            if out:find("1 packets received") or out:find("1 received") then
                reachable_count = reachable_count + 1
            else
                -- peer offline 不算 fail，但记录
                io.write(string.format("    (peer %s unreachable — possibly offline)\n", ip))
                -- 不 error，peer 离线是正常的
            end
        end)
    end

    test("at least 1 peer reachable", function()
        assert_true(reachable_count >= 1,
            string.format("no peers reachable (%d/%d)", reachable_count, total_peers))
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- T8: Proxy Subsystem
-- ═══════════════════════════════════════════════════════════════
if should_run("proxy") then
    category("T8: Proxy")

    local proxy_ok, proxy = pcall(require, "luci.model.mynet.proxy")
    if not proxy_ok then
        skip("proxy module", "luci.model.mynet.proxy not available")
    else
        test("load_config", function()
            local c, err = proxy.load_config()
            assert_true(c, "load: " .. tostring(err))
        end)

        test("get_status", function()
            local s, err = proxy.get_status()
            assert_true(s, "status: " .. tostring(err))
        end)

        test("proxy running or stopped (no crash)", function()
            local s = proxy.get_status()
            assert_true(s, "status nil")
            -- 不强制要求 running/stopped，只要有返回
        end)
    end
end

-- ═══════════════════════════════════════════════════════════════
-- 结果汇总
-- ═══════════════════════════════════════════════════════════════
print("\n═══════════════════════════════════════════════════════")
print("  测试结果汇总")
print("═══════════════════════════════════════════════════════")

local cats_order = { "T1: Auth & Config", "T2: Key Management", "T3: GNB Lifecycle",
                     "T4: Routes", "T5: Firewall/NAT", "T6: Scripts",
                     "T7: VPN Connectivity", "T8: Proxy" }
for _, cat in ipairs(cats_order) do
    local s = category_stats[cat]
    if s then
        local total = s.pass + s.fail + s.skip
        local pct = total > 0 and math.floor(s.pass / (s.pass + s.fail + 0.001) * 100) or 0
        print(string.format("  %-25s %2d pass / %2d fail / %2d skip  (%d%%)",
            cat, s.pass, s.fail, s.skip, pct))
    end
end

local total = pass_count + fail_count + skip_count
local pct = (pass_count + fail_count) > 0
    and math.floor(pass_count / (pass_count + fail_count) * 100) or 0
print(string.format("\n  总计: %d pass / %d fail / %d skip  (%d%%)",
    pass_count, fail_count, skip_count, pct))
print("═══════════════════════════════════════════════════════")

os.exit(fail_count > 0 and 1 or 0)
