# 部署与安装指南

---

## 一、通过 ipk 安装（推荐）

在 OpenWrt 路由器上：

```bash
# 上传 ipk 到路由器
scp luci-app-mynet_1.0.0-1_all.ipk root@192.168.1.1:/tmp/

# SSH 登录后安装
opkg install /tmp/luci-app-mynet_1.0.0-1_all.ipk

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
ROUTER=root@192.168.1.1

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
ssh root@192.168.1.1

# 检查文件
ls /usr/lib/lua/luci/controller/mynet.lua
ls /usr/lib/lua/luci/model/mynet/
ls /usr/share/luci/view/mynet/
ls /www/luci-static/resources/mynet/

# 检查配置
cat /etc/mynet/conf/config.json

# 检查 LuCI 路由注册
lua -e "require('luci.controller.mynet')"
```

访问地址：

```
http://<router-ip>/cgi-bin/luci/admin/mynet
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
| VPN init | `/etc/init.d/mynet` | 由 `mynet` 主程序包提供 |

---

## 六、依赖检查

```bash
opkg list-installed | grep -E "luci-base|curl|luci-lib-jsonc|mynet"
```

如缺少依赖：

```bash
opkg update
opkg install luci-base curl luci-lib-jsonc
```
