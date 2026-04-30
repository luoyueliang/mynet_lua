# macOS + QEMU VM 随身分流路由器

> 实战文档 · 2025-04
> 基于真实调试经验，涵盖 macOS 网络栈的深度踩坑与解决方案

---

## 1. 方案概述

在 macOS 上通过 QEMU 运行一个 Linux/OpenWrt 虚拟机，让 VM 作为**透明分流路由器**：国内流量直连，海外流量走 VPN 隧道。macOS 本机和下游设备的流量全部经过 VM 分流，应用层无感知。

```
┌─────────────────────────────────────────────────────┐
│ macOS (笔记本)                                        │
│                                                       │
│  应用 → 路由表 → bridge100 (vmnet-host)               │
│                       │                               │
│              ┌────────┴────────┐                      │
│              │  QEMU VM        │  ← 随身携带，开盖即用  │
│              │  Linux/OpenWrt  │                      │
│              │  ┌────────────┐ │                      │
│              │  │ 分流引擎    │ │  nft set / ipset     │
│              │  │ 国内→直连   │ │                      │
│              │  │ 海外→VPN   │ │  → GNB/WireGuard     │
│              │  └────────────┘ │                      │
│              │  eth1 (WAN)     │                      │
│              └────────┬────────┘                      │
│                       │                               │
│              vmnet-bridged → en0 WiFi → 物理路由器     │
└─────────────────────────────────────────────────────┘
```

**VM 不限定发行版**，只要满足三个条件：

1. **IP 转发** — 能作为路由器转发流量
2. **分流能力** — nft set / ipset 实现国内/海外 IP 分流
3. **NAT** — MASQUERADE 保证回程包能正确返回

OpenWrt、Debian、Alpine、任何 Linux 发行版都可以。

---

## 2. 为什么需要这个方案

| 场景 | 问题 | 本方案的解决方式 |
|------|------|-----------------|
| 笔记本用户 | 没有固定路由器做分流 | VM 随身携带，任何网络环境都能用 |
| macOS 无原生分流 | 没有 ipset/nft set，pf 是阉割版 | 把分流能力交给 VM |
| 系统代理的局限 | 很多应用不走系统代理（终端、游戏、后台服务） | 路由层透明代理，所有流量都走 |
| VPN 客户端的局限 | 全局 VPN 无法区分国内外，国内也绕一圈 | VM 内 ipset/nft set 精确分流 |

---

## 3. 网络架构

### 3.1 双网卡设计

VM 需要两块网卡：

| 网卡 | QEMU 模式 | macOS 侧接口 | 用途 |
|------|-----------|-------------|------|
| eth0 (LAN) | vmnet-host | bridge100 (192.168.101.1) | 管理口 + macOS 上游 |
| eth1 (WAN) | vmnet-bridged → en0 | bridge101 | 直连物理网络，出网口 |

```bash
# QEMU 启动参数
-device virtio-net-pci,netdev=lan
-netdev vmnet-host,id=lan,start-address=192.168.101.1,end-address=192.168.101.254,subnet-mask=255.255.255.0

-device virtio-net-pci,netdev=wan,mac=52:54:00:12:34:56
-netdev vmnet-bridged,id=wan,ifname=en0
```

### 3.2 流量路径

```
macOS 访问国内 IP：
  macOS → bridge100 → VM eth0 → nft 匹配国内 → eth1 → 路由器 → 直连
  延迟：+1-3ms

macOS 访问海外 IP：
  macOS → bridge100 → VM eth0 → nft 匹配海外 → VPN 隧道 → 出口节点
  延迟：+70-100ms（取决于 VPN 节点）

macOS 访问局域网：
  macOS → en0 直连（/24 路由绕过 VM）
  延迟：0ms
```

### 3.3 vmnet-framework 的工作原理

Apple 的 vmnet.framework 是本方案的基础设施。它不是 Linux 意义上的 bridge，而是一个**代理层**：

```
VM eth0 (MAC: 52:54:00:12:34:56)
    │
    ▼
vmnet.framework
    ├── ARP 代理：路由器只看到 macOS 的 MAC
    ├── MAC 重写：VM 的帧以 macOS 身份发出
    └── DHCP 代理：以 macOS 名义获取 IP
    │
    ▼
en0 WiFi (macOS 自己的 MAC)
    │
    ▼
路由器（看到的始终是 macOS 的 MAC，Wi-Fi 协议合规）
```

**为什么这很重要：** Wi-Fi（802.11）不支持真正的二层桥接。无线网卡要求每个 MAC 必须与 AP 单独关联认证。Linux 的 bridge + TAP 在 Wi-Fi 下无法工作。vmnet.framework 通过代理绕过了这个限制。

### 3.4 QEMU 资源配置

本方案的 VM 只服务于一台 macOS 主机，资源需求极低：

| 资源 | 配置 | 说明 |
|------|------|------|
| 内存 | 256M | nft set 加载 1.7 万条规则需要 ~150M，128M 会被 OOM killer 杀掉 |
| CPU | 2 核 | 转发和 nft 匹配都是轻量操作，2 核绑绑有余 |
| 磁盘 | 1-2G | qcow2 镜像，随用随扩 |
| 硬件加速 | HVF | Apple 原生虚拟化，`-machine virt,accel=hvf`，接近原生性能 |

```bash
# 最小化启动参数
-machine virt,accel=hvf    # Apple HVF 硬件加速（必须）
-cpu host                   # 透传宿主 CPU 特性
-smp 2                      # 2 核
-m 256M                     # 256M 内存（nft set 加载需要，128M 会 OOM）
```

**为什么 256M：** nft set 加载 1.7 万条 IP 段时，`nft -f` 进程峰值内存 ~150M。128M 会被内核 OOM killer 杀掉，导致分流规则加载失败。256M 是实际测试的最低要求。

**HVF 硬件加速：** macOS 的 Hypervisor.framework（QEMU 中的 `accel=hvf`）直接使用 Apple Silicon 的虚拟化扩展，VM 指令在硬件上执行，无需二进制翻译。性能接近原生，启动时间 < 1 秒。没有 HVF 的话，QEMU 会退回到 TCG（软件模拟），性能下降 10-50 倍。

---

## 4. macOS 网络栈的深度踩坑

> 这是本文档最有价值的部分。macOS 的网络栈相比 Linux 有大量隐性限制，不踩不知道。

### 4.1 克隆路由（Cloning Route）—— 最大的坑

**问题：** macOS 的 en0 接口在获得 IP 时，系统自动创建一条**克隆路由**：

```
default  link#14  UCSIg  en0 !
```

这条路由的行为：**对任何目标 IP，自动在 en0 上创建 /32 主机路由（克隆）**。克隆发生在路由查找时——内核查路由表，先命中这条克隆路由，立即为目标 IP 在 en0 上创建缓存条目。

**后果：** 即使你添加了 `route add default 192.168.101.2`（指向 VM），`route get 8.8.8.8` 仍然返回 `interface: en0`。因为克隆路由先被命中，创建了 /32 主机路由。/32 比任何网段路由优先级都高。

**无法删除：** 这条路由绑定在 en0 的 IP 地址上，不是绑定在默认网关上。删了默认路由它还在，删了它系统立刻重建。是内核级行为，用户态无法控制。

```
# 尝试删除 —— 失败
sudo route -n delete default -cloning -ifscope en0
# route: writing to routing socket: not in table

# 即使删了默认路由，克隆路由仍然存在
sudo route -n delete default
netstat -rn | grep UCSIg
# default  link#14  UCSIg  en0 !   ← 还在
```

**影响范围：** 所有基于 `route add default` 的方案都失效。包括：
- `route add default 192.168.101.2`
- `route add -net 0.0.0.0/0 192.168.101.2`
- `route add -net 0.0.0.0/1` + `route add -net 128.0.0.0/1`

**这是 macOS 网络栈最致命的限制。**

### 4.2 pf（Packet Filter）—— 功能残缺

macOS 的 pf 基于 2003 年的 OpenBSD 代码，之后基本没有更新。与现代 Linux 的 nftables 相比：

| 功能 | Linux nftables | macOS pf |
|------|---------------|----------|
| 策略路由（fwmark + ip rule） | ✅ | ❌ |
| ipset / nft set | ✅ | ❌ |
| route-to（指定出接口） | ✅ | 部分支持，行为不一致 |
| OUTPUT 链标记 | ✅ | ❌ |
| 连接跟踪 | 完整 | 有限 |
| 版本 | 持续更新 | 2003 年代码，冻结 |

实际测试中，pf 的 `route-to` 规则无法正确将流量导向 bridge100。包被发出后，路由表的克隆路由仍然生效，pf 无法覆盖。

### 4.3 bridge 接口 —— 半成品

macOS 的 bridge 接口有多个怪异行为：

**permanent ARP 条目：** bridge100 会为某些 IP 创建永久 ARP 条目，指向 bridge 自己的 MAC 地址。这些条目无法删除（`arp -d` 无效），会导致发往这些 IP 的包被桥接回本地，形成环路。

```
arp -i bridge100 -a
# dns.google (8.8.8.8) at 6e:7e:67:2c:57:64 on bridge100 permanent [bridge]
# ↑ 指向 bridge100 自己的 MAC，导致 8.8.8.8 的包被回环
```

**SMART 模式：** bridge 默认开启 SMART 模式，会自动学习和缓存 ARP 条目。无法通过 `ifconfig` 关闭（`-smart` 参数不被支持）。

**无独立 IP：** vmnet-host 创建的 bridge100 接口本身没有 IP 地址（IP 在 macOS 侧的接口上），导致某些路由场景异常。

### 4.4 网络配置碎片化

macOS 的网络配置分散在多个互不兼容的系统中：

| 工具 | 作用域 | 限制 |
|------|--------|------|
| `route` | 路由表 | 无法控制克隆行为 |
| `ifconfig` | 接口配置 | 无法关 SMART，参数有限 |
| `networksetup` | 系统偏好设置 | 需要 sudo，改的是 SystemConfiguration |
| `scutil` | 系统配置 | 复杂的键值存储 |
| `pfctl` | 包过滤 | 功能残缺 |
| `ipconfig` | DHCP/接口信息 | 只读 |

这些工具之间没有统一的协调机制。用 `route` 改的路由不会通知 `networksetup`，`networksetup` 改的配置可能被 `configd` 覆盖。

### 4.5 没有策略路由

Linux 的策略路由：

```bash
ip rule add fwmark 1 table 100
ip route add default via 10.0.0.1 table 100
iptables -t mangle -A OUTPUT -p tcp --dport 443 -j MARK --set-mark 1
```

macOS：**完全不支持。** 没有 `ip rule`，没有 fwmark，没有多路由表。路由决策完全由内核的单一路由表决定，用户态无法干预。

---

## 5. 解决方案：/8 路由覆盖法

### 5.1 核心发现

经过大量测试，我们发现：

- **克隆路由创建的是 /32 主机路由**
- **显式添加的 /8 网段路由优先级低于 /32 克隆路由**
- **但是：如果在流量发生之前预先添加 /8 路由，克隆不会覆盖**

原因：路由查找时，如果已存在一个匹配的显式路由（/8），内核直接使用它，不会触发克隆。克隆只在"没有显式路由"时发生。

### 5.2 方案

```bash
# 1. 所有公网 IP 走 VM（223 条 /8 路由）
for i in $(seq 0 126) $(seq 128 223); do
    sudo route -n add -net ${i}.0.0.0/8 192.168.101.2
done

# 2. 本地子网走 en0（更具体，覆盖 /8）
sudo route -n add -net 192.168.10.0/24 -interface en0
```

**效果验证：**

```
route get 9.9.9.9
  → gateway: 192.168.101.2
  → interface: bridge100        ✓ 走 VM

traceroute 9.9.9.9
  1  192.168.101.2              ← VM
  2  10.182.236.180             ← VPN 出口 (EC2)
  3  15.230.209.22              ← 互联网

curl https://api.ipify.org
  → 52.221.22.241               ← EC2 IP，不是本地 WiFi IP

ping 192.168.10.1
  → 3.6ms                       ← 局域网直连，不走 VM
```

### 5.3 路由表最终状态

```
0.0.0.0/8       → 192.168.101.2 (VM)     公网 A 类
1.0.0.0/8       → 192.168.101.2 (VM)     公网 A 类
...
10.0.0.0/8      → 192.168.101.2 (VM)     公网 A 类（VM 的 WAN 同网段，可路由）
...
192.168.10.0/24 → en0 (直连)              本地子网（更具体，覆盖 192.168.x.x/8）
...
223.0.0.0/8     → 192.168.101.2 (VM)     公网 A 类
```

共 224 条路由。`route add` 每条约 10ms，总计 ~2 秒完成。

### 5.4 为什么 10.0.0.0/8 也可以走 VM

一个疑问：10.0.0.0/8 是内网地址，走 VM 会不会有问题？

不会。因为：
- VM 的 WAN (eth1) 和 macOS 的 en0 在**同一个物理网络**上
- VM 能访问 192.168.10.0/24 上的所有设备，包括可能的 10.x.x.x 设备
- 如果 10.x.x.x 设备在路由器后面，路由器会处理

唯一需要走 en0 的是 **macOS 所在的 /24 子网**（192.168.10.0/24），因为这是 macOS 直接可达的链路层网络。

---

## 6. VM 内的分流实现

VM 内的分流不限于 OpenWrt。任何 Linux 发行版，只要能装 nftables 和 VPN 客户端，都可以。

### 6.1 最小要求

```bash
# 1. 开启 IP 转发
echo 1 > /proc/sys/net/ipv4/ip_forward

# 2. 安装 nftables
apt install nftables    # Debian/Ubuntu
opkg install nftables   # OpenWrt

# 3. 安装 VPN 客户端（GNB / WireGuard / OpenVPN 等）
```

### 6.2 nft set 分流（示例）

```bash
nft add table inet mangle
nft add set inet mangle cn_dst { type ipv4_addr\; flags interval\; }
# 导入国内 IP 段（从 chnroutes 等来源）
nft add element inet mangle cn_dst { 1.0.1.0/24, 1.0.2.0/23, ... }

nft add chain inet mangle prerouting { type filter hook prerouting priority mangle\; }
nft add rule inet mangle prerouting ip daddr @cn_dst meta mark set 1
nft add rule inet mangle prerouting meta mark != 1 meta mark set 2

# mark=1 直连，mark=2 走 VPN
ip rule add fwmark 1 table main
ip rule add fwmark 2 table 200
ip route add default via <VPN_GATEWAY> dev <VPN_IFACE> table 200

# NAT
nft add table inet nat
nft add chain inet nat postrouting { type nat hook postrouting priority srcnat\; }
nft add rule inet nat postrouting oifname "eth1" masquerade
```

### 6.3 nft 分流只对转发流量生效

nft 的 `prerouting` 链只处理**从其他接口转发过来的包**，不处理 VM 本机产生的包。

**不要试图在 OUTPUT 链做分流**——看起来可行，实际有无法解决的环路问题：

1. 路由查找在 OUTPUT 之前已决定出接口
2. OUTPUT 里 mark 所有包 → VPN 隧道自身的封装包也被 mark → VPN 流量试图走 VPN 自己 → 环路
3. 无法在 OUTPUT 区分"代理的出站连接"和"VPN 的协议包"

**这意味着：在 VM 上运行代理软件（如 SOCKS5）无法实现分流。** 代理发出的包走 VM 的默认路由，不经过 prerouting 分流。

**本方案不受影响**——macOS 的流量对 VM 来说都是"转发"流量（从 eth0 进来，从 eth1/gnb_tun 出去），nft set 分流完全生效。VM 自身不需要做代理。

---

## 7. 持久化

### 7.1 macOS 路由持久化

macOS 重启后路由表重置。用 launchd 在登录后自动执行：

```xml
<!-- ~/Library/LaunchAgents/com.user.vm-gateway.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.user.vm-gateway</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/path/to/gateway-mode.sh</string>
    <string>on</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key>
  <string>/tmp/vm-gateway.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.user.vm-gateway.plist
```

### 7.2 VM 分流规则持久化

根据发行版不同：
- **OpenWrt**: 写入 `/etc/rc.local` 或 nftables 配置文件
- **systemd**: 创建 systemd service
- **通用**: 写入 `/etc/rc.local`

---

## 8. 风险与回退

| 风险 | 触发条件 | 回退方法 |
|------|---------|---------|
| macOS 断网 | VM 未启动但路由已加 | `bash gateway-mode.sh off` |
| VM 启动慢 | 路由加了但 VM 还没就绪 | 等 VM 启动后再执行 `on` |
| WiFi 漫游 | 切换 WiFi 网络 | 重新执行 `on`（/8 路由会自动适应新网段） |
| VM 内 VPN 断连 | GNB/WireGuard 掉线 | 海外流量超时，国内不受影响 |
| 8.8.8.8 不通 | bridge100 的 permanent ARP 条目 | 用 8.8.4.4 或 1.1.1.1 替代测试 |
| 权限问题 | vmnet 需要 root 或 socket_vmnet | `sudo bash start.sh` 或安装 socket_vmnet |

**紧急回退（任何情况下）：**

```bash
# 一条命令恢复 macOS 直连
sudo route -n change default $(ipconfig getoption en0 router)
```

---

## 9. 与替代方案的对比

| 方案 | 分流能力 | 透明度 | 复杂度 | 适用场景 |
|------|---------|--------|--------|---------|
| **本方案（QEMU VM）** | nft set，完整 | 完全透明 | 中 | 笔记本，需要全局分流 |
| 系统代理（HTTP/SOCKS） | 应用层 | 只有支持代理的应用 | 低 | 桌面应用 |
| Clash/sing-box TUN | TUN 接口 | 较好 | 中 | macOS 本机 |
| 固定路由器（ImmortalWrt） | nft set，完整 | 完全透明 | 低 | 固定场所 |
| WireGuard 全局 VPN | 无分流 | 完全透明 | 低 | 简单翻墙 |

**本方案的独特优势：**
- 笔记本随身携带，不依赖固定路由器
- VM 内的 nft set 分流能力完整，不受 macOS 限制
- vmnet-host 管理口始终可达，即使分流出错也能 SSH 进 VM 修复
- VM 可以做 snapshot，配置坏了直接回滚

---

## 10. 脚本参考

### gateway-mode.sh

```bash
#!/usr/bin/env bash
# 开启网关模式
bash debug/gateway-mode.sh on

# 关闭网关模式
bash debug/gateway-mode.sh off

# 测试连通性
bash debug/gateway-mode.sh check

# 查看状态
bash debug/gateway-mode.sh status
```

### start.sh（QEMU 启动）

```bash
# 启动 VM
bash debug/start.sh

# 前台运行（调试用）
bash debug/start.sh -fg

# 停止 VM
bash debug/stop.sh
```

---

## 11. macOS 网络能力总结

| 能力 | Linux | macOS | 说明 |
|------|-------|-------|------|
| 策略路由 | ✅ ip rule + fwmark | ❌ | macOS 只有单一路由表 |
| nft set / ipset | ✅ | ❌ | 无法在内核层面做 IP 集合匹配 |
| 透明桥接 | ✅ bridge + TAP | 部分 vmnet | Wi-Fi 下只能用 vmnet 代理 |
| 自定义路由优先级 | ✅ metric | 有限 | 克隆路由无法被覆盖 |
| pf 功能 | ✅ nftables | 2003 版 pf | 无 route-to，无策略路由 |
| 网络配置统一性 | ✅ ip 命令 | 碎片化 | route/ifconfig/networksetup 各自为政 |
| VPN 接口控制 | ✅ tun/tap | 有限 | 需要特殊 entitlement |

**结论：** macOS 在网络层面是一个"够用但不可编程"的系统。对于简单的上网、代理、VPN 客户端，它完全胜任。但对于需要内核级流量控制的场景（策略路由、分流、透明代理），macOS 的能力远不如 Linux。

本方案的核心思路是：**把 macOS 做不了的事，交给一个随身携带的 Linux VM 来做。**

---

## 附录 A：vmnet.framework 技术细节

### A.1 模式对比

| 模式 | 行为 | VM 获得的 IP | 适用场景 |
|------|------|-------------|---------|
| vmnet-shared | macOS 做 NAT | 192.168.64.x（私有） | 开发调试，VM 不需要直连物理网络 |
| vmnet-host | 仅与 macOS 通信 | 192.168.101.x（指定） | 管理口，始终可用 |
| vmnet-bridged | 代理桥接到物理网络 | 192.168.10.x（从路由器 DHCP） | VM 需要直连物理网络 |

### A.2 Wi-Fi 桥接的限制

Linux bridge + TAP 在 Wi-Fi 下失败的原因：

1. 802.11 协议要求每个 MAC 地址必须与 AP 关联认证
2. bridge 透传的是 VM 的 MAC 地址，AP 不认识这个 MAC
3. AP 会丢弃未关联 MAC 的帧

vmnet.framework 的解决方案：

1. 拦截 VM 的 ARP 请求，以 macOS 身份代理
2. 重写以太网帧的源 MAC 为 macOS 的 MAC
3. 路由器只看到 macOS 的 MAC，Wi-Fi 协议合规
4. DHCP 请求也以 macOS 身份转发

这使得 VM 在 Wi-Fi 环境下也能获得真实的物理网络 IP，代价是增加了一层代理开销（延迟 +<1ms）。

### A.3 socket_vmnet

vmnet 操作需要 `com.apple.vm.networking` entitlement 或 root 权限。推荐使用 socket_vmnet：

```bash
brew install socket_vmnet
sudo /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet_client setup
```

socket_vmnet 作为特权 helper 运行，QEMU 以普通用户权限运行，通过 socket 与 socket_vmnet 通信。避免了整个 QEMU 进程跑在 root 下的安全风险。
