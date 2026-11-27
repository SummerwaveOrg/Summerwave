#!/bin/bash

# ast-grep/build.sh —— 把上游产物重新打包成 MacWave 的整树布局（**不重新编译**）
#
# 上游：https://github.com/ast-grep/ast-grep
# 上游产物：app-<arch>-apple-darwin.zip（sha256 见 notes.md）
# 输出：ast-grep-0.51.3-<架构>.tar.xz，布局 bin/ + （无，只有 bin/）
#
# 为什么要重打包：整树包（install: "tree"）的约定是「可执行文件在 bin/ 下」，
# 而 上游 zip 把 `ast-grep` 与 `sg` 两个可执行文件摊在根目录，没有 bin/。
# 二进制字节原样保留（只做移动 + ad-hoc 签名），所以行为与上游产物一致。

set -eE
set -u
set -o pipefail

VERSION="0.51.3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$PWD/out}"

GREEN='\033[32m'
RED_BOLD='\033[1;31m'
RESET='\033[0m'
say() { printf '%b\n' "$*"; }
die() { printf '%b\n' "${RED_BOLD}🌊 Error: $*${RESET}" >&2; exit 1; }
FETCH="$HERE/../scripts/fetch.sh"
[ -f "$FETCH" ] || die "fetch.sh not found: $FETCH"
RELOCATE_SH="$HERE/../scripts/relocate_stage.sh"
[ -f "$RELOCATE_SH" ] || die "relocate_stage.sh not found: $RELOCATE_SH"

for tool in curl clang codesign tar shasum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ast-grep-repack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT


build_one() {
    local arch="$1" url="$2" sha="$3"
    local dir="$WORK/tree-$arch"
    # stage 必须是运行时布局：客户端把整树落到 bin/<名称>@<版本>/，
    # 所以这里就摆成 <stage>/bin/ast-grep@<版本>/，relocate 才能算对相对路径。
    local stage="$dir/stage"
    local tree="$stage/bin/ast-grep@${VERSION}"

    say "${GREEN}🌊 Repacking ${arch}${RESET}"
    mkdir -p "$dir/extract" "$tree/bin"
    local archive="$WORK/$(basename "$url")"
    bash "$FETCH" "$url" "$archive"
    echo "$sha  $archive" | shasum -a 256 -c - >/dev/null \
        || die "upstream $arch artifact does not match the pinned sha256"
    case "$archive" in
        *.zip) unzip -qo "$archive" -d "$dir/extract" ;;
        *.tar.gz) tar -xzf "$archive" -C "$dir/extract" ;;
        *.tar.xz) tar -xJf "$archive" -C "$dir/extract" ;;
    esac

    local root="$dir/extract"
    local entries=("$root"/*)
    if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
        root="${entries[0]}"
    fi

    mv "$root/ast-grep" "$tree/bin/"
    mv "$root/sg" "$tree/bin/"
    if [[ -f "$root/LICENSE" ]]; then cp "$root/LICENSE" "$tree/"; fi


    bash "$RELOCATE_SH" "$stage"

    while IFS= read -r file; do
        file "$file" | grep -q Mach-O && codesign --force --sign - "$file" >/dev/null 2>&1
    done < <(find "$tree" -type f)

    mkdir -p "$OUT"
    tar -cJf "$OUT/ast-grep-${VERSION}-${arch}.tar.xz" -C "$tree" .
}

build_one arm64 "https://github.com/ast-grep/ast-grep/releases/download/0.51.3/app-aarch64-apple-darwin.zip" "7954eab1e2803d1485f263377be7f359db6d3915312b5d773cd575eb009330b1"
build_one amd64 "https://github.com/ast-grep/ast-grep/releases/download/0.51.3/app-x86_64-apple-darwin.zip" "af04ed50179e51316a0139b8bb39502a3841d6c8e9fd9a4bac40987a8c7c3acd"

say ""
say "${GREEN}🌊 Artifacts in ${OUT}${RESET}"
for arch in arm64 amd64; do
    f="$OUT/ast-grep-${VERSION}-${arch}.tar.xz"
    printf '  %-34s %10s B  %s\n' "$(basename "$f")" "$(stat -f%z "$f")" \
        "$(shasum -a 256 "$f" | cut -d' ' -f1)"
done
say ""
say "下一步：bash scripts/selfbuilt_check.sh <归档> --arch arm64 --tree --main bin/ast-grep"
say "        索引记录写 install: \"tree\" 与 min_client_version: \"4.5.0\"。"
