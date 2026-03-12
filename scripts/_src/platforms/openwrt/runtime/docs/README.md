# MyNet OpenWrt 集成

本目录包含 MyNet 在 OpenWrt 系统上的集成脚本和配置文件。

## 文件说明

### 核心文件
- `mynet_dynamic` - MyNet 动态服务脚本（主要组件）
- `deploy-service.sh` - 服务部署脚本
- `firewall.mynet` - 防火墙配置文件

### 路由网关脚本
- `route_gw.sh` - 完整的路由网关配置脚本
- `route_gw_simple.sh` - 简化版路由网关脚本
- `route_gw_example.conf` - 配置示例文件

### 文档
- `openwrt_gw.md` - OpenWrt 网关配置文档

## 部署流程

### 前提条件
1. OpenWrt 系统已安装
2. mynet 软件已安装并验证通过
3. 具有 root 权限

### 部署步骤

#### 1. 上传文件到 OpenWrt
```bash
# 将整个 openwrt 目录上传到 OpenWrt 设备
scp -r openwrt/ root@192.168.1.1:/tmp/mynet-openwrt/
```

#### 2. 部署服务
```bash
# 登录到 OpenWrt 设备
ssh root@192.168.1.1

# 进入部署目录
cd /tmp/mynet-openwrt

# 运行部署脚本
./deploy-service.sh --deploy
```

#### 3. 启动服务
```bash
# 启动服务
/etc/init.d/mynet start

# 启用开机启动
/etc/init.d/mynet enable

# 检查状态
/etc/init.d/mynet status
```

## 架构特性

### 零侵入设计
- **不修改系统配置**：不会修改 `/etc/config/network` 和 `/etc/config/firewall`
- **动态创建**：接口、防火墙规则、路由表都在运行时动态创建
- **完全可逆**：停止服务即清理所有动态配置

### 自动检测能力
- **VPN 类型检测**：自动检测 GNB（gnb_tun*）或 WireGuard（wg*）
- **路由器模式检测**：自动识别旁路由模式（无 WAN）或网关模式（有 WAN）
- **防火墙系统检测**：自动适配 fw3（iptables）或 fw4（nftables）

### 动态管理
- **接口管理**：动态创建 VPN 接口，无需预配置
- **防火墙规则**：根据模式动态添加转发和 NAT 规则
- **路由管理**：智能路由分流和策略路由

## 使用场景

### 旁路由模式（Bypass Router）
- 无 WAN 接口的旁路由设备
- 提供透明代理和分流服务
- 不影响主路由器配置

### 网关模式（Gateway Router）
- 有 WAN 接口的主路由器
- 提供完整的网关和 VPN 服务
- 支持多 WAN 负载均衡

## 服务管理

### 基本命令
```bash
# 启动服务
/etc/init.d/mynet start

# 停止服务
/etc/init.d/mynet stop

# 重启服务
/etc/init.d/mynet restart

# 重新加载配置
/etc/init.d/mynet reload

# 查看状态
/etc/init.d/mynet status

# 启用开机启动
/etc/init.d/mynet enable

# 禁用开机启动
/etc/init.d/mynet disable
```

### 高级功能
```bash
# 安装服务（首次部署时自动调用）
/etc/init.d/mynet install

# 卸载服务
/etc/init.d/mynet uninstall

# 检查配置
/etc/init.d/mynet check

# 调试模式
/etc/init.d/mynet debug
```

## 配置文件

### 配置文件结构
MyNet 使用模块化的配置文件系统，每个文件负责特定的功能：

```
/etc/mynet/
├── mynet.conf     # 主配置文件
├── vpn.conf       # VPN 服务配置
├── node.conf      # GNB 节点配置
└── route.conf     # 路由规则配置
```

### 主配置文件 (`mynet.conf`)
```bash
# 路由器模式
ROUTER_MODE=auto              # auto, bypass, gateway

# 网络接口
LAN_INTERFACE=br-lan          # LAN 接口名称
WAN_INTERFACE=wan             # WAN 接口名称

# VPN 区域
VPN_ZONE=mynet                # 防火墙区域名称

# 日志配置
LOG_LEVEL=INFO                # DEBUG, INFO, WARN, ERROR
LOG_FILE=/var/log/mynet.log   # 日志文件路径
DEBUG=0                       # 调试模式

# 路径配置
MYNET_ROOT=/opt/mynet         # MyNet 安装根目录
VPN_CONFIG=/etc/mynet/vpn.conf
ROUTE_CONFIG=/etc/mynet/route.conf

# 高级选项
STARTUP_DELAY=0               # 启动延迟（秒）
INTERFACE_TIMEOUT=30          # 接口创建超时
VPN_STARTUP_TIMEOUT=60        # VPN 启动超时
FIREWALL_VERSION=auto         # 防火墙版本：auto, fw3, fw4
ENABLE_MASQUERADE=auto        # 启用 MASQUERADE
```

### VPN 配置文件 (`vpn.conf`)
```bash
# VPN 基本配置
VPN_TYPE=gnb                  # gnb, wireguard, auto
VPN_INTERFACE=gnb_tun0        # VPN 接口名称

# 服务管理
VPN_START_CMD="/opt/mynet/driver/gnb/bin/gnb -c /etc/mynet/node.conf -d"
VPN_STOP_CMD="killall gnb"
VPN_PID_FILE=/var/run/gnb.pid

# 接口管理
PRECREATE_INTERFACE=1         # 预创建接口
KEEP_INTERFACE_DOWN=1         # 接口保持 DOWN 状态

# 路径配置
VPN_SERVICE_CONFIG=/etc/mynet/node.conf
VPN_DATA_DIR=/var/lib/mynet

# 高级选项
VPN_START_DELAY=2             # VPN 启动前等待
VPN_HEALTH_CHECK_INTERVAL=30  # 健康检查间隔
VPN_AUTO_RESTART=1            # 自动重启
```

### GNB 节点配置 (`node.conf`)
```bash
# 节点身份
nodeid=1001                   # 节点 ID
ed25519_private_key_file=/var/lib/mynet/ed25519.private

# 网络接口
listen=0.0.0.0:9001           # 监听地址
ifname=gnb_tun0               # 接口名称（与 vpn.conf 一致）
mtu=1420                      # MTU 大小

# 连接配置
index_address=your-index-server.com:9001
address4=10.1.0.1/24         # 虚拟 IP 地址

# 功能选项
upnp=no                       # UPnP 端口映射
route_push=yes                # 路由推送
multicast=no                  # 多播
crypto=aes128                 # 加密算法
compress=lz4                  # 压缩算法
log_level=1                   # 日志级别
```

### 路由配置 (`route.conf`)
```bash
# 基本路由规则
# 格式: 目标网段 网关 接口 metric
10.0.0.0/8 via_interface gnb_tun0 100
172.16.0.0/12 via_interface gnb_tun0 100

# 策略路由
# 格式: policy_route 源网段 目标网段 接口 优先级
policy_route 192.168.1.0/24 0.0.0.0/0 gnb_tun0 100

# 域名路由
# 格式: domain_route 域名 接口 DNS服务器
domain_route example.com gnb_tun0 8.8.8.8

# 排除路由
exclude_route 192.168.0.0/16
exclude_route 10.0.0.0/8

# 高级选项
route_table_id=100            # 路由表 ID
route_priority=100            # 路由优先级
enable_route_cache=yes        # 启用路由缓存
enable_dynamic_routes=yes     # 启用动态路由
enable_multipath=no           # 启用多路径负载均衡
```

## 故障排除

### 检查日志
```bash
# 查看服务日志
tail -f /var/log/mynet.log

# 查看系统日志
logread | grep mynet
```

### 常见问题

#### 1. 服务启动失败
- 检查 mynet 软件是否已安装：`mynet --version`
- 检查权限：`ls -l /etc/init.d/mynet`
- 查看详细错误：`/etc/init.d/mynet debug`

#### 2. 网络不通
- 检查接口状态：`ip link show`
- 检查路由表：`ip route show`
- 检查防火墙规则：`iptables -L -n` 或 `nft list ruleset`

#### 3. VPN 检测失败
- 确认 VPN 软件已启动
- 检查接口命名规则：GNB（gnb_tun*）、WireGuard（wg*）
- 手动指定 VPN 类型和接口

## 技术原理

### 动态接口管理
- 使用 `ip link` 命令动态创建和删除接口
- 不写入 `/etc/config/network`
- 支持热插拔和动态重配

### 动态防火墙管理
- 运行时添加 iptables/nftables 规则
- 不修改 `/etc/config/firewall`
- 停止时自动清理规则

### 智能检测机制
- 通过接口命名模式检测 VPN 类型
- 通过 UCI 配置检测路由器模式
- 通过系统特征检测防火墙类型

这种设计确保了最大的兼容性和最小的系统侵入性，适合各种 OpenWrt 环境和配置。