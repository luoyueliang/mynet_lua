# mynet_lua 升级计划 — 对齐 mynet_client 架构

> 创建: 2026-03-28
> 基准: mynet_client v2.0.0 (完成度 ~90%)
> 目标: mynet_lua (OpenWrt LuCI) 功能对齐、架构现代化

---

## 一、现状对比总览

| 维度 | mynet_client (Node.js) | mynet_lua (LuCI/Lua) | 差距评估 |
|------|----------------------|---------------------|---------|
| **认证** | JWT + 自动刷新 + 去重 | JWT + 自动刷新 | ⬜ 基本对齐 |
| **Zone/Node** | 完整 CRUD + 缓存 | 完整 CRUD，无缓存 | 🟡 小差距 |
| **Config 同步** | config-bundle 单请求 | 3 次独立请求 | 🔴 大差距 |
| **Peer Key 同步** | 批量 router-keys API | 逐个获取 | 🟡 中差距 |
| **GNB 进程管理** | 状态机 + 自动重启 + 网络设置 | 简单 spawn/kill | 🔴 大差距 |
| **GNB 安装** | CTL manifest | CTL manifest（已完善） | ⬜ 对齐 |
| **GNB 监控** | gnb_ctl map 解析 | gnb_ctl map 解析 | ⬜ 对齐 |
| **路由管理** | network.conf 生成 + 平台抽象 | 依赖 shell 脚本 | 🟡 中差距 |
| **防火墙** | nftables/pf 程序化 | UCI + shell 脚本 | ⬜ OpenWrt 方式合理 |
| **Plugin 系统** | heartbeat / proxy / updater | 无 | 🔴 大差距 |
| **Heartbeat** | HMAC-SHA256 签名上报 | mynetd 独立进程 | 🟡 方式不同 |
| **Proxy 模块** | 分流路由 + DNS 劫持 + IP set | shell 基础版 + 待增强 | 🟡 需补 Server/DNS/UI |
| **自动更新** | 客户端自身版本更新 | 无 | 🟡 OpenWrt 用 opkg |
| **日志系统** | 结构化 + 轮转 + 分级 | 基础日志 | 🟡 中差距 |
| **配置校验** | validator 自动修复 | 简单检查 | 🟡 中差距 |
| **Web UI** | Vue 3 SPA + Pinia + TailwindCSS | LuCI 模板 + 原生 JS | 🟡 栈不同，功能可对齐 |
| **WebSocket** | 实时事件推送 | 轮询 | 🟡 LuCI 限制 |
| **安全加固** | Helmet/CSP/Rate-limit/sudo安全 | LuCI session 隔离 | 🟡 中差距 |
| **平台抽象** | linux.js / darwin.js 统一接口 | OpenWrt 专用 | ⬜ 不需要 |

**结论**: mynet_lua 核心功能齐全，但在 **Config Bundle**、**服务状态机**、**插件体系**、**日志/监控** 方面有显著差距。

---

## 二、升级原则

1. **不重构框架**: 保持 LuCI/Lua 技术栈，不迁移到 SPA — OpenWrt 资源受限
2. **功能对齐优先**: 移植 client 的关键功能逻辑，不追求代码结构对称
3. **渐进式改造**: 每个 Phase 独立可交付，不阻塞当前运行
4. **OpenWrt 特色保留**: 防火墙/路由用 UCI/shell，不照搬 iproute2 直接调用
5. **遵守项目规范**: 严格遵守 copilot-instructions.md 中的禁止行为

---

## 三、升级路线图

### Phase 0 — 基础修复与代码质量（1~2 天）

> 不引入新功能，修复已知问题，为后续升级建立基线

#### 0.1 API 请求 Rate Limiting 意识
- **问题**: mynet_lua 对后端 API 无节流，快速点击可发起大量请求
- **方案**: JS 侧 `mnApi()` 增加按钮禁用 + 防抖（client 的 rate-limit 思路）
- **文件**: `htdocs/luci-static/resources/mynet/js/mynet.js`

#### 0.2 错误处理统一
- **问题**: 各 model 函数错误返回不一致（有 nil+msg、有 false+msg、有直接 return）
- **方案**: 统一为 `{ok=bool, data=any, error=string}` 信封格式（对齐 client 的 `{success, data, message}`）
- **文件**: 所有 `luasrc/model/mynet/*.lua` 的公共 API

#### 0.3 日志基础设施
- **问题**: 当前使用 `nixio.syslog` 或 `print()`，无结构化、无分级控制
- **方案**: 在 `util.lua` 增加轻量 logger — `util.log(level, module, msg)`，写入 `/var/log/mynet.log`
- **参考**: client 的 `src/utils/logger.js`（error/warn/info/debug 4 级）
- **文件**: `luasrc/model/mynet/util.lua`

---

### Phase 1 — Config Bundle 单请求同步（2~3 天）

> client 最重要的架构优化：一次 API 获取全部配置 + 密钥

#### 1.1 实现 Config Bundle 拉取

**现状**:
```lua
-- 当前流程：3 次请求
GET /nodes/{id}/config?render_conf=1     → node.conf
GET /route/node/{id}?render_conf=1       → route.conf  
GET /zones/services/indexes?render_conf=1 → address.conf
-- + N 次 peer key 请求
```

**目标**:
```lua
-- 新流程：1 次请求
GET /api/v2/nodes/{id}/config-bundle
Response: {
  files: { "node.conf": "...", "route.conf": "...", "address.conf": "..." },
  keys: {
    ed25519: { "peer1": "hex...", "peer2": "hex..." },
    security: { private: "hex...", public: "hex..." }
  }
}
```

**实现步骤**:
1. `api.lua` 新增 `get_config_bundle(node_id)` 方法
2. `node.lua` 新增 `refresh_configs_bundle(node_id)` — 解析 bundle 响应，一次写入所有文件
3. 保留旧的逐文件同步作为 **fallback**（后端可能尚未部署 bundle API）
4. `controller/mynet.lua` 的 `api_node_refresh_config` 优先尝试 bundle，失败回退

**文件**: `luasrc/model/mynet/api.lua`, `luasrc/model/mynet/node.lua`, `luasrc/controller/mynet.lua`

#### 1.2 Peer Key 批量获取

**现状**: 逐个 `GET /nodes/{peer_id}/keys`
**目标**: 使用 `POST /nodes/{node_id}/router-keys` 批量获取（与 client 对齐）

**注意**: client 目前此处有 bug（response 格式不匹配），实现时需:
1. 先确认后端实际返回格式
2. 添加 debug 日志打印原始响应
3. 兼容 `{peer_id: "hex"}` 和 `{peer_id: {public_key: "hex"}}` 两种格式

**文件**: `luasrc/model/mynet/node.lua` — `refresh_peer_keys()`

---

### Phase 2 — GNB 服务状态机（2~3 天）

> 对齐 client 的 STOPPED → STARTING → RUNNING → ERROR 状态机

#### 2.1 服务生命周期管理

**现状**: 简单的 `os.execute("gnb -c ... &")` + `kill -9 PID`
**目标**: 

```lua
-- 状态机
local STATES = { STOPPED=0, STARTING=1, RUNNING=2, STOPPING=3, ERROR=4 }

-- 服务管理器（node.lua 内新增或独立 service.lua）
M.service_state = STATES.STOPPED

function M.start_gnb(node_id)
  -- 1. Pre-flight checks（对齐 client checker.js）
  --    - gnb 二进制存在 + 可执行
  --    - node.conf 存在且有 nodeid
  --    - address.conf 有 index server
  --    - security/ 密钥存在（升级为 ERROR 级）
  --    - ed25519/ peer keys 存在
  -- 2. 状态转移 → STARTING
  -- 3. spawn gnb (io.popen 或 luci.sys.process.exec)
  -- 4. 等待 TUN 接口（轮询 ip link show gnb_tun）
  -- 5. 生成 network.conf（对齐 client network-routes.js）
  -- 6. 应用路由/防火墙
  -- 7. 状态转移 → RUNNING / ERROR
end
```

#### 2.2 Pre-flight 校验器

- 移植 client `src/service/checker.js` 的所有检查项
- security 目录检查升级为 **阻止启动**（不再只是 warn）
- 返回结构化检查结果，前端可展示每项检查状态

**文件**: `luasrc/model/mynet/node.lua` 或新增 `luasrc/model/mynet/checker.lua`

#### 2.3 network.conf 生成

- 移植 client `src/service/network-routes.js` 的逻辑
- 解析 route.conf → 生成 network.conf（/32 relay 路由）
- 写入 `/etc/mynet/driver/gnb/conf/{node_id}/network.conf`

**文件**: `luasrc/model/mynet/node.lua`

---

### Phase 3 — Heartbeat 心跳系统（1~2 天）

> 对齐 client 的 heartbeat 插件，但利用 OpenWrt 已有的 mynetd

#### 3.1 Heartbeat 上报增强

**现状**: mynetd 独立进程，功能不明确
**目标**: 确保 mynetd 上报的数据与 client heartbeat 对齐

**上报数据**:
```json
{
  "node_id": "...",
  "timestamp": "ISO8601",
  "metrics": {
    "cpu_percent": 15.2,
    "memory_used": 12345678,
    "memory_total": 67108864,
    "disk_used": ...,
    "disk_total": ...,
    "uptime": 86400,
    "vpn_status": "running",
    "peer_count": 5,
    "rx_bytes": ..., "tx_bytes": ...
  },
  "signature": "hmac-sha256..."
}
```

**实现**:
1. 在 `system.lua` 新增 `collect_metrics()` — 读取 `/proc/stat`, `/proc/meminfo`, `df` 等
2. 在 config.lua 配置 heartbeat 上报间隔、签名密钥
3. mynetd 配置生成时注入正确的参数

#### 3.2 HMAC 签名

- 对齐 client `heartbeat/signer.js` — 使用 security/{nodeId}.private 作为 HMAC key
- Lua 侧使用 `luci.crypto` 或 `openssl dgst -sha256 -hmac` shell 调用
- 签名字段: `node_id + timestamp + metrics_json`

**文件**: `luasrc/model/mynet/system.lua`, `luasrc/model/mynet/config.lua`

---

### Phase 4 — 前端功能增强（3~5 天）

> 在 LuCI 模板框架内尽可能对齐 client WebUI 体验

#### 4.1 Dashboard 增强

**client Dashboard 有而 mynet_lua 缺少的**:
- [ ] 实时 peer 连接数统计卡片
- [ ] VPN 带宽图表（简易版: 最近 10 次采样的折线）
- [ ] 快捷操作: 一键刷新配置 + 重启服务

**实现**: 扩展 `index.htm` + 新增 `/api/dashboard_stats` 端点

#### 4.2 Service 页面增强

**client Service 页面有而 mynet_lua 缺少的**:
- [ ] GNB 启动前校验结果展示（Pre-flight checklist UI）
- [ ] 服务日志实时尾部展示（`tail -f /var/log/mynet.log`）
- [ ] GNB 进程信息（PID、运行时长、内存用量）

**实现**: 扩展 `service.htm` + 新增 `/api/service_detail` 端点

#### 4.3 Settings 页面增强

**client Settings 有而 mynet_lua 缺少的**:
- [ ] 配置校验（validator）— 保存前检查 URL 格式、路径存在性
- [ ] Heartbeat 间隔配置
- [ ] 日志级别配置
- [ ] 一键恢复默认设置

**实现**: 扩展 `settings.htm`

#### 4.4 Node 页面小优化

- [ ] 配置文件差异对比（本地 vs 服务器）
- [ ] Config Bundle 一键同步按钮（Phase 1 实现的前端入口）
- [ ] 密钥状态可视化（本地有/无 + 服务器有/无）

---

### Phase 5 — 日志与监控体系（1~2 天）

> 对齐 client 的结构化日志和轮转机制

#### 5.1 结构化日志

```lua
-- util.lua 新增
function M.log(level, module, msg)
  -- level: error/warn/info/debug
  -- 格式: [2026-03-28T12:00:00] [INFO] [node] message
  -- 输出: /var/log/mynet.log + syslog
end
```

#### 5.2 日志轮转

**方案**: 利用 OpenWrt 自带的 `logrotate`（如有）或自实现简单轮转
```
/var/log/mynet.log {
    size 2M        ← OpenWrt 存储有限，比 client 的 10M 小
    rotate 3
    compress
    missingok
}
```

#### 5.3 日志查看 API

- 新增 `/api/logs_tail` — 返回最后 N 行日志
- 前端 service.htm 增加日志预览面板（JS 轮询）

**文件**: `luasrc/model/mynet/util.lua`, `luasrc/controller/mynet.lua`

---

### Phase 6 — 配置校验与自动修复（1 天）

> 对齐 client config/validator.js

#### 6.1 配置校验器

```lua
-- 新增 luasrc/model/mynet/validator.lua
local M = {}

function M.validate_config()
  local issues = {}
  -- 检查项:
  -- 1. config.json 存在且可解析
  -- 2. api_base_url 格式正确
  -- 3. gnb_root_path 目录存在
  -- 4. credential.json 权限 0600
  -- 5. zone.json 有 zone_id
  -- 6. node_id 已选择
  -- 7. gnb 二进制存在
  return issues  -- 空 = 全部通过
end

function M.auto_repair(issues)
  -- 自动修复可修复的问题:
  -- 1. 缺失字段 → 填入默认值
  -- 2. 权限错误 → chmod
  -- 3. 目录不存在 → mkdir -p
end

return M
```

#### 6.2 启动时自动校验

- Dashboard 加载时调用 `validator.validate_config()`
- 有不可修复问题时显示告警横幅
- 有可修复问题时自动修复并提示

---

### Phase 7 — 安全加固（1 天）

> 对齐 client 的安全措施（适配 LuCI 环境）

> **注意**: Phase 8 (Proxy 模块) 在本 Phase 之后，见下方

#### 7.1 API Rate Limiting

- LuCI 本身有 session 机制，但无请求频率限制
- 在 `controller/mynet.lua` 入口处增加简单频率控制:
  ```lua
  local rate_cache = {}  -- {ip: {count, timestamp}}
  local function check_rate_limit(ip, max_per_min)
    -- 简单滑动窗口
  end
  ```
- 登录接口: 10 次/分钟
- 普通 API: 60 次/分钟

#### 7.2 敏感文件权限强制

- 每次写入 credential.json / security/*.private 后确保 `chmod 0600`
- 对齐 client 的文件权限策略

#### 7.3 输入校验加固

- 所有 API 参数增加白名单验证（node_id 纯数字、key_hex 纯十六进制）
- 防止 shell 注入（检查 `os.execute` / `io.popen` 参数）

---

## 四、功能对齐矩阵

下表标记每项 client 功能在 mynet_lua 中的对齐计划:

| Client 功能 | mynet_lua 现状 | 升级 Phase | 优先级 | 备注 |
|------------|---------------|-----------|--------|------|
| Config Bundle API | ❌ 3次请求 | Phase 1 | P0 🔴 | 大幅减少网络往返 |
| 批量 Peer Key | ❌ 逐个获取 | Phase 1 | P0 🔴 | 网络效率 |
| 服务状态机 | ❌ 简单 spawn/kill | Phase 2 | P0 🔴 | 可靠性核心 |
| Pre-flight 校验 | ⚠️ 部分 | Phase 2 | P1 🟡 | 安全增强 |
| network.conf 生成 | ❌ 无 | Phase 2 | P1 🟡 | 路由完整性 |
| Heartbeat 上报 | ⚠️ mynetd 简单版 | Phase 3 | P1 🟡 | 监控对齐 |
| HMAC 签名 | ❌ 无 | Phase 3 | P2 🟢 | 安全增强 |
| Dashboard 增强 | ⚠️ 基础 | Phase 4 | P2 🟢 | 体验优化 |
| 服务日志查看 | ❌ 无 | Phase 4/5 | P1 🟡 | 运维必需 |
| Pre-flight UI | ❌ 无 | Phase 4 | P2 🟢 | 体验优化 |
| 结构化日志 | ❌ 基础 syslog | Phase 5 | P1 🟡 | 调试基础 |
| 日志轮转 | ❌ 无 | Phase 5 | P2 🟢 | 存储安全 |
| 配置校验 | ❌ 无 | Phase 6 | P2 🟢 | 健壮性 |
| Rate Limiting | ❌ 无 | Phase 7 | P2 🟢 | 安全 |
| 文件权限强制 | ⚠️ 部分 | Phase 7 | P1 🟡 | 安全 |
| 输入校验 | ⚠️ 部分 | Phase 7 | P1 🟡 | 安全 |
| Token 自动刷新去重 | ❌ 无去重 | Phase 0 | P2 🟢 | 可靠性 |
| Plugin 系统 | ❌ 无 | 不适用 | — | OpenWrt 用 shell 脚本扩展 |
| Proxy 模块 | ⚠️ shell 基础版 | Phase 8 | P1 🟡 | 缺 Server 模式/DNS/Web UI |
| Updater 插件 | ❌ 无 | 不适用 | — | OpenWrt 用 opkg |
| Vue SPA | ❌ LuCI 模板 | 不适用 | — | 资源限制，保持现状 |
| WebSocket | ❌ 轮询 | 不适用 | — | LuCI 不支持 |
| 多平台抽象 | ❌ 仅 OpenWrt | 不适用 | — | 专用平台，无需抽象 |

**"不适用" 说明**: 这些功能在 client 中需要是因为它运行在通用 Linux/macOS，而 mynet_lua 运行在 OpenWrt 生态中，有自己的等效方案或不需要。

---

## 五、实施时间线

```
Week 1:  Phase 0 (基础修复) + Phase 1 (Config Bundle)
         ├─ 0.1 API 防抖
         ├─ 0.2 错误格式统一
         ├─ 0.3 日志函数
         ├─ 1.1 Config Bundle 实现
         └─ 1.2 Peer Key 批量

Week 2:  Phase 2 (服务状态机)
         ├─ 2.1 服务生命周期
         ├─ 2.2 Pre-flight 校验
         └─ 2.3 network.conf 生成

Week 3:  Phase 3 (Heartbeat) + Phase 5 (日志)
         ├─ 3.1 metrics 采集
         ├─ 3.2 HMAC 签名
         ├─ 5.1 结构化日志
         ├─ 5.2 日志轮转
         └─ 5.3 日志查看 API

Week 4:  Phase 4 (前端) + Phase 6/7 (校验/安全)
         ├─ 4.1~4.4 前端增强
         ├─ 6.1 配置校验器
         ├─ 7.1 Rate Limiting
         └─ 7.2~7.3 安全加固

Week 5:  Phase 8 (Proxy 模块)
         ├─ 8.1 Server 模式 + 8.2 DNS 劫持
         ├─ 8.3 原子回滚 + 8.4 route.conf 注入
         ├─ 8.5 LuCI Proxy 页面 + API
         └─ 8.6 状态 JSON + 联调测试
```

**总工期估算**: 约 5 周（每天 2~3 小时投入）

---

### Phase 8 — Proxy 分流模块增强（3~5 天）

> 将 scripts/proxy/ 从纯 shell 脚本提升为 LuCI 可管理的完整分流方案

#### 现状评估

mynet_lua 已有 `scripts/proxy/` 实现了：
- ✅ route_policy.sh — nftables/iptables ipset + fwmark 策略路由
- ✅ proxy.sh — start/stop/refresh/status 生命周期
- ✅ hooks/ — pre_start/post_start/stop 钩子（与 GNB 生命周期联动）
- ✅ 智能路由表分配（不硬编码 table 200）
- ✅ ipset batch 加载（10x 快于逐条）
- ✅ 诊断工具（diagnose_proxy.sh, debug_route.sh）
- ✅ POSIX shell 兼容（ash/sh/bash 均可）

mynet_client 有而 mynet_lua 缺少的：
- ❌ Server 模式（NAT masquerade + FORWARD 规则）
- ❌ DNS 劫持（iptables NAT redirect / resolv.conf 覆写）
- ❌ 原子回滚（任一层失败 → 回退已成功层）
- ❌ GNB route.conf 注入（自动注入 /8 路由块）
- ❌ Web UI（LuCI 配置/状态/控制界面）
- ❌ 结构化状态 API（JSON 输出给前端）

#### 8.1 Server 模式支持

**目标**: OpenWrt 不仅做 proxy client（出站分流），也能做 proxy server（作为出口节点）

```bash
# route_policy.sh 新增 server 模式
start_server_mode() {
  # 1. 启用 ip_forward
  sysctl -w net.ipv4.ip_forward=1
  # 2. MASQUERADE — VPN 子网流量 NAT 到 WAN
  nft add rule inet mynet_proxy postrouting oifname "$WAN_IFACE" masquerade
  # 3. FORWARD — 允许 VPN→WAN 转发
  nft add rule inet mynet_proxy forward iifname "$TUN_IFACE" oifname "$WAN_IFACE" accept
  # 4. IP 白名单（可选）— 仅允许指定 VPN peer 使用 server
  # 加载 proxy_whitelist.txt 到 nftables set
}
```

**文件**: `scripts/proxy/openwrt/route_policy.sh`

#### 8.2 DNS 劫持

**目标**: 确保 proxy 模式下 DNS 查询也走 VPN 通道，防止 DNS 泄漏

**三种模式**（对齐 client dns.js）：

| 模式 | 实现 | 适用场景 |
|------|------|----------|
| **redirect** | iptables DNAT 53→VPN DNS | OpenWrt 默认 |
| **resolv** | 修改 /tmp/resolv.conf.d/resolv.conf.auto | 简单桌面/VM |
| **none** | 不劫持 DNS | 用户自行管理 |

```bash
# route_policy.sh 新增
start_dns_intercept() {
  local dns_mode="$1"  # redirect|resolv|none
  local dns_server="$2" # 目标 DNS (如 VPN 对端 DNS)
  case "$dns_mode" in
    redirect)
      # DNAT — LAN 设备 DNS 请求重定向到 VPN 侧 DNS
      nft add rule inet mynet_proxy prerouting \
        iifname "br-lan" udp dport 53 dnat to "$dns_server:53"
      nft add rule inet mynet_proxy prerouting \
        iifname "br-lan" tcp dport 53 dnat to "$dns_server:53"
      ;;
    resolv)
      cp /tmp/resolv.conf.d/resolv.conf.auto \
         /tmp/resolv.conf.d/resolv.conf.auto.proxy_bak
      echo "nameserver $dns_server" > /tmp/resolv.conf.d/resolv.conf.auto
      ;;
  esac
}
```

**文件**: `scripts/proxy/openwrt/route_policy.sh`

#### 8.3 原子回滚框架

**目标**: proxy 启动是多层操作（route inject → ipset → policy route → DNS），任一层失败应回退已成功的层

```bash
# proxy.sh 改造
start_proxy() {
  local layers_done=0

  # Layer 1: route.conf 注入
  inject_routes && layers_done=1 || { rollback $layers_done; return 1; }

  # Layer 2: ipset + fwmark
  start_policy_routing && layers_done=2 || { rollback $layers_done; return 1; }

  # Layer 3: DNS 劫持
  start_dns_intercept && layers_done=3 || { rollback $layers_done; return 1; }

  echo "$layers_done" > "$STATE_DIR/proxy_layers"
}

rollback() {
  local n="$1"
  [ "$n" -ge 3 ] && stop_dns_intercept
  [ "$n" -ge 2 ] && stop_policy_routing
  [ "$n" -ge 1 ] && restore_routes
}
```

**文件**: `scripts/proxy/proxy.sh`

#### 8.4 GNB route.conf 自动注入

**目标**: 对齐 client `route-inject.js` — 自动向 route.conf 注入 proxy peer 的 /8 路由块

```bash
# 新增 scripts/proxy/route_inject.sh
inject_routes() {
  local conf_dir="$MYNET_HOME/driver/gnb/conf/$NODE_ID"
  local route_conf="$conf_dir/route.conf"
  local backup="$conf_dir/route.conf.proxy_bak"

  # 备份原始
  cp "$route_conf" "$backup"

  # 读取 proxy_peers.conf 获取 peer node_id
  # 为每个 peer 生成 /8 路由条目（跳过 10/127/172.16-31/192.168/224-255）
  # 合并到 route.conf（已有条目优先）
}

restore_routes() {
  local backup="$conf_dir/route.conf.proxy_bak"
  [ -f "$backup" ] && mv "$backup" "$route_conf"
}
```

**文件**: 新增 `scripts/proxy/route_inject.sh`

#### 8.5 Proxy LuCI Web UI

**目标**: 在 mynet LuCI 界面中管理 proxy — 不需要 SSH 操作 shell 脚本

**新增页面**: `luasrc/view/mynet/proxy.htm`

```
┌─────────────────────────────────────────────────┐
│ Proxy 分流管理                                    │
├─────────────────────────────────────────────────┤
│                                                   │
│  状态: ● 运行中 / ○ 已停止                         │
│  模式: [Client ▼]  地区: [国内 ▼]                  │
│  DNS 模式: [redirect ▼]                            │
│                                                   │
│  [启动] [停止] [重载 IP 列表]                       │
│                                                   │
│  ─── 统计 ───                                      │
│  IP 规则数: 8,234 条 (chinaip.txt)                 │
│  路由表 ID: 200                                     │
│  Proxy Peers: 2 节点                                │
│  运行时长: 2h 15m                                   │
│                                                   │
│  ─── IP 列表管理 ───                                │
│  [chinaip.txt ▼] [编辑] [上传自定义]               │
│                                                   │
│  ─── 诊断 ───                                      │
│  测试 IP: [_________] [检测路由]                    │
│                                                   │
└─────────────────────────────────────────────────┘
```

**新增 API 端点**:
- `GET /api/proxy_status` — 获取 proxy 运行状态 + 统计
- `POST /api/proxy_start` — 启动 proxy（参数: mode, region, dns_mode）
- `POST /api/proxy_stop` — 停止 proxy
- `POST /api/proxy_reload` — 重载 IP 列表
- `POST /api/proxy_diagnose` — 诊断指定 IP 的路由路径
- `GET /api/proxy_config` — 获取 proxy 配置
- `POST /api/proxy_config` — 保存 proxy 配置

**新增 Model**: `luasrc/model/mynet/proxy.lua`
```lua
local M = {}

function M.get_status()
  -- 调用 proxy.sh status，解析 JSON 输出
end

function M.start(opts)
  -- opts: {mode, region, dns_mode}
  -- 写入 proxy_role.conf
  -- 调用 proxy.sh start
end

function M.stop()
  -- 调用 proxy.sh stop
end

function M.diagnose_ip(ip)
  -- 调用 debug_route.sh，返回结构化结果
end

return M
```

**文件**: 新增 `luasrc/model/mynet/proxy.lua`, `luasrc/view/mynet/proxy.htm`, 修改 `luasrc/controller/mynet.lua`

#### 8.6 proxy.sh 状态 JSON 输出

**目标**: `proxy.sh status` 增加 `--json` 输出，供 LuCI API 消费

```json
{
  "running": true,
  "mode": "client",
  "region": "domestic",
  "dns_mode": "redirect",
  "layers": {
    "route_inject": true,
    "policy_routing": true,
    "dns_intercept": true
  },
  "stats": {
    "ipset_count": 8234,
    "route_table_id": 200,
    "peer_count": 2,
    "uptime_seconds": 8100
  }
}
```

**文件**: `scripts/proxy/proxy.sh`

---

## 六、不迁移的功能及原因

| Client 功能 | 不迁移原因 |
|------------|-----------|
| **Plugin 加载器** | OpenWrt Lua 环境不适合动态插件；用 shell 脚本 + opkg 扩展更合理 |
| **Updater 自更新** | OpenWrt 有 opkg 生态；mynet_lua 本身是 LuCI 包，通过 ipk 升级 |
| **Vue SPA** | OpenWrt 路由器内存 / Flash 受限（通常 16~128MB），无法运行 Node.js 构建链 |
| **WebSocket** | LuCI CGI 模式不支持长连接，轮询是唯一方案 |
| **多平台抽象层** | mynet_lua 只运行在 OpenWrt，无需 darwin/windows 适配 |
| **CORS / Helmet** | LuCI 在内网运行，uhttpd 自带基本安全；过度安全头增加复杂度 |
| **sudo 安全写入** | OpenWrt 无普通用户概念，所有操作都是 root |

---

## 七、风险与注意事项

### 7.1 后端 API 兼容性
- Config Bundle API (`/api/v2/nodes/{id}/config-bundle`) 可能尚未在 mynet_back 部署
- **缓解**: Phase 1 实现 bundle + fallback 双路径，自动降级

### 7.2 Peer Key 格式不一致
- client 和 lua 都遇到了后端返回格式不明确的问题
- **缓解**: 实现时增加 debug 日志，兼容多种格式

### 7.3 OpenWrt 存储限制
- 日志、配置文件不能无限增长
- **缓解**: 日志轮转 2MB × 3 份；定期清理临时文件

### 7.4 LuCI 架构限制
- 无法实现 WebSocket、SPA、Service Worker
- **接受**: 在轮询模式内优化体验（降低轮询间隔、增加 loading 状态）

### 7.5 node_id 科学计数法
- **永远不忘**: 所有新增代码中的 node_id 必须经过 `nid()` / `util.int_str()` 转换
- 所有新增 API 端点的 node_id 参数都要先转换再拼接路径

---

## 八、验证标准

每个 Phase 完成后的验收标准:

| Phase | 验收条件 |
|-------|---------|
| Phase 0 | `lua -c` 语法检查全部通过；API 调用按钮有防抖；日志可写入 /var/log/mynet.log |
| Phase 1 | 一键刷新配置走 bundle API（可 fallback）；peer key 批量获取成功 |
| Phase 2 | GNB 启动走完状态机；pre-flight 失败时阻止启动并展示原因；network.conf 正确生成 |
| Phase 3 | mynetd 上报数据结构匹配 client heartbeat 格式；HMAC 签名可被后端验证 |
| Phase 4 | Dashboard 显示 peer 数 + 带宽；Service 页可查看日志；Settings 可配置 heartbeat |
| Phase 5 | `/var/log/mynet.log` 有分级日志；超过 2MB 自动轮转；API 可查看日志 |
| Phase 6 | Dashboard 启动时显示配置校验结果；可自动修复简单问题 |
| Phase 7 | 登录接口有频率限制；敏感文件权限 0600；无 shell 注入风险 |
| Phase 8 | Proxy server 模式可启动；DNS 劫持正常工作；LuCI 页面可控制启停；`proxy.sh status --json` 输出正确；原子回滚在层失败时恢复干净状态 |

---

## 九、文件变更预估

| 文件 | 变更类型 | 涉及 Phase |
|------|---------|-----------|
| `luasrc/model/mynet/util.lua` | 修改 — 增加 logger | 0, 5 |
| `luasrc/model/mynet/api.lua` | 修改 — 增加 bundle API | 1 |
| `luasrc/model/mynet/node.lua` | 大改 — bundle同步/状态机/network.conf | 1, 2 |
| `luasrc/model/mynet/system.lua` | 修改 — 增加 metrics 采集 | 3 |
| `luasrc/model/mynet/config.lua` | 修改 — 增加 heartbeat/日志配置 | 3, 5 |
| `luasrc/model/mynet/validator.lua` | **新增** — 配置校验器 | 6 |
| `luasrc/controller/mynet.lua` | 修改 — 新 API 端点 | 1, 2, 4, 5 |
| `luasrc/view/mynet/index.htm` | 修改 — Dashboard 增强 | 4 |
| `luasrc/view/mynet/service.htm` | 修改 — 日志查看/Pre-flight UI | 4 |
| `luasrc/view/mynet/settings.htm` | 修改 — Heartbeat/日志配置 | 4 |
| `luasrc/view/mynet/node.htm` | 轻微修改 — Bundle 按钮 | 4 |
| `htdocs/.../mynet.js` | 修改 — API 防抖/日志面板 JS | 0, 4 |
| `root/etc/mynet/conf/config.json` | 修改 — 增加新配置字段 | 3, 5 |
| `luasrc/model/mynet/proxy.lua` | **新增** — Proxy 模型层 | 8 |
| `luasrc/view/mynet/proxy.htm` | **新增** — Proxy LuCI 页面 | 8 |
| `scripts/proxy/proxy.sh` | 修改 — 原子回滚 + JSON 输出 | 8 |
| `scripts/proxy/route_inject.sh` | **新增** — route.conf 自动注入 | 8 |
| `scripts/proxy/openwrt/route_policy.sh` | 修改 — Server 模式 + DNS 劫持 | 8 |
