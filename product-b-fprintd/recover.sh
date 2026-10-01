#!/usr/bin/env bash
# ============================================================================
# 产品 B 的统一入口（三动作接口，和 suma-driver-recovery 一致）
#
#   sudo ./recover.sh apply      安装（等价于 install.sh --yes）
#        ./recover.sh status     看状态（只读，不需要 root）
#   sudo ./recover.sh rollback   卸载本产品装的东西
#
# 为什么要有这个：一个包一个入口，新人不用记一堆脚本名。
# ============================================================================

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-status}"

TOD_SO=/usr/lib/x86_64-linux-gnu/libfprint-2/tod-1/libpixelauth_pt2887.so
HELPER=/usr/local/bin/pam-biometric-exec.sh
DELTOOL=/usr/local/bin/fprint-delete-finger.py
PAM_FILES=(/etc/pam.d/sudo /etc/pam.d/sudo-i)

case "$ACTION" in
  apply|install)
      exec sudo "${DIR}/install.sh" --yes "${@:2}"
      ;;

  status)
      "${DIR}/install.sh" --status
      echo
      echo "--- 体检 ---"
      "${DIR}/payload/checkup.sh" --quiet || true
      rc=$?
      echo
      echo "--- 备份目录（rollback 会用） ---"
      ls -d /var/backups/biometric-b-* 2>/dev/null | tail -3 | sed 's/^/  /' || echo "  （没有）"
      exit $rc
      ;;

  rollback|uninstall)
      [ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行：sudo $0 rollback"; exit 1; }
      echo "============================================================"
      echo " 卸载产品 B"
      echo "============================================================"

      # 1) 移除 PAM 接线（用最近的备份还原；没有备份就删行）
      BK=$(ls -dt /var/backups/biometric-b-* 2>/dev/null | head -1)
      echo
      echo "[1] PAM 接线"
      for f in "${PAM_FILES[@]}"; do
          [ -f "$f" ] || continue
          grep -qF 'pam-biometric-exec.sh' "$f" || { echo "  ⏭  $f 本来就没有指纹行"; continue; }
          if [ -n "$BK" ] && [ -f "${BK}/$(basename "$f").orig" ]; then
              cp -p "${BK}/$(basename "$f").orig" "$f" && echo "  ✅ 用备份还原 $(basename "$f")"
          else
              cp -p "$f" "${f}.bak-preb-$(date +%Y%m%d)" 2>/dev/null
              sed -i '/pam-biometric-exec.sh/d' "$f" && echo "  ✅ 删行 $(basename "$f")（原件备份为 ${f}.bak-preb-*）"
          fi
      done

      # 2) 移除我们装的文件
      echo
      echo "[2] 移除文件"
      for f in "$DELTOOL" /usr/local/bin/fprint-delete-finger "$HELPER"; do
          if [ -e "$f" ] || [ -L "$f" ]; then
              rm -f "$f" && echo "  ✅ 删除 $f"
          fi
      done
      if [ -f "$TOD_SO" ]; then
          if [ -n "$BK" ] && [ -f "${BK}/libpixelauth_pt2887.so.orig" ]; then
              cp -p "${BK}/libpixelauth_pt2887.so.orig" "$TOD_SO" && echo "  ✅ 还原旧驱动"
          else
              rm -f "$TOD_SO" && echo "  ✅ 删除 TOD 驱动"
          fi
      fi

      # 3) fprintd「重新登记」补丁（如果在）
      echo
      echo "[3] fprintd 补丁"
      FPV=$(dpkg-query -W -f'${Version}' fprintd 2>/dev/null || echo "")
      case "$FPV" in
          *+pa1*)
              bash "${DIR}/payload/fprintd-patch/install-fprintd-patched.sh" revert \
                  && echo "  ✅ fprintd 已还原到原版" \
                  || echo "  ⚠️  未还原成功 —— 手动： sudo ${DIR}/payload/fprintd-patch/install-fprintd-patched.sh revert" ;;
          *)  echo "  ⏭  当前不是补丁版，跳过（版本：${FPV:-未装}）" ;;
      esac

      systemctl restart fprintd 2>/dev/null || true
      echo
      echo "============================================================"
      echo " 卸载完成。sudo 已回到纯密码验证（PAM 行没了或助手没了都会回退）。"
      echo " 芯片里的指纹没有动（模板还在芯片里，随时可以重装再用）。"
      echo " 备份目录保留在：${BK:-（无）}"
      echo "============================================================"
      ;;

  *)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 2
      ;;
esac
