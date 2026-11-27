#!/bin/bash

# dtc/build.sh —— 可复现地编出 device-tree-compiler（整树产物，两个架构分别编）
#
# 上游：https://git.kernel.org/pub/scm/utils/dtc/dtc.git
# 源码：https://www.kernel.org/pub/software/utils/dtc/dtc-1.7.2.tar.xz
# 产物：dtc-1.7.2-<架构>.tar.xz（整树：bin/ + include/ + lib/）
#
# 三个必须注意的地方：
#   1. 用 1.7.2 而不是 1.8.x：1.8 起 Makefile 只剩一句「请用 meson」的壳，构建
#      要额外装 meson/ninja；1.7.2 的 make 路径完整可用。
#   2. libyaml：Mac 上只要装了 Homebrew 的 libyaml，Makefile 的 pkg-config 探测就会
#      打开 yaml 支持，但那条路径**不会**把 yaml.o 链进来，于是 dtc 链接失败。
#      NO_YAML 是 Makefile 内部用 := 算的、命令行传不进去，所以直接
#      PKG_CONFIG=/usr/bin/false 让探测失败，再把 -DNO_YAML 显式写进 CFLAGS
#      （命令行赋值的 CFLAGS 会覆盖 Makefile 的 CFLAGS +=，所以必须自己带 -D）。
#   3. 每个架构一份干净的源码树：make 不清 .o，混着编会链进另一个架构的目标文件。
#
# 整树包：bin/ 下 dtc、fdtget、fdtput、fdtdump、fdtoverlay、convert-dtsv0、dtdiff
# 安装时各链一条 links/<命令名>。

set -eE
set -u
set -o pipefail

VERSION="1.7.2"
SRC_SHA256="92d8ca769805ae1f176204230438fe52808f4e1c7944053c9eec0e649b237539"
SRC_URL="https://www.kernel.org/pub/software/utils/dtc/dtc-${VERSION}.tar.xz"

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dtc-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "${GREEN}🌊 Downloading dtc ${VERSION}${RESET}"
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
    local pkg="$stage/bin/dtc@${VERSION}"

    say "${GREEN}🌊 Building ${arch}${RESET}"
    cp -R "$WORK/dtc-$VERSION" "$tree"
    (
        cd "$tree"
        make -j"$(sysctl -n hw.ncpu)" \
            NO_PYTHON=1 NO_VALGRIND=1 PKG_CONFIG=/usr/bin/false \
            CC=/usr/bin/clang \
            CFLAGS="-DNO_YAML -arch $carm -O2 -mmacosx-version-min=11.0 -isysroot $SDK" \
            LDFLAGS="-arch $carm -O2 -mmacosx-version-min=11.0 -isysroot $SDK -Wl,-headerpad_max_install_names" \
            PREFIX="$pkg" install
    )

    # dtc 的 libfdt 用的是裸 soname（`libfdt.dylib.1`），而它只是 lib/ 下的一个软链，
    # 真文件名是 `libfdt.dylib.1.7.2`。重定位按 basename 在树里找 Mach-O，软链不算
    # Mach-O，名字也对不上 —— 所以先把引用改成真文件的绝对路径，让它能被解析，
    # 随后 relocate 再统一改成 @loader_path 相对形式。
    local libfdt
    # 必须是真文件：lib/ 里 libfdt.dylib.1 是指向它的软链，名字排序还在前面。
    libfdt="$(find "$pkg/lib" -maxdepth 1 -type f -name 'libfdt.dylib.*' 2>/dev/null | head -1)"
    if [[ -n "$libfdt" ]]; then
        install_name_tool -id "$libfdt" "$libfdt" 2>/dev/null || true
        while IFS= read -r file; do
            otool -L "$file" 2>/dev/null | grep -qF 'libfdt.dylib.1 ' || continue
            install_name_tool -change libfdt.dylib.1 "$libfdt" "$file"
        done < <(find "$pkg/bin" -type f)
    fi

    # 重定位必须在签名之前：install_name_tool 改写会作废已有签名。
    bash "$RELOCATE_SH" "$stage"

    while IFS= read -r file; do
        file "$file" | grep -q Mach-O && codesign --force --sign - "$file" >/dev/null 2>&1
    done < <(find "$pkg" -type f)

    mkdir -p "$OUT"
    tar -cJf "$OUT/dtc-${VERSION}-${carm}.tar.xz" -C "$pkg" .
}

build_one arm64 arm64
build_one amd64 x86_64

say ""
say "${GREEN}🌊 Artifacts in ${OUT}${RESET}"
for arch in arm64 x86_64; do
    file="$OUT/dtc-${VERSION}-${arch}.tar.xz"
    printf '  %-32s %10s B  %s\n' "$(basename "$file")" "$(stat -f%z "$file")" \
        "$(shasum -a 256 "$file" | cut -d' ' -f1)"
done
say ""
say "下一步：bash scripts/selfbuilt_check.sh <归档> --arch arm64 --tree --main bin/dtc"
say "        索引记录写 install: \"tree\" 与 min_client_version: \"4.5.0\"。"
