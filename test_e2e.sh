#!/bin/sh
# 端到端故障注入：验证 checkconf 失败时生产配置不被破坏
S=/root/dns-work/dns-setup.sh
W=$(mktemp -d /tmp/dnse2e.XXXXXX)
PASS=0; FAIL=0
okc() { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
ng()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

# 备份真实生产配置
cp -p /etc/unbound/unbound.conf "$W/prod-unbound.bak"
md5_before=$(md5sum /etc/unbound/unbound.conf | cut -d' ' -f1)
echo "生产配置 md5: $md5_before"

# 构造一个「checkconf 一定失败」的场景：让脚本写到假路径 + 假 checkconf
# 用沙箱版脚本：把 UNBOUND_CONF 改成临时路径，checkconf 用失败桩
sed -e "s|/etc/unbound/unbound.conf|$W/unbound.conf|g" \
    -e "s|/etc/resolv.conf|$W/resolv.conf|g" \
    -e "s|/etc/dns-setup-managed|$W/marker|g" \
    "$S" > "$W/sandbox.sh"

mkdir -p "$W/bin"
printf '#!/bin/sh\nexit 1\n' > "$W/bin/unbound-checkconf"
chmod +x "$W/bin/unbound-checkconf"
echo 'PROD_ORIGINAL' > "$W/unbound.conf"
echo 'nameserver 10.9.9.9' > "$W/resolv.conf"

PATH="$W/bin:$PATH"; export PATH
cd "$W"

# 只调用 write_unbound_conf（不动 restat_unbound）
last=$(grep -n '^detect_system$' "$S" | head -1 | cut -d: -f1)
sed -n "1,$((last-1))p" "$W/sandbox.sh" > "$W/lib.sh"
. "$W/lib.sh"

write_unbound_conf "1.1.1.1" "udp" > /dev/null 2>&1
r=$?
if [ "$r" -ne 0 ]; then okc "checkconf 失败 -> 返回非 0 (rc=$r)"; else ng "checkconf 失败却返回 0"; fi
if grep -q PROD_ORIGINAL "$W/unbound.conf"; then okc "沙箱配置未被污染"; else ng "沙箱配置被污染"; fi

# 确认生产文件完全没动
md5_after=$(md5sum /etc/unbound/unbound.conf | cut -d' ' -f1)
if [ "$md5_before" = "$md5_after" ]; then
    okc "真实生产配置未被触达"
else
    ng "真实生产配置被改动！"
fi

printf '\n----------------------------------------\n'
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
rm -rf "$W"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
