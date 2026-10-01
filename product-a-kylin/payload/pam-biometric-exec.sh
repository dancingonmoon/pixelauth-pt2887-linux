#!/bin/bash
# ============================================================================
# pam_exec 助手：用品识指纹模组为 PAM 提供认证
#
# 由 /etc/pam.d/sudo 的 pam_exec.so 调用（注意：pam_exec 以「被认证用户」身份运行，
# 不是 root，所以日志必须写用户可写的位置）。
#
#   exit 0 → 认证成功
#   非 0   → 失败（pam_exec 配 sufficient 时优雅回退密码）
#
# 关键设计：
#   - 所有外部调用都套 timeout，绝不能让 sudo 卡住
#   - 任何异常路径都返回失败 → 回退密码，不会把人锁在外面
#   - ★ 必须给用户提示：sudo 里的 pam_exec 配了 stdout，脚本的 stdout 是接到
#     终端的。之前一字节都不输出，用户只看到一个不动的光标，根本不知道
#     要按指纹 —— 这一版把每一步都讲清楚。
# ============================================================================

LOG=/tmp/bioauth-pam.log
CLI=/usr/bin/biometric-auth-client
T_FAST=5     # 列驱动/列指纹 的超时（秒）
T_VERIFY=12  # 单次指纹验证的超时（够按一次指纹）

log() { echo "$(date '+%F %T') [pam-bio] $*" >> "$LOG" 2>/dev/null; }

# ★★ 提示输出：三条路依次试 ★★
#
# 实测教训（2026-09-28）：
#   1) pam_exec.so 的 stdout 选项不是"接到终端"，而是变成 PAM_TEXT_INFO，
#      而 **sudo 只显示 PAM_ERROR_MSG，不显示 PAM_TEXT_INFO**；
#   2) pam_exec 的子进程**没有控制终端**，/dev/tty 打不开（ENXIO）；
#   3) PAM 会把终端名放在 **PAM_TTY** 里，这是最靠谱的一条路。
# 所以顺序试：PAM_TTY → /dev/tty → stdout，全失败也不能让脚本报错刷屏。
say() {
    local out=""
    if [ -n "${PAM_TTY:-}" ] && [ -c "${PAM_TTY}" ] && [ -w "${PAM_TTY}" ]; then
        out="${PAM_TTY}"
    elif { : > /dev/tty; } 2>/dev/null; then
        out="/dev/tty"
    fi
    if [ -n "$out" ]; then
        if ! echo "$@" > "$out" 2>/dev/null; then
            echo "$@" 2>/dev/null
        fi
    else
        echo "$@" 2>/dev/null
    fi
    return 0
}

USER_NAME="${PAM_USER:-$(id -un)}"
SERVICE="${PAM_SERVICE:-unknown}"

log "==== 开始: user=$USER_NAME service=$SERVICE uid=$(id -u) ===="
# 诊断用：把可用的输出通道记下来，免得每次都要靠猜
log "    输出环境: PAM_TTY=[${PAM_TTY:-未设置}] tty1=$([ -t 1 ] && echo yes || echo no) 可写=$([ -n "${PAM_TTY:-}" ] && [ -w "${PAM_TTY:-/nonexistent}" ] && echo yes || echo no)"

# --- 只对普通用户生效 ---
uid=$(id -u "$USER_NAME" 2>/dev/null || echo 0)
if [ "$USER_NAME" = "root" ] || [ "$uid" -lt 1000 ]; then
    log "跳过：非普通用户 ($USER_NAME uid=$uid)"
    exit 1
fi

# --- 找驱动 ID ---
DRV=$(timeout $T_FAST $CLI get-driver-list 2>/dev/null \
      | awk -F'|' '$4 ~ /pabio/ { gsub(/ /,"",$3); print $3; exit }')
if [ -z "$DRV" ]; then
    log "跳过：没找到 pabio 驱动"
    exit 1
fi
log "驱动 ID = $DRV"

# --- 列该用户的指纹索引 ---
LIST=$(timeout $T_FAST $CLI get-feature-list -d "$DRV" -u "$USER_NAME" 2>/dev/null)
IDXS=$(echo "$LIST" | awk -F'|' '
    /Finger Print/ { gsub(/ /,"",$7); if ($7 ~ /^[0-9]+$/) print $7 }')

if [ -z "$IDXS" ]; then
    log "跳过：用户 $USER_NAME 无已录入指纹"
    exit 1
fi
log "可用索引: $(echo $IDXS | tr '\n' ' ')"

# --- 提示用户（没有这一段，用户面对的就是一个不动的光标）---
#
# ★ 文案设计（2026-09-28 用户反馈后重写）：
#   刻意**不暴露任何内部计数** ——
#     · 不写"第 1/2 枚"：用户既不知道那是哪根手指，也不关心芯片里有几条记录；
#       多枚指纹的轮询对用户应当是**透明**的（一枚没中直接试下一枚，不打扰他）。
#     · 不写秒数：它随指纹数量变化（N×12），既不准确也没必要；
#       用户真正需要知道的是"不做会怎样"，所以改成"未识别会自动转为密码验证"。
#     · 不建议按 Ctrl+C：sudo 在 PAM 阶段未必响应它，给个没用的建议比不给更糟。
say ""
say "  请触摸电源键上的指纹传感器"
say "  未通过会自动转为密码验证"
say ""

# --- 逐个尝试（每个都有超时，绝不会卡死 sudo；对用户是透明的）---
#
# ★ 区分两种「失败」，文案不能混为一谈（2026-09-28 用户指出）：
#     · 按了但没认出来 → 客户端输出 "Verify feature no match"
#     · 根本没按（超时）→ 输出里只有 "请按压传感器"
#   把两者都说成"未识别"是不准确的 —— 没人按的时候，根本不存在"识别"这个动作。
PRESSED=0
for i in $IDXS; do
    log "尝试索引 $i ..."
    OUT=$(timeout $T_VERIFY $CLI verify -d "$DRV" -i "$i" -u "$USER_NAME" 2>&1)
    RC=$?
    log "  退出码=$RC 输出: $(echo "$OUT" | tr '\n' ' ' | cut -c1-200)"

    # 必须匹配行尾的 match，否则 "no match" 会被误判成成功
    if echo "$OUT" | grep -qE 'Verify feature match[[:space:]]*$'; then
        log "✅ 认证成功（索引 $i）"
        say "  ✅ 指纹验证通过"
        exit 0
    fi

    if echo "$OUT" | grep -q 'Verify feature no match'; then
        PRESSED=1
        log "  这枚按了但没匹配上"
    elif [ $RC -eq 124 ]; then
        log "  超时（没按指纹或按得太慢）"
    fi
done

if [ "$PRESSED" -eq 1 ]; then
    log "❌ 按了但未通过，回退密码"
    say "  ❌ 指纹未通过，请改用密码"
else
    log "❌ 没检测到指纹，回退密码"
    say "  ⏱  没有检测到指纹，请改用密码"
fi
say ""
exit 1
