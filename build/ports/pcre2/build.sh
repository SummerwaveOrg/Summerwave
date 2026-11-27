#!/bin/bash

# pcre2/build.sh —— 从源码编 PCRE2（整树产物）
#
# 上游：https://github.com/PCRE2Project/pcre2
# 源码：https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.42/pcre2-10.42.tar.gz
# 产物：pcre2@10.42.macos-<arch>.tar.bz2
#
# 为什么自建：conda-forge 的 pcre2 带 `info/has_prefix`；它是 git / grep / ripgrep-class
# 工具的正则后端，换掉它等于同时消掉一批依赖的前缀补丁。
#
# 八位、十六位、三十二位三种宽度**全部编**：`pcre2-16`／`pcre2-32` 的库名不同
# （libpcre2-16 / libpcre2-32），不存在覆盖问题，而少编一种就得为个别下游再开一次端口。
# JIT 在 arm64 与 x86_64 都可用，打开。
#
# 用法：bash pcre2/build.sh [arch]

set -eE
set -u
set -o pipefail

VERSION="10.42"
SRC_SHA256="c33b418e3b936ee3153de2c61cc638e7e4fe3156022a5c77d0711bcbb9d64f1f"
SRC_URL="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${VERSION}/pcre2-${VERSION}.tar.gz"

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pcre2-build.XXXXXX")"
trap 'if [ -n "${MW_KEEP:-}" ]; then say "🌊 kept: $WORK"; else rm -rf "$WORK"; fi' EXIT

say "${GREEN}🌊 Downloading pcre2 ${VERSION}${RESET}"
bash "$FETCH" "$SRC_URL" "$WORK/pcre2.tar.gz"
echo "${SRC_SHA256}  $WORK/pcre2.tar.gz" | shasum -a 256 -c - >/dev/null \
    || die "source tarball does not match the pinned sha256"
tar -xzf "$WORK/pcre2.tar.gz" -C "$WORK"
SRC="$WORK/pcre2-${VERSION}"
[ -d "$SRC" ] || die "unpacked directory not found: $SRC"

mw_build_env "$ARCH"

PREFIX="$(mw_prefix pcre2 "$VERSION")"
STAGE_ROOT="$WORK/root"
TREE="$STAGE_ROOT$PREFIX"

say "${GREEN}🌊 Building pcre2 ${VERSION} for ${ARCH}${RESET}"
say "   prefix: $PREFIX"
mkdir -p "$TREE"

(
    cd "$SRC"
    ./configure \
        --prefix="$PREFIX" \
        --enable-shared --disable-static \
        --enable-pcre2-16 --enable-pcre2-32 \
        --enable-jit --enable-pcre2grep-jit \
        --enable-pcre2grep-callout \
        --enable-unicode \
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
ARCHIVE="$OUT/pcre2@${VERSION}.${TAG}.tar.bz2"
tar cjf "$ARCHIVE" -C "$TREE" . || die "cannot pack $ARCHIVE"

say ""
say "${GREEN}🌊 Artifact: $ARCHIVE${RESET}"
say "   sha256: $(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
mw_verify_artifact "$ARCHIVE" "$ARCH" || die "artifact failed the upload gates"
