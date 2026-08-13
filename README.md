# 🛡️ dns-setup

VPS DNS 自动配置工具 v2.0 — 集成 AKDNS 测速逻辑，自动扫描 8 个 AKDNS 节点，选出最快的 DNS，通过 unbound 本地转发器强制走 TCP，并防止 DHCP 续约覆盖配置。

支持 Alpine Linux（openrc）和 Debian/Ubuntu（systemd）。

---

## ✨ v2.0 新特性

- **集成 AKDNS 测速**：自动扫描 AKDNS 官方 8 个节点（与 akdns.sh 同源），UDP 和 TCP 同时测试
- **智能协议选择**：UDP 优先，UDP 全超时时自动切换 TCP
- **真实延迟测速**：每节点 ping 5 次取平均值，延迟单位精确到毫秒
- **保留手动模式**：仍可手动输入任意 DNS 服务商

---

## 🧩 默认扫描的 AKDNS 节点

| 地址 | 节点 |
|------|------|
| 66.66.66.66 | AKDNS #1 |
| 45.207.157.146 | AKDNS #2 |
| 108.160.138.51 | AKDNS #3 |
| 139.180.133.239 | AKDNS #4 |
| 45.76.83.113 | AKDNS #5 |
| 45.76.71.83 | AKDNS #6 |
| 45.63.99.176 | AKDNS #7 |
| 166.0.199.207 | AKDNS #8 |

> 注：节点列表与 [AKDNS 官方脚本](https://github.com/akile-network/aktools) 保持一致

---

## ⚡ 快速开始

一键安装并自动配置：

```bash
curl -fsSL https://raw.githubusercontent.com/zhangweixy666/dns-setup/main/dns-setup.sh | sh -s -- --auto
```

或分步执行：

```bash
# 下载脚本
curl -fsSL https://raw.githubusercontent.com/zhangweixy666/dns-setup/main/dns-setup.sh -o /root/dns-setup.sh
chmod +x /root/dns-setup.sh

# 交互式菜单
sh /root/dns-setup.sh

# 一键自动配置（非交互）
sh /root/dns-setup.sh --auto
```

---

## 🖥️ 菜单说明

```
╔══════════════════════════════════════╗
  ║  DNS Setup  v2.0.0                   ║
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
| 1 | **自动扫描 AKDNS**：测速 8 个节点（UDP+TCP），选最快的，配置 unbound 并锁定 |
| 2 | **手动输入 DNS**：支持任意服务商（如 `8.8.8.8 1.1.1.1`），可选强制 TCP |
| 3 | 显示当前 unbound 状态、上游、协议、DNS 解析结果 |
| 4 | 还原到操作前的原始 DNS 配置 |

---

## 🔧 命令行参数

| 参数 | 说明 |
|------|------|
| `--auto` | 全自动扫描 AKDNS 并应用最佳节点，无需交互 |
| `--status` | 查看当前状态 |
| `--restore` | 还原原始 DNS |

---

## 📊 测速示例输出

```
[INFO] Scanning DNS servers (5 pings each)...

  Server                UDP (ms)        TCP (ms)      
  --------------------  --------------  --------------
  66.66.66.66           fail            fail          
  45.207.157.146        fail            153 ms  ✓   
  108.160.138.51        fail            109 ms  ✓   
  139.180.133.239       fail            189 ms  ✓   
  45.76.83.113          fail            150 ms  ✓   
  45.76.71.83           fail            9 ms  ✓     
  45.63.99.176          fail            138 ms  ✓   
  166.0.199.207         fail            172 ms  ✓   

[WARN] All UDP DNS timed out, trying TCP...
[OK] TCP DNS available, will use TCP mode
[INFO] Alpine/musl detected: forced TCP via unbound
[OK] Best: 45.76.71.83  proto: tcp  latency: 9ms (TCP)
```

---

## 🏗️ 架构

```
系统程序
  └─▶ 127.0.0.1:53  (本地 unbound)
        └─▶ 强制 TCP  ──▶  AKDNS 最快节点:53
```

`/etc/resolv.conf` 始终保持 `nameserver 127.0.0.1`，由 unbound 负责转发和协议选择。

---

## 🛡️ DHCP 防护机制

解决 **Incus/LXC 容器 DHCP 续约覆盖 DNS** 的问题：

1. **`chattr +i`** — 文件系统锁定 `/etc/resolv.conf`
2. **udhcpc patch** — 修改 Alpine 的 `/usr/share/udhcpc/default.script`，检测到托管标记后跳过 DNS 覆写
3. **dhcpcd hook** — Debian/Ubuntu 的 dhcpcd 保护
4. **systemd-resolved 禁用** — 停用可能冲突的系统 DNS 管理器

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
- Alpine 使用 musl libc，`/etc/resolv.conf` 的 `options use-vc` 不可靠，本脚本通过 unbound 层解决
- 部分 VPS 环境出站 UDP 53 被封锁，脚本会自动检测并切换到 TCP
- 还原操作会停止 unbound 并解除所有保护

---

## 🆚 与 AKDNS 官方脚本的区别

| 特性 | dns-setup v2.0 | AKDNS 官方脚本 |
|------|----------------|----------------|
| 测速逻辑 | ✅ 完全集成 AKDNS 算法 | ✅ 原版 |
| DNS 节点 | ✅ AKDNS 8 节点 | ✅ AKDNS 8 节点 |
| TCP 强制 | ✅ unbound `forward-tcp-upstream` | ⚠️ `options use-vc`（Alpine 不可靠） |
| DHCP 防护 | ✅ 三层保护 + udhcpc patch | ❌ 仅 `chattr +i` |
| 手动 DNS | ✅ 支持任意服务商 | ❌ 仅 AKDNS |
| 架构 | unbound 本地转发 | 直接写 `/etc/resolv.conf` |

---

## 📄 License

MIT

---

## 🔗 相关链接

- AKDNS 官方：https://dns.akile.ai/
- AKDNS 脚本仓库：https://github.com/akile-network/aktools
