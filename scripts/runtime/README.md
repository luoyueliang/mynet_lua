# MyNet OpenWrt Runtime

本目录是 MyNet 在 OpenWrt 上的运行时脚本源码，不再做平台分层。

## 目录结构

```
scripts/runtime/
├── rc.mynet
├── route.mynet
├── firewall.mynet
├── modules/
└── docs/
```

## 部署后的系统结构

```
/etc/init.d/mynet
/etc/mynet/scripts/route.mynet
/etc/mynet/scripts/firewall.mynet
```

这些源码由 Makefile、release workflow 和 debug/sync.sh 复制到运行时路径。

## 📋 完整工作流程

### 阶段一：环境准备
1. **系统检查**: 检测OpenWrt版本和必要组件
2. **路径检测**: 自动检测MyNet二进制文件位置
3. **配置验证**: 验证现有配置文件

### 阶段二：服务部署  
1. **服务脚本安装**: 复制`rc.mynet`到`/etc/init.d/mynet`
2. **权限设置**: 设置执行权限
3. **服务注册**: 启用自启动服务

### 阶段三：网络配置
1. **脚本部署**: 
   - `firewall.mynet` → `/etc/mynet/script/firewall.mynet`
   - `route.sh` → `/etc/mynet/script/route.sh`
2. **配置生成**:
   - 主配置 → `/etc/mynet/conf/mynet.conf`
   - 路由配置 → `/etc/mynet/conf/route.conf`
3. **模块化调用**: 服务脚本动态调用防火墙和路由模块

### 阶段四：服务启动
1. **服务启动**: 启动MyNet服务
2. **状态检查**: 验证服务运行状态
3. **网络测试**: 验证网络连通性

## 🔧 高级配置

### 手动网关配置
```bash
# 使用简化版网关配置脚本
./route_gw_simple.sh --interactive

# 干运行模式（测试配置）
./route_gw_simple.sh --dry-run
```

### 路由管理
```bash
# 使用部署后的路由脚本
/etc/mynet/script/route.sh --config /etc/mynet/conf/route.conf apply

# 查看路由状态
/etc/mynet/script/route.sh --status
```

### 防火墙管理
```bash
# 手动配置防火墙
/etc/mynet/script/firewall.mynet start --vpn-type gnb --router-mode bypass

# 停止防火墙配置
/etc/mynet/script/firewall.mynet stop
```

## 📝 配置文件

### 主配置文件
```bash
# /etc/mynet/conf/mynet.conf
VPN_TYPE="gnb"                    # VPN类型
ROUTER_MODE="bypass"              # 路由模式
VPN_INTERFACE="gnb_tun0"         # VPN接口名称
NODE_ID="1234567890123456"       # 节点ID
```

### 路由配置格式
```bash
# /etc/mynet/conf/route.conf
# 格式: nodeId|ipAddress|netmask
1234567890123456|192.168.1.0|255.255.255.0
9876543210987654|10.0.0.0|255.0.0.0
```

### 模板文件位置
- 部署前: `templates/` 目录
- 部署后: `/etc/mynet/conf/` 目录

## 🛠️ 故障排除

### 常见问题
1. **服务无法启动**: 检查MyNet二进制文件路径
2. **网络不通**: 验证防火墙和路由配置
3. **权限问题**: 确保以root权限运行

### 调试模式
```bash
# 启用详细日志
./deploy-service.sh --verbose

# 检查服务状态  
service mynet status
```

## 📚 详细文档

- [技术文档索引](docs/INDEX.md) - 完整技术文档导航
- [改进总结](docs/IMPROVEMENT_SUMMARY.md) - 最新功能和改进
- [OpenWrt网关指南](docs/openwrt_gw.md) - 网关配置详细说明

## ⚡ 特性

- ✅ **无人值守部署**: 支持`--auto-yes`和`--force`参数
- ✅ **智能路径检测**: 自动发现MyNet安装位置  
- ✅ **GNB兼容**: 支持GNB路由配置格式
- ✅ **防火墙集成**: 自动配置OpenWrt防火墙规则
- ✅ **服务管理**: 完整的服务生命周期管理
- ✅ **配置模板**: 提供标准配置模板

## 🔗 相关工具

- **route.sh**: 路由规则处理（从上级目录复制）
- **rc.mynet**: OpenWrt标准服务脚本
- **firewall.mynet**: 防火墙规则文件  
- **route_gw_simple.sh**: 手动网关配置工具

## 📋 依赖要求

- OpenWrt 系统
- MyNet (GNB/WireGuard) 已安装
- root权限或sudo访问
- 基本网络工具 (ip, iptables等)

## 💡 使用建议

1. **首次部署**: 使用`./deploy-service.sh --auto-yes`
2. **配置调整**: 修改`templates/`下的模板文件
3. **手动调试**: 使用`route_gw_simple.sh`进行手动配置
4. **故障排查**: 查看`docs/`目录下的详细文档

---

**注意**: 部署前请备份重要配置文件，建议先在测试环境中验证。