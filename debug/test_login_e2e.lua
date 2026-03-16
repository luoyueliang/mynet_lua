-- 端到端登录测试：验证 64-bit ID 精度修复
package.path = "/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;" .. package.path

local auth = require("luci.model.mynet.auth")
local cred = require("luci.model.mynet.credential")
local cfg  = require("luci.model.mynet.config")

print("=== mynet login e2e test ===")
print("api_url: " .. cfg.get_api_url())

-- 1. 登录
local c, err = auth.login("luoyueliang@gmail.com", "Lyt@2017")
if err then
  print("LOGIN FAIL: " .. tostring(err))
  os.exit(1)
end
print("\n[1] LOGIN OK")
print("  token:     " .. c.token:sub(1,24) .. "...")
print("  user_id:   " .. tostring(c.user_id))
print("  zone_id:   " .. tostring(c.zone_id))
print("  expires_at:" .. tostring(c.expires_at))

-- 2. 验证 ID 是否为纯数字字符串（无科学计数法）
local uid_str = tostring(c.user_id)
local zid_str = tostring(c.zone_id)
local uid_ok  = uid_str:match("^%d+$") ~= nil
local zid_ok  = zid_str:match("^%d+$") ~= nil
print("\n[2] ID 精度检查")
print("  user_id digits-only: " .. (uid_ok and "PASS" or "FAIL  <-- " .. uid_str))
print("  zone_id digits-only: " .. (zid_ok and "PASS" or "FAIL  <-- " .. zid_str))

-- 3. 读回 credential.json
local loaded = cred.load()
print("\n[3] credential.json 读回")
if loaded then
  local lu = tostring(loaded.user_id)
  local lz = tostring(loaded.zone_id)
  print("  user_id:  " .. lu .. (lu:match("^%d+$") and " (OK)" or " <-- PRECISION LOSS"))
  print("  zone_id:  " .. lz .. (lz:match("^%d+$") and " (OK)" or " <-- PRECISION LOSS"))
  print("  is_valid: " .. tostring(cred.is_valid(loaded)))
else
  print("  FAIL: could not load credential")
end

-- 4. 验证 X-Zone-ID header 内容
print("\n[4] X-Zone-ID header value")
print("  会发送: " .. zid_str)

print("\n=== done ===")
