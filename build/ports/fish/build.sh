#!/bin/bash

# fish/build.sh —— 从上游 macOS .app 里取出 fish 并重打包成整树（**不重新编译**）
#
# 上游：https://github.com/fish-shell/fish-shell
# 上游产物：fish-4.9.3.app.zip（sha256 3619fa92…）。上游不发「裸二进制」：
#   release 里只有 .pkg（安装器）和 .app（一个 119 KB 的启动器 + base/ 下的真身）。
#   .app/Contents/Resources/base/usr/local 才是真正的 prefix 树：bin/fish 等 + share/fish。
# 输出：fish-4.9.3-<架构>.tar.xz，布局 bin/ + share/ + etc/
#
# 为什么能重打包：fish 4 按**可执行文件自身位置**解析数据目录（实测把整棵树挪到
# 任意路径、再经软链启动，`$__fish_data_dir` 仍指向树内的 share/fish，函数与补全
# 都正常）。所以 prefix 不需要在编译期对齐 MacWave 的安装路径。
#
# 上游那份是 universal；索引按「每架构一份」组织，这里用 lipo -thin 拆开再各自
# ad-hoc 签名。

set -eE
set -u
set -o pipefail

VERSION="4.9.3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SHA256="3619fa92d540ed0dff4816594429290550d21b92226e0523457e5f0242c5e9a8"
SRC_URL="https://github.com/fish-shell/fish-shell/releases/download/${VERSION}/fish-${VERSION}.app.zip"

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

for tool in curl unzip lipo codesign tar shasum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fish-repack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT


say "${GREEN}🌊 Downloading fish ${VERSION}${RESET}"
bash "$FETCH" "$SRC_URL" "$WORK/fish.app.zip"
echo "$SRC_SHA256  $WORK/fish.app.zip" | shasum -a 256 -c - >/dev/null \
    || die "upstream app bundle does not match the pinned sha256"
unzip -qo "$WORK/fish.app.zip" -d "$WORK/app"
PREFIX="$WORK/app/fish-${VERSION}.app/Contents/Resources/base/usr/local"
[[ -x "$PREFIX/bin/fish" ]] || die "unexpected app bundle layout: no bin/fish"

build_one() {
    local arch="$1" carm="$2"
    # stage 必须是运行时布局：客户端把整树落到 bin/<名称>@<版本>/，所以这里就摆成
    # <stage>/bin/fish@<版本>/，relocate 才能按最终位置算出正确的相对路径。
    local stage="$WORK/stage-$arch"
    local tree="$stage/bin/fish@${VERSION}"
    mkdir -p "$tree/bin"

    say "${GREEN}🌊 Repacking ${arch}${RESET}"
    # 上游 .app 里只有 fish 本体是 universal；fish_indent / fish_key_reader 只编了
    # arm64。所以不能无脑拷：amd64 包里塞一个 arm64 二进制，Intel 机器上一调就是
    # "Bad CPU type"。没有目标架构的直接跳过，并把它说出来。
    local name archs
    for name in fish fish_indent fish_key_reader; do
        archs="$(lipo -archs "$PREFIX/bin/$name")"
        if ! printf '%s\n' "$archs" | tr ' ' '\n' | grep -qx "$carm"; then
            say "🌊   skipping bin/$name: upstream ships it ${archs}-only"
            continue
        fi
        case "$archs" in
            *" "*) lipo -thin "$carm" "$PREFIX/bin/$name" -output "$tree/bin/$name" ;;
            *)     cp "$PREFIX/bin/$name" "$tree/bin/$name" ;;
        esac
    done
    cp -R "$PREFIX/share" "$tree/"
    cp -R "$PREFIX/etc" "$tree/"

    # 重定位必须在签名之前：install_name_tool 改写会作废已有签名。
    bash "$RELOCATE_SH" "$stage"

    while IFS= read -r file; do
        file "$file" | grep -q Mach-O && codesign --force --sign - "$file" >/dev/null 2>&1
    done < <(find "$tree" -type f)

    mkdir -p "$OUT"
    tar -cJf "$OUT/fish-${VERSION}-${arch}.tar.xz" -C "$tree" .
}

build_one arm64 arm64
build_one amd64 x86_64

say ""
say "${GREEN}🌊 Artifacts in ${OUT}${RESET}"
for arch in arm64 amd64; do
    f="$OUT/fish-${VERSION}-${arch}.tar.xz"
    printf '  %-30s %10s B  %s\n' "$(basename "$f")" "$(stat -f%z "$f")" \
        "$(shasum -a 256 "$f" | cut -d' ' -f1)"
done
say ""
say "下一步：bash scripts/selfbuilt_check.sh <归档> --arch arm64 --tree --main bin/fish"
say "        索引记录写 install: \"tree\" 与 min_client_version: \"4.5.0\"（fish 依赖树内 share/fish）。"
