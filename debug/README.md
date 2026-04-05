# debug — 本地 OpenWrt 调试环境

基于 QEMU 在 macOS (Apple Silicon) 本地运行 OpenWrt ARM64 虚拟机，用于开发阶段的快速调试。

## 网络模式

使用 macOS vmnet 原生网络（需要 sudo）：

| 接口 | 设备 | 模式 | 地址 | 用途 |
|------|------|------|------|------|
| WAN | eth0 | vmnet-shared | DHCP | NAT 上网 |
| LAN | eth1 (br-lan) | vmnet-host | 192.168.101.2 | SSH/HTTP 管理 |

**直连访问**（无需端口转发）：
- **Web**：http://192.168.101.2/cgi-bin/luci/admin/services/mynet
- **SSH**：`ssh openwrt-qemu`（无密码直接登录）

---

## 快速开始

### 第一步：初始化（仅需一次）

```bash
bash debug/setup.sh
```

脚本会自动：
1. 通过 Homebrew 安装 `qemu`
2. 下载 OpenWrt 23.05.5 armsr-armv8 镜像（约 15MB）
3. 预写入网络配置和 opkg 清华源
4. 转换为 qcow2 稀疏格式并扩展至 512MB

### 第二步：启动虚拟机

```bash
bash debug/start.sh        # 后台运行（sudo，等待 20 秒就绪）
# 或
bash debug/start.sh -fg    # 前台运行（可看完整启动日志，退出: Ctrl-A X）
```

> **注意**：vmnet 需要 root 权限，启动/停止会提示输入密码。

### 第三步：首次部署项目（安装 LuCI + 同步文件）

```bash
bash debug/sync.sh install
```

首次会在 OpenWrt 里安装 `luci`、`luci-lib-jsonc`、`curl`，时间稍长（需要网络）。

### 第四步：访问

- **Web**：[http://192.168.101.2/cgi-bin/luci/admin/services/mynet](http://192.168.101.2/cgi-bin/luci/admin/services/mynet)
- **SSH**：`ssh openwrt-qemu`（无密码直接登录）

---

## 日常开发工作流

改完代码后，按需同步：

```bash
bash debug/sync.sh              # 同步全部（controller + model + view + static + config）
bash debug/sync.sh controller   # 只同步 controller/mynet.lua
bash debug/sync.sh model        # 只同步 model/*.lua
bash debug/sync.sh view         # 只同步 view/*.htm
bash debug/sync.sh static       # 只同步 CSS/JS
bash debug/sync.sh config       # 只同步 config.json
```

sync 脚本同步完会自动清理 LuCI 缓存（`rm -rf /tmp/luci-*`），刷新浏览器即可看到效果。

---

## 调试方法

```bash
# 实时查看 LuCI 日志
ssh openwrt-qemu "logread -f | grep -i luci"

# 查看所有系统日志
ssh openwrt-qemu "logread | tail -50"

# 交互式 Lua REPL（测试单个模块）
ssh openwrt-qemu "lua -i"
# 然后：
# > require("luci.model.mynet.api")

# Lua 语法检查（本地，无需虚拟机）
luac -p luasrc/controller/mynet.lua
luac -p luasrc/model/mynet/*.lua
```

---

## 停止虚拟机

```bash
bash debug/stop.sh
```

---

## 文件说明

| 文件 | 说明 |
|------|------|
| `setup.sh` | 一次性初始化：安装 qemu、下载镜像、转换 qcow2 |
| `start.sh` | 启动 QEMU 虚拟机（sudo + vmnet） |
| `stop.sh` | 停止 QEMU 虚拟机（sudo kill） |
| `fix-network.sh` | 修复 vmnet 网络配置（WAN=DHCP, LAN=192.168.101.2） |
| `sync.sh` | 同步项目文件到虚拟机 |
| `*.qcow2` | OpenWrt 磁盘镜像（已 .gitignore，不入库）|
| `qemu.log` | QEMU 后台运行日志（已 .gitignore）|

---

## SSH 配置

在 `~/.ssh/config` 中添加：

```
Host openwrt-qemu
    HostName 192.168.101.2
    User root
    StrictHostKeyChecking no
```

---

## 注意事项

- vmnet 需要 root 权限，`start.sh` 和 `stop.sh` 会使用 `sudo`。
- OpenWrt 虚拟机每次重启后安装的包都会保留（qcow2 持久化）。
- Apple Silicon 上使用 HVF 硬件加速 + vmnet 内核态网络，性能接近原生。
- 如需修改 LAN IP，编辑 `setup.sh` 中的网络配置和 `start.sh` 中的 vmnet 子网参数。
