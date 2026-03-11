# 架构设计说明

---

## 整体架构

```
浏览器
  │  HTTP (LuCI CGI)
  ▼
┌─────────────────────────────────┐
│  LuCI 框架 (luci-base)          │
│  ┌───────────────────────────┐  │
│  │  controller/mynet.lua     │  │  路由 & Action
│  │  ┌─────────────────────┐  │  │
│  │  │  model/mynet/       │  │  │  业务逻辑
│  │  │  ├─ auth.lua        │  │  │
│  │  │  ├─ zone.lua        │  │  │
│  │  │  ├─ node.lua        │  │  │
│  │  │  ├─ config.lua      │  │  │
│  │  │  ├─ credential.lua  │  │  │
│  │  │  ├─ api.lua         │  │  │  curl → MyNet API
│  │  │  └─ util.lua        │  │  │
│  │  └─────────────────────┘  │  │
│  └───────────────────────────┘  │
│  ┌───────────────────────────┐  │
│  │  view/mynet/*.htm         │  │  HTml 模板
│  └───────────────────────────┘  │
└─────────────────────────────────┘
  │  curl HTTP/HTTPS
  ▼
MyNet API 服务端 (/api/v1)
```

---

## 模块职责

### controller/mynet.lua
- 注册 LuCI 菜单和 URL 路由
- 每个 Action 对应一个页面（index / login / zones / nodes / node_detail / status / settings）
- 负责 HTTP 请求参数读取、调用 model、将数据传递到 view

### model/mynet/

| 模块 | 职责 |
|------|------|
| `util.lua` | 文件读写、Shell 命令执行、JSON 编解码工具函数 |
| `api.lua` | 封装 curl 调用，统一处理 HTTP GET/POST，返回解析后的 Lua table |
| `credential.lua` | 从 `/etc/mynet/conf/credential.json` 读写 Token / 过期时间 |
| `config.lua` | 从 `/etc/mynet/conf/config.json` 读写 `api_base_url` 等配置 |
| `auth.lua` | 登录（POST /auth/login）、登出、Token 有效性校验与刷新 |
| `zone.lua` | 获取区域列表（GET /user/zones）、切换当前区域 |
| `node.lua` | 获取节点列表/详情、拉取并写入 node.conf / route.conf |

### view/mynet/
HTml 模板，使用 LuCI 内置的 `<%=` / `<%` 模板语法渲染数据，**无独立前端框架**。

### htdocs/luci-static/resources/mynet/
- `mynet.css`：界面样式
- `mynet.js`：前端交互（状态轮询、表单提交等）

---

## 数据流：节点配置同步

```
用户点击「同步配置」
  │
  ▼ controller: action_node_detail()
  │
  ├─ node.get_node_config(node_id)
  │     └─ api.get("/nodes/{id}/config?render_conf=1")
  │         └─ util.write_file("/etc/mynet/node.conf", content)
  │
  ├─ node.get_route_config(node_id)
  │     └─ api.get("/route/node/{id}?render_conf=1")
  │         └─ util.write_file("/etc/mynet/route.conf", content)
  │
  └─ util.shell("/etc/init.d/mynet restart")
```

---

## 认证机制

1. 用户在登录页提交用户名/密码
2. `auth.login()` → `POST /auth/login` → 获取 `access_token` + `expires_at`
3. Token 写入 `/etc/mynet/conf/credential.json`
4. 后续每次 API 请求，`api.lua` 自动从 `credential.lua` 读取 Token 并注入 `Authorization: Bearer` 头
5. Token 过期时，`auth.refresh()` 使用 refresh_token 续期；失败则跳回登录页

---

## 会话管理

本项目**不维护独立会话**，直接复用 LuCI 本身的 HTTP Session（`luci.dispatcher` 的认证中间件）。
MyNet 的 Token 存储在路由器本地文件，属于系统级凭证，不与浏览器 Session 绑定。

---

## 静态资源缓存

LuCI 通过 `/www/luci-static/` 直接由 uhttpd 提供静态文件，**绕过 CGI**，具有较好的缓存性能。
CSS/JS 修改后若浏览器有缓存，强制刷新（Ctrl+F5）即可。
