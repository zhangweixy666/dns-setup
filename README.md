# DNS 修改

VPS 通用 DNS 自动配置与管理脚本

适用于 Alpine、Debian/Ubuntu 等 Linux VPS，以及使用 DHCP 网络的 Incus/LXC 容器。

脚本会下载 AKDNS 官方脚本，动态读取当前 DNS 节点列表，分别测试 UDP/TCP 连通性和延迟，然后选择可用的最快 DNS。UDP 不可用时自动切换 TCP，并通过本地 unbound 转发，避免 Alpine/musl 对 `options use-vc` 支持不可靠的问题。

README 中的命令均按“一个代码块一个命令”排列，便于直接复制执行。

## ✨ 项目简介

这是一个面向 VPS 和容器环境的 DNS 修改工具，重点解决以下问题：

- VPS 出站 UDP/53 被限制，但 TCP/53 可用。
- AKDNS 节点需要先通过官方脚本测速，不能使用固定结果。
- Alpine/musl 下 `options use-vc` 不能稳定强制系统解析器走 TCP。
- Incus/LXC 的 DHCP 续租会把下发的 DNS 写回 `/etc/resolv.conf`。
- `udhcpc`、`dhcpcd`、`systemd-resolved` 等组件可能覆盖手动 DNS 配置。
- 修改 DNS 后需要保留备份，并能随时还原。

## 🧩 功能概览

| 功能 | 说明 |
|------|------|
| AKDNS 动态测速 | 通过 `wget` 下载 AKDNS 官方脚本并读取其中的 `DNS_LIST` |
| UDP/TCP 检测 | 每个节点分别测试 UDP 和 TCP，每种协议测试 2 次 |
| 智能协议选择 | UDP 有可用节点时优先选择最快 UDP；UDP 全部失败时选择最快 TCP |
| TCP 转发 | 通过 unbound 的 `forward-tcp-upstream: yes` 强制连接上游 TCP/53 |
| 自定义 DNS | 支持手动输入任意 DNS 服务商地址 |
| DHCP 防覆盖 | 处理 `chattr`、Alpine `udhcpc`、`dhcpcd` 等常见覆盖来源 |
| 本地 DNS 入口 | 系统统一使用 `127.0.0.1:53`，由 unbound 负责转发 |
| 自动备份 | 修改前备份 `/etc/resolv.conf` 和 unbound 配置 |
| 一键还原 | 还原最近一次 DNS 配置并停止 unbound |
| 中文界面 | 菜单、状态和错误提示均为中文 |
| 开机自启 | 自动加入 Alpine OpenRC 或 systemd 启动流程 |

## ⚡ 快速开始

下载脚本：

```sh
wget -qO /root/dns-setup.sh https://raw.githubusercontent.com/zhangweixy666/dns-setup/main/dns-setup.sh
```

赋予执行权限：

```sh
chmod +x /root/dns-setup.sh
```

启动中文交互菜单：

```sh
sh /root/dns-setup.sh
```

直接执行自动测速并应用：

```sh
wget -qO- https://raw.githubusercontent.com/zhangweixy666/dns-setup/main/dns-setup.sh | sh -s -- --auto
```

## 🖥️ 菜单说明

```text
========================================
       通用 DNS 配置工具 v2.1.0
========================================
系统：Alpine Linux（openrc）

  1) 下载 AKDNS 官方脚本并自动测速配置
  2) 手动输入 DNS 服务商地址
  3) 查看当前 DNS 状态
  4) 还原上一次备份的 DNS
  0) 退出

请选择 [0-4]：
```

### 1. 下载 AKDNS 官方脚本并自动测速配置

执行流程：

```text
下载 AKDNS 官方脚本
    ↓
读取官方 DNS_LIST
    ↓
每个节点测试 UDP 2 次、TCP 2 次
    ↓
UDP 可用：选择最快 UDP
UDP 全部不可用：选择最快 TCP
    ↓
生成 unbound 配置
    ↓
将 /etc/resolv.conf 指向 127.0.0.1
    ↓
部署 DHCP 防覆盖
    ↓
验证 DNS 解析和 GitHub 访问
```

该模式不会使用本项目中写死的 AKDNS 节点列表。每次运行都会重新下载官方脚本并读取最新节点。

### 2. 手动输入 DNS 服务商地址

支持一个或多个 IPv4 地址，例如：

```text
8.8.8.8 8.8.4.4
```

```text
1.1.1.1 1.0.0.1
```

```text
45.76.71.83
```

输入后可以选择是否强制上游使用 TCP。

如果 VPS 的 UDP/53 不通，应选择强制 TCP；如果 UDP/53 正常，可以使用默认 UDP 转发。

### 3. 查看当前 DNS 状态

显示以下信息：

- 当前系统发行版和 init 系统。
- `/etc/resolv.conf` 内容。
- unbound 服务状态。
- 当前上游 DNS 和转发协议。
- DHCP 托管标记。
- `/etc/resolv.conf` 的 immutable 属性。
- 测试域名的解析结果。

### 4. 还原上一次备份的 DNS

还原最近一次备份的 `/etc/resolv.conf`，删除 DNS 托管标记，并停止 unbound。

备份目录：

```text
/var/lib/dns-setup/backup/
```

## 🔧 命令行参数

自动测速并应用：

```sh
sh /root/dns-setup.sh --auto
```

查看当前状态：

```sh
sh /root/dns-setup.sh --status
```

还原最近一次备份：

```sh
sh /root/dns-setup.sh --restore
```

## 🌐 DNS 转发原理

系统不会直接把 AKDNS 地址写进 `/etc/resolv.conf`，而是使用本地 unbound 作为稳定入口：

UDP 正常时：

```text
系统程序
  → 127.0.0.1:53
  → unbound
  → 上游 DNS:53/UDP
```

UDP 不通时：

```text
系统程序
  → 127.0.0.1:53
  → unbound
  → 上游 DNS:53/TCP
```

当测速判断需要 TCP 时，配置中会写入：

```conf
forward-tcp-upstream: yes
```

因此，`dig @127.0.0.1` 显示本地请求使用 UDP 不代表外部上游使用 UDP。真正的上游连接由 unbound 控制。

## 🧱 DHCP 覆盖问题

Incus Alpine 容器中的典型覆盖链路：

```text
eth0 配置为 DHCP
        ↓
udhcpc 常驻后台
        ↓
DHCP 续约或重新绑定
        ↓
调用 /usr/share/udhcpc/default.script
        ↓
执行 resolv_conf()
        ↓
DHCP 下发的 DNS 覆盖 /etc/resolv.conf
```

例如 DHCP 下发：

```text
nameserver 10.10.0.1
```

即使手动修改过 DNS，续租后也可能重新变成：

```text
nameserver 10.10.0.1
```

## 🛡️ 防覆盖机制

脚本应用 DNS 后会执行以下保护：

1. 将 `/etc/resolv.conf` 设置为：

```text
nameserver 127.0.0.1
```

2. 尝试执行：

```sh
chattr +i /etc/resolv.conf
```

防止 DHCP 客户端直接覆盖文件。

3. Alpine 检测到 `/usr/share/udhcpc/default.script` 时：

- 自动创建原始脚本备份。
- 在 `resolv_conf()` 中加入托管标记判断。
- DHCP 续租时跳过 DNS 覆写。

4. 如果系统安装了 `dhcpcd`，添加保护钩子。

5. 在 systemd 系统中停用 `systemd-resolved`，避免它重新接管 DNS。

6. 将 unbound 加入开机启动。

如果容器文件系统不支持 immutable 属性，脚本仍会使用 DHCP 脚本保护，并在输出中提示实际生效的保护方式。

## 📂 配置和备份位置

| 路径 | 作用 |
|------|------|
| `/etc/unbound/unbound.conf` | unbound 主配置 |
| `/etc/resolv.conf` | 系统 DNS 入口，通常为 `127.0.0.1` |
| `/etc/dns-setup-managed` | DNS 已由脚本接管的标记 |
| `/var/lib/dns-setup/backup/` | DNS 配置备份 |
| `/usr/share/udhcpc/default.script.dns-setup-bak` | Alpine udhcpc 原始脚本备份 |

## 🔍 常用排障

查看系统 DNS：

```sh
cat /etc/resolv.conf
```

查看 unbound 状态：

```sh
rc-service unbound status
```

检查 unbound 配置：

```sh
unbound-checkconf /etc/unbound/unbound.conf
```

测试本地 DNS：

```sh
dig @127.0.0.1 www.google.com
```

测试指定上游 TCP：

```sh
dig +tcp @45.76.71.83 www.google.com
```

查看 DHCP 保护是否写入：

```sh
grep -n DNS-SETUP-MANAGED /usr/share/udhcpc/default.script
```

查看当前 immutable 属性：

```sh
lsattr /etc/resolv.conf
```

如果 DNS 仍然失败，先确认：

- VPS 是否能访问 GitHub raw。
- 上游 DNS 的 53 端口是否可达。
- `unbound` 是否处于 started 状态。
- `/etc/resolv.conf` 是否仍为 `127.0.0.1`。
- 容器文件系统是否支持 `chattr +i`。
- 上游 DNS 是否已经临时失效。

## ⚠️ 注意事项

- 需要 root 权限。
- 自动模式依赖访问 GitHub raw 下载 AKDNS 官方脚本。
- DNS 节点的可用性会随时间和网络环境变化，每次自动模式都会重新测速。
- 脚本会修改 DNS 管理行为，建议操作前创建 VPS 或容器快照。
- 还原前会自动保存当前配置。
- 生产环境请先确认云厂商安全组和容器网络策略。
- 本项目只负责 DNS 配置，不负责 AKDNS 控制台中的解锁授权。
- 请在自己拥有或获授权管理的服务器上使用。

## 📄 License

MIT

## 🔗 相关链接

- AKDNS 官方项目：https://github.com/akile-network/aktools
- AKDNS 官方脚本：https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh
- 本项目：https://github.com/zhangweixy666/dns-setup
