#!/bin/bash
# ============================================================================
# fpearlypass 助手（产品 B 0.3.0）：sudo 指纹等待的体验改进
#
# 行为：
#   · 指纹通过 → 立即通过（PAM 行必须是 sufficient）；
#   · 指纹“按下但没认出来”→ 驱动给出结论时立即转密码；
#   · 等待中按 回车 / Esc → 立即转密码（按键不送给 sudo）；
#   · 等待期间终端不显示按键；都不发生 → 窗口到点（默认 12 秒）转密码。
#
# 安装：/usr/local/bin/fp-earlypass-helper（root:root 0755）
# 包：  /usr/local/lib/fp-earlypass/fpearlypass/*.py（root:root 0644）
# PAM： auth sufficient pam_exec.so stdout /usr/local/bin/fp-earlypass-helper
# ============================================================================
set -u
LOG=/tmp/bioauth-pam.log
FPBIN="${FP_EARLYPASS_BIN:-/usr/local/lib/fp-earlypass}"
STATE_DIR="${FP_EARLYPASS_STATE:-/var/lib/fpearlypass}"
FP_WINDOW="${FP_WINDOW:-12}"
log() { echo "$(date '+%F %T') [fp-early] $*" >> "$LOG" 2>/dev/null; }

if [ "$(id -u)" = 0 ]; then
    USER_NAME="${PAM_USER:-$(id -un)}"; SERVICE_NAME="${PAM_SERVICE:-}"
    case "$SERVICE_NAME" in sudo|sudo-i) ;; *) log "跳过：服务 ${SERVICE_NAME}"; exit 1;; esac
    uid=$(id -u "$USER_NAME" 2>/dev/null || echo 0)
    if [ "$USER_NAME" = root ] || [ "$uid" -lt 1000 ]; then log "跳过：非普通用户 ${USER_NAME}"; exit 1; fi
    if ! timeout 10 fprintd-list "$USER_NAME" 2>/dev/null | grep -q ' - #'; then
        log "跳过：${USER_NAME} 没有已录入指纹"; exit 1
    fi
    fn="fp-early-${USER_NAME}.sh"; inst="${STATE_DIR}/${fn}"
    if ! cmp -s "$0" "$inst" 2>/dev/null; then
        mkdir -p "$STATE_DIR" && chmod 755 "$STATE_DIR"
        cp -f "$0" "$inst" && chmod 755 "$inst" && chown root:root "$inst" || { log "无法写 ${inst}"; exit 1; }
    fi
    home=$(getent passwd "$USER_NAME" | cut -d: -f6); gid=$(id -g "$USER_NAME")
    log "管理员阶段完成：以 ${USER_NAME}(${uid}) 运行用户阶段"
    exec /usr/bin/setpriv --reuid="$uid" --regid="$gid" --init-groups --reset-env \
        env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$home" LANG="${LANG:-C.UTF-8}" \
            PAM_TTY="${PAM_TTY:-}" PAM_USER="$USER_NAME" PAM_SERVICE="$SERVICE_NAME" \
            FP_EARLYPASS_BIN="$FPBIN" FP_WINDOW="$FP_WINDOW" \
        /bin/bash "$inst"
    exit 1
fi

USER_NAME="${PAM_USER:-$(id -un)}"
TTY_PATH="${PAM_TTY:-}"
[ -c "$TTY_PATH" ] || TTY_PATH=""
log "==== 开始（用户阶段）: user=${USER_NAME} tty=${TTY_PATH:-无} 窗口=${FP_WINDOW}s ===="

FPRINTD_VERIFY="${FP_FPRINTD_VERIFY:-/usr/bin/fprintd-verify}"
FP_CMD="/usr/bin/timeout $((FP_WINDOW + 20)) $FPRINTD_VERIFY -f any $USER_NAME"

if [ -z "$TTY_PATH" ]; then
    out=$(/bin/sh -c "$FP_CMD" 2>&1); rc=$?
    log "无终端：fprintd-verify rc=${rc}"
    echo "$out" | grep -q 'Verify result: verify-match' && exit 0
    exit 1
fi

OUT=$(/usr/bin/python3 "$FPBIN/fpearlypass/run.py" "$TTY_PATH" "$FP_WINDOW" $FP_CMD 2>&1)
RC=$?
log "run.py 退出码=${RC} 输出=$(echo "$OUT" | tr '\n' ' ' | cut -c1-200)"
[ "$RC" -eq 0 ] && { log "✅ 指纹通过"; exit 0; }
exit 1
