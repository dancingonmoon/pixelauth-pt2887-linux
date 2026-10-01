#!/usr/bin/env bash
# ============================================================================
# 集成步骤 —— 让"麒麟生物识别"真正接到 sudo 上
#
#   本脚本做三件事（都是 install_biometric_ubuntu.sh 明确不做的）：
#     1. 装 PAM 助手 /usr/local/bin/pam-biometric-exec.sh
#     2. 往 /etc/pam.d/sudo 和 sudo-i 各插**一行**，让 sudo 先试指纹
#     3. 给内核加 8250.nr_uarts=2（不加则厂商驱动枚举失败 BUFFER_TOO_SMALL）
#
# 用法：
#   sudo ./install_integration_ubuntu.sh
#
# ★★★ 这是整个方案里**唯一能搞坏系统**的一步 ★★★
#   PAM 配置写错会让人登录不进去。所以本脚本：
#     · 改之前先把原文件备份到 /var/backups/biometric-<时间戳>/
#     · **事务性**：两个文件要么都改成功，要么都还原，绝不留下半成品
#     · 幂等：那一行已经在就跳过，重复运行安全
#     · 生成 integration-rollback.sh，一条命令还原
#     · 只动 sudo 和 sudo-i —— **不碰 common-auth、不碰登录/GDM 的 PAM**
#       （所以即使出错，你也还能用密码登录，只是 sudo 退回密码）
#
# 为什么不用厂商的 pam_biometric.so：
#   它依赖 org.ukui.UniauthBackend、polkit-ukui-authentication-agent-1、LightDM，
#   而本机是 GNOME/GDM —— 那套在 Ubuntu 上跑不起来。
#   参见 docs 里"为什么不用 pam_biometric.so"一节。
# ============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HELPER_SRC="${SCRIPT_DIR}/pam-biometric-exec.sh"
HELPER_DST="/usr/local/bin/pam-biometric-exec.sh"
PAM_LINE='auth    sufficient    pam_exec.so stdout /usr/local/bin/pam-biometric-exec.sh'
PAM_FILES=(/etc/pam.d/sudo /etc/pam.d/sudo-i)
GRUB_FILE=/etc/default/grub
GRUB_PARAM='8250.nr_uarts=2'

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="/var/backups/biometric-integration-${STAMP}"
LOG_DIR="/var/log/biometric-install"
LOG_FILE="${LOG_DIR}/integration_${STAMP}.log"

die() { echo; echo "ERROR: $*"; echo "日志：${LOG_FILE}"; exit 1; }
section() { echo; echo "============================================================================"; echo "$*"; echo "============================================================================"; }

require_root() { [ "$(id -u)" -eq 0 ] || die "请用 sudo 运行：sudo $0"; }

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------- 1
install_helper() {
    section "1. 安装 PAM 助手"

    [ -f "$HELPER_SRC" ] || die "找不到 ${HELPER_SRC}"

    # ★ 不变式（必须固化，不是巧合）：/usr/local 与 /usr/local/bin 必须 root 拥有
    #   且不可被普通用户写 —— 否则普通用户能替换这个脚本、以 root 上下文执行。
    for d in /usr/local /usr/local/bin; do
        local owner
        owner="$(stat -c '%U' "$d")"
        [ "$owner" = "root" ] || die "${d} 的属主是 ${owner}，不是 root。拒绝安装（提权风险）。"
        if [ -n "$(find "$d" -maxdepth 0 -perm /022 -print -quit)" ]; then
            die "${d} 可被组/其他用户写。拒绝安装（提权风险）。"
        fi
    done

    install -m 0755 -o root -g root "$HELPER_SRC" "$HELPER_DST"
    echo "  ✅ ${HELPER_DST}（root:root 0755）"
    echo "$HELPER_DST" >> "${BACKUP_DIR}/INSTALLED_FILES.txt"
}

# ---------------------------------------------------------------- 2
wire_pam() {
    section "2. 配置 PAM（sudo 指纹）"

    local -a changed=()
    local f

    # --- 先全部检查一遍，确认这一行确实需要插入 ---
    for f in "${PAM_FILES[@]}"; do
        if [ ! -f "$f" ]; then
            echo "  ⚠️  跳过 ${f}（不存在）"
            continue
        fi
        if grep -qF 'pam-biometric-exec.sh' "$f"; then
            echo "  ⏭  ${f} 已经配置过，跳过"
            continue
        fi
        changed+=("$f")
    done

    if [ ${#changed[@]} -eq 0 ]; then
        echo "  ✅ 无需改动（都已配置）"
        return 0
    fi

    # --- 备份 ---
    echo
    echo "  备份原文件 → ${BACKUP_DIR}/"
    for f in "${changed[@]}"; do
        cp -p "$f" "${BACKUP_DIR}/$(basename "$f").orig"
        echo "      $(basename "$f").orig"
    done

    # --- 插入（事务性：任何一步失败就全部还原）---
    echo
    echo "  插入 PAM 行："
    echo "      ${PAM_LINE}"
    if ! _pam_insert_all "${changed[@]}"; then
        echo "  ❌ 插入失败，正在还原..."
        _pam_restore "${changed[@]}"
        die "PAM 配置失败，已还原原文件。指纹未接入，系统保持原状。"
    fi

    # --- 校验：每份文件里这一行恰好出现一次 ---
    local n
    for f in "${changed[@]}"; do
        n="$(grep -cF 'pam-biometric-exec.sh' "$f" || true)"
        [ "$n" -eq 1 ] || { _pam_restore "${changed[@]}"; die "${f} 校验失败（出现 ${n} 次），已还原"; }
        echo "  ✅ ${f}（1 行）"
    done

    for f in "${changed[@]}"; do
        echo "$f" >> "${BACKUP_DIR}/MODIFIED_FILES.txt"
    done
}

# 在 pam_env.so 之后、@include common-auth 之前插入。
# 位置理由：pam_env 设好环境变量再跑我们的助手；放在 common-auth 之前才能"通过就不问密码"。
_pam_insert_all() {
    local f tmp line_no
    for f in "$@"; do
        tmp="$(mktemp)"
        line_no="$(grep -n '^@include common-auth' "$f" | head -1 | cut -d: -f1)"
        if [ -z "$line_no" ]; then
            rm -f "$tmp"
            echo "  ❌ ${f} 里找不到 '@include common-auth'，无法安全定位插入点"
            return 1
        fi
        awk -v n="$line_no" -v line="$PAM_LINE" \
            'NR==n { print line } { print }' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
        cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    done
    return 0
}

_pam_restore() {
    local f
    for f in "$@"; do
        [ -f "${BACKUP_DIR}/$(basename "$f").orig" ] && \
            cp -p "${BACKUP_DIR}/$(basename "$f").orig" "$f" && \
            echo "      已还原 $(basename "$f")"
    done
}

# ---------------------------------------------------------------- 3
wire_grub() {
    section "3. 内核参数 ${GRUB_PARAM}"

    [ -f "$GRUB_FILE" ] || { echo "  ⚠️  ${GRUB_FILE} 不存在，跳过"; return 0; }

    # 为什么需要：N50 的固件会暴露一堆"幽灵串口"。不把 8250 的 uart 数压到 2，
    # 厂商驱动做设备枚举时算出的值会溢出（32×22+9 = 713 > 256），
    # 直接返回 BUFFER_TOO_SMALL，指纹模组就枚举不出来。

    if grep -qF "$GRUB_PARAM" "$GRUB_FILE"; then
        echo "  ⏭  已经设置过，跳过"
        echo "     当前运行值：$(cat /sys/module/8250/parameters/nr_uarts 2>/dev/null || echo '读不到')"
        return 0
    fi

    cp -p "$GRUB_FILE" "${BACKUP_DIR}/grub.orig"
    echo "  备份 → ${BACKUP_DIR}/grub.orig"
    echo "$GRUB_FILE" >> "${BACKUP_DIR}/MODIFIED_FILES.txt"

    # 追加到 GRUB_CMDLINE_LINUX（与既有安装保持一致）
    if grep -q '^GRUB_CMDLINE_LINUX=' "$GRUB_FILE"; then
        sed -i "s|^GRUB_CMDLINE_LINUX=\"\(.*\)\"|GRUB_CMDLINE_LINUX=\"\1 ${GRUB_PARAM}\"|" "$GRUB_FILE"
        echo "  ✅ 已追加到 GRUB_CMDLINE_LINUX"
    else
        echo "GRUB_CMDLINE_LINUX=\"${GRUB_PARAM}\"" >> "$GRUB_FILE"
        echo "  ✅ 已新建 GRUB_CMDLINE_LINUX"
    fi
    grep '^GRUB_CMDLINE_LINUX=' "$GRUB_FILE" | sed 's/^/      /'

    if command -v update-grub >/dev/null 2>&1; then
        update-grub 2>&1 | tail -3 | sed 's/^/      /'
        echo "  ✅ update-grub 完成"
    else
        echo "  ⚠️  找不到 update-grub，请手动运行后再重启"
    fi

    echo
    echo "  ★★ 这条参数【必须重启】才生效。 ★★"
    echo "     重启前指纹驱动枚举会失败，这是预期的。"
}

# ---------------------------------------------------------------- 4
ensure_state_dirs() {
    section "4. 运行期状态目录"

    # ★★ 2026-09-30 补：这个目录是"哪枚指纹属于哪个用户"的账本所在。
    #   芯片是 match-on-chip，模板不随系统重装丢；但**这个 DB 会丢** ——
    #   丢了以后 get-feature-list 返回空，PAM 助手直接回退密码，
    #   表现是"sudo 指纹静默失效、且完全不知道为什么"。
    #   安装时确保它在、权限对；备份/恢复见 docs 的"重装与迁移"一章。
    install -d -m 0755 -o root -g root /var/lib/biometric-auth
    echo "  ✅ /var/lib/biometric-auth （0755 root:root，账本数据库所在目录）"

    install -d -m 0700 -o root -g root /etc/pixelauth
    echo "  ✅ /etc/pixelauth （0700 root:root，厂商私有存储）"
}

# ---------------------------------------------------------------- 5
write_rollback() {
    section "5. 生成集成回滚脚本"

    local rb="${BACKUP_DIR}/integration-rollback.sh"

    cat > "$rb" <<ROLLBACK
#!/usr/bin/env bash
# 撤销 ${STAMP} 的「集成步骤」：PAM 接线 + GRUB 参数 + PAM 助手
set -uo pipefail
[ "\$(id -u)" -eq 0 ] || { echo "请用 sudo 运行"; exit 1; }

echo "1) 移除 PAM 里的指纹行"
for f in /etc/pam.d/sudo /etc/pam.d/sudo-i; do
    [ -f "\$f" ] || continue
    if grep -qF 'pam-biometric-exec.sh' "\$f"; then
        if [ -f "${BACKUP_DIR}/\$(basename \$f).orig" ]; then
            cp -p "${BACKUP_DIR}/\$(basename \$f).orig" "\$f"
            echo "   还原 \$(basename \$f)（用安装时的备份）"
        else
            sed -i '/pam-biometric-exec.sh/d' "\$f"
            echo "   删行 \$(basename \$f)"
        fi
    fi
done

echo "2) 移除 PAM 助手"
rm -f ${HELPER_DST} && echo "   已删 ${HELPER_DST}"

echo "3) 撤销 GRUB 参数（如果你还想改回的话）"
if [ -f "${BACKUP_DIR}/grub.orig" ]; then
    cp -p "${BACKUP_DIR}/grub.orig" ${GRUB_FILE}
    update-grub 2>&1 | tail -2 | sed 's/^/   /'
    echo "   已还原 ${GRUB_FILE} —— ★ 需要重启才生效"
else
    echo "   （没有 grub 备份，未改动）"
fi

echo
echo "完成。sudo 会回到纯密码验证。"
echo "备份仍在：${BACKUP_DIR}"
ROLLBACK

    chmod +x "$rb"
    echo "  ✅ ${rb}"
}

# ---------------------------------------------------------------- main
main() {
    require_root

    # --yes / -y：跳过交互确认（给顶层 install.sh 无人值守调用）
    local ASSUME_YES=0
    case "${1:-}" in
        -y|--yes) ASSUME_YES=1 ;;
    esac

    cat <<EOF

============================================================================
 集成步骤：把指纹接到 sudo 上
============================================================================
 将要改动：
   · ${HELPER_DST}
   · ${PAM_FILES[0]}   （插 1 行）
   · ${PAM_FILES[1]}   （插 1 行）
   · ${GRUB_FILE}      （加 ${GRUB_PARAM}）
 不会碰：
   · /etc/pam.d/common-auth 及任何登录/GDM 的 PAM 配置
   · pam_biometric.so、pam-auth-update

 备份与回滚脚本都会放到：${BACKUP_DIR}
============================================================================
EOF
    if [ "$ASSUME_YES" -eq 0 ]; then
        read -r -p "确认继续？(yes/no) " ans
        [ "$ans" = "yes" ] || { echo "已取消。"; exit 0; }
    else
        echo "（--yes：跳过确认）"
    fi

    install_helper
    wire_pam
    wire_grub
    ensure_state_dirs
    write_rollback

    section "完成"
    cat <<EOF

 做了什么：
   ✅ PAM 助手 → ${HELPER_DST}
   ✅ PAM 接线 → ${PAM_FILES[*]}
   ✅ 内核参数 → ${GRUB_FILE}
   ✅ 状态目录 → /var/lib/biometric-auth 、/etc/pixelauth

 ★ 现在【重启】才完整生效（GRUB 参数）。
   重启后：新开一个终端跑  sudo -k; sudo true  ，应当提示"请触摸电源键上的指纹传感器"。

 回滚：sudo ${BACKUP_DIR}/integration-rollback.sh
 日志：${LOG_FILE}
 备份：${BACKUP_DIR}

EOF
}

main "$@"
