#!/bin/sh
# 自动定位待测脚本：优先参数，次选脚本所在目录的上一级。
# 这样任何人 clone 下来都能直接跑，不依赖作者机器上的绝对路径。
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

S="${1:-$REPO/dns-setup.sh}"
if [ ! -f "$S" ]; then
    echo "找不到待测脚本：$S" >&2
    exit 2
fi

# 沙箱验证 uninstall 的备份选择逻辑（不碰真实系统）
W=$(mktemp -d /tmp/unsb.XXXXXX)
PASS=0; FAIL=0
okc() { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
ng()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

# 生成沙箱脚本：所有路径重定向到 $W
sed -e "s|/etc/resolv.conf|$W/resolv.conf|g" \
    -e "s|/var/lib/dns-setup|$W/lib|g" \
    -e "s|/etc/dns-setup-managed|$W/marker|g" \
    -e "s|/var/log|$W/log|g" \
    "$S" > "$W/sb.sh"

# 提取函数库
last=$(grep -n '^detect_system$' "$W/sb.sh" | head -1 | cut -d: -f1)
sed -n "1,$((last-1))p" "$W/sb.sh" > "$W/lib.sh"

mkdir -p "$W/lib/backup" "$W/bin"
echo 'nameserver 10.9.9.9' > "$W/resolv.conf"

# 制造多份备份：旧的静态、新的指向本地、空文件、非时间戳
printf 'nameserver 10.1.1.1\n' > "$W/lib/backup/resolv.conf.20260102-000002"
printf 'nameserver 127.0.0.1\n' > "$W/lib/backup/resolv.conf.20260105-000005"
: > "$W/lib/backup/resolv.conf.20260106-000006"
printf 'junk\n' > "$W/lib/backup/resolv.conf.unknown"

. "$W/lib.sh"
BACKUP_DIR="$W/lib/backup"
RESOLV_LINK_SAVE="$W/lib/resolink"
export BACKUP_DIR RESOLV_LINK_SAVE

printf '\n=== A. list_backups 严格过滤 ===\n'
n=$(list_backups resolv.conf | wc -l)
if [ "$n" = "3" ]; then okc "只返回 3 个合法时间戳（排除 unknown）"; else ng "返回 $n 个，预期 3"; fi
first=$(list_backups resolv.conf | head -1)
case "$first" in
    *20260106*) okc "倒序首项是最新备份" ;;
    *) ng "首项错误：$first" ;;
esac

printf '\n=== B. uninstall 选备份：跳过空与本地指向 ===\n'
found=""
for f in $(list_backups resolv.conf); do
    [ -s "$f" ] || continue
    if grep -qE '^[[:space:]]*nameserver[[:space:]]+(127\.0\.0\.1|::1)' "$f" 2>/dev/null; then
        continue
    fi
    found="$f"
    break
done
case "$found" in
    *20260102*) okc "正确选中 20260102（跳过空文件与指向本地）" ;;
    "") ng "未选中任何备份" ;;
    *) ng "选错：$found" ;;
esac

printf '\n=== C. 无可用备份时回落公共 DNS ===\n'
rm -f "$W/lib/backup"/*
: > "$W/resolv.conf"
for f in $(list_backups resolv.conf); do
    [ -n "$f" ] && break
done
if ! grep -qE '^[[:space:]]*nameserver' "$W/resolv.conf" 2>/dev/null; then
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$W/resolv.conf"
fi
if grep -q '1.1.1.1' "$W/resolv.conf"; then okc "空备份场景下写入公共 DNS 兜底"; else ng "未写兜底"; fi

printf '\n=== D. 解析失败用缓存降级 ===\n'
: > "$W/lib/nodes.cache"
printf '66.66.66.66 45.207.157.146\n' > "$W/lib/nodes.cache"
DNS_LIST=""
if [ -s "$W/lib/nodes.cache" ]; then
    DNS_LIST=$(cat "$W/lib/nodes.cache" 2>/dev/null)
fi
if [ -n "$DNS_LIST" ]; then okc "解析为空时读到缓存：$DNS_LIST"; else ng "缓存未生效"; fi

printf '\n----------------------------------------\n'
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
rm -rf "$W"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
