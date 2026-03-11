# mynet-luci — MyNet VPN LuCI 管理界面

基于 OpenWrt LuCI 框架的 MyNet VPN Web 管理界面，对应 Go 版 `mynet_tui` 的全部核心功能。

## 功能

- 用户认证（登录 / 登出 / Token 自动刷新）
- 区域（Zone）列表与切换
- 节点（Node）列表、详情、状态查看
- 配置同步（node.conf / route.conf / address.conf）
- VPN 服务启停（调用 `/etc/init.d/mynet`）
- 系统状态监控（VPN 接口、运行时间、负载）
- 设置页面（API 服务器地址）

## 项目结构

```
mynet_lua/
├── Makefile                          # OpenWrt 包构建文件
├── luasrc/
│   ├── controller/
│   │   └── mynet.lua                 # URL 路由与 Action 处理
│   ├── model/
│   │   └── mynet/
│   │       ├── util.lua              # 文件I/O、Shell、JSON 工具
│   │       ├── api.lua               # HTTP REST 客户端（curl）
│   │       ├── credential.lua        # 凭证持久化（JSON 文件）
│   │       ├── config.lua            # 配置文件读写
│   │       ├── auth.lua              # 认证逻辑
│   │       ├── zone.lua              # 区域管理
│   │       └── node.lua              # 节点管理
│   └── view/
│       └── mynet/
│           ├── index.htm             # 控制台
│           ├── login.htm             # 登录
│           ├── zones.htm             # 区域列表
│           ├── nodes.htm             # 节点列表
│           ├── node_detail.htm       # 节点详情
│           ├── status.htm            # 系统状态
│           └── settings.htm          # 设置
├── htdocs/
│   └── luci-static/resources/mynet/
│       ├── css/mynet.css
│       └── js/mynet.js
└── root/etc/mynet/conf/
    └── config.json                   # 默认 API 配置
```

## 安装（OpenWrt）

```bash
# 复制文件到路由器
scp -r . root@192.168.1.1:/tmp/mynet-luci/

# 在路由器上执行
cd /tmp/mynet-luci
cp -r luasrc/controller/mynet.lua     /usr/lib/lua/luci/controller/
cp -r luasrc/model/mynet/             /usr/lib/lua/luci/model/
cp -r luasrc/view/mynet/              /usr/share/luci/view/
cp -r htdocs/luci-static/resources/mynet/ /www/luci-static/resources/
cp -n root/etc/mynet/conf/config.json /etc/mynet/conf/config.json 2>/dev/null

# 清理 LuCI 缓存
rm -rf /tmp/luci-*

# 访问
# http://router-ip/cgi-bin/luci/admin/mynet
```

## OpenWrt 包构建

```bash
# 在 OpenWrt SDK 中
make package/mynet-luci/compile V=s
```

## 前置依赖

| 依赖 | 说明 |
|------|------|
| `luci-base` | LuCI 框架核心 |
| `curl` | HTTP 请求（API 通信）|
| `luci-lib-jsonc` | JSON 解析 |
| `mynet` | MyNet VPN 主程序 |

## API 对接

与 MyNet 服务端 API (`/api/v1`) 完全兼容。API 地址在 `/etc/mynet/conf/config.json` 中配置：

```json
{
  "server_config": {
    "api_base_url": "https://your-server/api/v1",
    "timeout": 30
  }
}
```

## 认证流程

```
POST /auth/login → 保存 credential.json
              ↓
GET /user/zones → 选择区域
              ↓
GET /nodes → 选择节点
              ↓
GET /nodes/{id}/config?render_conf=1 → 下载 node.conf
GET /route/node/{id}?render_conf=1   → 下载 route.conf
              ↓
/etc/init.d/mynet start
```

## 版本

v1.0.0 — 2026-03-12
