#!/bin/bash

# zlib/build.sh —— 从源码编 zlib（整树产物，依赖树的根）
#
# 上游：https://github.com/madler/zlib
# 源码：https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
# 产物：zlib@1.3.1.macos-<arch>.tar.bz2，归档根 = 版本目录的内容（include/ lib/ share/）
#
# 为什么自建：conda-forge / Homebrew 的 zlib 都带各自前缀，且产物里写着
# `info/has_prefix` 那套占位符，装的时候要再做一次二进制前缀替换。源码编一次成型：
# configure 的 --prefix 直接给**装完之后的绝对路径**，`.pc` 与配置里的路径天生就是对的，
# 不需要任何事后替换。
#
# 三条约束，别改：
#   1. 固定上游版本与源码 sha256（下面的值取自官方 tarball，2026-11-26 实测）；
#   2. 两个架构分别编，不要 universal：索引是「每架构一个产物」；
#   3. 顺序只能是「编 → 重定位 → 签名 → 打包」。重定位会作废已有签名。
#
# zlib 只链 libSystem，所以重定位后应当**零改写** —— 有改写就说明链接参数写错了。
#
# 为什么是 1.3.1 而不是索引里原本的 1.2.13：1.2.13 的 zutil.h 在
# `#if defined(MACOS) || defined(TARGET_OS_MAC)` 里把 fdopen 定义成宏，而现代 SDK 的
# 系统头会定义 TARGET_OS_MAC —— 于是 <stdio.h> 里 `FILE *fdopen(int, const char *)`
# 被宏吃掉，clang 报 expected identifier or '('。1.3.1 里这个问题已经不存在。
# soname 两边都是 libz.1.dylib，所以下游不需要重编；只需要把索引里的 deps 引用
# 从 zlib@1.2.13 改成 zlib@1.3.1。
#
# 用法：bash zlib/build.sh [arch]      arch 默认 arm64
# 依赖：Xcode 命令行工具（clang、make、codesign、tar、curl）

set -eE
set -u
set -o pipefail

VERSION="1.3.1"
SRC_SHA256="9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
SRC_URL="https://github.com/madler/zlib/releases/download/v${VERSION}/zlib-${VERSION}.tar.gz"

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

for tool in curl make clang codesign tar python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found (install the Xcode command line tools)"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zlib-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "${GREEN}🌊 Downloading zlib ${VERSION}${RESET}"
bash "$FETCH" "$SRC_URL" "$WORK/zlib.tar.gz"
echo "${SRC_SHA256}  $WORK/zlib.tar.gz" | shasum -a 256 -c - >/dev/null \
    || die "source tarball does not match the pinned sha256"
tar -xzf "$WORK/zlib.tar.gz" -C "$WORK"
SRC="$WORK/zlib-${VERSION}"
[ -d "$SRC" ] || die "unpacked directory not found: $SRC"

mw_build_env "$ARCH"

PREFIX="$(mw_prefix zlib "$VERSION")"      # 装完之后的绝对路径，烘进 configure
STAGE_ROOT="$WORK/root"                    # ≙ 安装根 /
TREE="$STAGE_ROOT$PREFIX"                  # <stage>/opt/macwave/Shore/zlib/<版本>

say "${GREEN}🌊 Building zlib ${VERSION} for ${ARCH}${RESET}"
say "   prefix: $PREFIX"
mkdir -p "$TREE"

(
    cd "$SRC"
    # zlib 的 configure 只认 CC/CFLAGS 环境变量；DESTDIR 由 Makefile 支持。
    CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
        ./configure --prefix="$PREFIX" --shared
    make -j"$(sysctl -n hw.ncpu)" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
    make install DESTDIR="$STAGE_ROOT"
)

[ -d "$TREE/lib" ] || die "install did not produce $TREE/lib"

say "${GREEN}🌊 Relocating and signing${RESET}"
mw_relocate_stage "$STAGE_ROOT"

mkdir -p "$OUT"
TAG="$(mw_bottle_tag "$ARCH")"
ARCHIVE="$OUT/zlib@${VERSION}.${TAG}.tar.bz2"
tar cjf "$ARCHIVE" -C "$TREE" . || die "cannot pack $ARCHIVE"

say ""
say "${GREEN}🌊 Artifact: $ARCHIVE${RESET}"
say "   sha256: $(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
mw_verify_artifact "$ARCHIVE" "$ARCH" || die "artifact failed the upload gates"
