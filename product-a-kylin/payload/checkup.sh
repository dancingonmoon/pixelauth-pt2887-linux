#!/usr/bin/env bash
# ============================================================================
# 指纹链路体检 —— 装完跑一遍，或怀疑失效时跑一遍
#
# 用法：
#   ./checkup.sh              # 人看的报告
#   ./checkup.sh --quiet      # 只输出失败项与汇总（给脚本调用）
#
# 不需要 sudo（个别项需要 root 才能看，会标成"看不到"而不是"失败"）。
#
# 退出码：0 = 没有失败项；1 = 有失败项。方便自动化验收。
#
# 覆盖两条链路：
#   A 麒麟栈  → sudo 指纹、录入新指纹
#   B fprintd → GNOME 锁屏 / 登录界面
#
# ★ 2026-09-30 重写自 check-biometric.sh，修掉两处"永远修不好"的假警报：
#     · 原来检查 /root/pam-biometric-backup —— 安装器从来不建它
#     · 原来指向 /root/restore-pam.sh     —— 该文件不在交付包里
#   并补上：芯片槽位/记录一致性、产品 B 那半边、"改了 GRUB 但没重启"的检测。
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

[ "$QUIET" = 1 ] || {
echo "============================================================"
echo " 指纹链路体检        $(date '+%F %T')        $(hostname)"
echo "============================================================"
}

# ============================================================ 0
sec "[0] 硬件"
if lsusb -d "${VID}:${PID}" >/dev/null 2>&1; then
    ok "指纹模组在线（$(lsusb -d "${VID}:${PID}" | sed 's/.*ID //')）"
else
    bad "指纹模组不在线 —— 检查排线/电源键；换个 USB 口试；lsusb 看有没有 2f0a:8020"
fi
if [ -r /sys/module/8250/parameters/nr_uarts ]; then
    NR=$(cat /sys/module/8250/parameters/nr_uarts)
    NTTY=$(ls -d /sys/class/tty/*/device 2>/dev/null | wc -l)
    info "nr_uarts=${NR}  带 /device 的 tty 数=${NTTY}  预计枚举值=$((NTTY*22+9))（上限 256）"
    if [ "$NR" = "2" ] && [ "$NTTY" -le 6 ]; then
        ok "内核参数 8250.nr_uarts=2 生效"
    else
        # ★ 区分"没配"和"配了没重启" —— 原来的脚本只会笼统报失败
        if grep -q '8250.nr_uarts=2' /etc/default/grub 2>/dev/null; then
            bad "内核参数【已配置但未生效】—— 十有八九是【还没重启】。重启即可。"
            info "（GRUB 里已写，但 /proc/cmdline 里没有 —— 典型的就是没重启）"
        else
            bad "内核参数未配置 —— 跑 install_integration_ubuntu.sh，或手工："
            info "在 /etc/default/grub 的 GRUB_CMDLINE_LINUX 里加 8250.nr_uarts=2，然后 update-grub + 重启"
        fi
    fi
else
    warn "读不到 8250 参数（需要 root 或内核未加载该模块）"
fi

# ============================================================ 1
# ★★ 顺序很重要：芯片侧检查必须**排在碰 fprintd 之前**。
#   踩过的坑（2026-09-30）：本脚本原来把这段放在 fprintd 之后，
#   而 `fprintd-list` 会通过 D-Bus **把 fprintd 拉起来并让它占住 USB 设备**
#   （而且它会持续占 ~30 秒），于是芯片侧永远读不到索引表 ——
#   变成一个每次运行都出现的假警报。挪到前面就对了。
sec "[1] 芯片侧（槽位与记录的一致性）"
# 这一段是 2026-09-29/30 两次"指纹莫名失效"事故换来的经验：
#   · 有索引没记录 → 芯片认不出（我们的旧版录入就是这样）
#   · 有记录没索引 → 同样没用
#   两者都表现为"明明录过，就是用不了"。
PROBE=""
for c in "$(dirname "$0")/pa_probe" "$(dirname "$0")/tools/pa_probe" /usr/local/bin/pa_probe; do
    [ -x "$c" ] && { PROBE="$c"; break; }
done
if [ -z "$PROBE" ]; then
    warn "没找到 pa_probe，跳过芯片侧检查（源码在 payload/tools/pa_probe.c，可现场编译）"
else
    # 探针输出形如：  "   占用槽位: 10 11   共 2 个"   或者  "   占用槽位: (无)   共 0 个"
    IDX_LINE=$("$PROBE" 1f 2>/dev/null | grep '占用槽位' || true)
    if [ -z "$IDX_LINE" ]; then
        warn "读不到芯片索引表 —— 多半是设备正被占用。排查："
        info "  systemctl is-active fprintd biometric-authentication"
        info "  等 30 秒（fprintd 会自动释放）再跑本脚本；或 sudo systemctl stop fprintd"
    else
        # 砍掉"共…"后面的部分，只留槽位号
        # （第一版没砍干净，把"共 2 个"里的 2 当成了槽位、在"个"上崩了）
        IDX=$(printf '%s\n' "$IDX_LINE" | sed 's/.*占用槽位: *//; s/ *共.*//')
        case "$IDX" in ""|"(无)") IDX="" ;; esac
        if [ -z "$IDX" ]; then
            warn "芯片索引表是空的 —— 芯片里一枚模板都没有（新机器/换机器时正常）"
            info "录指纹：biometric-auth-client enroll -d 100 -n \"左手食指\""
        else
            ok "芯片索引表：占用槽位 ${IDX}"
            for s in $IDX; do
                addr=$(( s * 0x40 ))
                ah=$(printf '%02x' $(( addr >> 8 ))); al=$(printf '%02x' $(( addr & 0xff )))
                rec=$("$PROBE" a6 "$ah" "$al" 00 40 2>/dev/null | grep 'payload' | sed 's/.*payload *([^)]*) *//' || true)
                data="${rec:10:64}"
                case "$data" in
                    "")                 warn "槽位 ${s}：读不到记录" ;;
                    fffffffff*)         bad  "槽位 ${s}：★ 有索引但记录区是空的 —— 芯片认不出，这枚用不了" ;;
                    333333333*)         bad  "槽位 ${s}：★ 记录是 0x33 占位符（旧版驱动「只录不写记录」留下的）—— 用不了，且会被麒麟清掉" ;;
                    *)                  ok   "槽位 ${s}：记录正常（${data:0:16}…）" ;;
                esac
            done
        fi
    fi
fi

# ============================================================ 2
sec "[2] 麒麟栈（sudo 指纹 / 录入新指纹）"

# --- 服务 ---
if systemctl is-active --quiet biometric-authentication.service 2>/dev/null; then
    ok "biometric-authentication.service 运行中"
else
    bad "服务未运行 —— sudo systemctl start biometric-authentication.service"
fi
if [ -f /usr/share/dbus-1/system-services/org.ukui.Biometric.service ]; then
    ok "D-Bus 激活文件在（崩溃后可自动拉起）"
else
    warn "D-Bus 激活文件缺失 —— 崩溃后不会自动拉起（重装 install_biometric_ubuntu.sh 可补）"
fi

# --- 文件齐备（含两个曾经漏装的）---
for f in /usr/lib/x86_64-linux-gnu/libbiometric.so.0.0.0 \
         /usr/lib/biometric-authentication/biometric-authenticationd \
         /usr/bin/biometric-auth-client ; do
    [ -e "$f" ] && ok "在：$(basename "$f")" || bad "缺失：$f —— 跑 install_biometric_ubuntu.sh"
done
if [ -L /usr/lib/biometric-authentication/drivers/pa180k/libpixelauth_pa180k.so ]; then
    ok "驱动符号链接在（libpixelauth_pa180k.so）"
else
    bad "驱动符号链接缺失 —— 驱动配置正指向它！修复："
    info "sudo ln -sfn libpixelauth_pa180k.so.1.0.1 \\"
    info "  /usr/lib/biometric-authentication/drivers/pa180k/libpixelauth_pa180k.so"
fi

# --- Python 依赖 ---
MISSING=""
for m in dbus gi prettytable; do
    /usr/bin/python3 -c "import $m" 2>/dev/null || MISSING="$MISSING $m"
done
[ -z "$MISSING" ] && ok "CLI 的 Python 依赖齐（dbus / gi / prettytable）" \
                  || bad "CLI 缺少 Python 模块：${MISSING} —— sudo apt install python3-dbus python3-gi python3-prettytable"

# --- 枚举 ---
# ★ 注意这里用 grep -c 而不是 grep -q：
#   grep -q 一找到就退出，会让上游 journalctl 吃到 SIGPIPE（退出码 141），
#   而脚本开了 set -o pipefail —— 于是整条管道被判为失败，**明明有枚举也报没有**。
#   这个坑 2026-09-30 实测踩过一次（本文件的第一版就是这么错的）。
ENUM_N=$(journalctl -u biometric-authentication.service -b --no-pager 2>/dev/null \
         | grep -c 'COSAPI_EnumDevice return OK' || true)
if [ "${ENUM_N:-0}" -gt 0 ]; then
    ok "本次启动设备枚举成功（${ENUM_N} 次）"
else
    warn "本次启动没看到枚举成功 —— journalctl -u biometric-authentication.service -b | tail -50"
fi

# --- 驱动与账本 ---
DRV=$(timeout 5 biometric-auth-client get-driver-list 2>/dev/null \
      | awk -F'|' '$4 ~ /pabio/ {gsub(/ /,"",$3); print $3; exit}')
[ -n "$DRV" ] && ok "驱动已加载（ID=${DRV}）" || bad "驱动未加载 —— 看服务日志"

U="${SUDO_USER:-${USER:-$(id -un)}}"
FEAT=$(timeout 5 biometric-auth-client get-feature-list -d "${DRV:-100}" -u "$U" 2>/dev/null | grep -c 'Finger Print')
if [ "$FEAT" -gt 0 ]; then
    ok "账号 $U 名下有 ${FEAT} 枚指纹（麒麟账本里有记录）"
else
    bad "账号 $U 名下一枚指纹都没有 —— ★ 这就是 sudo 指纹静默失效的典型症状"
    info "如果芯片里明明有模板，多半是 /var/lib/biometric-auth/biometric.db 丢了（重装系统会）"
    info "修复：从备份恢复该 DB（见 docs 恢复章节），或重新录入："
    info "  biometric-auth-client enroll -d ${DRV:-100} -n \"左手食指\""
fi

# --- PAM ---
for s in sudo sudo-i; do
    if grep -qF 'pam-biometric-exec.sh' "/etc/pam.d/$s" 2>/dev/null; then
        ok "/etc/pam.d/$s 已接线"
    else
        bad "/etc/pam.d/$s 缺少指纹行 —— 跑 install_integration_ubuntu.sh"
    fi
done
if [ -x /usr/local/bin/pam-biometric-exec.sh ]; then
    OWNER=$(stat -c '%U' /usr/local/bin/pam-biometric-exec.sh)
    [ "$OWNER" = root ] && ok "PAM 助手在（root:root）" \
                        || bad "PAM 助手属主是 ${OWNER}，必须是 root（提权风险）"
else
    bad "PAM 助手缺失 —— 跑 install_integration_ubuntu.sh"
fi

# ============================================================ B
sec "[3] fprintd（GNOME 锁屏 / 登录界面）"
if [ -f "$TOD_SO" ]; then
    ok "TOD 驱动已装：$(basename "$TOD_SO")（$(stat -c%s "$TOD_SO") 字节）"
else
    bad "TOD 驱动没装 —— 装 product-b-fprintd 的包，或跑它的 install.sh"
    info "（产品 A 与 B 是独立的：只装 A 只会有 sudo 指纹，锁屏/登录不会有）"
fi
if ! command -v fprintd-list >/dev/null 2>&1; then
    warn "fprintd 未安装 —— sudo apt install fprintd libpam-fprintd"
else
    if fprintd-list "$U" >/dev/null 2>&1; then
        N=$(fprintd-list "$U" 2>/dev/null | grep -c ' - #')
        [ "$N" -gt 0 ] && ok "fprintd 里有 ${N} 条指纹记录" \
                       || bad "fprintd 里一条记录都没有 —— 需要绑定：fprintd-enroll -f <手指名>"
    else
        warn "fprintd-list 执行失败（设备可能被麒麟占着，或 fprintd 没启动）"
    fi
fi

# ============================================================ 汇总
echo
echo "============================================================"
echo " 结果：$PASS 项通过，$FAIL 项失败，$WARN 项提醒"
echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
    echo " 全绿。实测："
    echo "   sudo 指纹   ：sudo -k && sudo true        （看到提示后按指纹）"
    echo "   锁屏        ：Super+L，然后用指纹解锁"
else
    echo " 有 $FAIL 项异常。修完重跑本脚本直到全绿。"
    echo
    echo " ★ 万一 sudo 进不去（改坏 PAM 才有这种可能）："
    echo "     Ctrl+Alt+F3 切到文字终端用密码登录，然后跑："
    echo "       sudo /var/backups/biometric-integration-*/integration-rollback.sh"
fi
echo
[ "$QUIET" = 1 ] || echo " 提示：本脚本不修改任何东西，只读。"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
