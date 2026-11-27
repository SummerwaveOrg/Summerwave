#!/bin/bash

# tar/build.sh —— 可复现地编出 GNU tar（单文件产物，两个架构分别编）
#
# 上游：https://savannah.gnu.org/projects/tar/
# 源码：https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz
# 产物：tar-<架构>（裸可执行文件，索引里 file: "tar-<架构>"）

set -eE
set -u
set -o pipefail

VERSION="1.35"
SRC_SHA256="4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16"
SRC_URL="https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$PWD/out}"

GREEN='\033[32m'
RED_BOLD='\033[1;31m'
RESET='\033[0m'

say() { printf '%b\n' "$*"; }
die() { printf '%b\n' "${RED_BOLD}🌊 Error: $*${RESET}" >&2; exit 1; }
RELOCATE_SH="$HERE/../scripts/relocate_stage.sh"
[ -f "$RELOCATE_SH" ] || die "relocate_stage.sh not found: $RELOCATE_SH"
FETCH="$HERE/../scripts/fetch.sh"
[ -f "$FETCH" ] || die "fetch.sh not found: $FETCH"

for tool in curl clang codesign make shasum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found (install the Xcode command line tools)"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tar-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "${GREEN}🌊 Downloading tar ${VERSION}${RESET}"
bash "$FETCH" "$SRC_URL" "$WORK/src.tar"
echo "${SRC_SHA256}  $WORK/src.tar" | shasum -a 256 -c - >/dev/null \
    || die "source tarball does not match the published sha256"
tar -xf "$WORK/src.tar" -C "$WORK"
SRC="$WORK/tar-${VERSION}"

SDK="$(xcrun --show-sdk-path)"

build_one() {
    local arch="$1" carm="$2"
    # 单文件产物：客户端落到 bin/<名>@<版本>/<名>，所以 stage 也摆成这样，
    # relocate 才能按最终位置算出正确的相对路径。
    local stage="$WORK/stage-$arch"
    local tree="$stage/bin/tar@${VERSION}"

    say "${GREEN}🌊 Building ${arch}${RESET}"
    rm -rf "$WORK/build-$arch"
    # -p 保留 mtime：不保留的话 y.tab.c 与 parse.y 的新旧关系是随机的，
    # make 可能去跑 bison 重新生成，而新版 bison 编不了 bash 5.3 的
    # parse.y（"symbol YYEOF is used, but is not defined"）。
    cp -Rp "$SRC" "$WORK/build-$arch"
    (
        cd "$WORK/build-$arch"
        LIBS=-liconv ./configure --prefix="$tree" --disable-nls \
            CC=/usr/bin/clang \
            CFLAGS="-arch $carm -O2 -mmacosx-version-min=11.0 -isysroot $SDK" \
            LDFLAGS="-arch $carm -O2 -mmacosx-version-min=11.0 -isysroot $SDK -Wl,-headerpad_max_install_names"
        make -j"$(sysctl -n hw.ncpu)"
        make install
    )

    # 重定位必须在签名之前：install_name_tool 改写会作废已有签名。
    bash "$RELOCATE_SH" "$stage"
    codesign --force --sign - "$tree/bin/tar" >/dev/null 2>&1
    mkdir -p "$OUT"
    cp "$tree/bin/tar" "$OUT/tar-$carm"
}

build_one arm64 arm64
build_one amd64 x86_64

say ""
say "${GREEN}🌊 Artifacts in ${OUT}${RESET}"
for arch in arm64 x86_64; do
    file="$OUT/tar-$arch"
    printf '  %-28s %10s B  %s\n' "$(basename "$file")" "$(stat -f%z "$file")" \
        "$(shasum -a 256 "$file" | cut -d' ' -f1)"
done
say ""
say "下一步：bash scripts/selfbuilt_check.sh out/tar-arm64 --arch arm64"
