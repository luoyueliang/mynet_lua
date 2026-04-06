# Changelog

## v2.0.0 (2026-04-06)

### Features
- **安装向导** — Landing 页模式选择（MyNet 在线 / 离线模式），Zone→Node 三步引导
- **MyNet 在线模式** — 登录/Token 自动刷新 → 选区域 → 选节点 → 配置自动下载（Bundle API 优先）
- **离线/Guest 模式** — 无需 MyNet 账号：创建本地 GNB 网络 / 导入 .tar.gz 配置包 / 节点 CRUD
- **节点管理** — node.conf / route.conf / address.conf 配置查看与同步，ed25519 密钥生成/导入/上传
- **GNB 服务控制** — 启动/停止/重启，实时状态监控，GNB Peers 连接状态
- **代理分流** — 客户端/服务端模式，国内/海外路由策略，DNS 劫持，网络诊断
- **GNB 自动安装** — 平台检测 + manifest 解析 + 后台下载安装，支持 arm64/x86_64
- **运维中心** — 统一 Operations 页面（状态/网络/Peers/日志/诊断 5 个 Tab）
- **插件系统** — 插件列表入口（Proxy Traffic Split + Remote Monitoring 预留）
- **系统诊断** — 依赖检查、10 项配置校验 + 自动修复、防火墙管理
- **完整中文化** — 380+ 条 PO 翻译，LuCI 标准 i18n
- **安全加固** — API 频率限制、参数校验（防注入）、敏感文件 0600 权限

### Architecture
- 12 个 Model 模块 + 50+ API 端点 + 9 个活跃页面
- Bundle API 配置同步（单请求获取全部配置+密钥），自动 fallback 到 legacy 模式
- GitHub Actions CI/CD — push tag 自动构建 ipk 并发布 GitHub Release

### Documentation
- 8 个 Mermaid 流程图（向导/切换/安装/启动/代理/导航/认证/同步）
- 完整架构设计文档（模块职责/数据流/安全设计/运行时路径）

### i18n
- 完整 i18n 覆盖：463 条翻译（JS + 内联模板字符串）
- 新增 `_i18n_js.htm` 翻译桥接（静态 JS 文件 i18n 支持）
