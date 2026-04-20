# 部署与安装指南

---

## 一、通过 ipk 安装（推荐）

在 OpenWrt 路由器上：

```bash
# 上传 ipk 到路由器
scp build/luci-app-mynet_2.1.6-1_all.ipk root@192.168.0.2:/tmp/

# SSH 登录后安装
opkg install /tmp/luci-app-mynet_2.1.6-1_all.ipk

# 清理 LuCI 缓存
rm -rf /tmp/luci-*
```

卸载：

```bash
opkg remove luci-app-mynet
```

---

## 二、手动文件部署（开发 / 快速测试）

```bash
ROUTER=root@192.168.0.2

# 控制器
scp luasrc/controller/mynet.lua \
    $ROUTER:/usr/lib/lua/luci/controller/

# 模型
ssh $ROUTER "mkdir -p /usr/lib/lua/luci/model/mynet"
scp luasrc/model/mynet/*.lua \
    $ROUTER:/usr/lib/lua/luci/model/mynet/

# 视图模板
ssh $ROUTER "mkdir -p /usr/share/luci/view/mynet"
scp luasrc/view/mynet/*.htm \
    $ROUTER:/usr/share/luci/view/mynet/

# 静态资源
ssh $ROUTER "mkdir -p /www/luci-static/resources/mynet/css \
                      /www/luci-static/resources/mynet/js"
scp htdocs/luci-static/resources/mynet/css/mynet.css \
    $ROUTER:/www/luci-static/resources/mynet/css/
scp htdocs/luci-static/resources/mynet/js/mynet.js \
    $ROUTER:/www/luci-static/resources/mynet/js/

# 代理 hooks
ssh $ROUTER "mkdir -p /etc/mynet/scripts/proxy/hooks"
scp scripts/proxy/hooks/*.sh \
    $ROUTER:/etc/mynet/scripts/proxy/hooks/

# 默认配置（不覆盖已存在的）
ssh $ROUTER "mkdir -p /etc/mynet/conf"
scp -n root/etc/mynet/conf/config.json \
    $ROUTER:/etc/mynet/conf/ 2>/dev/null || true

# 清理缓存
ssh $ROUTER "rm -rf /tmp/luci-*"
```

---

## 三、验证安装

```bash
ssh root@192.168.0.2

# 检查文件
ls /usr/lib/lua/luci/controller/mynet.lua
ls /usr/lib/lua/luci/model/mynet/
ls /usr/share/luci/view/mynet/
ls /www/luci-static/resources/mynet/

# 检查配置
cat /etc/mynet/conf/config.json
cat /etc/mynet/conf/route.conf

# 检查 LuCI 路由注册
lua -e "require('luci.controller.mynet')"
```

访问地址：

```
http://<router-ip>/cgi-bin/luci/admin/services/mynet
```

---

## 四、配置说明

默认配置文件路径：`/etc/mynet/conf/config.json`

```json
{
  "server_config": {
    "api_base_url": "https://your-server/api/v1",
    "timeout": 30
  }
}
```

也可以在 Web 界面的「设置」页面直接修改 API 服务器地址。

---

## 五、运行时文件位置

| 文件 | 路径 | 说明 |
|------|------|------|
| 配置 | `/etc/mynet/conf/config.json` | API 基础地址、超时 |
| 凭证 | `/etc/mynet/conf/credential.json` | 登录 Token（自动生成）|
| 路由 | `/etc/mynet/conf/route.conf` | 内核 OS 路由输入文件 |
| 代理 hooks | `/etc/mynet/scripts/proxy/hooks/` | 代理启停钩子脚本 |
| VPN init | `/etc/init.d/mynet` | 由 `mynet` 主程序包提供 |

---

## 六、依赖检查

```bash
opkg list-installed | grep -E "luci-base|curl|libcurl-gnutls4|luci-lib-jsonc|bash|ca-bundle|mynet"
```

如缺少依赖：

```bash
opkg update
opkg install luci-base curl libcurl-gnutls4 luci-lib-jsonc bash ca-bundle
```

---

## 七、路由与代理部署注意事项

- `/etc/mynet/conf/route.conf` 中写入的是 OS 路由，格式应为 `cidr dev <vpn_iface>`
- 代理启停最终走 Lua `proxy.start()` / `proxy.stop()`，不要在文档或脚本中再描述成直接调用 shell `proxy.sh start/stop`
- 更新 `.lua` / `.htm` 后，如页面未刷新，先清理 `/tmp/luci-*` 缓存再重试
