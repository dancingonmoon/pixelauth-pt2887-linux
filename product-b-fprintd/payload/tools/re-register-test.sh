#!/bin/bash
# ============================================================================
# 「重新登记该手指」安全性测试 —— RED / GREEN 通用
#
# 背景（2026-09-30 事故）：GNOME 里对一枚已录手指点「重新登记该手指」时，
#   fprintd 1.94.3 会【先删掉这枚旧记录（连芯片槽位一起）】再去做去重检查；
#   检查一失败（按到别的手指）就中止 —— 旧的没了、新的又没录上。
#
# 本脚本复刻该流程并断言两件事：
#   A1  跑完之后 victim 手指【还在】列表里
#   A2  芯片【槽位数没变】（没有丢槽位）
#
#   未打补丁的 fprintd → 断言失败（victim 被删）← 这就是它抓到 bug 的证明（RED）
#   打过补丁的 fprintd → 断言通过（victim 幸存）← GREEN
#
# 用法：
#   ./re-register-test.sh <victim手指> <去按的手指> [--yes]
#   例： ./re-register-test.sh left-thumb right-index-finger
#
# ⚠️ 测试会【真的走一遍】这个流程 —— 在未打补丁的机器上 victim 会真的被删！
#    所以 victim 必须选【一次性测试手指】（别用日常在用的那几根）。
#
# ⚠️ 读芯片的坑：fprintd 被任何调用（包括 fprintd-list）唤醒后会【占住
#    USB 设备约 30 秒】，期间 pa_probe 读不到。所以本脚本：
#      · 先读芯片（基线）→ 再碰 fprintd
#      · 结束后的读芯片带重试（最多等 75 秒 fprintd 释放）
# ============================================================================
set -uo pipefail

VICTIM="${1:?用法: $0 <victim手指> <去按的手指> [--yes]}"
PRESS="${2:?用法: $0 <victim手指> <去按的手指> [--yes]}"
ASSUME_YES="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# 找芯片探针（开发目录在 probe/，产品包里在 tools/ 或同目录）
PROBE=""
for c in "$HERE/probe/pa_probe" "$HERE/tools/pa_probe" "$HERE/pa_probe" /usr/local/bin/pa_probe; do
    [ -x "$c" ] && { PROBE="$c"; break; }
done
[ -n "$PROBE" ] || { echo "❌ 找不到 pa_probe（芯片探针）" >&2; exit 1; }
PYTEST="$HERE/re-register-test.py"
USER_NAME="$(id -un)"
TS="$(date '+%F %T')"

# 读芯片占用槽位：先重试等到能读（fprintd 释放设备前会 BUSY），
# 再连读 2 次确认稳定（教训：写操作后的瞬时读数不可靠）
slots() {
    local deadline=$((SECONDS + 75)) out="" o2 i
    while [ $SECONDS -lt $deadline ]; do
        out=$("$PROBE" 1f 2>/dev/null | grep '占用槽位' | sed 's/.*占用槽位: *//; s/ *共.*//' || true)
        [ -n "$out" ] && break
        echo -n "." >&2
        sleep 5
    done
    for i in 1 2; do
        sleep 1
        o2=$("$PROBE" 1f 2>/dev/null | grep '占用槽位' | sed 's/.*占用槽位: *//; s/ *共.*//' || true)
        [ -n "$o2" ] && out="$o2"
    done
    case "$out" in ""|"(无)") echo "(无)" ;; *) echo "$out" ;; esac
}
slotcount() { local s; s="$(slots)"; [ "$s" = "(无)" ] && echo 0 || echo "$s" | wc -w; }

echo "============================================================"
echo " 「重新登记该手指」安全性测试"
echo "   victim（被重新登记的）: $VICTIM"
echo "   去按的手指            : $PRESS"
echo "   当前 fprintd          : $(dpkg-query -W -f'${Version}' fprintd 2>/dev/null)"
echo "============================================================"
case "$(dpkg-query -W -f'${Version}' fprintd 2>/dev/null)" in
    *+pa1*) echo "  （已打补丁 → 预期：victim 幸存 = GREEN）" ;;
    *)      echo "  （未打补丁 → 预期：victim 被删 = RED —— 这是有意的，测试就是抓它）" ;;
esac
echo

# --- 基线：先读芯片（还没碰 fprintd，设备通常空闲）---
echo "── 基线：芯片状态 ─────────────────────────────────────────"
[ -t 2 ] && echo "   （若出现点号是在等 fprintd 释放设备，最多 75 秒）"
BEFORE_S="$(slots)"
BEFORE="$(slotcount)"
echo "   占用槽位: $BEFORE_S   （共 $BEFORE 个）"

# --- 前置检查（这里才开始碰 fprintd）---
LIST="$(fprintd-list "$USER_NAME" 2>/dev/null || true)"
if ! grep -q ": ${VICTIM}\$" <<<"$LIST"; then
    echo "❌ $VICTIM 还没有录。先跑： fprintd-enroll -f $VICTIM" >&2
    echo "   现有指纹：" >&2
    sed 's/^/     /' <<<"$LIST" >&2
    exit 1
fi
if ! grep -q ": ${PRESS}\$" <<<"$LIST"; then
    echo "❌ $PRESS 不在列表里（去按的那根必须是已录的手指）" >&2
    exit 1
fi
echo

if [ "$ASSUME_YES" != "--yes" ]; then
    echo "⚠️  下一步会模拟「重新登记 $VICTIM」，期间让你去按【$PRESS】。"
    echo "    未打补丁时 $VICTIM 会被真的删掉（预期行为）。"
    read -r -p "    确认 $VICTIM 是【一次性测试手指】？(输入 yes 继续) " ans
    [ "$ans" = "yes" ] || { echo "已取消"; exit 1; }
fi

echo
echo "── 走流程（D-Bus，等价于 GNOME「重新登记该手指」）──────────"
python3 "$PYTEST" "$USER_NAME" "$VICTIM" "$PRESS"
RC=$?
if [ "$RC" != 0 ]; then
    echo "❌ 测试流程本身没跑起来（exit=$RC）—— 先排查环境再重试" >&2
    exit 2
fi

echo
echo "── 流程结束后：等 3 秒再读芯片（可能要等 fprintd 释放）───"
sleep 3
AFTER_S="$(slots)"
AFTER="$(slotcount)"
LIST2="$(fprintd-list "$USER_NAME" 2>/dev/null || true)"

A1=no; grep -q ": ${VICTIM}\$" <<<"$LIST2" && A1=yes
A2=no; [ "$AFTER" = "$BEFORE" ] && A2=yes

echo
echo "════════════════════════ 结果 ════════════════════════════"
if [ "$A1" = yes ]; then echo "   A1  victim 仍在列表里 : 是 ✅"; else echo "   A1  victim 仍在列表里 : 否 ❌（被删了）"; fi
if [ "$A2" = yes ]; then echo "   A2  芯片槽位数没变    : 是 ✅（$BEFORE → $AFTER）"; else echo "   A2  芯片槽位数没变    : 否 ❌（$BEFORE → $AFTER）"; fi
echo "        槽位明细: $AFTER_S"
echo
echo "── 证据（本次 fprintd 日志摘要）────────────────────────────"
journalctl -u fprintd --since "$TS" --no-pager 2>/dev/null \
    | grep -E 'Deleting enrolled|enroll-duplicate|start enrollment|identify:|delete:|目标槽位|enroll-failed' \
    | tail -20 | sed 's/^/     /'
echo

if [ "$A1" = yes ] && [ "$A2" = yes ]; then
    echo "   ★ 判定：GREEN —— victim 幸存。这正是打过补丁后应有的结果 ✓"
    exit 0
else
    echo "   ★ 判定：RED —— victim 被删。这正是【未打补丁】时应有的结果"
    echo "     （说明这个测试确实抓得住 bug ✓；装上补丁后重跑应为 GREEN）"
    exit 1
fi
