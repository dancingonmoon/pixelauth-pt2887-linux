#!/usr/bin/env bash
# ============================================================================
# 产品 B 体检 —— fprintd 那条链路（锁屏 / 登录界面 / sudo）
#
# 用法：   ./checkup.sh              # 人看的报告
#         ./checkup.sh --quiet      # 只输出失败项与汇总（给脚本调用）
# 退出码： 0 = 没有失败项；1 = 有失败项
#
# 覆盖：TOD 驱动 / fprintd（含重登记修复补丁）/ 芯片侧（索引与记录一致性）/ sudo 接线 / 麒麟退役状态
#
# ★ 与产品 A 的 checkup 的区别：那份以"麒麟栈"为中心（查守护进程、麒麟账本），
#   麒麟退役之后那些检查全是过时的。这份只认 fprintd。
# ============================================================================

set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); [ "$QUIET" = 1 ] || echo "  ✅ $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $*"; }
warn() { WARN=$((WARN+1)); [ "$QUIET" = 1 ] || echo "  ⚠️  $*"; }
info() { [ "$QUIET" = 1 ] || echo "      $*"; }
sec()  { [ "$QUIET" = 1 ] || { echo; echo "$*"; }; }

VID=2f0a; PID=8020
TOD_DIR=/usr/lib/x86_64-linux-gnu/libfprint-2/tod-1
TOD_SO="${TOD_DIR}/libpixelauth_pt2887.so"
HELPER=/usr/local/bin/fp-earlypass-helper
PYBIN=/usr/local/lib/fp-earlypass
U="${SUDO_USER:-${USER:-$(id -un)}}"

[ "$QUIET" = 1 ] || {
echo "============================================================"
echo " 产品 B 体检（fprintd 链路）    $(date '+%F %T')    $(hostname)"
echo "============================================================"
}

# ============================================================ 0
sec "[0] 硬件与内核"
if lsusb -d "${VID}:${PID}" >/dev/null 2>&1; then
    ok "指纹模组在线（${VID}:${PID}）"
else
    bad "指纹模组不在线 —— 检查排线/电源键；换个 USB 口；lsusb 看有没有 2f0a:8020"
fi

if [ -r /sys/module/8250/parameters/nr_uarts ]; then
    NR=$(cat /sys/module/8250/parameters/nr_uarts)
    NTTY=$(ls -d /sys/class/tty/*/device 2>/dev/null | wc -l)
    info "nr_uarts=${NR}  带 /device 的 tty 数=${NTTY}  预计枚举值=$((NTTY*22+9))（上限 256）"
    if [ "$NR" = "2" ] && [ "$NTTY" -le 6 ]; then
        ok "内核参数 8250.nr_uarts=2 生效"
    elif grep -q '8250.nr_uarts=2' /etc/default/grub 2>/dev/null; then
        bad "内核参数【已配置但未生效】—— 多半是【还没重启】"
    else
        bad "内核参数未配置 —— 跑 install_integration 或手工：GRUB_CMDLINE_LINUX 里加 8250.nr_uarts=2 + update-grub + 重启"
    fi
else
    warn "读不到 8250 参数（需要 root，或内核没加载该模块）"
fi

# ============================================================ 1
# ★ 顺序：芯片侧检查必须在碰 fprintd 之前 —— `fprintd-list` 会把 fprintd 拉起来
#   并让它占住 USB 设备（而且持续约 30 秒），那之后探针就读不到芯片了。
sec "[1] 芯片侧（索引与记录的一致性）"
#   这一节是 2026-09-29/30 两次"指纹莫名失效"换来的：
#     · 有索引没记录 → 芯片认不出
#     · 有记录没索引 → 同样没用（索引被删掉了）
PROBE=""
for c in "$(dirname "$0")/pa_probe" "$(dirname "$0")/tools/pa_probe" /usr/local/bin/pa_probe; do
    [ -x "$c" ] && { PROBE="$c"; break; }
done
if [ -z "$PROBE" ]; then
    warn "没找到 pa_probe，跳过芯片侧检查（源码在 payload/tools/pa_probe.c，可现场编译）"
else
    IDX_LINE=$("$PROBE" 1f 2>/dev/null | grep '占用槽位' || true)
    if [ -z "$IDX_LINE" ]; then
        warn "读不到芯片索引表 —— 多半是设备正被占用。等 30 秒（fprintd 会自动释放）再跑，或 sudo systemctl stop fprintd"
    else
        IDX=$(printf '%s\n' "$IDX_LINE" | sed 's/.*占用槽位: *//; s/ *共.*//')
        case "$IDX" in ""|"(无)") IDX="" ;; esac
        if [ -z "$IDX" ]; then
            warn "芯片索引是空的 —— 芯片里一枚模板都没有（新机器/换机器时正常）"
            info "录指纹：fprintd-enroll -f right-index-finger"
        else
            ok "芯片索引：占用槽位 ${IDX}"
            for s in $IDX; do
                addr=$(( s * 0x40 ))
                ah=$(printf '%02x' $(( addr >> 8 ))); al=$(printf '%02x' $(( addr & 0xff )))
                rec=$("$PROBE" a6 "$ah" "$al" 00 40 2>/dev/null | grep 'payload' | sed 's/.*payload *([^)]*) *//' || true)
                data="${rec:10:64}"
                case "$data" in
                    "")         warn "槽位 ${s}：读不到记录" ;;
                    fffffffff*) bad  "槽位 ${s}：★ 有索引但记录是空的 —— 芯片认不出，这枚用不了" ;;
                    333333333*) bad  "槽位 ${s}：★ 记录是 0x33 占位符（旧驱动「只录不写 a5」留下的）—— 用不了" ;;
                    *)          ok   "槽位 ${s}：记录正常（${data:0:16}…）" ;;
                esac
            done
        fi
    fi
fi

# ============================================================ 2
sec "[2] fprintd 与 TOD 驱动"
if [ -f "$TOD_SO" ]; then
    ok "TOD 驱动已装：$(basename "$TOD_SO")（$(stat -c%s "$TOD_SO") 字节）"
else
    bad "TOD 驱动没装 —— 跑本产品的 install.sh"
fi
FPVER=$(dpkg-query -W -f'${Version}' fprintd 2>/dev/null || echo "")
case "$FPVER" in
    *+pa1*)
        ok "fprintd 已打「重新登记」修复补丁（$FPVER）" ;;
    "")
        : ;;   # 没装 fprintd 的情况由下面那段报
    *)
        warn "fprintd 是原版（$FPVER）—— GNOME「重新登记该手指」按错手指会毁数据"
        info "打补丁： sudo ./payload/fprintd-patch/install-fprintd-patched.sh apply（README 4.6 节）" ;;
esac
if ! command -v fprintd-list >/dev/null 2>&1; then
    bad "fprintd 未安装 —— sudo apt install fprintd libpam-fprintd"
else
    if fprintd-list "$U" >/dev/null 2>&1; then
        N=$(fprintd-list "$U" 2>/dev/null | grep -c ' - #')
        if [ "$N" -gt 0 ]; then
            ok "用户 $U 在 fprintd 里有 ${N} 枚指纹"
            fprintd-list "$U" 2>/dev/null | grep ' - #' | sed 's/^/        /'
        else
            bad "fprintd 里一条记录都没有 —— 录指纹：fprintd-enroll -f right-index-finger"
        fi
    else
        warn "fprintd-list 执行失败（设备可能被占用，或 fprintd 没起来）"
    fi
fi

# ============================================================ 2b
#  2026-10-01 实踩：补丁只装了 fprintd、漏装 libpam-fprintd → 后者依赖
#  「fprintd (= 1.94.3-1)」悬空 → apt 报「已损坏个数 > 0」，所有更新
#  （含安全更新、unattended）全部装不上。这节把「版本族一致 + apt 可解算」查住。
sec "[2b] apt 依赖完整性（补丁必须两包同版本）"
PAMVER=$(dpkg-query -W -f'${Version}' libpam-fprintd 2>/dev/null || echo "")
if [ -z "$FPVER$PAMVER" ]; then
    warn "fprintd / libpam-fprintd 未装，跳过本节"
else
    info "fprintd=$FPVER  libpam-fprintd=$PAMVER"
    case "$FPVER" in
        *+pa1*)
            case "$PAMVER" in
                *+pa1*) ok "libpam-fprintd 与 fprintd 同版本族（都是 +pa1）" ;;
                *)      bad "★ fprintd 已打补丁但 libpam-fprintd 没同步（$PAMVER）—— apt 会报「已损坏个数 > 0」，全部更新装不上"
                        info "修复：sudo ./payload/fprintd-patch/install-fprintd-patched.sh apply" ;;
            esac ;;
        *)
            case "$PAMVER" in
                *+pa1*) warn "libpam-fprintd 是补丁版但 fprintd 不是 —— 版本不一致" ;;
                *)      ok "两包均为原版（未打补丁）" ;;
            esac ;;
    esac
    if apt-get -s upgrade >/dev/null 2>&1; then
        ok "apt 解算正常（无未满足依赖）"
    else
        bad "apt 解算失败 —— 有未满足依赖（补丁族版本不一致最可能是元凶）"
        info "看详情：apt-get -s upgrade 2>&1 | tail -5"
    fi
fi

# ============================================================ 3
sec "[3] sudo 接线"
if [ -x "$HELPER" ]; then
    OWNER=$(stat -c '%U' "$HELPER")
    [ "$OWNER" = root ] && ok "PAM 助手在（root:root）" \
                        || bad "PAM 助手属主是 ${OWNER}，必须是 root（提权风险）"
    if grep -q 'fprintd-verify' "$HELPER" 2>/dev/null; then
        ok "助手是 0.3.0 单进程版（当前形态）"
        if grep -q -- '-f any' "$HELPER" 2>/dev/null; then
            ok "助手带 -f any（sudo 认全部已录手指）"
        else
            warn "助手缺 -f any —— sudo 只认列表第一根手指（其余静默回退密码）"
        fi
        [ -f "${PYBIN}/fpearlypass/run.py" ] && ok "助手 Python 包在（${PYBIN}/fpearlypass）" \
                                            || bad "助手 Python 包缺失 —— 重跑 install.sh"
    else
        warn "助手不是 0.3.0 单进程版（可能是旧的 pam-biometric-exec.sh）—— 重跑 install.sh"
    fi
else
    bad "PAM 助手缺失 —— 跑本产品的 install.sh"
fi
for s in sudo sudo-i; do
    if grep -qF 'fp-earlypass-helper' "/etc/pam.d/$s" 2>/dev/null; then
        grep -qE '^auth +sufficient +pam_exec\.so +stdout +/usr/local/bin/fp-earlypass-helper$' "/etc/pam.d/$s" \
            && ok "/etc/pam.d/$s 已接线（sufficient ✓）" \
            || warn "/etc/pam.d/$s 接线不是 sufficient（指纹成功也会再要密码）"
    else
        bad "/etc/pam.d/$s 缺少指纹行 —— 见 docs 的安装章节"
    fi
done

# ============================================================ 4
sec "[4] 麒麟退役状态"
# 麒麟在跑 = 芯片记录有被它删掉的风险（它的同步会删"不在它库里"的记录）
if systemctl is-active --quiet biometric-authentication.service 2>/dev/null; then
    warn "麒麟守护进程还在跑 —— 它每次被调用都会删掉「不在它库里」的芯片记录"
    info "安全起见建议停掉（sudo systemctl disable --now biometric-authentication）"
    info "停掉后 sudo 会走 fprintd（本产品的助手），不再依赖麒麟"
else
    ok "麒麟已停（当前形态：全部走 fprintd）"
fi

# ============================================================ 汇总
echo
echo "============================================================"
echo " 结果：$PASS 项通过，$FAIL 项失败，$WARN 项提醒"
echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
    echo " 全绿。实测："
    echo "   sudo 指纹 ：sudo -k && sudo true      （看到提示后按指纹）"
    echo "   锁屏      ：Super+L 用指纹解锁"
    echo "   GNOME 登录：重启后在登录界面直接按指纹"
else
    echo " 有 $FAIL 项异常。修完重跑本脚本直到全绿。"
    echo
    echo " ★ 万一 sudo 进不去（只有改坏 PAM 才可能）："
    echo "     Ctrl+Alt+F3 切文字终端用密码登录，然后"
    echo "     sudo rm -f /usr/local/bin/pam-biometric-exec.sh"
    echo "     （助手不在，PAM 那行会失败并自动回退密码，不影响登录）"
fi
echo
[ "$QUIET" = 1 ] || echo " 提示：本脚本只读，不改任何东西。"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
