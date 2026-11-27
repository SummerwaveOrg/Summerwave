#!/bin/bash

# build-source.sh —— 从上游源码包编出一个整树产物（通用构建器）
#
# 用法：bash scripts/build-source.sh <名字> <版本> <源码地址> [构建系统]
#
# 为什么要它：绝大多数包**不编** —— 上游 release 已经给了 macOS 二进制，用
# scripts/prepare_bottle.py 重打就行。只有下面两种情况才走这里：
#   1. 上游只发源码，不发 macOS 二进制；
#   2. 上游产物带着别人家前缀（conda-forge 的 `_h_env_placehold_…`），改不干净。
# 这两种情况不可能每个手写一个 build.sh —— 绝大多数只是「取源码 → 一条构建命令 →
# 把产物摆进 bin/」。所以这里按**构建系统**分派，各家的特殊之处再单独加端口。
#
# 判定（scripts/source_census.py 已经算好，写在 census.tsv 的 build 列）：
#   go / cargo / cmake / meson / autotools / make
#
# 三条铁律（与手写端口一致）：
#   1. 两个架构分别编，不 universal；
#   2. 顺序只能是「编 → 重定位 → 签名 → 打包」；
#   3. 产物名 `<名>@<版本>.macos-<arch>.tar.bz2`，归档根是版本目录的内容。
#
# 产物形状统一成 `bin/<名>`：0.1.0 的树模式只从 `<版本>/bin/` 取命令，
# 「可执行文件躺在版本目录根上」等于装完一条链接都不建（147 个上游产物踩过）。

set -eE
set -u
set -o pipefail

NAME="${1:-}"; VERSION="${2:-}"; SRC_URL="${3:-}"; SYSTEM="${4:-auto}"
[ -n "$NAME" ] && [ -n "$VERSION" ] && [ -n "$SRC_URL" ] || {
    echo "usage: build-source.sh <name> <version> <source-url> [build-system]" >&2; exit 2; }

ARCH="${ARCH:-arm64}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$HERE/../out}"
# shellcheck source=./build-env.sh
source "$HERE/build-env.sh"

say() { printf '%b\n' "$*"; }
die() { printf '%b\n' "🌊 Error [$NAME@$VERSION]: $*" >&2; exit 1; }

mw_build_env "$ARCH"
PREFIX="$(mw_prefix "$NAME" "$VERSION")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/src-$NAME-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "🌊 $NAME@$VERSION ← $(basename "$SRC_URL")"
# 走 fetch.sh：github.com 直连常年被掐（`curl: (52) Empty reply from server`），
# 它会换用 api.github.com 的 tarball 端点。所有 build.sh 共用这一个取件口。
bash "$HERE/fetch.sh" "$SRC_URL" "$WORK/src.tar.gz" || die "cannot download the source tarball"
mkdir -p "$WORK/src"
tar -xzf "$WORK/src.tar.gz" -C "$WORK/src" --strip-components=1 2>/dev/null \
    || tar -xf "$WORK/src.tar.gz" -C "$WORK/src"   # 少数包没有单一顶层目录

# 构建系统自动判定（调用方没给时）
if [[ "$SYSTEM" == "auto" ]]; then
    if [[ -f "$WORK/src/go.mod" ]]; then SYSTEM=go
    elif [[ -f "$WORK/src/Cargo.toml" ]]; then SYSTEM=cargo
    elif [[ -f "$WORK/src/CMakeLists.txt" ]]; then SYSTEM=cmake
    elif [[ -f "$WORK/src/meson.build" ]]; then SYSTEM=meson
    elif [[ -x "$WORK/src/configure" ]]; then SYSTEM=autotools
    elif [[ -f "$WORK/src/Makefile" ]]; then SYSTEM=make
    else SYSTEM=unknown; fi
fi

STAGE="$WORK/root"
TREE="$STAGE$PREFIX"
mkdir -p "$TREE/bin"

BIN_DIR="$TREE/bin"

# -------------------- go --------------------
build_go() {
    command -v go >/dev/null || die "go not found"
    export GOFLAGS="${GOFLAGS:-} -trimpath"
    export GO111MODULE=on
    # cgo 产物要带地板，否则 minos 会等于构建机的系统版本
    export CGO_CFLAGS="$CFLAGS"
    export CGO_LDFLAGS="$LDFLAGS"
    local flags="-s -w"

    # 一个仓库常有多个 main 包（age 就有 age / age-keygen / age-inspect…），
    # 上游发布的压缩包里也是把它们一起给的。全编，各自进 bin/ —— 树模式靠 bin/ 列命令。
    local pkgs
    pkgs="$( cd "$WORK/src" && go list -f '{{if eq .Name "main"}}{{.ImportPath}}{{end}}' ./... 2>/dev/null \
             | grep -v '^$' || true )"
    [[ -n "$pkgs" ]] || die "no main package found"

    local built=0 pkg base
    while read -r pkg; do
        [[ -n "$pkg" ]] || continue
        base="$(basename "$pkg")"
        [[ "$base" == "." || "$base" == "..." ]] && base="$NAME"
        if ( cd "$WORK/src" && go build -ldflags "$flags" -o "$BIN_DIR/$base" "$pkg" ); then
            built=$((built + 1))
        fi
    done <<< "$pkgs"
    (( built > 0 )) || die "go build failed for every main package"

    # 主包的 ImportPath 末段常常不是包名（`./cmd/server`、模块带 `/v2`）。
    # 只产出一个可执行文件、又跟包名对不上时，直接按包名收进来。
    if [[ ! -x "$BIN_DIR/$NAME" ]]; then
        local produced
        produced="$(find "$BIN_DIR" -maxdepth 1 -type f -perm +111 | head -2)"
        if [[ -n "$produced" ]] && [[ "$(printf '%s\n' "$produced" | wc -l | tr -d ' ')" == "1" ]]; then
            mv "$produced" "$BIN_DIR/$NAME"
        fi
    fi
}

# -------------------- cargo --------------------
build_cargo() {
    command -v cargo >/dev/null || die "cargo not found"
    ( cd "$WORK/src" && cargo build --release --locked 2>/dev/null ) \
        || ( cd "$WORK/src" && cargo build --release )
    # 同样可能有多个 bin（`[[bin]]` 多段），把 release 目录里的可执行文件都收进来
    local produced count=0 f
    produced="$(find "$WORK/src/target/release" -maxdepth 1 -type f -perm +111 \
                -not -name "*.d" -not -name "*.rlib" -not -name "*.so" -not -name "*.dylib" | head -20)"
    [[ -n "$produced" ]] || die "cargo produced no executable"
    while read -r f; do
        [[ -n "$f" ]] || continue
        cp "$f" "$BIN_DIR/$(basename "$f")"
        count=$((count + 1))
    done <<< "$produced"
    (( count > 0 )) || die "cargo produced no executable"
}

# -------------------- cmake / meson / autotools / make --------------------
build_cmake() {
    cmake -S "$WORK/src" -B "$WORK/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES="$(mw_clang_arch "$ARCH")" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$(mw_deployment_target "$ARCH")" >/dev/null
    cmake --build "$WORK/build" --parallel "$(sysctl -n hw.ncpu)" >/dev/null
    DESTDIR="$STAGE" cmake --install "$WORK/build" >/dev/null
}

build_meson() {
    command -v meson >/dev/null || die "meson not found"
    meson setup "$WORK/build" "$WORK/src" --prefix="$PREFIX" --buildtype=release >/dev/null
    ninja -C "$WORK/build" >/dev/null
    DESTDIR="$STAGE" ninja -C "$WORK/build" install >/dev/null
}

build_autotools() {
    ( cd "$WORK/src"
      if [[ ! -x ./configure ]]; then
          # git archive 出来的源码没有 configure，要自己生成
          autoreconf -fi >/dev/null 2>&1 || die "autoreconf failed"
      fi
      ./configure --prefix="$PREFIX" --disable-static CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" >/dev/null
      make -j"$(sysctl -n hw.ncpu)" >/dev/null
      make install DESTDIR="$STAGE" >/dev/null )
}

build_make() {
    ( cd "$WORK/src"
      make -j"$(sysctl -n hw.ncpu)" PREFIX="$PREFIX" >/dev/null
      make install PREFIX="$PREFIX" DESTDIR="$STAGE" >/dev/null )
}

case "$SYSTEM" in
    go)         build_go ;;
    cargo)      build_cargo ;;
    cmake)      build_cmake ;;
    meson)      build_meson ;;
    autotools)  build_autotools ;;
    make)       build_make ;;
    *)          die "unknown build system" ;;
esac

# 统一形状：命令必须在 <版本>/bin/ 下。cmake/autotools/make 可能已经装好了 bin/。
if [[ ! -x "$BIN_DIR/$NAME" ]]; then
    # 找一个与包同名、或版本目录里唯一的可执行文件，摆进 bin/
    found="$(find "$TREE" -type f -perm +111 -not -path "*/bin/*" \
             -not -name "*.dylib" -not -name "*.so" -not -name "*.a" | head -5)"
    if [[ -n "$found" ]]; then
        first="$(printf '%s\n' "$found" | grep -E "/$NAME$" | head -1)"
        [[ -n "$first" ]] || first="$(printf '%s\n' "$found" | head -1)"
        cp "$first" "$BIN_DIR/$NAME"
    fi
fi
[[ -x "$BIN_DIR/$NAME" ]] || die "no executable named '$NAME' was produced"

say "🌊 relocating and signing"
mw_relocate_stage "$STAGE"

mkdir -p "$OUT"
TAG="$(mw_bottle_tag "$ARCH")"
ARCHIVE="$OUT/$NAME@$VERSION.$TAG.tar.bz2"
tar cjf "$ARCHIVE" -C "$TREE" . || die "cannot pack"

say "🌊 $(basename "$ARCHIVE")  sha256=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
mw_verify_artifact "$ARCHIVE" "$ARCH" || die "artifact failed the gates"
