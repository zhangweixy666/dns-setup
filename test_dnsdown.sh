#!/bin/sh
# 终审：干净副本上验证 DNS 全断状态下的自救
S=/root/dns-final/dns-setup.sh
W=$(mktemp -d /tmp/final.XXXXXX)
PASS=0; FAIL=0
okc() { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
ng()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

last=$(grep -n '^download_text()' "$S" | head -1 | cut -d: -f1)
sed -n "1,$((last-1))p" "$S" > "$W/lib.sh"
. "$W/lib.sh"
RAW_HOST="raw.githubusercontent.com"
RAW_IP_CACHE="$W/raw_ip"
export RAW_HOST RAW_IP_CACHE

OUT="$W/out.sh"
if fetch_by_ip "$RAW_HOST" "https://raw.githubusercontent.com/akile-network/aktools/refs/heads/main/akdns.sh" "$OUT"; then
    okc "IP 直连下载成功"
    [ -s "$OUT" ] && okc "文件非空（$(wc -c < "$OUT") 字节）" || ng "文件为空"
    grep -q 'DNS_LIST' "$OUT" && okc "内容含 DNS_LIST" || ng "内容不含 DNS_LIST"
else
    ng "IP 直连下载失败"
fi

# 失败路径：不可达 IP 必须返回非 0 且不留空文件
OUT2="$W/out2.sh"
RAW_IP_CACHE="$W/raw_ip2"
if fetch_by_ip "nonexistent.invalid.example" "https://nonexistent.invalid.example/x" "$OUT2"; then
    ng "不可达主机却返回成功"
else
    okc "不可达主机返回失败"
    [ -f "$OUT2" ] && ng "失败后残留文件" || okc "失败后无残留文件"
fi

printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
rm -rf "$W"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
