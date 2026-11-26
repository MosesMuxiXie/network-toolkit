# 并行网络工具箱

两个本机网络工具，互不依赖，可单独开、单独关。提供 **Tauri 桌面版**（Windows / macOS）与原来的 PowerShell 脚本版。

| 工具 | 解决什么 | 管理员 |
| --- | --- | --- |
| **双链路并行** | 两条出口不同的网卡按连接分流，多线程下载叠加带宽 | 不需要 |
| **Steam 社区直连** | SNI 被墙时仍能打开 Steam 社区 / 市场 / 创意工坊 | 需要 |

两者都**不装驱动、不建虚拟网卡、不改系统路由**。

---

## 桌面版（推荐）

原生窗口，Windows 与 macOS 同一套界面。

从 [Releases](https://github.com/rainy-rain/parallel-network-adaptors/releases) 下载对应平台的安装包：

| 平台 | 文件 |
| --- | --- |
| Windows 10/11 x64 | `ParallelNetworkToolkit_*_x64-setup.exe`（NSIS）或 `.msi` |
| macOS 11+ Apple Silicon | `ParallelNetworkToolkit_*_aarch64.dmg` |
| macOS 11+ Intel | `ParallelNetworkToolkit_*_x64.dmg` |

安装包自带运行所需的脚本，首次启动会把它们释放到应用数据目录；`caddy` 二进制由构建时打进包内（Windows 为 `caddy.exe`，macOS 为 `caddy`）。

自己编译：

```bash
cd desktop
pnpm install
node node_modules/@tauri-apps/cli/tauri.js icon icon-source.png   # 仅首次
pnpm tauri build
```

产物在 `desktop/src-tauri/target/release/bundle/`。

**macOS 首次打开**：未签名/未公证的包会被 Gatekeeper 拦下，右键 →「打开」，或

```bash
xattr -dr com.apple.quarantine /Applications/ParallelNetworkToolkit.app
```

桌面版的「Steam 社区直连」在 macOS 上用的是 `SteamProxy.sh`：hosts 写入、根证书导入（`security add-trusted-cert`）、launchd 开机自启，逻辑与 Windows 版一一对应。

---

## 脚本版（Windows）

适合不想装应用的场合，全部是纯 PowerShell，可直接读改。

### 安装

```powershell
powershell -ExecutionPolicy Bypass -File .\installer\install.ps1
```

会做四件事：

1. 复制整个工具箱到 `%LOCALAPPDATA%\ParallelNetworkToolkit`
2. 准备 `caddy.exe`（仓库里有就复制，没有就从 caddyserver.com 下载）
3. 在桌面和开始菜单建「并行网络工具箱」快捷方式
4. 把卸载脚本一并放进安装目录

加 `-StartNow` 可在装完后立即开启 Steam 社区反代。

装完双击桌面「并行网络工具箱」，两个工具二选一。

卸载：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ParallelNetworkToolkit\installer\uninstall.ps1"
```

---

## 界面说明（每个按钮是干什么的）

窗口分三个标签页，对应三个互相独立的工具。**鼠标悬停在任何按钮上也会显示同一段说明。**

### 顶栏

| 控件 | 作用 |
|---|---|
| 平台标签 | 显示当前识别到的系统（Windows / macOS）；决定走 `.ps1` 还是 `.sh` / `.py` |
| **刷新状态** | 重新读三项状态。每次都要起一次 PowerShell，约 1 秒 |
| 状态栏（底部） | 显示当前正在做什么、上一次操作的结果 |

### 标签页一：双链路并行

把多条网卡同时在一条本地 SOCKS5 端口上并行出口。**不需要管理员，不改路由，不装驱动。**

| 控件 | 作用 |
|---|---|
| **重新检测链路** | 枚举网卡，只保留「已启用 + 有 IPv4 + 有默认网关」的，标出物理 / 虚拟与出口归属（校园网 / 手机蜂窝 / ICS 共享…） |
| **链路自检** | 让每条链路各下载 500 KB，验证它**真的能出网**，并报出速度。链路表里有不代表能上网 |
| **启动分流** | 在 `127.0.0.1:1080` 起 SOCKS5。新连接按网卡轮询分发 |
| **停止分流** | 停掉并释放 1080 |
| **打开分流日志** | 打开分流器自己的日志文件 |
| **用代理重启选中进程** | 给选中的程序设 `HTTP_PROXY` / `ALL_PROXY` 后重启它 —— 只有走系统代理的程序才吃得到这套分流 |
| **线程数** | 分片下载的并发线程数，默认 16。线程越多越容易吃满多条链路，小文件收益有限 |
| **分片（MB）** | 每个分片多大，默认 4 MB。文件要被切成这么多份才能并行下载 |
| **多线程下载测试** | 按上面两个参数跑一次真实下载，验证带宽是否真的叠加 |

**这个工具解决什么**：单条 TCP 只能走一条网卡，所以一条连接再快也压不满两条线。只有多线程 / 分片这类并发场景，才能把两条线的带宽加在一起。

### 标签页二：Steam 社区直连

社区和商店被按 SNI 拦掉时，在本机终结 TLS 再转发到 Valve 白名单域名（域前置）。

| 控件 | 作用 |
|---|---|
| **开启** | 起 Caddy（监听 443）→ 装本地根证书 → 写 hosts → 验证一次 → 注册开机自启。**需要管理员** |
| **关闭** | 停 Caddy → 清 hosts → 删自启任务，**保留根证书**（下次开启更快） |
| **自检** | 四项状态（Caddy / hosts / 证书 / 443）+ SNI 是否还被封 + 反代能否连通 + 真的用浏览器拉一次首页 |
| **打开日志** | Caddy 访问日志（JSON，一次请求一行，含状态码、耗时、大小、UA） |
| 四行状态 | Caddy 进程 / hosts 是否写入 / 根证书是否已装 / 443 是否在听 |

**这个工具解决什么**：浏览器和 Steam 客户端把 SNI 写死在程序里，改不了。所以只能在本机做 TLS 终结 —— 客户端以为自己在跟 `steamcommunity.com` 说话，实际是 Caddy；Caddy 再以 `steampowered.com` 的身份去连 Akamai，回程原样交回。

### 标签页三：CM 直连中继

Steam 底部显示 NO CONNECTION、好友与聊天掉线 —— 这是 CM 连不上，与商店/社区无关。

| 控件 | 作用 |
|---|---|
| **开启 CM 直连** | 起中继（24 个 DC × 22 端口 = **528 个本地监听**）→ 写 hosts → 刷 DNS 缓存。**约 17 秒**；非管理员运行时会弹一次 **UAC** 授权（只写 hosts 那一步提权）。完成后要**彻底退出 Steam 再启动**（托盘右键退出，不是关窗口） |
| **关闭 CM 直连** | 停中继 → 从 hosts 删掉 CM 那一段 → 完全恢复原状 |
| **测速** | 对 4 个 DC 各做一次 TLS 握手，验证分片是否真的绕过了 DPI，报出握手耗时 |
| **打开日志** | 中继日志，每次连接一行（accept / tunnel up / 对端 IP） |
| 四行状态 | 是否在跑 / 监听数 / DC 数 / hosts 是否写入 / 中继进程 PID |

**这个工具解决什么**：这台网络对 CM 的 TLS 握手做 IP 级阻断（TCP 通、明文通、ClientHello 一发出就 RST），但 **DPI 不做 TCP 流重组**。所以把首包切成 20 字节一段、间隔 3 ms 写出去就能过。**全程走本地回环，不经过任何代理节点。**

### 标签页四：P2P 直连

把两台不同网络里的设备接成**同一个局域网** —— 文件共享、Minecraft 局域网房间这类需要「互相看得见」的场景才能用。三条通道互补，哪条通走哪条。

| 通道 | 成本 | 能干什么 | 不能干什么 |
|---|---|---|---|
| **A · UDP 打洞** | ¥0 | 两端直连，流量不经过任何服务器；延迟就是两端之间的 RTT | 两端**都在校园网内**时打不通（网关代理 ARP + NAT 不环回） |
| **B · Cloudflare 中继** | ¥0（Workers 免费额度） | 补上 A 打不通的那一半：两端同网也能通，且绕开境外 DERP 的 300ms | 要自己部署一个 Worker（见下） |
| **C · 免费 TCP 隧道** | ¥0 | 把本机一个 TCP 端口暴露到公网，别人直接连（Minecraft 25565） | 只解决单端口；不做局域网发现；拿不到 445 这类特权端口 |

**A 通道怎么用**

1. 两端都点「启动」。卡片会从`未启用`→`等待对端`，并显示**邀请码**（= `base64(公网IP:端口|本地端口)`）。
2. 一端点「复制邀请码」发给对方；对方把邀请码解出来的 `IP:端口` 填到**对端**一栏，再点「启动」。
3. 命中后两端都变成`已连通`，卡片上能看到 RTT 与实际收发字节数。
4. 要走 UDP 应用（基岩版 19132 之类），把**本地 UDP**和**对端 UDP**都填上，才会开端口转发。

对称 NAT 下对方的真实端口会在预测值附近漂移，所以「喷射」默认 64：启动后向 `端口±64` 全扫一遍，命中即停。这个网络实测端口**单调递增**（步长 15–40），所以盲扫命中率很高。

**B 通道怎么用**

1. 点「登录 Cloudflare」——本机没装 wrangler 会先自动 `npm i -g wrangler`，然后拉起浏览器走 OAuth 授权（`wrangler login` 自己打开授权页）。
2. 授权完成后点「一键部署」：把 `p2p-worker.js` + `wrangler.toml` 复制到脚本目录下的 `tools\relay\`，跑 `wrangler deploy`，成功后**自动把 `https://p2p-relay.<子域>.workers.dev` 填进 Worker 一栏**。
3. 两端填**同一个房间名**（留空则自动生成，记得把生成的那个发给对方），各自「启动」。

没连账号时直接点「启动」也行：会先发现未登录，自动打开浏览器授权，并把「还没连上 Cloudflare 账号」写进状态卡，而不是丢一句看不懂的连接失败。

服务端只做房间内转发，看不到内容；同房间的所有连接互为对端。

**C 通道怎么用**

选服务商、填本地端口、点「启动」。**bore 免注册、单文件，没装会自动下载配好**——`https://github.com/ekzhang/bore/releases` 的 660 KB 压缩包直接解出 `bore.exe` 放到脚本目录的 `tools\` 下，随后立即启动并在卡片上显示 `bore.pub:端口`。也可以先点「安装 bore」只装不启动。

cpolar / ngrok / cloudflared / frpc 都要注册或登录，装不了就是装不了，界面会写明原因，不假装在忙。

**A 通道实测（当前校园网）**

| 项目 | 值 |
|---|---|
| NAT 类型 | 对称（同一 socket 对 5 个 STUN 拿到不同映射端口） |
| 端口分配 | 单调递增，20 次连续分配步长 15–40（均值 26.7） |
| 映射存活 | >90 秒（同一 socket 同一目的 90 秒内不变） |
| NAT 环回 | 不支持（发给自己公网映射无回应） |
| 跨 socket 注入 | 不成立（两端互相打对方映射收不到） |

结论：**对外打洞可行，校园网内部两台设备之间打不通** —— 后者只能走 B。

## 工具一：双链路并行

把 Windows 上两条**互相独立**的链路（比如 校园网 Wi-Fi + 手机 USB 共享）按连接分流，让支持代理的软件同时使用两条线路。

> 它做的是**连接级分流**，不是带宽聚合：一条 TCP 连接只能走一条链路，只有多连接下载（多线程 / 分片）才可能叠加。

### 原理

1. 本机起一个 SOCKS5 + HTTP CONNECT 代理（默认 `127.0.0.1:1080`）；
2. 每进来一条连接，用 Windows 的 `IP_UNICAST_IF`（socket 选项 31）**强制指定出口网卡**，再按连接轮询；
3. 因为是在 socket 层指定网卡，**不需要管理员权限、不改系统路由、不干扰 VPN / TUN**；
4. 下载器把文件切成多段 → 每段各自命中不同网卡 → 两条链路同时跑。

### 图形界面

双击 `gui\AdaptersGUI.ps1`，或从工具箱启动器进入。

- **重新检测链路**：列出所有 Up 状态、有默认网关的网卡，标出物理/虚拟与出口归属
- **链路自检**：每条链路各下载约 500 KB，看到两行 OK 才算通
- **启动 / 停止分流**：在 `127.0.0.1:1080` 起停代理
- **用代理重启选中进程**：列出有窗口的进程，双击即用代理环境重启
- **多线程下载测试**：调 `multi-fetch.ps1`，看叠加效果

命令行模式（不开窗口）：

```powershell
powershell -ExecutionPolicy Bypass -File .\gui\AdaptersGUI.ps1 -Status
powershell -ExecutionPolicy Bypass -File .\gui\AdaptersGUI.ps1 -StartQuiet
powershell -ExecutionPolicy Bypass -File .\gui\AdaptersGUI.ps1 -StopQuiet
```

### 脚本清单

| 文件 | 作用 |
| --- | --- |
| `split-proxy.ps1` | 分流代理（SOCKS5 + HTTP CONNECT），自动探测网卡；`-Probe` 自检、`-List` 查看链路 |
| `multi-fetch.ps1` | 多线程分段下载器（IDM 原理），支持 `-Proxy` |
| `dl.ps1` | 一键：自动检查并启动分流器 + 多线程下载 |
| `app-split.ps1` | 列出有窗口且联网的进程，选择后用代理环境重启它 |
| `app-split.bat` | 双击入口：先自检链路，再选择软件 |

### 环境要求

- Windows 10 / 11，PowerShell 5.1+
- 两条**物理**且**出口不同**的链路（例如 校园网 Wi-Fi + 手机 USB 共享）
- 手机必须是 **USB 共享**；「手机开 Wi-Fi 热点让电脑连」不行 —— 一块无线网卡不能同时关联两个 Wi-Fi

### 快速开始

双击 `app-split.bat` → 自动自检 → 输入编号选择要分流的软件。

命令行方式：

```powershell
# 查看当前可用链路
powershell -ExecutionPolicy Bypass -File .\split-proxy.ps1 -List

# 链路自检（每条链路下载 500 KB，通过返回 0，失败返回 1）
powershell -ExecutionPolicy Bypass -File .\split-proxy.ps1 -Probe

# 双线下载
powershell -ExecutionPolicy Bypass -File .\dl.ps1 -Url https://example.com/big.iso -Threads 16
```

自检输出示例：

```
自检目标: mirrors.tuna.tsinghua.edu.cn (101.6.15.130)，每条约 500 KB
  [主] WLAN        10.66.81.134 ... 连接  145 ms | 下载  0.51 MB/s | OK
  [副] 以太网 2     192.168.0.2  ... 连接  191 ms | 下载  0.50 MB/s | OK
自检通过
```

### 软件支持度与验证

#### 列表里的标记

| 标记 | 来源 | 含义 |
| --- | --- | --- |
| `[支持]` / `[部分]` / `[不支持]` | 内置名单 | 已人工确认过的常见软件 |
| `[支持*]` | 静态扫描 | EXE 导入了 `winhttp`/`wininet`/`libcurl`，或属于 Electron/Chromium/CEF |
| `[很可能*]` | 静态扫描 | Qt Network 程序，通常跟随系统代理 |
| `[未知*]` | 静态扫描 | 只看到 `ws2_32`，或读不到导入表（加壳/动态加载） |
| `[不支持*]` | 静态扫描 | 没有网络导入表 |

带 `*` 的只是静态推断，不代表一定能用。

#### 启动后实测（自动）

选好软件并启动后，脚本会观察 12 秒：

- 统计经过代理端口的连接峰值——有连接说明它确实走了代理；
- 同时统计两条网卡各自的峰值速率——两边都有流量才算真的双线。

```
正在观察 12 秒：确认是否真的走代理、两条链路是否都在动 ...
  实测：经代理的连接峰值 8 条 → 该软件确实走了代理
  WLAN: 峰值 212.6 Mbps
  以太网 2: 峰值 24.7 Mbps
```

也可以手动触发：`app-split.ps1 -Verify -Port 1080`。

> 当检测到 DNS 返回 `198.18.x`（Clash TUN 的 fake-IP）时，代理会用 DoH 重新解析真实 IP，避免连到假地址。

### 链路出口识别

`-List` 会按网段标出每张网卡的出口归属，避免把蜂窝链路当成校园网：

```
可用链路（按优先级排序）：
  [1] WLAN      10.66.81.134 网关 10.66.80.1  度量 30 物理 | 出口 校园网
  [2] 以太网 2   192.168.0.2  网关 192.168.0.1 度量 35 物理 | 出口 手机共享
```

内置网段：校园网 `10.66.80.0/21`、iPhone 蜂窝 `172.20.10.0/28`、手机共享 `192.168.42/43/49.0/24`、ICS `192.168.137.0/24`。

`multi-fetch` 不带 `-Proxy` 时会强制直连（`--noproxy *`），不会误走系统代理。

### 实测参考

同一台机器、校园网 Wi-Fi + 手机 USB 共享：

| 配置 | 速度 |
| --- | --- |
| 单走 Wi-Fi，8 线程 | 50.4 Mbps |
| 单走手机 USB，4 线程 | 30.9 Mbps |
| 两条分流，8 线程 | 59.6 Mbps |

叠加后的上限约等于两条链路之和（50 + 31 ≈ 80 Mbps），不是翻倍。

### 限制

| 限制 | 说明 |
| --- | --- |
| 单连接不会变快 | 一条 TCP 流只能走一条链路 |
| 非代理型软件用不了 | Steam、游戏启动器、Windows Update 需要 `/32` 路由或双 WAN 路由器 |
| 仅 Windows | 依赖 `IP_UNICAST_IF` |
| 只处理 TCP | UDP / QUIC 不走代理（浏览器会自动回落 TCP） |
| 手机流量计费 | 第二条链路走蜂窝网络会产生流量费用 |

`mac/` 下另有一份 macOS 实现（Python + Shell），原理相同，用 `SO_BINDTODEVICE` 替代。

---

## 工具二：Steam 社区直连

校园网 / 企业网里 `steamcommunity.com` 常被按 **SNI 字符串**阻断：TLS ClientHello 里的 Server Name 命中黑名单，连接立刻被 RST。所有依赖该域名的页面（社区、市场、创意工坊、个人资料）全部打不开。

这个工具**不依赖代理、不建虚拟网卡**，只在本机做一件事：**终结 TLS，再用 Akamai 域前置转发**。

### 原理

1. 把 `steamcommunity.com` 的 hosts 指向 `127.0.0.1`；
2. 本机 Caddy 在 443 监听，用自签根证书对浏览器出示 `steamcommunity.com` 的证书；
3. Caddy 再向上游发起**真正的 TLS**，但：
   - `SNI = steampowered.com`（未被封的 Valve 白名单域名）
   - `Host = steamcommunity.com`
4. Akamai 校验通过这张 Valve 多域名证书（一张证书覆盖 47 个 Valve 域），按 `Host` 把请求路由到社区源站，回包照原路返回。

### 为什么 SNI 再封也能用

它**从头到尾都不用 `steamcommunity.com` 作为 SNI**，所以：

| 情况 | 结果 |
| --- | --- |
| SNI 解封 | 可用，多一跳本地转发（约 +0.1s） |
| SNI 重新封 | 可用 —— 这正是它的设计目标 |
| `steampowered.com` 也被拉黑 | 才会失效，把 Caddyfile 里的上游换成 `steam.tv` 或 `steamgames.com`（同一张证书覆盖） |

### 图形界面

双击 `steam-community\SteamProxy.ps1`，或从工具箱启动器进入。

- **开启**：启动 Caddy → 装根证书 → 写 hosts → 验证 HTTP 200 → 注册开机自启
- **关闭**：停 Caddy → 清 hosts → 删自启任务（根证书保留）
- **自检**：查四项状态 → Cloudflare DoH + `--resolve` 探测 SNI 是否被封 → 测本机反代 → Edge 无头加载社区页
- **卸载**：撤销全部改动

命令行模式：

```powershell
powershell -ExecutionPolicy Bypass -File .\steam-community\SteamProxy.ps1 -Test
powershell -ExecutionPolicy Bypass -File .\steam-community\SteamProxy.ps1 -EnableQuiet
powershell -ExecutionPolicy Bypass -File .\steam-community\SteamProxy.ps1 -DisableQuiet
```

### 实测数据

```
Caddy 进程：运行中 PID 8832
443 监听：是
hosts 指向：127.0.0.1
根证书：已信任
SNI 未封：真实 IP 23.15.140.216，HTTP 200，TLS 握手成功 0.268s
本机反代：HTTP 200，耗时 0.483s
浏览器加载：DOM 174,192 字符，title=[Steam Community]
```

`access.log` 里能看到 Steam 客户端自己的请求：

```
"User-Agent": ["Mozilla/5.0 (Windows NT 10.0; Win64; x64; Valve Steam Client/default/1792618285) ..."]
"uri": "/gid/.../ajaxgetvanityandclanid/?origin=https://steamloopback.host"
"status": 200
```

即 **Steam 客户端内嵌浏览器也走通了**，不只是系统浏览器。

### 已知限制

1. **登录仍需临时开代理**：`login.steampowered.com` 的域前置被 Akamai 返回 403（它校验 SNI 与 Host 一致性）。登录时开一次代理，登录完关掉。
2. **部分 API 模块可能空白**：`api.steampowered.com` 同理。社区主页、市场、创意工坊、个人资料不受影响。
3. **443 端口独占**：本工具占用本机 443。装了 IIS 或其他 HTTPS 服务需先让出。
4. **hosts 偶被占用**：脚本已做 6 次重试（间隔 400ms），仍失败会在日志里明确报错。

---

## 工具三：Steam CM 直连（TLS 分片）

Steam 底部状态栏显示 **NO CONNECTION**，库里能看、头像能显示，但好友和聊天一直掉线。这不是商店或社区的问题，是 **CM（连接管理器）** 连不上。

### 原理

Steam 的 CM 走自己的 TCP 协议（27015–27036 端口，WebSocket 走 443），**不读系统代理**（注册表 `HKCU\Software\Valve\Steam` 的 `ProxyMode` 是空的），所以 Clash 之类设了系统代理也管不到它。

实测该网络对 CM 的处理是：**TCP 三次握手放行，ClientHello 一发出去就回 RST**。24 个 CM 域名 × 23 个端口 = 552 个组合，TLS 成功 0 个；但同一批 IP 的 80 端口明文 HTTP 是 404 正常。也就是说封的是 **TLS 握手**，不是 IP 也不是端口。

关键发现：**这台网络的 DPI 不做 TCP 流重组**，只在单个 TCP 段内匹配 ClientHello 的特征。于是把首包切开分几次发出去就能过：

| 每段字节 | 段间延迟 | 结果 |
|---|---|---|
| 1 | 30 ms | OK（TLS 1.2 握手成功）|
| 3 | 10 ms | OK |
| 10 | 5 ms | OK |
| 50 | 2 ms | OK |
| 1000（不分片）| 0 | **RST** |

所以不需要任何代理：本机起一个转发器，把 Steam 发给 CM 的字节切成 20 字节一段、间隔 3 ms 写出去，CM 回来的数据原样转发。全程走本地回环，**不经过任何境外节点**。

### 结构

- `cm-splitter.ps1` — 启停、状态、测速，并维护 hosts
- `CmSplitter.cs` — 转发器本体（`TcpListener` + 分片写 + 双向 `Pump`）
- 24 个 CM 域名指向 `127.0.0.2`–`127.0.0.25`，每个 IP 上监听 22 个端口（27015–27036），共 **528 个监听**
- hosts 里由 `# === SteamCM BEGIN ===` / `# === SteamCM END ===` 包住的那一段，关闭时整段删除

### 用法

桌面版：Steam 标签页顶部的「CM 直连中继」卡片 → **开启**。

命令行：

```powershell
# 开启（起转发器 + 写 hosts + 刷新 DNS 缓存）
powershell -ExecutionPolicy Bypass -File cm-splitter.ps1 -Action enable

# 看状态
powershell -ExecutionPolicy Bypass -File cm-splitter.ps1 -Action status

# 测速（4 个 DC）
powershell -ExecutionPolicy Bypass -File cm-splitter.ps1 -Action test

# 关闭（停转发器 + 清 hosts）
powershell -ExecutionPolicy Bypass -File cm-splitter.ps1 -Action disable
```

`status` 输出 `KEY=VALUE`：

```
CM_ENABLED=1            # 中继在跑且有监听
CM_PID=23100
CM_LISTENERS=528
CM_DC=24
CM_HOSTS=1              # hosts 里 CM 段与当前 DC 表一致
CM_HOSTS_ADMIN=1        # 当前进程是否管理员
CM_HOSTS_STALE=1        # 仅在「块在但内容过期」时出现
CM_HOSTS_ERR=...        # 仅在写入失败时出现，带失败原因
CM_HOSTS_HINT=...       # 仅在需要用户动作时出现（例如「会弹一次 UAC」）
```

前五行是稳定接口（桌面端按它渲染），后四行是给人看的原因码。

### hosts 写入要管理员权限

`hosts` 的 ACL 是 `Users: 读`、`Administrators: 完全控制`，所以**任何**用户态的写都会失败——早期版本把异常吞掉，界面只显示「hosts 未写入」，中继却在跑（`CM_LISTENERS=528`），看起来「开了但没效果」。现在：

1. 先在当前进程试写（有的机器 Users 组被额外放权）；
2. 写不进去且是桌面端 / `enable` 调用时，用 `Start-Process -Verb RunAs` 只把「写 hosts」这一步提到管理员，**中继本身仍以普通权限运行**；
3. 弹窗被点「否」按错误 1223 上报，界面状态栏和 CM 日志都会写明「hosts 未写入——CM 直连不生效」；
4. 已经是目标状态就跳过写入（幂等），不会每次开启都弹 UAC；
5. 写入前把原文件备份成脚本目录下的 `hosts.bak.yyyyMMdd-HHmmss`（保留最近 5 个），写完回读校验；只增删 `# === SteamCM BEGIN/END ===` 这一段，其它行（包括 UU 加速器写的段）逐字节保留。

### 实测

```
CM_ENABLED=1  CM_PID=23100  CM_LISTENERS=528  CM_DC=24  CM_HOSTS=1

cmp1-hkg1  403  0.414s   （含 TLS 握手）
cmp2-hkg1  403  0.400s
cmp1-sgp1  403  0.760s
```

同一条 `cmp1-hkg1:27018` 走 SOCKS5 代理要 3.47 s，分片中继 **0.41 s**，快 8 倍，而且不消耗节点流量。

Steam 侧日志确认：

```
ConnectionCompleted() (127.0.0.2:27020, WebSocket)
[Connected, 4, 7] Logging on [U:1:...]
[Logged On, 4, 7] processing complete
```

### 已知限制

- 仅 Windows。macOS 上这个卡片会提示不支持。
- 写 hosts 需要管理员：桌面端会在开启时弹一次 UAC，命令行直接跑 `-Action enable` 时若当前不是管理员，同样会弹一次。点「否」的后果是**中继在跑但 hosts 没写**，此时 `CM_HOSTS=0` + `CM_HOSTS_ERR` 会说明原因，界面状态栏也会变成「hosts 未写入——CM 直连不生效」。
- `CM_HOSTS=0` 时 `-Action test` 会全 `FAIL:000`：域名还指着真 CM，TLS 直连被 DPI 掐掉。所以「测速全失败」先看 `CM_HOSTS`，不是 DC 挂了。
- 24 个 DC 里约 18 个可用；`cmp1/2-tyo3`、`ext1/2-bom2`、`ext1/2-maa2` 是 IP 本身路由不通，不是 DPI 问题。
- 需要 528 个监听端口，防火墙弹窗要允许。
- 开过 UU 加速器后它可能改写 hosts，重新点一次「开启」即可覆盖回来。
## 目录结构

```
.
├── split-proxy.ps1          双链路分流代理
├── multi-fetch.ps1          多线程分段下载
├── dl.ps1                   一键下载
├── app-split.ps1 / .bat     进程级分流
├── mac/                     macOS 实现
├── gui/
│   ├── Launcher.ps1         工具箱启动器
│   └── AdaptersGUI.ps1      双链路并行 图形界面
├── cm-splitter.ps1        # CM 直连中继（启停 / 状态 / 测速）
├── CmSplitter.cs          # 分片转发器本体
├── steam-community/
│   ├── SteamProxy.ps1       Steam 社区直连 图形界面
│   └── Caddyfile            反代规则
└── installer/
    ├── install.ps1          安装
    └── uninstall.ps1        卸载
```

`caddy.exe`（约 51 MB）不进仓库，安装时按需下载或从本地复制。

---

## 排错

| 现象 | 位置 |
| --- | --- |
| 分流器启不来 | `%TEMP%\split-proxy.log`，或 GUI 里点「打开分流日志」 |
| 只找到一条链路 | 确认手机 USB 共享已连接且分配了 IPv4 默认网关 |
| 端口被占用 | 分流器换 `-Port`，Steam 侧检查 443 |
| Steam 页面白屏 | 看 `steam-community\access.log` 有没有对应请求 |
| 证书告警 | 确认 `LocalMachine\Root` 里有 `Caddy Local Authority` 根证书 |

---

## 许可

MIT