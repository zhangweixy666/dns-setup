#!/bin/sh
# dns-setup.sh - 通用 DNS 配置工具
# 版本：2.2.0
# 自动从 AKDNS 官方脚本读取节点；每个节点测速 2 次（节点间并发）
# 支持 Alpine/openrc、Debian/Ubuntu/systemd，防止 DHCP 覆盖 resolv.conf
# v2.2.0 新增：验证失败自动回滚、手动输入 IPv4 校验、并发测速、unbound.conf 一并还原

VERSION="2.2.1"
AKDNS_URL="https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh"
UNBOUND_CONF="/etc/unbound/unbound.conf"
BACKUP_DIR="/var/lib/dns-setup/backup"
MANAGED_MARKER="/etc/dns-setup-managed"
TEST_DOMAIN="www.google.com"
COUNT=2
TIMEOUT=1
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

download_text() {
    output="$1"
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$output" "$AKDNS_URL"
    else
        curl -fsSL "$AKDNS_URL" -o "$output"
    fi
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

    {
        cat <<'CONF'
server:
    interface: 127.0.0.1
    port: 53
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    access-control: 127.0.0.0/8 allow
    hide-identity: yes
    hide-version: yes
    prefetch: yes
    cache-min-ttl: 3600
    cache-max-ttl: 86400
    msg-cache-size: 16m
    msg-cache-slabs: 8
    rrset-cache-size: 32m
    rrset-cache-slabs: 8
    outgoing-num-tcp: 8
    infra-cache-min-rtt: 50
    infra-cache-max-rtt: 1000

forward-zone:
    name: "."
CONF
        if [ "$proto" = "tcp" ]; then
            printf '    forward-tcp-upstream: yes\n'
        fi
        for dns in $servers; do
            printf '    forward-addr: %s@53\n' "$dns"
        done
    } > "$UNBOUND_CONF"

    if ! unbound-checkconf "$UNBOUND_CONF" >/dev/null 2>&1; then
        err "unbound 配置检查失败："
        unbound-checkconf "$UNBOUND_CONF"
        return 1
    fi
    ok "unbound 配置已生成，协议：$proto，上游：$servers"
}

restart_unbound() {
    if [ "$INIT" = "openrc" ]; then
        rc-service unbound restart || rc-service unbound start
        rc-update add unbound default >/dev/null 2>&1 || true
    elif [ "$INIT" = "systemd" ]; then
        systemctl enable --now unbound
        systemctl restart unbound
    else
        err "无法识别 init 系统，不能自动启动 unbound。"
        return 1
    fi
}

write_resolv() {
    chattr -i /etc/resolv.conf 2>/dev/null || true
    printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
    touch "$MANAGED_MARKER"
    ok "系统 DNS 已指向本机 unbound：127.0.0.1"
}

protect_dhcp() {
    changed=0

    if chattr +i /etc/resolv.conf 2>/dev/null; then
        ok "已锁定 /etc/resolv.conf，防止 DHCP 覆盖。"
        changed=1
    else
        warn "当前容器不支持 chattr +i，将使用 DHCP 脚本保护。"
    fi

    udhcpc_script="/usr/share/udhcpc/default.script"
    if [ -f "$udhcpc_script" ]; then
        if ! grep -q 'DNS-SETUP-MANAGED' "$udhcpc_script"; then
            cp -p "$udhcpc_script" "${udhcpc_script}.dns-setup-bak"
            tmp="${udhcpc_script}.tmp.$$"
            in_func=0
            while IFS= read -r line; do
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
            mv "$tmp" "$udhcpc_script"
            chmod +x "$udhcpc_script"
            ok "已保护 udhcpc default.script，续租时不会覆写 DNS。"
            changed=1
        else
            ok "udhcpc default.script 已经受到保护。"
            changed=1
        fi
    fi

    if command -v dhcpcd >/dev/null 2>&1; then
        hook_dir="/etc/dhcpcd.enter-hooks.d"
        mkdir -p "$hook_dir"
        cat > "$hook_dir/50-dns-setup-protect" <<HOOK
# DNS-SETUP-MANAGED
[ -f "$MANAGED_MARKER" ] && make_resolv_conf() { :; }
HOOK
        ok "已添加 dhcpcd DNS 保护钩子。"
        changed=1
    fi

    if [ "$INIT" = "systemd" ] &&
        systemctl is-active systemd-resolved >/dev/null 2>&1; then
        systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
        ok "已停用 systemd-resolved，避免它覆盖 DNS。"
        changed=1
    fi

    [ "$changed" -eq 0 ] &&
        warn "没有发现可修改的 DHCP/DNS 管理器，仅完成 resolv.conf 写入。"
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

wait_dns_ready() {
    # 等待 unbound 准备好并能解析，最多 10 秒
    i=0
    while [ "$i" -lt 10 ]; do
        if dig @127.0.0.1 "$TEST_DOMAIN" +time=2 +tries=1 +short 2>/dev/null | grep -qE '[0-9]'; then
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
    backup_current || return 1
    write_unbound_conf "$servers" "$proto" || return 1
    if ! restart_unbound; then
        err "unbound 启动失败，正在还原最近备份..."
        restore_dns >/dev/null 2>&1
        return 1
    fi
    write_resolv || {
        warn "写入 resolv.conf 失败，自动还原最近备份..."
        restore_dns >/dev/null 2>&1
        return 1
    }
    protect_dhcp
    if ! verify_dns; then
        warn "DNS 验证失败，自动还原最近一次备份..."
        restore_dns >/dev/null 2>&1
        return 1
    fi
}

auto_configure() {
    ensure_deps || return 1
    load_akdns_nodes || return 1
    scan_dns || return 1

    printf "\n将使用 %s（%s）作为上游，确认应用？[Y/n] " \
        "$CHOSEN_SERVER" "$CHOSEN_PROTO"
    read confirm
    case "$confirm" in
        n|N) info "已取消。"; return 0 ;;
    esac

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
        if ! valid_ip "$ip"; then
            err "无效的 IPv4 地址：$ip（示例：8.8.8.8 8.8.4.4）"
            return 0
        fi
    done

    printf "是否强制上游使用 TCP？[y/N] "
    read force_tcp
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
    latest=$(ls -t "$BACKUP_DIR"/resolv.conf.* 2>/dev/null | head -1)
    if [ -z "$latest" ]; then
        err "没有找到可还原的 DNS 备份。"
        return 1
    fi

    chattr -i /etc/resolv.conf 2>/dev/null || true
    cp "$latest" /etc/resolv.conf || return 1

    # 同时还原 unbound 配置（与 resolv.conf 同时间点备份）
    latest_u=$(ls -t "$BACKUP_DIR"/unbound.conf.* 2>/dev/null | head -1)
    if [ -n "$latest_u" ] && [ -f "$UNBOUND_CONF" ]; then
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
    elif [ "$INIT" = "systemd" ]; then
        systemctl disable --now unbound >/dev/null 2>&1 || true
    fi
    ok "已还原 DNS：$latest"
    cat /etc/resolv.conf
}

menu() {
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
        read choice
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
case "${1:-}" in
    --auto)
        ensure_deps &&
        load_akdns_nodes &&
        scan_dns &&
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
    "")
        menu
        ;;
    *)
        printf "用法：%s [--auto|--status|--restore]\n" "$0"
        exit 2
        ;;
esac