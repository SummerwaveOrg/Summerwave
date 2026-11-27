#!/bin/bash

# zstd/build.sh —— 从源码编 Zstandard（整树产物）
#
# 上游：https://github.com/facebook/zstd
# 源码：https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
# 产物：zstd@1.5.7.macos-<arch>.tar.bz2
#
# 为什么自建：conda-forge 的 zstd 带 `info/has_prefix`；它被 xz / 部分归档工具
# 间接依赖，前缀补丁一次消掉。
#
# zstd 没有 configure，直接吃 Makefile 的 PREFIX/DESTDIR。注意两点：
#   * `-j` 只能给 `make` 一次，不能二次 make 复用同一个 tree；
#   * 库名是 `libzstd.1.dylib`（不带补丁号），install_name 由 Makefile 里的
#     `-install_name` 决定，重定位为此基本零改写。
#
# 用法：bash zstd/build.sh [arch]

set -eE
set -u
set -o pipefail

VERSION="1.5.7"
SRC_SHA256="eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3"
SRC_URL="https://github.com/facebook/zstd/releases/download/v${VERSION}/zstd-${VERSION}.tar.gz"

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zstd-build.XXXXXX")"
trap 'if [ -n "${MW_KEEP:-}" ]; then say "🌊 kept: $WORK"; else rm -rf "$WORK"; fi' EXIT

say "${GREEN}🌊 Downloading zstd ${VERSION}${RESET}"
bash "$FETCH" "$SRC_URL" "$WORK/zstd.tar.gz"
echo "${SRC_SHA256}  $WORK/zstd.tar.gz" | shasum -a 256 -c - >/dev/null \
    || die "source tarball does not match the pinned sha256"
tar -xzf "$WORK/zstd.tar.gz" -C "$WORK"
SRC="$WORK/zstd-${VERSION}"
[ -d "$SRC" ] || die "unpacked directory not found: $SRC"

mw_build_env "$ARCH"

PREFIX="$(mw_prefix zstd "$VERSION")"
STAGE_ROOT="$WORK/root"
TREE="$STAGE_ROOT$PREFIX"

say "${GREEN}🌊 Building zstd ${VERSION} for ${ARCH}${RESET}"
say "   prefix: $PREFIX"
mkdir -p "$TREE"

(
    cd "$SRC"
    # 工具链变量只能从**环境**给，不能当 make 参数给：命令行变量会覆盖 Makefile 里的
    # `$(ZSTD_DYNLIB): LDFLAGS += -shared`，动态库那一行就丢了 -shared，
    # clang 于是拒绝 -install_name/-compatibility_version。mw_build_env 已经 export 了。
    make -j"$(sysctl -n hw.ncpu)" PREFIX="$PREFIX"
    # zstd 的 install 目标支持 DESTDIR，路径一律「$DESTDIR$PREFIX/...」
    make install PREFIX="$PREFIX" DESTDIR="$STAGE_ROOT"
)

[ -d "$TREE/lib" ] || die "install did not produce $TREE/lib"

say "${GREEN}🌊 Relocating and signing${RESET}"
mw_relocate_stage "$STAGE_ROOT"

mkdir -p "$OUT"
TAG="$(mw_bottle_tag "$ARCH")"
ARCHIVE="$OUT/zstd@${VERSION}.${TAG}.tar.bz2"
tar cjf "$ARCHIVE" -C "$TREE" . || die "cannot pack $ARCHIVE"

say ""
say "${GREEN}🌊 Artifact: $ARCHIVE${RESET}"
say "   sha256: $(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
mw_verify_artifact "$ARCHIVE" "$ARCH" || die "artifact failed the upload gates"
