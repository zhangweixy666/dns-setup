# dns-setup

VPS 通用 DNS 配置工具，适用于 Alpine、Debian/Ubuntu 等 Linux VPS 和 Incus/LXC 容器。

脚本使用中文交互界面，自动下载 AKDNS 官方脚本读取当前节点列表，每个节点测试 2 次；UDP 不可用时自动改用 TCP。也支持手动输入任意 DNS 服务商地址，并通过 unbound 和 DHCP 防护避免 `/etc/resolv.conf` 被系统覆盖。

## 功能

- 中文交互菜单和中文状态提示。
- 自动下载：
  `https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh`
- 从 AKDNS 官方脚本动态读取 `DNS_LIST`，不在本项目中固定 AKDNS 节点。
- 每个节点分别测试 UDP 和 TCP，每种协议测试 2 次并计算平均延迟。
- UDP 有可用节点时优先使用最快 UDP。
- 所有 UDP 节点不可用时，自动选择最快 TCP，并由 unbound 的 `forward-tcp-upstream: yes` 强制转发。
- 手动输入任意 DNS 服务商的一个或多个 IPv4 地址。
- 使用 unbound 监听 `127.0.0.1:53`，让系统解析链路稳定。
- 自动备份当前 DNS 配置，支持还原。
- 支持 Alpine/openrc 和 Debian/Ubuntu/systemd。
- 处理 DHCP/网络管理器覆盖 DNS 的常见情况。

## DHCP 覆盖保护

Incus Alpine 容器常见链路：

```text
eth0 使用 DHCP
  -> udhcpc 常驻后台
  -> DHCP 续租或重新绑定
  -> /usr/share/udhcpc/default.script
  -> resolv_conf()
  -> DHCP 下发的 DNS 覆盖 /etc/resolv.conf
```

本脚本应用 DNS 后会：

1. 把 `/etc/resolv.conf` 指向 `127.0.0.1`。
2. 尝试对 `/etc/resolv.conf` 使用 `chattr +i`，阻止 DHCP 直接写入。
3. 在 Alpine 的 `/usr/share/udhcpc/default.script` 中加入托管标记判断，续租时跳过 `resolv_conf()`。
4. 如果检测到 `dhcpcd`，添加保护钩子。
5. 在 systemd 系统中停用 `systemd-resolved`，避免它和静态配置冲突。
6. unbound 注册为开机启动服务。

如果容器文件系统不支持 immutable 属性，脚本仍会保留 DHCP 脚本保护；运行输出会明确提示实际启用的保护方式。

## 快速开始

下载并运行中文交互菜单：

```sh
wget -qO /root/dns-setup.sh https://raw.githubusercontent.com/zhangweixy666/dns-setup/main/dns-setup.sh
chmod +x /root/dns-setup.sh
sh /root/dns-setup.sh
```

也可以直接运行自动模式：

```sh
wget -qO- https://raw.githubusercontent.com/zhangweixy666/dns-setup/main/dns-setup.sh | sh -s -- --auto
```

自动模式会执行：

```text
下载 AKDNS 官方脚本
  -> 读取 DNS_LIST
  -> 每节点测试 UDP/TCP 各 2 次
  -> UDP 可用则选择最快 UDP
  -> UDP 全部不可用则选择最快 TCP
  -> 写入 unbound
  -> 设置 /etc/resolv.conf 为 127.0.0.1
  -> 防止 DHCP 覆盖
  -> 验证解析和 GitHub 访问
```

## 菜单

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
```

### 1. 自动测速配置

从 AKDNS 官方脚本实时读取节点，不使用本项目内的固定节点列表。每个节点 UDP、TCP 各测试 2 次。

- UDP 有可用节点：选最快 UDP。
- UDP 全部失败、TCP 有可用节点：选最快 TCP。
- Alpine/musl 环境使用 unbound 强制 TCP，不依赖 `options use-vc`。

### 2. 手动配置

输入一个或多个 DNS IPv4 地址，例如：

```text
8.8.8.8 8.8.4.4
1.1.1.1 1.0.0.1
45.76.71.83
```

随后选择是否强制上游使用 TCP。若服务器的 UDP/53 被封锁，应选择 `y`。

### 3. 查看状态

查看：

- `/etc/resolv.conf`
- unbound 服务状态
- unbound 上游和协议
- DHCP 托管标记
- 文件 immutable 属性
- 当前域名解析结果

### 4. 还原 DNS

还原最近一次备份，并停止 unbound。备份目录：

```text
/var/lib/dns-setup/backup/
```

## 命令行参数

```sh
sh dns-setup.sh --auto
sh dns-setup.sh --status
sh dns-setup.sh --restore
```

## 配置文件

```text
/etc/unbound/unbound.conf
/etc/resolv.conf
/etc/dns-setup-managed
/var/lib/dns-setup/backup/
```

## 解析链路

UDP 正常时：

```text
系统程序 -> 127.0.0.1:53 -> unbound -> 上游 DNS:53/UDP
```

UDP 不通时：

```text
系统程序 -> 127.0.0.1:53 -> unbound -> 上游 DNS:53/TCP
```

本地程序访问 `127.0.0.1` 时显示 UDP 是正常的；`forward-tcp-upstream: yes` 控制的是 unbound 到外部上游的连接协议。

## 注意

- 需要 root 权限。
- 需要 VPS 能访问 GitHub raw；如果官方脚本无法下载，自动模式会停止，不会写入未知 DNS。
- DNS 节点的可用性会随网络、运营商和时间变化，每次自动模式都会重新读取并测速。
- 还原前会保留备份。
- 生产环境请先创建 VPS/容器快照。

## License

MIT

## 相关项目

- AKDNS：https://github.com/akile-network/aktools
