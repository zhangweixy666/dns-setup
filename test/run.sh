#!/bin/sh
# 统一测试入口：依次运行全部套件。
# 用法：
#   sh test/run.sh              # 测仓库根的 dns-setup.sh
#   sh test/run.sh /path/to/x.sh

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
TARGET="${1:-$REPO/dns-setup.sh}"

if [ ! -f "$TARGET" ]; then
    echo "找不到待测脚本：$TARGET" >&2
    exit 2
fi

echo "========================================"
echo " 测试目标: $TARGET"
echo " 仓库根:   $REPO"
echo "========================================"

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_SUITES=""

for f in "$HERE"/test_*.sh; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    case "$name" in
        test_static.sh) desc="静态断言" ;;
        test_behavior.sh) desc="沙箱行为" ;;
        test_e2e.sh) desc="故障注入" ;;
        test_uninstall.sh) desc="卸载沙箱" ;;
        test_dnsdown.sh) desc="DNS全断自救" ;;
        *) desc="未知" ;;
    esac
    printf '\n>>> [%s] %s\n' "$desc" "$name"
    out=$(sh "$f" "$TARGET" 2>&1)
    rc=$?
    p=$(printf '%s\n' "$out" | sed -n 's/.*PASS=\([0-9]*\).*/\1/p' | tail -1)
    q=$(printf '%s\n' "$out" | sed -n 's/.*FAIL=\([0-9]*\).*/\1/p' | tail -1)
    [ -n "$p" ] || p=0
    [ -n "$q" ] || q=0
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + q))
    if [ "$rc" -ne 0 ]; then
        FAILED_SUITES="$FAILED_SUITES $name"
        printf '%s\n' "$out" | grep -E '\[FAIL\]' || true
    fi
    printf '    PASS=%s FAIL=%s\n' "$p" "$q"
done

echo ""
echo "========================================"
echo " 合计: PASS=$TOTAL_PASS  FAIL=$TOTAL_FAIL"
if [ -n "$FAILED_SUITES" ]; then
    echo " 失败套件:$FAILED_SUITES"
    echo "========================================"
    exit 1
fi
echo " 全部通过"
echo "========================================"
exit 0
