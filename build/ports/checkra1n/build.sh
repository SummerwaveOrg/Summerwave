#!/bin/bash

# checkra1n/build.sh —— 从上游 .dmg 里取出 checkra1n 的 CLI 并重打包（**不重新编译**）
#
# 上游：https://checkra.in（assets.checkra.in 直链，URL 路径里那段就是 dmg 的 sha256）
# 产物：checkra1n-<版本>.tar.xz，布局 bin/ + lib/
#
# 为什么要重打包：上游只发 .dmg（里面是 checkra1n.app），安装方式是让用户自己
# 「打开应用 → 拖进 Applications」。而它的二进制本身就是个完整 CLI：
#
#   $ checkra1n --help
#     -c, --cli        Force command line
#     -t, --tui        Start a terminal graphical user interface
#     -p, --pongo      Boots to a Pongo shell
#     -w, --wui <IPV4> <PORT>   Start webra1n
#
# 所以这里只做「取出 + 摆位置 + 重签」，字节不改（除了 install_name 那条引用）。
#
# 已知限制，写在这里免得以后当成 bug：
#   1. **只有 x86_64**。上游 0.12.4 仍只发 Intel 版，Apple 芯片机器靠 Rosetta 2 跑，
#      所以索引两个架构共用同一份产物。
#   2. **需要 root**：`sudo checkra1n -c`。它走 USB 与设备通信、改 rootfs。
#   3. min_os 10.9，且**上游未签名**（`codesign -dv` 报 "not signed at all"），
#      这里统一 ad-hoc 重签。
#
# 用法：CHECKRA1N_VERSION=0.12.3 bash checkra1n/build.sh [已有 dmg 路径] [输出目录]

set -eE
set -u
set -o pipefail

# 版本 → dmg 的 sha256。所有版本都还是 beta（上游只发 beta），版本号里不写 beta。
# 0.12.4 是当前主流版本；0.12.3 留作退路（0.12.4 对部分机型改动过 pongo）。
VERSION="${CHECKRA1N_VERSION:-0.12.4}"
case "$VERSION" in
    0.12.4) SRC_SHA256="754bb6ec4747b2e700f01307315da8c9c32c8b5816d0fe1e91d1bdfc298fe07b" ;;
    0.12.3) SRC_SHA256="08be5f1b146447a36ae40446d60304451bce9524ba5a3922ebfee4f37b88d15c" ;;
    *) printf '\033[1;31m🌊 Error: unknown version %s (known: 0.12.4 0.12.3)\033[0m\n' "$VERSION" >&2; exit 1 ;;
esac
SRC_URL="https://assets.checkra.in/downloads/macos/${SRC_SHA256}/checkra1n%20beta%20${VERSION}.dmg"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${2:-$PWD/out}"
LOCAL_DMG="${1:-}"

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

say() { printf '%b\n' "$*"; }
die() { printf '%b\n' "${RED_BOLD}🌊 Error: $*${RESET}" >&2; exit 1; }

RELOCATE_SH="$HERE/../scripts/relocate_stage.sh"
[ -f "$RELOCATE_SH" ] || die "relocate_stage.sh not found: $RELOCATE_SH"
FETCH="$HERE/../scripts/fetch.sh"
[ -f "$FETCH" ] || die "fetch.sh not found: $FETCH"

for tool in hdiutil codesign otool install_name_tool tar shasum xattr; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/checkra1n-repack.XXXXXX")"
trap 'hdiutil detach "$WORK/mnt" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

if [[ -n "$LOCAL_DMG" ]]; then
    say "${GREEN}🌊 Using local dmg: $LOCAL_DMG${RESET}"
    cp "$LOCAL_DMG" "$WORK/c.dmg"
else
    bash "$FETCH" "$SRC_URL" "$WORK/c.dmg"
fi
echo "$SRC_SHA256  $WORK/c.dmg" | shasum -a 256 -c - >/dev/null \
    || die "dmg does not match the published sha256"

say "${GREEN}🌊 Mounting${RESET}"
mkdir -p "$WORK/mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$WORK/mnt" "$WORK/c.dmg" >/dev/null

APP="$WORK/mnt/checkra1n.app/Contents/MacOS"
[[ -x "$APP/checkra1n" ]] || die "unexpected dmg layout: no checkra1n.app/Contents/MacOS/checkra1n"

# stage 摆成运行时布局：客户端把整树落到 bin/checkra1n@<版本>/，
# 所以可执行文件在 bin/、它依赖的 dylib 在 lib/。
STAGE="$WORK/stage"
PKG="$STAGE/bin/checkra1n@${VERSION}"
mkdir -p "$PKG/bin" "$PKG/lib"
cp "$APP/checkra1n" "$PKG/bin/"
cp "$APP/libfatman.dylib" "$PKG/lib/"

# 上游写的是 @loader_path/libfatman.dylib（与可执行文件同目录）。挪进 lib/ 之后这条
# 引用要一起改，否则 dyld 找不到。
install_name_tool -change @loader_path/libfatman.dylib \
    @loader_path/../lib/libfatman.dylib "$PKG/bin/checkra1n"

# dmg 里的文件带扩展属性（resource fork），codesign 会拒绝：
#   "resource fork, Finder information, or similar detritus not allowed"
# 先清干净再改引用 / 签名。
xattr -cr "$PKG"

# 重定位必须在签名之前：install_name_tool 改写会作废签名（上游本来就没签）。
bash "$RELOCATE_SH" "$STAGE"

codesign --force --sign - "$PKG/bin/checkra1n" >/dev/null 2>&1 \
    || die "ad-hoc signing failed for bin/checkra1n"
codesign --force --sign - "$PKG/lib/libfatman.dylib" >/dev/null 2>&1 \
    || die "ad-hoc signing failed for lib/libfatman.dylib"

mkdir -p "$OUT"
tar -cJf "$OUT/checkra1n-${VERSION}.tar.xz" -C "$PKG" bin lib

say ""
say "${GREEN}🌊 Artifact in $OUT${RESET}"
printf '  %-34s %10s B  %s\n' "checkra1n-${VERSION}.tar.xz" \
    "$(stat -f%z "$OUT/checkra1n-${VERSION}.tar.xz")" \
    "$(shasum -a 256 "$OUT/checkra1n-${VERSION}.tar.xz" | cut -d' ' -f1)"
say ""
say "自检：bin/checkra1n --version（免 root；真正刷机才要 sudo checkra1n -c）"
say "闸门：bash scripts/selfbuilt_check.sh <归档> --arch amd64 --tree --main bin/checkra1n"
say "注意：产物是 x86_64，Apple 芯片靠 Rosetta 2；索引两个架构共用这一份。"
