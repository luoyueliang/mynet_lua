# GNB 离线模式 — mynet_client 对接规范

> **状态**: mynet_lua 侧已完成，等待 mynet_client 适配  
> **日期**: 2025-07

---

## 概述

mynet_lua 新增 **Guest 模式（GNB 离线模式）**，用户无需 MyNet 帐号即可在路由器上创建
本地 GNB VPN 网络。路由器生成所有节点的密钥和配置文件，远程设备通过下载配置包接入。

**差异化**：Guest 模式不支持 Proxy 流量分流功能（仅在线用户模式支持）。

---

## Guest 模式数据结构

### guest.json (`/etc/mynet/conf/guest.json`)

```json
{
  "network_name": "MyNetwork",
  "subnet": "10.1.0",
  "listen_port": 9001,
  "local_node_id": 1001,
  "nodes": [
    { "node_id": 1001, "name": "Router (本机)", "virtual_ip": "10.1.0.1", "is_local": true },
    { "node_id": 1002, "name": "设备 2", "virtual_ip": "10.1.0.2", "is_local": false },
    { "node_id": 1003, "name": "设备 3", "virtual_ip": "10.1.0.3", "is_local": false }
  ],
  "created_at": "2025-07-01T00:00:00Z"
}
```

### 配置文件路径

与在线模式共用 GNB 配置目录：

```
/etc/mynet/driver/gnb/conf/{node_id}/
├── node.conf
├── route.conf
├── address.conf
├── security/
│   ├── {node_id}.private   # 128 hex chars (64 bytes)
│   └── {node_id}.public    # 64 hex chars (32 bytes)
└── ed25519/
    ├── {peer1}.public
    └── {peer2}.public
```

### 模式标识

`config.json` 中 `"mode": "guest" | "mynet"`

---

## 导出配置包格式

API `GET /admin/services/mynet/api/guest_export?node_id=1002` 返回 `tar.gz`：

```
gnb_node_1002.tar.gz
├── node.conf
├── route.conf
├── address.conf          # 含 n|1001|<ROUTER_IP>|9001 模板
├── security/
│   ├── 1002.private
│   └── 1002.public
└── ed25519/
    ├── 1001.public
    ├── 1002.public
    └── 1003.public
```

**注意**: `address.conf` 中 `<ROUTER_IP>` 需要用户手动替换为路由器实际 IP 地址。

---

## mynet_client 需要适配的功能

### 1. 导入 Guest 配置包

mynet_client 应支持导入 `gnb_node_XXXX.tar.gz` 配置包：

```
mynet_client import --config gnb_node_1002.tar.gz
```

- 解压到本地 GNB 配置目录
- 提示用户设置 `address.conf` 中的路由器 IP
- 启动 GNB 连接

### 2. 一键升级（未来）

未来 mynet 后端新增导入接口后，mynet_client 应支持：

```
mynet_client upgrade --from-guest
```

- 读取本地 guest 配置中的密钥
- 调用 MyNet API 注册/导入节点
- 将 Guest 节点转换为在线管理的节点
- 切换模式为 `"mynet"`

### 3. 后端导入接口（待开发）

MyNet API 侧需新增：

```
POST /api/v1/nodes/import
{
  "public_key": "hex...",
  "node_id": 1002,          // guest 分配的 ID，服务端可重新分配
  "network_name": "MyNetwork"
}
```

返回新的服务端 node_id + zone 信息。

---

## Guest 模式 Node ID 范围

- Guest 节点 ID 从 **1001** 开始递增
- 在线模式节点 ID 为服务端分配的大整数（如 `3840000000000001`）
- 两者不会冲突

---

## API 汇总

| Endpoint | Method | 说明 |
|----------|--------|------|
| `/api/guest_init` | POST | 初始化: node_count, network_name, subnet, listen_port, local_index |
| `/api/guest_nodes` | GET | 获取节点列表 + 运行状态 |
| `/api/guest_add` | POST | 新增节点: name |
| `/api/guest_delete` | POST | 删除节点: node_id |
| `/api/guest_export` | GET | 下载配置包: node_id → tar.gz |
| `/api/guest_start` | POST | 启动 GNB |
| `/api/guest_stop` | POST | 停止 GNB |
| `/api/guest_reset` | POST | 重置网络（删除所有配置） |
| `/api/set_mode` | POST | 切换模式: mode=mynet|guest |

所有 API 路径前缀: `/admin/services/mynet/api/`
