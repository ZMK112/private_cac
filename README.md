<div align="center">

# cac — Claude Code Cloak

**Claude Code 小雨伞** — 给 Claude Code 包一层隐私保护。无感运行，零侵入。

**[中文](#中文) | [English](#english)**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey.svg)]()

</div>

---

<a id="中文"></a>

## 中文

> **[Switch to English](#english)**

### 简介

Claude Code 运行时会读取设备标识符（硬件 UUID、MAC、主机名等）。**cac** 通过 wrapper 机制拦截所有 `claude` 调用，提供：

- **隐私隔离** — 每个配置拥有独立的设备指纹
- **进程级代理** — 直连远端代理，无需本地代理工具
- **遥测阻断** — 多层 DNS + 环境变量 + fetch 拦截

### 特性

| 特性 | 实现方式 |
|:---|:---|
| 硬件 UUID 隔离 | macOS `ioreg` / Linux `machine-id` / Windows `wmic`+`reg` shim |
| 主机名 / MAC 隔离 | Shell shim + Node.js `os.hostname()` / `os.networkInterfaces()` hook |
| Node.js 指纹钩子 | `fingerprint-hook.js` 通过 `NODE_OPTIONS --require` 注入 |
| 遥测阻断 | DNS guard + 12 层环境变量 + fetch 拦截 + HOSTALIASES |
| 健康检查 bypass | 本地 HTTPS server + `/etc/hosts` + `NO_PROXY`，跳过 Cloudflare 403 |
| mTLS 客户端证书 | 自签 CA + 每环境独立客户端证书 |
| 进程级代理 | HTTP / HTTPS / SOCKS5，自动检测协议 |
| Relay 本地中转 | 127.0.0.1 TCP relay，绕过 Clash/Surge TUN 模式 |
| 启动前检测 | 代理连通性 + TUN 冲突检测 |

### 安装

```bash
# npm（推荐）
npm install -g claude-cac
cac setup

# 手动安装
git clone https://github.com/nmhjklnm/cac.git
cd cac && bash install.sh
```

<details>
<summary>Windows (PowerShell)</summary>

```powershell
git clone https://github.com/nmhjklnm/cac.git
copy cac\cac.ps1 %USERPROFILE%\bin\
copy cac\cac.cmd %USERPROFILE%\bin\
copy cac\fingerprint-hook.js %USERPROFILE%\bin\
# 将 ~/bin 和 ~/.cac/bin 加入 PATH
cac setup
```

</details>

### 快速上手

```bash
cac setup                                       # 首次初始化
cac add us1 1.2.3.4:1080:username:password      # 添加配置
cac us1                                          # 切换配置
claude                                           # 启动 Claude Code（首次需 /login）
```

### 命令

| 命令 | 说明 |
|:---|:---|
| `cac setup` | 首次安装 |
| `cac add <名字> <代理>` | 添加配置（`host:port:user:pass` 或完整 URL） |
| `cac <名字>` | 切换配置 |
| `cac ls` | 列出所有配置 |
| `cac check` | 检查代理、安全防护、TUN 冲突 |
| `cac relay on [--route]` | 启用本地中转（绕过 TUN） |
| `cac relay off` | 停用中转 |
| `cac stop` / `cac -c` | 暂停 / 恢复保护 |

### 工作原理

```
              cac wrapper（进程级，零入侵源代码）
              ┌──────────────────────────────────────────┐
  claude ────►│  健康检查 bypass（本地 HTTPS server）      │
              │  12 层遥测环境变量保护                      │
              │  NODE_OPTIONS: DNS guard + 指纹钩子       │──► 代理 ──► Anthropic API
              │  PATH: 设备指纹 shim                      │
              │  mTLS: 客户端证书注入                      │
              └──────────────────────────────────────────┘
```

TUN 代理冲突时启用 relay：

```
  claude ──► wrapper ──► relay (127.0.0.1:17890) ──► 远端代理 ──► API
                          ↑ loopback 流量不经过 TUN
```

### 文件结构

```
~/.cac/
├── bin/claude              # wrapper
├── shim-bin/               # ioreg / hostname / ifconfig / cat shim
├── fingerprint-hook.js     # Node.js 指纹拦截
├── relay.js                # TCP relay 服务
├── cac-dns-guard.js        # DNS + fetch 遥测拦截
├── ca/                     # 自签 CA + 健康检查 bypass 证书
├── current                 # 当前激活的配置名
└── envs/<name>/
    ├── proxy               # 代理地址
    ├── uuid / stable_id    # 隔离身份
    ├── hostname / mac_address / machine_id
    ├── client_cert.pem     # mTLS 证书
    └── relay               # "on" 启用中转
```

### Docker 容器模式

完全隔离的运行环境：sing-box TUN 网络隔离 + cac 身份伪装，预装 Claude Code。

```bash
cac docker setup     # 粘贴代理地址，网络自动检测
cac docker create    # 拉取预构建镜像
cac docker start     # 启动容器
cac docker enter     # 进入容器，claude + cac 直接可用
cac docker check     # 网络 + 身份一键诊断
cac docker port 6287 # 端口转发
```

| 命令 | 说明 |
|:---|:---|
| `cac docker setup` | 配置代理（交互式） |
| `cac docker create` | 拉取 Docker 镜像 |
| `cac docker start` / `stop` / `restart` | 容器生命周期 |
| `cac docker enter` | 进入容器 |
| `cac docker check` | 网络 + 身份诊断 |
| `cac docker port <端口>` | 端口转发到 localhost |
| `cac docker status` | 查看状态 |
| `cac docker logs` | 查看日志 |

代理格式：`ip:port:user:pass`（SOCKS5）、`ss://...`、`vmess://...`、`vless://...`、`trojan://...`

容器自动完成：TUN 启动 → 时区/语言检测 → cac profile 创建并激活 → 身份伪装生效。`/root` 和 `/home` 持久化到宿主机 `docker/data/`。

### 注意事项

- **首次登录**：启动 `claude` 后，在界面内输入 `/login` 完成 OAuth 授权。健康检查由 cac 自动 bypass。
- **TUN 冲突**：使用 `cac relay on` 或在 TUN 软件中为代理 IP 添加 DIRECT 规则。`cac check` 会自动检测。
- **API 环境变量**：wrapper 启动时自动清除 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY`。
- **IPv6**：建议系统级关闭，防止真实地址泄露。

---

<a id="english"></a>

## English

> **[切换到中文](#中文)**

### Overview

Claude Code reads device identifiers at runtime (hardware UUID, MAC, hostname, etc.). **cac** intercepts all `claude` invocations via a wrapper, providing:

- **Privacy isolation** — each profile has independent device fingerprints
- **Process-level proxy** — direct connection to remote proxy, no local proxy tools needed
- **Telemetry blocking** — multi-layer DNS + env var + fetch interception

### Features

| Feature | How |
|:---|:---|
| Hardware UUID isolation | macOS `ioreg` / Linux `machine-id` / Windows `wmic`+`reg` shim |
| Hostname / MAC isolation | Shell shim + Node.js `os.hostname()` / `os.networkInterfaces()` hook |
| Node.js fingerprint hook | `fingerprint-hook.js` via `NODE_OPTIONS --require` |
| Telemetry blocking | DNS guard + 12 env vars + fetch interception + HOSTALIASES |
| Health check bypass | Local HTTPS server + `/etc/hosts` + `NO_PROXY`, skips Cloudflare 403 |
| mTLS client certificates | Self-signed CA + per-profile client certs |
| Process-level proxy | HTTP / HTTPS / SOCKS5, auto-detect protocol |
| Relay (bypass TUN) | Local TCP relay on 127.0.0.1, bypasses Clash/Surge TUN mode |
| Pre-launch check | Proxy connectivity + TUN conflict detection |

### Install

```bash
# npm (recommended)
npm install -g claude-cac
cac setup

# or manual
git clone https://github.com/nmhjklnm/cac.git
cd cac && bash install.sh
```

<details>
<summary>Windows (PowerShell)</summary>

```powershell
git clone https://github.com/nmhjklnm/cac.git
copy cac\cac.ps1 %USERPROFILE%\bin\
copy cac\cac.cmd %USERPROFILE%\bin\
copy cac\fingerprint-hook.js %USERPROFILE%\bin\
# Add ~/bin and ~/.cac/bin to PATH
cac setup
```

</details>

### Quick start

```bash
cac setup                                       # first-time init
cac add us1 1.2.3.4:1080:username:password      # add profile
cac us1                                          # switch
claude                                           # run Claude Code (first time: /login)
```

### Commands

| Command | Description |
|:---|:---|
| `cac setup` | First-time setup |
| `cac add <name> <proxy>` | Add profile (`host:port:user:pass` or full URL) |
| `cac <name>` | Switch to profile |
| `cac ls` | List profiles |
| `cac check` | Verify proxy, fingerprint, TUN conflicts |
| `cac relay on [--route]` | Enable local relay (bypass TUN) |
| `cac relay off` | Disable relay |
| `cac stop` / `cac -c` | Pause / resume protection |

### How it works

```
              cac wrapper (process-level, zero source invasion)
              ┌──────────────────────────────────────────┐
  claude ────►│  Health check bypass (local HTTPS server) │
              │  Env vars: 12-layer telemetry kill        │
              │  NODE_OPTIONS: DNS guard + fingerprint    │──► Proxy ──► Anthropic API
              │  PATH: device fingerprint shims           │
              │  mTLS: client cert injection              │
              └──────────────────────────────────────────┘
```

When TUN-mode proxy software (Clash, Surge) causes conflicts:

```
  claude ──► wrapper ──► relay (127.0.0.1:17890) ──► remote proxy ──► API
                          ↑ loopback bypasses TUN
```

### File layout

```
~/.cac/
├── bin/claude              # wrapper
├── shim-bin/               # ioreg / hostname / ifconfig / cat shims
├── fingerprint-hook.js     # Node.js fingerprint interception
├── relay.js                # TCP relay server
├── cac-dns-guard.js        # DNS + fetch telemetry interception
├── ca/                     # self-signed CA + health bypass cert
├── current                 # active profile name
└── envs/<name>/
    ├── proxy               # proxy URL
    ├── uuid / stable_id    # isolated identity
    ├── hostname / mac_address / machine_id
    ├── client_cert.pem     # mTLS cert
    └── relay               # "on" if relay enabled
```

### Docker Mode

Fully isolated environment: sing-box TUN network isolation + cac identity protection, with Claude Code pre-installed.

```bash
cac docker setup     # paste proxy, network auto-detected
cac docker create    # pull pre-built image
cac docker start     # start container
cac docker enter     # shell with claude + cac ready
cac docker check     # network + identity diagnostics
cac docker port 6287 # port forwarding
```

| Command | Description |
|:---|:---|
| `cac docker setup` | Configure proxy (interactive) |
| `cac docker create` | Pull Docker image |
| `cac docker start` / `stop` / `restart` | Container lifecycle |
| `cac docker enter` | Enter container |
| `cac docker check` | Network + identity diagnostics |
| `cac docker port <port>` | Forward port to localhost |
| `cac docker status` | Show status |
| `cac docker logs` | View logs |

Proxy formats: `ip:port:user:pass` (SOCKS5), `ss://...`, `vmess://...`, `vless://...`, `trojan://...`

Container auto-setup: TUN start → timezone/locale detection → cac profile created and activated → identity spoofed. `/root` and `/home` persist to host `docker/data/`.

### Notes

- **First login**: Run `claude`, then type `/login` in the interface. Health check is automatically bypassed by cac.
- **TUN conflicts**: Use `cac relay on` or add DIRECT rule in your TUN software. `cac check` detects this.
- **API env vars**: Wrapper clears `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY`.
- **IPv6**: Recommend disabling system-wide to prevent real address exposure.

---

<div align="center">

MIT License

</div>
