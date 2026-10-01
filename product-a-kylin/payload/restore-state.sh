#!/usr/bin/env bash
# ============================================================================
# 从快照恢复「主机侧账本」—— 重装系统后跑，指纹立刻可用，不用重录
#
# 用法：
#   sudo ./restore-state.sh                    # 自动找包里的 state-snapshot.tar.gz
#   sudo ./restore-state.sh <快照文件路径>
#
# 前置：先跑过 install.sh（框架和驱动得先装好），再跑本脚本。
#
# 恢复什么：
#   /var/lib/biometric-auth/   麒麟账本（"哪枚指纹属于谁"）★ 最关键
#   /etc/pixelauth/            厂商侧账本
#   /etc/biometric-auth/       框架配置
#   /var/lib/fprint/           fprintd 的本地绑定记录
#
# **不恢复** config-ref/ 里的 PAM / GRUB —— 新系统的这些要让安装器去配，
# 盲目还原旧文件有风险（分区、内核、PAM 版本都可能不同）。
#
# 原理：芯片模板不随重装丢（match-on-chip），丢的只是主机侧账本。
#       账本回来了，模板还在，指纹就回来了。
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(dirname "$SCRIPT_DIR")"

SNAP="${1:-${PKG_ROOT}/state-snapshot.tar.gz}"
[ -f "$SNAP" ] || SNAP="${SCRIPT_DIR}/state-snapshot.tar.gz"
[ -f "$SNAP" ] || { echo "ERROR: 找不到快照文件。"; echo "  用法：sudo $0 <state-snapshot.tar.gz 的路径>"; exit 1; }

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行：sudo $0"; exit 1; }

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/var/backups/biometric-restore-${STAMP}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "============================================================"
echo " 从快照恢复        快照：$(basename "$SNAP")"
echo "============================================================"

tar -xzf "$SNAP" -C "$WORK" || { echo "ERROR: 快照解不开（文件坏了？）"; exit 1; }
[ -d "${WORK}/data" ] || { echo "ERROR: 快照里没有 data/ 目录，不是本产品生成的快照？"; exit 1; }

echo
echo "[快照信息]"
[ -f "${PKG_ROOT}/SNAPSHOT-INFO.txt" ] && head -8 "${PKG_ROOT}/SNAPSHOT-INFO.txt" | sed 's/^/  /'

echo
echo "[将要恢复]"
(cd "$WORK/data" && find . -maxdepth 3 -type d | sed 's|^\./|  /|')

# ★★ 前置校验：快照必须含关键的几样，缺了就直接停。
#   为什么要这么严：第一版 snapshot.sh 有 bug，把 /var/lib/biometric-auth 和
#   /etc/pixelauth 各**少拷了一层目录**，而恢复脚本当时是"找不到就静默跳过" ——
#   于是重装后会**悄悄丢掉最关键的账本**，人还以为恢复成功了。
#   教训：宁可在这里拦住，也不要静默放过。
echo
echo "[校验快照完整性]"
CRITICAL=(
    "var/lib/biometric-auth/biometric.db:麒麟账本（哪枚指纹属于哪个用户）"
    "var/lib/fprint:fprintd 的本地绑定记录"
)
missing=0
for item in "${CRITICAL[@]}"; do
    rel="${item%%:*}"; desc="${item##*:}"
    if [ -e "${WORK}/data/${rel}" ]; then
        echo "  ✅ ${rel}  （${desc}）"
    else
        echo "  ❌ 快照里缺 ${rel}  （${desc}）"
        missing=$((missing+1))
    fi
done
if [ "$missing" -gt 0 ]; then
    echo
    echo "ERROR: 快照不完整，拒绝恢复（免得恢复出一半、账本反而更乱）。"
    echo "  可能原因：快照是用早期版本的 snapshot.sh 抓的（那个版本有拷贝 bug）。"
    echo "  处理办法：回到还正常的那台机器/系统，用当前版本的 payload/snapshot.sh 重抓一份。"
    exit 1
fi

echo
echo "[当前状态会先备份到] ${BACKUP}"
mkdir -p "$BACKUP"

restore_one() {
    local rel="$1"                       # 形如 var/lib/fprint
    local src="${WORK}/data/${rel}"
    local dst="/${rel}"
    [ -e "$src" ] || { echo "  ⏭  快照里没有 ${dst}，跳过"; return 0; }

    if [ -e "$dst" ]; then
        mkdir -p "${BACKUP}/$(dirname "$rel")"
        cp -a "$dst" "${BACKUP}/${rel}" 2>/dev/null && echo "  💾 备份了现有 ${dst}"
    fi
    mkdir -p "$(dirname "$dst")"
    cp -a "${src}/." "$dst/" 2>/dev/null \
        && echo "  ✅ 恢复 ${dst}" \
        || echo "  ❌ 恢复 ${dst} 失败（权限？）"
}

restore_one var/lib/biometric-auth
restore_one etc/pixelauth
restore_one etc/biometric-auth
restore_one var/lib/fprint

# 修正属主/权限（快照里带过来了，但目标机的 uid 可能不同）
echo
echo "[修正属主与权限]"
[ -d /var/lib/biometric-auth ] && chown -R root:root /var/lib/biometric-auth && chmod 755 /var/lib/biometric-auth
[ -f /var/lib/biometric-auth/biometric.db ] && chmod 600 /var/lib/biometric-auth/biometric.db && echo "  ✅ biometric.db → root:root 0600"
[ -d /etc/pixelauth ] && chown -R root:root /etc/pixelauth && chmod 700 /etc/pixelauth && echo "  ✅ /etc/pixelauth → root:root 0700"
[ -d /var/lib/fprint ] && chown -R root:root /var/lib/fprint && echo "  ✅ /var/lib/fprint → root:root"

# 让两个守护进程重新读账本
echo
echo "[让服务重新读取账本]"
systemctl restart biometric-authentication.service 2>/dev/null && echo "  ✅ 麒麟守护进程已重启"
systemctl stop fprintd 2>/dev/null || true
echo "  ✅ fprintd 已停（下次用到时按需启动）"

echo
echo "============================================================"
echo " 恢复完成。现在验收："
echo "   ./checkup.sh                              ← 应当全绿"
echo "   sudo -k; sudo true                        ← 应当提示按指纹"
echo "   Super+L 然后用指纹解锁"
echo
echo " 若麒麟账本条目数为 0（checkup 会报），说明快照没覆盖到 ——"
echo " 那就只能重新录入指纹（芯片里还有模板，但主机侧对应关系丢了）。"
echo " 恢复前的原状备份在：${BACKUP}"
echo "============================================================"
