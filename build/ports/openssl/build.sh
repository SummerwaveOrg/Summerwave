#!/bin/bash

# openssl/build.sh —— 从源码编 openssl（整树产物）
#
# 上游：https://github.com/openssl/openssl
# 源码：https://github.com/openssl/openssl/releases/download/openssl-3.0.15/openssl-3.0.15.tar.gz
# 产物：openssl@3.0.15.macos-<arch>.tar.bz2，归档根 = 版本目录的内容（bin/ lib/ include/ ssl/）
#
# 为什么自建：conda-forge 的 openssl 带它自己的前缀（`info/has_prefix` 里那串
# `_h_env_placehold_…`），装的时候要做二进制前缀替换；而它是被依赖最多的包之一
# （git / curl / python 全链 libssl），值得一次编对。
#
# 三条约束，别改：
#   1. 固定上游版本与源码 sha256；
#   2. 两个架构分别编（darwin64-arm64-cc / darwin64-x86_64-cc），不要 universal；
#   3. 顺序只能是「编 → 重定位 → 签名 → 打包」。
#
# 刻意关掉的两项：
#   * `no-zlib` —— 链接 zlib 只会让压缩握手可用（CRIME/BREACH 那一类），而我们要
#     先把依赖面收窄到一个不依赖任何自建库的 openssl。将来要开再单独评估。
#   * `no-tests` / `no-ssl-trace` 之外尽量少关：`ssl/openssl.cnf` 仍然按 prefix 装。
#
# 用法：bash openssl/build.sh [arch]
# 依赖：Xcode 命令行工具 + perl（macOS 自带）

set -eE
set -u
set -o pipefail

VERSION="3.0.15"
SRC_SHA256="23c666d0edf20f14249b3d8f0368acaee9ab585b09e1de82107c66e1f3ec9533"
SRC_URL="https://github.com/openssl/openssl/releases/download/openssl-${VERSION}/openssl-${VERSION}.tar.gz"

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

for tool in curl perl make clang codesign tar python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/openssl-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "${GREEN}🌊 Downloading openssl ${VERSION}${RESET}"
bash "$FETCH" "$SRC_URL" "$WORK/openssl.tar.gz"
echo "${SRC_SHA256}  $WORK/openssl.tar.gz" | shasum -a 256 -c - >/dev/null \
    || die "source tarball does not match the pinned sha256"
tar -xzf "$WORK/openssl.tar.gz" -C "$WORK"
SRC="$WORK/openssl-${VERSION}"
[ -d "$SRC" ] || die "unpacked directory not found: $SRC"

mw_build_env "$ARCH"

PREFIX="$(mw_prefix openssl "$VERSION")"
STAGE_ROOT="$WORK/root"
TREE="$STAGE_ROOT$PREFIX"

case "$ARCH" in
    arm64)  TARGET=darwin64-arm64-cc ;;
    x86_64) TARGET=darwin64-x86_64-cc ;;
    *)      die "unknown arch: $ARCH" ;;
esac

say "${GREEN}🌊 Building openssl ${VERSION} for ${ARCH} (${TARGET})${RESET}"
say "   prefix: $PREFIX"
mkdir -p "$TREE"

(
    cd "$SRC"
    # Configure 认的是它自己的变量名；把 -arch / -isysroot / -mmacosx-version-min
    # 传进去，保证产物顶到地板而不是构建机的系统版本。
    perl ./Configure "$TARGET" \
        --prefix="$PREFIX" \
        --openssldir="$PREFIX/ssl" \
        shared no-zlib no-tests \
        --with-rand-seed=getrandom \
        CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
    # 只能整棵树编。`build_libs` / `build_programs` 各自会再 fork 一个 make，
    # 两个一起 -j 会并发写同一批 `.d.tmp`（mv: No such file or directory）。
    make -j"$(sysctl -n hw.ncpu)"
    make install_sw DESTDIR="$STAGE_ROOT"
)

[ -d "$TREE/lib" ] || die "install did not produce $TREE/lib"

say "${GREEN}🌊 Relocating and signing${RESET}"
mw_relocate_stage "$STAGE_ROOT"

mkdir -p "$OUT"
TAG="$(mw_bottle_tag "$ARCH")"
ARCHIVE="$OUT/openssl@${VERSION}.${TAG}.tar.bz2"
tar cjf "$ARCHIVE" -C "$TREE" . || die "cannot pack $ARCHIVE"

say ""
say "${GREEN}🌊 Artifact: $ARCHIVE${RESET}"
say "   sha256: $(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
mw_verify_artifact "$ARCHIVE" "$ARCH" || die "artifact failed the upload gates"
