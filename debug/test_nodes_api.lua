package.path = "/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;" .. package.path
local api  = require("luci.model.mynet.api")
local cfg  = require("luci.model.mynet.config")
local cred = require("luci.model.mynet.credential")

local c = cred.load()
if not c then print("no cred"); os.exit(1) end
print("zone_id in cred: " .. tostring(c.zone_id))

-- 用 credential 里的 zone_id 请求
local data, err = api.get_json(cfg.get_api_url(), "/nodes?page=1&per_page=5", c.token, c.zone_id)
if err then print("err: " .. err); os.exit(1) end

local function dump(t, indent)
    indent = indent or ""
    for k, v in pairs(t or {}) do
        if type(v) == "table" then
            print(indent .. tostring(k) .. " = {")
            if #v > 0 then
                print(indent .. "  [array len=" .. #v .. "]")
                if #v > 0 then
                    print(indent .. "  [0]=")
                    dump(v[1], indent .. "    ")
                end
            else
                dump(v, indent .. "  ")
            end
            print(indent .. "}")
        else
            print(indent .. tostring(k) .. " = " .. tostring(v))
        end
    end
end

dump(data)
