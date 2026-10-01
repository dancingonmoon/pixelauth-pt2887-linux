#!/bin/bash
# ============================================================================
# PAM 助手（fprintd 版）—— 让 sudo 用指纹认证
#
# 安装到：/usr/local/bin/pam-biometric-exec.sh   （必须 root:root 0755）
# 被 PAM 调用，两行：
#   /etc/pam.d/sudo     auth  sufficient  pam_exec.so stdout /usr/local/bin/pam-biometric-exec.sh
#   /etc/pam.d/sudo-i   auth  sufficient  pam_exec.so stdout /usr/local/bin/pam-biometric-exec.sh
#
# ★ 2026-09-30 重写：**从"麒麟栈"改成"fprintd"**
#   旧版调 /usr/bin/biometric-auth-client（麒麟框架）。换掉的理由：
#     ① 麒麟的守护进程每次被调用都会做一次"同步"，把芯片里它不认识的记录**删掉**
#        —— 我们自己录的指纹就活不过一次 sudo。这个坑 09-29/09-30 踩了两次，
#        一共毁掉过 5 个槽位。
#     ② 换成 fprintd 之后，sudo 和锁屏/登录界面用**同一套指纹、同一份记录**，
#        行为一致、只有一个数据源，排查也简单。
#     ③ 麒麟那套就可以整个退役了（它的账本、同步、二进制都不再需要）。
#
# 设计要点（沿用旧版、都是踩着坑换来的）：
#   · 提示语走 PAM_TTY → /dev/tty → stdout 三级降级
#     （pam_exec 的子进程**没有控制终端**，/dev/tty 打不开；而 stdout 会变成
#      PAM_TEXT_INFO，sudo 只显示 PAM_ERROR_MSG 不显示它）
#   · 任何异常路径一律返回非 0 → 因 PAM 里配的是 sufficient，自动回退密码
#   · 所有外部调用都套 timeout，最坏几十秒必退，绝不卡死 sudo
# ============================================================================

LOG=/tmp/bioauth-pam.log
CLI=/usr/bin/fprintd-verify
T_VERIFY=35          # 单次验证超时（我们自己驱动的窗口是 29 秒/槽位，留点余量）

log() { echo "$(date '+%F %T') [pam-bio] $*" >> "$LOG" 2>/dev/null; }

# 提示输出：PAM_TTY 最靠谱（pam_exec 子进程没有控制终端，stdout 又会被吞掉）
say() {
    local out=""
    if [ -n "${PAM_TTY:-}" ] && [ -c "${PAM_TTY}" ] && [ -w "${PAM_TTY}" ]; then
        out="${PAM_TTY}"
    elif { : > /dev/tty; } 2>/dev/null; then
        out="/dev/tty"
    fi
    if [ -n "$out" ]; then
        if ! echo "$@" > "$out" 2>/dev/null; then echo "$@" 2>/dev/null; fi
    else
        echo "$@" 2>/dev/null
    fi
    return 0
}

USER_NAME="${PAM_USER:-$(id -un)}"
SERVICE="${PAM_SERVICE:-unknown}"

log "==== 开始(fprintd 版): user=$USER_NAME service=$SERVICE uid=$(id -u) ===="
log "    输出环境: PAM_TTY=[${PAM_TTY:-未设置}] 可写=$([ -n "${PAM_TTY:-}" ] && [ -w "${PAM_TTY:-/nonexistent}" ] && echo yes || echo no)"

# --- 只对普通用户生效 ---
uid=$(id -u "$USER_NAME" 2>/dev/null || echo 0)
if [ "$USER_NAME" = "root" ] || [ "$uid" -lt 1000 ]; then
    log "跳过：非普通用户 ($USER_NAME uid=$uid)"
    exit 1
fi

if [ ! -x "$CLI" ]; then
    log "跳过：找不到 $CLI（fprintd 没装？）"
    exit 1
fi

# --- 该用户有没有录过指纹 ---
if ! timeout 10 fprintd-list "$USER_NAME" 2>/dev/null | grep -q ' - #'; then
    log "跳过：用户 $USER_NAME 没有已录入指纹"
    exit 1
fi

say ""
say "  请触摸电源键上的指纹传感器"
say "  未通过会自动转为密码验证"
say ""

# --- 验证 ---
# ★ 2026-10-01 修：必须带 `-f any`。
#   不带 -f 时 fprintd-verify 只验「列表里第一根手指」——实测日志：
#   Verifying: right-index-finger → 驱动只 arm 目标槽位 10。
#   按别的手指会静默失败、白白回退密码。
#   带 -f any 才会走 identify，遍历该用户全部指纹（对用户透明）。
OUT=$(timeout $T_VERIFY "$CLI" -f any "$USER_NAME" 2>&1)
RC=$?
log "fprintd-verify 退出码=$RC 输出: $(echo "$OUT" | tr '\n' ' ' | cut -c1-200)"

if echo "$OUT" | grep -q 'Verify result: verify-match'; then
    log "✅ 认证成功"
    say "  ✅ 指纹验证通过"
    exit 0
fi

# 区分两种失败：按了但没认出来 / 压根没按（超时）—— 文案不能混为一谈
if echo "$OUT" | grep -q 'verify-no-match'; then
    log "❌ 按了但未匹配"
    say "  ❌ 指纹未通过，请改用密码"
else
    log "⏱ 没检测到指纹（超时）"
    say "  ⏱ 没有检测到指纹，请改用密码"
fi
exit 1
