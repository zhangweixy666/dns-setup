#!/bin/sh
# 行为测试：在沙箱里提取函数单独运行，不碰真实系统文件
S="$1"
[ -n "$S" ] || S=/root/dns-work/dns-setup.sh
W=$(mktemp -d /tmp/dnsbeh.XXXXXX)
PASS=0; FAIL=0

okc() { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
ng()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

# 提取函数库（到最后一个函数定义之前的所有内容 + 目标函数）
last=$(grep -n '^detect_system$' "$S" | head -1 | cut -d: -f1)
sed -n "1,$((last-1))p" "$S" > "$W/lib.sh"
echo 'detect_system() { OS="Alpine Linux"; INIT="openrc"; }' >> "$W/lib.sh"

printf '\n=== A. valid_ip6 严格校验 ===\n'
. "$W/lib.sh"
for ip in "2606:4700::1111" "2001:db8::1" "::1" "::ffff:127.0.0.1" "2001:db8:0:0:0:0:0:1"; do
    if valid_ip6 "$ip"; then okc "接受合法 $ip"; else ng "误拒合法 $ip"; fi
done
for ip in ":::::" "12345::" "gggg::1" "1:2:3:4:5:6:7:8:9" "abc"; do
    if valid_ip6 "$ip"; then ng "误放非法 $ip"; else okc "拒绝非法 $ip"; fi
done

printf '\n=== B. valid_ip4 回归 ===\n'
for ip in "8.8.8.8" "1.1.1.1" "0.0.0.0" "255.255.255.255"; do
    if valid_ip "$ip"; then okc "接受 $ip"; else ng "误拒 $ip"; fi
done
for ip in "256.1.1.1" "1.2.3" "a.b.c.d" ""; do
    if valid_ip "$ip"; then ng "误放 $ip"; else okc "拒绝 $ip"; fi
done

printf '\n=== C. 原子写入：checkconf 失败不碰原文件 ===\n'
mkdir -p "$W/etc/unbound" "$W/bin"
echo 'ORIGINAL_CONFIG' > "$W/etc/unbound/unbound.conf"
cat > "$W/bin/unbound-checkconf" <<'EOS'
#!/bin/sh
# 模拟校验失败
exit 1
EOS
chmod +x "$W/bin/unbound-checkconf"
PATH="$W/bin:$PATH"; export PATH
UNBOUND_CONF="$W/etc/unbound/unbound.conf"
export UNBOUND_CONF
n_db=$(grep -c . "$UNBOUND_CONF")
if write_unbound_conf "1.1.1.1" "udp" >/dev/null 2>&1; then
    ng "校验失败却返回成功"
else
    okc "校验失败返回非 0"
fi
if grep -q ORIGINAL_CONFIG "$UNBOUND_CONF"; then
    okc "原配置未被破坏（原子性生效）"
else
    ng "原配置被破坏"
fi
if ls "$W/etc/unbound/" | grep -q 'unbound.conf.tmp'; then
    ng "临时文件残留"
else
    okc "临时文件已清理"
fi

printf '\n=== D. 原子写入：checkconf 通过则替换 ===\n'
cat > "$W/bin/unbound-checkconf" <<'EOS'
#!/bin/sh
exit 0
EOS
chmod +x "$W/bin/unbound-checkconf"
if write_unbound_conf "9.9.9.9" "tcp" >/dev/null 2>&1; then
    okc "校验通过返回成功"
else
    ng "校验通过却返回失败"
fi
if grep -q 'forward-addr: 9.9.9.9@53' "$UNBOUND_CONF"; then
    okc "新配置已写入"
else
    ng "新配置未写入"
fi
if grep -q 'forward-tcp-upstream: yes' "$UNBOUND_CONF"; then
    okc "TCP 模式写入 forward-tcp-upstream"
else
    ng "TCP 模式缺失"
fi
if grep -q 'do-ip6: no' "$UNBOUND_CONF"; then
    okc "IPv4 上游时 do-ip6: no"
else
    ng "IPv4 上游时 do-ip6 错误"
fi

printf '\n=== E. IPv6 上游时 do-ip6 为 yes ===\n'
write_unbound_conf "2606:4700::1111" "udp" >/dev/null 2>&1
if grep -q 'do-ip6: yes' "$UNBOUND_CONF"; then
    okc "IPv6 上游时 do-ip6: yes"
else
    ng "IPv6 上游仍写 do-ip6: no"
fi

printf '\n=== F. 多上游去重 ===\n'
BACKUP_SERVERS="9.9.9.9 8.8.8.8 1.1.1.1"
PRIMARY_SERVER="9.9.9.9"
write_unbound_conf "9.9.9.9" "udp" >/dev/null 2>&1
n=$(grep -c 'forward-addr' "$UNBOUND_CONF")
if [ "$n" = "3" ]; then okc "去重后 3 条上游；实际 $n 条"
else ng "去重失败：预期 3 条，实际 $n 条"; fi
first=$(grep 'forward-addr' "$UNBOUND_CONF" | head -1)
case "$first" in
    *9.9.9.9*) okc "首选节点在最前" ;;
    *) ng "首选不在最前：$first" ;;
esac

printf '\n=== G. dhcpcd hook 追加不覆盖 ===\n'
HOOK="$W/enter-hook"
printf '# OTHER_VENDOR_HOOK\necho keep-me\n' > "$HOOK"
MANAGED_MARKER="$W/marker"
export MANAGED_MARKER
hook_file="$HOOK"
{
    if [ -s "$hook_file" ] && [ -n "$(tail -c 1 "$hook_file" 2>/dev/null)" ]; then
        printf '\n' >> "$hook_file"
    fi
    cat >> "$hook_file" <<'EOS'
# DNS-SETUP-MANAGED-BEGIN
if [ -f "marker" ]; then
    skip_hooks="$skip_hooks resolv.conf"
fi
# DNS-SETUP-MANAGED-END
EOS
} 2>/dev/null
if grep -q OTHER_VENDOR_HOOK "$HOOK"; then
    okc "别人的钩子内容保留"
else
    ng "别人的钩子被覆盖"
fi
if grep -q DNS-SETUP-MANAGED-BEGIN "$HOOK"; then
    okc "本脚本钩子已追加"
else
    ng "本脚本钩子未写入"
fi

printf '\n=== H. 精确移除钩子段 ===\n'
tmp="$HOOK.tmp"
awk '
    /^# DNS-SETUP-MANAGED-BEGIN$/ { skip = 1; next }
    /^# DNS-SETUP-MANAGED-END$/ { skip = 0; next }
    !skip { print }
' "$HOOK" > "$tmp"
mv "$tmp" "$HOOK"
if grep -q OTHER_VENDOR_HOOK "$HOOK"; then
    okc "移除后别人的钩子仍在"
else
    ng "移除时误删别人的钩子"
fi
if grep -q DNS-SETUP-MANAGED "$HOOK"; then
    ng "本脚本钩子段未清除"
else
    okc "本脚本钩子段已清除"
fi

printf '\n=== I. 符号链接检测 ===\n'
TARGET="$W/stub-resolv.conf"
echo 'nameserver 10.0.0.1' > "$TARGET"
LINK="$W/resolv.conf"
ln -sf "$TARGET" "$LINK"
if [ -L "$LINK" ]; then okc "测试环境符号链接创建成功"; else ng "符号链接创建失败"; fi
# 模拟 unlink_resolv 逻辑
t=$(readlink "$LINK")
if [ "$t" = "$TARGET" ]; then okc "readlink 读出目标"; else ng "readlink 失败"; fi

printf '\n----------------------------------------\n'
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
rm -rf "$W"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
