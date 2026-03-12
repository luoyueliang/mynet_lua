# debug — 本地 OpenWrt 调试环境

基于 QEMU 在 macOS 本地运行 OpenWrt x86 虚拟机，用于开发阶段的快速调试。

## 端口映射

| 宿主机 | 虚拟机 | 用途 |
|--------|--------|------|
| localhost:2222 | :22 | SSH |
| localhost:8080 | :80 | LuCI Web |

---

## 快速开始

### 第一步：初始化（仅需一次）

```bash
bash debug/setup.sh
```

脚本会自动：
1. 通过 Homebrew 安装 `qemu`
2. 下载 OpenWrt 23.05.5 x86/64 镜像（约 15MB）
3. 解压并扩展磁盘至 512MB

### 第二步：启动虚拟机

```bash
bash debug/start.sh        # 后台运行，等待 20 秒自动就绪
# 或
bash debug/start.sh -fg    # 前台运行（可看到完整 OpenWrt 启动日志，退出: Ctrl-A X）
```

### 第三步：首次部署项目（安装 LuCI + 同步文件）

```bash
bash debug/sync.sh install
```

首次会在 OpenWrt 里安装 `luci`、`luci-lib-jsonc`、`curl`，时间稍长（需要网络）。

### 第四步：访问

- **Web**：[http://localhost:8080/cgi-bin/luci/admin/mynet](http://localhost:8080/cgi-bin/luci/admin/mynet)
- **SSH**：`ssh root@localhost -p 2222`（无密码直接登录）

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
ssh root@localhost -p 2222 "logread -f | grep -i luci"

# 查看所有系统日志
ssh root@localhost -p 2222 "logread | tail -50"

# 交互式 Lua REPL（测试单个模块）
ssh root@localhost -p 2222 "lua -i"
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
| `setup.sh` | 一次性初始化：安装 qemu、下载解压镜像 |
| `start.sh` | 启动 QEMU 虚拟机 |
| `stop.sh` | 停止 QEMU 虚拟机 |
| `sync.sh` | 同步项目文件到虚拟机 |
| `*.img` | OpenWrt 磁盘镜像（已 .gitignore，不入库）|
| `qemu.log` | QEMU 后台运行日志（已 .gitignore）|

---

## 注意事项

- OpenWrt 虚拟机每次重启后 `/tmp/` 和安装的包都会保留（ext4 持久化），但磁盘写入较慢，正常现象。
- 如果 8080 或 2222 端口被占用，修改 `start.sh` 中的 `hostfwd` 参数即可。
- Apple Silicon (M1/M2/M3) 上运行 x86 qemu 是软件模拟，速度较慢但完全可用；Intel Mac 上更快。
