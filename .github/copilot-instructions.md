# MyNet Lua — Copilot 指南

> Lua 5.1 / LuCI v3 / OpenWrt  
> 包名: luci-app-mynet v1.0.0

## 📚 MyNet 生态系统知识库

> **SSOT 知识库**位于 `mynet_ctl/docs/knowledge-base/`：
> - [ecosystem.md](../../mynet_ctl/docs/knowledge-base/ecosystem.md) — 项目全景与关系图
> - [conventions.md](../../mynet_ctl/docs/knowledge-base/conventions.md) — 统一规范
> - [projects/mynet_lua.md](../../mynet_ctl/docs/knowledge-base/projects/mynet_lua.md) — 本项目速查卡

## 项目定位

OpenWrt 路由器专用 MyNet 管理界面。功能与 mynet_tui/mynet_client 完全对应，但适配 OpenWrt 资源受限环境。

**为何保留 Lua**：OpenWrt 路由器无法运行 Node.js/Go，Lua 是 LuCI 原生语言。

## ⚠️ 强制规则

### 1. API 调用
使用 curl 调用 REST API（无 HTTP 库），通过 `model/mynet/api.lua` 封装。

### 2. LuCI MVC 架构
```
luasrc/
├── controller/mynet.lua       URL 路由与动作处理
├── model/mynet/               业务逻辑
│   ├── util.lua               文件 I/O, JSON, Shell 工具
│   ├── api.lua                HTTP 客户端
│   ├── auth.lua               登录认证
│   ├── config.lua             配置管理
│   ├── zone.lua               Zone 操作
│   ├── node.lua               节点操作
│   ├── system.lua             平台检测
│   └── gnb_installer.lua      GNB 安装
└── view/mynet/                HTM 视图模板
```

### 3. 配置存储
- `/etc/mynet/conf/config.json` — API URL、超时设置
- `/etc/mynet/conf/credential.json` — Token 持久化
- UCI 集成用于 OpenWrt 网络配置

### 4. GNB 路径
遵循 GNB 标准目录结构（参见知识库 conventions.md）。
OpenWrt 上 GNB 安装在 `/usr/bin/` 或 `/opt/mynet/bin/`。

### 5. 前端
- 静态 HTML + CSS + JavaScript（htdocs/luci-static/resources/mynet/）
- 无构建工具、无 npm——纯静态文件
- LuCI 模板引擎（HTM）渲染服务端页面

## 数据流

```
mynet_back (认证 + 配置) ← curl → model/mynet/api.lua
mynet_ctl (binary 下载) ← curl → model/mynet/gnb_installer.lua
```
