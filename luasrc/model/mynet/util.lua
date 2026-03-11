-- mynet/util.lua  — 基础工具模块
-- 提供文件 I/O、Shell 执行、JSON 编解码、日志等公共能力。
-- 所有其他 mynet 模块都依赖本模块；本模块不依赖其他 mynet 模块。

local M = {}

-- ─────────────────────────────────────────────────────────────
-- 路径常量
-- ─────────────────────────────────────────────────────────────

M.MYNET_HOME  = "/etc/mynet"
M.CONF_DIR    = M.MYNET_HOME .. "/conf"
M.CRED_FILE   = M.CONF_DIR  .. "/credential.json"
M.CONFIG_FILE = M.CONF_DIR  .. "/config.json"
M.ZONE_FILE   = M.CONF_DIR  .. "/zone.json"
M.VPN_CONF    = M.CONF_DIR  .. "/mynet.conf"
M.LOG_FILE    = M.MYNET_HOME .. "/logs/luci.log"

-- ─────────────────────────────────────────────────────────────
-- JSON（优先使用 luci.jsonc，失败则降级）
-- ─────────────────────────────────────────────────────────────

local _jsonc_ok, _jsonc = pcall(require, "luci.jsonc")

local function _json_encode(obj)
    if _jsonc_ok then
        local ok, s = pcall(_jsonc.stringify, obj)
        if ok then return s end
    end
    -- 极简降级实现（仅支持简单嵌套对象/数组/字符串/数字/布尔/nil）
    local t = type(obj)
    if t == "nil"     then return "null" end
    if t == "boolean" then return obj and "true" or "false" end
    if t == "number"  then return tostring(obj) end
    if t == "string"  then
        return '"' .. obj:gsub('\\','\\\\'):gsub('"','\\"')
                         :gsub('\n','\\n'):gsub('\r','\\r')
                         :gsub('\t','\\t') .. '"'
    end
    if t == "table" then
        -- array?
        local is_arr = (#obj > 0)
        if is_arr then
            local parts = {}
            for _, v in ipairs(obj) do parts[#parts+1] = _json_encode(v) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(obj) do
                parts[#parts+1] = _json_encode(tostring(k)) .. ":" .. _json_encode(v)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

local function _json_decode(str)
    if _jsonc_ok then
        local ok, result = pcall(_jsonc.parse, str)
        if ok then return result end
    end
    return nil
end

-- 对外接口
function M.json_encode(obj) return _json_encode(obj) end
function M.json_decode(str) return _json_decode(str) end

-- ─────────────────────────────────────────────────────────────
-- Shell 执行
-- ─────────────────────────────────────────────────────────────

-- 执行命令，返回 stdout（忽略 stderr）
function M.exec(cmd)
    local h = io.popen(cmd .. " 2>/dev/null")
    if not h then return nil end
    local out = h:read("*a")
    h:close()
    return out
end

-- 执行命令，返回 (stdout+stderr, exit_code)
function M.exec_status(cmd)
    local marker = "__MYNET_EXIT__"
    local h = io.popen(cmd .. " 2>&1; echo " .. marker .. ":$?")
    if not h then return nil, -1 end
    local raw = h:read("*a")
    h:close()
    local code_str = raw:match(marker .. ":(%d+)%s*$")
    local output   = raw:gsub("\n?" .. marker .. ":%d+%s*$", "")
    return output, tonumber(code_str) or -1
end

-- ─────────────────────────────────────────────────────────────
-- 文件系统
-- ─────────────────────────────────────────────────────────────

function M.file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

function M.ensure_dir(path)
    os.execute("mkdir -p " .. path)
end

function M.read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end

-- 写文件（自动创建父目录）
function M.write_file(path, content)
    local dir = path:match("(.+)/[^/]+$")
    if dir then M.ensure_dir(dir) end
    local f = io.open(path, "w")
    if not f then return false, "cannot write: " .. path end
    f:write(content)
    f:close()
    return true
end

-- 加载 JSON 文件 → Lua table
function M.load_json_file(path)
    local c = M.read_file(path)
    if not c then return nil end
    return M.json_decode(c)
end

-- 保存 Lua table → JSON 文件
function M.save_json_file(path, obj)
    local s = M.json_encode(obj)
    if not s then return false, "json encode failed" end
    return M.write_file(path, s)
end

-- ─────────────────────────────────────────────────────────────
-- 字符串工具
-- ─────────────────────────────────────────────────────────────

function M.trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$")
end

-- ─────────────────────────────────────────────────────────────
-- 时间
-- ─────────────────────────────────────────────────────────────

function M.time_now()
    return os.time()
end

-- 格式化为本地时间字符串（ISO 8601，不含时区）
function M.format_time(ts)
    return os.date("%Y-%m-%dT%H:%M:%S", ts)
end

-- 解析简单 ISO 8601 字符串 → Unix timestamp（忽略时区偏移）
function M.parse_time(str)
    if not str or str == "" then return 0 end
    local y, mo, d, h, mi, s = str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return 0 end
    return os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min   = tonumber(mi),  sec = tonumber(s),
        isdst = false,
    })
end

-- ─────────────────────────────────────────────────────────────
-- 设备 ID
-- ─────────────────────────────────────────────────────────────

function M.get_machine_id()
    local id = M.read_file("/etc/machine-id")
    if id and M.trim(id) ~= "" then return M.trim(id) end
    -- OpenWrt：使用 br-lan 或 eth0 的 MAC 地址
    local mac = M.exec("cat /sys/class/net/br-lan/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null")
    if mac and M.trim(mac) ~= "" then
        return M.trim(mac):gsub(":", "")
    end
    return "openwrt-device"
end

-- ─────────────────────────────────────────────────────────────
-- 日志（写到文件，非阻断性）
-- ─────────────────────────────────────────────────────────────

function M.log(level, msg)
    local ts   = os.date("%Y-%m-%d %H:%M:%S")
    local line = string.format("[%s] [%-5s] %s\n", ts, level, msg)
    M.ensure_dir(M.MYNET_HOME .. "/logs")
    local f = io.open(M.LOG_FILE, "a")
    if f then f:write(line); f:close() end
end

function M.log_info(msg)  M.log("INFO",  msg) end
function M.log_warn(msg)  M.log("WARN",  msg) end
function M.log_error(msg) M.log("ERROR", msg) end

return M
