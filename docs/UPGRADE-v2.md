# mynet_lua (OpenWrt LuCI) — v2 升级指南

> 优先级: **P1（第五批升级）** — 依赖 CTL v2 + back v2 先就绪
> 关联文档: `mynet_ctl/docs/v2-upgrade-plan.md`（总规划）

---

## 一、当前状态

| 项目 | 值 |
|------|------|
| 框架 | Lua/LuCI, OpenWrt 包 (luci-app-mynet) |
| 版本 | 1.0.0 (Makefile PKG_VERSION) |
| 产品名 | 使用 `mynet` (tui) 产品的 binary |

**当前 URL 配置（需迁移）：**

| 文件 | 当前 URL | 问题 |
|------|----------|------|
| `luasrc/model/mynet/config.lua` → `DEFAULT_API_URL` | `https://api.mynet.club/api/v1` | 改为 v2 |
| `luasrc/model/mynet/gnb_installer.lua` → `APPS_INDEX` | `https://download.mynet.club/apps.json` | ⚠️ 已废弃 |
| `scripts/upgrade/upgrade-manager.sh` → `MANIFEST_URL` | `https://download.mynet.club/mynet/manifest.json` | ⚠️ 已废弃 |

---

## 二、升级任务

### 2.1 更新 config.lua 默认 API URL

**文件: `luasrc/model/mynet/config.lua`**

```lua
-- 旧值:
-- local DEFAULT_API_URL = "https://api.mynet.club/api/v1"
-- 新值:
local DEFAULT_API_URL = "https://api.mynet.club/api/v2"
```

### 2.2 更新 gnb_installer.lua 索引 URL

**文件: `luasrc/model/mynet/gnb_installer.lua`**

```lua
-- 旧值:
-- local APPS_INDEX = "https://download.mynet.club/apps.json"
-- 新值:
local APPS_INDEX = "https://ctl.mynet.club/api/v2/apps"
```

同时检查 manifest 请求逻辑：
- 旧: 从 apps.json 获取 manifest URL → 请求 `xxx/manifest.json`
- 新: 从 `/api/v2/apps` 获取 manifest URL → 请求 `xxx/manifest`（无 `.json` 后缀）

### 2.3 更新 upgrade-manager.sh

**文件: `scripts/upgrade/upgrade-manager.sh`**

```bash
# 旧值:
# MANIFEST_URL="https://download.mynet.club/mynet/manifest.json"
# 新值:
MANIFEST_URL="https://ctl.mynet.club/api/v2/mynet/manifest"
```

---

## 三、需要修改的文件清单

| 文件 | 操作 | 变更 |
|------|------|------|
| `luasrc/model/mynet/config.lua` | 编辑 | DEFAULT_API_URL → v2 |
| `luasrc/model/mynet/gnb_installer.lua` | 编辑 | APPS_INDEX → CTL v2 |
| `scripts/upgrade/upgrade-manager.sh` | 编辑 | MANIFEST_URL → CTL v2 |

---

## 四、验证方法

```bash
# 1. 在 OpenWrt 路由器上测试（或 QEMU）
# 修改 config.lua 指向本地:
#   DEFAULT_API_URL = "http://api.mynet.local/api/v2"
#   APPS_INDEX = "http://ctl.mynet.local/api/v2/apps"

# 2. 在 LuCI 中操作
# - 登录 → 检查 API 连接
# - 安装 GNB → 检查 binary 下载

# 3. 验证 upgrade-manager.sh
sh scripts/upgrade/upgrade-manager.sh --check
```

---

## 五、回滚方案

修改 Lua 源文件中的 URL 常量回 v1 地址，重新编译 ipk 包。

---

## 六、注意事项

- OpenWrt 设备上使用 `wget`（BusyBox 版本），确保 CTL 的 HTTPS 证书被信任
- 如果设备无法解析 `ctl.mynet.club`，需确认 DNS 配置正确
- 升级脚本 `upgrade-manager.sh` 在设备上直接运行，需测试网络环境

**预计工作量**: 中（2-3 小时，含 OpenWrt 实机测试）
