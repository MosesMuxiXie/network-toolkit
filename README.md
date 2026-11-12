# parallel-network-adaptors

把 Windows 上两条**互相独立**的链路（比如 校园网 Wi-Fi + 手机 USB 共享）按连接分流，让支持代理的软件同时使用两条线路实现「双链路并行下载」。

> 它做的是 **连接级分流**，不是带宽聚合：一条 TCP 连接只能走一条链路，只有多连接下载（多线程 / 分片）才可能叠加。也不涉及破解任何网络认证或计费。

## 原理

1. 在本机起一个 SOCKS5 + HTTP CONNECT 代理（默认 `127.0.0.1:1080`）；
2. 每进来一条连接，用 Windows 的 `IP_UNICAST_IF`（socket 选项 31）**强制指定出口网卡**，再按连接轮询两条链路；
3. 因为是在 socket 层指定网卡，**不需要管理员权限、不改系统路由、也不干扰 VPN / TUN**；
4. 下载器把文件切成多段 → 每段各自命中不同网卡 → 两条链路同时跑。

## 组成

| 文件 | 作用 |
| --- | --- |
| `split-proxy.ps1` | 分流代理（SOCKS5 + HTTP CONNECT），自动探测网卡；`-Probe` 自检、`-List` 查看链路、`-SelfTest` 测出口 |
| `multi-fetch.ps1` | 多线程分段下载器（IDM 原理），支持 `-Proxy` |
| `dl.ps1` | 一键：自动检查并启动分流器 + 多线程下载 |
| `app-split.ps1` | 列出有窗口且联网的进程，选择后用代理环境重启它 |
| `app-split.bat` | 双击入口：先自检链路，再选择软件 |

## 环境要求

- Windows 10 / 11，PowerShell 5.1+
- 两条**物理**且**出口不同**的链路（例如 校园网 Wi-Fi + 手机 USB 共享）
- 手机必须是 **USB 共享**；「手机开 Wi-Fi 热点让电脑连」不行——一块无线网卡不能同时关联两个 Wi-Fi
- 不需要管理员权限（只有给 Steam 这类不认代理的软件加 `/32` 路由时才需要）

## 快速开始

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

## 软件支持度

`app-split` 在列出进程时会同时标注这个软件能不能用本方式提速：

| 标记 | 含义 | 典型软件 |
| --- | --- | --- |
| `[支持]` | 认代理 + 可多连接，能吃到双线 | Chrome / Edge / Firefox、curl、aria2、IDM、qBittorrent、Electron 应用 |
| `[部分]` | 看版本或只认系统代理，需实测 | 微信、QQ、迅雷、百度网盘、钉钉 |
| `[不支持]` | 不认代理，需 `/32` 路由或双 WAN | Steam、Epic、战网、UU 加速器、游戏启动器、msiexec |
| `[未知]` | 不在名单里，多半不认代理 | 大多数安装包和临时程序 |

选中 `[不支持]` 或 `[未知]` 的软件时会先给出提示，确认后才会启动。
## 实测参考

同一台机器、校园网 Wi-Fi + 手机 USB 共享：

| 配置 | 速度 |
| --- | --- |
| 单走 Wi-Fi，8 线程 | 50.4 Mbps |
| 单走手机 USB，4 线程 | 30.9 Mbps |
| 两条分流，8 线程 | 59.6 Mbps |

叠加后的上限约等于两条链路之和（50 + 31 ≈ 80 Mbps），不是翻倍。

## 限制

| 限制 | 说明 |
| --- | --- |
| 单连接不会变快 | 一条 TCP 流只能走一条链路 |
| 非代理型软件用不了 | Steam、游戏启动器、Windows Update 需要 `/32` 路由或双 WAN 路由器 |
| 仅 Windows | 依赖 `IP_UNICAST_IF` |
| 只处理 TCP | UDP / QUIC 不走代理（浏览器会自动回落 TCP） |
| 手机流量计费 | 第二条链路走蜂窝网络会产生流量费用 |

## 排错

- 日志：`%TEMP%\split-proxy.log`
- 端口被占用：换 `-Port`
- 只找到一条链路：确认手机 USB 共享已连接，且它分配了 IPv4 默认网关

## 许可

MIT
