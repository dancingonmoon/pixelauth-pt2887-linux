#!/bin/bash
# 调整指纹等待窗口（秒），默认 12。用法：sudo fp-earlypass-set-window 8
set -eu
[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行"; exit 1; }
S="${1:?用法: sudo fp-earlypass-set-window <秒数>}"
case "$S" in ''|*[!0-9]*) echo "秒数必须是整数"; exit 1;; esac
[ "$S" -ge 3 ] && [ "$S" -le 60 ] || { echo "秒数应在 3..60 之间"; exit 1; }
for f in /usr/local/bin/fp-earlypass-helper /var/lib/fpearlypass/fp-early-*.sh; do
  [ -f "$f" ] || continue
  sed -i "s/^FP_WINDOW=\"\${FP_WINDOW:-[0-9]*}\"/FP_WINDOW=\"\${FP_WINDOW:-$S}\"/" "$f"
done
echo "已设置为 ${S} 秒（下次 sudo 生效）"
