# MyNet LuCI 测试报告

**测试日期**: 2025-06-02  
**测试环境**: OpenWrt QEMU (x86_64), LuCI + Argon 主题  
**测试版本**: v1.0.0 (refactor commit)  
**测试方法**: curl CLI + SSH 远程验证  

---

## 1. Lua 模块语法与加载测试

| 模块 | 本地 luac -p | OpenWrt 加载 | 状态 |
|------|:-----------:|:----------:|:----:|
| util.lua | ✅ | ✅ | PASS |
| api.lua | ✅ | ✅ | PASS |
| auth.lua | ✅ | ✅ | PASS |
| config.lua | ✅ | ✅ | PASS |
| credential.lua | ✅ | ✅ | PASS |
| gnb_installer.lua | ✅ | ✅ | PASS |
| guest.lua | ✅ | ✅ | PASS |
| node.lua | ✅ | ✅ | PASS |
| proxy.lua | ✅ | ✅ | PASS |
| system.lua | ✅ | ✅ | PASS |
| util.lua | ✅ | ✅ | PASS |
| validator.lua | ✅ | ✅ | PASS |
| zone.lua | ✅ | ✅ | PASS |
| **controller/mynet.lua** | ✅ | ✅ | PASS |

---

## 2. 页面渲染测试

| 页面 | URL 路径 | HTTP 状态 | 预期 | 状态 |
|------|---------|:---------:|------|:----:|
| Dashboard | /admin/services/mynet/index | 200 | 正常渲染 | PASS |
| Wizard（未配置） | /admin/services/mynet/wizard | 200 | 显示单选模式 | PASS |
| Wizard（已配置） | /admin/services/mynet/wizard | 302→guest | 重定向到 guest | PASS |
| Login | /admin/services/mynet/login | 200 | 正常渲染 | PASS |
| Guest | /admin/services/mynet/guest | 200 | 正常渲染 | PASS |
| Node（未配置） | /admin/services/mynet/node | 302→wizard | 重定向 | PASS |
| Node（已配置） | /admin/services/mynet/node | 200 | 正常渲染 | PASS |
| Service | /admin/services/mynet/service | 200 | 正常渲染 | PASS |
| Settings | /admin/services/mynet/settings | 200 | 正常渲染 | PASS |
| Diagnose | /admin/services/mynet/diagnose | 302 | 需配置节点 | PASS |
| Log | /admin/services/mynet/log | 302 | 需 MyNet 认证 | PASS |

---

## 3. Wizard 单选 UX 测试

| 测试项 | 结果 |
|--------|:----:|
| 4 行 radio button 正确渲染 | PASS |
| 默认选中 Online Mode（第一行） | PASS |
| "继续" 按钮正确显示（i18n 翻译生效） | PASS |
| 每行 `data-mode` 属性正确 | PASS |
| JS `mnWizardSelect()` / `mnWizardGo()` 函数存在 | PASS |
| URL 映射正确（online→login, import→guest?mode=import, create→guest?mode=create, manual→node?tab=config） | PASS |

---

## 4. API 端点测试

### 4.1 认证 + 速率限制

| 测试项 | 结果 |
|--------|:----:|
| `require_api_auth()` 在 Guest 模式下返回 `{ guest: true }` | PASS |
| CSRF Token 验证（POST 请求需要 token） | PASS |
| 速率限制触发（5/min for guest_import） | PASS |
| 无效 node_id 注入尝试被拒 (`123;rm -rf` → "invalid node_id") | PASS |

### 4.2 API 功能测试

| API | 方法 | 结果 | 状态 |
|-----|------|------|:----:|
| /api/svc_state | POST | `{"success":true,"data":{"state":"stopped"}}` | PASS |
| /api/proxy_status | POST | 返回代理状态 | PASS |
| /api/dashboard_stats | POST | 返回系统指标 | PASS |
| /api/preflight (无 node_id) | POST | `{"message":"node_id required"}` | PASS |
| /api/gnb_start (无效 node_id) | POST | `{"message":"invalid node_id"}` | PASS |
| /api/gnb_start (有效 node_id, 无配置) | POST | 返回 pre-flight 失败详情 | PASS |

---

## 5. Guest 导入流程测试

**测试文件**: `~/Downloads/gnb_node_2003.tar.gz` (877 bytes)

| 步骤 | 结果 | 状态 |
|------|------|:----:|
| Base64 上传 + Preview | 正确解析 node_id=2003、4 peer routes、密钥指纹 | PASS |
| Apply (step=apply) | `{"success":true,"node_id":"2003"}` | PASS |
| 文件写入验证 | `/etc/mynet/driver/gnb/conf/2003/` 包含 node.conf, route.conf, address.conf, ed25519/, security/ | PASS |
| 配置后 node 页面可访问 (HTTP 200) | PASS |

---

## 6. 重构验证测试

### 6.1 util.lua 新增函数

| 函数 | 测试 | 状态 |
|------|------|:----:|
| `nid_fmt` (= `int_str` 别名) | 模板中使用正常 | PASS |
| `fmt_bytes` | 模块加载无错误 | PASS |
| `parse_bash_conf` | config.lua / proxy.lua 使用成功 | PASS |
| `ensure_dir` (使用 shell_escape) | 目录创建正常 | PASS |

### 6.2 Controller 重构

| 重构项 | 影响范围 | 状态 |
|--------|----------|:----:|
| `parse_node_id()` 替换 10 处 inline 解析 | gnb_start/stop/restart, node_refresh/save_key/switch/gen_key, preflight, heartbeat, guest_use | PASS |
| `require_api_auth()` 替换 12 处 inline auth | get_nodes, get_zones, node_refresh/save_key/switch/gen_key, heartbeat, proxy_status/start/stop/reload/diagnose/config | PASS |

### 6.3 api.lua 重构

| 重构项 | 状态 |
|--------|:----:|
| `parse_json_response()` 提取（消除 4 处重复） | PASS |

### 6.4 JS 修复

| 修复项 | 状态 |
|--------|:----:|
| 删除 `mnNodeRefreshAll()` 冗余定义 (L754) | PASS |

### 6.5 gnb_installer.lua

| 修复项 | 状态 |
|--------|:----:|
| 删除冗余 `json_decode()` 包装器，改用 `util.json_decode()` | PASS |

---

## 7. i18n 翻译测试

| 测试项 | 结果 | 状态 |
|--------|------|:----:|
| PO 文件编译为 LMO | 382 翻译条目写入 | PASS |
| "Continue" → "继续" 在 wizard 页显示 | PASS |
| 新增 5 条翻译（Continue, No peers, Configure node first, Switch/Use This Config） | PASS |

---

## 8. 部署测试

| 步骤 | 结果 | 状态 |
|------|------|:----:|
| `bash debug/sync.sh all` 构建 ipk | 180,849 bytes | PASS |
| SCP 上传到 QEMU | 成功 | PASS |
| `opkg install` 安装 | 成功（含 conffile 保留） | PASS |
| LuCI 缓存自动清理 | 成功 | PASS |
| 所有页面可正常访问 | 已逐一验证 | PASS |

---

## 测试总结

| 类别 | 通过 | 失败 | 总计 |
|------|:----:|:----:|:----:|
| Lua 语法/加载 | 14 | 0 | 14 |
| 页面渲染 | 11 | 0 | 11 |
| Wizard UX | 6 | 0 | 6 |
| API 安全 | 4 | 0 | 4 |
| API 功能 | 6 | 0 | 6 |
| Guest 导入 | 4 | 0 | 4 |
| 重构验证 | 9 | 0 | 9 |
| i18n | 3 | 0 | 3 |
| 部署 | 4 | 0 | 4 |
| **合计** | **61** | **0** | **61** |

**测试结果**: 全部通过 ✅
