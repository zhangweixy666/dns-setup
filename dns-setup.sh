#!/bin/sh
# dns-setup.sh - Universal DNS forwarder with DHCP protection
# Version: 1.3.0

VERSION="1.3.0"
UNBOUND_CONF="/etc/unbound/unbound.conf"
BACKUP_DIR="/var/lib/dns-setup/backup"
MANAGED_MARKER="/etc/dns-setup-managed"
TEST_DOMAIN="github.com"
DEFAULT_SERVERS="45.76.71.83 45.76.83.113 45.207.157.146 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 9.9.9.9 208.67.222.222 114.114.114.114"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
ok(){ printf "${G}[OK]${N} %s\n" "$*"; }
info() { printf "${C}[INFO]${N} %s\n" "$*"; }
warn() { printf "${Y}[WARN]${N} %s\n" "$*"; }
err()  { printf "${R}[ERR]${N}  %s\n" "$*"; }
pause() { printf "\nPress Enter to continue..."; read _dummy; }

# ── detect OS ────────────────────────────────────────────────────
detect_system() {
    if [ -f /etc/alpine-release ]; then
        OS=alpine; INIT=openrc
    elif [ -f /etc/debian_version ]; then
        OS=debian; INIT=systemd
    else
        OS=other; INIT=unknown
    fi
}

# ── install deps ─────────────────────────────────────────────────
ensure_deps() {
    local need=0
    command -v unbound >/dev/null 2>&1 || need=1
    command -v dig >/dev/null 2>&1 || need=1
    if [ $need -eq 1 ]; then
        info "Installing unbound + dig..."
        if [ "$OS" = "alpine" ]; then
            apk add --no-cache unbound bind-tools 2>&1 | grep -E '(Installing|OK:|error)' || true
        elif [ "$OS" = "debian" ]; then
            apt-get install -y -qq unbound dnsutils 2>&1 | tail -3
        fi
    fi
}

# ── test one server: outputs "udp=NNN tcp=NNN" (NNN=ms or fail) ──
test_server() {
    local s="$1" u="fail" t="fail" ms
    ms=$(dig +time=3 +tries=1 @"$s" "$TEST_DOMAIN" 2>&1 | awk '/Query time/{print $4}')
    [ -n "$ms" ] && u="$ms"
    ms=$(dig +time=3 +tries=1 +tcp @"$s" "$TEST_DOMAIN" 2>&1 | awk '/Query time/{print $4}')
    [ -n "$ms" ] && t="$ms"
    printf "udp=%s tcp=%s" "$u" "$t"
}

# ── scan candidates, set CHOSEN_SERVER and CHOSEN_PROTO ──────────
auto_scan() {
    CHOSEN_SERVER=""
    CHOSEN_PROTO=""
    local best_ms=99999

    info "Scanning DNS servers..."
    printf "\n  %-20s  %-14s  %-14s\n" "Server" "UDP (ms)" "TCP (ms)"
    printf "  %-20s  %-14s  %-14s\n" "--------------------" "--------------" "--------------"

    for s in $DEFAULT_SERVERS; do
        result=$(test_server "$s")
        u=$(echo "$result" | sed 's/udp=\([^ ]*\).*/\1/')
        t=$(echo "$result" | sed 's/.*tcp=\([^ ]*\)/\1/')

        u_label="fail"
        t_label="fail"
        [ "$u" != "fail" ] && u_label="${u} ms✓"
        [ "$t" != "fail" ] && t_label="${t} ms  ✓"
        printf "  %-20s  %-14s  %-14s\n" "$s" "$u_label" "$t_label"

        # prefer UDP over TCP
        if [ "$u" != "fail" ]; then
            if [ "$u" -lt "$best_ms" ] 2>/dev/null; then
                best_ms=$u
                CHOSEN_SERVER=$s
                CHOSEN_PROTO=udp
            fi
        elif [ "$t" != "fail" ]; then
            if [ "$t" -lt "$best_ms" ] 2>/dev/null; then
                best_ms=$t
                CHOSEN_SERVER=$s
                CHOSEN_PROTO=tcp
            fi
        fi
    doneprintf "\n"

    if [ -z "$CHOSEN_SERVER" ]; then
        err "No reachable DNS server found."
        return 1
    fi
    ok "Best: $CHOSEN_SERVER  proto: $CHOSEN_PROTO  latency: ${best_ms}ms"
}

# ── write unbound.conf ────────────────────────────────────────────
write_unbound_conf() {
    local servers="$1" proto="$2"
    mkdir -p /etc/unbound

    {
        cat <<'CONF_HEAD'
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

forward-zone:
    name: "."
CONF_HEADif [ "$proto" = "tcp" ]; then
            printf "    forward-tcp-upstream: yes\n"fi

        for s in $servers; do
            printf "    forward-addr: %s@53\n" "$s"
        done
    } > "$UNBOUND_CONF"

    if ! unbound-checkconf "$UNBOUND_CONF" >/dev/null 2>&1; then
        err "unbound config validation failed:"
        unbound-checkconf "$UNBOUND_CONF"
        return 1
    fi
    ok "unbound.conf written  servers: $servers  proto: $proto"
}

# ── start/restart unbound ─────────────────────────────────────────
restart_unbound() {
    if [ "$INIT" = "openrc" ]; then
        rc-service unbound restart 2>&1 | grep -E 'ok|!!' || true
        rc-update add unbound default >/dev/null 2>&1 || true
    elif [ "$INIT" = "systemd" ]; then
        systemctl restart unbound
        systemctl enable unbound >/dev/null 2>&1 || true
    fi
}

# ── write resolv.conf ─────────────────────────────────────────────
write_resolv() {
    chattr -i /etc/resolv.conf 2>/dev/null || true
    printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
    touch "$MANAGED_MARKER"
    ok "resolv.conf -> nameserver 127.0.0.1"
}

# ── protect resolv.conf from DHCP overwrite ───────────────────────
protect_dhcp() {
    local changed=0

    # 1. immutable bit
    if chattr +i /etc/resolv.conf 2>/dev/null; then
        ok "chattr +i applied (immutable lock)"
        changed=1
    else
        warn "chattr unavailable; falling back to script-level protection"
    fi

    # 2. patch Alpine udhcpc default.script
    local udhcpc_script="/usr/share/udhcpc/default.script"
    if [ -f "$udhcpc_script" ]; then
        if ! grep -q 'DNS-SETUP-MANAGED' "$udhcpc_script"; then
            cp -p "$udhcpc_script" "${udhcpc_script}.dns-setup-bak"
            local tmp="${udhcpc_script}.tmp.$$"
            local in_func=0
            while IFS= read -r line; do
                printf '%s\n' "$line"
                if echo "$line" | grep -q '^resolv_conf()'; then
                    in_func=1
                fiif [ $in_func -eq 1 ] && echo "$line" | grep -q '^{'; then
                    printf '\t# DNS-SETUP-MANAGED: skip DHCP DNS overwrite\n'
                    printf '\t[ -f "%s" ] && return 0\n' "$MANAGED_MARKER"
                    in_func=0
                fi
            done < "$udhcpc_script" > "$tmp"
            mv "$tmp" "$udhcpc_script"
            chmod +x "$udhcpc_script"
            ok "udhcpc default.script patched - DHCP DNS overwrite blocked"
            changed=1
        else
            ok "udhcpc script already patched"
            changed=1
        fi
    fi

    # 3. dhcpcd hook
    if command -v dhcpcd >/dev/null 2>&1; then
        local hook_dir="/etc/dhcpcd.enter-hooks.d"
        mkdir -p "$hook_dir"
        cat > "$hook_dir/50-dns-setup-protect" <<HOOK
# DNS-SETUP-MANAGED
[ -f "$MANAGED_MARKER" ] && make_resolv_conf() { :; }
HOOK
        ok "dhcpcd hook installed"
        changed=1
    fi

    # 4. disable systemd-resolved if present
    if [ "$INIT" = "systemd" ] && systemctl is-active systemd-resolved >/dev/null 2>&1; then
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        ok "systemd-resolved disabled"
        changed=1
    fi

    [ $changed -eq 0 ] && warn "No DHCP protection applied (no known client found)"
}

# ── verify ────────────────────────────────────────────────────────
verify() {
    info "Verifying DNS resolution..."
    sleep 1
    local ip
    ip=$(getent hosts "$TEST_DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$ip" ]; then
        ok "getent hosts $TEST_DOMAIN -> $ip"
    else
        err "System resolver failed for $TEST_DOMAIN"
        dig @127.0.0.1 "$TEST_DOMAIN" +time=5 +tries=1 2>&1 | tail -8
        return 1
    fi
    local http
    http=$(curl -4 -sL --connect-timeout 8 -o /dev/null -w '%{http_code}' \
        https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh 2>/dev/null)
    if [ "$http" = "200" ]; then
        ok "GitHub raw: HTTP 200"
    else
        warn "GitHub raw: HTTP $http"
    fi
}

# ── backup ────────────────────────────────────────────────────────
backup_current() {
    mkdir -p "$BACKUP_DIR"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cp /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.${ts}" 2>/dev/null || true
    [ -f "$UNBOUND_CONF" ] && cp "$UNBOUND_CONF" "${BACKUP_DIR}/unbound.conf.${ts}" 2>/dev/null || true
    ok "Backup saved to $BACKUP_DIR (*.$ts)"
}

# ── restore ───────────────────────────────────────────────────────
restore_dns() {
    local latest
    latest=$(ls -t "${BACKUP_DIR}/resolv.conf."* 2>/dev/null | head -1)
    if [ -z "$latest" ]; then
        err "No backup found in $BACKUP_DIR"
        pause
        return 1
    fi
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cp "$latest" /etc/resolv.conf
    rm -f "$MANAGED_MARKER"
    if [ "$INIT" = "openrc" ]; then
        rc-service unbound stop 2>/dev/null || true
        rc-update del unbound default 2>/dev/null || true
    elif [ "$INIT" = "systemd" ]; then
        systemctl stop unbound 2>/dev/null || true
        systemctl disable unbound 2>/dev/null || true
    fi
    ok "Restored from $latest"
    cat /etc/resolv.confpause
}

# ── show status ───────────────────────────────────────────────────
show_status() {
    local svc_status attr proto upstream
    if [ "$INIT" = "openrc" ]; then
        svc_status=$(rc-service unbound status 2>/dev/null | grep -oE 'started|stopped' || echo unknown)
    else
        svc_status=$(systemctl is-active unbound 2>/dev/null || echo unknown)
    fi
    attr=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')
    upstream=$(grep 'forward-addr' "$UNBOUND_CONF" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    proto="UDP (default)"
    grep -q 'forward-tcp-upstream: yes' "$UNBOUND_CONF" 2>/dev/null && proto="TCP forced"
    grep -q 'forward-tls-upstream: yes' "$UNBOUND_CONF" 2>/dev/null && proto="DoT (TLS 853)"

    local ip
    ip=$(getent hosts "$TEST_DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)

    printf "\n  ╔════════════════════════════════════╗\n"
    printf   "  ║  DNS Setup Status v%-5s          ║\n" "$VERSION"
    printf   "  ╠════════════════════════════════════╣\n"
    printf   "  ║  OS: %-22s  ║\n" "$OS ($INIT)"
    printf   "  ║  resolv    : %-22s  ║\n" "$(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
    printf   "  ║  immutable : %-22s  ║\n" "$attr"
    printf   "  ║  managed   : %-22s  ║\n" "$([ -f "$MANAGED_MARKER" ] && echo yes || echo no)"
    printf   "  ║  unbound   : %-22s  ║\n" "$svc_status"
    printf   "  ║  protocol  : %-22s  ║\n" "$proto"
    printf   "  ║  upstream  : %-22s  ║\n" "${upstream:-(none)}"
    printf   "  ║  $TEST_DOMAIN : %-22s  ║\n" "${ip:-(resolve failed)}"
    printf   "  ╚════════════════════════════════════╝\n\n"
    pause
}

# ── auto configure ────────────────────────────────────────────────
auto_configure() {
    ensure_deps
    auto_scan || { pause; return 1; }

    printf "\n  Apply: %s via %s? [Y/n]: " "$CHOSEN_SERVER" "$CHOSEN_PROTO"
    read confirm
    case "$confirm" in
        n|N) info "Cancelled."; pause; return;;
    esac

    backup_current
    write_unbound_conf "$CHOSEN_SERVER" "$CHOSEN_PROTO" || { pause; return 1; }
    restart_unbound
    write_resolv
    protect_dhcp
    verify
    printf "\n"
    ok "Done. Upstream: $CHOSEN_SERVER ($CHOSEN_PROTO) via unbound @ 127.0.0.1"
    pause
}

# ── manual configure ──────────────────────────────────────────────
manual_configure() {
    printf "\n  Enter DNS server IPs (space-separated):\n"
    printf "  e.g. 8.8.8.8 1.1.1.1 45.76.71.83\n  > "
    read user_servers
    if [ -z "$user_servers" ]; then
        warn "Cancelled."
        pause
        return
    fi

    printf "\n  Force TCP upstream? [y/N]: "
    read ft
    local proto=udp
    case "$ft" in y|Y) proto=tcp ;; esac

    ensure_deps
    backup_current
    write_unbound_conf "$user_servers" "$proto" || { pause; return 1; }
    restart_unbound
    write_resolv
    protect_dhcp
    verify
    ok "Done."
    pause
}

# ── main ──────────────────────────────────────────────────────────
detect_system

case "$1" in
    --auto)
        ensure_deps
        auto_scan || exit 1
        backup_current
        write_unbound_conf "$CHOSEN_SERVER" "$CHOSEN_PROTO" || exit 1
        restart_unbound
        write_resolv
        protect_dhcp
        verify
        ok "Done. Upstream: $CHOSEN_SERVER ($CHOSEN_PROTO) via unbound @ 127.0.0.1"
        exit 0
        ;;
    --status)  show_status; exit ;;
    --restore) restore_dns; exit ;;
esac

while true; do
    clear
    printf "\n  ╔══════════════════════════════════════╗\n"
    printf   "  ║  DNS Setup  v%-5s                   ║\n" "$VERSION"
    printf   "  ║System: %-28s  ║\n" "$OS ($INIT)"
    printf   "  ╠══════════════════════════════════════╣\n"
    printf   "  ║  1) Auto-detect best DNS and apply   ║\n"
    printf   "  ║  2) Manually enter DNS server(s)     ║\n"
    printf   "  ║  3) Show current status              ║\n"
    printf   "  ║  4) Restore original DNS             ║\n"
    printf   "  ║  0) Exit                             ║\n"
    printf   "  ╚══════════════════════════════════════╝\n\n"
    printf   "  Choose [0-4]: "
    read choice
    case "$choice" in
        1) auto_configure ;;
        2) manual_configure ;;
        3) show_status ;;
        4) restore_dns ;;
        0) exit 0 ;;
        *) warn "Invalid choice"; sleep 1 ;;
    esac
done
