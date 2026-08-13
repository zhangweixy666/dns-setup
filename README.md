# 🛡️ dns-setup

VPS DNS 自动配置工具 — 自动检测 UDP/TCP 连通性，通过 unbound 本地转发器强制走 TCP，并防止 DHCP 续约覆盖配置。

支持 Alpine Linux（openrc）和 Debian/Ubuntu（systemd）。

---

## ✨ 功能特性

- **自动扫描**：对多个 DNS 服务商同时测试 UDP 和 TCP 延迟，优先选择 UDP，UDP 不通则自动切换 TCP
- **强制 TCP**：通过 unbound `forward-tcp-upstream` 实现，不依赖 musl `options use-vc`（Alpine 上不可靠）
- **DHCP 防覆盖**：三层保护
  - `chattr +i` 文件系统锁定 `/etc/resolv.conf`
  - 修补 Alpine `udhcpc default.script`，DHCP 续约时跳过 DNS 覆写
  - dhcpcd hook（如有）
- **自定义 DNS**：可手动填写任意 DNS 服务商，支持多个上游（故障自动转移）
- **一键还原**：操作前自动备份，支持随时回滚
- **开机自启**：自动注册 unbound 到 openrc/systemd

---

## 🧩 默认扫描的 DNS 服务商

| 地址 | 服务商 |
|------|--------|
| 45.76.71.83 / 45.76.83.113 / 45.207.157.146 | AKDNS |
| 8.8.8.8 / 8.8.4.4 | Google |
| 1.1.1.1 / 1.0.0.1 | Cloudflare |
| 9.9.9.9 | Quad9 |
| 208.67.222.222 | OpenDNS |
| 114.114.114.114 | 114DNS |

---

## ⚡ 快速开始

下载脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/zhangweixy666/dns-setup/main/dns-setup.sh -o /root/dns-setup.sh
```

赋予执行权限：

```bash
chmod +x /root/dns-setup.sh
```

交互式菜单：

```bash
sh /root/dns-setup.sh
```

一键自动配置（非交互，适合远程脚本调用）：

```bash
sh /root/dns-setup.sh --auto
```

---

## 🖥️ 菜单说明

```╔══════════════════════════════════════╗
  ║  DNS Setup  v1.3.0                   ║
  ║System: alpine (openrc)               ║
  ╠══════════════════════════════════════╣
  ║  1) Auto-detect best DNS and apply   ║
  ║  2) Manually enter DNS server(s)     ║
  ║  3) Show current status              ║
  ║  4) Restore original DNS             ║
  ║  0) Exit                             ║
  ╚══════════════════════════════════════╝
```

| 选项 | 功能 |
|------|------|
| 1 | 自动扫描所有内置 DNS 服务器，选出最快的，自动配置 unbound 并锁定 |
| 2 | 手动填写 DNS 服务器 IP（空格分隔），可选是否强制 TCP |
| 3 | 显示当前 unbound 状态、上游、协议、DNS 解析结果 |
| 4 | 还原到操作前的原始 DNS 配置 |

---

## 🔧 命令行参数

| 参数 | 说明 |
|------|------|
| `--auto` | 全自动扫描并应用，无需交互 |
| `--status` | 查看当前状态 |
| `--restore` | 还原原始 DNS |

---

## 🏗️ 架构

```
系统程序
  └─▶ 127.0.0.1:53  (本地 unbound)
        └─▶ 强制 TCP  ──▶  上游 DNS:53
```

`/etc/resolv.conf` 始终保持 `nameserver 127.0.0.1`，由 unbound 负责转发和协议选择。

---

## 📂 文件说明

| 路径 | 说明 |
|------|------|
| `/etc/unbound/unbound.conf` | unbound 主配置 |
| `/etc/resolv.conf` | 系统 DNS，始终为 `127.0.0.1` |
| `/etc/dns-setup-managed` | 托管标记，DHCP 保护依据此文件 |
| `/var/lib/dns-setup/backup/` | 操作前的自动备份 |
| `/usr/share/udhcpc/default.script.dns-setup-bak` | udhcpc 原始脚本备份 |

---

## ⚠️ 注意事项

- 需要 root 权限运行
- Alpine 使用 musl libc，`/etc/resolv.conf` 的 `options use-vc` 不可靠，本脚本通过 unbound 层解决此问题
- 部分 VPS 环境出站 UDP 53 被封锁，脚本会自动检测并切换到 TCP
- 还原操作会停止 unbound 并解除所有保护

---

## 📄 License

MIT
