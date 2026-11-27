#!/bin/bash

# selfbuilt_check.sh —— 自建产物上传前的最后一道闸门。
#
# 每个 build.sh 的结尾都会说「先跑 scripts/selfbuilt_check.sh 再上传」。它检查的是
# 那些**装到用户机器上才会暴露**的问题：
#
#   1. 架构对不对（拿 arm64 的产物去发 amd64 的条目，用户那边直接 "Bad CPU type"）；
#   2. 签名还在不在（改过路径没重签，Apple Silicon 上根本不执行）；
#   3. 引用里有没有写死本机路径 —— 这是 4.6 起的硬规则：除了 /usr/lib、/System、
#      /Library/Apple，LC_LOAD_DYLIB / LC_ID_DYLIB 里不许出现绝对路径，只能是
#      @loader_path / @rpath / @executable_path。写死了就意味着产物只能活在构建机的
#      那个目录里，装到用户机器上换个 base_dir 就加载不到库；
#   4. 整树包里有没有把构建目录写进文本文件（例如编进去的 GIT_EXEC_PATH），
#      这类问题在 Mach-O 检查里看不见，但换台机器就指向不存在的目录；
#   5. minos（「用户最低要哪个 macOS」）有没有超过约定地板。忘了写
#      -mmacosx-version-min 时 minos 就等于构建机的系统版本 —— aria2c@1.37.0
#      就是这么变成「声明支持 12、实际要求 15」的，而构建机上完全看不出来。
#
# 用法：
#   bash scripts/selfbuilt_check.sh out/bash-arm64 --arch arm64
#   bash scripts/selfbuilt_check.sh out/git-2.56.1-arm64.tar.xz --arch arm64 \
#        --tree --main bin/git
#
# 退出码：0 = 可以上传；1 = 有问题（下面会逐条列出）。

set -u
set -o pipefail

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

die() { printf '%b\n' "${RED_BOLD}🌊 Error: $*${RESET}" >&2; exit 1; }
note() { printf '%b\n' "${YELLOW}🌊 $*${RESET}"; }
ok() { printf '%b\n' "${GREEN}🌊 $*${RESET}"; }

ARTIFACT=""
ARCH=""
TREE=0
MAIN=""
# 空 = 不检查 minos；build-env.sh 会按架构传 15.0（arm64）/ 12.0（x86_64）
MAX_MINOS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="${2:-}"; shift 2 ;;
        --tree) TREE=1; shift ;;
        --main) MAIN="${2:-}"; shift 2 ;;
        --max-minos) MAX_MINOS="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) ARTIFACT="$1"; shift ;;
    esac
done

[[ -n "$ARTIFACT" ]] || die "usage: selfbuilt_check.sh <artifact> [--arch arm64|amd64] [--tree] [--main bin/<name>] [--max-minos X.Y]"
[[ -e "$ARTIFACT" ]] || die "artifact not found: $ARTIFACT"

# 没给 --max-minos 时按架构取默认地板（与 scripts/build-env.sh 的
# MW_DEPLOYMENT_TARGET_* 是同一组值；改一处要改两处，所以这里只留一份表并打印出来）。
if [[ -z "$MAX_MINOS" ]]; then
    case "$ARCH" in
        arm64)        MAX_MINOS="${MW_DEPLOYMENT_TARGET_ARM64:-15.0}" ;;
        amd64|x86_64) MAX_MINOS="${MW_DEPLOYMENT_TARGET_X86_64:-12.0}" ;;
    esac
    [[ -n "$MAX_MINOS" ]] && note "minos floor for ${ARCH}: $MAX_MINOS"
fi

for tool in otool codesign lipo file; do
    command -v "$tool" > /dev/null 2>&1 || die "$tool not found (install the Xcode command line tools)"
done

PROBLEMS=0
problem() { printf '%b\n' "${RED_BOLD}🌊 ✗ $*${RESET}"; PROBLEMS=$((PROBLEMS + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/selfbuilt_check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 产物可以是：单文件 / 目录 / 压缩包
ROOT=""
SINGLE=""
case "$ARTIFACT" in
    *.tar.xz|*.txz)
        TREE=1
        tar -xJf "$ARTIFACT" -C "$WORK" || die "cannot extract $ARTIFACT"
        ROOT="$WORK" ;;
    *.tar.gz|*.tgz)
        TREE=1
        tar -xzf "$ARTIFACT" -C "$WORK" || die "cannot extract $ARTIFACT"
        ROOT="$WORK" ;;
    # 1.0 的重打产物统一是 bz2（prepare_bottle / 源码编都一样）。漏了这一支的话
    # 压缩包会被当成「单文件产物」，然后在架构与签名上一起报红。
    *.tar.bz2|*.tbz2)
        TREE=1
        tar -xjf "$ARTIFACT" -C "$WORK" || die "cannot extract $ARTIFACT"
        ROOT="$WORK" ;;
    *)
        if [[ -d "$ARTIFACT" ]]; then
            ROOT="$ARTIFACT"
            TREE=1
        else
            SINGLE="$ARTIFACT"
        fi ;;
esac

# 收集要检查的 Mach-O（静态库 !<arch> 不算，符号链接不重复检查）
MACHOS=()
if [[ -n "$SINGLE" ]]; then
    MACHOS=("$SINGLE")
else
    while IFS= read -r candidate; do
        file -b "$candidate" 2>/dev/null | grep -q "Mach-O" || continue
        MACHOS+=("$candidate")
    done < <(find "$ROOT" -type f ! -type l)
fi

[[ ${#MACHOS[@]} -gt 0 ]] || die "no Mach-O files found in $ARTIFACT"

echo "🌊 Checking ${#MACHOS[@]} Mach-O file(s) from $ARTIFACT"

SYSTEM_PREFIXES='^(/usr/lib/|/System/|/Library/Apple/)'
RELATIVE_PREFIXES='^(@loader_path/|@executable_path/|@rpath/)'

# 索引里叫 amd64，clang / lipo 报的是 x86_64 —— 同一个架构两种写法，先归一化，
# 否则 --arch amd64 对任何 x86_64 产物都会报 "architecture is 'x86_64'"。
EXPECT_ARCH="$ARCH"
EXPECT_NOTE=""
case "$ARCH" in
    amd64) EXPECT_ARCH=x86_64; EXPECT_NOTE=" (lipo calls it x86_64)" ;;
esac

for binary in "${MACHOS[@]}"; do
    rel="${binary#"$WORK"/}"

    # 1. 架构
    if [[ -n "$EXPECT_ARCH" ]]; then
        arches="$(lipo -archs "$binary" 2>/dev/null || true)"
        case " $arches " in
            *" $EXPECT_ARCH "*) ;;
            *) problem "$rel: architecture is '${arches:-unknown}', expected ${ARCH}${EXPECT_NOTE}" ;;
        esac
    fi

    # 1.5 minos：产物的最低系统要求不能超过地板
    if [[ -n "$MAX_MINOS" ]]; then
        minos="$(vtool -show-build "$binary" 2>/dev/null | awk '/minos/{print $2; exit}')"
        if [[ -n "$minos" ]]; then
            # 版本比较：15.0 > 14.5 > 12.0（不能用字符串比，10.15 vs 9.0）
            if [[ "$(printf '%s\n%s\n' "$minos" "$MAX_MINOS" | sort -V | tail -1)" == "$minos" \
                  && "$minos" != "$MAX_MINOS" ]]; then
                problem "$rel: minos $minos exceeds the ${ARCH:-arch} floor $MAX_MINOS" \
                        "(missing -mmacosx-version-min? use scripts/build-env.sh)"
            fi
        else
            note "$rel: no LC_BUILD_VERSION minos (very old toolchain?)"
        fi
    fi

    # 2. 单文件产物必须是可执行文件，不能是 dylib —— choma 就栽在这里：
    # build.sh 抓错产物，发出去的包里是个动态库，用户那边根本没有这个命令。
    if [[ -n "$SINGLE" ]]; then
        kind="$(file -b "$binary")"
        case "$kind" in
            *executable*) ;;
            *) problem "$rel: not an executable ($kind)" ;;
        esac
    fi

    # 3. 签名
    if ! codesign --verify --verbose=0 "$binary" > /dev/null 2>&1; then
        problem "$rel: signature does not verify (re-run codesign --force --sign -)"
    fi

    # 4. 引用里不许有绝对路径
    while IFS= read -r reference; do
        [[ -n "$reference" ]] || continue
        [[ "$reference" =~ $SYSTEM_PREFIXES ]] && continue
        [[ "$reference" =~ $RELATIVE_PREFIXES ]] && continue
        problem "$rel: names an absolute path outside the system: $reference"
    done < <(otool -L "$binary" 2>/dev/null | awk 'NR > 1 && /^[[:space:]]/ {print $1}')

    # dylib 自己的 install name 同理
    own_id="$(otool -D "$binary" 2>/dev/null | sed -n '2p')"
    if [[ -n "$own_id" && ! "$own_id" =~ $SYSTEM_PREFIXES && ! "$own_id" =~ $RELATIVE_PREFIXES ]]; then
        problem "$rel: install name is an absolute path: $own_id"
    fi
done

# 5. 整树包：文本文件里写死的构建目录
if [[ "$TREE" -eq 1 ]]; then
    # build.sh 的 stage 通常在 mktemp -d 的 $TMPDIR 下，macOS 上是
    # /var/folders/... —— 只搜 /Users 与 /opt/local 会漏掉这一类。
    while IFS= read -r hit; do
        note "text file references a build path: ${hit#"$WORK"/}"
        note "  compiled-in prefix; it will point at a directory that does not exist for the user"
    done < <(grep -rIl -e '/Users/' -e '/opt/local' -e '/var/folders/' \
        -e '/private/var/folders/' -e "$WORK" "$ROOT" 2>/dev/null | head -5)

    if [[ -n "$MAIN" ]]; then
        [[ -e "$ROOT/$MAIN" ]] || problem "main executable missing: $MAIN"
    fi
fi

echo
if [[ "$PROBLEMS" -gt 0 ]]; then
    printf '%b\n' "${RED_BOLD}🌊 $PROBLEMS problem(s): do not upload this artifact${RESET}"
    printf '%b\n' "${YELLOW}🌊 If a reference is absolute, relocate at build time:${RESET}"
    printf '%b\n' "${YELLOW}🌊   python3 <MacWave>/scripts/relocate_rpath.py <stage-dir>${RESET}"
    printf '%b\n' "${YELLOW}🌊 then re-sign before packing. See MacWave docs/RELOCATION.md.${RESET}"
    exit 1
fi

ok "all ${#MACHOS[@]} Mach-O file(s) passed"
if [[ -n "$SINGLE" ]]; then
    printf '  %-14s %s\n' "architecture" "$(lipo -archs "$SINGLE" 2>/dev/null || echo unknown)"
    printf '  %-14s %s\n' "min_os" "$(vtool -show-build "$SINGLE" 2>/dev/null | awk '/minos/{print $2; exit}')"
    printf '  %-14s %s\n' "sha256" "$(shasum -a 256 "$SINGLE" | awk '{print $1}')"
fi
