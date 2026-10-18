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
| AKDNS 动态测速 | 下载 AKDNS 官方脚本并读取其中的 `DNS_LIST`；本机 DNS 已断时用公共解析器直连兜底 |
| 多上游兜底 | 除最快节点外，额外写入最多 3 个可用备用上游，避免单点下线导致整机 DNS 中断 |
| UDP/TCP 检测 | 每个节点分别测试 UDP 和 TCP，每种协议测试 2 次 |
| 智能协议选择 | UDP 有可用节点时优先选择最快 UDP；UDP 全部失败时选择最快 TCP |
| TCP 转发 | 通过 unbound 的 `forward-tcp-upstream: yes` 强制连接上游 TCP/53 |
| 自定义 DNS | 支持手动输入 IPv4 / IPv6 DNS 服务商地址 |
| DHCP 防覆盖 | 处理 `chattr`、Alpine `udhcpc`、`dhcpcd` 等常见覆盖来源 |
| 本地 DNS 入口 | 系统统一使用 `127.0.0.1:53`，由 unbound 负责转发 |
| 自动备份 | 修改前备份 `/etc/resolv.conf` 和 unbound 配置 |
| 一键还原 | 按时间戳配对还原 resolv.conf 与 unbound 配置，跳过空备份，还原后实测解析 |
| 失败回滚 | 验证不通过时回滚本次改动（含 resolv.conf 与 immutable 属性） |
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

还原最近一次备份的 `/etc/resolv.conf` 和对应的 unbound 配置。

如果备份中的 `resolv.conf` 仍指向本地 unbound（`127.0.0.1`），脚本会保持 unbound 运行、保留 DNS 托管标记并维持开机自启，避免还原后 DNS 中断；只有备份内容不依赖本地 unbound 时，才会停止 unbound 并移除开机自启。

还原时还会：跳过 0 字节的无效备份；按文件名时间戳配对还原对应的 unbound 配置；还原完成后实测解析，若该备份对应的上游已失效会明确提示重新运行 `--auto`。

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

预演模式（只打印将写入的配置，不修改任何文件）：

```sh
sh /root/dns-setup.sh --dry-run
```

无人值守（跳过依赖安装确认）：

```sh
sh /root/dns-setup.sh --yes
```

一键卸载（恢复原始 resolv.conf、撤销全部 DHCP 保护、停用 unbound）：

```sh
sh /root/dns-setup.sh --uninstall
```

可调参数（环境变量，按需覆盖）：

```sh
CACHE_MIN_TTL=60 sh /root/dns-setup.sh --auto   # 强制最小缓存 60 秒（CDN 调度/DDNS 场景）
SCAN_TIMEOUT=2 sh /root/dns-setup.sh --auto     # 单次探测超时 2 秒（繁忙 VPS）
SCAN_COUNT=5 sh /root/dns-setup.sh --auto       # 每节点每协议采样 5 次（更稳）
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

## 🧪 测试

仓库附带五套测试（共 144 项断言），全部在仓库根的 `test/` 目录下，
已做自动路径定位，clone 后可直接运行，不依赖任何绝对路径：

```sh
sh test/run.sh
```

指定其他待测脚本：

```sh
sh test/run.sh /path/to/dns-setup.sh
```

各套件单独运行（同样支持传路径）：

```txt
test/test_static.sh      82 项  静态断言（版本一致性、关键特征、配置项位置）
test/test_behavior.sh    49 项  沙箱行为（提取函数单独跑，不碰真实系统）
test/test_e2e.sh          3 项  故障注入（伪造 checkconf 失败，验证生产配置不被污染）
test/test_uninstall.sh    5 项  卸载沙箱（备份筛选、保留策略、回退优先级）
test/test_dnsdown.sh      5 项  DNS 全断自救（IP 直连取数 + 失败后不留残留）
```

> 注：`test_dnsdown.sh` 会真实访问 GitHub raw，无网络环境会失败，属预期。

`test/` 目录不参与脚本运行，不影响部署。

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

## 📜 更新记录

### v2.4.1（2026-10-18）

终审阶段深度检查发现的问题修复。本轮把 shellcheck 引入验证流程，找出了没有任何测试覆盖的死代码分支。

- 修复（高危，死代码）：`fetch_by_ip` 的 wget 兜底分支从未真正工作过。用 IP 直连 `https://$ip/` 时，TLS 证书 CN 是域名而非 IP，不加 `--no-check-certificate` 必然 SSL 验证失败（实测 `wget rc=5`），且会留下一个 0 字节文件。这意味着**只有 wget 没有 curl 的机器，DNS 已断时仍然救不回来**——所谓「鸡生蛋」自救一直只对装了 curl 的机器有效。现在加上忽略证书验证（可接受：URL 写死为 GitHub raw，且已用 `Host` 头指定目标主机，下载后还会校验内容是否含 `DNS_LIST`），并在下载后检查文件非空，失败时清理残留。实测：DNS 屏蔽状态下成功取回 78684 字节且含 `DNS_LIST`。
- 修复：`curl` 兜底分支未检查产出文件是否非空，失败时会留下空文件被当成成功。现在 `curl` 与 `wget` 两条路径都校验 `[ -s "$output" ]`。
- 修复：`verify_dns` 里 `[ ... ] && ok || warn` 的写法不符合 if-then-else 语义（`ok` 若返回非 0 会连带执行 `warn`）。改为显式 `if/else`。
- 修复：5 处 `read` 未带 `-r`，会吞掉反斜杠。其中 `read manual_servers` 直接影响用户手动输入的 DNS 地址。
- 改进：`verbosity` 由 `0` 调到 `1`。`0` 只记录错误，日常几乎无输出，等于「配了日志但断线时依然查不到东西」；`1` 是运行信息级，足够排查且不像 `2+` 那样刷爆磁盘。

### v2.4.0（2026-10-18）

补齐运维闭环：卸载、备份治理、降级容错、参数覆盖。（本项目不再发布 GitHub Release，版本以 tag 为准。）

- 新增：`--uninstall` 一键卸载。按优先级找最近一份**非空且不指向本机 unbound** 的备份恢复 `resolv.conf`；找不到则尝试恢复原符号链接；两者都无时写入公共 DNS 兜底避免直接断网。随后撤销 DHCP 保护、停 unbound 并删开机自启、重新启用被停用的 systemd-resolved、清理标记与缓存。备份目录默认保留不删。
- 新增：`--yes` / `-y` 无人值守模式，跳过依赖安装确认。
- 新增：`ensure_deps` 装包前必须确认。之前 `--auto` 会静默 `apk add` / `apt-get install`，在生产机上属于不可接受的副作用。
- 新增：节点列表缓存降级。AKDNS 官方脚本改了格式（单引号 / 换行分隔 / 变量拼接）导致解析为空时，不再直接失败，改用 `/var/lib/dns-setup/nodes.cache` 上次成功的列表。
- 新增：备份保留策略。`BACKUP_KEEP`（默认 10）按时间戳保留最近 N 份，防止无限累积占盘。
- 新增：`resolv.conf` 保留 `search` / `domain` 域。云环境的主机名短名解析依赖它，之前会被直接冲掉。
- 新增：`options timeout:1 attempts:2`。unbound 若意外挂掉，默认 5 秒 × 2 次会把每个请求卡 10 秒，现在最多 2 秒。
- 修复（重要）：备份列表不再接受任意文件名。之前 `ls -1 | sort -r` 会把目录里任何 `resolv.conf.*` 文件纳入排序，而字典序里 `unknown` / `bak2` 排在数字之后，倒排时抢占头部——`--restore` 可能把非时间戳文件当成「最新备份」，保留策略也会把真正最新的备份挤出窗口。新增 `list_backups` 只接受 `YYYYMMDD-HHMMSS` 严格格式，并用 `grep -E '^[0-9]{8}-[0-9]{6}$'` 锚定（不用 `case` 定长模式，写错位数会静默全部不匹配）。

### v2.3.1（2026-10-18）

补齐 DNS 覆盖链、日志与可调参数。

- 新增：NetworkManager 覆盖链。写入 `/etc/NetworkManager/conf.d/99-dns-setup.conf`（`dns=none` + `rc-manager=unmanaged`）。NM 自行管理 resolv.conf 时，之前所有写入都会被它覆盖回去。
- 新增：systemd-networkd 覆盖链。为每个 `*.network` 创建 `*.network.d/99-dns-setup.conf`（`UseDNS=no`），保留 DHCP 本身工作但阻止 DNS 下发。
- 新增：openresolv / resolvconf 覆盖链。写入 `/etc/resolvconf.conf` 的 `name_servers="127.0.0.1"`。Debian/Alpine 上这是最常见却被忽略的覆盖源。
- 新增：上述三条链的回滚。`restore_dhcp_guards` 现在会删除 NM drop-in、networkd drop-in，并用 awk 精确剥离 `resolvconf.conf` 中的标记段（只删自己写的，不碰原有 `search` 等配置）。
- 新增：unbound 日志。配置 `logfile: "/var/log/unbound.log"` + `log-time-ascii: yes` + `use-syslog: no`。写入前自动创建文件、`chown unbound:unbound`、`chmod 640`；无法创建时自动降级为 `use-syslog: no` 并告警，不会因为日志权限导致 unbound 起不来。
- 新增：`do-not-query-localhost: yes`，降低被当成开放解析器滥用的风险。
- 新增：三个环境变量可覆盖参数：
  - `CACHE_MIN_TTL`（默认 3600）——CDN 调度 / DDNS 场景应调小，如 `60`
  - `SCAN_TIMEOUT`（默认 1 秒）——繁忙 VPS 上 1 秒容易把好节点判死
  - `SCAN_COUNT`（默认 2 次）——2 次取平均噪声偏大，建议 5
- 改进：`--dry-run` 在探测日志可写性时不再创建任何文件，只判断目录权限，保证打印内容与实际写入一致。

### v2.3.0（2026-10-18）

本轮聚焦「失败原子性」：每个改动都必须能被安全撤销，绝不把系统留在看似正常、重启才炸的状态。

- 修复（高危）：`write_unbound_conf` 先写生产文件再 `unbound-checkconf` 校验，校验失败直接 return，坏配置已落盘。当下 unbound 还跑旧内存配置看不出问题，下次重启就再也起不来。改为写临时文件 → 校验 → `mv` 原子替换，校验失败原配置分毫不动。
- 修复（高危）：`/etc/resolv.conf` 是符号链接时（Debian/Ubuntu 上 systemd-resolved 指向 `/run/systemd/resolve/stub-resolv.conf`），`>` 写入会穿透链接落到 tmpfs，重启全丢，`chattr` 也加在 tmpfs 上无效。新增 `unlink_resolv` 先记录原链接目标再替换为实体文件。
- 修复（高危）：`protect_dhcp` 用 `cat >` 无条件 truncate `/etc/dhcpcd.enter-hook`。这是系统级共享钩子，其他软件（NetworkManager / 云厂商 agent / 自定义 hook）写在这里的内容会被静默清空。改为追加写入并加 BEGIN/END 标记，便于精确撤销。
- 修复（高危）：验证失败只恢复 `/etc/resolv.conf`，但 `MANAGED_MARKER`、udhcpc 插桩、dhcpcd 钩子、systemd-resolved 停用状态全部保留。结果 DNS 恢复成 DHCP 下发的旧值，可这个旧值从此再也不会被 DHCP 更新——换机房、换子网、续租拿到新 DNS 全部失效且无任何报错。新增 `save_pre_state` / `rollback_changes` / `restore_dhcp_guards` 统一完整回滚。
- 修复（高危）：`--restore` 还原成不依赖本地 unbound 的静态 DNS 后，没有清理托管标记与 DHCP 保护，同样造成 DHCP 被永久屏蔽。现在同步撤销。
- 修复：`write_resolv` 最后一句是 `ok()`（恒为真），写入失败也返回 0，导致 `apply_dns` 里的回滚分支永远不会执行。改为失败返回非 0。
- 修复：没有中断保护。`apply_dns` 中途被 Ctrl+C / SSH 断开 / timeout 杀掉时，可能停在「unbound.conf 已换新、resolv.conf 还是旧值」的半成品态。新增 `trap 'on_interrupt' INT TERM`。
- 修复：`do-ip6: no` 写死，手动输入的 IPv6 上游能通过校验并写入 `forward-addr`，但 unbound 根本不会去连，必然 verify 失败回滚——README 宣称的 IPv6 支持实际不可用。现在按上游地址族动态生成。
- 修复：`valid_ip6` 的 `^[0-9A-Fa-f:]+$` 会放行 `:::::`、`12345::` 这类非法地址，同时拒绝 `::ffff:127.0.0.1`。改为按 8 组 / `::` 压缩一次的严格校验，只用 busybox awk 支持的内置函数（busybox 无 `rindex()`）。
- 新增：`--dry-run` 预演模式，只打印将写入的 `unbound.conf`、`resolv.conf` 与 DHCP 保护动作，不修改任何文件。

### v2.2.2（2026-08-31）

- 修复（高危）：`unbound` 只配置单个上游，节点下线后整机 DNS 全断且 unbound 仍显示 started。现在写入最快节点 + 最多 3 个备用上游。
- 修复（高危）：`--auto` 在本机 DNS 已断时无法下载 AKDNS 脚本（鸡生蛋死锁）。新增公共解析器取 IP + 直连兜底与 IP 缓存。
- 修复（高危）：`wait_dns_ready` 用 `grep [0-9]` 判断解析成功，而 dig 失败时会把含数字的错误文本写到 stdout，导致误判成功、自动回滚永不触发。改为过滤 `^;` 注释行并严格匹配整行 IP。
- 修复（高危）：dhcpcd 保护写入 `/etc/dhcpcd.enter-hooks.d`，该目录不被 `dhcpcd-run-hooks` 加载，保护静默失效。改用官方保证加载的 `/etc/dhcpcd.enter-hook` 设置 `skip_hooks`，并清理旧位置残留。
- 修复：非交互（`curl | sh`）时菜单 `read` 遇 EOF 不报错，造成无限刷屏死循环。新增 `require_tty` 守卫与 EOF 退出。
- 修复：容器缺少 `CAP_LINUX_IMMUTABLE` 时 `chattr +i` 返回 0 但未生效，脚本误报“已锁定”。现在用 `lsattr` 复核并如实警告。
- 修复：`restore_dns` 用 `ls -t` 选备份，同秒创建的备份 mtime 相同会退化为目录序而还原到最旧备份；改为按文件名时间戳倒序。
- 修复：`restore_dns` 分别取 resolv.conf 与 unbound.conf 的最新文件，跨时间点错配；改为按同一时间戳配对。
- 修复：0 字节备份会被还原成空 `resolv.conf` 并触发停止 unbound，导致 DNS 彻底中断；现在跳过空备份，全空时拒绝还原。
- 修复：`apply_dns` 验证失败时只调 `restore_dns`（会还原到上一次备份而非改动前状态），且未恢复 immutable 属性；现在先快照本次改动前的 resolv.conf 并完整回滚。
- 修复：`restart_unbound` 不确认服务真的起来（OpenRC stale 态下 restart 返回 0 但进程未启动）。新增 `unbound_running` 校验与二次重启兜底。
- 修复：`protect_dhcp` 改写 udhcpc 脚本时，文件末尾无换行会丢失最后一行（如 `exit 0`）。
- 新增：root 权限检查；手动输入支持 IPv6；`--restore` 后实测解析并提示；确认提示在 EOF 下默认拒绝而非静默应用。
- 修正：文件头注释版本号与 `VERSION` 不一致（2.2.0 / 2.2.1）。

### v2.2.1（2026-08-30）

- 修复：`--restore` 还原后若备份的 `resolv.conf` 仍指向本地 unbound（`127.0.0.1`），保持 unbound 运行并继续托管，避免出现“还原完成后 DNS 解析失败”的问题。
- 修复：仅当还原内容不依赖本地 unbound 时，才停止 unbound 并移除开机自启。
- README：菜单示例版本号与还原行为说明同步更新。

## 📄 License

MIT

## 🔗 相关链接

- AKDNS 官方项目：https://github.com/akile-network/aktools
- AKDNS 官方脚本：https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh
- 本项目：https://github.com/zhangweixy666/dns-setup
