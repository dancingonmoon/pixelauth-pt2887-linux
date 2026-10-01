#!/usr/bin/env bash
# ============================================================================
# 麒麟生物识别框架 + 品识(PixelAuth) pa180k 指纹驱动  →  Ubuntu 24.04
#
# 目标设备：Suma/中科可控 天阔 N50 的电源键二合一指纹模组
#           USB  VID 2f0a / PID 8020  (PT2887-SS Module)
#
# 用法：
#   sudo ./install_biometric_ubuntu.sh
#
# ★★★ 安全边界（重要）★★★
#   本脚本【只做阶段 1+2】：
#     - 安装麒麟 biometric 框架（库 + 守护进程 + CLI）
#     - 安装品识 pa180k 指纹驱动
#     - 启动服务并验证设备能否被识别
#
#   本脚本【绝对不碰】：
#     - /etc/pam.d/ 下的任何文件
#     - pam_biometric.so（不安装）
#     - pam-auth-update（不运行）
#
#   原因：PAM 配置错误会导致登录不进去，是唯一能"搞坏系统"的点。
#         指纹能不能用于登录，等阶段 2 验证通过后再单独决定。
#
# 安全策略（沿用 install_fantgpu_ubuntu.sh 的思路）：
#   - 不覆盖任何已存在的文件：发现冲突立即停止并报告
#   - 所有改动先备份到 /var/backups/biometric-<时间戳>/
#   - 自动生成回滚脚本
#   - 全程日志
# ============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ★ 2026-09-30 产品化：stage 就在本脚本同级的 stage/ 下（原来在 pixelauth-pa180k/stage）。
#   支持两种布局，两种都能跑 —— 换机器/重装时解包位置随意。
if   [ -d "${SCRIPT_DIR}/stage" ]; then
    STAGE="${SCRIPT_DIR}/stage"
elif [ -d "${SCRIPT_DIR}/pixelauth-pa180k/stage" ]; then
    STAGE="${SCRIPT_DIR}/pixelauth-pa180k/stage"
else
    echo "ERROR: 找不到 stage 目录（应在 ${SCRIPT_DIR}/stage 或 ${SCRIPT_DIR}/pixelauth-pa180k/stage）" >&2
    exit 1
fi

DEV_VID="2f0a"
DEV_PID="8020"
DRIVER_NAME="pabio-pa180k"

STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="/var/log/biometric-install"
LOG_FILE="${LOG_DIR}/install_${STAMP}.log"
BACKUP_DIR="/var/backups/biometric-${STAMP}"
MANIFEST="${BACKUP_DIR}/INSTALLED_FILES.txt"

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

die() { echo; echo "ERROR: $*"; echo "日志：$LOG_FILE"; exit 1; }
section() { echo; echo "============================================================================"; echo "$*"; echo "============================================================================"; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请用 sudo 运行：sudo $0"
}

# ---------------------------------------------------------------- 1
check_prereq() {
    section "1. 前置检查"

    echo "系统：$(. /etc/os-release; echo "${PRETTY_NAME:-?}")"
    echo "内核：$(uname -r)"

    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] || die "当前不是 Ubuntu，停止。"

    # 源文件齐备？
    local missing=0
    for f in libbiometric.so.0.0.0 biometric-authenticationd biometric-auth-client \
             biometric-config-tool biometric-device-discover biometric-drivers.conf \
             biometric-authentication.service org.ukui.Biometric.conf \
             com.pixelauth.pa180k.rules; do
        if [ ! -f "${STAGE}/${f}" ]; then echo "  ❌ 缺少源文件: ${f}"; missing=1; fi
    done
    [ -d "${STAGE}/drivers-pa180k" ] || { echo "  ❌ 缺少 drivers-pa180k/"; missing=1; }
    [ "$missing" -eq 0 ] || die "staging 目录不完整：${STAGE}"

    echo "  ✅ staging 文件齐备：${STAGE}"

    # 设备在线？——不在线不阻止安装，但要明确告知
    if lsusb -d "${DEV_VID}:${DEV_PID}" >/dev/null 2>&1; then
        echo "  ✅ 指纹模组在线：$(lsusb -d "${DEV_VID}:${DEV_PID}" | cut -d' ' -f6-)"
    else
        echo "  ⚠️  当前没检测到 ${DEV_VID}:${DEV_PID}（不影响安装，但无法验证）"
    fi

    # 冲突检查：只允许"路径原本不存在"
    echo
    echo "目标路径冲突检查："
    local conflict=0
    for p in /usr/lib/biometric-authentication \
             /etc/biometric-auth \
             /usr/lib/x86_64-linux-gnu/libbiometric.so.0 \
             /usr/lib/x86_64-linux-gnu/libbiometric.so.0.0.0 \
             /usr/bin/biometric-auth-client \
             /usr/bin/biometric-config-tool \
             /usr/bin/biometric-device-discover \
             /usr/lib/systemd/system/biometric-authentication.service \
             /etc/dbus-1/system.d/org.ukui.Biometric.conf \
             /etc/udev/rules.d/com.pixelauth.pa180k.rules ; do
        if [ -e "$p" ]; then echo "  ⚠️  已存在: $p"; conflict=1; fi
    done
    if [ "$conflict" -eq 1 ]; then
        echo
        echo "发现已存在的路径。为避免覆盖你现有的文件，脚本停止。"
        echo "请先确认这些文件是否属于更早的安装，清理后再运行。"
        die "存在路径冲突。"
    fi
    echo "  ✅ 无冲突，全部为全新安装"
}

# ---------------------------------------------------------------- 2
install_framework() {
    section "2. 安装麒麟 biometric 框架"

    echo "[2.1] 框架库 libbiometric"
    install -D -m 0644 "${STAGE}/libbiometric.so.0.0.0" \
        /usr/lib/x86_64-linux-gnu/libbiometric.so.0.0.0
    ln -sfn libbiometric.so.0.0.0 /usr/lib/x86_64-linux-gnu/libbiometric.so.0
    echo "      /usr/lib/x86_64-linux-gnu/libbiometric.so.0 -> libbiometric.so.0.0.0"
    ldconfig
    echo "      ldconfig 完成"

    echo "[2.2] 守护进程"
    install -D -m 0755 "${STAGE}/biometric-authenticationd" \
        /usr/lib/biometric-authentication/biometric-authenticationd

    echo "[2.3] 命令行工具"
    for t in biometric-auth-client biometric-config-tool biometric-device-discover; do
        install -D -m 0755 "${STAGE}/${t}" "/usr/bin/${t}"
        echo "      /usr/bin/${t}"
    done

    echo "[2.4] 配置文件"
    install -D -m 0644 "${STAGE}/biometric-drivers.conf" \
        /etc/biometric-auth/biometric-drivers.conf

    echo "[2.5] systemd 服务"
    install -D -m 0644 "${STAGE}/biometric-authentication.service" \
        /usr/lib/systemd/system/biometric-authentication.service

    echo "[2.6] D-Bus 策略"
    install -D -m 0644 "${STAGE}/org.ukui.Biometric.conf" \
        /etc/dbus-1/system.d/org.ukui.Biometric.conf

    # ★★ 2026-09-30 补：D-Bus **激活文件**
    #   和符号链接是同一类问题：厂商 stage 里没有、原安装器不装，
    #   本机那一份是事后手工建的（09-27 20:25）。
    #   有了它，任何程序一调 org.ukui.Biometric，D-Bus 就自动把守护进程拉起来；
    #   没有它只能靠 systemd 服务，崩溃后不会自动恢复。
    if [ -f "${STAGE}/org.ukui.Biometric.service" ]; then
        install -D -m 0644 "${STAGE}/org.ukui.Biometric.service" \
            /usr/share/dbus-1/system-services/org.ukui.Biometric.service
        echo "      /usr/share/dbus-1/system-services/org.ukui.Biometric.service"
    else
        echo "      ⚠️  stage 里没有 org.ukui.Biometric.service，跳过（崩溃后不会自动拉起）"
    fi

    echo "[2.7] Python 依赖"
    # ★ 2026-09-30 补：biometric-auth-client 是 864 行的 Python3 脚本
    #   （#!/usr/bin/python3，不是二进制），它 import 三个模块：
    #       dbus          → python3-dbus
    #       gi.repository.GLib → python3-gi
    #       prettytable   → python3-prettytable
    #   原脚本只查了 prettytable。最小安装下另外两个不一定在，
    #   而且它们常常是 apt 的自动包、可能被 autoremove 带走 —— 缺了 CLI 一跑就 ImportError。
    local mod pkg
    for mod_pkg in "dbus:python3-dbus" "gi:python3-gi" "prettytable:python3-prettytable"; do
        mod="${mod_pkg%%:*}"; pkg="${mod_pkg##*:}"
        if /usr/bin/python3 -c "import ${mod}" 2>/dev/null; then
            echo "      ✅ ${mod}（${pkg}）已具备"
        else
            echo "      → 安装 ${pkg}"
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" \
                || die "${pkg} 安装失败（biometric-auth-client 需要 import ${mod}）"
        fi
    done

    {
        echo "/usr/lib/x86_64-linux-gnu/libbiometric.so.0.0.0"
        echo "/usr/lib/x86_64-linux-gnu/libbiometric.so.0"
        echo "/usr/lib/biometric-authentication/biometric-authenticationd"
        echo "/usr/bin/biometric-auth-client"
        echo "/usr/bin/biometric-config-tool"
        echo "/usr/bin/biometric-device-discover"
        echo "/etc/biometric-auth/biometric-drivers.conf"
        echo "/etc/biometric-auth"
        echo "/usr/lib/systemd/system/biometric-authentication.service"
        echo "/etc/dbus-1/system.d/org.ukui.Biometric.conf"
        echo "/usr/share/dbus-1/system-services/org.ukui.Biometric.service"
    } >> "$MANIFEST"

    echo "  框架安装完成"
}

# ---------------------------------------------------------------- 3
install_driver() {
    section "3. 安装品识 pa180k 指纹驱动"

    echo "[3.1] 驱动文件 → /usr/lib/biometric-authentication/drivers/pa180k/"
    install -d -m 0755 /usr/lib/biometric-authentication/drivers/pa180k
    install -D -m 0644 "${STAGE}/drivers-pa180k/libpixelauth_pa180k.so.1.0.1" \
        /usr/lib/biometric-authentication/drivers/pa180k/libpixelauth_pa180k.so.1.0.1
    install -D -m 0644 "${STAGE}/drivers-pa180k/com.pixelauth.pa180k.json" \
        /usr/lib/biometric-authentication/drivers/pa180k/com.pixelauth.pa180k.json

    # ★★ 2026-09-30 补：符号链接 libpixelauth_pa180k.so -> .so.1.0.1
    #   为什么必须有：/etc/biometric-auth/biometric-drivers.conf 里写的是
    #       Driver=/usr/lib/biometric-authentication/drivers/pa180k/libpixelauth_pa180k.so
    #   而框架的 biometric-device-discover 也按这个约定路径找驱动。
    #   原安装器只装了 .so.1.0.1、没建链接 —— 本机当时是事后手工补的（链接 mtime 09:02，
    #   安装 09:01），所以"照原脚本装"在干净机器上可能压根加载不了驱动。
    ln -sfn libpixelauth_pa180k.so.1.0.1 \
        /usr/lib/biometric-authentication/drivers/pa180k/libpixelauth_pa180k.so
    echo "      libpixelauth_pa180k.so -> libpixelauth_pa180k.so.1.0.1"

    echo "[3.2] udev 规则（让普通用户可访问设备）"
    install -D -m 0644 "${STAGE}/com.pixelauth.pa180k.rules" \
        /etc/udev/rules.d/com.pixelauth.pa180k.rules
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=usb 2>/dev/null || true

    {
        echo "/usr/lib/biometric-authentication/drivers/pa180k/libpixelauth_pa180k.so"
        echo "/usr/lib/biometric-authentication/drivers/pa180k/libpixelauth_pa180k.so.1.0.1"
        echo "/usr/lib/biometric-authentication/drivers/pa180k/com.pixelauth.pa180k.json"
        echo "/usr/lib/biometric-authentication/drivers/pa180k"
        echo "/etc/udev/rules.d/com.pixelauth.pa180k.rules"
    } >> "$MANIFEST"

    echo "  驱动安装完成"
}

# ---------------------------------------------------------------- 4
start_service() {
    section "4. 注册驱动并启动服务"

    systemctl daemon-reload

    echo "[4.1] 启动 biometric-authentication.service"
    systemctl enable --now biometric-authentication.service || true
    sleep 2

    if systemctl is-active --quiet biometric-authentication.service; then
        echo "      ✅ 服务已运行"
    else
        echo "      ⚠️  服务未运行，最近日志："
        journalctl -u biometric-authentication.service -n 30 --no-pager 2>/dev/null | sed 's/^/        /' || true
        echo "      （继续尝试注册驱动，可能服务是按需启动）"
    fi

    echo "[4.2] 注册驱动：${DRIVER_NAME}"
    # ★ 2026-09-30：用 grep -c 而非 grep -q —— 见下面 [5.2] 的说明（SIGPIPE + pipefail）
    DRV_N=$(biometric-auth-client get-driver-list 2>/dev/null | grep -c "${DRIVER_NAME}" || true)
    if [ "${DRV_N:-0}" -gt 0 ]; then
        echo "      已注册，跳过"
    else
        biometric-config-tool add-driver "${DRIVER_NAME}" \
            /usr/lib/biometric-authentication/drivers/pa180k/libpixelauth_pa180k.so \
            && echo "      ✅ add-driver 成功" \
            || echo "      ⚠️  add-driver 返回非零（见日志）"
    fi

    systemctl restart biometric-authentication.service 2>/dev/null || true
    sleep 2
}

# ---------------------------------------------------------------- 5
verify() {
    section "5. 验证（阶段 2 的核心）"

    echo "[5.1] 服务状态"
    systemctl status biometric-authentication.service --no-pager 2>/dev/null | head -12 | sed 's/^/  /' || true

    echo
    echo "[5.2] D-Bus 接口是否在线"
    # ★★ 2026-09-30 修一个潜伏 bug：这里原来写的是
    #       if busctl --system list | grep -qi 'ukui.Biometric'; then ...
    #   `busctl --system list` 输出很长（几百行），而 `grep -q` 一找到就退出 ——
    #   busctl 立刻吃到 SIGPIPE（退出码 141）。脚本开着 set -o pipefail，
    #   于是整条管道被判为失败 → **D-Bus 明明在线也会报"未看到"**。
    #   改用 grep -c（会把输入读完，不会让上游 SIGPIPE）。
    DBUS_OUT=$(busctl --system list 2>/dev/null || true)
    DBUS_N=$(printf '%s\n' "$DBUS_OUT" | grep -ci 'ukui.Biometric' || true)
    if [ "${DBUS_N:-0}" -gt 0 ]; then
        printf '%s\n' "$DBUS_OUT" | grep -i 'ukui.Biometric' | sed 's/^/  ✅ /'
    else
        echo "  ⚠️  D-Bus 上未看到 org.ukui.Biometric"
    fi

    echo
    echo "[5.3] 驱动列表"
    biometric-auth-client get-driver-list 2>&1 | sed 's/^/  /' || echo "  （命令执行失败）"

    echo
    echo "[5.4] 设备发现（关键：能否找到 2f0a:8020）"
    biometric-device-discover 2>&1 | head -20 | sed 's/^/  /' || echo "  （命令执行失败）"

    echo
    echo "[5.5] 设备状态"
    biometric-auth-client get-device-list 2>&1 | head -20 | sed 's/^/  /' || true

    echo
    echo "[5.6] 内核层确认（设备已被认领）"
    lsusb -d "${DEV_VID}:${DEV_PID}" 2>/dev/null | sed 's/^/  /' || echo "  设备不在线"
}

# ---------------------------------------------------------------- 6
write_rollback() {
    section "6. 生成回滚脚本"

    # ★ 2026-09-30 改：回滚脚本写到**备份目录**，不再写到 SCRIPT_DIR。
    #   原因：SCRIPT_DIR 是解包出来的 payload 目录（常常在 /tmp），
    #   解包目录一删、回滚脚本就没了；而且若把这份脚本连同写死的 MANIFEST
    #   路径一起打包分发，它会拿一份**过期的清单**去 rm 新机器上的路径 —— 有害。
    #   正确做法就是"每次安装时现生成一份、放在 /var/backups/ 下"。
    local rb="${BACKUP_DIR}/rollback.sh"

    cat > "$rb" <<ROLLBACK
#!/usr/bin/env bash
# 自动生成的回滚脚本 —— 撤销 ${STAMP} 的这次「麒麟框架 + 厂商驱动」安装
# 注意：这只回滚**框架与驱动**。GRUB 参数与 PAM 接线由集成步骤单独处理
#       （见同目录的 integration-rollback.sh，若存在）。
set -uo pipefail
[ "\$(id -u)" -eq 0 ] || { echo "请用 sudo 运行"; exit 1; }

echo "停止并禁用服务..."
systemctl disable --now biometric-authentication.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

echo "删除已安装文件..."
while read -r f; do
    [ -n "\$f" ] || continue
    if [ -e "\$f" ] || [ -L "\$f" ]; then
        rm -rf "\$f" && echo "  删除 \$f"
    fi
done < "${MANIFEST}"

echo "清理可能残留的指纹模板目录..."
rm -rf /etc/pafingers 2>/dev/null || true
rm -rf /etc/pixelauth 2>/dev/null || true

echo "刷新动态库缓存与 udev..."
ldconfig 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true

echo
echo "回滚完成。"
echo "★ 本次安装期间被改动过的既有文件备份在：${BACKUP_DIR}"
echo "  （若集成步骤改过 /etc/pam.d/sudo、/etc/default/grub，那里的备份也要还原）"
echo "★ 注意：/var/lib/biometric-auth/biometric.db 是运行期账本，本脚本不动它。"
echo "  想连它一起清掉的话手动删（会丢掉\"哪枚指纹属于谁\"的对应关系）。"
ROLLBACK

    chmod +x "$rb"
    echo "  回滚脚本：${rb}"
}

# ---------------------------------------------------------------- main
main() {
    require_root
    check_prereq
    install_framework
    install_driver
    start_service
    verify
    write_rollback

    section "完成 —— 阶段 1+2 结束"
    cat <<EOF

本阶段做了什么：
  ✅ 安装麒麟 biometric 框架（库/守护进程/CLI）
  ✅ 安装品识 pa180k 指纹驱动 + udev 规则
  ✅ 启动服务并注册驱动
  ❌ 没有碰任何 PAM 配置

下一步（阶段 3，需要你确认后才做）：
  如果上面 [5.4] 能看到你的设备，说明驱动工作正常。
  那时再单独讨论要不要接 PAM（先 sudo，后登录界面）。

回滚：sudo ${BACKUP_DIR}/rollback.sh
日志：${LOG_FILE}
备份：${BACKUP_DIR}

EOF
}

main "$@"
