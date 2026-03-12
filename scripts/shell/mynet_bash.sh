#!/bin/bash

# 初始化环境
echo "正在初始化环境..."

# 检查是否为OpenWrt系统
if [ ! -f "/etc/openwrt_release" ]; then
    echo "错误：此脚本仅支持OpenWrt系统"
    exit 1
fi

# 时间同步方法（使用阿里云NTP服务器）
configure_ntp() {
    echo "==============================="
    echo "配置时间同步"
    echo "将执行以下操作："
    echo "1. 配置使用阿里云NTP服务器"
    echo "2. 立即同步系统时间"
    echo "3. 设置定时同步任务"
    echo -n "是否配置时间同步？(默认Y) [Y/n] "
    read -r confirm
    confirm=${confirm:-Y}
    
    if [[ "$confirm" != "Y" && "$confirm" != "y" ]]; then
        echo "跳过时间同步配置"
        return 0
    fi
    
    # 检查ntpd服务是否安装
    if ! command -v ntpd >/dev/null 2>&1; then
        echo "安装NTP服务..."
        opkg update
        opkg install ntpd
        if [ $? -ne 0 ]; then
            echo "警告：安装NTP服务失败，将跳过时间同步配置"
            return 1
        fi
    fi
    
    # 配置NTP服务器，使用uci命令保留其他设置
    echo "配置阿里云NTP服务器..."
    
    # 设置系统时区（仅当未设置时）
    if ! uci show system.@system[0].timezone | grep -q "CST-8"; then
        echo "设置时区为中国标准时间..."
        uci set system.@system[0].timezone='CST-8'
        uci set system.@system[0].zonename='Asia/Shanghai'
    fi
    
    # 配置NTP
    uci set system.ntp=timeserver
    uci set system.ntp.enabled='1'
    uci set system.ntp.enable_server='0'
    
    # 清除现有服务器并添加阿里云NTP服务器
    uci delete system.ntp.server >/dev/null 2>&1 
    uci add_list system.ntp.server='ntp.aliyun.com'
    uci add_list system.ntp.server='ntp1.aliyun.com'
    uci add_list system.ntp.server='ntp2.aliyun.com'
    uci add_list system.ntp.server='ntp3.aliyun.com'
    
    # 提交更改
    uci commit system
    
    # 立即同步时间
    echo "立即同步系统时间..."
    /etc/init.d/sysntpd restart
    
    # 等待几秒让NTP同步
    echo "等待时间同步..."
    sleep 3
    
    # 显示当前时间
    current_time=$(date "+%Y-%m-%d %H:%M:%S")
    echo "当前系统时间：$current_time"
    
    # 设置每日定时同步，使用UCI配置而非直接编辑crontab
    echo "配置定时同步..."
    if ! grep -q "/usr/sbin/ntpd -n -q" /etc/crontabs/root 2>/dev/null; then
        # 检查是否存在crontab服务
        if [ ! -f /etc/init.d/cron ]; then
            echo "安装cron服务..."
            opkg update
            opkg install cron
        fi
        
        # 添加到crontab
        echo "配置每天凌晨4点自动同步..."
        echo "0 4 * * * /usr/sbin/ntpd -n -q -p ntp.aliyun.com >/dev/null 2>&1" >> /etc/crontabs/root
        /etc/init.d/cron restart
    fi
    
    echo "时间同步配置完成"
}
# 先进行时间同步
configure_ntp
# 更新软件包列表并安装必要组件
echo "更新软件包列表并安装必要组件..."
opkg update
if [ $? -ne 0 ]; then
    echo "错误：无法更新软件包列表，请检查网络连接"
    exit 1
fi

# 安装必要的软件包
PACKAGES="kmod-tun luci-i18n-argon-config-zh-cn luci-app-argon-config luci-compat luci-i18n-ttyd-zh-cn luci-app-ttyd ttyd"
for pkg in $PACKAGES; do
    if ! opkg list-installed | grep -q "^$pkg "; then
        echo "正在安装 $pkg..."
        opkg install $pkg
        if [ $? -ne 0 ]; then
            echo "警告：安装 $pkg 失败"
        fi
    else
        echo "$pkg 已安装"
    fi
done

# 检查tun模块是否加载
if ! lsmod | grep -q "^tun "; then
    echo "正在加载tun模块..."
    modprobe tun
    if [ $? -ne 0 ]; then
        echo "错误：无法加载tun模块"
        exit 1
    fi
fi

#安装openclash 的方法, 用ipk安装, https://github.com/vernesong/OpenClash/releases/download/v0.46.137/luci-app-openclash_0.46.137_all.ipk
configure_openclash() {
    echo "==============================="
    echo "安装OpenClash"
    echo "将执行以下操作："
    echo "1. 下载OpenClash安装包"
    echo "2. 安装OpenClash"
    echo -n "是否要安装OpenClash？(默认Y) [Y/n] "
    read -r confirm
    confirm=${confirm:-Y}
    
    if [[ "$confirm" != "Y" && "$confirm" != "y" ]]; then
        echo "跳过安装OpenClash"
        return 0
    fi 

    #export https_proxy=http://arthur:lanyantu.com@home.luoyueliang.com:12306/
    wget -O luci-app-openclash_0.46.137_all.ipk https://github.com/vernesong/OpenClash/releases/download/v0.46.137/luci-app-openclash_0.46.137_all.ipk
    opkg install luci-app-openclash_0.46.137_all.ipk
    if [ $? -ne 0 ]; then
        echo "错误：无法安装openclash"
    else
        echo "openclash安装成功"
        rm -f luci-app-openclash_0.46.137_all.ipk
        
        # 等待OpenClash服务初始化
        echo "等待 30 秒,OpenClash服务初始化..."
        sleep 30
        
        # 检测系统使用的防火墙工具
        echo "检测系统防火墙类型..."
        if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
            echo "系统使用 nftables 防火墙"
            echo "推荐使用 Fake-IP TUN 模式以确保GNB网段(10.1.0.0/24)流量不被代理"
            
            echo -n "是否要自动配置OpenClash为Fake-IP TUN模式？(默认Y) [Y/n] "
            read -r setup_mode
            setup_mode=${setup_mode:-Y}
            
            if [[ "$setup_mode" == "Y" || "$setup_mode" == "y" ]]; then
                echo "配置OpenClash为Fake-IP TUN模式..."
                
                # 确保OpenClash配置目录存在
                mkdir -p /etc/openclash/custom
                
                # 配置OpenClash为Fake-IP TUN模式
                uci set openclash.config.enable='1'
                uci set openclash.config.enable_meta_core='1'
                uci set openclash.config.en_mode='fake-ip'
                uci set openclash.config.stack_type='system'
                uci set openclash.config.proxy_mode='rule'
                uci set openclash.config.enable_udp_proxy='1'
                uci set openclash.config.enable_tun_device='1'
                uci set openclash.config.auto_route='0'
                uci set openclash.config.ipv6_enable='0'
                uci set openclash.config.china_ip_route='0'
                
                # 配置fake-ip-filter（过滤GNB网段）
                uci delete openclash.config.fake_filter_include 2>/dev/null
                uci add_list openclash.config.fake_filter_include='*.10.1.0.0/24'
                uci add_list openclash.config.fake_filter_include='10.1.0.*'
                uci add_list openclash.config.fake_filter_include='*.lan'
                uci add_list openclash.config.fake_filter_include='*.local'
                
                # 应用设置
                uci commit openclash
                
                # 创建使用命令行重新配置的参考脚本
                cat > /root/openclash_tun_setup.sh << 'EOF'
#!/bin/sh

# OpenClash Fake-IP TUN模式配置脚本
# 用于重新配置或修复OpenClash设置

# 配置OpenClash为Fake-IP TUN模式
uci set openclash.config.enable='1'
uci set openclash.config.enable_meta_core='1'
uci set openclash.config.en_mode='fake-ip'
uci set openclash.config.stack_type='system'
uci set openclash.config.proxy_mode='rule'
uci set openclash.config.enable_udp_proxy='1'
uci set openclash.config.enable_tun_device='1'
uci set openclash.config.auto_route='0'
uci set openclash.config.ipv6_enable='0'
uci set openclash.config.china_ip_route='0'

# 配置fake-ip-filter（过滤GNB网段）
uci delete openclash.config.fake_filter_include 2>/dev/null
uci add_list openclash.config.fake_filter_include='*.10.1.0.0/24'
uci add_list openclash.config.fake_filter_include='10.1.0.*'
uci add_list openclash.config.fake_filter_include='*.lan'
uci add_list openclash.config.fake_filter_include='*.local'

# 应用设置
uci commit openclash

# 重启OpenClash服务
/etc/init.d/openclash restart

echo "OpenClash已配置为Fake-IP TUN规则模式并重启"
EOF
                chmod +x /root/openclash_tun_setup.sh
                
                echo "是否立即重启OpenClash应用新配置？(默认Y) [Y/n] "
                read -r restart_oc
                restart_oc=${restart_oc:-Y}
                
                if [[ "$restart_oc" == "Y" || "$restart_oc" == "y" ]]; then
                    echo "重启OpenClash服务..."
                    /etc/init.d/openclash restart
                    echo "OpenClash已重启并配置为Fake-IP TUN模式"
                else
                    echo "配置已保存，请稍后手动重启OpenClash: /etc/init.d/openclash restart"
                fi
                
                echo "已创建配置脚本：/root/openclash_tun_setup.sh，可随时重新应用设置"
            else
                echo "请在OpenClash Web界面手动配置为Fake-IP TUN模式"
                echo "具体步骤："
                echo "1. 访问路由器管理界面 -> 服务 -> OpenClash"
                echo "2. 模式设置 -> 运行模式：TUN模式"
                echo "3. 模式设置 -> DNS模式：fake-ip"
                echo "4. 全局设置 -> 高级设置 -> fake-ip过滤，添加：*.10.1.0.0/24 和 10.1.0.*"
            fi
        else
            echo "系统未使用nftables防火墙或无法确定防火墙类型"
            echo "OpenClash已安装，请通过Web界面进行配置"
        fi
    fi
}

# 清理临时文件的方法
clean_temp_files() {
    echo "清理临时文件..."
    rm -f "gnb_${NodeID}.tgz"
    rm -rf bin conf opengnb scripts gnb_setup.sh
}

# 配置wan_ssh 的方法
config_wan_ssh() {
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-SSH-WAN'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].dest_port='22'
    uci commit firewall
    /etc/init.d/firewall restart
}
# 配置网络接口函数
configure_interface() {
    echo "==============================="
    echo "网络接口配置"
    echo "将执行以下操作："
    echo "1. 创建 gnb_tun 接口"
    echo "2. 设置设备为 gnb_tun"
    echo "3. 禁用自动启动"
    echo -n "是否要配置网络接口？(默认Y) [Y/n] "
    read -r confirm
    confirm=${confirm:-Y}
    
    if [[ "$confirm" == "Y" || "$confirm" == "y" ]]; then
        echo "添加 gnb_tun 网络接口..."
        uci set network.gnb_tun=interface
        uci set network.gnb_tun.proto='none'
        uci set network.gnb_tun.device='gnb_tun'
        uci set network.gnb_tun.auto='0'
        uci commit network
        echo "网络接口配置完成"
    fi
}

# 防火墙配置函数
configure_firewall() {
    echo "==============================="
    echo "防火墙配置"
    echo "将执行以下操作："
    echo "1. 创建mynet防火墙区域"
    echo "2. 允许mynet与lan/wan的双向通信"
    echo "3. 保持原有lan/wan规则不变"
    echo -n "是否要配置防火墙？(默认Y) [Y/n] "
    read -r confirm
    confirm=${confirm:-Y}
    
    if [[ "$confirm" != "Y" && "$confirm" != "y" ]]; then
        echo "跳过防火墙配置"
        return 0
    fi

    # 创建mynet区域（如果不存在）
    if ! uci get firewall.mynet >/dev/null 2>&1; then
        echo "创建mynet区域..."
        uci add firewall zone > /dev/null
        uci set firewall.@zone[-1].name='mynet'
        uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='ACCEPT'
        uci add_list firewall.@zone[-1].network='gnb_tun'
        uci set firewall.@zone[-1].masq='1'
    fi

    # 配置mynet与lan的规则
    echo "配置mynet<->lan规则..."
    if ! uci get firewall.mynet_lan_forward >/dev/null 2>&1; then
        uci add firewall forwarding > /dev/null
        uci set firewall.@forwarding[-1].name='mynet_lan_forward'
        uci set firewall.@forwarding[-1].src='mynet'
        uci set firewall.@forwarding[-1].dest='lan'
    fi 

    # 配置mynet与wan的规则
    echo "配置mynet<->wan规则..."
    if ! uci get firewall.mynet_wan_forward >/dev/null 2>&1; then
        uci add firewall forwarding > /dev/null
        uci set firewall.@forwarding[-1].name='mynet_wan_forward'
        uci set firewall.@forwarding[-1].src='mynet'
        uci set firewall.@forwarding[-1].dest='wan'
    fi
    # 从lan 到 mynet 的规则
    echo "配置lan<->mynet规则..."
    if ! uci get firewall.lan_mynet_forward >/dev/null 2>&1; then
        uci add firewall forwarding > /dev/null
        uci set firewall.@forwarding[-1].name='lan_mynet_forward'
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='mynet'
    fi
    # 从wan 到 mynet 的规则
    echo "配置wan<->mynet规则..."
    if ! uci get firewall.wan_mynet_forward >/dev/null 2>&1; then
        uci add firewall forwarding > /dev/null
        uci set firewall.@forwarding[-1].name='wan_mynet_forward'
        uci set firewall.@forwarding[-1].src='wan'
        uci set firewall.@forwarding[-1].dest='mynet'
    fi
    
    # 提交配置
    uci commit firewall
    echo "防火墙配置完成，变更内容："
    uci changes firewall

    # 应用配置
    echo -n "是否立即应用防火墙配置？(默认Y) [Y/n] "
    read -r apply
    apply=${apply:-Y}
    if [[ "$apply" == "Y" || "$apply" == "y" ]]; then
        /etc/init.d/firewall reload
        echo "防火墙配置已生效"
    else
        echo "请稍后手动执行：/etc/init.d/firewall reload"
    fi
}

# 配置无线网络函数
configure_wireless() {
    echo "==============================="
    echo "无线网络配置"
    echo "将执行以下操作："
    echo "1. 检测可用无线设备"
    echo "2. 配置2.4G和5G无线网络"
    
    # 询问用户是否要配置无线网络
    echo -n "是否要配置无线网络？(默认Y) [Y/n] "
    read -r confirm
    confirm=${confirm:-Y}
    
    if [[ "$confirm" == "Y" || "$confirm" == "y" ]]; then
        # 获取用户输入的2.4G SSID
        echo -n "请输入2.4G无线网络名称（默认：MyNet）："
        read -r ssid_24g
        ssid_24g=${ssid_24g:-"MyNet"}
        
        # 获取用户输入的5G SSID
        echo -n "请输入5G无线网络名称（默认：${ssid_24g}_5G）："
        read -r ssid_5g
        ssid_5g=${ssid_5g:-"${ssid_24g}_5G"}
        
        # 获取用户输入的WiFi密码
        echo -n "请输入无线网络密码（默认：Mynet.Club）："
        read -r wifi_password
        wifi_password=${wifi_password:-"Mynet.Club"}
        
        echo "扫描无线设备..."
        
        # 检测可用radio设备
        radios=$(uci show wireless | grep '=wifi-device' | cut -d'=' -f1 | cut -d'.' -f2)
        for radio in $radios; do
            type=$(uci get wireless.$radio.type)
            band=$(uci get wireless.$radio.band 2>/dev/null || echo 'unknown')
            
            echo "检测到无线设备: $radio (类型: $type 频段: $band)"
            
            # 启用无线接口
            uci set wireless.$radio.disabled='0'
            
            # 根据频段配置SSID
            if [[ "$band" == "5g" || "$type" == "qcawifi" ]]; then
                ssid="$ssid_5g"
                echo "配置5GHz无线网络: $ssid"
            else
                ssid="$ssid_24g"
                echo "配置2.4GHz无线网络: $ssid"
            fi
            
            # 设置无线参数
            uci set wireless.default_$radio.ssid="$ssid"
            uci set wireless.default_$radio.encryption='psk2'
            uci set wireless.default_$radio.key="$wifi_password"
        done
        
        if [ -z "$radios" ]; then
            echo "未检测到无线设备，跳过无线配置"
        else
            uci commit wireless
            echo "无线配置已保存，配置信息："
            echo "2.4G SSID: $ssid_24g"
            echo "5G SSID: $ssid_5g"
            echo "密码: $wifi_password"
            echo "（配置需要重启生效）"
        fi
    fi
}

# 配置LAN IP函数
configure_lan() {
    echo "==============================="
    echo "LAN口配置"
    lan_ip="${LanNetWork%.*}.1"
    echo "将设置LAN口IP为: $lan_ip"
    echo -n "是否要配置LAN口？(默认Y) [Y/n] "
    read -r confirm
    confirm=${confirm:-Y}
    
    if [[ "$confirm" == "Y" || "$confirm" == "y" ]]; then
        uci set network.lan.ipaddr="$lan_ip"
        uci commit network
        echo "LAN口配置已保存（需要重启生效）"
    fi
}

# 配置SSH服务器监听所有接口
configure_ssh_listen_all() {
    echo "==============================="
    echo "配置SSH服务"
    echo "将执行以下操作："
    echo "1. 设置SSH(Dropbear)监听所有接口"
    echo "2. 保持原有SSH配置不变"
    echo -n "是否配置SSH监听所有接口？(默认Y) [Y/n] "
    read -r confirm
    confirm=${confirm:-Y}
    
    if [[ "$confirm" != "Y" && "$confirm" != "y" ]]; then
        echo "跳过SSH配置"
        return 0
    fi

    # 备份原始配置
    cp /etc/config/dropbear /etc/config/dropbear.bak
    
    # 修改dropbear配置，删除interface='lan'限制
    uci delete dropbear.@dropbear[0].interface
    uci commit dropbear
    
    echo "SSH配置已更新，现在将监听所有接口"
    echo -n "是否立即重启SSH服务？(默认Y) [Y/n] "
    read -r restart
    restart=${restart:-Y}
    
    if [[ "$restart" == "Y" || "$restart" == "y" ]]; then
        /etc/init.d/dropbear restart
        echo "SSH服务已重启"
    else
        echo "请稍后手动执行：/etc/init.d/dropbear restart"
    fi
}

### 主程序开始 ###

# 提示输入 NodeID
while true; do
    echo -n "请输入 NodeID（如 1134）："
    read -r NodeID

    if [[ -n "$NodeID" && "$NodeID" =~ ^[0-9]+$ ]]; then
        echo -n "您输入的 NodeID 是：${NodeID}，确认输入无误吗？(默认：Y)"
        read -r confirm
        confirm=${confirm:-y}
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            break
        else
            echo "请重新输入 NodeID。"
        fi
    else
        echo "无效输入，请输入一个有效的数字 NodeID。"
    fi
done

# 计算节点短ID
short_node_id=$((NodeID - 1000))

# 提示输入节点 IP
default_node_ip="10.1.0.${short_node_id}"
echo -n "请输入节点 IP（默认：${default_node_ip}）："
read -r NodeIP
NodeIP=${NodeIP:-$default_node_ip}

# 提示输入本地网络 IP
default_lan_network="192.168.${short_node_id}.0"
echo -n "请输入本地网络 IP（默认：${default_lan_network}）："
read -r LanNetWork
LanNetWork=${LanNetWork:-$default_lan_network}

# 提示输入安装目录，默认值为 /etc/opengnb
default_install_dir="/etc/opengnb"
echo -n "请输入安装目录（默认：${default_install_dir}）："
read -r install_dir
install_dir=${install_dir:-$default_install_dir}

# 下载配置文件
url="https://x.dsplat.com/gnb_conf/gnb_${NodeID}.tgz" 
echo "正在下载配置文件：$url"
wget --no-check-certificate "$url" -O "gnb_${NodeID}.tgz"
if [[ $? -ne 0 ]]; then
    echo "下载失败，请检查 URL 或网络连接。"
    exit 1
fi

# 解压文件
echo "解压文件 gnb_${NodeID}.tgz ..."
tar -xzf "gnb_${NodeID}.tgz"
if [[ $? -ne 0 ]]; then
    echo "解压失败，请检查文件。"
    clean_temp_files
    exit 1
fi

# 创建目标目录并拷贝文件
mkdir -p "$install_dir"
cp -r bin conf scripts "$install_dir/"
if [[ $? -ne 0 ]]; then
    echo "文件拷贝失败，请检查权限或路径。"
    clean_temp_files
    exit 1
fi

# 复制 openwrt 脚本
echo "复制 openwrt 脚本到 /etc/init.d/opengnb ..."
cp "$install_dir/scripts/openwrt" /etc/init.d/opengnb
if [[ $? -ne 0 ]]; then
    echo "脚本复制失败，请检查文件路径或权限。"
    clean_temp_files
    exit 1
fi

# 修改 openwrt 脚本中的配置路径
echo "修改 /etc/init.d/opengnb 配置路径..."
sed -i "s|CONFIG_PATH=\"/etc/opengnb/conf/NodeID\"|CONFIG_PATH=\"${install_dir}/conf/${NodeID}\"|g" /etc/init.d/opengnb
if [[ $? -ne 0 ]]; then
    echo "配置路径修改失败，请检查文件是否存在或权限。"
    clean_temp_files
    exit 1
fi

# 选择需要通信的节点
route_file="${install_dir}/conf/${NodeID}/route.conf"
security_dir="${install_dir}/conf/${NodeID}/ed25519"
echo "配置需要通信的节点..."

# 默认需要添加的节点列表
default_nodes=("1001" "1002" "1005" "1008" "${NodeID}")
selected_nodes=()

# 从route.conf中读取所有唯一的节点ID
all_nodes=()
if [[ -f "$route_file" ]]; then
    echo "扫描现有的 route.conf 文件..."
    
    # 使用cut命令提取第一列（节点ID），然后使用sort和uniq命令获取唯一的节点ID
    all_nodes=($(cut -d'|' -f1 "$route_file" | sort -n | uniq))
    
    echo "从route.conf中找到以下节点: ${all_nodes[*]}"
else
    echo "未找到现有的route.conf文件，将创建新文件。"
    touch "$route_file"
fi

echo "请选择需要保留的节点路由："

# 遍历所有节点ID，询问用户是否需要保留
for node in "${all_nodes[@]}"; do
    # 跳过当前节点
    if [[ "$node" == "$NodeID" ]]; then
        selected_nodes+=("$node")
        continue
    fi
    
    # 确定该节点是否为默认节点
    is_default=0
    for default_node in "${default_nodes[@]}"; do
        if [[ "$node" == "$default_node" ]]; then
            is_default=1
            break
        fi
    done
    
    # 设置默认选择
    if [[ $is_default -eq 1 ]]; then
        default_choice="Y"
    else
        default_choice="N"
    fi
    
    # 询问用户是否需要与该节点通信
    echo -n "是否保留节点 $node 的路由规则？(默认：$default_choice) "
    read -r choice
    choice=${choice:-$default_choice}
    
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        # 添加到已选择节点列表
        selected_nodes+=("$node")
    else
        # 如果选择不保留，删除对应的公钥文件
        public_key="${security_dir}/${node}.public"
        if [[ -f "$public_key" ]]; then
            echo "删除节点 $node 的公钥文件..."
            rm -f "$public_key"
        fi
    fi
done

# 临时文件存储新的路由
temp_route_file=$(mktemp)

# 确保本机节点在选定列表中
if [[ ! " ${selected_nodes[@]} " =~ " ${NodeID} " ]]; then
    selected_nodes+=("$NodeID")
fi

# 对选定的节点ID进行排序
sorted_selected_nodes=($(for node in "${selected_nodes[@]}"; do echo "$node"; done | sort -n))

# 按节点ID顺序添加路由
for node in "${sorted_selected_nodes[@]}"; do
    if [[ "$node" == "$NodeID" ]]; then
        # 添加本机节点路由
        echo "${NodeID}|${NodeIP}|255.255.255.0" >> "$temp_route_file"
        echo "${NodeID}|${LanNetWork}|255.255.255.0" >> "$temp_route_file"
    elif [[ "$node" == "1001" ]]; then
        # 添加1001节点路由
        echo "1001|10.1.0.1|255.255.255.0" >> "$temp_route_file"
    elif [[ "$node" == "1002" ]]; then
        # 添加1002节点路由
        echo "1002|10.1.0.2|255.255.255.0" >> "$temp_route_file"
        echo "1002|192.168.0.0|255.255.255.0" >> "$temp_route_file"
    elif [[ "$node" == "1005" ]]; then
        # 添加1005节点路由
        echo "1005|10.1.0.5|255.255.255.0" >> "$temp_route_file"
        echo "1005|10.0.0.0|255.255.255.0" >> "$temp_route_file"
    elif [[ "$node" == "1008" ]]; then
        # 添加1008节点路由
        echo "1008|10.1.0.8|255.255.255.0" >> "$temp_route_file"
        echo "1008|192.168.8.0|255.255.255.0" >> "$temp_route_file"
    else
        # 从原始route.conf提取该节点的路由
        short_id=$((node - 1000))
        echo "${node}|10.1.0.${short_id}|255.255.255.0" >> "$temp_route_file"
        
        # 如果原route.conf有该节点的其他路由，也添加进去
        if [[ -f "$route_file" ]]; then
            grep "^${node}|" "$route_file" | grep -v "10.1.0.${short_id}" >> "$temp_route_file" || true
        fi
    fi
done

# 更新 route.conf
cat "$temp_route_file" > "$route_file"
rm -f "$temp_route_file"

echo "route.conf 已更新，包含以下路由："
cat "$route_file"
echo ""

# 执行四个配置模块
configure_interface
configure_firewall
configure_wireless
configure_lan
configure_openclash
configure_ssh_listen_all

# 设置脚本权限并启用
chmod +x /etc/init.d/opengnb
/etc/init.d/opengnb enable # 设置开机启动
echo "启用并启动 openwrt 服务..."
echo "如果WAN口是10.0.0.0/8,请暂时不要启动openwrt服务"
#判断wan口是否是10.0.0.0/8, wan口是dhcp获取的ip, 使用ip命令获取
wan_ip=$(ubus call network.interface.wan status | grep \"address\" | head -n1 | awk -F'"' '{print $4}')
if echo "$wan_ip" | grep -qE '^10\.0\.0\.'; then
    echo "WAN口是10.0.0.0/8,请暂时不要启动openwrt服务"
else
    /etc/init.d/opengnb start
    if [[ $? -ne 0 ]]; then
        echo "服务启动失败，请检查配置或日志。"
    fi
fi

# 清理临时文件
clean_temp_files

# 提示操作完成
public_key_file="${install_dir}/conf/${NodeID}/security/${NodeID}.public"
echo "========================================="
echo "配置已完成！请按以下步骤操作："
echo ""
echo "1. 重要：先保存当前SSH会话"
echo "2. 执行物理重启路由器（不要用reboot命令）"
echo "3. 重启后连接新的WiFi："
echo "   - 2.4G: ${ssid_24g}"
echo "   - 5G: ${ssid_5g}"
echo "   - 密码: ${wifi_password}"
if [[ "$(uci get network.lan.ipaddr)" != "${LanNetWork%.*}.1" ]]; then
    echo "4. 使用新LAN IP访问：http://${LanNetWork%.*}.1"
fi
echo ""
echo "GNB节点信息："
echo "   NodeID: ${NodeID}"
echo "   节点IP: ${NodeIP}"
echo "   本地网段: ${LanNetWork}/24"
echo ""
echo "首次启动后请检查："
echo "   /etc/init.d/opengnb status"
echo "   logread -e opengnb"
echo "========================================="    