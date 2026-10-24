<div align="center">

<h1>🛡 DNS Setup</h1>

<p><b>VPS 通用 DNS 自动配置与管理脚本</b></p>

<p>自动测速 · UDP/TCP 智能切换 · DHCP 防覆盖 · 一键回滚</p>

[![Version](https://img.shields.io/badge/version-v2.4.1-2ea44f?style=for-the-badge)](https://github.com/zhangweixy666/dns-setup)
[![Platform](https://img.shields.io/badge/platform-Alpine%20%7C%20Debian%20%7C%20Ubuntu-0078d7?style=for-the-badge)](#-系统要求)
[![Init](https://img.shields.io/badge/init-OpenRC%20%7C%20systemd-orange?style=for-the-badge)](#-系统要求)
[![License](https://img.shields.io/badge/license-MIT-lightgrey?style=for-the-badge)](#-致谢与许可)

<p><b>DNS 断了也能自救 · 改坏了能一键还原</b></p>

[🚀 快速开始](#-快速开始)　·　[🎯 解决什么问题](#-解决什么问题)　·　[✨ 核心特性](#-核心特性)　·　[❓ 常见问题](#-常见问题)　·　[📜 更新记录](#-更新记录)

</div>

---

## 🎯 解决什么问题

手动改 DNS，翻车的方式就那么几种：

| 你遇到的坑 | 这个脚本怎么处理 |
|:---|:---|
| VPS 出站 UDP/53 被限制，但 TCP/53 可用 | 每个节点分别测 UDP 和 TCP，UDP 全挂自动切 TCP，由 unbound 强制 `forward-tcp-upstream` |
| Alpine/musl 下 `options use-vc` 不能稳定强制 TCP | 不依赖系统解析器，统一走本地 unbound 转发 |
| Incus/LXC 的 DHCP 续租把手改的 DNS 写回去 | 6 层防覆盖：immutable 属性 + udhcpc 插桩 + dhcpcd 钩子 + systemd-resolved + NM + networkd |
| DNS 已经断了，脚本却下载不下来节点列表 | 公共解析器取 IP + IP 直连兜底 + 节点列表缓存降级 |
| 改完不生效，只能重装系统或者重建容器 | `--dry-run` 预演、`--restore` 还原、`--uninstall` 干净卸载 |
| 中途 Ctrl+C，机器停在一半新一半旧的状态 | 临时文件 → 校验 → `mv` 原子替换 + `trap` 中断回滚 |

> 💡 **一句话**：它不只是「把 DNS 改快」，而是保证「改不坏，坏了能退」。

---

## 🚀 快速开始

### 一键自动测速并应用

```sh
wget -qO- https://raw.githubusercontent.com/zhangweixy666/dns-setup/main/dns-setup.sh | sh -s -- --auto
```

### 下载后运行（推荐）

```sh
wget -qO /root/dns-setup.sh https://raw.githubusercontent.com/zhangweixy666/dns-setup/main/dns-setup.sh
```

```sh
chmod +x /root/dns-setup.sh
```

```sh
sh /root/dns-setup.sh
```

### 先看看它会做什么（不改任何文件）

```sh
sh /root/dns-setup.sh --dry-run
```

---

## 📖 目录

- [🎯 解决什么问题](#-解决什么问题)
- [🚀 快速开始](#-快速开始)
- [✨ 核心特性](#-核心特性)
  - [智能测速与协议选择](#-智能测速与协议选择)
  - [六层 DHCP 防覆盖](#-六层-dhcp-防覆盖)
  - [失败原子性](#-失败原子性)
  - [运维闭环](#-运维闭环)
- [🏗 工作原理](#-工作原理)
- [🖥 菜单与命令行](#-菜单与命令行)
- [🔧 可调参数](#-可调参数)
- [📂 配置与备份位置](#-配置与备份位置)
- [🧩 系统要求](#-系统要求)
- [🧪 测试](#-测试)
- [❓ 常见问题](#-常见问题)
- [📜 更新记录](#-更新记录)
- [🙏 致谢与许可](#-致谢与许可)

---

## ✨ 核心特性

### 🔍 智能测速与协议选择

- 下载 AKDNS **官方脚本**并解析其中的 `DNS_LIST`，**不使用任何写死的节点列表**
- 每个节点 **UDP 测 2 次 + TCP 测 2 次**，按真实延迟排序
- UDP 有可用节点 → 选最快 UDP；UDP 全挂 → 选最快 TCP
- 写入 **最快节点 + 最多 3 个备用上游**，单点下线不会导致整机 DNS 中断
- 每节点每协议采样次数可调（`SCAN_COUNT`），繁忙 VPS 可加大采样降低误判

```text
下载 AKDNS 官方脚本
    ↓
读取官方 DNS_LIST（失败则用上次缓存）
    ↓
每节点 UDP ×2 / TCP ×2
    ↓
UDP 可用 → 最快 UDP   ·   UDP 全挂 → 最快 TCP
    ↓
生成 unbound 配置（最快 + 3 备用）
    ↓
/etc/resolv.conf → 127.0.0.1
    ↓
部署 DHCP 防覆盖
    ↓
实测解析 + GitHub 访问验证
```

### 🛡 六层 DHCP 防覆盖

改完 DNS 过一会儿又变回去，通常是这些组件在动手：

| # | 覆盖来源 | 处理方式 |
|:---:|:---|:---|
| 1 | 直接覆写文件 | `/etc/resolv.conf` 写入 `nameserver 127.0.0.1`，尝试 `chattr +i` |
| 2 | Alpine `udhcpc` | 在 `/usr/share/udhcpc/default.script` 的 `resolv_conf()` 插入托管标记判断 |
| 3 | `dhcpcd` | 写入官方保证加载的 `/etc/dhcpcd.enter-hook`（**只追加，不 truncate**） |
| 4 | `systemd-resolved` | 停用服务并移除开机自启 |
| 5 | NetworkManager | `conf.d/99-dns-setup.conf`：`dns=none` + `rc-manager=unmanaged` |
| 6 | systemd-networkd / openresolv | `*.network.d/*.conf` → `UseDNS=no`；`resolvconf.conf` → `name_servers="127.0.0.1"` |

> ⚠️ 容器缺少 `CAP_LINUX_IMMUTABLE` 时，`chattr +i` 会返回 0 但**实际不生效**。脚本用 `lsattr` 复核，并在输出中如实告知最终生效的是哪几层保护。

### 🔒 失败原子性

系统级 DNS 改动的可怕之处不是「当场报错」，而是「当下看着正常、重启才炸」。本项目为此做了四件事：

- **配置原子写入**：临时文件 → `unbound-checkconf` 校验 → `mv` 原子替换。校验失败，生产配置分毫不动
- **符号链接先拆**：Debian 上 `/etc/resolv.conf` 常是 systemd-resolved 的软链，`>` 会穿透写入 tmpfs，重启全丢。脚本先 `readlink` 记录再替换为实体文件
- **共享文件只追加**：`dhcpcd.enter-hook`、`resolvconf.conf` 等系统级共享入口一律 `>>` + `BEGIN/END` 标记，绝不 `cat >`
- **回滚与改动对称**：`save_pre_state` / `rollback_changes` / `restore_dhcp_guards` 三件套，文件内容、`chattr` 属性、新增标记、drop-in、追加段、被停用服务**全部还原**；`trap 'on_interrupt' INT TERM` 覆盖 Ctrl+C 与 SSH 断连

### 🧰 运维闭环

| 能力 | 命令 | 说明 |
|:---|:---|:---|
| 预演 | `--dry-run` | 只打印将写入的配置与保护动作，**不修改任何文件**（副作用探测也不真做） |
| 还原 | `--restore` | 按文件名时间戳**配对**还原 resolv.conf 与 unbound 配置，跳过 0 字节备份，还原后实测解析 |
| 卸载 | `--uninstall` | 逆序撤销全部改动：备份 → 原符号链接 → 公共 DNS 三级回退，重新启用 systemd-resolved |
| 无人值守 | `--yes` | 跳过装包确认（脚本装包前**默认必须确认**） |
| 备份保留 | `BACKUP_KEEP` | 默认保留最近 10 份，按严格时间戳排序，不无限占盘 |

---

## 🏗 工作原理

系统不会直接把 AKDNS 地址写进 `/etc/resolv.conf`，而是用本地 unbound 做一个**永远不变的入口**：

**UDP 正常时**

```text
系统程序
  → 127.0.0.1:53
  → unbound
  → 上游 DNS :53/UDP
```

**UDP 被限制时**

```text
系统程序
  → 127.0.0.1:53
  → unbound  (forward-tcp-upstream: yes)
  → 上游 DNS :53/TCP
```

> 📌 所以 `dig @127.0.0.1` 显示本地走 UDP，**不代表**上游走 UDP —— 真正的上游连接协议由 unbound 决定。

**DHCP 典型覆盖链（以 Incus Alpine 容器为例）**

```text
eth0 配置为 DHCP
    ↓
udhcpc 常驻
    ↓
续约 / 重新绑定
    ↓
/usr/share/udhcpc/default.script → resolv_conf()
    ↓
DHCP 下发的 nameserver 覆盖 /etc/resolv.conf
```

脚本正是在最后一步之前插入托管判断，把这条链掐断。

---

## 🖥 菜单与命令行

### 交互菜单

```text
========================================
       通用 DNS 配置工具 v2.4.1
========================================
系统：Alpine Linux（openrc）
  1) 下载 AKDNS 官方脚本并自动测速配置
  2) 手动输入 DNS 服务商地址
  3) 查看当前 DNS 状态
  4) 还原上一次备份的 DNS
  0) 退出
请选择 [0-4]：
```

### 命令行参数

| 参数 | 作用 |
|:---|:---|
| `--auto` | 自动测速并应用 |
| `--status` | 查看当前 DNS 状态（resolv.conf、unbound、上游、托管标记、immutable、解析实测） |
| `--restore` | 还原最近一次备份 |
| `--dry-run` | 预演，只打印不落盘 |
| `--yes` / `-y` | 跳过依赖安装确认 |
| `--uninstall` | 一键卸载并恢复原始 DNS |

---

## 🔧 可调参数

全部通过环境变量覆盖，不改脚本：

```sh
CACHE_MIN_TTL=60 sh /root/dns-setup.sh --auto
```

```sh
SCAN_TIMEOUT=2 sh /root/dns-setup.sh --auto
```

```sh
SCAN_COUNT=5 sh /root/dns-setup.sh --auto
```

| 变量 | 默认 | 什么时候改 |
|:---|:---:|:---|
| `CACHE_MIN_TTL` | `3600` | CDN 调度 / DDNS 场景调小（如 `60`），否则切 IP 要等一小时 |
| `SCAN_TIMEOUT` | `1` | 繁忙 VPS 上 1 秒容易把好节点判死，调到 `2` |
| `SCAN_COUNT` | `2` | 2 次取平均噪声偏大，建议 `5` |
| `BACKUP_KEEP` | `10` | 备份保留份数 |

---

## 📂 配置与备份位置

| 路径 | 作用 |
|:---|:---|
| `/etc/unbound/unbound.conf` | unbound 主配置（原子写入） |
| `/etc/resolv.conf` | 系统 DNS 入口，通常为 `127.0.0.1` |
| `/etc/dns-setup-managed` | 「DNS 已由本脚本接管」的标记 |
| `/var/lib/dns-setup/backup/` | DNS 配置备份（按 `YYYYMMDD-HHMMSS` 命名） |
| `/usr/share/udhcpc/default.script.dns-setup-bak` | Alpine udhcpc 原始脚本备份 |
| `/var/lib/dns-setup/nodes.cache` | 上次成功的节点列表（官方脚本改格式时降级用） |
| `/var/log/unbound.log` | unbound 运行日志（`verbosity: 1`） |

---

## 🧩 系统要求

| 项目 | 要求 |
|:---|:---|
| 系统 | Alpine Linux、Debian / Ubuntu，以及使用 DHCP 的 Incus / LXC 容器 |
| init | OpenRC（Alpine）或 systemd（Debian/Ubuntu） |
| 权限 | root |
| 依赖 | `unbound`（脚本会先询问再安装）、`curl` 或 `wget`、`dig` |
| 网络 | 自动模式需能访问 GitHub raw |

---

## 🧪 测试

仓库自带 **5 套测试、共 144 项断言**，全部在 `test/` 下，自动定位路径，clone 后可直接运行：

```sh
sh test/run.sh
```

```sh
sh test/run.sh /path/to/dns-setup.sh
```

| 套件 | 项数 | 作用 |
|:---|:---:|:---|
| `test_static.sh` | 82 | 静态断言：版本一致性、关键特征存在、配置项位置 |
| `test_behavior.sh` | 49 | 沙箱行为：提取函数单独跑，路径重定向到临时目录，不碰真实系统 |
| `test_e2e.sh` | 3 | 故障注入：伪造 `checkconf` 失败，验证生产配置不被污染 |
| `test_uninstall.sh` | 5 | 卸载沙箱：备份筛选、保留策略、回退优先级 |
| `test_dnsdown.sh` | 5 | DNS 全断自救：IP 直连取数 + 失败后不留残留 |

> 📌 `test_dnsdown.sh` 会真实访问 GitHub raw，无网络环境失败属预期。
> `test/` 目录不参与脚本运行，不影响部署。

---

## ❓ 常见问题

<details>
<summary><b>装完之后 `dig` 还是走 UDP，是不是没生效？</b></summary>

不是。`dig @127.0.0.1` 测的是「本机 → unbound」这一段，这一段永远是 UDP。真正决定上游走 UDP 还是 TCP 的是 unbound 的 `forward-tcp-upstream`。

想验证上游协议，看 unbound 配置或日志：

```sh
grep forward-tcp-upstream /etc/unbound/unbound.conf
```

</details>

<details>
<summary><b>Alpine 容器里 `chattr +i` 没报错，但 DNS 还是被改了？</b></summary>

容器通常没有 `CAP_LINUX_IMMUTABLE`，`chattr +i` 会**返回 0 但不生效**。脚本用 `lsattr` 复核并会明确告知。这种情况下靠的是 udhcpc 插桩 + dhcpcd 钩子那几层，通常已经够用。

</details>

<details>
<summary><b>DNS 已经断了，脚本还能跑起来吗？</b></summary>

能。这是本项目从 v2.2.2 起专门解决的问题：

1. 用公共解析器单独取 GitHub 的 IP
2. 用 IP 直连下载（带 `Host` 头，`--no-check-certificate`）
3. 下载后校验内容含 `DNS_LIST`
4. 仍失败则用 `/var/lib/dns-setup/nodes.cache` 上次成功的列表

</details>

<details>
<summary><b>`--restore` 会把我现在的 DNS 弄断吗？</b></summary>

不会。还原逻辑有三重保护：

- 跳过 0 字节的无效备份
- 按同一时间戳**配对**还原 resolv.conf 与 unbound 配置（避免跨时间点错配）
- 如果备份内容仍指向 `127.0.0.1`，会**保持 unbound 运行**并保留托管标记，而不是傻乎乎地停掉它

还原完成后还会实测解析，若该备份的上游已失效会提示重跑 `--auto`。

</details>

<details>
<summary><b>备份会不会把磁盘占满？</b></summary>

不会。`BACKUP_KEEP` 默认保留最近 10 份，且备份列表只接受严格的 `YYYYMMDD-HHMMSS` 文件名。

> 这一步是踩过坑的：`ls -1 | sort -r` 会把 `resolv.conf.unknown`、`resolv.conf.bak2` 也纳入排序，而字典序里非数字排在数字之后，倒排就抢到了头部 —— 于是「最新备份」变成垃圾文件，真正的备份反而被挤出保留窗口。

</details>

<details>
<summary><b>`--dry-run` 真的什么都不改吗？</b></summary>

真的。包括**副作用探测**也不做 —— 判断日志是否可写时只检查目录权限（`[ -w dir ]`），不会创建测试文件，保证打印内容与实际执行完全一致。

</details>

<details>
<summary><b>会影响容器里其他服务吗？</b></summary>

不会改动别人的配置。所有系统级共享文件（`dhcpcd.enter-hook`、`resolvconf.conf`）都只追加带标记的段落，卸载时用 `awk` 精确剥离自己写的那一段，其余内容原样保留。

</details>

<details>
<summary><b>支持 IPv6 上游吗？</b></summary>

支持。早期版本写死了 `do-ip6: no`，导致 IPv6 上游「能通过校验、能写进配置、但 unbound 根本不去连」，必然验证失败回滚。v2.3.0 起按上游地址族动态生成。

</details>

---

## 📜 更新记录

### v2.4.1 — 终审用 shellcheck 挖出死代码

- 🚨 **`fetch_by_ip` 的 wget 兜底从未工作过**：用 IP 直连 `https://$ip/` 时 TLS 证书 CN 是域名而非 IP，不加 `--no-check-certificate` 必然失败（实测 `wget rc=5`），还会留下 0 字节文件。这意味着「DNS 已断时自救」一直只对装了 curl 的机器有效。现加上忽略证书验证（URL 写死为 GitHub raw + `Host` 头指定 + 下载后校验内容含 `DNS_LIST`），并检查文件非空。实测 DNS 屏蔽状态下成功取回 78684 字节。
- 🩹 `curl` 兜底分支也未校验非空，失败会留下空文件被当成成功；现在两条路径都校验 `[ -s "$output" ]`
- 🩹 `verify_dns` 里 `[ ... ] && ok || warn` 不符合 if-then-else 语义（`ok` 返回非 0 会连带执行 `warn`），改显式 `if/else`
- 🩹 5 处 `read` 未带 `-r`，其中 `read manual_servers` 直接影响用户输入的 DNS 地址
- 🔧 `verbosity` 由 `0` 调到 `1`：`0` 只记错误，等于「配了日志但断线时依然查不到东西」

<details>
<summary><b>📚 历史版本（点击展开）</b></summary>

<br>

**v2.4.0** — 补齐运维闭环：新增 `--uninstall`（三级回退：有效备份 → 原符号链接 → 公共 DNS）、`--yes`、装包前确认、节点列表缓存降级、`BACKUP_KEEP` 保留策略、保留 `search`/`domain`、`options timeout:1 attempts:2`；修复备份列表接受任意文件名导致 `--restore` 可能还原到垃圾文件。

**v2.3.1** — 补齐三条覆盖链（NetworkManager `dns=none`、systemd-networkd `UseDNS=no`、openresolv `name_servers`）并全部纳入回滚；新增 unbound 日志（自动 `chown`/`chmod`，失败降级为 syslog）；新增 `do-not-query-localhost`；新增三个可调环境变量。

**v2.3.0** — 聚焦失败原子性：配置改临时文件 + 校验 + `mv`；拆解 `resolv.conf` 符号链接；共享钩子改追加 + 标记段；新增 `save_pre_state`/`rollback_changes`/`restore_dhcp_guards` 完整回滚；新增 `trap` 中断保护；修复 `do-ip6` 写死与 `valid_ip6` 粗校验；新增 `--dry-run`。

**v2.2.2** — 多上游兜底、DNS 全断自救、`dig` 失败文本误判、dhcpcd 钩子路径、非交互 EOF 死循环、`chattr` 假成功、`--restore` 三连问题、`restart_unbound` 假成功等 13 个 bug。

**v2.2.1** — `--restore` 还原后若备份仍指向本地 unbound，保持 unbound 运行并继续托管，避免「还原完成后 DNS 解析失败」。

</details>

---

## 🙏 致谢与许可

- DNS 节点与测速脚本来自 [akile-network/aktools](https://github.com/akile-network/aktools)（AKDNS）
- 转发与缓存由 [NLnet Labs Unbound](https://nlnetlabs.nl/projects/unbound/about/) 提供

**许可**：MIT

> ⚠️ **免责声明**：本项目仅供技术学习与研究使用。脚本会修改系统 DNS 管理行为，建议操作前创建 VPS / 容器快照。请在你拥有或获授权管理的服务器上使用，并遵守所在地法律法规及服务商条款。

<div align="center">

**[⬆ 回到顶部](#-dns-setup)**

Made with 🛡 by [zhangweixy666](https://github.com/zhangweixy666)

</div>
