#!/bin/bash

# testdisk/build.sh —— 可复现地编出 TestDisk / PhotoRec（整树产物，两个架构分别编）
#
# 上游：https://www.cgsecurity.org/wiki/TestDisk
# 源码：https://www.cgsecurity.org/testdisk-7.2.tar.bz2
# 产物：testdisk-7.2-<架构>.tar.xz（整树：bin/ + share/）
#
# 上游的 macOS「二进制」只有 intel 与 ppc，arm64 必须自己编 —— 所以这是自建包，
# 不是「有上游产物可收」的那一类。
#
# 关掉三个可选依赖：libewf（读取 EWF 镜像，体积大且要额外库）、
# ntfs3g/ntfs（挂载 NTFS，Mac 上没意义）。剩下的依赖面只有系统库：
# libncurses / libz / libiconv / libSystem。
#
# 整树包：bin/ 下 testdisk、photorec、fidentify 安装时各链一条 links/<命令名>，
# 只链 testdisk 等于把 photorec 藏起来 —— 数据恢复恰恰最常用 photorec。

set -eE
set -u
set -o pipefail

VERSION="7.2"
SRC_SHA256="f8343be20cb4001c5d91a2e3bcd918398f00ae6d8310894a5a9f2feb813c283f"
SRC_URL="https://www.cgsecurity.org/testdisk-${VERSION}.tar.bz2"

OUT="${1:-$PWD/out}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[32m'
RED_BOLD='\033[1;31m'
RESET='\033[0m'

say() { printf '%b\n' "$*"; }
die() { printf '%b\n' "${RED_BOLD}🌊 Error: $*${RESET}" >&2; exit 1; }
FETCH="$HERE/../scripts/fetch.sh"
[ -f "$FETCH" ] || die "fetch.sh not found: $FETCH"
RELOCATE_SH="$HERE/../scripts/relocate_stage.sh"
[ -f "$RELOCATE_SH" ] || die "relocate_stage.sh not found: $RELOCATE_SH"

for tool in curl clang codesign make; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found (install the Xcode command line tools)"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/testdisk-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "${GREEN}🌊 Downloading testdisk ${VERSION}${RESET}"
bash "$FETCH" "$SRC_URL" "$WORK/src.tar"
echo "${SRC_SHA256}  $WORK/src.tar" | shasum -a 256 -c - >/dev/null \
    || die "source tarball does not match the published sha256"
tar -xf "$WORK/src.tar" -C "$WORK"

SDK="$(xcrun --show-sdk-path)"

build_one() {
    local arch="$1" carm="$2"
    # stage 必须是运行时布局：客户端把整树落到 bin/<名称>@<版本>/，
    local tree="$WORK/tree-$arch"
    local stage="$tree/stage"
    local pkg="$stage/bin/testdisk@${VERSION}"

    say "${GREEN}🌊 Building ${arch}${RESET}"
    cp -R "$WORK/testdisk-$VERSION" "$tree"
    (
        cd "$tree"
        ./configure --prefix="$pkg" \
            --without-ewf --without-ntfs3g --without-ntfs \
            CC=/usr/bin/clang \
            CFLAGS="-arch $carm -O2 -mmacosx-version-min=11.0 -isysroot $SDK" \
            LDFLAGS="-arch $carm -O2 -mmacosx-version-min=11.0 -isysroot $SDK -Wl,-headerpad_max_install_names"
        make -j"$(sysctl -n hw.ncpu)"
        make install
    )

    # 重定位必须在签名之前：install_name_tool 改写会作废已有签名。
    bash "$RELOCATE_SH" "$stage"

    while IFS= read -r file; do
        file "$file" | grep -q Mach-O && codesign --force --sign - "$file" >/dev/null 2>&1
    done < <(find "$pkg" -type f)

    mkdir -p "$OUT"
    tar -cJf "$OUT/testdisk-${VERSION}-${carm}.tar.xz" -C "$pkg" .
}

build_one arm64 arm64
build_one amd64 x86_64

say ""
say "${GREEN}🌊 Artifacts in ${OUT}${RESET}"
for arch in arm64 x86_64; do
    file="$OUT/testdisk-${VERSION}-${arch}.tar.xz"
    printf '  %-32s %10s B  %s\n' "$(basename "$file")" "$(stat -f%z "$file")" \
        "$(shasum -a 256 "$file" | cut -d' ' -f1)"
done
say ""
say "下一步：bash scripts/selfbuilt_check.sh <归档> --arch arm64 --tree --main bin/testdisk"
say "        索引记录写 install: \"tree\" 与 min_client_version: \"4.5.0\"。"
