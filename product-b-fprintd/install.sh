#!/usr/bin/env bash
# ============================================================================
# 产品 B 安装入口 —— fprintd 那条链路：GNOME 锁屏 / 登录界面 / sudo
#
# 用法：
#   sudo ./install.sh              # 交互式
#   sudo ./install.sh --yes        # 无人值守
#   ./install.sh --status          # 只看状态（不需要 root）
#
# 装什么：
#   1. TOD 驱动 → /usr/lib/x86_64-linux-gnu/libfprint-2/tod-1/
#      （用包内预编译的 .so；加 --build 则现场重新编译）
#   2. PAM 助手 → /usr/local/bin/fp-earlypass-helper（0.3.0 单进程版）+ Python 包
#   3. PAM 接线 → /etc/pam.d/sudo 与 sudo-i 各插一行（**事务性**，失败全还原）
#   4. 精确删除工具 → /usr/local/bin/fprint-delete-finger.py
#   5. fprintd「重新登记」修复补丁（dpkg 装 1.94.3-1+pa1；--no-fprintd-patch 可跳过）
#   6. 跑一遍体检
#
# ★ 和产品 A 的关系：产品 A 装的是麒麟栈的 pam-biometric-exec.sh；
#   产品 B 0.3.0 起改为装 /usr/local/bin/fp-earlypass-helper，装 B 就等于把 sudo 切到 fprintd 单进程助手。
#   装 B 之后麒麟可以退役（见 README「退役麒麟」一节）。
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="${SCRIPT_DIR}/payload"
[ -d "$PAYLOAD" ] || PAYLOAD="${SCRIPT_DIR}"

TOD_DIR=/usr/lib/x86_64-linux-gnu/libfprint-2/tod-1
TOD_SO="${TOD_DIR}/libpixelauth_pt2887.so"
HELPER_DST=/usr/local/bin/fp-earlypass-helper
PYBIN_DST=/usr/local/lib/fp-earlypass
SETWIN_DST=/usr/local/bin/fp-earlypass-set-window
DELTOOL_DST=/usr/local/bin/fprint-delete-finger.py
PAM_LINE='auth    sufficient    pam_exec.so stdout /usr/local/bin/fp-earlypass-helper'
PAM_FILES=(/etc/pam.d/sudo /etc/pam.d/sudo-i)
VID=2f0a; PID=8020
VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo '未标注')"

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="/var/backups/biometric-b-${STAMP}"

ASSUME_YES=0; DO_STATUS=0; DO_BUILD=0; SKIP_FPRINTD_PATCH=0
for a in "$@"; do
    case "$a" in
        -y|--yes) ASSUME_YES=1 ;;
        --status) DO_STATUS=1 ;;
        --build)  DO_BUILD=1 ;;
        --no-fprintd-patch) SKIP_FPRINTD_PATCH=1 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done

echo "============================================================"
echo " 品识 PT2887-SS 指纹 —— 产品 B（fprintd）"
echo " 版本：${VERSION}"
echo "============================================================"

# --------------------------------------------------------------- 状态
echo
echo "[状态]"
printf '  TOD 驱动    : '; [ -f "$TOD_SO" ] && echo "已装（$(stat -c%s "$TOD_SO") 字节）" || echo "未装"
printf '  PAM 助手    : '; if [ -x "$HELPER_DST" ]; then
    [ -f "${PYBIN_DST}/fpearlypass/run.py" ] && echo "已装（0.3.0 单进程版 ✓）" || echo "已装（★ 缺 Python 包）"
else echo "未装"; fi
printf '  sudo 接线   : '; PAMOK=1; for s in sudo sudo-i; do grep -qF 'fp-earlypass-helper' "/etc/pam.d/$s" 2>/dev/null || PAMOK=0; done
[ "$PAMOK" = 1 ] && echo "已接线" || echo "未接线"
printf '  删除工具    : '; [ -x "$DELTOOL_DST" ] && echo "已装" || echo "未装"
printf '  fprintd 修复 : '; FPVER=$(dpkg-query -W -f'${Version}' fprintd 2>/dev/null); case "$FPVER" in
    *+pa1*) echo "已打补丁 ✓（$FPVER：重新登记安全）" ;;
    "")     echo "★ 没装 fprintd" ;;
    *)      echo "原版（$FPVER）—— 重新登记按错手指会毁数据，建议补上" ;;
esac
printf '  指纹模组    : '; lsusb -d "${VID}:${PID}" >/dev/null 2>&1 && echo "在线 ✅" || echo "★ 不在线"
printf '  fprintd     : '; command -v fprintd-list >/dev/null 2>&1 && echo "已安装" || echo "★ 未安装（sudo apt install fprintd libpam-fprintd）"

[ "$DO_STATUS" -eq 1 ] && { echo; echo "（--status：只看不装）"; exit 0; }

# --------------------------------------------------------------- 前置
[ "$(id -u)" -eq 0 ] || { echo; echo "请用 sudo 运行：sudo $0"; exit 1; }
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || { echo; echo "ERROR: 当前不是 Ubuntu（${PRETTY_NAME:-?}）"; exit 1; }
echo
echo "[环境] ${PRETTY_NAME}  内核 $(uname -r)"

command -v fprintd-list >/dev/null 2>&1 || { echo "ERROR: 没装 fprintd —— sudo apt install fprintd libpam-fprintd"; exit 1; }

[ -s "${PAYLOAD}/prebuilt/libpixelauth_pt2887.so" ] || [ "$DO_BUILD" -eq 1 ] || {
    echo "ERROR: 包内没有预编译的驱动，也没有指定 --build"; exit 1; }

if [ "$ASSUME_YES" -eq 0 ]; then
    echo
    echo "即将安装到："
    echo "  ${TOD_SO}"
    echo "  ${HELPER_DST}          （0.3.0 单进程版 PAM 助手）"
    echo "  ${PYBIN_DST}/fpearlypass/          （助手用的 Python 包）"
    echo "  ${PAM_FILES[*]}        （各插 1 行，事务性）"
    echo "  ${DELTOOL_DST}"
    [ "$SKIP_FPRINTD_PATCH" -eq 0 ] && echo "  fprintd                （dpkg 装 1.94.3-1+pa1：重登记修复 + apt-mark hold）"
    read -r -p "继续？(yes/no) " ans
    [ "$ans" = "yes" ] || { echo "已取消。"; exit 0; }
fi

# --------------------------------------------------------------- 1 驱动
echo
echo "############################################################"
echo "# 1/5：TOD 驱动"
echo "############################################################"
mkdir -p "$BACKUP_DIR"
if [ -f "$TOD_SO" ]; then
    cp -p "$TOD_SO" "${BACKUP_DIR}/libpixelauth_pt2887.so.orig" && echo "  已备份旧驱动"
fi
if [ "$DO_BUILD" -eq 1 ]; then
    echo "  现场编译：meson setup build && ninja"
    ( cd "${PAYLOAD}/src" && { [ -d build ] || meson setup build; } && ninja -C build ) \
        || { echo "ERROR: 编译失败。需要：meson ninja-build gcc pkg-config libfprint-2-tod-dev"; exit 1; }
    install -D -m 0755 "${PAYLOAD}/src/build/libpixelauth_pt2887.so" "$TOD_SO"
else
    install -D -m 0755 "${PAYLOAD}/prebuilt/libpixelauth_pt2887.so" "$TOD_SO"
fi
echo "  ✅ ${TOD_SO}（$(stat -c%s "$TOD_SO") 字节）"

# --------------------------------------------------------------- 2 助手
echo
echo "############################################################"
echo "# 2/5：PAM 助手（0.3.0 单进程版）"
echo "############################################################"
for d in /usr/local /usr/local/bin; do
    [ "$(stat -c '%U' "$d")" = root ] || { echo "ERROR: ${d} 属主不是 root（提权风险），拒绝安装"; exit 1; }
done
if [ -f "$HELPER_DST" ]; then
    cp -p "$HELPER_DST" "${BACKUP_DIR}/fp-earlypass-helper.orig" && echo "  已备份旧助手"
fi
# 旧版助手（fprintd 版 pam-biometric-exec.sh）如果还在，一并备份后删除，避免两套助手并存
if [ -f /usr/local/bin/pam-biometric-exec.sh ]; then
    cp -p /usr/local/bin/pam-biometric-exec.sh "${BACKUP_DIR}/pam-biometric-exec.sh.orig" && echo "  已备份旧助手 pam-biometric-exec.sh"
fi
install -d -m 0755 "${PYBIN_DST}/fpearlypass"
install -m 0644 "${PAYLOAD}"/fpearlypass/*.py "${PYBIN_DST}/fpearlypass/"
install -m 0755 -o root -g root "${PAYLOAD}/fp-earlypass-helper.sh" "$HELPER_DST"
install -m 0755 -o root -g root "${PAYLOAD}/set-window.sh" "$SETWIN_DST"
if ! env -i PATH=/usr/bin:/bin /usr/bin/python3 -c 'import sys; sys.path.insert(0, "'"${PYBIN_DST}"'"); import fpearlypass.session' 2>/dev/null; then
    echo "ERROR: Python 包导入自检失败"; exit 1
fi
echo "  ✅ ${HELPER_DST}（root:root 0755）+ 包 ${PYBIN_DST}/fpearlypass（导入自检通过）"

# --------------------------------------------------------------- 3 PAM
echo
echo "############################################################"
echo "# 3/5：PAM 接线（sudo / sudo-i）"
echo "############################################################"
CHANGED=()
for f in "${PAM_FILES[@]}"; do
    [ -f "$f" ] || continue
    # 0.3.0：已接线就改成 sufficient；旧行（pam-biometric-exec.sh / optional）也要替换
    if grep -qE '^auth +(sufficient|optional) +pam_exec\.so +stdout +/usr/local/bin/fp-earlypass-helper$' "$f"; then
        echo "  ⏭  ${f} 已是 sufficient 接线，跳过"
    else
        CHANGED+=("$f")
    fi
done
if [ ${#CHANGED[@]} -gt 0 ]; then
    for f in "${CHANGED[@]}"; do cp -p "$f" "${BACKUP_DIR}/$(basename "$f").orig"; done
    echo "  已备份原文件 → ${BACKUP_DIR}/"
    ok_all=1
    for f in "${CHANGED[@]}"; do
        n=$(grep -n '^@include common-auth' "$f" | head -1 | cut -d: -f1)
        if [ -z "$n" ]; then
            echo "  ❌ ${f} 里找不到 '@include common-auth'，无法安全定位插入点"
            ok_all=0; break
        fi
        tmp="$(mktemp)"
        # 先删掉旧助手行（pam-biometric-exec.sh / optional 版），再在 @include common-auth 之前插入 sufficient 行
        grep -vE '^auth +(sufficient|optional) +pam_exec\.so +stdout +/usr/local/bin/(pam-biometric-exec\.sh|fp-earlypass-helper)$' "$f" > "$tmp"
        n=$(grep -n '^@include common-auth' "$tmp" | head -1 | cut -d: -f1)
        awk -v n="$n" -v line="$PAM_LINE" 'NR==n { print line } { print }' "$tmp" > "${tmp}.2" && cat "${tmp}.2" > "$f"
        rm -f "$tmp" "${tmp}.2"
    done
    if [ "$ok_all" -ne 1 ]; then
        for f in "${CHANGED[@]}"; do
            [ -f "${BACKUP_DIR}/$(basename "$f").orig" ] && cp -p "${BACKUP_DIR}/$(basename "$f").orig" "$f"
        done
        echo "ERROR: PAM 接线失败，已全部还原。系统保持原状。"; exit 1
    fi
    for f in "${CHANGED[@]}"; do
        c=$(grep -cF 'fp-earlypass-helper' "$f")
        [ "$c" -eq 1 ] || { for g in "${CHANGED[@]}"; do cp -p "${BACKUP_DIR}/$(basename "$g").orig" "$g"; done
                            echo "ERROR: ${f} 校验失败，已还原"; exit 1; }
        echo "  ✅ ${f}（插了 1 行）"
    done
fi

# --------------------------------------------------------------- 4 工具
echo
echo "############################################################"
echo "# 4/5：工具"
echo "############################################################"
install -m 0755 -o root -g root "${PAYLOAD}/fprint-delete-finger.py" "$DELTOOL_DST"
ln -sf fprint-delete-finger.py /usr/local/bin/fprint-delete-finger
echo "  ✅ ${DELTOOL_DST}"
echo "  ✅ /usr/local/bin/fprint-delete-finger（短名，日常就用这个）"
echo "     （GNOME 46 的设置程序没有「删单枚」功能 —— 它会走到全删。"
echo "       要精确删一枚就用这个工具，见 README 第 4.2 节）"

# --------------------------------------------------------------- 5 fprintd 补丁
echo
echo "############################################################"
echo "# 5/5：fprintd「重新登记」修复补丁"
echo "############################################################"
FPVER_CUR=$(dpkg-query -W -f'${Version}' fprintd 2>/dev/null || echo "")
case "$FPVER_CUR" in
    *+pa1*)
        PAMVER_CUR=$(dpkg-query -W -f'${Version}' libpam-fprintd 2>/dev/null || echo "")
        case "$PAMVER_CUR" in
            *+pa1*)
                echo "  ⏭  已打过（$FPVER_CUR / $PAMVER_CUR），跳过" ;;
            *)
                echo "  ⚠️  fprintd 已打补丁但 libpam-fprintd 没跟上（$PAMVER_CUR）—— 补跑 apply 对齐两包"
                bash "${PAYLOAD}/fprintd-patch/install-fprintd-patched.sh" apply \
                    || echo "  ⚠️  补丁安装失败 —— 见 README 第 4.6 节" ;;
        esac ;;
    *)
        if [ "$SKIP_FPRINTD_PATCH" -eq 1 ]; then
            echo "  ⏭  按 --no-fprintd-patch 跳过"
            echo "     ⚠️   GNOME「重新登记该手指」仍有毁数据风险（见 README 第 4.6 节）"
        else
            bash "${PAYLOAD}/fprintd-patch/install-fprintd-patched.sh" apply \
                || echo "  ⚠️  补丁安装失败 —— 重新登记仍有风险；可重试或看 README 第 4.6 节"
        fi
        ;;
esac

systemctl restart fprintd 2>/dev/null || true
sleep 1
echo
bash "${PAYLOAD}/checkup.sh" || true

cat <<EOF

============================================================
 安装完成。

 回滚（只回滚本产品装的东西）：
   sudo cp -p ${BACKUP_DIR}/fp-earlypass-helper.orig ${HELPER_DST} 2>/dev/null
   sudo rm -rf ${PYBIN_DST} ${SETWIN_DST}
   sudo cp -p ${BACKUP_DIR}/libpixelauth_pt2887.so.orig ${TOD_SO} 2>/dev/null
   sudo ./payload/fprintd-patch/install-fprintd-patched.sh revert   # 还原原版 fprintd + libpam-fprintd
   （PAM 行的原文件也在 ${BACKUP_DIR}/ 下）

 验收：
   sudo -k && sudo true          ← 应提示"请触摸电源键上的指纹传感器"
   Super+L                       ← 锁屏后用指纹解锁
   sudo ./payload/checkup.sh     ← 全绿
   （可选）重新登记安全性：
   ./payload/tools/re-register-test.sh <已录手指> <另一根已录手指>   ← 应 GREEN（见 README 第 4.6 节）

 备份目录：${BACKUP_DIR}
============================================================
EOF
