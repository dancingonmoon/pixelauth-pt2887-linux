#!/usr/bin/env bash
# ============================================================================
# 抓一份「当前可用状态」快照 —— 让重装系统从"重建"变成"恢复"
#
# 用法（在**现在这台还正常工作的机器上**跑一次）：
#   sudo ./snapshot.sh
#
# 为什么要它：
#   芯片里的指纹模板**不随系统重装丢**（那是 match-on-chip）。
#   但下面这些**会丢**，而它们一丢，表现是"指纹明明录过却用不了"：
#     · /var/lib/biometric-auth/biometric.db  ← "哪枚指纹属于哪个用户"的账本
#     · /etc/pixelauth/                        ← 厂商侧的模板账本
#     · /var/lib/fprint/                       ← fprintd 的本地绑定记录
#   重装后把这三样恢复回去，指纹立刻就能用，不用重新录（芯片里现成的）。
#
# 快照里还带上配置文件与文字记录，**只作对照**，恢复时不会自动覆盖
# （新系统的 PAM/GRUB 要让安装器去配，不能盲目还原旧文件）。
#
# 产物：state-snapshot.tar.gz + SNAPSHOT-INFO.txt
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(dirname "$SCRIPT_DIR")"          # 产品 A 的根目录
OUT="${PKG_ROOT}/state-snapshot.tar.gz"
INFO="${PKG_ROOT}/SNAPSHOT-INFO.txt"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行：sudo $0"; exit 1; }

echo "============================================================"
echo " 状态快照        $(date '+%F %T')"
echo "============================================================"

# ---------- 1. 数据（恢复后直接生效）----------
echo
echo "[1] 抓数据（这些是重装后「恢复即可用」的关键）"
mkdir -p "${STAGE}/data"
for src in /var/lib/biometric-auth /etc/pixelauth /etc/biometric-auth /var/lib/fprint; do
    if [ -e "$src" ]; then
        # ★★ 坑（2026-09-30 实测踩到）：这里必须 `mkdir -p "$dest"` ——
        #   建 **dest 本身**，不是建它的父目录。
        #   第一版写的是 mkdir -p "$(dirname "$dest")"（只建父目录），于是第一次
        #   `cp -a src dest` 时 dest 还不存在 → cp 把 dest **整体当成目标名**，
        #   结果 dest 变成了 src 的内容，**白白少一层目录**：
        #       /var/lib/biometric-auth → data/var/lib            （少了 biometric-auth 这层）
        #       /etc/pixelauth          → data/etc                （少了 pixelauth 这层）
        #   而后面两个侥幸是对的（那时 dest 已存在，cp 是"往里拷"）——
        #   这种"部分正确"最难察觉，重装时才会发现账本恢复不了。
        dest="${STAGE}/data${src}"
        mkdir -p "$dest"
        if cp -a "${src}/." "$dest/" ; then
            echo "    ✅ ${src}（$(du -sh "$src" 2>/dev/null | cut -f1)）"
        else
            echo "    ⚠️  ${src} 复制失败（权限？）"
        fi
    else
        echo "    ⏭  ${src} 不存在，跳过"
    fi
done

# ---------- 2. 配置（仅作对照，恢复时不覆盖）----------
echo
echo "[2] 抓配置（只作对照）"
mkdir -p "${STAGE}/config-ref"
for f in /etc/pam.d/sudo /etc/pam.d/sudo-i /etc/default/grub; do
    [ -f "$f" ] && cp -p "$f" "${STAGE}/config-ref/$(basename "$f")" && echo "    ✅ ${f}"
done
[ -d /etc/systemd/system/fprintd.service.d ] && \
    cp -a /etc/systemd/system/fprintd.service.d "${STAGE}/config-ref/" && \
    echo "    ✅ /etc/systemd/system/fprintd.service.d/"

# ---------- 3. 文字记录（人工核对用）----------
echo
echo "[3] 抓文字记录（出问题时对照用）"
mkdir -p "${STAGE}/text"
{
    echo "快照时间：$(date '+%F %T')"
    echo "主机名  ：$(hostname)"
    echo "系统    ：$(. /etc/os-release; echo "${PRETTY_NAME:-?}")"
    echo "内核    ：$(uname -r)"
    echo
    echo "===== lsusb 指纹设备 ====="
    lsusb -d 2f0a:8020 2>/dev/null || echo "(设备不在线)"
    echo
    echo "===== fprintd 里的指纹 ====="
    for u in $(ls /var/lib/fprint 2>/dev/null); do
        echo "-- 用户 ${u} --"
        fprintd-list "$u" 2>/dev/null || echo "(查询失败)"
    done
    echo
    echo "===== 麒麟账本里的指纹 ====="
    DRV=$(timeout 5 biometric-auth-client get-driver-list 2>/dev/null \
          | awk -F'|' '$4 ~ /pabio/ {gsub(/ /,"",$3); print $3; exit}')
    for u in $(ls /home 2>/dev/null); do
        echo "-- 用户 ${u}（驱动 ${DRV:-?}）--"
        timeout 5 biometric-auth-client get-feature-list -d "${DRV:-100}" -u "$u" 2>/dev/null || echo "(查询失败)"
    done
} > "${STAGE}/text/state.txt" 2>&1
echo "    ✅ text/state.txt"

# 芯片侧：索引表 + 每个槽位的记录（用 pa_probe，只读）
PROBE=""
for c in "${SCRIPT_DIR}/tools/pa_probe" "${SCRIPT_DIR}/pa_probe"; do
    [ -x "$c" ] && { PROBE="$c"; break; }
done
if [ -n "$PROBE" ]; then
    {
        echo "===== 芯片索引表与记录（pa_probe，只读）====="
        "$PROBE" 1f 2>&1
        IDX=$("$PROBE" 1f 2>/dev/null | grep '占用槽位' | sed 's/.*占用槽位: *//; s/ *共.*//')
        for s in $IDX; do
            addr=$(( s * 0x40 )); ah=$(printf '%02x' $(( addr >> 8 ))); al=$(printf '%02x' $(( addr & 0xff )))
            echo
            echo "----- 槽位 ${s} -----"
            "$PROBE" a6 "$ah" "$al" 00 40 2>&1 | grep -E 'payload|状态'
        done
    } > "${STAGE}/text/chip.txt" 2>&1
    echo "    ✅ text/chip.txt"
else
    echo "    ⏭  没找到 pa_probe，跳过芯片记录（不影响恢复）"
fi

# ---------- 4. 打包 ----------
echo
echo "[4] 打包"
tar -czf "$OUT" -C "$STAGE" . || { echo "打包失败"; exit 1; }
chmod 600 "$OUT"

# ★ 属主交给调用者（不是 root）。
#   踩过的坑（2026-09-30）：原来落成 root:root 600 —— 于是打包脚本以普通用户跑时
#   **读不到这个文件**，快照就进不了交付包，重装时才发现少了最关键的东西。
#   600 的权限保持不变（里面有用户名与指纹标识，别让别的用户看到）。
OWNER="${SUDO_USER:-}"
if [ -n "$OWNER" ] && id "$OWNER" >/dev/null 2>&1; then
    chown "${OWNER}:" "$OUT" "$INFO" 2>/dev/null || true
fi
SIZE=$(du -h "$OUT" | cut -f1)
echo "    ✅ ${OUT}（${SIZE}，属主 ${OWNER:-root}，权限 600）"

cat > "$INFO" <<EOF
状态快照说明
================================================================
抓取时间：$(date '+%F %T')
抓取主机：$(hostname)
本机系统：$(. /etc/os-release; echo "${PRETTY_NAME:-?}")  内核 $(uname -r)
文件    ：state-snapshot.tar.gz（${SIZE}，权限 600）

里面有什么
----------------------------------------------------------------
data/        重装后【恢复即可用】的数据：
               var/lib/biometric-auth/   麒麟账本（哪枚指纹属于谁）
               etc/pixelauth/            厂商侧账本
               etc/biometric-auth/       框架配置
               var/lib/fprint/           fprintd 的本地绑定记录
config-ref/  仅作对照，恢复时**不会**自动覆盖：
               pam.d/sudo, sudo-i, default/grub, fprintd.service.d/
text/        人工核对用：
               state.txt   设备/两个账本里的指纹清单
               chip.txt    芯片索引表与每个槽位的记录

怎么用
----------------------------------------------------------------
重装系统后：
  1) 先按 docs 正常装本产品（sudo ./install.sh）
  2) 再跑 payload/restore-state.sh 恢复 data/
  3) 跑 payload/checkup.sh 验收

为什么芯片不用重录
----------------------------------------------------------------
模板存在指纹芯片里（match-on-chip），重装系统**不会**动它。
丢的是"主机侧账本"，恢复账本 + 模板，指纹立刻可用。

注意
----------------------------------------------------------------
· 本快照含用户名与指纹标识，按敏感文件对待（已设 600）。
· 换到**另一台**机器时：芯片可能是空的或装着别人的模板，
  那种情况恢复账本没有意义 —— 要重新录入（见 docs 的换机章节）。
EOF
echo "    ✅ ${INFO}"
echo
echo "============================================================"
echo " 完成。把这两个文件留在包里一起保管。"
echo "============================================================"
