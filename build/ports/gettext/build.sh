#!/bin/bash

# gettext/build.sh —— 从源码编 GNU gettext（整树产物）
#
# 上游：https://savannah.gnu.org/projects/gettext/
# 源码：https://ftpmirror.gnu.org/gettext/gettext-0.21.tar.xz
# 产物：gettext@0.21.0.macos-<arch>.tar.bz2
#
# 版本号的写法有讲究：**上游自己叫 0.21**，索引里叫 `0.21.0`。产物名与安装路径都跟
# 索引走（`0.21.0`），否则 `gettext@0.21.0` 这条依赖引用就指向一个不存在的目录。
# 上游没有 0.21.0 这个 tag，源码仍然取 0.21。
#
# 为什么自建：conda-forge 的 gettext 带 `info/has_prefix`，而它的 `bin/gettext` /
# `msgfmt` 把 `<前缀>/share/locale` 编译进了二进制 —— 前缀替换要动二进制，源码编一遍
# 天生就是对的。
#
# 关掉的四个后端不是省事，是必须：`--disable-java --disable-csharp`（这台机器没有
# JDK / Mono，configure 会先找到再失败）；`--without-emacs`（不往用户机器装 elisp）；
# `--disable-openmp`（gettext 不用它，但会把它拖进依赖面）。
#
# 用法：bash gettext/build.sh [arch]

set -eE
set -u
set -o pipefail

VERSION="0.21.0"          # 索引与安装路径用的名字
SRC_VERSION="0.21"        # 上游实际发布的版本号
SRC_SHA256="d20fcbb537e02dcf1383197ba05bd0734ef7bf5db06bdb241eb69b7d16b73192"
SRC_URL="https://ftpmirror.gnu.org/gettext/gettext-${SRC_VERSION}.tar.xz"

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

for tool in curl make clang codesign tar shasum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gettext-build.XXXXXX")"
trap 'if [ -n "${MW_KEEP:-}" ]; then say "🌊 kept: $WORK"; else rm -rf "$WORK"; fi' EXIT

say "${GREEN}🌊 Downloading gettext ${SRC_VERSION}${RESET}"
bash "$FETCH" "$SRC_URL" "$WORK/gettext.tar.xz"
echo "${SRC_SHA256}  $WORK/gettext.tar.xz" | shasum -a 256 -c - >/dev/null \
    || die "source tarball does not match the pinned sha256"
tar -xJf "$WORK/gettext.tar.xz" -C "$WORK"
SRC="$WORK/gettext-${SRC_VERSION}"
[ -d "$SRC" ] || die "unpacked directory not found: $SRC"

mw_build_env "$ARCH"

# gettext 0.21 里那份 gnulib 的 `obstack.c` 把 `void (*)(void)` 赋给 `noreturn` 的函数
# 指针，clang 15 起这是**默认报错**（-Wincompatible-function-pointer-types），
# 而 0.21 是 2020 年的代码、上游 2023 才修。降级成警告即可，运行时行为不变。
export CFLAGS="$CFLAGS -Wno-incompatible-function-pointer-types -Wno-int-conversion"

PREFIX="$(mw_prefix gettext "$VERSION")"
STAGE_ROOT="$WORK/root"
TREE="$STAGE_ROOT$PREFIX"

say "${GREEN}🌊 Building gettext ${SRC_VERSION} for ${ARCH}${RESET}"
say "   prefix: $PREFIX"
mkdir -p "$TREE"

(
    cd "$SRC"
    ./configure \
        --prefix="$PREFIX" \
        --enable-shared --disable-static \
        --disable-java --disable-native-java --disable-csharp \
        --without-emacs --disable-openmp \
        --disable-dependency-tracking \
        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
    make -j"$(sysctl -n hw.ncpu)"
    make install DESTDIR="$STAGE_ROOT"
)

[ -d "$TREE/lib" ] || die "install did not produce $TREE/lib"
[ -e "$TREE/lib/libintl.dylib" ] || die "libintl was not built"

say "${GREEN}🌊 Relocating and signing${RESET}"
mw_relocate_stage "$STAGE_ROOT"

mkdir -p "$OUT"
TAG="$(mw_bottle_tag "$ARCH")"
ARCHIVE="$OUT/gettext@${VERSION}.${TAG}.tar.bz2"
tar cjf "$ARCHIVE" -C "$TREE" . || die "cannot pack $ARCHIVE"

say ""
say "${GREEN}🌊 Artifact: $ARCHIVE${RESET}"
say "   sha256: $(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
mw_verify_artifact "$ARCHIVE" "$ARCH" || die "artifact failed the upload gates"
