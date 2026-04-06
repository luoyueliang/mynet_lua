# mynet-luci — MyNet VPN LuCI 管理界面

基于 OpenWrt LuCI 框架的 MyNet/GNB VPN Web 管理界面，对应 Go 版 `mynet_tui` 的全部核心功能。

## 功能

- **安装向导** — 单选式引导：在线模式（MyNet 账号）/ 导入配置 / 创建网络 / 手动配置
- **MyNet 在线模式** — 登录 → 选区域 → 选节点 → 配置自动下载，支持远程管理、密钥交换、代理插件
- **离线/Guest 模式** — 无需 MyNet 账号：导入 .tar.gz 配置包或创建新的本地 GNB 网络
- **节点管理** — node.conf / route.conf / address.conf 配置查看与同步，密钥生成/导入
- **GNB 服务控制** — 启动/停止/重启 GNB VPN，实时状态监控
- **代理分流** — 代理模式配置（客户端/服务端），DNS 分流，区域路由策略
- **系统诊断** — 依赖检查、网络诊断、日志查看、GNB 自动安装
- **完整中文化** — 所有界面字符串提供中英双语（PO 翻译）

## 项目结构

```
mynet_lua/
├── Makefile                              # OpenWrt 包构建
├── luasrc/
│   ├── controller/mynet.lua              # URL 路由 + Action/API handlers
│   ├── model/mynet/
│   │   ├── util.lua                      # 基础工具（文件IO/Shell/JSON/日志）
│   │   ├── api.lua                       # HTTP REST 客户端（curl 封装）
│   │   ├── auth.lua                      # 认证逻辑（登录/Token 刷新）
│   │   ├── config.lua                    # 本地配置读写
│   │   ├── credential.lua                # 凭证持久化
│   │   ├── node.lua                      # 节点管理（配置同步/密钥/GNB启停）
│   │   ├── zone.lua                      # Zone 区域管理
│   │   ├── guest.lua                     # Guest 离线模式
│   │   ├── proxy.lua                     # 代理分流管理
│   │   ├── system.lua                    # 系统状态/依赖检查/心跳
│   │   ├── gnb_installer.lua             # GNB 自动检测与安装
│   │   └── validator.lua                 # 配置校验
│   └── view/mynet/
│       ├── index.htm                     # Dashboard 控制台
│       ├── wizard.htm                    # 安装向导（Landing→Zone→Node）
│       ├── login.htm                     # MyNet 账号登录
│       ├── guest.htm                     # 离线网络节点管理
│       ├── node.htm                      # 节点配置（配置/密钥/列表 Tab）
│       ├── service.htm                   # 运维中心（状态/网络/Peers/日志/诊断）
│       ├── plugin.htm                    # 插件列表
│       ├── proxy.htm                     # 代理分流配置
│       └── settings.htm                  # 系统设置
├── htdocs/luci-static/resources/mynet/
│   ├── css/mynet.css                     # 样式
│   └── js/mynet.js                       # 前端逻辑
├── po/
│   ├── templates/mynet.pot               # 翻译模板
│   └── zh-cn/mynet.po                    # 中文翻译
├── scripts/                              # 运行时脚本（安装/代理/工具）
├── root/etc/mynet/conf/config.json       # 默认 API 配置
├── docs/                                 # 文档（架构/流程图/构建/部署）
└── debug/                                # 开发用 QEMU 虚拟机工具
```

## 快速开始

### 开发环境部署（QEMU）

```bash
# 启动 OpenWrt QEMU 虚拟机
bash debug/start.sh

# 同步代码到虚拟机并安装
bash debug/sync.sh all

# 访问：http://192.168.101.2/cgi-bin/luci/admin/services/mynet
```

### 生产安装（OpenWrt）

```bash
# 方式 1：IPK 包安装
# 从 GitHub Releases 下载 .ipk
scp luci-app-mynet_2.0.0-1_all.ipk root@router:/tmp/
ssh root@router "opkg install /tmp/luci-app-mynet_2.0.0-1_all.ipk"

# 方式 2：手动复制
bash debug/sync.sh all  # 或手动 scp 各目录
```

## 前置依赖

| 依赖 | 说明 |
|------|------|
| `luci-base` | LuCI 框架核心 |
| `curl` / `libcurl-gnutls4` | HTTP 请求（API 通信 + TLS） |
| `luci-lib-jsonc` | JSON 解析（可降级到内置 fallback） |
| `gnb` | GNB VPN 二进制（可通过设置页自动安装） |
| `kmod-tun` | TUN 内核模块 |
| `bash` | 服务脚本运行时 |
| `ca-bundle` | CA 证书包 |

## 架构要点

### 安全
- 所有 API 端点统一通过 `require_api_auth()` 进行认证 + 频率限制
- node_id 参数通过 `parse_node_id()` 统一校验（防注入）
- Shell 参数通过 `util.shell_escape()` 转义
- 敏感文件（凭证/私钥）使用 `write_file_secure()` 写入（权限 0600）

### 编码规范
- 大整数 node_id 必须使用 `util.int_str()` 转换（避免 Lua 科学计数法）
- JS 端 `window.mnCurrentNodeId` 使用字符串（避免精度丢失）
- API URL 通过 `_mnApiBase()` 构造（不硬编码路径）

### 国际化
- 模板使用 `<%:String%>` LuCI 翻译标签
- PO 文件：`po/zh-cn/mynet.po`（460+ 翻译条目）

## 文档

- [架构设计](docs/architecture.md) — 模块职责、数据流、安全设计
- [核心流程图](docs/FLOWS.md) — Mermaid 图（向导/切换/安装/启动/代理）
- [构建指南](docs/build.md)
- [部署指南](docs/deploy.md)

## 版本

v2.0.0 — 2026-04
