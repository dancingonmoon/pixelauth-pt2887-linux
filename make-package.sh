#!/usr/bin/env bash
# ============================================================================
# 打包 —— 把两个产品各打成一个可交付的 tar.gz
#
# 用法：
#   ./make-package.sh            # 打包两个产品
#   ./make-package.sh a          # 只打产品 A
#   ./make-package.sh b          # 只打产品 B
#
# 产物（放在 dist/ 下）：
#   pixelauth-kylin-<版本>.tar.gz     产品 A：麒麟栈（sudo + 录入）
#   pixelauth-fprintd-<版本>.tar.gz   产品 B：fprintd（锁屏 + 登录）
#
# 每个包里都带 checksums.sha256；安装脚本会先校验再动手。
#
# 注（仓库版）：本仓库的产品 A 不含厂商二进制与本机快照 —— 直接打包出的 A 包
# 需要使用者自备厂商文件（见 product-a-kylin/payload/stage/README-自备文件.md）。
# 产品 B 打出的包是完整可用的。
# ============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="${ROOT}/dist"
WHICH="${1:-both}"

mkdir -p "$DIST"

# 生成校验和：覆盖 payload 下的所有文件（相对路径，解包后照样能校验）
#
# ★ 2026-09-30 修：**排除规则必须和打包时的排除规则一致**。
#   第一版只排除了 checksums 自己，结果把 `payload/src/build/` 里的 meson 产物
#   也算进了校验和；而打包时那些目录被删掉了 → 解包后 `sha256sum -c` 必然报
#   "没有那个文件或目录"，把校验搞成了永远失败。
gen_checksums() {
    local dir="$1"
    ( cd "$dir" && find payload -type f \
        ! -name 'checksums.sha256' \
        ! -path '*/build/*' \
        ! -path '*/__pycache__/*' \
        ! -name '*.pyc' -print0 \
        | sort -z | xargs -0 sha256sum > checksums.sha256 )
    echo "    ✅ checksums.sha256（$(wc -l < "$dir/checksums.sha256") 个文件）"
}

# 打包一个产品
pack() {
    local key="$1" dir="$2" name="$3"
    echo
    echo "============================================================"
    echo " 打包 ${name}"
    echo "============================================================"

    [ -d "$dir" ] || { echo "ERROR: 找不到 ${dir}"; return 1; }
    local ver; ver="$(cat "${dir}/VERSION" 2>/dev/null || echo 0.0.0)"
    local out="${DIST}/${name}-${ver}.tar.gz"

    # --- 打包前的自检 ---
    echo "[自检]"
    local problems=0
    for f in install.sh README.md VERSION; do
        [ -e "${dir}/${f}" ] || { echo "  ❌ 缺 ${f}"; problems=1; }
    done
    [ -d "${dir}/payload" ] || { echo "  ❌ 缺 payload/"; problems=1; }
    for f in "${dir}"/payload/*.sh "${dir}"/install.sh; do
        bash -n "$f" 2>/dev/null || { echo "  ❌ 语法错误：$(basename "$f")"; problems=1; }
    done
    [ "$problems" -eq 0 ] && echo "  ✅ 文件齐、脚本语法全过"

    # 快照对产品 A 是可选的，但没抓的话要提醒
    if [ "$key" = "a" ] && [ ! -f "${dir}/state-snapshot.tar.gz" ]; then
        echo "  ⚠️  没有 state-snapshot.tar.gz —— 建议先跑 payload/snapshot.sh，"
        echo "      否则重装系统后要重新录指纹（模板还在芯片里，但对应关系会丢）"
    fi

    echo "[生成校验和]"
    gen_checksums "$dir"

    echo "[打包]"
    # 用 staging 目录，保证解包出来是一个带版本号的顶层目录
    local stage; stage="$(mktemp -d)"
    local top; top="$(basename "${name}-${ver}")"
    mkdir -p "${stage}/${top}"
    cp -a "${dir}/." "${stage}/${top}/"
    # 去掉不该进包的东西（**任意层级** —— meson 的 build/ 在 payload/src/ 下）
    find "${stage}/${top}" -type d -name build -prune -exec rm -rf {} + 2>/dev/null
    find "${stage}/${top}" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
    find "${stage}/${top}" -name '*.pyc' -delete 2>/dev/null

    tar -czf "$out" -C "$stage" "$top" || { rm -rf "$stage"; echo "ERROR: 打包失败"; return 1; }
    rm -rf "$stage"

    echo "    ✅ ${out}（$(du -h "$out" | cut -f1)）"

    echo "[验证]"
    tar -tzf "$out" >/dev/null 2>&1 && echo "    ✅ 压缩包可正常解开" || echo "    ❌ 压缩包坏了"
    local n; n=$(tar -tzf "$out" | wc -l)
    echo "    ✅ 含 ${n} 个条目"
    tar -tzf "$out" | grep -q 'checksums.sha256' && echo "    ✅ 校验和文件在包里"
    echo
    echo " 交付物：${out}"
}

case "$WHICH" in
    a|A) pack a "${ROOT}/product-a-kylin"  pixelauth-kylin ;;
    b|B) pack b "${ROOT}/product-b-fprintd" pixelauth-fprintd ;;
    *)   pack a "${ROOT}/product-a-kylin"  pixelauth-kylin
         pack b "${ROOT}/product-b-fprintd" pixelauth-fprintd ;;
esac

echo
echo "============================================================"
echo " dist/ 内容："
ls -lh "$DIST" 2>/dev/null | tail -n +2 | sed 's/^/   /'
echo "============================================================"
