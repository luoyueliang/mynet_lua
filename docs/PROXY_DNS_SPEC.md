# MyNet Proxy / DNS 实现规范（v2026.05）

> 本文档描述 MyNet 路由器端 Proxy 与 DNS 分流的完整实现契约。
> **mynet_client（macOS / Linux 客户端项目）需按此规范同步落地**，确保两端行为一致。
>
> 涉及文件：
> - Lua 业务层：`luasrc/model/mynet/proxy.lua`
> - Shell 执行层：`scripts/proxy/route_policy.sh`、`scripts/proxy/dns_split.sh`
> - Controller / API：`luasrc/controller/mynet.lua`（`api_proxy_*`）
> - 视图：`luasrc/view/mynet/proxy.htm`

---

## 1. 设计原则

| 原则 | 说明 |
|---|---|
| **Lua 持有真相** | 所有常量（DNS 列表、默认值）、参数校验、状态聚合在 `proxy.lua`；shell 只做"系统命令执行" |
| **shell 通过 env 接参** | `proxy_policy_params.env` 是 Lua → shell 的唯一参数通道，避免 shell 内重复硬编码 |
| **单一执行点** | 同一系统操作（如"路由 8.8.8.8 到隧道"）只在一个地方实现，避免 Lua/shell 双写漂移 |
| **启动即加载，与模式无关** | 国外 DNS 服务器 /32 路由在 proxy `start()` 末尾**总是**执行，不被 `dns_mode` / `region` / `mode` 任何分支跳过 |
| **优先委托独立脚本** | split DNS 完全由 `dns_split.sh` 实现；`route_policy.sh` 只调用，不内联备份逻辑 |

---

## 2. 数据模型

### 2.1 `proxy_role.conf`（持久化配置，bash KEY="VAL" 格式）

| Key | 取值 | 默认 | 说明 |
|---|---|---|---|
| `PROXY_ENABLED` | `0`/`1` | `0` | 是否随 GNB 自启 |
| `PROXY_MODE` | `client` / `server` / `both` | `client` | 分流模式 |
| `NODE_REGION` | `domestic` / `international` / `non_domestic` | `domestic` | 节点所在区域，决定 IP 集合数据源与匹配语义 |
| `DNS_MODE` | `none` / `redirect` / `resolv` / `split` | `none` | DNS 处理策略 |
| `DNS_SERVER` | IPv4 或 hostname | `""` | DNS 上游（redirect/resolv 用作目标，split 用作国外 DNS） |
| `DNS_DOMESTIC_SERVER` | 逗号分隔 IPv4 列表 | `223.5.5.5,119.29.29.29` | split 模式的国内 DNS |
| `PROXY_PEERS` | 逗号分隔的 GNB nodeId | `""` | 出站对端节点 |

### 2.2 `proxy_policy_params.env`（Lua → shell 一次性运行参数）

由 `proxy.start()` 自动写入，shell 通过 `. $PARAMS_FILE` 加载。**新增字段：**

```env
NODE_REGION="domestic"
MATCH_MODE="normal"                              # normal | inverted
DNS_MODE="split"
DNS_SERVER="8.8.8.8"
DNS_DOMESTIC_SERVER="223.5.5.5,119.29.29.29"
FOREIGN_DNS_SERVERS="8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 9.9.9.9 208.67.222.222 208.67.220.220"
```

> ⚠️ **mynet_client 必须提供等价机制**（macOS 可用 `launchd` plist 的 `EnvironmentVariables`，或临时 export）。

### 2.3 `proxy_state.json`（运行时状态，PROXY_HOME/var/proxy_state.json）

```json
{
  "start_ts": 1746234567,
  "mode":    "client",
  "region":  "domestic",
  "dns_mode": "split"
}
```

---

## 3. Region 与 DNS Mode 的语义

### 3.1 三种 Region 匹配

| Region | IP 集合数据源 | nft / pf 规则 | 用途 |
|---|---|---|---|
| `domestic` | `interip.txt`（海外 IP，~17000 条） | `daddr ∈ set → mark`（命中走代理） | 节点在国内，海外加速 |
| `international` | `chinaip.txt`（国内 IP） | `daddr ∈ set → mark`（命中走代理） | 节点在海外，回国加速 |
| `non_domestic` | `chinaip.txt`（国内 IP） | `daddr ∉ set → mark`（**反转**） | **全局代理但国内直连**，对应 `MATCH_MODE=inverted` |

### 3.2 四种 DNS Mode

| Mode | 实现 | LAN 客户端 DNS 路径 | 适用 |
|---|---|---|---|
| `none` | 不修改 dnsmasq | 沿用现有上游 | 已有自定义 DNS 方案 |
| `redirect` | nft NAT prerouting DNAT br-lan:53 → peer_vip | 强制走 peer smartdns | 简单粗暴，绕过 dnsmasq |
| `resolv` | 改写 `/tmp/resolv.conf.d/resolv.conf.auto` | dnsmasq → peer_vip | 仅修路由器自身 DNS |
| `split` | dnsmasq + GFW list（`server=/{domain}/{foreign_dns}`） | dnsmasq 智能分流 | **推荐**：无需 peer smartdns，国内 CDN + 海外干净 IP |

---

## 4. 国外 DNS 服务器系统级路由（核心机制）

### 4.1 列表（Lua 单一真相源）

```lua
-- proxy.lua
M.FOREIGN_DNS_SERVERS = {
    "8.8.8.8", "8.8.4.4",          -- Google
    "1.1.1.1", "1.0.0.1",          -- Cloudflare
    "9.9.9.9",                      -- Quad9
    "208.67.222.222", "208.67.220.220",  -- OpenDNS
}
```

### 4.2 写入时机

**proxy `start()` 的最后一步无条件执行**（与 `dns_mode`、`region`、`mode` **完全无关**）：

```lua
function M.start(opts)
    ...
    M.register_firewall_include()
    M.route_foreign_dns()       -- ← 这一行没有任何 if 分支保护
    return true, ...
end
```

### 4.3 路由命令

```sh
ip route replace 8.8.8.8/32 dev gnb_tun_XX
ip route replace 8.8.4.4/32 dev gnb_tun_XX
... (依次 7 个)
```

`/32` 主表路由优先级**高于** GNB 注入的 `/8` pipe 路由，确保任何客户端发往这些公共 DNS 的查询直接通过隧道，**不被 ISP DNS 拦截/污染**。

### 4.4 可达性验证（v2026.05 新增）

`route_foreign_dns()` 不只是 `ip route replace` 后计数，还会执行：

```sh
ip route get 8.8.8.8 | head -1
```

并检查输出中 `dev` 是否为 GNB 接口；若不匹配则不计入 `verified`。返回结构：

```lua
{ routed = 7, verified = 7, total = 7 }
```

### 4.5 状态查询

`get_status()` 在 `layers` 字段下增加 `foreign_dns_routed`：

```json
{
  "layers": {
    "route_inject":       true,
    "policy_routing":     true,
    "dns_intercept":      true,
    "foreign_dns_routed": true   ← 新增
  }
}
```

UI 应该展示这一项，让用户直观感知"DNS 反污染保护已生效"。

### 4.6 清理时机

`proxy.stop()` 中 `M.unroute_foreign_dns()` 删除全部 `/32`。**shell 不再重复实现**这个逻辑。

---

## 5. 模块职责划分（v2026.05 重构）

### 5.1 proxy.lua（业务真相层）

- 持有 `FOREIGN_DNS_SERVERS` / `DOMESTIC_DNS_SERVERS` 常量
- 写入 `proxy_policy_params.env`（含两个 DNS 列表）
- `validate_params()`：校验 `mode`/`region`/`dns_mode`（**enable() / start() 都校验**）
- `route_foreign_dns()` / `unroute_foreign_dns()`：唯一执行点
- `route_inject()` / `route_restore()`：GNB route.conf pipe 注入

### 5.2 route_policy.sh（系统命令执行层）

只负责：
- 路由表注册 + `ip rule` + `ip route` 默认网关
- nft / iptables mangle PREROUTING fwmark 规则
- WAN 网关 `/32` 修复
- DNS 模式分发（none / redirect / resolv → 自处理；split → 委托 `dns_split.sh`）

**已移除**（v2026.05）：
- ~~`route_foreign_dns` / `unroute_foreign_dns`~~（→ Lua）
- ~~`setup_split_dns_inline` / `update_gfwlist`~~（→ `dns_split.sh`）
- ~~硬编码的 `223.5.5.5,119.29.29.29` 恢复值~~（→ 用 `DNS_DOMESTIC_SERVER`）
- ~~`/tmp/.dns_route` 临时文件~~（→ `$MYNET_HOME/var/dns_route_pin`）

### 5.3 dns_split.sh（split DNS 专属脚本）

接口：
```sh
dns_split.sh setup [domestic_dns] [foreign_dns]
dns_split.sh update [foreign_dns]
dns_split.sh status
dns_split.sh stop
```

**已移除**（v2026.05）：
- ~~直接 sed 写 `/etc/dnsmasq.conf` 的双写~~（仅 OpenWrt 部分发行版生效，不可移植）
- ~~`dnsmasq restart`~~ → `dnsmasq reload`（避免中断 in-flight 查询）

`stop` 行为补强：清理 `gfwlist.conf` + `extra-domains.conf` + `dnsmasq.conf` 残留 sed 段（升级兼容）。

---

## 6. 启动 / 停止流程（更新版）

### 6.1 启动

```text
proxy.enable()              ← 持久化 PROXY_ENABLED=1（含 validate_params）
   └─ if GNB running → proxy.start(opts)

proxy.start(opts)
   ├─ 1. validate_params(opts)
   ├─ 2. update_config(opts) → proxy_role.conf
   ├─ 3. route_inject()      → GNB route.conf 注入 pipe 路由
   ├─ 4. proxy.sh generate   → proxy_route.conf (nft 元素)
   ├─ 5. write proxy_policy_params.env (含 FOREIGN_DNS_SERVERS / DNS_DOMESTIC_SERVER)
   ├─ 6. route_policy.sh start
   │     ├─ ensure_route_table / add_default_routes / add_ip_rules
   │     ├─ fix_wan_gateway_route
   │     ├─ start_nftables | start_iptables (mark fwmark 0xc8)
   │     └─ DNS_MODE 分发
   │         ├─ none      → 跳过
   │         ├─ redirect  → uci 改 dnsmasq 上游 + nft DNAT br-lan:53
   │         ├─ resolv    → 改 resolv.conf.auto
   │         └─ split     → bash dns_split.sh setup "$DNS_DOMESTIC_SERVER" "$DNS_SERVER"
   ├─ 7. write proxy_state.json
   ├─ 8. register_firewall_include
   └─ 9. route_foreign_dns()   ← 与模式无关，启动即生效
```

### 6.2 停止

```text
proxy.stop()
   ├─ 1. unroute_foreign_dns()  ← 与模式无关
   ├─ 2. route_policy.sh stop
   │     ├─ stop_dns_intercept
   │     ├─ stop_server_mode
   │     ├─ nft delete table inet mynet_proxy
   │     ├─ ip rule del / ip route flush table 200
   │     └─ DNS_MODE 恢复
   │         ├─ split       → bash dns_split.sh stop
   │         ├─ redirect/resolv → uci 恢复 DNS_DOMESTIC_SERVER
   │         └─ none        → 跳过
   ├─ 3. route_restore()        ← strip GNB route.conf 注入段
   ├─ 4. rm proxy_state.json
   └─ 5. unregister_firewall_include
```

---

## 7. mynet_client 同步落地清单

> mynet_client 是 macOS / Linux 桌面客户端项目，需提供等价能力。

### 7.1 必须实现

- [ ] **常量定义**（`FOREIGN_DNS_SERVERS` / `DOMESTIC_DNS_SERVERS`）必须与 [proxy.lua](../luasrc/model/mynet/proxy.lua#L27-L38) 完全一致
- [ ] **proxy `start()` 末尾无条件路由 7 个国外 DNS** 到 GNB 隧道接口（macOS 用 `route -n add -host 8.8.8.8 -interface utun7`）
- [ ] **proxy `stop()` 必须撤销** 这 7 条路由
- [ ] **状态接口 `layers.foreign_dns_routed`** 字段（用 `route -n get 8.8.8.8` 验证）
- [ ] **`validate_params` 必须校验** `dns_mode ∈ {none, redirect, resolv, split}`、`region ∈ {domestic, international, non_domestic}`
- [ ] **MATCH_MODE 派生**：`region == "non_domestic" ⇒ MATCH_MODE = "inverted"`，反转 nft/pf 规则匹配语义

### 7.2 平台差异适配

| 能力 | OpenWrt | macOS 客户端建议 |
|---|---|---|
| 防火墙 fwmark | `nft mark set 0xc8` | `pf` 不支持 fwmark；用 `pf` 的 `route-to` 指令直接转发到隧道接口 |
| 策略路由表 | `ip rule fwmark 0xc8 lookup 200` | macOS 无策略路由；用 `pf` `route-to (utun7 peer_vip)` 替代 |
| `/32` host route | `ip route replace` | `route -n add -host 8.8.8.8 -interface utunN`（无 `replace`，先 delete） |
| dnsmasq split | `dnsmasq + /etc/dnsmasq.d/gfwlist.conf` | macOS 用 `dnsmasq`（brew）或直接写 `/etc/resolver/{domain}` 文件 |
| GNB 接口名 | `gnb_tun_XX` | `utunN`（动态分配，需通过 `ifconfig` 解析） |

### 7.3 行为一致性测试（端到端）

```sh
# 1. proxy 启动后立即检查
ip route get 8.8.8.8 | grep -q "dev gnb_tun"   && echo "✓ foreign DNS routed"
ip route get 1.1.1.1 | grep -q "dev gnb_tun"   && echo "✓ cloudflare routed"

# 2. 状态接口
curl -s http://router/api/proxy_status | jq '.data.layers.foreign_dns_routed'
# 期望: true

# 3. 停止后清理验证
ip route show 8.8.8.8/32   # 应为空
```

---

## 8. 变更历史

### v2026.05（本次）

| 类型 | 变更 |
|---|---|
| 新增 | `dns_mode = split`（dnsmasq + GFW list 域名分流） |
| 新增 | `region = non_domestic`（反转匹配，全局代理但国内直连） |
| 新增 | `M.FOREIGN_DNS_SERVERS` 系统级 `/32` 路由（启动即加载） |
| 新增 | `get_status().layers.foreign_dns_routed` |
| 重构 | `route_foreign_dns` 真相源迁至 Lua，shell 删除重复实现 |
| 重构 | `setup_split_dns_inline` / `update_gfwlist` 从 route_policy.sh 移除 |
| 重构 | `proxy_policy_params.env` 注入 `FOREIGN_DNS_SERVERS` / `DOMESTIC_DNS_SERVER` |
| 修复 | `dns_split.sh` 不再写 `/etc/dnsmasq.conf`（不可移植） |
| 修复 | `dnsmasq restart` → `reload`（避免中断 in-flight 查询） |
| 修复 | `enable()` 增加 `validate_params` 校验 |
| 修复 | `/tmp/.dns_route` → `$MYNET_HOME/var/dns_route_pin`（避免崩溃后误清用户路由） |

---

## 9. 附录：API 速查

| 路径 | 方法 | 说明 |
|---|---|---|
| `/admin/services/mynet/api/proxy_status` | GET | 含 `layers.foreign_dns_routed` |
| `/admin/services/mynet/api/proxy_start` | POST | 入参：`mode`/`region`/`dns_mode`/`dns_server`/`proxy_peers` |
| `/admin/services/mynet/api/proxy_stop` | POST | — |
| `/admin/services/mynet/api/proxy_enable` | POST | 同 start，但同时设 `PROXY_ENABLED=1` |
| `/admin/services/mynet/api/proxy_disable` | POST | — |
| `/admin/services/mynet/api/proxy_reload` | POST | 重载 IP 列表 |
| `/admin/services/mynet/api/proxy_diagnose` | POST | 入参：`ip`，返回路由路径检查结果 |
| `/admin/services/mynet/api/proxy_net_detect` | POST | 入参：`type=domestic|proxy`，返回出口 IP |
| `/admin/services/mynet/api/proxy_net_check` | POST | 入参：`host`，返回连通性 |
