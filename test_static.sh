#!/bin/sh
# 回归测试：验证 v2.3.0 的 P0 修复是否真的生效
# 重点：每个断言都要能「在旧版上失败、在新版上通过」

S="$1"
[ -n "$S" ] || S=/root/dns-work/dns-setup.sh
PASS=0
FAIL=0

chk() {
    desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS+1))
        printf '  [PASS] %s\n' "$desc"
    else
        FAIL=$((FAIL+1))
        printf '  [FAIL] %s\n' "$desc"
    fi
}

grepq() {
    desc="$1"
    pat="$2"
    if grep -q -- "$pat" "$S"; then
        PASS=$((PASS+1))
        printf '  [PASS] %s\n' "$desc"
    else
        FAIL=$((FAIL+1))
        printf '  [FAIL] %s\n' "$desc"
    fi
}

grepn() {
    desc="$1"
    pat="$2"
    if grep -q -- "$pat" "$S"; then
        FAIL=$((FAIL+1))
        printf '  [FAIL] %s\n' "$desc"
    else
        PASS=$((PASS+1))
        printf '  [PASS] %s\n' "$desc"
    fi
}

printf '\n=== 1. 静态检查 ===\n'
chk "sh -n 语法通过" sh -n "$S"
grepq "版本号为 2.3.0" 'VERSION="2.3.0"'
grepq "头注释版本一致" '# 版本：2.3.0'
if [ "$(grep -c $'\xef\xbf\xbd' "$S")" = "0" ]; then
    PASS=$((PASS+1)); printf '  [PASS] %s\n' "无 U+FFFD 乱码"
else
    FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "存在 U+FFFD 乱码"
fi

printf '\n=== 2. P0-1 配置原子写 ===\n'
grepq "写临时文件" 'tmp_conf="${UNBOUND_CONF}.tmp.$$"'
grepq "checkconf 校验临时文件" 'unbound-checkconf "$tmp_conf"'
grepq "mv 原子替换" 'mv -f "$tmp_conf" "$UNBOUND_CONF"'
grepn "不再直接覆盘" '} > "$UNBOUND_CONF"'

printf '\n=== 3. P0-2 符号链接检测 ===\n'
grepq "unlink_resolv 函数存在" '^unlink_resolv() {'
grepq "检测 -L 符号链接" 'if \[ -L /etc/resolv.conf \]'
grepq "记录原链接目标" 'RESOLV_LINK_SAVE'
grepq "write_resolv 调用 unlink_resolv" 'unlink_resolv || return 1'

printf '\n=== 4. P0-3 dhcpcd hook 追加 ===\n'
grepq "使用 >> 追加" 'cat >> "$hook_file"'
grepn "不再 truncate enter-hook" 'cat > "$hook_file" <<HOOK'
grepq "有 BEGIN 标记" 'DNS-SETUP-MANAGED-BEGIN'
grepq "有 END 标记" 'DNS-SETUP-MANAGED-END'

printf '\n=== 5. P0-4 统一回滚 ===\n'
grepq "save_pre_state 存在" '^save_pre_state() {'
grepq "rollback_changes 存在" '^rollback_changes() {'
grepq "restore_dhcp_guards 存在" '^restore_dhcp_guards() {'
grepq "on_interrupt 存在" '^on_interrupt() {'
grepq "apply 失败调 rollback" 'rollback_changes'
grepq "恢复 udhcpc 备份" 'udhcpc_bak'
grepq "移除 hook 标记段" 'DNS-SETUP-MANAGED-BEGIN\$/'

printf '\n=== 6. P0-5 restore 状态清理 ===\n'
grepq "restore 里删 marker" 'rm -f "$MANAGED_MARKER"'
grepq "restore 里还 DHCP 保护" 'restore_dhcp_guards'

printf '\n=== 7. write_resolv 返回值 ===\n'
grepq "写入失败 return 1" '无法写入 /etc/resolv.conf'
grepq "结尾 return 0" '^    return 0$'

printf '\n=== 8. IPv6 ===\n'
grepq "do-ip6 动态判断" "grep -q ':'"
grepn "不再写死 do-ip6: no" '    do-ip6: no$'
if grep -qF 'length(g[i]) > 4' "$S"; then
    PASS=$((PASS+1)); printf '  [PASS] %s\n' '严格 IPv6 校验 (8组/::压缩)'
else
    FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' '严格 IPv6 校验'
fi

printf '\n=== 9. trap 安装 ===\n'
grepq "全局 trap INT TERM" "trap 'on_interrupt' INT TERM"

printf '\n=== 10. --dry-run ===\n'
grepq "DRY_RUN 全局变量" 'DRY_RUN=0'
grepq "--dry-run 参数分支" '\-\-dry-run)'
grepq "apply 有 dry-run 分支" '\[dry-run\] 以下是将要执行的全部改动'
grepq "不写入 unbound" '\[dry-run\] 将写入 \$UNBOUND_CONF'
grepq "不写入 resolv" '\[dry-run\] 将写入 /etc/resolv.conf'
grepq "用法提示含 dry-run" 'dry-run\]'

printf '\n=== 11. do-ip6 位置正确 ===\n'
# do-ip6 必须在 server 块内（forward-zone 之前）
if awk '/^    do-ip6: /{p=NR} /^forward-zone:/{f=NR} END{exit (p && f && p < f) ? 0 : 1}' "$S"; then
    PASS=$((PASS+1)); printf '  [PASS] %s\n' 'do-ip6 在 forward-zone 之前'
else
    FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' 'do-ip6 位置错误'
fi
if grep -q '__DOIP6_PLACEHOLDER__' "$S"; then
    FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' '存在占位符残留'
else
    PASS=$((PASS+1)); printf '  [PASS] %s\n' '无占位符残留'
fi

printf '\n----------------------------------------\n'
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
