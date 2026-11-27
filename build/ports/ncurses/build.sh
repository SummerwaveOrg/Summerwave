#!/bin/bash

# ncurses/build.sh —— 从源码编 ncurses（整树产物，终端界面的底座）
#
# 上游：https://invisible-island.net/ncurses/
# 源码：https://invisible-island.net/archives/ncurses/ncurses-6.6.tar.gz
# 产物：ncurses@6.6.macos-<arch>.tar.bz2
#
# 为什么自建：conda-forge 的 ncurses 带 `info/has_prefix`，而它是 htop / tmux / ncdu
# 全链的上游；这一层编对了，上面几个包才有干净的依赖闭包。
#
# 三个刻意的选择：
#
#   1. `--enable-widec --enable-overwrite` —— 只编宽字符版，但用「不带 w 的文件名」
#      装出去。于是 `libncurses.dylib` / `ncurses.h` 实际就是宽字符实现，
#      下游不管写 `-lncurses` 还是 `-lncursesw` 都能链接、都能显示 CJK。
#      两套都编（Homebrew 的做法）会多出一倍体积，收益只是「窄字符构建」，
#      而我们的下游全部要重编，没有这个包袱。
#   2. `--with-termlib` —— 把 terminfo 相关的符号拆进 libtinfo，跟主流发行版一致；
#      否则 libncurses 会把 tgetent 之类也导出去。
#   3. terminfo 数据库随包自带（`share/terminfo`），搜索路径是「自己优先，系统兜底」。
#      `--with-terminfo-dirs` 的顺序就是查找顺序。
#
# 用法：bash ncurses/build.sh [arch]

set -eE
set -u
set -o pipefail

VERSION="6.6"
SRC_SHA256="355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11"
SRC_URL="https://invisible-island.net/archives/ncurses/ncurses-${VERSION}.tar.gz"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$HERE/../out}"
ARCH="${1:-arm64}"

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'
say() { printf '%b\n' "$*"; }
die() { printf '%b\n' "${RED_BOLD}🌊 Error: $*${RESET}" >&2; exit 1; }

FETCH="$HERE/../scripts/fetch.sh"
[ -f "$FETCH" ] || die "fetch.sh not found: $FETCH"
BUILD_ENV="$HERE/../scripts/build-env.sh"
[ -f "$BUILD_ENV" ] || die "build-env.sh not found: $BUILD_ENV"
# shellcheck source=../scripts/build-env.sh
source "$BUILD_ENV"

for tool in curl make clang codesign tar; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ncurses-build.XXXXXX")"
# MW_KEEP=1 留着 stage 树看装了些什么（排错用；正常跑完自动删）
trap 'if [ -n "${MW_KEEP:-}" ]; then say "🌊 kept: $WORK"; else rm -rf "$WORK"; fi' EXIT

say "${GREEN}🌊 Downloading ncurses ${VERSION}${RESET}"
bash "$FETCH" "$SRC_URL" "$WORK/ncurses.tar.gz"
echo "${SRC_SHA256}  $WORK/ncurses.tar.gz" | shasum -a 256 -c - >/dev/null \
    || die "source tarball does not match the pinned sha256"
tar -xzf "$WORK/ncurses.tar.gz" -C "$WORK"
SRC="$WORK/ncurses-${VERSION}"
[ -d "$SRC" ] || die "unpacked directory not found: $SRC"

mw_build_env "$ARCH"

PREFIX="$(mw_prefix ncurses "$VERSION")"
STAGE_ROOT="$WORK/root"
TREE="$STAGE_ROOT$PREFIX"

say "${GREEN}🌊 Building ncurses ${VERSION} for ${ARCH}${RESET}"
say "   prefix: $PREFIX"
mkdir -p "$TREE"

(
    cd "$SRC"
    ./configure \
        --prefix="$PREFIX" \
        --with-shared --without-normal --without-debug \
        --with-termlib --enable-widec --enable-overwrite \
        --enable-pc-files --with-pkg-config-libdir="$PREFIX/lib/pkgconfig" \
        --with-terminfo-dirs="$PREFIX/share/terminfo:/usr/share/terminfo" \
        --without-ada --without-manpages --without-tests \
        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
    # 只编库与工具：文档对运行时没用，却能让安装阶段慢十倍。
    make -j"$(sysctl -n hw.ncpu)"
    # install.libs/progs/includes/pc 不碰 man 页；terminfo 由 install.data 负责。
    make install.libs install.progs install.includes DESTDIR="$STAGE_ROOT"
    make install.data DESTDIR="$STAGE_ROOT"
)

[ -d "$TREE/lib" ] || die "install did not produce $TREE/lib"

# 宽字符版的库名一律带 w（libncursesw / libtinfow …）。--enable-overwrite 只改头文件名，
# 不改库名。下游 configure 大多写 `-lncurses`／`-ltinfo`，所以补一组不带 w 的链接：
# 链接期找得到，运行期 install_name 仍是带 w 的真名，不产生第二份二进制。
for lib in ncurses tinfo panel menu form; do
    [ -e "$TREE/lib/lib${lib}w.dylib" ] || continue
    ln -sf "lib${lib}w.dylib" "$TREE/lib/lib${lib}.dylib"
done
for pc in ncurses tinfo panel menu form; do
    [ -e "$TREE/lib/pkgconfig/${pc}w.pc" ] || continue
    ln -sf "${pc}w.pc" "$TREE/lib/pkgconfig/${pc}.pc"
done

[ -e "$TREE/lib/libncursesw.dylib" ] || die "wide-character library not installed"

# ncurses 的 gen-pkgconfig 把 $(LDFLAGS) 整串抄进 .pc 的 `Libs:`，于是
# `-arch arm64 -mmacosx-version-min=15.0 -isysroot /Applications/Xcode.app/...` 全会
# 落到**别人机器上** —— 那串 SDK 路径是构建机的，链接参数也把下游钉死在同一个架构。
# 这些是构建期的自用参数，用 pkg-config 的下游不该看见，装完就地删掉。
# `ncursesw6-config` 同理。
for f in "$TREE"/lib/pkgconfig/*.pc "$TREE"/bin/ncursesw*-config; do
    # 上面补的 ncurses.pc 等是符号链接，sed -i 不认，跳过（内容与带 w 的那份相同）
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    sed -i '' -E 's/ -arch [a-zA-Z0-9_]+//g; s/ -mmacosx-version-min=[0-9.]+//g; s| -isysroot [^ "]+||g' "$f"
done
if grep -rqs -- "-isysroot" "$TREE/lib/pkgconfig"; then
    die "build-only flags survived in the pkg-config files"
fi

say "${GREEN}🌊 Relocating and signing${RESET}"
mw_relocate_stage "$STAGE_ROOT"

mkdir -p "$OUT"
TAG="$(mw_bottle_tag "$ARCH")"
ARCHIVE="$OUT/ncurses@${VERSION}.${TAG}.tar.bz2"
tar cjf "$ARCHIVE" -C "$TREE" . || die "cannot pack $ARCHIVE"

say ""
say "${GREEN}🌊 Artifact: $ARCHIVE${RESET}"
say "   sha256: $(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
mw_verify_artifact "$ARCHIVE" "$ARCH" || die "artifact failed the upload gates"
