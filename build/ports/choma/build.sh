#!/bin/bash

# choma/build.sh —— 可复现地编出 choma 的两个架构
#
# 上游：https://github.com/opa334/ChOma
# 产物：裸可执行文件（不带扩展名），文件名 ChOma_<架构>
#
# 三条约束，别改：
#   1. 固定上游 tag，不要跟 main —— 索引里的 sha256 对应的是某一次具体构建；
#   2. 两个架构分别编，不要出 universal：MacWave 的索引是「每架构一个产物」；
#   3. 编完 ad-hoc 签名（Apple 芯片对未签名的 arm64 直接拒绝执行）。
#
# 用法：bash choma/build.sh <上游 tag> [输出目录]
# 依赖：Xcode 命令行工具、openssl（pkg-config libcrypto）、make

set -eE
set -u
set -o pipefail

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

# 上游没有 tag（`gh api repos/opa334/ChOma/tags` 是空的），所以钉 commit SHA。
# 版本名沿用索引里的 1.0-macwaveteam2，但**源头不是同名 tag** —— 索引哈希跟着这次
# 重编一起更新，provenance 看这一行和 notes.md。
TAG="${1:-7dccded6bc17081c08f5f5cdbd7a4b051543a825}"
VERSION="${CHOMA_VERSION:-1.0-macwaveteam2}"
OUT="${2:-$PWD/out}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '%b\n' "$*"; }
die() { printf '%b\n' "${RED_BOLD}🌊 $*${RESET}" >&2; exit 1; }
FETCH="$HERE/../scripts/fetch.sh"
[ -f "$FETCH" ] || die "fetch.sh not found: $FETCH"
RELOCATE_SH="$HERE/../scripts/relocate_stage.sh"
[ -f "$RELOCATE_SH" ] || die "relocate_stage.sh not found: $RELOCATE_SH"

for tool in make clang lipo codesign vtool; do
    command -v "$tool" >/dev/null || die "缺少 $tool（Xcode 命令行工具：xcode-select --install）"
done
command -v pkg-config >/dev/null || die "缺少 pkg-config（brew install pkg-config）"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say "🌊 取上游 $TAG"
# 走 codeload 而不是 git clone：github.com 在国内常年连不上，codeload 通。
bash "$FETCH" "https://codeload.github.com/opa334/ChOma/tar.gz/$TAG" "$WORK/src.tar.gz"
mkdir -p "$WORK/ChOma"
tar xzf "$WORK/src.tar.gz" -C "$WORK/ChOma" --strip-components=1

mkdir -p "$OUT"

for arch in arm64 amd64; do
    triplet=$([[ "$arch" == arm64 ]] && echo arm64 || echo x86_64)
    say "🌊 编译 $arch（clang -arch $triplet）"
    make -C "$WORK/ChOma" clean >/dev/null 2>&1 || true

    # CLI 在 output/tests/choma_cli。DISABLE_TESTS=1 只编库，`find -perm -111` 能抓到
    # 的就只剩 dylib —— 之前发出去的包里根本没有 choma 这个命令。但也不能整体开测试：
    # tests/choma_sign 用的是旧 API，编不过。所以分两步，第二步只点那一个目标。
    CF=(-arch "$triplet" -Wall $(pkg-config --cflags libcrypto) -fPIC
        -Wno-pointer-to-int-cast -Wno-unused-command-line-argument
        -Wno-deprecated-declarations -framework CoreFoundation
        -mmacosx-version-min=10.13)
    LD=(-arch "$triplet")

    make -C "$WORK/ChOma" CFLAGS="${CF[*]}" LDFLAGS="${LD[*]}" \
        DISABLE_SIGNING=0 DISABLE_TESTS=1 >/dev/null
    make -C "$WORK/ChOma" CFLAGS="${CF[*]}" LDFLAGS="${LD[*]}" \
        DISABLE_SIGNING=0 DISABLE_TESTS=0 output/tests/choma_cli >/dev/null

    built="$WORK/ChOma/output/tests/choma_cli"
    [[ -f "$built" ]] || die "$arch 编完没找到 output/tests/choma_cli"
    file -b "$built" | grep -q 'executable' \
        || die "$arch 的 $built 不是可执行文件（$(file -b "$built")）"

    # 单文件产物：客户端落到 bin/choma@<版本>/，stage 也摆成这样。
    stage="$WORK/stage-$arch"
    pkg="$stage/bin/choma@${VERSION}"
    mkdir -p "$pkg"
    cp "$built" "$pkg/ChOma_$arch"

    # ChOma 动态链着构建机的 libcrypto。重定位要按「客户端装好依赖后的位置」算相对
    # 路径，所以先把那份 dylib 在 deps 树里摆一份骨架（只用来算路径，不进产物）。
    libcrypto=""
    abs_ref=""
    abs_ref="$(otool -L "$pkg/ChOma_$arch" | awk '/libcrypto/ {print $1; exit}')"
    if [[ "$abs_ref" == /* ]]; then
        libcrypto="$stage/deps/openssl/openssl@3.0.15/lib/$(basename "$abs_ref")"
        mkdir -p "$(dirname "$libcrypto")"
        cp "$abs_ref" "$libcrypto"
        say "🌊 staged dep skeleton: ${libcrypto#"$stage"/}"
    fi

    # 重定位必须在签名之前：install_name_tool 改写会作废已有签名。
    bash "$RELOCATE_SH" "$stage"

    cp "$pkg/ChOma_$arch" "$OUT/ChOma_$arch"
    chmod +x "$OUT/ChOma_$arch"
    codesign --force --sign - "$OUT/ChOma_$arch" 2>/dev/null \
        || die "$arch ad-hoc 签名失败"
done

say ""
for arch in arm64 amd64; do
    f="$OUT/ChOma_$arch"
    say "  $(lipo -archs "$f")  $(basename "$f")  $(wc -c < "$f" | tr -d ' ') B"
    say "    min_os $(vtool -show-build "$f" 2>/dev/null | awk '/minos/{print $2; exit}')"
    say "    sha256 $(shasum -a 256 "$f" | awk '{print $1}')"
done
say ""
say "${GREEN}🌊 产物在 $OUT —— 先跑 scripts/selfbuilt_check.sh 再上传${RESET}"
