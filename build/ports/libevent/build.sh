#!/bin/bash

# libevent/build.sh —— 从源码编 libevent（整树产物，tmux 的上游）
#
# 上游：https://github.com/libevent/libevent
# 源码：https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz
# 产物：libevent@2.1.12.macos-<arch>.tar.bz2
#
# 为什么是 2.1.12 而不是索引里 amd64 现用的 2.1.13：**上游没有 2.1.13 这个版本**，
# 那是下游打包方自己的编号。既然要自建，就统一到上游最新的稳定 tag，
# 于是两个架构共用同一个版本号（引用 `libevent@2.1.13` 的三条 tmux 记录要跟着改成
# `2.1.12`，见 ~/MD/Summerwave/1.0-切换操作手册-数据侧.md）。
# 2.1.x 的 soname 一直是 `libevent-2.1.7.dylib`，所以这条级联不需要重编 tmux 本身。
#
# `--disable-openssl`：tmux 不用 libevent 的 bufferevent_openssl，开了就要把 openssl
# 拖进依赖面。真需要时再单独评估。
#
# 用法：bash libevent/build.sh [arch]

set -eE
set -u
set -o pipefail

VERSION="2.1.12"
SRC_SHA256="92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb"
SRC_URL="https://github.com/libevent/libevent/releases/download/release-${VERSION}-stable/libevent-${VERSION}-stable.tar.gz"

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/libevent-build.XXXXXX")"
trap 'if [ -n "${MW_KEEP:-}" ]; then say "🌊 kept: $WORK"; else rm -rf "$WORK"; fi' EXIT

say "${GREEN}🌊 Downloading libevent ${VERSION}${RESET}"
bash "$FETCH" "$SRC_URL" "$WORK/libevent.tar.gz"
echo "${SRC_SHA256}  $WORK/libevent.tar.gz" | shasum -a 256 -c - >/dev/null \
    || die "source tarball does not match the pinned sha256"
tar -xzf "$WORK/libevent.tar.gz" -C "$WORK"
SRC="$WORK/libevent-${VERSION}-stable"
[ -d "$SRC" ] || die "unpacked directory not found: $SRC"

mw_build_env "$ARCH"

PREFIX="$(mw_prefix libevent "$VERSION")"
STAGE_ROOT="$WORK/root"
TREE="$STAGE_ROOT$PREFIX"

say "${GREEN}🌊 Building libevent ${VERSION} for ${ARCH}${RESET}"
say "   prefix: $PREFIX"
mkdir -p "$TREE"

(
    cd "$SRC"
    ./configure \
        --prefix="$PREFIX" \
        --enable-shared --disable-static \
        --disable-openssl --disable-samples --disable-libevent-regress \
        --disable-dependency-tracking \
        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
    make -j"$(sysctl -n hw.ncpu)"
    make install DESTDIR="$STAGE_ROOT"
)

[ -d "$TREE/lib" ] || die "install did not produce $TREE/lib"

say "${GREEN}🌊 Relocating and signing${RESET}"
mw_relocate_stage "$STAGE_ROOT"

mkdir -p "$OUT"
TAG="$(mw_bottle_tag "$ARCH")"
ARCHIVE="$OUT/libevent@${VERSION}.${TAG}.tar.bz2"
tar cjf "$ARCHIVE" -C "$TREE" . || die "cannot pack $ARCHIVE"

say ""
say "${GREEN}🌊 Artifact: $ARCHIVE${RESET}"
say "   sha256: $(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
mw_verify_artifact "$ARCHIVE" "$ARCH" || die "artifact failed the upload gates"
