#!/bin/bash
# ============================================================================
# 安装 / 回滚「打过补丁的 fprintd」（重新登记安全修复）
#
#   用法： sudo ./install-fprintd-patched.sh apply|revert|status
#
#   apply  : 装 +pa1 版（fprintd 和 libpam-fprintd 两个一起装，dpkg -i），
#            两个都 apt-mark hold（防被 apt 升级覆盖），停掉正在跑的旧进程
#            （下次 D-Bus 调用会用新二进制重启）
#   revert : 解 hold（两个），装回原版 1.94.3-1（out/ 里那两份原版 .deb）
#   status : 看两个包的当前版本 + 是否被 hold + apt 解算是否正常
#
#   ★ 为什么必须两个一起装：补丁把 fprintd 的版本改成了 +pa1，而
#     libpam-fprintd 的依赖是「fprintd (= 1.94.3-1)」精确等于 —— 只装 fprintd
#     会造成 apt 账本上「未满足的依赖」，apt 报「已损坏个数 > 0」，
#     所有更新（含安全更新和 unattended）全部装不上。
#     （2026-10-01 实际踩过一次；哪天补丁要再加包，记得维持"同版本族"原则。）
#
# 装完必须重跑一次 re-register 测试（用一次性测试手指）确认 GREEN。
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
PATCHED_DEB="$(ls "$OUT"/fprintd_1.94.3-1+pa1_*.deb 2>/dev/null | head -1 || true)"
ORIG_DEB="$OUT/fprintd_1.94.3-1_amd64.deb"
PAM_PATCHED_DEB="$(ls "$OUT"/libpam-fprintd_1.94.3-1+pa1_*.deb 2>/dev/null | head -1 || true)"
PAM_ORIG_DEB="$OUT/libpam-fprintd_1.94.3-1_amd64.deb"

need_root() { [ "$(id -u)" = 0 ] || { echo "请用 sudo 运行（$*）"; exit 1; }; }

apt_ok() {  # 一行 apt 解算体检（防再次出现「已损坏个数 > 0」）
    if apt-get -s upgrade >/dev/null 2>&1; then
        echo "    apt 解算: 正常 ✓"
    else
        echo "    ⚠️ apt 解算异常（有未满足的依赖）—— 跑 apt-get -s upgrade 看详情"
    fi
}

case "${1:-status}" in
apply)
    need_root apply
    [ -n "$PATCHED_DEB" ] || { echo "❌ 找不到补丁版 fprintd .deb —— 先跑 $HERE/build.sh"; exit 1; }
    [ -f "$PAM_PATCHED_DEB" ] || { echo "❌ 找不到补丁版 libpam-fprintd .deb —— 先跑 $HERE/build.sh"; exit 1; }
    echo "== 安装前 =="
    dpkg-query -W -f='    ${Package}  ${Version}\n' fprintd libpam-fprintd
    echo "== 安装： $(basename "$PATCHED_DEB") + $(basename "$PAM_PATCHED_DEB") =="
    dpkg -i "$PATCHED_DEB" "$PAM_PATCHED_DEB"
    apt-mark hold fprintd libpam-fprintd
    systemctl stop fprintd 2>/dev/null || true    # 旧进程停掉；下次调用自动用新二进制激活
    echo "== 安装后 =="
    dpkg-query -W -f='    ${Package}  ${Version}\n' fprintd libpam-fprintd
    for p in fprintd libpam-fprintd; do
        if apt-mark showhold | grep -qx "$p"; then
            echo "    apt-mark hold: $p 是（apt 升级不会覆盖；revert 可解）"
        else
            echo "    ❌ apt-mark hold: $p 否 —— 补丁可能被 apt 升级覆盖，请重跑本脚本"
        fi
    done
    apt_ok
    echo
    echo "✅ 完成。验证：跑一次 re-register 测试（应得到 GREEN）"
    ;;
revert)
    need_root revert
    [ -f "$ORIG_DEB" ] || { echo "❌ 找不到原版 fprintd .deb（$ORIG_DEB）—— 跑 build.sh 时应当下载过"; exit 1; }
    [ -f "$PAM_ORIG_DEB" ] || { echo "❌ 找不到原版 libpam-fprintd .deb（$PAM_ORIG_DEB）—— 跑 build.sh 时应当下载过"; exit 1; }
    apt-mark unhold fprintd libpam-fprintd 2>/dev/null || true
    dpkg -i "$ORIG_DEB" "$PAM_ORIG_DEB"
    systemctl stop fprintd 2>/dev/null || true
    dpkg-query -W -f='    ${Package}  ${Version}\n' fprintd libpam-fprintd
    apt_ok
    echo "✅ 已回滚到原版（fprintd + libpam-fprintd 都回到 1.94.3-1）"
    ;;
status)
    dpkg-query -W -f='    ${Package}  ${Version}\n' fprintd libpam-fprintd
    for p in fprintd libpam-fprintd; do
        if apt-mark showhold | grep -qx "$p"; then echo "    apt-mark hold: $p 是"; else echo "    apt-mark hold: $p 否"; fi
    done
    FPVER="$(dpkg-query -W -f'${Version}' fprintd 2>/dev/null || echo "?")"
    PAMVER="$(dpkg-query -W -f'${Version}' libpam-fprintd 2>/dev/null || echo "?")"
    case "$FPVER" in
        *+pa1*) echo "    → fprintd 打过补丁（重新登记安全修复已生效）" ;;
        *)      echo "    → fprintd 原版（重新登记仍有'先删后查'的毁数据风险）" ;;
    esac
    case "$FPVER" in *+pa1*) FP_PA=1 ;; *) FP_PA=0 ;; esac
    case "$PAMVER" in *+pa1*) PAM_PA=1 ;; *) PAM_PA=0 ;; esac
    if [ "$FP_PA" != "$PAM_PA" ]; then
        echo "    ⚠️ 版本不一致：fprintd=$FPVER  libpam-fprintd=$PAMVER —— apt 会报「已损坏个数 > 0」"
        echo "      修复： sudo $HERE/install-fprintd-patched.sh apply"
    else
        echo "    fprintd 与 libpam-fprintd 版本同步 ✓"
    fi
    apt_ok
    ;;
*)
    echo "用法: $0 apply|revert|status"; exit 1;;
esac
