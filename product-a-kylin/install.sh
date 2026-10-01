#!/usr/bin/env bash
# ============================================================================
# 产品 A 安装入口 —— 麒麟栈：让 sudo 能用指纹、并能录入新指纹
#
# 用法：
#   sudo ./install.sh              # 交互式（会问一次确认）
#   sudo ./install.sh --yes        # 无人值守
#   ./install.sh --status          # 只看状态，什么都不装（不需要 root）
#
# 这个脚本自己不做任何危险的改动，它只是按顺序调三个子脚本：
#   payload/install_biometric_ubuntu.sh    装框架 + 厂商驱动 + udev
#   payload/install_integration_ubuntu.sh  装 PAM 助手 + 接 PAM + 加内核参数
#   payload/checkup.sh                     体检（只读）
#
# ★ 设计前提（2026-09-30）：没有第二台机器可以试跑。
#   所以本脚本的原则是：**能自己判断的都自己判断、失败说人话、重跑安全**。
#   每一步都可以单独重跑，不会越搞越糟。
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="${SCRIPT_DIR}/payload"
[ -d "$PAYLOAD" ] || PAYLOAD="${SCRIPT_DIR}"      # 容忍解包后目录被压平

VID=2f0a; PID=8020
VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo '未标注')"

ASSUME_YES=0
DO_STATUS=0
for a in "$@"; do
    case "$a" in
        -y|--yes) ASSUME_YES=1 ;;
        --status) DO_STATUS=1 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done

echo "============================================================"
echo " 品识 PT2887-SS 指纹 —— 产品 A（麒麟栈）"
echo " 版本：${VERSION}"
echo "============================================================"

# --------------------------------------------------------------- 状态判断
# 用来回答"这台机器现在是什么状态"，也是重跑时决定跳过哪一步的依据。
FW_FILES=(/usr/lib/x86_64-linux-gnu/libbiometric.so.0.0.0
          /usr/lib/biometric-authentication/biometric-authenticationd
          /usr/bin/biometric-auth-client)
PAM_DONE=1; for s in sudo sudo-i; do grep -qF 'pam-biometric-exec.sh' "/etc/pam.d/$s" 2>/dev/null || PAM_DONE=0; done

fw_present=0; for f in "${FW_FILES[@]}"; do [ -e "$f" ] && fw_present=$((fw_present+1)); done

echo
echo "[状态]"
if [ "$fw_present" -eq 0 ]; then
    echo "  麒麟框架：未安装"
elif [ "$fw_present" -eq "${#FW_FILES[@]}" ]; then
    echo "  麒麟框架：已安装"
else
    echo "  麒麟框架：★ 装了一半（${fw_present}/${#FW_FILES[@]} 个文件在）—— 建议先回滚再重装"
fi
echo "  PAM 接线：$([ "$PAM_DONE" -eq 1 ] && echo '已接线' || echo '未接线')"
if command -v lsusb >/dev/null 2>&1; then
    if lsusb -d "${VID}:${PID}" >/dev/null 2>&1; then
        echo "  指纹模组：在线 ✅"
    else
        echo "  指纹模组：★ 不在线 —— 装完也无法验证（检查排线/换个 USB 口）"
    fi
fi

if [ "$DO_STATUS" -eq 1 ]; then
    echo
    echo "（--status：只看不装）"
    exit 0
fi

# --------------------------------------------------------------- 前置检查
[ "$(id -u)" -eq 0 ] || { echo; echo "请用 sudo 运行：sudo $0"; exit 1; }

. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || { echo; echo "ERROR: 当前不是 Ubuntu（${PRETTY_NAME:-?}），本包只在 Ubuntu 24.04 上验证过。"; exit 1; }
echo
echo "[环境] ${PRETTY_NAME}  内核 $(uname -r)"

for f in install_biometric_ubuntu.sh install_integration_ubuntu.sh checkup.sh pam-biometric-exec.sh; do
    [ -f "${PAYLOAD}/${f}" ] || { echo "ERROR: 缺 ${PAYLOAD}/${f}（包不完整）"; exit 1; }
done
[ -d "${PAYLOAD}/stage" ] || { echo "ERROR: 缺 ${PAYLOAD}/stage（厂商框架文件）"; exit 1; }
echo "       包内容完整 ✅"

# 校验和：确认包在传输/解包过程中没损坏
#
# ★★ 2026-09-30 修：**不要解析 sha256sum 的输出文本**。
#   它的"通过"字样是**本地化**的 —— 中文环境是 ": 成功"，英文才是 ": OK"。
#   第一版写了 grep ': OK$'，在中文机器上会**把每个文件都误报成不匹配**
#   （实测：`payload/checkup.sh: 成功` 被判为不匹配）。
#   正确做法：用 --quiet（只打印失败项）+ **退出码**判断，与语言无关。
if [ -f "${SCRIPT_DIR}/checksums.sha256" ] && command -v sha256sum >/dev/null 2>&1; then
    BAD="$( cd "$SCRIPT_DIR" && sha256sum -c --quiet checksums.sha256 2>&1 || true )"
    if [ -z "$BAD" ]; then
        echo "       校验和验证通过 ✅"
    else
        echo "       ⚠️  校验和不匹配（下面这些文件对不上）："
        printf '%s\n' "$BAD" | sed 's/^/           /'
        echo "       可能原因：包在传输中损坏、解包不完整，或者打包后又改过这些文件。"
        echo "       如果你确定是自己改的，可以忽略；否则建议重新解包。"
    fi
fi

if [ "$ASSUME_YES" -eq 0 ]; then
    echo
    echo "即将安装。这会改动："
    echo "  · 麒麟框架与厂商驱动（/usr/lib/biometric-authentication 等）"
    echo "  · PAM 助手 + /etc/pam.d/sudo、sudo-i 各一行"
    echo "  · 内核参数 8250.nr_uarts=2（需要重启生效）"
    read -r -p "继续？(yes/no) " ans
    [ "$ans" = "yes" ] || { echo "已取消。"; exit 0; }
fi

# --------------------------------------------------------------- 1) 框架
echo
echo "############################################################"
echo "# 步骤 1/3：框架 + 厂商驱动"
echo "############################################################"
if [ "$fw_present" -eq "${#FW_FILES[@]}" ]; then
    echo "已装过，跳过。（要重装请先跑 /var/backups/biometric-*/rollback.sh）"
else
    bash "${PAYLOAD}/install_biometric_ubuntu.sh" || {
        echo
        echo "ERROR: 框架安装失败。日志见 /var/log/biometric-install/install_*.log"
        echo "       修好后可重跑本脚本（已装的部分会被跳过）。"
        exit 1
    }
fi

# --------------------------------------------------------------- 2) 集成
echo
echo "############################################################"
echo "# 步骤 2/3：PAM 接线 + 内核参数"
echo "############################################################"
if [ "$PAM_DONE" -eq 1 ] && grep -q '8250.nr_uarts=2' /etc/default/grub 2>/dev/null; then
    echo "已接线且参数已配，跳过。"
else
    bash "${PAYLOAD}/install_integration_ubuntu.sh" --yes || {
        echo
        echo "ERROR: 集成步骤失败。PAM 部分已自动还原（事务性），系统保持原状。"
        echo "       日志见 /var/log/biometric-install/integration_*.log"
        exit 1
    }
fi

# --------------------------------------------------------------- 3) 体检
echo
echo "############################################################"
echo "# 步骤 3/3：体检"
echo "############################################################"
bash "${PAYLOAD}/checkup.sh" || true

# --------------------------------------------------------------- 收尾
echo
cat <<'EOF'
============================================================
 安装完成。接下来：

  1) 【重启】—— 内核参数 8250.nr_uarts=2 要重启才生效。
     重启前厂商驱动枚举会失败，这是预期的，不是装坏了。

  2) 重启后，录入第一枚指纹：
       biometric-auth-client enroll -d 100 -n "右手食指"
     （会提示反复按压十几次，跟着做就行）

  3) 验收：
       sudo -k; sudo true        ← 应当提示"请触摸电源键上的指纹传感器"
     或随时跑体检： sudo ./install.sh --status  再 ./payload/checkup.sh

 出问题看这里：
   · 安装日志：/var/log/biometric-install/
   · 体检脚本：payload/checkup.sh（只读，会说清哪一层坏了）
   · 万一 sudo 进不去：Ctrl+Alt+F3 切文字终端用密码登录，然后
       sudo /var/backups/biometric-integration-*/integration-rollback.sh
============================================================
EOF
