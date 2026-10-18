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

# 回归测试：验证 v2.3.0 的 P0 修复是否真的生效
# 重点：每个断言都要能「在旧版上失败、在新版上通过」

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
grepq "版本号为 2.4.1" 'VERSION="2.4.1"'
grepq "头注释版本一致" '# 版本：2.4.1'
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

printf '\n=== 12. v2.3.1 覆盖链 ===\n'
grepq "NetworkManager drop-in" 'NetworkManager/conf.d/99-dns-setup.conf'
grepq "NM dns=none" 'dns=none'
grepq "NM rc-manager=unmanaged" 'rc-manager=unmanaged'
grepq "networkd drop-in" '99-dns-setup.conf'
grepq "networkd UseDNS=no" 'UseDNS=no'
grepq "resolvconf 支持" 'resolvconf.conf'
grepq "resolvconf name_servers" 'name_servers="127.0.0.1"'

printf '\n=== 13. v2.3.1 回滚完整性 ===\n'
grepq "回滚删除 NM 配置" 'nm_conf="/etc/NetworkManager'
grepq "回滚清理 resolvconf" 'tmp_rc='

printf '\n=== 14. v2.3.1 可配置项 ===\n'
grepq "CACHE_MIN_TTL 可覆盖" 'CACHE_MIN_TTL:-3600'
grepq "SCAN_TIMEOUT 可覆盖" 'SCAN_TIMEOUT'
grepq "SCAN_COUNT 可覆盖" 'SCAN_COUNT'
grepq "TTL 变量生效" 'cache-min-ttl: \$CACHE_MIN_TTL'

printf '\n=== 15. v2.3.1 日志 ===\n'
grepq "logfile 配置" 'logfile: "/var/log/unbound.log"'
grepq "日志权限处理" 'chown unbound:unbound'
grepq "无权限时降级" 'LOGFILE_LINES'
grepq "do-not-query-localhost" 'do-not-query-localhost: yes'

printf '\n=== 16. --uninstall ===\n'
grepq "uninstall_all 函数" '^uninstall_all() {'
grepq "uninstall 参数分支" '\-\-uninstall)'
grepq "uninstall 停服务" 'rc-service unbound stop'
grepq "uninstall 删自启" 'rc-update del unbound default'
grepq "uninstall 清标记" 'rm -f "\$MANAGED_MARKER"'
grepq "uninstall 恢复 resolved" 'systemctl enable --now systemd-resolved'
grepq "uninstall 公共DNS兜底" 'nameserver 1.1.1.1'
grepq "uninstall 后验证解析" 'wait_dns_ready; then'

printf '\n=== 17. 依赖安装确认 ===\n'
grepq "--yes 可跳过确认" 'ASSUME_YES=1'
grepq "装包前询问" '是否现在安装'
grepq "dry-run 不装包" 'DRY_RUN" -ne 1 \] && \[ "\$ASSUME_YES"'

printf '\n=== 18. 节点缓存降级 ===\n'
grepq "NODE_CACHE 定义" 'NODE_CACHE="\/var\/lib\/dns-setup\/nodes.cache"'
grepq "解析失败读缓存" '上次缓存'
grepq "成功后写缓存" '> "\$NODE_CACHE"'

printf '\n=== 19. 备份保留策略 ===\n'
grepq "BACKUP_KEEP 可配" 'BACKUP_KEEP:-10'
grepq "按时间戳裁剪" 'BACKUP_KEEP" -gt 0'
grepq "只动两类文件" 'for prefix in resolv.conf unbound.conf'

printf '\n=== 20. resolv.conf 保留 search ===\n'
grepq "提取 search/domain" 'search_lines='
grepq "写回 search" '"$search_lines"'
grepq "超时兜底 options" 'options timeout:1 attempts:2'

printf '\n=== 21. wget 兜底非死代码 ===\n'
grepq "wget 忽略证书" 'no-check-certificate'
grepq "wget 校验非空" '\[ -s "\$output" \] && return 0'
grepq "curl 分支校验非空" 'curl -fsSL.*return 0'
grepq "失败时清理空文件" 'rm -f "\$output"'

printf '\n=== 22. 显式 if 代替 A&&B||C ===\n'
if grep -q '\[ "\$http" = "200" \] &&' "$S"; then
    FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' '仍存在 A&&B||C 写法'
else
    PASS=$((PASS+1)); printf '  [PASS] %s\n' '已改为显式 if'
fi

printf '\n=== 23. read 均带 -r ===\n'
nr=$(grep -c 'read ' "$S")
nrr=$(grep -c 'read -r ' "$S")
bare=$(grep -n 'read ' "$S" | grep -v 'read -r' | grep -v '#' | wc -l)
if [ "$bare" = "0" ]; then
    PASS=$((PASS+1)); printf '  [PASS] %s\n' '所有 read 均带 -r'
else
    FAIL=$((FAIL+1)); printf '  [FAIL] %s（%d 处未带）\n' '存在未带 -r 的 read' "$bare"
fi

printf '\n----------------------------------------\n'
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
