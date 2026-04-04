-- mynet/node.lua  — 节点管理模块
-- 节点列表、配置下载、状态上报、VPN 服务控制。
-- 对应 Go 项目 internal/application/node_app_service.go +
--              internal/application/status_app_service.go

local M    = {}
local api  = require("luci.model.mynet.api")
local auth = require("luci.model.mynet.auth")
local cfg  = require("luci.model.mynet.config")
local util = require("luci.model.mynet.util")

-- 安全整数字符串：避免 Lua 大整数变成科学计数法
local function nid(v) return util.int_str(v) end

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
    if not zone or not zone.zone_id or tostring(zone.zone_id) == "0" then
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
    local zone_id = zone and zone.zone_id or "0"
    local endpoint = string.format("/nodes/%s/config?render_conf=1", nid(node_id))

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
    local zone_id = zone and zone.zone_id or "0"
    local endpoint = string.format("/route/node/%s?render_conf=1", nid(node_id))

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
    local zone_id = zone and zone.zone_id or "0"

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
    local zone_id = zone and zone.zone_id or "0"
    local endpoint = string.format("/nodes/%s/status", nid(node_id))

    local data, api_err = api.patch_json(cfg.get_api_url(), endpoint,
        { status = status_code }, current.token, zone_id)
    if api_err then return nil, api_err end
    if not data or not data.success then
        return nil, (data and data.message) or "status update failed"
    end
    return true, nil
end

-- ─────────────────────────────────────────────────────────────
-- 将节点 route.conf 同步到 /etc/mynet/conf/route.conf
-- 调用 generate_network_conf 生成 <cidr> via <gateway> 格式
-- 供 service tab 显示和 rc.mynet 启动脚本使用
-- ─────────────────────────────────────────────────────────────
function M.sync_top_route_conf(node_id)
    M.generate_network_conf(node_id)
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
    local node_conf_path = string.format("%s/%s/node.conf",
        cfg.get_gnb_conf_root(), nid(node_id))
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
    local route_path = string.format("%s/%s/route.conf", util.GNB_CONF_DIR, nid(node_id))
    local route_text, err2 = M.get_route_config_rendered(node_id)
    if err2 then
        results.ok = false
        results.errors[#results.errors+1] = "route.conf: " .. err2
    elseif route_text and route_text ~= "" then
        local ok, we = util.write_file(route_path, route_text .. "\n")
        if ok then
            results.files[#results.files+1] = route_path
            M.sync_top_route_conf(node_id)
        else
            results.ok = false
            results.errors[#results.errors+1] = "write route.conf: " .. (we or "")
        end
    end

    -- 3. address.conf（非致命，部分区域无服务地址）
    local addr_path = string.format("%s/%s/address.conf", util.GNB_CONF_DIR, nid(node_id))
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
    -- 4. 同步对端公钥（优先批量 API）
    local pk_result = M.refresh_peer_keys_batch(node_id)
    if pk_result.count > 0 then
        results.files[#results.files+1] = string.format("peer_keys(%d)", pk_result.count)
    end
    for _, e in ipairs(pk_result.errors or {}) do
        util.log_warn("refresh_configs: peer key: " .. e)
    end
    return results
end

-- ─────────────────────────────────────────────────────────────
-- Config Bundle：单次请求获取全部配置 + 密钥，然后写入磁盘
-- 优先使用 bundle API，若后端不支持（404）则回退到 refresh_configs()
-- 返回: { ok, files=[], errors=[], method="bundle"|"legacy" }
-- ─────────────────────────────────────────────────────────────
function M.refresh_configs_bundle(node_id)
    local current, err = auth.ensure_valid()
    if err then
        return { ok = false, files = {}, errors = { "auth: " .. err }, method = "legacy" }
    end

    local zone    = cfg.load_current_zone()
    local zone_id = zone and zone.zone_id or "0"
    local self_nid = nid(node_id)

    -- 尝试 bundle API
    local bundle, berr = api.get_config_bundle(
        cfg.get_api_url(), self_nid, current.token, zone_id)

    if berr == "not_supported" or not bundle then
        -- 后端不支持 bundle → 回退
        util.log_info("node", "config-bundle not supported, fallback to legacy refresh")
        local r = M.refresh_configs(node_id)
        r.method = "legacy"
        return r
    end

    local results = { ok = true, files = {}, errors = {}, method = "bundle" }
    local gnb_conf_root = cfg.get_gnb_conf_root()

    -- 写入配置文件
    local files = bundle.files or (bundle.data and bundle.data.files) or {}
    local file_map = {
        ["node.conf"]    = string.format("%s/%s/node.conf", gnb_conf_root, self_nid),
        ["route.conf"]   = string.format("%s/%s/route.conf", util.GNB_CONF_DIR, self_nid),
        ["address.conf"] = string.format("%s/%s/address.conf", util.GNB_CONF_DIR, self_nid),
    }
    for fname, dest in pairs(file_map) do
        local content = files[fname]
        if content and content ~= "" then
            local ok, we = util.write_file(dest, content .. "\n")
            if ok then
                results.files[#results.files + 1] = dest
                if fname == "route.conf" then
                    M.sync_top_route_conf(node_id)
                end
            else
                results.ok = false
                results.errors[#results.errors + 1] = "write " .. fname .. ": " .. (we or "")
            end
        end
    end

    -- 写入密钥
    local keys = bundle.keys or (bundle.data and bundle.data.keys) or {}
    local ed_keys = keys.ed25519 or {}
    local ed_dir = string.format("%s/%s/ed25519", util.GNB_CONF_DIR, self_nid)
    util.ensure_dir(ed_dir)
    local key_count = 0
    for peer_id, pub_hex in pairs(ed_keys) do
        if type(pub_hex) == "table" then pub_hex = pub_hex.public_key end
        if pub_hex and pub_hex ~= "" then
            pub_hex = util.trim(pub_hex)
            if #pub_hex == 64 and pub_hex:match("^[0-9a-fA-F]+$") then
                util.write_file(string.format("%s/%s.public", ed_dir, peer_id), pub_hex)
                key_count = key_count + 1
            end
        end
    end
    if key_count > 0 then
        results.files[#results.files + 1] = string.format("peer_keys(%d)", key_count)
    end

    -- 写入自身密钥（如果 bundle 提供了）
    local sec = keys.security or {}
    if sec.private and sec.private ~= "" then
        M.save_private_key(node_id, sec.private)
    end
    if sec.public and sec.public ~= "" then
        M.save_public_key(node_id, sec.public)
    end

    return results
end

-- ─────────────────────────────────────────────────────────────
-- 获取单个节点详情
-- 对应 Go: GET /nodes/{id}
-- 返回: (node_table, nil) 或 (nil, error_string)
-- ─────────────────────────────────────────────────────────────
function M.get_single_node(node_id)
    local current, err = auth.ensure_valid()
    if err then return nil, err end

    local zone    = cfg.load_current_zone()
    local zone_id = zone and zone.zone_id or "0"
    local endpoint = string.format("/nodes/%s", nid(node_id))

    local data, api_err = api.get_json(cfg.get_api_url(), endpoint, current.token, zone_id)
    if api_err then return nil, api_err end
    if not data or not data.success then
        return nil, (data and data.message) or "failed to get node"
    end
    return data.data, nil
end

-- ─────────────────────────────────────────────────────────────
-- 读取本地配置文件（从磁盘，不调用 API）
-- 返回: { node_conf, route_conf, address_conf }
-- ─────────────────────────────────────────────────────────────
function M.read_local_configs(node_id)
    local gnb_conf_root = cfg.get_gnb_conf_root()
    local node_conf_path = string.format("%s/%s/node.conf", gnb_conf_root, nid(node_id))
    local route_path     = string.format("%s/%s/route.conf",   util.GNB_CONF_DIR, nid(node_id))
    local addr_path      = string.format("%s/%s/address.conf", util.GNB_CONF_DIR, nid(node_id))

    local node_conf    = util.trim(util.read_file(node_conf_path) or "")
    local route_conf   = util.trim(util.read_file(route_path)     or "")
    local address_conf = util.trim(util.read_file(addr_path)      or "")
    return {
        node_conf        = node_conf,
        route_conf       = route_conf,
        address_conf     = address_conf,
        node_conf_path   = node_conf_path,
        route_path       = route_path,
        addr_path        = addr_path,
        node_conf_ok     = node_conf ~= "",
        route_conf_ok    = route_conf ~= "",
        address_conf_ok  = address_conf ~= "",
    }
end

-- ─────────────────────────────────────────────────────────────
-- 私钥管理（ed25519 hex 格式，存于 {GNB_CONF_DIR}/{node_id}/security/{node_id}.private）
-- ─────────────────────────────────────────────────────────────

function M.get_private_key(node_id)
    local path = string.format("%s/%s/security/%s.private",
        util.GNB_CONF_DIR, nid(node_id), nid(node_id))
    local raw = util.read_file(path)
    if not raw then return nil, "file not found: " .. path end
    return util.trim(raw), nil
end

-- 保存私钥（校验 hex 格式，写文件 chmod 600）
-- 返回: (true, nil) 或 (nil, error_string)
function M.save_private_key(node_id, key_hex)
    if not key_hex or key_hex == "" then
        return nil, "key is empty"
    end
    -- 去除空白
    key_hex = key_hex:gsub("%s+", "")
    -- 校验：只含 0-9a-fA-F，长度 128（GNB ed25519 私钥 64 字节 = 128 hex chars）
    if not key_hex:match("^[0-9a-fA-F]+$") then
        return nil, "invalid hex characters in key"
    end
    if #key_hex ~= 128 then
        return nil, string.format("key length error: expected 128 hex chars (GNB private key), got %d", #key_hex)
    end

    local dir  = string.format("%s/%s/security", util.GNB_CONF_DIR, nid(node_id))
    local path = string.format("%s/%s.private", dir, nid(node_id))
    util.ensure_dir(dir)
    local ok, werr = util.write_file_secure(path, key_hex .. "\n")
    if not ok then return nil, werr end
    return true, nil
end

-- 保存公鑰到 security 目录（写入 {GNB_CONF_DIR}/{node_id}/security/{node_id}.public）
-- 同时写入 ed25519 目录中自身公鑰
function M.save_public_key(node_id, pub_hex)
    if not pub_hex or pub_hex == "" then return nil, "pub_hex is empty" end
    pub_hex = pub_hex:gsub("%s+", "")
    if not pub_hex:match("^[0-9a-fA-F]+$") then
        return nil, "invalid hex in public key"
    end

    local sec_dir = string.format("%s/%s/security", util.GNB_CONF_DIR, nid(node_id))
    util.ensure_dir(sec_dir)
    local sec_path = string.format("%s/%s.public", sec_dir, nid(node_id))
    local ok, werr = util.write_file(sec_path, pub_hex)
    if not ok then return nil, werr end

    -- 同时写入 ed25519 目录（gnb 运行时从此处读取公钥）
    local ed_dir  = string.format("%s/%s/ed25519", util.GNB_CONF_DIR, nid(node_id))
    util.ensure_dir(ed_dir)
    local ed_path = string.format("%s/%s.public", ed_dir, nid(node_id))
    util.write_file(ed_path, pub_hex)

    return true, nil
end
-- 返回: [{ peer_id, key_hex }]
-- ─────────────────────────────────────────────────────────────
function M.get_peer_keys(node_id)
    local dir     = string.format("%s/%s/ed25519", util.GNB_CONF_DIR, nid(node_id))
    local self_id = nid(node_id)
    local result  = {}

    -- 枚举目录下的 .public 文件
    local ls_out = util.exec("ls " .. dir .. "/*.public 2>/dev/null") or ""
    for path in ls_out:gmatch("[^\n]+") do
        path = util.trim(path)
        if path ~= "" then
            local fname = path:match("([^/]+)$") or ""
            if fname:match("%.public$") then
                local peer_id = fname:gsub("%.public$", "")
                -- 排除自身节点
                if peer_id ~= self_id then
                    local raw = util.read_file(path)
                    if raw then
                        result[#result+1] = {
                            peer_id = peer_id,
                            key_hex = util.trim(raw),
                        }
                    end
                end
            end
        end
    end
    return result
end

-- ─────────────────────────────────────────────────────────────
-- 从 route.conf 内容中提取对端节点 ID 列表（格式: nodeID|network|netmask）
-- 排除自身节点 ID，去重
-- ─────────────────────────────────────────────────────────────
local function extract_peer_ids_from_route(route_content, self_nid)
    local seen  = {}
    local peers = {}
    for line in (route_content .. "\n"):gmatch("([^\n]*)\n") do
        line = line:match("^%s*(.-)%s*$")  -- trim
        if line ~= "" and not line:match("^#") then
            local peer_id = line:match("^([^|]+)|")
            if peer_id then
                peer_id = peer_id:match("^%s*(.-)%s*$")
                if peer_id ~= "" and peer_id ~= self_nid and not seen[peer_id] then
                    seen[peer_id]      = true
                    peers[#peers + 1]  = peer_id
                end
            end
        end
    end
    return peers
end

-- ─────────────────────────────────────────────────────────────
-- 解析 GNB route.conf → 结构化条目
-- 格式: nodeId|network|netmask 或 n|nodeId|network|netmask
-- ─────────────────────────────────────────────────────────────
local function parse_gnb_route_conf(content)
    local entries = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            local parts = {}
            for p in line:gmatch("[^|]+") do
                parts[#parts + 1] = p:match("^%s*(.-)%s*$")
            end
            local node_id, network, netmask
            if #parts >= 4 then
                node_id = parts[2]; network = parts[3]; netmask = parts[4]
            elseif #parts == 3 then
                node_id = parts[1]; network = parts[2]; netmask = parts[3]
            end
            if node_id and network and netmask then
                entries[#entries + 1] = {
                    node_id = node_id, network = network, netmask = netmask
                }
            end
        end
    end
    return entries
end

-- ─────────────────────────────────────────────────────────────
-- 从 route.conf 获取本地对端节点列表
-- 返回: { { node_id=str, virtual_ip=str, is_self=bool }, ... }
-- ─────────────────────────────────────────────────────────────
function M.get_local_peers(node_id)
    local self_nid = nid(node_id)
    local route_path = string.format("%s/%s/route.conf", util.GNB_CONF_DIR, self_nid)
    local route_content = util.trim(util.read_file(route_path) or "")
    if route_content == "" then return {} end

    local entries = parse_gnb_route_conf(route_content)
    -- 按 node_id 分组，取每组第一条记录（VPN IP）
    local seen = {}
    local result = {}
    for _, e in ipairs(entries) do
        if not seen[e.node_id] then
            seen[e.node_id] = true
            result[#result + 1] = {
                node_id    = e.node_id,
                virtual_ip = e.network,
                is_self    = (e.node_id == self_nid),
            }
        end
    end
    return result
end

-- ─────────────────────────────────────────────────────────────
-- 从服务器拉取对端节点公钥并写入 ed25519 目录
-- 只拉取 route.conf 中出现的对端节点（而非全部节点），与 mynet_tui 行为一致
-- 写法：{GNB_CONF_DIR}/{node_id}/ed25519/{peer_id}.public（内容不含换行）
-- 返回: { ok, count, errors=[] }
-- ─────────────────────────────────────────────────────────────
function M.refresh_peer_keys(node_id)
    local current, err = auth.ensure_valid()
    if err then return { ok = false, count = 0, errors = { "auth: " .. err } } end

    local zone    = cfg.load_current_zone()
    local zone_id = zone and zone.zone_id or "0"
    local self_nid = nid(node_id)

    -- 从本地 route.conf 提取对端 node ID
    local route_path = string.format("%s/%s/route.conf", util.GNB_CONF_DIR, self_nid)
    local route_content = util.trim(util.read_file(route_path) or "")
    local peer_ids = extract_peer_ids_from_route(route_content, self_nid)

    local ed25519_dir = string.format("%s/%s/ed25519", util.GNB_CONF_DIR, self_nid)
    util.ensure_dir(ed25519_dir)

    local count  = 0
    local errors = {}
    for _, peer_id in ipairs(peer_ids) do
        local keys_ep = string.format("/nodes/%s/keys", peer_id)
        local kdata, kerr = api.get_json(cfg.get_api_url(), keys_ep, current.token, zone_id)
        local pub_hex = nil
        if not kerr and kdata then
            local d = (kdata.data) or {}
            pub_hex = (d.key and d.key.public_key)
                   or d.public_key
                   or (d.keys and #d.keys > 0 and d.keys[1].public_key)
        end
        if pub_hex and pub_hex ~= "" then
            pub_hex = util.trim(pub_hex)
            -- 验证：64 hex chars（GNB ed25519 公钥 32 字节）
            if #pub_hex == 64 and pub_hex:match("^[0-9a-fA-F]+$") then
                local key_path = string.format("%s/%s.public", ed25519_dir, peer_id)
                -- 写入时不加换行，与 mynet_tui 行为一致
                util.write_file(key_path, pub_hex)
                count = count + 1
            else
                errors[#errors + 1] = "peer " .. peer_id .. ": invalid public key (len=" .. #pub_hex .. ")"
            end
        else
            errors[#errors + 1] = "peer " .. peer_id .. ": " .. (kerr or "no public_key in response")
        end
    end
    return { ok = true, count = count, errors = errors }
end

-- ─────────────────────────────────────────────────────────────
-- 批量获取 peer 公钥（POST /nodes/{id}/router-keys）
-- 优先使用批量 API，若后端不支持则回退到逐个获取
-- 返回: { ok, count, errors=[], method="batch"|"legacy" }
-- ─────────────────────────────────────────────────────────────
function M.refresh_peer_keys_batch(node_id)
    local current, err = auth.ensure_valid()
    if err then return { ok = false, count = 0, errors = { "auth: " .. err }, method = "legacy" } end

    local zone    = cfg.load_current_zone()
    local zone_id = zone and zone.zone_id or "0"
    local self_nid = nid(node_id)

    local kdata, kerr = api.get_router_keys(
        cfg.get_api_url(), self_nid, current.token, zone_id)

    if kerr == "not_supported" or not kdata then
        util.log_info("node", "router-keys API not supported, fallback to per-peer fetch")
        local r = M.refresh_peer_keys(node_id)
        r.method = "legacy"
        return r
    end

    -- 解析响应：兼容 {peer_id: "hex"} 和 {peer_id: {public_key: "hex"}}
    local keys = kdata.data or kdata.keys or kdata
    if type(keys) ~= "table" then
        local r = M.refresh_peer_keys(node_id)
        r.method = "legacy"
        return r
    end

    local ed25519_dir = string.format("%s/%s/ed25519", util.GNB_CONF_DIR, self_nid)
    util.ensure_dir(ed25519_dir)

    local count  = 0
    local errors = {}
    for peer_id, v in pairs(keys) do
        local pub_hex = (type(v) == "string") and v or (type(v) == "table" and v.public_key or nil)
        if pub_hex and pub_hex ~= "" then
            pub_hex = util.trim(pub_hex)
            if #pub_hex == 64 and pub_hex:match("^[0-9a-fA-F]+$") then
                util.write_file(string.format("%s/%s.public", ed25519_dir, peer_id), pub_hex)
                count = count + 1
            else
                errors[#errors + 1] = "peer " .. tostring(peer_id) .. ": invalid key (len=" .. #pub_hex .. ")"
            end
        end
    end
    return { ok = true, count = count, errors = errors, method = "batch" }
end

-- ─────────────────────────────────────────────────────────────
-- 刷新单个配置文件（按类型：node / route / address）
-- 返回: { ok, file, error }
-- ─────────────────────────────────────────────────────────────
function M.refresh_single_config(node_id, config_type)
    if config_type == "node" then
        local node_conf_path = string.format("%s/%s/node.conf",
            cfg.get_gnb_conf_root(), nid(node_id))
        local text, err = M.get_node_config_rendered(node_id)
        if err then return { ok = false, file = node_conf_path, error = err } end
        local ok, we = util.write_file(node_conf_path, (text or "") .. "\n")
        return { ok = ok, file = node_conf_path, error = we }

    elseif config_type == "route" then
        local route_path = string.format("%s/%s/route.conf", util.GNB_CONF_DIR, nid(node_id))
        local text, err  = M.get_route_config_rendered(node_id)
        if err then return { ok = false, file = route_path, error = err } end
        local ok, we = util.write_file(route_path, (text or "") .. "\n")
        if ok then
            -- route 更新后批量同步对端公钥
            local pk_result = M.refresh_peer_keys_batch(node_id)
            util.log_warn(string.format("refresh_single_config(route): synced %d peer keys", pk_result.count))
        end
        return { ok = ok, file = route_path, error = we }

    elseif config_type == "address" then
        local addr_path  = string.format("%s/%s/address.conf", util.GNB_CONF_DIR, nid(node_id))
        local text, err  = M.get_services_index()
        if err then return { ok = false, file = addr_path, error = err } end
        local ok, we = util.write_file(addr_path, (text or "") .. "\n")
        return { ok = ok, file = addr_path, error = we }

    else
        return { ok = false, file = "", error = "unknown config type: " .. tostring(config_type) }
    end
end

-- ─────────────────────────────────────────────────────────────
-- VPN 服务控制（/etc/init.d/mynet）
-- ─────────────────────────────────────────────────────────────

function M.get_vpn_service_status()
    -- 直接检测 gnb 进程（init.d status 在 OpenWrt 不可靠，无 status 命令时总是返回 0）
    local node_id = cfg.get_node_id()
    if node_id and node_id ~= 0 then
        if M.gnb_is_running(node_id) then return "running" end
    end
    -- 兜底：pgrep
    local ps = util.trim(util.exec("pgrep gnb 2>/dev/null") or "")
    if ps ~= "" then return "running" end
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
-- GNB 服务状态机
-- 状态: STOPPED → STARTING → RUNNING → STOPPING → STOPPED / ERROR
-- 状态持久化到 /etc/mynet/var/gnb_state.json（跨请求保持）
-- ─────────────────────────────────────────────────────────────

M.SVC_STATE = {
    STOPPED  = "stopped",
    STARTING = "starting",
    RUNNING  = "running",
    STOPPING = "stopping",
    ERROR    = "error",
}

local GNB_STATE_FILE = util.MYNET_HOME .. "/var/gnb_state.json"

local function load_svc_state()
    return util.load_json_file(GNB_STATE_FILE) or { state = M.SVC_STATE.STOPPED }
end

local function save_svc_state(state, detail)
    util.ensure_dir(util.MYNET_HOME .. "/var")
    util.save_json_file(GNB_STATE_FILE, {
        state   = state,
        detail  = detail or "",
        updated = util.format_time(util.time_now()),
    })
end

function M.get_svc_state()
    local s = load_svc_state()
    -- 若声称 running 则验证进程确实存在
    if s.state == M.SVC_STATE.RUNNING then
        local node_id = cfg.get_node_id()
        if node_id and not M.gnb_is_running(node_id) then
            s.state = M.SVC_STATE.ERROR
            s.detail = "process not found (crashed?)"
            save_svc_state(s.state, s.detail)
        end
    end
    return s
end

-- ─────────────────────────────────────────────────────────────
-- Pre-flight 校验器（对齐 client checker.js）
-- 返回: { ok=bool, checks=[{name, ok, detail}] }
-- ─────────────────────────────────────────────────────────────
function M.preflight_check(node_id)
    local checks = {}
    local all_ok = true
    local n = nid(node_id)

    local function add(name, ok, detail)
        checks[#checks + 1] = { name = name, ok = ok, detail = detail or "" }
        if not ok then all_ok = false end
    end

    -- 1. gnb 二进制
    local gnb_bin = cfg.get_gnb_bin()
    add("gnb_binary", util.file_exists(gnb_bin),
        util.file_exists(gnb_bin) and gnb_bin or "not found: " .. gnb_bin)

    -- 2. node.conf 存在且含 nodeid
    local node_conf_path = string.format("%s/%s/node.conf", cfg.get_gnb_conf_root(), n)
    local node_conf = util.read_file(node_conf_path) or ""
    local has_nodeid = node_conf:match("nodeid%s") ~= nil
    add("node_conf", node_conf ~= "" and has_nodeid,
        node_conf == "" and "missing: " .. node_conf_path
        or (not has_nodeid and "no 'nodeid' in node.conf" or "ok"))

    -- 3. route.conf 存在（非空）
    local route_path = string.format("%s/%s/route.conf", util.GNB_CONF_DIR, n)
    local route_conf = util.read_file(route_path) or ""
    add("route_conf", route_conf ~= "",
        route_conf == "" and "missing: " .. route_path or "ok")

    -- 4. address.conf 有 index server
    local addr_path = string.format("%s/%s/address.conf", util.GNB_CONF_DIR, n)
    local addr_conf = util.read_file(addr_path) or ""
    add("address_conf", addr_conf ~= "",
        addr_conf == "" and "missing (non-fatal): " .. addr_path or "ok")

    -- 5. 私钥存在（128 hex chars）
    local priv_path = string.format("%s/%s/security/%s.private", util.GNB_CONF_DIR, n, n)
    local priv_hex  = util.trim(util.read_file(priv_path) or "")
    local priv_ok   = #priv_hex == 128 and priv_hex:match("^[0-9a-fA-F]+$") ~= nil
    add("private_key", priv_ok,
        not priv_ok and "missing or invalid: " .. priv_path or "ok")

    -- 6. 至少一个 peer 公钥
    local ed_dir = string.format("%s/%s/ed25519", util.GNB_CONF_DIR, n)
    local pk_out = util.exec("ls " .. ed_dir .. "/*.public 2>/dev/null | wc -l") or "0"
    local pk_count = tonumber(util.trim(pk_out)) or 0
    add("peer_keys", pk_count > 0,
        pk_count > 0 and pk_count .. " peer(s)" or "no peer keys in " .. ed_dir)

    -- 7. kmod-tun
    local tun_ok = util.file_exists("/dev/net/tun")
    if not tun_ok then
        local lsmod = util.trim(util.exec("lsmod 2>/dev/null | grep -w tun") or "")
        tun_ok = lsmod ~= ""
    end
    add("kmod_tun", tun_ok,
        tun_ok and "ok" or "/dev/net/tun missing — opkg install kmod-tun")

    return { ok = all_ok, checks = checks }
end

-- ─────────────────────────────────────────────────────────────
-- IP 工具函数（对齐 mynet_client network-routes.js）
-- ─────────────────────────────────────────────────────────────
local function ip_to_int(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return 0 end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    return a * 16777216 + b * 65536 + c * 256 + d
end

local function int_to_ip(n)
    return string.format("%d.%d.%d.%d",
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256)
end

local function netmask_to_cidr(mask)
    if not mask or mask == "" then return 0 end
    if mask:sub(1, 1) == "/" then return tonumber(mask:sub(2)) or 0 end
    local bits = 0
    for octet in mask:gmatch("(%d+)") do
        local n = tonumber(octet) or 0
        while n > 0 do
            bits = bits + (n % 2)
            n = math.floor(n / 2)
        end
    end
    return bits
end

local function network_addr(ip, prefix)
    local n = ip_to_int(ip)
    if prefix == 0 then return "0.0.0.0" end
    -- Lua 不支持 32 位左移，用乘法模拟
    local mask = 0
    for i = 31, 32 - prefix, -1 do
        mask = mask + 2 ^ i
    end
    -- bit-and via floor
    local result = math.floor(n / (2 ^ (32 - prefix))) * (2 ^ (32 - prefix))
    return int_to_ip(result)
end

-- ─────────────────────────────────────────────────────────────
-- 构建路由表（对齐 mynet_client buildRouteTable）
-- 返回: { peer_routes, gw_routes, self_vpn_ip, vpn_subnet }
-- ─────────────────────────────────────────────────────────────
local function build_route_table(entries, self_nid)
    local self_entry
    for _, e in ipairs(entries) do
        if e.node_id == self_nid then self_entry = e; break end
    end
    local self_vpn_ip = self_entry and self_entry.network or nil
    local vpn_mask = 0xFFFFFF00  -- /24
    local vpn_net = self_vpn_ip and math.floor(ip_to_int(self_vpn_ip) / 256) * 256 or 0
    local vpn_subnet = self_vpn_ip
        and (int_to_ip(vpn_net) .. "/24") or nil

    -- 按 node_id 分组（保持插入顺序）
    local by_node = {}
    local node_order = {}
    for _, e in ipairs(entries) do
        if e.node_id ~= self_nid then
            if not by_node[e.node_id] then
                by_node[e.node_id] = {}
                node_order[#node_order + 1] = e.node_id
            end
            local t = by_node[e.node_id]
            t[#t + 1] = e
        end
    end

    local peer_routes = {}   -- cross-zone /32 via selfVpnIp
    local gw_routes = {}     -- subnet via peerVpnIp

    for _, nid_key in ipairs(node_order) do
        local node_entries = by_node[nid_key]
        local peer_vpn_ip = node_entries[1].network

        -- 同子网判断
        local in_same_subnet = self_vpn_ip and
            (math.floor(ip_to_int(peer_vpn_ip) / 256) * 256 == vpn_net)

        if not in_same_subnet and self_vpn_ip then
            peer_routes[#peer_routes + 1] = {
                node_id = nid_key,
                network = peer_vpn_ip,
                cidr    = peer_vpn_ip .. "/32",
                gateway = self_vpn_ip,
            }
        end

        -- 后续条目 = peer 背后的子网
        for i = 2, #node_entries do
            local e = node_entries[i]
            local prefix = netmask_to_cidr(e.netmask)
            local net = network_addr(e.network, prefix)
            gw_routes[#gw_routes + 1] = {
                node_id = nid_key,
                network = net,
                cidr    = net .. "/" .. prefix,
                gateway = peer_vpn_ip,
            }
        end
    end

    return {
        peer_routes  = peer_routes,
        gw_routes    = gw_routes,
        self_vpn_ip  = self_vpn_ip,
        vpn_subnet   = vpn_subnet,
    }
end

-- ─────────────────────────────────────────────────────────────
-- 生成 /etc/mynet/conf/route.conf（OS 级路由配置）
-- 格式对齐 mynet_client network-routes.js generateNetworkConf
-- 输出: <cidr> via <gateway>
-- 同时写入 per-node network.conf（向后兼容）
-- ─────────────────────────────────────────────────────────────
function M.generate_network_conf(node_id)
    local n = nid(node_id)
    local route_path = string.format("%s/%s/route.conf", util.GNB_CONF_DIR, n)
    local route_content = util.trim(util.read_file(route_path) or "")
    if route_content == "" then
        return nil, "route.conf is empty"
    end

    local entries = parse_gnb_route_conf(route_content)
    if #entries == 0 then
        return nil, "no routes parsed from route.conf"
    end

    local rt = build_route_table(entries, n)
    local lines = {
        "# MyNet Network Routes — auto-generated",
        "# Node: " .. n .. " (" .. (rt.self_vpn_ip or "unknown") .. ")",
        "# VPN Subnet: " .. (rt.vpn_subnet or "unknown"),
        "# Updated: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
        "# Format: <cidr> via <gateway>",
        "#!self_vpn_ip=" .. (rt.self_vpn_ip or ""),
        "",
    }

    if #rt.peer_routes > 0 then
        lines[#lines + 1] = "# Cross-zone peer relay routes (via self VPN IP)"
        for _, r in ipairs(rt.peer_routes) do
            lines[#lines + 1] = "# Peer " .. r.node_id .. " (" .. r.network .. ")"
            lines[#lines + 1] = r.cidr .. " via " .. r.gateway
        end
        lines[#lines + 1] = ""
    end

    if #rt.gw_routes > 0 then
        lines[#lines + 1] = "# Subnet routes (via peer VPN IP)"
        local last_nid = ""
        for _, r in ipairs(rt.gw_routes) do
            if r.node_id ~= last_nid then
                lines[#lines + 1] = "# Node " .. r.node_id .. " via " .. r.gateway
                last_nid = r.node_id
            end
            lines[#lines + 1] = r.cidr .. " via " .. r.gateway
        end
    end

    local content = table.concat(lines, "\n") .. "\n"

    -- 写入 per-node network.conf（向后兼容）
    local conf_path = string.format("%s/%s/network.conf", util.GNB_CONF_DIR, n)
    local ok, we = util.write_file(conf_path, content)
    if not ok then return nil, "write network.conf: " .. (we or "") end

    -- 同步写入 /etc/mynet/conf/route.conf（供 rc.mynet + service tab 使用）
    util.ensure_dir(util.CONF_DIR)
    util.write_file(util.CONF_DIR .. "/route.conf", content)

    return conf_path, nil
end

-- ─────────────────────────────────────────────────────────────
-- 直接启动/停止 GNB 进程（带状态机 + pre-flight）
-- 命令：{GNB_BIN_DIR}/gnb -c {GNB_CONF_DIR}/{nid}
-- ─────────────────────────────────────────────────────────────
local function gnb_pidfile(node_id)
    return string.format("%s/%s/gnb.pid", util.GNB_CONF_DIR, nid(node_id))
end

function M.gnb_is_running(node_id)
    local pidfile = gnb_pidfile(node_id)
    local pid_str = util.trim(util.read_file(pidfile) or "")
    if pid_str == "" then return false end
    local pid = tonumber(pid_str)
    if not pid then return false end
    local stat = util.exec("test -d /proc/" .. pid .. " && echo y 2>/dev/null")
    return util.trim(stat or "") == "y"
end

function M.start_gnb(node_id)
    local n    = nid(node_id)
    local bin  = util.GNB_BIN_DIR .. "/gnb"
    local conf = string.format("%s/%s", util.GNB_CONF_DIR, n)
    local log  = conf .. "/gnb.log"
    local pid  = gnb_pidfile(node_id)

    if M.gnb_is_running(node_id) then
        save_svc_state(M.SVC_STATE.RUNNING, "already running")
        return nil, "gnb already running for node " .. n
    end

    -- route.conf 缺失时自动尝试刷新配置（在线模式从 API 拉取）
    local route_path = string.format("%s/%s/route.conf", util.GNB_CONF_DIR, n)
    local route_content = util.trim(util.read_file(route_path) or "")
    if route_content == "" then
        util.log_info("node", "route.conf missing for " .. n .. ", attempting refresh_configs")
        M.refresh_configs(node_id)
    end

    -- Pre-flight check
    local pf = M.preflight_check(node_id)
    if not pf.ok then
        local failed = {}
        for _, c in ipairs(pf.checks) do
            if not c.ok then failed[#failed + 1] = c.name .. ": " .. c.detail end
        end
        local reason = "pre-flight failed: " .. table.concat(failed, "; ")
        save_svc_state(M.SVC_STATE.ERROR, reason)
        return nil, reason
    end

    -- 状态 → STARTING
    save_svc_state(M.SVC_STATE.STARTING, "spawning gnb")

    -- 生成 network.conf
    local nconf, nconf_err = M.generate_network_conf(node_id)
    if nconf then
        util.log_info("node", "generated " .. nconf)
    elseif nconf_err then
        util.log_warn("node", "network.conf: " .. nconf_err)
    end

    util.ensure_dir(conf)
    local cmd = string.format(
        "'%s' -c '%s' </dev/null >> '%s' 2>&1 & echo $! > '%s'",
        bin, conf, log, pid)
    util.exec(cmd)

    -- 等待 TUN 接口就绪（最多 5 秒）
    local iface = cfg.get_vpn_interface()
    local tun_ready = false
    for _ = 1, 5 do
        util.exec("sleep 1")
        if not M.gnb_is_running(node_id) then
            save_svc_state(M.SVC_STATE.ERROR, "gnb exited immediately, check " .. log)
            return nil, "gnb process exited immediately, check " .. log
        end
        local link = util.exec("ip link show " .. iface .. " 2>/dev/null") or ""
        if link ~= "" then
            tun_ready = true
            break
        end
    end

    if tun_ready then
        save_svc_state(M.SVC_STATE.RUNNING, "gnb running, tun ready")
        util.log_info("node", "gnb started for node " .. n .. ", tun interface ready")
    else
        save_svc_state(M.SVC_STATE.RUNNING, "gnb running, tun not yet detected")
        util.log_warn("node", "gnb started but tun interface not detected within 5s")
    end

    return true, nil
end

function M.stop_gnb(node_id)
    save_svc_state(M.SVC_STATE.STOPPING, "killing gnb")
    local pidfile = gnb_pidfile(node_id)
    local pid_str = util.trim(util.read_file(pidfile) or "")
    if pid_str ~= "" then
        local pid_num = tonumber(pid_str)
        if pid_num then
            util.exec("kill " .. pid_num .. " 2>/dev/null; true")
            util.exec("sleep 1")
            util.exec("kill -9 " .. pid_num .. " 2>/dev/null; true")
        end
        util.exec("rm -f '" .. pidfile .. "'")
    end
    save_svc_state(M.SVC_STATE.STOPPED, "gnb stopped")
    return true, nil
end

function M.restart_gnb(node_id)
    M.stop_gnb(node_id)
    util.exec("sleep 1")
    return M.start_gnb(node_id)
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

-- ─────────────────────────────────────────────────────────────
-- 生成新 GNB 密钥对（调用 gnb_crypto -c，写入临时目录后读取）
-- 返回: { priv_hex, pub_hex }, nil  或  nil, error_string
-- ─────────────────────────────────────────────────────────────
function M.generate_key_pair()
    local gnc = util.GNB_BIN_DIR .. "/gnb_crypto"
    if not util.file_exists(gnc) then
        return nil, "gnb_crypto not found: " .. gnc
    end

    -- 创建临时目录
    local tmpd = util.trim(util.exec("mktemp -d 2>/dev/null") or "")
    if tmpd == "" then return nil, "mktemp failed" end

    local priv_f = tmpd .. "/k.private"
    local pub_f  = tmpd .. "/k.public"

    local _, code = util.exec_status(
        string.format("'%s' -c -p '%s' -k '%s' 2>/dev/null", gnc, priv_f, pub_f))

    if code ~= 0 then
        os.execute("rm -rf '" .. tmpd .. "'")
        return nil, "gnb_crypto failed (exit=" .. tostring(code) .. ")"
    end

    local priv_hex = util.trim(util.read_file(priv_f) or "")
    local pub_hex  = util.trim(util.read_file(pub_f)  or "")
    os.execute("rm -rf '" .. tmpd .. "'")

    if priv_hex == "" or pub_hex == "" then
        return nil, "key generation produced empty output"
    end
    return { priv_hex = priv_hex, pub_hex = pub_hex }, nil
end

-- ─────────────────────────────────────────────────────────────
-- 从服务器下载本节点公钥并写入本地（GET /nodes/{id}/keys）
-- 返回: pub_hex, nil  或  nil, error_string
-- ─────────────────────────────────────────────────────────────
function M.fetch_server_public_key(node_id)
    local current, err = auth.ensure_valid()
    if err then return nil, err end

    local zone    = cfg.load_current_zone()
    local zone_id = zone and zone.zone_id or "0"
    local endpoint = string.format("/nodes/%s/keys", nid(node_id))

    local kdata, kerr = api.get_json(cfg.get_api_url(), endpoint, current.token, zone_id)
    if kerr then return nil, kerr end

    local d = (kdata and kdata.data) or {}
    local pub_hex = (d.key and d.key.public_key)
               or d.public_key
               or (d.keys and #d.keys > 0 and d.keys[1].public_key)
    if not pub_hex or pub_hex == "" then
        return nil, "no public_key in server response"
    end
    pub_hex = util.trim(pub_hex)
    if #pub_hex ~= 64 or not pub_hex:match("^[0-9a-fA-F]+$") then
        return nil, string.format("invalid public key from server (len=%d)", #pub_hex)
    end
    -- 写入 security/ 和 ed25519/ 目录
    local ok, werr = M.save_public_key(node_id, pub_hex)
    if not ok then return nil, werr end
    return pub_hex, nil
end

-- 上传公钥到服务器（POST /nodes/{id}/keys/upload）
-- 返回: true, nil  或  nil, error_string
-- ─────────────────────────────────────────────────────────────────────────────
function M.upload_public_key(node_id, pub_hex)
    local current, err = auth.ensure_valid()
    if err then return nil, err end

    local zone    = cfg.load_current_zone()
    local zone_id = zone and zone.zone_id or "0"
    local endpoint = string.format("/nodes/%s/keys/upload", nid(node_id))

    local data, api_err = api.post_json(cfg.get_api_url(), endpoint,
        { custom_public_key = pub_hex, force_regenerate = true },
        current.token, zone_id)
    if api_err then return nil, api_err end
    if not data or not data.success then
        return nil, (data and data.message) or "upload public key failed"
    end
    return true, nil
end

return M
