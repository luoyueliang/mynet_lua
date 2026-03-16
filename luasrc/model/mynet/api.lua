-- mynet/api.lua  — HTTP REST 客户端
-- 通过 curl 实现所有与 MyNet 服务端的 HTTP 通信。
-- 对应 Go 项目 internal/api/client.go 的核心功能。

local M   = {}
local util = require("luci.model.mynet.util")

local DEFAULT_TIMEOUT = 30  -- 秒

-- ─────────────────────────────────────────────────────────────
-- 内部：构建 curl 命令并执行
-- 返回: body_string, http_status_code, error_string
-- ─────────────────────────────────────────────────────────────

local function do_curl(method, url, json_body, extra_headers, accept_type, timeout)
    local t = timeout or DEFAULT_TIMEOUT

    -- 使用 -D - 将响应头输出到 stdout，以便解析状态码（更可靠）
    -- -w "\n__STATUS:%{http_code}" 在末尾附加状态码标记
    local parts = {
        "curl", "-s",
        "-w", "'\n__STATUS:%{http_code}'",
        "-m", tostring(t),
        "-X", method,
    }

    -- 请求头
    local headers = {
        ["User-Agent"] = "mynet-luci/1.0.0",
        ["Accept"]     = accept_type or "application/json",
    }
    for k, v in pairs(extra_headers or {}) do
        headers[k] = v
    end
    for k, v in pairs(headers) do
        -- 安全转义单引号
        local safe_v = tostring(v):gsub("'", "'\\''")
        parts[#parts+1] = string.format("-H '%s: %s'", k, safe_v)
    end

    -- 请求体
    if json_body then
        local safe_body = json_body:gsub("'", "'\\''")
        parts[#parts+1] = "-H 'Content-Type: application/json'"
        parts[#parts+1] = "--data '" .. safe_body .. "'"
    end

    -- URL
    local safe_url = url:gsub("'", "'\\''")
    parts[#parts+1] = "'" .. safe_url .. "'"

    local cmd = table.concat(parts, " ")
    local raw = util.exec(cmd)

    if not raw then
        return nil, 0, "curl execution failed"
    end

    -- 从末尾提取 HTTP 状态码
    local status_str  = raw:match("__STATUS:(%d+)'?%s*$")
    local body        = raw:gsub("\n?%'?__STATUS:%d+'?%s*$", "")
    local status_code = tonumber(status_str) or 0

    return body, status_code, nil
end

-- ─────────────────────────────────────────────────────────────
-- 公开接口
-- ─────────────────────────────────────────────────────────────

-- 构建鉴权请求头
local function auth_headers(token, zone_id)
    local h = {}
    if token and token ~= "" then
        h["Authorization"] = "Bearer " .. token
    end
    local zid = tostring(zone_id or "")
    if zid ~= "" and zid ~= "0" then
        h["X-Zone-ID"] = zid
    end
    return h
end

-- GET → JSON table
-- returns: (table, nil)  或  (nil, error_string)
function M.get_json(base_url, endpoint, token, zone_id)
    local url = base_url .. endpoint
    local body, status, err = do_curl("GET", url, nil, auth_headers(token, zone_id))
    if err then return nil, err end
    if status == 0 then return nil, "connection failed (timeout or unreachable)" end

    local data = util.json_decode(body)
    if not data then
        return nil, string.format("invalid JSON (http=%d body=%s)", status, (body or ""):sub(1, 200))
    end
    if status >= 400 then
        return nil, string.format("api error %d: %s", status, tostring(data.message or "unknown"))
    end
    return data, nil
end

-- POST JSON body → JSON table
function M.post_json(base_url, endpoint, payload, token, zone_id)
    local url  = base_url .. endpoint
    local body_str = util.json_encode(payload) or "{}"
    local resp, status, err = do_curl("POST", url, body_str, auth_headers(token, zone_id))
    if err then return nil, err end
    if status == 0 then return nil, "connection failed" end

    local data = util.json_decode(resp)
    if not data then
        return nil, string.format("invalid JSON (http=%d)", status)
    end
    if status >= 400 then
        return nil, string.format("api error %d: %s", status, tostring(data.message or "unknown"))
    end
    return data, nil
end

-- PATCH JSON body → JSON table
function M.patch_json(base_url, endpoint, payload, token, zone_id)
    local url      = base_url .. endpoint
    local body_str = util.json_encode(payload) or "{}"
    local resp, status, err = do_curl("PATCH", url, body_str, auth_headers(token, zone_id))
    if err then return nil, err end
    if status == 0 then return nil, "connection failed" end

    local data = util.json_decode(resp)
    if not data then
        return nil, string.format("invalid JSON (http=%d)", status)
    end
    if status >= 400 then
        return nil, string.format("api error %d: %s", status, tostring(data.message or "unknown"))
    end
    return data, nil
end

-- PUT JSON body → JSON table
function M.put_json(base_url, endpoint, payload, token, zone_id)
    local url      = base_url .. endpoint
    local body_str = util.json_encode(payload) or "{}"
    local resp, status, err = do_curl("PUT", url, body_str, auth_headers(token, zone_id))
    if err then return nil, err end
    if status == 0 then return nil, "connection failed" end

    local data = util.json_decode(resp)
    if not data then
        return nil, string.format("invalid JSON (http=%d)", status)
    end
    if status >= 400 then
        return nil, string.format("api error %d: %s", status, tostring(data.message or "unknown"))
    end
    return data, nil
end

-- GET plain text（用于 render_conf=1 接口，直接返回配置文本）
-- 对应 Go: GetNodeConfigRendered / GetRouteConfigRendered
function M.get_text(base_url, endpoint, token, zone_id)
    local url  = base_url .. endpoint
    local body, status, err = do_curl("GET", url, nil, auth_headers(token, zone_id), "text/plain")
    if err then return nil, err end
    if status == 0 then return nil, "connection failed" end
    if status >= 400 then
        return nil, string.format("api error %d", status)
    end
    return util.trim(body or ""), nil
end

return M
