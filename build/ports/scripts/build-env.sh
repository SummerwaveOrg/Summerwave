#!/bin/bash

# build-env.sh —— 所有 build.sh 的公共构建环境。**source 它，不要自己写 -arch /
# -mmacosx-version-min / -isysroot 那一串。**
#
# 为什么要有这个文件：`-mmacosx-version-min` 决定产物里的 `LC_BUILD_VERSION minos`，
# 也就是「用户最低要哪个系统」。忘了写，minos 就等于构建机的系统版本 ——
# aria2c@1.37.0 就是这么变成「声明支持 12、实际要求 15」的。这类偏差在构建机上
# 完全看不出来，只有拿到旧系统上才会炸。所以这里把它固化成函数，别靠人记得。
#
# 地板按架构分，不是全库一个值：
#
#   arm64  = 15.0（Sequoia）。任何 Apple Silicon Mac 都跑得动 15，所以这个地板
#            只排除「能升但不升」的用户，不排除任何硬件。
#   x86_64 = 12.0（Monterey）。由 Intel 构建机的 SDK 决定，本来就是这个值；
#            它让老 Intel Mac 也能装上 —— 那批机器的系统更新早就停了。
#
# 用法（典型 build.sh）：
#
#     source "$(dirname "${BASH_SOURCE[0]}")/../scripts/build-env.sh"
#     mw_build_env arm64                     # 导出 CC/CXX/CFLAGS/LDFLAGS/...
#     "$SRC/configure" --prefix="$(mw_prefix jq 1.8.2)" "${COMMON[@]}"
#     make -j"$(sysctl -n hw.ncpu)"
#     mw_sign_and_check_stage "$STAGE"
#
# 换一套地板（例如实验性构建）：
#     MW_DEPLOYMENT_TARGET_ARM64=14.0 bash build.sh arm64
#     MW_DEPLOYMENT_TARGET_X86_64=13.0 bash build.sh x86_64

set -u

# -------------------- 可调项 --------------------

MW_DEPLOYMENT_TARGET_ARM64="${MW_DEPLOYMENT_TARGET_ARM64:-15.0}"
MW_DEPLOYMENT_TARGET_X86_64="${MW_DEPLOYMENT_TARGET_X86_64:-12.0}"

# 装完之后的绝对路径根。0.1.0 起安装位置写死（macOS 是 /opt/macwave），
# 所以构建时就能给出最终前缀 —— `.pc`、wrapper、configure 的 --prefix 都按它写。
MW_PREFIX_ROOT="${MW_PREFIX_ROOT:-/opt/macwave}"

MW_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MW_CHECK="$MW_SCRIPTS_DIR/selfbuilt_check.sh"

# 客户端仓库的位置：relocate_rpath.py 与平台标签词表都只有一份，都在那边。
# 0.1.0 起代码仓库叫 SummerwaveOrg/Summerwave；4.x 时代是 MacWaveOrg/MacWave。
# 用 MACWAVE_CLIENT_REPO 覆盖（例如 CI 里 checkout 到别处）。
MW_CLIENT_REPO="${MACWAVE_CLIENT_REPO:-}"
if [[ -z "$MW_CLIENT_REPO" ]]; then
    # scripts/ → Ports/ → MacWaveOrg/ → Projects/，所以是三级
    for candidate in "$MW_SCRIPTS_DIR/../../../SummerwaveOrg/Summerwave" \
                     "$MW_SCRIPTS_DIR/../../../MacWaveOrg/MacWave" \
                     "$HOME/Projects/SummerwaveOrg/Summerwave"; do
        if [[ -f "$candidate/scripts/relocate_rpath.py" ]]; then
            MW_CLIENT_REPO="$(cd "$candidate" && pwd)"
            break
        fi
    done
fi
MW_RELOCATE="${MW_CLIENT_REPO:-/nonexistent}/scripts/relocate_rpath.py"

# -------------------- 输出 --------------------

if [[ -t 1 ]]; then
    MW_RED='\033[1;31m'; MW_GREEN='\033[32m'; MW_YELLOW='\033[33m'; MW_RESET='\033[0m'
else
    MW_RED=''; MW_GREEN=''; MW_YELLOW=''; MW_RESET=''
fi
mw_die() { printf '%b\n' "${MW_RED}🌊 Error: $*${MW_RESET}" >&2; exit 1; }
mw_say() { printf '%b\n' "$*"; }
mw_note() { printf '%b\n' "${MW_YELLOW}🌊 $*${MW_RESET}"; }

# -------------------- 地板 --------------------

mw_deployment_target() {
    case "$1" in
        arm64|aarch64) echo "$MW_DEPLOYMENT_TARGET_ARM64" ;;
        x86_64|amd64)  echo "$MW_DEPLOYMENT_TARGET_X86_64" ;;
        *) return 1 ;;
    esac
}

mw_clang_arch() {
    # clang 认的 -arch 名字
    case "$1" in
        arm64|aarch64) echo arm64 ;;
        x86_64|amd64)  echo x86_64 ;;
        *) return 1 ;;
    esac
}

mw_host_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo arm64 ;;
        x86_64)        echo x86_64 ;;
        *) uname -m ;;
    esac
}

# -------------------- 环境导出 --------------------

mw_build_env() {
    local arch target clang_arch sdk
    arch="${1:-$(mw_host_arch)}"
    target="$(mw_deployment_target "$arch")" || mw_die "unknown arch: $arch (use arm64 or x86_64)"
    clang_arch="$(mw_clang_arch "$arch")"

    command -v xcrun >/dev/null 2>&1 || mw_die "xcrun not found (install the Xcode command line tools)"
    sdk="$(xcrun --sdk macosx --show-sdk-path)" || mw_die "cannot locate the macOS SDK"
    [[ -d "$sdk" ]] || mw_die "macOS SDK not found: $sdk"

    # 构建机的系统不能比目标地板还老（老 SDK 编不出新系统的产物）
    local host_version
    host_version="$(sw_vers -productVersion)"
    if [[ "$(printf '%s\n%s\n' "$target" "$host_version" | sort -V | tail -1)" == "$target" \
          && "$target" != "$host_version" ]]; then
        mw_die "this machine runs macOS $host_version, which is older than the target $target for $arch"
    fi

    export MACOSX_DEPLOYMENT_TARGET="$target"
    export SDKROOT="$sdk"
    export CC="${CC:-clang}"
    export CXX="${CXX:-clang++}"

    local common="-arch $clang_arch -mmacosx-version-min=$target -isysroot $sdk"
    export CFLAGS="${CFLAGS:-} $common"
    export CXXFLAGS="${CXXFLAGS:-} $common"
    export CPPFLAGS="${CPPFLAGS:-} -isysroot $sdk"
    # -headerpad_max_install_names 给 install_name_tool 留出改写空间。源码编理想情况下
    # 一次都不用改，但依赖闭包里只要有一个上游产物需要重定位，没有它就报
    # "larger updated load commands do not fit"。
    export LDFLAGS="${LDFLAGS:-} $common -Wl,-headerpad_max_install_names"

    # 归一化多余空格，避免 configure 里出现空的 -D 之类
    CFLAGS="$(echo "$CFLAGS" | tr -s ' ')"; export CFLAGS
    CXXFLAGS="$(echo "$CXXFLAGS" | tr -s ' ')"; export CXXFLAGS
    LDFLAGS="$(echo "$LDFLAGS" | tr -s ' ')"; export LDFLAGS

    mw_say "🌊 build env: ${MW_GREEN}$arch${MW_RESET} target ${MW_GREEN}$target${MW_RESET} sdk $sdk"
}

# -------------------- 路径 --------------------

mw_prefix() {
    # 装完之后的绝对前缀：<根>/Shore/<名>/<版本>。包与依赖同构，见 config/configpaths.py。
    local name="${1:-}" version="${2:-}"
    [[ -n "$name" && -n "$version" ]] || mw_die "usage: mw_prefix <name> <version>"
    echo "${MW_PREFIX_ROOT%/}/Shore/$name/$version"
}

mw_bottle_tag() {
    # <os>-<arch>，例如 macos-arm64。词表只有一份，在客户端的 config/platforminfo.py；
    # 这里调它，不自己拼 —— 两边漂了的话，产物名与索引记录名会对不上。
    local arch="${1:-$(mw_host_arch)}"
    [[ -n "$MW_CLIENT_REPO" ]] || mw_die "client repo not found; set MACWAVE_CLIENT_REPO"
    python3 - "$MW_CLIENT_REPO" "$arch" <<'PY'
import sys, pathlib
repo, arch = pathlib.Path(sys.argv[1]), sys.argv[2]
sys.path.insert(0, str(repo / "config"))
import platforminfo
print(platforminfo.bottle_tag(arch, os_name="macos"))
PY
}

# -------------------- 收尾 --------------------

mw_relocate_stage() {
    # 整棵 stage 重定位。源码编正常这里应当「零改动」——
    # 有改动说明链接参数没写对（缺 -install_name / -rpath），不是失败但值得看一眼。
    local stage="${1:-}"
    [[ -d "$stage" ]] || mw_die "stage directory not found: $stage"
    [[ -f "$MW_RELOCATE" ]] || mw_die "relocate_rpath.py not found: $MW_RELOCATE"
    python3 "$MW_RELOCATE" "$stage"
    python3 "$MW_RELOCATE" "$stage" --check || mw_die "stage is still not position-independent: $stage"
}

mw_verify_artifact() {
    # 上传前的闸门：架构、签名、绝对引用、文本里的构建路径、minos 地板。
    local artifact="${1:-}" arch="${2:-}"
    [[ -n "$artifact" && -n "$arch" ]] || mw_die "usage: mw_verify_artifact <file> <arm64|x86_64>"
    [[ -f "$MW_CHECK" ]] || mw_die "selfbuilt_check.sh not found: $MW_CHECK"
    bash "$MW_CHECK" "$artifact" --arch "$arch" --max-minos "$(mw_deployment_target "$arch")"
}

# -------------------- 自检（直接执行时） --------------------

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "arm64  target: $(mw_deployment_target arm64)   clang -arch: $(mw_clang_arch arm64)"
    echo "x86_64 target: $(mw_deployment_target x86_64)  clang -arch: $(mw_clang_arch x86_64)"
    echo "host arch:     $(mw_host_arch)"
    echo "prefix:        $(mw_prefix jq 1.8.2)"
    echo "bottle tag:    $(mw_bottle_tag arm64) / $(mw_bottle_tag x86_64)"
    echo "client repo:   ${MW_CLIENT_REPO:-（没找到，设 MACWAVE_CLIENT_REPO）}"
    echo "relocate:      $MW_RELOCATE"
    echo "check:         $MW_CHECK"
fi
