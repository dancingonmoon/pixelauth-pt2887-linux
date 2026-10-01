#!/bin/bash
# ============================================================================
# 构建「打过补丁的 fprintd」.deb —— 重新登记（re-register）安全修复
#
#   补丁（re-register-fix.patch，约 100 行、其中一半是注释）：
#     把"重新登记该手指"时删除旧记录的动作，从 EnrollStart 开头
#     推迟到去重检查通过之后；匹配到"正在登记的那根手指"不再判为重复。
#     修复现象：GNOME 里重新登记 + 按错手指（或中途放弃）→ 旧指纹被毁。
#
# 用法： ./build.sh
#   · 首次运行会用 sudo 装几个构建依赖（会提示输密码）：
#       debhelper dh-exec libpam0g-dev libpolkit-gobject-1-dev libsystemd-dev
#   · 之后全程普通用户；产物在 out/（fprintd 与 libpam-fprintd 两个包，
#     安装时必须一起装 —— 缺一个会造成 apt「已损坏个数 > 0」依赖真空）
#   · 幂等：重复运行会重新解包、打补丁、构建
#
# 来源：Ubuntu noble 的 fprintd 1.94.3-1（源码 tar 若不在 src-cache/ 会自动下载）
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_CACHE="$HERE/src-cache"
WORK="$HERE/work"
OUT="$HERE/out"
PATCH="$HERE/re-register-fix.patch"

ORIG_TAR="fprintd_1.94.3.orig.tar.bz2"
DEB_TAR="fprintd_1.94.3-1.debian.tar.xz"
VER_PA="1.94.3-1+pa1"
BASE_URL="http://archive.ubuntu.com/ubuntu/pool/main/f/fprintd"

say() { echo "==> $*"; }

fetch_src() {
    local f="$1"
    [ -f "$SRC_CACHE/$f" ] && return 0
    say "下载源码：$f"
    mkdir -p "$SRC_CACHE"
    curl -sfO --output-dir "$SRC_CACHE" "$BASE_URL/$f" \
        || { echo "ERROR: 下载失败：$BASE_URL/$f"; exit 1; }
}

# ---------------------------------------------------------------- 1) 构建依赖
DEPS_NEED=()
for p in debhelper dh-exec libpam0g-dev libpolkit-gobject-1-dev libsystemd-dev; do
    dpkg -s "$p" >/dev/null 2>&1 || DEPS_NEED+=("$p")
done
if [ "${#DEPS_NEED[@]}" -gt 0 ]; then
    say "缺构建依赖：${DEPS_NEED[*]} —— 用 sudo 安装（会提示输密码）"
    sudo apt-get update -qq || true
    sudo apt-get install -y "${DEPS_NEED[@]}"
else
    say "构建依赖齐了"
fi

# ---------------------------------------------------------------- 2) 解包 + 打补丁
fetch_src "$ORIG_TAR"
fetch_src "$DEB_TAR"
say "全新解包 + 打补丁"
rm -rf "$WORK"
mkdir -p "$WORK"
tar -xjf "$SRC_CACHE/$ORIG_TAR" -C "$WORK"
TREE="$WORK/fprintd-v1.94.3"
tar -xJf "$SRC_CACHE/$DEB_TAR" -C "$TREE"
( cd "$TREE" && patch -p1 --dry-run < "$PATCH" >/dev/null && patch -p1 < "$PATCH" )
say "补丁已应用（device.c 中 [pa] 标记 $(grep -c '\[pa\]' "$TREE/src/device.c") 处）"

# ---------------------------------------------------------------- 3) changelog
say "加 changelog 条目（版本 $VER_PA）"
{
cat <<EOF
fprintd ($VER_PA) noble; urgency=medium

  * [pa] 重新登记安全修复（本地补丁，非官方）：
    EnrollStart 不再立刻删除该手指的旧记录；删除推迟到去重检查通过之后。
    匹配到自己（重新登记）不再判为重复。修复 GNOME「重新登记该手指」在
    按错手指/中途放弃时把旧指纹毁掉的问题。

 -- pixelauth-pt2887-linux <dancingonmoon@users.noreply.github.com>  $(date -R)

EOF
cat "$TREE/debian/changelog"
} > /tmp/pa-changelog.new
mv /tmp/pa-changelog.new "$TREE/debian/changelog"

# ---------------------------------------------------------------- 4) 构建
# DEB_BUILD_PROFILES=nodoc：把 fprintd-doc 包从 dh_listpackages 里剔掉。
#   （少了它，debian/rules 会开 -Dgtk_doc=true → configure 就要 xsltproc；
#     DEB_BUILD_OPTIONS 里的 nodoc 只管 debhelper，管不到这个剖面。）
say "dpkg-buildpackage（nocheck + nodoc 剖面；跳过测试与文档包）"
( cd "$TREE" && DEB_BUILD_OPTIONS="nocheck nodoc" DEB_BUILD_PROFILES="nodoc" \
      dpkg-buildpackage -b -uc -us -d )

# ---------------------------------------------------------------- 5) 收产物
#   ★ 必须收【两个】包：fprintd 和 libpam-fprintd。只装 fprintd 会让
#     libpam-fprintd 的「fprintd (= 1.94.3-1)」依赖悬空 → apt 报
#     「已损坏个数 > 0」，全部更新装不上（2026-10-01 踩过）。
mkdir -p "$OUT"
cp "$WORK"/fprintd_"$VER_PA"_*.deb "$OUT/" 2>/dev/null || cp "$WORK"/fprintd_*.deb "$OUT/"
if ls "$WORK"/libpam-fprintd_"$VER_PA"_*.deb >/dev/null 2>&1; then
    cp "$WORK"/libpam-fprintd_"$VER_PA"_*.deb "$OUT/"
else
    say "⚠️ 没找到 libpam-fprintd +pa1 产物 —— install 脚本 apply 会拒绝（防依赖真空）"
fi
if [ ! -f "$OUT/fprintd_1.94.3-1_amd64.deb" ]; then
    say "下载原版 fprintd .deb（回滚用）"
    ( cd "$OUT" && apt-get download fprintd 2>/dev/null ) \
        || ( cd "$OUT" && curl -sO "http://archive.ubuntu.com/ubuntu/pool/main/f/fprintd/fprintd_1.94.3-1_amd64.deb" )
fi
if [ ! -f "$OUT/libpam-fprintd_1.94.3-1_amd64.deb" ]; then
    say "下载原版 libpam-fprintd .deb（回滚用）"
    ( cd "$OUT" && apt-get download libpam-fprintd 2>/dev/null ) \
        || ( cd "$OUT" && curl -sO "http://archive.ubuntu.com/ubuntu/pool/main/f/fprintd/libpam-fprintd_1.94.3-1_amd64.deb" )
fi

say "产物："
ls -l "$OUT"
say "校验和："
sha256sum "$OUT"/fprintd_*.deb "$OUT"/libpam-fprintd_*.deb
echo
say "下一步： sudo $HERE/install-fprintd-patched.sh apply"
