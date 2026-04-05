# MyNet LuCI — 核心流程图

> 本文档使用 Mermaid 语法，可在 GitHub 页面直接渲染。

---

## 1. 安装向导流程（Wizard Flow）

首次访问或未配置时，用户通过向导完成初始化。

```mermaid
flowchart TD
    A[用户访问 /wizard] --> B{有登录凭证?}
    B -- 否 --> C[显示 Landing 页]
    C --> C1{用户选择}
    C1 -- MyNet 在线模式 --> D[跳转 /login 登录]
    C1 -- 离线模式 --> E[跳转 /guest]

    B -- 是 --> F{当前模式?}
    F -- guest --> E
    F -- mynet --> G{已有完整配置?}

    G -- 是 --> H[跳转 /node 节点页]
    G -- 否 --> I{已选 Zone?}

    I -- 否 --> J[显示 Zone 选择]
    J --> J1[加载 Zone 列表]
    J1 --> J2{只有1个 Zone?}
    J2 -- 是 --> J3[自动选择]
    J2 -- 否 --> J4[用户手动选择]
    J3 --> K
    J4 --> K

    I -- 是 --> K[显示 Node 选择]
    K --> K1[加载节点列表]
    K1 --> K2[用户点击 Use This Node]
    K2 --> K3[confirm 确认对话框]
    K3 -- 确认 --> L[生成 mynet.conf]
    L --> M[下载配置包 bundle API]
    M --> N[写入 node.conf + route.conf + address.conf + 密钥]
    N --> H

    D --> D1[输入邮箱 + 密码]
    D1 --> D2{登录成功?}
    D2 -- 是 --> D3[保存 Token + 凭证]
    D3 --> J
    D2 -- 否 --> D4[显示错误 + 重试]
```

---

## 2. 节点切换流程（Node Switch Flow）

从节点管理页或向导页切换到不同节点。

```mermaid
flowchart TD
    A[用户点击 Change Node] --> B{当前模式?}
    B -- MyNet --> C[跳转 /wizard?tab=zone]
    B -- Guest --> D[跳转 /guest]

    C --> E[选择 Zone]
    E --> F[选择新节点]
    F --> G[confirm 确认切换]
    G -- 确认 --> H[POST wizard_select_node]
    H --> I[generate_mynet_conf]
    I --> J[refresh_configs_bundle]
    J --> K{bundle API 可用?}
    K -- 是 --> L[单请求获取全部配置+密钥]
    K -- 否 --> M[fallback: 3次独立请求]
    L --> N[写入本地配置文件]
    M --> N
    N --> O[跳转 /node 节点页]

    D --> P[选择离线节点]
    P --> Q[点击 Use This Config]
    Q --> R[更新 local_node_id]
    R --> S[重新生成 mynet.conf + route.conf]
    S --> T[页面刷新]
```

---

## 3. GNB 自动安装流程（GNB Auto-Install Flow）

Settings 页面或 Dashboard 检测到 GNB 未安装时触发。

```mermaid
flowchart TD
    A[触发安装] --> B{gnb_ctl 已存在?}
    B -- 是 --> C[返回 already_ok]
    B -- 否 --> D{安装进程已运行?}
    D -- 是 --> E[返回 already_running]
    D -- 否 --> F[检测平台架构]

    F --> G[uname -m → 映射 gnb_arch]
    G --> H{架构可识别?}
    H -- 否 --> I[返回错误: 未知平台]
    H -- 是 --> J[预装依赖]
    J --> J1[bash / kmod-tun / curl-gnutls / ca-bundle]

    J1 --> K[拉取 apps.json 索引]
    K --> L[拉取 GNB manifest]
    L --> M[解析最新稳定版本]
    M --> N[选择对应架构资源包]
    N --> O[生成安装脚本]
    O --> P[后台执行: 下载 → 解压 → 安装]
    P --> Q[写入锁文件 + PID]
    Q --> R[返回 started + 版本信息]

    R --> S[前端轮询 install_status]
    S --> T{安装完成?}
    T -- 否 --> S
    T -- 是 --> U[刷新页面 → GNB 可用]
```

---

## 4. VPN 服务启动流程（Service Start Flow）

用户在 Dashboard 或 Service 页面启动 GNB VPN。

```mermaid
flowchart TD
    A[用户点击 Start VPN] --> B[POST api/vpn_start]
    B --> C["/etc/init.d/mynet start"]

    C --> D[rc.mynet init 脚本]
    D --> D1[读取 mynet.conf]
    D1 --> D2[定位 GNB 二进制]
    D2 --> D3{kmod-tun 已加载?}
    D3 -- 否 --> D4[modprobe tun]
    D3 -- 是 --> D5[启动 GNB 进程]
    D4 --> D5

    D5 --> E[GNB 绑定 TUN 接口]
    E --> F[执行 route.mynet apply]
    F --> F1[读取 route.conf]
    F1 --> F2[注入路由表项]

    F2 --> G[执行 firewall.mynet apply]
    G --> G1[配置 mynet zone]
    G1 --> G2[设置转发规则]
    G2 --> G3[firewall reload]

    G3 --> H{启动成功?}
    H -- 是 --> I[返回 success]
    H -- 否 --> J[分析错误 → 生成提示]
    J --> K[返回 error + hint]

    I --> L[前端刷新状态: ● Running]
```

---

## 5. 代理分流运行流程（Proxy Traffic Split Flow）

通过 GNB 隧道进行策略路由分流。

```mermaid
flowchart TD
    A[用户点击 Enable Proxy] --> B{GNB 正在运行?}
    B -- 否 --> C[返回错误: 先启动 GNB]
    B -- 是 --> D[保存代理参数]

    D --> D1[mode: client/server]
    D --> D2[region: domestic/overseas]
    D --> D3[dns_mode: none/intercept/redirect]

    D1 --> E[Lua route_inject]
    D2 --> E
    D3 --> E
    E --> E1[读取 route.conf 获取对端节点]
    E1 --> E2[为对端添加 GNB 数据路由]

    E2 --> F["执行 proxy.sh start"]
    F --> G[pre_start.sh hook]
    G --> H[创建 ipset 集合]
    H --> I[加载分流规则列表]
    I --> J[配置策略路由表]
    J --> K[post_start.sh hook]
    K --> L{DNS 模式}

    L -- none --> M[完成]
    L -- intercept --> N[iptables DNAT 53→本地DNS]
    L -- redirect --> O[使用指定 DNS 服务器]
    N --> M
    O --> M

    M --> P[注册防火墙 include]
    P --> Q[记录运行状态]
    Q --> R[返回 success]

    style A fill:#e8f5e9
    style C fill:#ffebee
    style R fill:#e8f5e9
```

### 代理停止流程

```mermaid
flowchart TD
    A[用户点击 Stop/Disable Proxy] --> B["执行 proxy.sh stop"]
    B --> C[stop.sh hook]
    C --> D[清除 ipset 集合]
    D --> E[移除策略路由规则]
    E --> F[Lua route_restore]
    F --> G[清除运行状态文件]
    G --> H[注销防火墙 include]
    H --> I[返回 success]
```

---

## 6. 页面导航总览（Navigation Map）

```mermaid
flowchart LR
    subgraph 菜单页面
        IDX[Dashboard<br/>/index]
        NODE[Node<br/>/node]
        SVC[Operations<br/>/service]
        PLG[Plugins<br/>/plugin]
        SET[Settings<br/>/settings]
    end

    subgraph 功能页面
        WIZ[Wizard<br/>/wizard]
        LOGIN[Login<br/>/login]
        GUEST[Guest<br/>/guest]
        PROXY[Proxy<br/>/proxy]
    end

    subgraph "兼容重定向 (旧路由)"
        ZONES[/zones] -.-> NODE
        NODES[/nodes] -.-> NODE
        STATUS[/status] -.-> IDX
        DIAG[/diagnose] -.-> SVC
        LOG[/log] -.-> SVC
        NET[/network] -.-> SVC
        GNB_MON[/gnb] -.-> SVC
        NM[/node/manager] -.-> NODE
    end

    IDX --> NODE
    NODE -- "Change Node" --> WIZ
    NODE -- "Change Node (Guest)" --> GUEST
    PLG -- "Configure" --> PROXY
    WIZ -- "Login" --> LOGIN
    WIZ -- "Offline" --> GUEST
    LOGIN -- "成功" --> WIZ
    SET -- "GNB Install" --> IDX
```

---

## 7. 认证流程（Authentication Flow）

```mermaid
sequenceDiagram
    participant U as 浏览器
    participant C as Controller
    participant A as auth.lua
    participant CR as credential.lua
    participant API as MyNet API

    U->>C: 访问受保护页面
    C->>CR: cred_m.load()
    CR-->>C: {token, refresh_token, expire_at}

    alt Token 有效
        C->>C: 继续处理请求
    else Token 过期
        C->>A: auth.ensure_valid()
        A->>API: POST /auth/refresh {refresh_token}
        alt 刷新成功
            API-->>A: {new_token, new_expire}
            A->>CR: 保存新凭证
            A-->>C: 凭证对象
        else 刷新失败
            A->>API: POST /auth/login {email, password}
            alt 重登录成功
                API-->>A: {token, refresh_token}
                A->>CR: 保存凭证
                A-->>C: 凭证对象
            else 全部失败
                A-->>C: nil
                C->>U: 重定向 → /login
            end
        end
    end
```

---

## 8. 配置同步流程（Config Sync / Bundle API）

```mermaid
flowchart TD
    A[触发配置同步] --> B["调用 refresh_configs_bundle(node_id)"]
    B --> C[确保认证有效]
    C --> D[请求 Bundle API]
    D --> E{API 支持 bundle?}

    E -- 是 --> F[收到完整配置包]
    F --> G[写入 node.conf]
    F --> H[写入 route.conf]
    F --> I[写入 address.conf]
    F --> J[写入 ed25519 对端公钥]
    F --> K{包含自身密钥?}
    K -- 是 --> L[写入 private_key + public_key]
    K -- 否 --> M[跳过]

    H --> N[同步顶层 route.conf]
    N --> O{Proxy 已启用?}
    O -- 是 --> P[重新注入代理路由]
    O -- 否 --> Q[完成]

    E -- 否 --> R[Fallback: Legacy 模式]
    R --> S[GET /nodes/id/config → node.conf]
    R --> T[GET /route/node/id → route.conf]
    R --> U[GET /nodes/id/keys → 更新公钥]
    S --> Q
    T --> Q
    U --> Q

    P --> Q
    L --> Q
    M --> Q
```
