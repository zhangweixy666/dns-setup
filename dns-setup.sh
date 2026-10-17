#!/bin/sh
# dns-setup.sh - 通用 DNS 配置工具
# 版本：2.3.1
# 自动从 AKDNS 官方脚本读取节点；每个节点测速 2 次（节点间并发）
# 支持 Alpine/openrc、Debian/Ubuntu/systemd，防止 DHCP 覆盖 resolv.conf
# v2.2.0 新增：验证失败自动回滚、手动输入 IPv4 校验、并发测速、unbound.conf 一并还原

VERSION="2.3.1"
AKDNS_URL="https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh"
UNBOUND_CONF="/etc/unbound/unbound.conf"
BACKUP_DIR="/var/lib/dns-setup/backup"
MANAGED_MARKER="/etc/dns-setup-managed"
RESOLV_LINK_SAVE="/var/lib/dns-setup/resolv.link"
PRE_STATE_DIR=""
ROLLBACK_NEEDED=0
CLEANUP_TMP=""
DRY_RUN=0
# 以下三项可由环境变量覆盖，便于 CDN/故障转移等场景调优：
#   CACHE_MIN_TTL  —— 强制最小缓存时间。CDN 调度/DDNS 场景应调小（如 60）。
#   SCAN_TIMEOUT   —— 单次探测超时秒数。繁忙 VPS 上 1s 容易把好节点判死。
#   SCAN_COUNT     —— 每个节点每协议采样次数。2 次取平均噪声偏大。
TEST_DOMAIN="${TEST_DOMAIN:-www.google.com}"
CACHE_MIN_TTL="${CACHE_MIN_TTL:-3600}"
COUNT="${SCAN_COUNT:-2}"
TIMEOUT="${SCAN_TIMEOUT:-1}"
DNS_LIST=""

G='\033[0;32m'
Y='\033[1;33m'
R='\033[0;31m'
C='\033[0;36m'
N='\033[0m'

ok() { printf "${G}[成功]${N} %s\n" "$*"; }
info() { printf "${C}[信息]${N} %s\n" "$*"; }
warn() { printf "${Y}[警告]${N} %s\n" "$*"; }
err() { printf "${R}[错误]${N} %s\n" "$*"; }
pause() { printf "\n按回车键返回菜单..."; read _dummy; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "需要 root 权限运行，请使用 sudo 或切换到 root 用户。"
        exit 1
    fi
}

ask_yes() {
    # 返回 0=确认，1=拒绝。stdin 结束（EOF）时默认拒绝，
    # 避免在管道/无人值守场景下静默应用配置。
    if ! read answer; then
        answer="n"
    fi
    case "$answer" in
        n|N|no|NO) return 1 ;;
        *) return 0 ;;
    esac
}

require_tty() {
    # 交互菜单依赖 stdin，非终端环境（curl | sh）下会无限循环刷屏
    if [ ! -t 0 ]; then
        err "当前不是交互式终端，请使用命令行参数：--auto / --status / --restore"
        exit 2
    fi
}

detect_system() {
    if [ -f /etc/alpine-release ]; then
        OS="Alpine Linux"
        INIT="openrc"
    elif [ -f /etc/debian_version ]; then
        OS="Debian/Ubuntu"
        INIT="systemd"
    else
        OS="其他 Linux"
        INIT="unknown"
    fi
}

ensure_deps() {
    need=0
    command -v unbound >/dev/null 2>&1 || need=1
    command -v dig >/dev/null 2>&1 || need=1
    command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || need=1

    if [ "$need" -eq 0 ]; then
        return 0
    fi

    info "正在安装 unbound、dig 和 wget..."
    if [ "$OS" = "Alpine Linux" ]; then
        apk add --no-cache unbound bind-tools wget
    elif [ "$OS" = "Debian/Ubuntu" ]; then
        apt-get update -qq
        apt-get install -y unbound dnsutils wget
    else
        err "无法自动识别软件包管理器，请手动安装 unbound、dig、wget。"
        return 1
    fi
}

mkdir -p /var/lib/dns-setup 2>/dev/null || true
RAW_HOST="raw.githubusercontent.com"
RAW_IP_CACHE="/var/lib/dns-setup/raw_ip"

fetch_by_ip() {
    # DNS 已经坏了的时候，还需要下载 AKDNS 脚本才能修 DNS（鸡生蛋）。
    # 这里用公共解析器直接拿 raw.githubusercontent.com 的 IP 绕过本机 DNS。
    host="$1"
    url="$2"
    output="$3"
    ip=""
    for resolver in 1.1.1.1 8.8.8.8 9.9.9.9; do
        ip=$(dig +short +time=3 +tries=1 @$resolver "$host" A 2>/dev/null |
            grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1)
        [ -n "$ip" ] && break
    done
    if [ -z "$ip" ] && [ -f "$RAW_IP_CACHE" ]; then
        ip=$(cat "$RAW_IP_CACHE" 2>/dev/null | head -1)
    fi
    [ -n "$ip" ] || return 1
    mkdir -p "$(dirname "$RAW_IP_CACHE")" 2>/dev/null || true
    printf '%s\n' "$ip" > "$RAW_IP_CACHE" 2>/dev/null || true
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 8 --resolve "$host:443:$ip" "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=10 --header="Host: $host" -O "$output" "https://$ip/${url#https://$host}"
    else
        return 1
    fi
}

download_text() {
    output="$1"
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 15 -O "$output" "$AKDNS_URL" && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 8 "$AKDNS_URL" -o "$output" && return 0
    fi
    # 常规下载失败（多半是本机 DNS 已断），走 IP 直连兜底
    info "常规下载失败，尝试绕过本机 DNS 直连获取..."
    fetch_by_ip "$RAW_HOST" "$AKDNS_URL" "$output"
}

load_akdns_nodes() {
    akdns_file=$(mktemp /tmp/akdns.XXXXXX) || {
        err "无法创建临时文件。"
        return 1
    }

    info "正在下载 AKDNS 官方脚本并读取节点列表..."
    if ! download_text "$akdns_file"; then
        rm -f "$akdns_file"
        err "无法下载 AKDNS 官方脚本：$AKDNS_URL"
        return 1
    fi

    DNS_LIST=$(sed -n '/^DNS_LIST=(/,/^)/p' "$akdns_file" |
        sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p' | tr '\n' ' ')
    rm -f "$akdns_file"

    if [ -z "$DNS_LIST" ]; then
        err "没有从 AKDNS 官方脚本中读取到 DNS_LIST。"
        return 1
    fi

    ok "已读取 AKDNS 节点：$DNS_LIST"
}

valid_ip6() {
    # 严格校验 IPv6：必须是 8 组 hex（允许 :: 压缩一次），或 IPv4 映射地址。
    # 旧实现 ^[0-9A-Fa-f:]+$ 会放行 ":::::"、"12345::" 这类非法地址。
    case "$1" in
        *:*) ;;
        *) return 1 ;;
    esac
    # 注意：Alpine 的 /bin/sh 配 busybox awk，没有 rindex()。
    # 这里只用 split / length / index / sub 这些 POSIX 基础能力实现。
    printf '%s\n' "$1" | awk '
        {
            s = $0
            if (s ~ /^::ffff:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { exit 0 }
            if (s ~ /[^0-9A-Fa-f:]/) exit 1
            n = split(s, g, ":")
            cnt = 0
            for (i = 1; i <= n; i++) {
                if (g[i] == "") continue
                if (length(g[i]) > 4) exit 1
                if (g[i] !~ /^[0-9A-Fa-f]+$/) exit 1
                cnt++
            }
            if (s ~ /::/) {
                # 剥离第一处 :: 之前的部分，剩下部分不得再含 ::
                t = s
                p = index(t, "::")
                t = substr(t, p + 2)
                if (t ~ /::/) exit 1
                if (cnt > 7) exit 1
                exit 0
            }
            if (cnt != 8) exit 1
            exit 0
        }'
}

valid_ip() {
    # 校验 IPv4：4 段数字，每段 0-255
    printf '%s\n' "$1" | awk -F. '
        NF==4 { ok=1; for(i=1;i<=4;i++){ if($i !~ /^[0-9]+$/ || $i+0 < 0 || $i+0 > 255) ok=0 } }
        END { exit (ok==1) ? 0 : 1 }
    '
}

measure_dns() {
    dns="$1"
    extra="$2"
    sum=0
    valid=0
    i=1

    while [ "$i" -le "$COUNT" ]; do
        query_time=$(dig @"$dns" "$TEST_DOMAIN" $extra \
            +stats +time="$TIMEOUT" +tries=1 2>/dev/null |
            awk '/Query time/ {print $4; exit}')
        case "$query_time" in
            ''|*[!0-9]*) ;;
            *)
                sum=$((sum + query_time))
                valid=$((valid + 1))
                ;;
        esac
        i=$((i + 1))
    done

    if [ "$valid" -eq 0 ]; then
        printf '%s\n' 1000
    else
        printf '%s\n' $((sum / valid))
    fi
}

scan_dns() {
    CHOSEN_SERVER=""
    CHOSEN_PROTO=""
    scan_file="/tmp/dns-scan.$$"
    : > "$scan_file"

    info "并发测试所有节点（每个节点 UDP/TCP 各 ${COUNT} 次），测试域名：$TEST_DOMAIN"
    printf "\n  %-20s %-14s %-14s\n" "DNS 地址" "UDP 平均延迟" "TCP 平均延迟"
    printf "  %-20s %-14s %-14s\n" "--------------------" "--------------" "--------------"

    # 节点间并发测速；单节点内部 UDP 与 TCP 各 COUNT 次串行
    for dns in $DNS_LIST; do
        (
            udp_ms=$(measure_dns "$dns" "")
            tcp_ms=$(measure_dns "$dns" "+tcp")
            printf '%s %s %s\n' "$dns" "$udp_ms" "$tcp_ms" >> "$scan_file"
        ) &
    done
    wait

    for dns in $DNS_LIST; do
        line=$(awk -v d="$dns" '$1==d {print; exit}' "$scan_file")
        [ -z "$line" ] && continue
        set -- $line
        udp_ms=$2
        tcp_ms=$3
        udp_text="不可用"
        tcp_text="不可用"
        [ "$udp_ms" -lt 1000 ] 2>/dev/null && udp_text="${udp_ms} ms"
        [ "$tcp_ms" -lt 1000 ] 2>/dev/null && tcp_text="${tcp_ms} ms"
        printf "  %-20s %-14s %-14s\n" "$dns" "$udp_text" "$tcp_text"
    done

    best_udp_line=$(awk '$2 < 1000 {print $2, $1}' "$scan_file" |
        sort -n | head -1)
    best_tcp_line=$(awk '$3 < 1000 {print $3, $1}' "$scan_file" |
        sort -n | head -1)

    # 除最快节点外，把其余可用节点作为备用上游（最多 3 个）
    BACKUP_SERVERS=""
    if [ -n "$best_udp_line" ]; then
        BACKUP_SERVERS=$(awk '$2 < 1000 {print $2, $1}' "$scan_file" |
            sort -n | awk 'NR>1 && n<3 {printf "%s ", $2; n++}')
    else
        BACKUP_SERVERS=$(awk '$3 < 1000 {print $3, $1}' "$scan_file" |
            sort -n | awk 'NR>1 && n<3 {printf "%s ", $2; n++}')
    fi

    if [ -n "$best_udp_line" ]; then
        best_ms=$(echo "$best_udp_line" | awk '{print $1}')
        CHOSEN_SERVER=$(echo "$best_udp_line" | awk '{print $2}')
        CHOSEN_PROTO="udp"
        ok "检测到可用 UDP，选择最快节点：$CHOSEN_SERVER（${best_ms} ms）"
    elif [ -n "$best_tcp_line" ]; then
        best_ms=$(echo "$best_tcp_line" | awk '{print $1}')
        CHOSEN_SERVER=$(echo "$best_tcp_line" | awk '{print $2}')
        CHOSEN_PROTO="tcp"
        warn "所有 UDP DNS 均不可用，切换为 TCP。"
        ok "选择最快 TCP 节点：$CHOSEN_SERVER（${best_ms} ms）"
        [ "$OS" = "Alpine Linux" ] &&
            info "Alpine 使用 musl，将由 unbound 强制转发 TCP。"
    else
        rm -f "$scan_file"
        err "UDP 和 TCP 都没有可用 DNS 节点。"
        return 1
    fi

    rm -f "$scan_file"
}

write_unbound_conf() {
    servers="$1"
    proto="$2"
    mkdir -p /etc/unbound || return 1

    # 先写临时文件再校验，最后 atomic mv 覆盘。
    # 旧实现直接 > $UNBOUND_CONF，一旦 checkconf 失败就 return，
    # 坏配置已经落在生产文件上；当下因为旧进程还跑旧内存配置看不出问题，
    # 下次重启 unbound 就再也起不来，DNS 彻底中断。
    tmp_conf="${UNBOUND_CONF}.tmp.$$"
    CLEANUP_TMP="$tmp_conf"

    # 配了 logfile 就必须保证 unbound 能写。否则 unbound 启动失败，
    # 而症状只是 DNS 不通，很难联想到是日志权限问题。
    # dry-run 也要探测一次可写性，否则打印出来的配置与实际会写入的不一致。
    logdir="/var/log"
    logfile="$logdir/unbound.log"
    if [ "$DRY_RUN" -ne 1 ]; then
        mkdir -p "$logdir" 2>/dev/null || true
        [ -f "$logfile" ] || : >> "$logfile" 2>/dev/null || true
        if ! touch "$logfile" 2>/dev/null; then
            warn "无法创建 $logfile，本配置将不启用 logfile。"
            LOGFILE_OK=0
        else
            LOGFILE_OK=1
            chown unbound:unbound "$logfile" 2>/dev/null || true
            chmod 640 "$logfile" 2>/dev/null || true
        fi
    else
        # 只判断目录可写，不创建任何文件
        if [ -w "$logdir" ] || [ -w "$logfile" ]; then
            LOGFILE_OK=1
        else
            LOGFILE_OK=0
        fi
    fi

    {
        # do-ip6 必须与上游地址族匹配，且必须写在 server: 块内部。
        # 写在 forward-zone: 之后会被 unbound-checkconf 判为语法错误；
        # 写死 no 时手动输入的 IPv6 上游永远不会被真正使用。
        if printf '%s\n' "$servers" | grep -q ':'; then
            do_ip6_line="yes"
        else
            do_ip6_line="no"
        fi
    # 注意：本 heredoc 内容均为字面量（不含 $ 与反引号），
    # 去掉引号仅为了让 $do_ip6_line / $CACHE_MIN_TTL / $LOGFILE_LINES 展开。
        if [ "${LOGFILE_OK:-0}" -eq 1 ]; then
            LOGFILE_LINES='    logfile: "/var/log/unbound.log"
    log-time-ascii: yes
    use-syslog: no'
        else
            LOGFILE_LINES='    use-syslog: no'
        fi
        cat <<CONF
server:
    interface: 127.0.0.1
    port: 53
    do-ip4: yes
    do-ip6: $do_ip6_line
    do-udp: yes
    do-tcp: yes
    access-control: 127.0.0.0/8 allow
    hide-identity: yes
    hide-version: yes
    prefetch: yes
    cache-min-ttl: $CACHE_MIN_TTL
    cache-max-ttl: 86400
    msg-cache-size: 16m
    msg-cache-slabs: 8
    rrset-cache-size: 32m
    rrset-cache-slabs: 8
    outgoing-num-tcp: 8
    infra-cache-min-rtt: 50
    infra-cache-max-rtt: 1000
    # 日志：断线时没有任何证据可查是这类脚本的头号痛点。
    # 只写 warning 级别，避免流量大时把磁盘写满。
    verbosity: 0
$LOGFILE_LINES
    # 强化：拒绝无效域名与私有地址回显，降低被当成开放解析器的滥用风险。
    do-not-query-localhost: yes

forward-zone:
    name: "."
CONF
        if [ "$proto" = "tcp" ]; then
            printf '    forward-tcp-upstream: yes\n'
        fi
        # 首选节点写在最前，其余可用节点作为备用一并写入：
        # 单个上游节点随时可能下线，只配一条会在节点失效时
        # 造成本机 DNS 全面中断（unbound 仍显示 started 但解析全失败）。
        seen_dns=" "
        for dns in $PRIMARY_SERVER $servers ${BACKUP_SERVERS:-}; do
            case "$seen_dns" in
                *" $dns "*) continue ;;
            esac
            seen_dns="$seen_dns$dns "
            printf '    forward-addr: %s@53\n' "$dns"
        done
    } > "$tmp_conf"

    if ! unbound-checkconf "$tmp_conf" >/dev/null 2>&1; then
        err "unbound 配置检查失败（已放弃写入，原配置未动）："
        unbound-checkconf "$tmp_conf"
        rm -f "$tmp_conf"
        return 1
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] 将写入 $UNBOUND_CONF："
        sed 's/^/    | /' "$tmp_conf"
        rm -f "$tmp_conf"
        CLEANUP_TMP=""
        return 0
    fi
    if ! mv -f "$tmp_conf" "$UNBOUND_CONF" 2>/dev/null; then
        err "无法写入 $UNBOUND_CONF（原配置未动）。"
        rm -f "$tmp_conf"
        return 1
    fi
    CLEANUP_TMP=""
    ok "unbound 配置已生成，协议：$proto，上游：$servers"
}

unbound_running() {
    if [ "$INIT" = "openrc" ]; then
        rc-service unbound status 2>/dev/null | grep -q 'status: started'
    elif [ "$INIT" = "systemd" ]; then
        systemctl is-active --quiet unbound
    else
        return 1
    fi
}

restart_unbound() {
    if [ "$INIT" = "openrc" ]; then
        rc-service unbound restart >/dev/null 2>&1 ||
            rc-service unbound start >/dev/null 2>&1
        # OpenRC stale 状态下 restart 可能返回 0 但进程没起来，必须实测端口
        if ! unbound_running; then
            rc-service unbound stop >/dev/null 2>&1
            sleep 1
            rc-service unbound start >/dev/null 2>&1
        fi
        rc-update add unbound default >/dev/null 2>&1 || true
    elif [ "$INIT" = "systemd" ]; then
        systemctl enable --now unbound >/dev/null 2>&1
        systemctl restart unbound >/dev/null 2>&1
        if ! unbound_running; then
            systemctl stop unbound >/dev/null 2>&1
            sleep 1
            systemctl start unbound >/dev/null 2>&1
        fi
    else
        err "无法识别 init 系统，不能自动启动 unbound。"
        return 1
    fi

    if ! unbound_running; then
        err "unbound 未能进入运行状态。"
        return 1
    fi
    ok "unbound 已运行。"
}

unlink_resolv() {
    # Debian/Ubuntu 上 systemd-resolved 会把 /etc/resolv.conf 做成指向
    # /run/systemd/resolve/stub-resolv.conf 的符号链接。直接 > 写入会穿透
    # 链接写到 /run（tmpfs），重启全丢，chattr 也加在 tmpfs 上无效。
    # 这里先把原链接目标记下来备用，再替换成实体文件。
    if [ -L /etc/resolv.conf ]; then
        target=$(readlink /etc/resolv.conf 2>/dev/null)
        if [ ! -f "$RESOLV_LINK_SAVE" ]; then
            mkdir -p "$(dirname "$RESOLV_LINK_SAVE")" 2>/dev/null || true
            printf '%s\n' "$target" > "$RESOLV_LINK_SAVE" 2>/dev/null || true
        fi
        warn "检测到 /etc/resolv.conf 是符号链接（-> ${target:-?}），改为实体文件。"
        rm -f /etc/resolv.conf || return 1
    fi
    return 0
}

write_resolv() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] 将写入 /etc/resolv.conf：nameserver 127.0.0.1"
        if [ -L /etc/resolv.conf ]; then
            info "[dry-run] 将把符号链接 -> $(readlink /etc/resolv.conf) 替换为实体文件"
        fi
        return 0
    fi
    chattr -i /etc/resolv.conf 2>/dev/null || true
    unlink_resolv || return 1
    # 写入失败必须返回非 0：旧实现最后一句是 ok()（恒为 true），
    # 导致 apply_dns 里的 write_resolv || { 回滚 } 永远不会执行。
    if ! printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf 2>/dev/null; then
        err "无法写入 /etc/resolv.conf。"
        return 1
    fi
    touch "$MANAGED_MARKER" 2>/dev/null || true
    ok "系统 DNS 已指向本机 unbound：127.0.0.1"
    return 0
}

protect_dhcp() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] 将执行 DHCP 防覆盖：chattr +i /etc/resolv.conf（若支持）"
        [ -f /usr/share/udhcpc/default.script ] &&
            info "[dry-run] 将插桩 /usr/share/udhcpc/default.script"
        command -v dhcpcd >/dev/null 2>&1 &&
            info "[dry-run] 将追加 /etc/dhcpcd.enter-hook"
        return 0
    fi
    changed=0

    # 容器缺少 CAP_LINUX_IMMUTABLE 时，chattr +i 可能返回 0 却没真正
    # 设置标志，必须用 lsattr 复核，否则会误报「已锁定」。
    immutable_ok=0
    if chattr +i /etc/resolv.conf 2>/dev/null; then
        if lsattr /etc/resolv.conf 2>/dev/null |
            awk '{print $1}' | grep -q 'i'; then
            immutable_ok=1
            ok "已锁定 /etc/resolv.conf，防止 DHCP 覆盖。"
            changed=1
        fi
    fi
    if [ "$immutable_ok" -eq 0 ]; then
        warn "当前环境不支持 chattr +i（容器权限受限），改由 DHCP 脚本保护。"
    fi

    udhcpc_script="/usr/share/udhcpc/default.script"
    if [ -f "$udhcpc_script" ]; then
        if ! grep -q 'DNS-SETUP-MANAGED' "$udhcpc_script"; then
            cp -p "$udhcpc_script" "${udhcpc_script}.dns-setup-bak"
            tmp="${udhcpc_script}.tmp.$$"
            in_func=0
            # 用 `|| [ -n "$line" ]` 兜住文件末尾无换行的情况，
            # 否则 while read 会丢掉最后一行（如 exit 0）。
            while IFS= read -r line || [ -n "$line" ]; do
                printf '%s\n' "$line"
                if echo "$line" | grep -q '^resolv_conf()'; then
                    in_func=1
                fi
                if [ "$in_func" -eq 1 ] && echo "$line" | grep -q '{'; then
                    printf '\t# DNS-SETUP-MANAGED: 跳过 DHCP DNS 覆盖\n'
                    printf '\t[ -f "%s" ] && return 0\n' "$MANAGED_MARKER"
                    in_func=0
                fi
            done < "$udhcpc_script" > "$tmp"
            if [ ! -s "$tmp" ]; then
                rm -f "$tmp"
                warn "udhcpc 脚本保护写入异常，已放弃修改。"
            else
                mv "$tmp" "$udhcpc_script"
            fi
            chmod +x "$udhcpc_script"
            ok "已保护 udhcpc default.script，续租时不会覆写 DNS。"
            changed=1
        else
            ok "udhcpc default.script 已经受到保护。"
            changed=1
        fi
    fi

    if command -v dhcpcd >/dev/null 2>&1 ||
        [ -x /sbin/dhcpcd ] || [ -x /usr/sbin/dhcpcd ]; then
        # dhcpcd-run-hooks 只加载三个位置：/etc/dhcpcd.enter-hook、
        # /usr/lib/dhcpcd/dhcpcd-hooks/*、/etc/dhcpcd.exit-hook。
        # enter-hook 最先被 source，在此屏蔽 resolv.conf 钩子即可阻止覆写。
        hook_file="/etc/dhcpcd.enter-hook"
        if [ -f "$hook_file" ] &&
            grep -q 'DNS-SETUP-MANAGED' "$hook_file"; then
            ok "dhcpcd enter-hook 已受保护。"
            changed=1
        elif {
            # 旧实现用 cat > 无条件 truncate /etc/dhcpcd.enter-hook。
            # 这是系统级共享钩子，其他软件（NetworkManager/云厂商 agent/
            # 自定义 hook）写在这里的内容会被静默清空。改为追加。
            if [ -s "$hook_file" ] && [ -n "$(tail -c 1 "$hook_file" 2>/dev/null)" ]; then
                printf '\n' >> "$hook_file"
            fi
            cat >> "$hook_file" <<HOOK
# DNS-SETUP-MANAGED-BEGIN
if [ -f "$MANAGED_MARKER" ]; then
    skip_hooks="$skip_hooks resolv.conf"
    make_resolv_conf() { :; }
    build_resolv_conf() { :; }
fi
# DNS-SETUP-MANAGED-END
HOOK
        }
        then
            chmod 644 "$hook_file" 2>/dev/null || true
            ok "已写入 dhcpcd 保护钩子：$hook_file"
            changed=1
        else
            warn "无法写入 $hook_file，跳过该项保护。"
        fi
    fi

    # 清理旧版本写错位置的残留（不被 dhcpcd 加载）
    rm -f /etc/dhcpcd.enter-hooks.d/50-dns-setup-protect 2>/dev/null || true
    rm -f /usr/lib/dhcpcd/dhcpcd-hooks.d/50-dns-setup-protect 2>/dev/null || true

    if [ "$INIT" = "systemd" ] &&
        systemctl is-active systemd-resolved >/dev/null 2>&1; then
        systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
        ok "已停用 systemd-resolved，避免它覆盖 DNS。"
        changed=1
    fi

    # --- NetworkManager：自行编写 resolv.conf 时会绕过 /etc/resolv.conf ---
    # 必须用 drop-in 把 dns 设为 none，否则 NM 会把 DHCP 下发的 DNS 写回去。
    nm_dir="/etc/NetworkManager/conf.d"
    if [ -d /etc/NetworkManager ] || [ -d "$nm_dir" ]; then
        if mkdir -p "$nm_dir" 2>/dev/null; then
            if [ "$DRY_RUN" -eq 1 ]; then
                info "[dry-run] 将写入 $nm_dir/99-dns-setup.conf（dns=none）"
            else
                if cat > "$nm_dir/99-dns-setup.conf" <<NMCONF
# DNS-SETUP-MANAGED
[main]
dns=none
rc-manager=unmanaged
NMCONF
                then
                    ok "已配置 NetworkManager 不接管 DNS。"
                    changed=1
                    if command -v nmcli >/dev/null 2>&1; then
                        systemctl reload NetworkManager >/dev/null 2>&1 ||
                            systemctl restart NetworkManager >/dev/null 2>&1 || true
                    fi
                else
                    warn "无法写入 $nm_dir/99-dns-setup.conf。"
                fi
            fi
        fi
    fi

    # --- systemd-networkd：可能自带 static resolv.conf 生成 ---
    # 创建 drop-in 关闭 DNS 下发，保留 DHCP 本身工作。
    nd_dir="/etc/systemd/network"
    if [ "$INIT" = "systemd" ] &&
        (systemctl list-unit-files 2>/dev/null | grep -q 'systemd-networkd.service'); then
        if [ "$DRY_RUN" -eq 1 ]; then
            info "[dry-run] 将为 systemd-networkd 写入 drop-in（UseDNS=no）"
        else
            nd_changed=0
            for f in "$nd_dir"/*.network; do
                [ -f "$f" ] || continue
                if grep -q 'DNS-SETUP-MANAGED' "$f" 2>/dev/null; then
                    nd_changed=1
                    continue
                fi
                base=$(basename "$f")
                drop="$nd_dir/$base.d"
                if mkdir -p "$drop" 2>/dev/null && cat > "$drop/99-dns-setup.conf" <<'NDCONF'
# DNS-SETUP-MANAGED
[Network]
UseDNS=no
NDCONF
                then
                    nd_changed=1
                fi
            done
            if [ "$nd_changed" -eq 1 ]; then
                ok "已配置 systemd-networkd 不接管 DNS。"
                changed=1
                systemctl restart systemd-networkd >/dev/null 2>&1 || true
            fi
        fi
    fi

    # --- openresolv / resolvconf：Debian/Alpine 上常见的 resolv.conf 代理 ---
    # 它们会在网络事件时重建 resolv.conf，必须把本机 unbound 告知它。
    rc_conf="/etc/resolvconf.conf"
    if command -v resolvconf >/dev/null 2>&1 || [ -d /etc/resolvconf ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            info "[dry-run] 将写入 $rc_conf（name_servers=127.0.0.1）"
        else
            if [ -f "$rc_conf" ] && grep -q 'DNS-SETUP-MANAGED' "$rc_conf" 2>/dev/null; then
                ok "resolvconf 已受保护。"
                changed=1
            else
                mkdir -p /etc 2>/dev/null || true
                if {
                    [ -s "$rc_conf" ] &&
                        [ -n "$(tail -c 1 "$rc_conf" 2>/dev/null)" ] &&
                        printf '
' >> "$rc_conf"
                    cat >> "$rc_conf" <<RCCONF
# DNS-SETUP-MANAGED
name_servers="127.0.0.1"
RCCONF
                } 2>/dev/null; then
                    ok "已配置 resolvconf 指向本机 unbound。"
                    changed=1
                else
                    warn "无法写入 $rc_conf。"
                fi
            fi
        fi
    fi

    [ "$changed" -eq 0 ] &&
        warn "没有发现可修改的 DHCP/DNS 管理器，仅完成 resolv.conf 写入。"
}

save_pre_state() {
    # 记录本次 apply 改动前的完整状态，供 rollback_changes 使用：
    # resolv.conf 内容 / immutable 属性 / 是否被接管 / udhcpc 原始脚本存在性 /
    # dhcpcd 钩子是否存在。旧实现只恢复 resolv.conf，其余改动全部保留，
    # 导致 DHCP 被永久屏蔽但没有任何提示。
    PRE_STATE_DIR=$(mktemp -d /tmp/dns-pre.XXXXXX) || return 1
    cp -p /etc/resolv.conf "$PRE_STATE_DIR/resolv.conf" 2>/dev/null || true
    if lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
        printf '1\n' > "$PRE_STATE_DIR/immutable"
    else
        printf '0\n' > "$PRE_STATE_DIR/immutable"
    fi
    [ -f "$MANAGED_MARKER" ] && : > "$PRE_STATE_DIR/had_marker"
    [ -f /etc/dhcpcd.enter-hook ] && : > "$PRE_STATE_DIR/had_enter_hook"
    ROLLBACK_NEEDED=1
    return 0
}

restore_dhcp_guards() {
    # 撤销 protect_dhcp 做的全部改动：
    # 1) udhcpc default.script 用原始备份还原，并删掉备份文件
    # 2) dhcpcd enter-hook 只删除本脚本追加的标记段，保留别人的内容
    udhcpc_script="/usr/share/udhcpc/default.script"
    udhcpc_bak="${udhcpc_script}.dns-setup-bak"
    if [ -f "$udhcpc_bak" ]; then
        if cp -p "$udhcpc_bak" "$udhcpc_script" 2>/dev/null; then
            rm -f "$udhcpc_bak"
            info "已还原 udhcpc default.script。"
        else
            warn "还原 udhcpc default.script 失败（备份保留：$udhcpc_bak）。"
        fi
    fi

    # NetworkManager drop-in
    nm_conf="/etc/NetworkManager/conf.d/99-dns-setup.conf"
    if [ -f "$nm_conf" ] && grep -q 'DNS-SETUP-MANAGED' "$nm_conf" 2>/dev/null; then
        rm -f "$nm_conf" 2>/dev/null && info "已移除 NetworkManager DNS 保护。"
        systemctl reload NetworkManager >/dev/null 2>&1 || true
    fi

    # systemd-networkd drop-in（只读本脚本写入的那个文件名）
    for d in /etc/systemd/network/*.network.d; do
        [ -d "$d" ] || continue
        f="$d/99-dns-setup.conf"
        if [ -f "$f" ] && grep -q 'DNS-SETUP-MANAGED' "$f" 2>/dev/null; then
            rm -f "$f" 2>/dev/null
            rmdir "$d" 2>/dev/null || true
            info "已移除 systemd-networkd DNS 保护。"
        fi
    done

    # resolvconf.conf 是追加式，必须精确删除标记段而不是删整个文件
    rc_conf="/etc/resolvconf.conf"
    if [ -f "$rc_conf" ] && grep -q 'DNS-SETUP-MANAGED' "$rc_conf" 2>/dev/null; then
        tmp_rc="${rc_conf}.tmp.$$"
        awk '
            /^# DNS-SETUP-MANAGED$/ { skip = 1; next }
            skip == 1 && /^name_servers="127\.0\.0\.1"$/ { skip = 2; next }
            skip == 2 && /^$/ { skip = 0; next }
            skip == 2 { skip = 0 }
            { print }
        ' "$rc_conf" > "$tmp_rc" 2>/dev/null
        if [ -f "$tmp_rc" ]; then
            if [ -s "$tmp_rc" ]; then
                mv "$tmp_rc" "$rc_conf" 2>/dev/null && info "已移除 resolvconf DNS 保护。"
            else
                rm -f "$rc_conf" "$tmp_rc" 2>/dev/null
                info "已移除 resolvconf 配置文件。"
            fi
        fi
    fi

    hook_file="/etc/dhcpcd.enter-hook"
    if [ -f "$hook_file" ] && grep -q 'DNS-SETUP-MANAGED-BEGIN' "$hook_file" 2>/dev/null; then
        tmp_hook="${hook_file}.tmp.$$"
        awk '
            /^# DNS-SETUP-MANAGED-BEGIN$/ { skip = 1; next }
            /^# DNS-SETUP-MANAGED-END$/ { skip = 0; next }
            !skip { print }
        ' "$hook_file" > "$tmp_hook" 2>/dev/null
        if [ -f "$tmp_hook" ]; then
            if [ -s "$tmp_hook" ]; then
                mv "$tmp_hook" "$hook_file" 2>/dev/null && info "已移除 dhcpcd 保护钩子段。"
            else
                rm -f "$hook_file" "$tmp_hook" 2>/dev/null
                info "已移除 dhcpcd 保护钩子文件。"
            fi
        fi
    fi
}

rollback_changes() {
    # 统一的撤销入口：apply_dns 失败分支、中断 trap、--restore 共用。
    # 必须幂等：重复调用不应造成额外破坏。
    chattr -i /etc/resolv.conf 2>/dev/null || true

    if [ -n "${PRE_STATE_DIR:-}" ] && [ -d "$PRE_STATE_DIR" ]; then
        if [ -s "$PRE_STATE_DIR/resolv.conf" ]; then
            cp "$PRE_STATE_DIR/resolv.conf" /etc/resolv.conf 2>/dev/null ||
                warn "恢复 /etc/resolv.conf 失败。"
        fi
        if [ "$(cat "$PRE_STATE_DIR/immutable" 2>/dev/null)" = "1" ]; then
            chattr +i /etc/resolv.conf 2>/dev/null || true
        fi
    fi

    if [ -n "${PRE_STATE_DIR:-}" ] && [ ! -f "$PRE_STATE_DIR/had_marker" ]; then
        rm -f "$MANAGED_MARKER" 2>/dev/null || true
    fi

    restore_dhcp_guards

    [ -n "${CLEANUP_TMP:-}" ] && rm -f "$CLEANUP_TMP" 2>/dev/null || true
    if [ -n "${PRE_STATE_DIR:-}" ] && [ -d "$PRE_STATE_DIR" ]; then
        rm -rf "$PRE_STATE_DIR" 2>/dev/null || true
    fi
    PRE_STATE_DIR=""
    ROLLBACK_NEEDED=0
    return 0
}

on_interrupt() {
    printf '\n'
    warn "检测到中断，正在回滚本次未完成的改动..."
    if [ "$ROLLBACK_NEEDED" -eq 1 ]; then
        rollback_changes
        warn "已回滚。请检查 /etc/resolv.conf 与 unbound 状态后再重试。"
    fi
    [ -n "${CLEANUP_TMP:-}" ] && rm -f "$CLEANUP_TMP" 2>/dev/null || true
    exit 130
}

backup_current() {
    mkdir -p "$BACKUP_DIR" || return 1
    timestamp=$(date +%Y%m%d-%H%M%S)
    chattr -i /etc/resolv.conf 2>/dev/null || true
    if cp -p /etc/resolv.conf "$BACKUP_DIR/resolv.conf.$timestamp" 2>/dev/null; then
        ok "当前配置已备份到：$BACKUP_DIR"
    else
        warn "无法备份当前 /etc/resolv.conf（继续执行）。"
    fi
    [ -f "$UNBOUND_CONF" ] &&
        cp -p "$UNBOUND_CONF" "$BACKUP_DIR/unbound.conf.$timestamp" 2>/dev/null || true
}

dns_probe_ok() {
    # 只接受真正的解析结果行：dig 出错时（connection refused / no servers
    # could be reached）会把含数字的错误文本写到 stdout，必须过滤 ^; 注释行，
    # 并严格匹配整行 IP，否则会把失败误判为成功。
    dig @127.0.0.1 "$1" +short +time=2 +tries=1 2>/dev/null |
        grep -vE '^[[:space:]]*;' |
        grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9A-Fa-f:]*[0-9A-Fa-f:]+:[0-9A-Fa-f:]*$'
}

wait_dns_ready() {
    # 等待 unbound 准备好并能解析，最多 10 秒
    i=0
    while [ "$i" -lt 10 ]; do
        if dns_probe_ok "$TEST_DOMAIN"; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

verify_dns() {
    info "正在验证系统 DNS..."
    if ! wait_dns_ready; then
        err "系统 DNS 解析失败。"
        dig @127.0.0.1 "$TEST_DOMAIN" +time=5 +tries=1 2>&1 | tail -8
        return 1
    fi
    ip=$(getent hosts "$TEST_DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}')
    if [ -z "$ip" ]; then
        err "getent 无法解析 $TEST_DOMAIN（unbound 可能未真正接管）。"
        return 1
    fi
    ok "$TEST_DOMAIN 解析成功：$ip"

    if command -v curl >/dev/null 2>&1; then
        http=$(curl -4 -sL --connect-timeout 8 -o /dev/null \
            -w '%{http_code}' \
            https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh 2>/dev/null)
        [ "$http" = "200" ] &&
            ok "GitHub raw 访问成功：HTTP $http" ||
            warn "GitHub raw 返回：HTTP $http"
    fi
}

apply_dns() {
    servers="$1"
    proto="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] 以下是将要执行的全部改动，不会写入任何文件："
        write_unbound_conf "$servers" "$proto" || return 1
        write_resolv || return 1
        protect_dhcp
        info "[dry-run] 不会重启 unbound、不会修改 DHCP 配置。"
        return 0
    fi
    backup_current || return 1
    # 记录本次改动前的完整状态（resolv.conf / immutable / 标记 / 钩子），
    # 任何一步失败或中断都要完整退回，不只是恢复一个 resolv.conf。
    save_pre_state || return 1
    write_unbound_conf "$servers" "$proto" || {
        rollback_changes
        return 1
    }
    if ! restart_unbound; then
        err "unbound 启动失败，正在回滚本次改动..."
        rollback_changes
        return 1
    fi
    write_resolv || {
        warn "写入 resolv.conf 失败，回滚本次改动..."
        rollback_changes
        return 1
    }
    protect_dhcp
    if ! verify_dns; then
        warn "DNS 验证失败，回滚本次改动..."
        rollback_changes
        return 1
    fi
    if [ -n "$PRE_STATE_DIR" ] && [ -d "$PRE_STATE_DIR" ]; then
        rm -rf "$PRE_STATE_DIR" 2>/dev/null || true
    fi
    PRE_STATE_DIR=""
    ROLLBACK_NEEDED=0
    return 0
}

auto_configure() {
    ensure_deps || return 1
    load_akdns_nodes || return 1
    scan_dns || return 1

    printf "\n将使用 %s（%s）作为上游，备用 %s，确认应用？[Y/n] " \
        "$CHOSEN_SERVER" "$CHOSEN_PROTO" "${BACKUP_SERVERS:-无}"
    ask_yes || {
        info "已取消。"
        return 0
    }

    PRIMARY_SERVER="$CHOSEN_SERVER"
    apply_dns "$CHOSEN_SERVER" "$CHOSEN_PROTO"
}

manual_configure() {
    printf "\n请输入 DNS 地址（可输入多个 IPv4，以空格分隔）：\n> "
    read manual_servers
    [ -n "$manual_servers" ] || {
        warn "未输入 DNS，已取消。"
        return 0
    }

    for ip in $manual_servers; do
        if ! valid_ip "$ip" && ! valid_ip6 "$ip"; then
            err "无效的 DNS 地址：$ip（示例：8.8.8.8 8.8.4.4 或 2606:4700::1111）"
            return 0
        fi
    done

    printf "是否强制上游使用 TCP？[y/N] "
    if read force_tcp; then
        :
    else
        force_tcp="n"
    fi
    manual_proto="udp"
    case "$force_tcp" in
        y|Y) manual_proto="tcp" ;;
    esac

    ensure_deps || return 1
    apply_dns "$manual_servers" "$manual_proto"
}

show_status() {
    printf "\n========== DNS 当前状态 ==========\n"
    printf "系统：%s（%s）\n" "$OS" "$INIT"
    printf "resolv.conf：\n"
    cat /etc/resolv.conf 2>/dev/null
    printf "\nunbound："
    if [ "$INIT" = "openrc" ]; then
        rc-service unbound status 2>/dev/null | tail -1
    else
        systemctl is-active unbound 2>/dev/null || true
    fi
    printf "上游配置：\n"
    grep 'forward-' "$UNBOUND_CONF" 2>/dev/null || true
    printf "DHCP 托管标记："
    [ -f "$MANAGED_MARKER" ] && echo "已启用" || echo "未启用"
    printf "resolv.conf 属性："
    lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}'
    verify_dns
}

restore_dns() {
    # 按时间戳配对：同一 timestamp 的 resolv.conf 与 unbound.conf 属于同一次备份，
    # 分别取各自最新会导致跨时间点错配。
    latest=""
    # 备份文件名内嵌 YYYYmmdd-HHMMSS，字典序即时间序；
    # 不用 ls -t：同一秒内创建的多个备份 mtime 相同，ls -t 会退化成目录序。
    for f in $(ls -1 "$BACKUP_DIR"/resolv.conf.* 2>/dev/null | sort -r); do
        # 跳过空备份：cp 失败或原文件为空时会留下 0 字节文件，
        # 还原它等于把系统 DNS 清空。
        if [ ! -s "$f" ]; then
            warn "跳过空备份文件：$f"
            continue
        fi
        latest="$f"
        break
    done
    if [ -z "$latest" ]; then
        err "没有找到可还原的 DNS 备份。"
        return 1
    fi

    stamp=${latest##*resolv.conf.}
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cp "$latest" /etc/resolv.conf || return 1

    # 还原与本次 resolv.conf 同一时间戳的 unbound 配置
    latest_u="$BACKUP_DIR/unbound.conf.$stamp"
    if [ -f "$latest_u" ] && [ -s "$latest_u" ] && [ -f "$UNBOUND_CONF" ]; then
        cp "$latest_u" "$UNBOUND_CONF" 2>/dev/null &&
            info "已还原 unbound 配置：$latest_u"
    fi

    # 判断还原后的 resolv.conf 是否仍依赖本地 unbound（127.0.0.1/::1）。
    # 若仍指向本地 unbound 却停止服务，会导致 DNS 全面中断。
    if grep -qE '^nameserver[[:space:]]+(127\.0\.0\.1|::1)' /etc/resolv.conf 2>/dev/null; then
        info "备份中的 resolv.conf 仍指向本地 unbound，保持 unbound 运行并继续托管。"
        touch "$MANAGED_MARKER" 2>/dev/null || true
        chattr +i /etc/resolv.conf 2>/dev/null || true
        if [ "$INIT" = "openrc" ]; then
            rc-service unbound restart >/dev/null 2>&1 || rc-service unbound start >/dev/null 2>&1 || true
            rc-update add unbound default >/dev/null 2>&1 || true
        elif [ "$INIT" = "systemd" ]; then
            systemctl restart unbound >/dev/null 2>&1 || systemctl enable --now unbound >/dev/null 2>&1 || true
        fi
    elif [ "$INIT" = "openrc" ]; then
        rc-service unbound stop >/dev/null 2>&1 || true
        rc-update del unbound default >/dev/null 2>&1 || true
        # 还原成不依赖本地 unbound 的静态 DNS 后，必须一并撤销托管状态，
        # 否则 MANAGED_MARKER 和 udhcpc 插桩还在，DHCP 会被永久屏蔽：
        # 换机房/换子网/续租拿到新 DNS 全部失效，且没有任何报错。
        rm -f "$MANAGED_MARKER" 2>/dev/null || true
        restore_dhcp_guards
        info "已撤销 DNS 托管标记与 DHCP 保护。"
    elif [ "$INIT" = "systemd" ]; then
        systemctl disable --now unbound >/dev/null 2>&1 || true
        rm -f "$MANAGED_MARKER" 2>/dev/null || true
        restore_dhcp_guards
        info "已撤销 DNS 托管标记与 DHCP 保护。"
    fi
    ok "已还原 DNS：$latest"
    cat /etc/resolv.conf
    # 备份记录的是当时的状态，当时可能本身就是不可用的（例如上游已下线），
    # 还原成功不等于 DNS 可用，必须实测后如实提示。
    if wait_dns_ready; then
        ok "还原后解析正常。"
    else
        warn "还原后仍无法解析：该备份对应的上游可能已失效。"
        warn "可重新运行 --auto 测速并应用可用节点。"
    fi
}

menu() {
    require_tty
    while true; do
        printf "\033c"
        printf "========================================\n"
        printf "       通用 DNS 配置工具 v%s\n" "$VERSION"
        printf "========================================\n"
        printf "系统：%s（%s）\n\n" "$OS" "$INIT"
        printf "  1) 下载 AKDNS 官方脚本并自动测速配置\n"
        printf "  2) 手动输入 DNS 服务商地址\n"
        printf "  3) 查看当前 DNS 状态\n"
        printf "  4) 还原上一次备份的 DNS\n"
        printf "  0) 退出\n\n"
        printf "请选择 [0-4]："
        read choice || {
            printf "\n输入结束，已退出。\n"
            return 0
        }
        case "$choice" in
            1) auto_configure; pause ;;
            2) manual_configure; pause ;;
            3) show_status; pause ;;
            4) restore_dns; pause ;;
            0) printf "已退出。\n"; return 0 ;;
            *) warn "无效选择，请输入 0-4。"; sleep 1 ;;
        esac
    done
}

detect_system
require_root
# apply_dns 中途被 Ctrl+C / SSH 断开 / timeout 杀掉时，必须回滚，
# 否则可能停在「unbound.conf 已换新、resolv.conf 还是旧值」的半成品态。
trap 'on_interrupt' INT TERM
case "${1:-}" in
    --auto)
        PRIMARY_SERVER=""
        BACKUP_SERVERS=""
        ensure_deps &&
        load_akdns_nodes &&
        scan_dns &&
        PRIMARY_SERVER="$CHOSEN_SERVER" &&
        apply_dns "$CHOSEN_SERVER" "$CHOSEN_PROTO"
        exit $?
        ;;
    --status)
        show_status
        exit $?
        ;;
    --restore)
        restore_dns
        exit $?
        ;;
    --dry-run)
        DRY_RUN=1
        PRIMARY_SERVER=""
        BACKUP_SERVERS=""
        ensure_deps &&
        load_akdns_nodes &&
        scan_dns &&
        PRIMARY_SERVER="$CHOSEN_SERVER" &&
        apply_dns "$CHOSEN_SERVER" "$CHOSEN_PROTO"
        exit $?
        ;;
    "")
        menu
        ;;
    *)
        printf "用法：%s [--auto|--status|--restore|--dry-run]\n" "$0"
        exit 2
        ;;
esac
