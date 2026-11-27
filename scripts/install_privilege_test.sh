#!/bin/bash

# install_privilege_test.sh
# `install.sh` 什么时候需要提权：按**写权限**判断，不按「是不是在家目录下」。
#
# 安装根写死成 /opt/macwave 之后，这条判断只剩一种形状：目标树写不了就提权。
# 用户级安装、自定义目录、SIP/SSV 这几套分支都已经删掉 —— 它们存在的理由是
# 「可能装到别处」，而现在没有别处。
#
# 全程 `--dry-run`：不下载、不提权、不建目录；版本数据指向一个必然失败的本地地址，
# 于是不必联网。

# 语言：install.sh 会按 locale / 系统首选语言自动切中文，断言因此会随开发者的
# 系统语言漂（中文 Mac 上所有英文断言一起红）。这里钉成英文 + 清掉外层的覆盖。
unset MACWAVE_LANG LC_ALL LC_MESSAGES
export LANG=en_US.UTF-8

# 这些用例用的是赝品镜像，里面没有 latest.toml.sig，而验签是强制的
# （不通过就不装）。真实验签由 signature_test.sh 单独覆盖，这里放开。
export MACWAVE_ALLOW_UNSIGNED=1

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="$REPO_DIR/lib/install.sh"

FAILED=0
PASSED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

if [[ ! -f "$INSTALL_SH" ]]; then
    echo -e "${RED_BOLD}🌊 Error: install.sh not found at $INSTALL_SH${RESET}"
    exit 1
fi

WORK=$(mktemp -d)
RO_DIRS=()
cleanup() {
    local dir
    for dir in ${RO_DIRS[@]+"${RO_DIRS[@]}"}; do
        [[ -d "$dir" ]] && chmod 755 "$dir" 2>/dev/null
    done
    [[ -d "$WORK" ]] && chmod -R u+rwX "$WORK" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# 每个用例一个独立的测试根：它们对目录权限的摆弄互不影响。
new_root() {
    local root="$WORK/$1"
    mkdir -p "$root"
    echo "$root"
}

# 干跑一次，返回它的输出。版本数据指向 127.0.0.1:1 —— 立刻失败并回落到占位版本号，
# 于是这条测试不碰网络，也不会因为线上换版本而变红。
dry_run() {
    local root="$1"; shift
    MACWAVE_TEST="$root" \
        SUMMERWAVE_SELFUPDATE_DOMAIN="http://127.0.0.1:1" \
        /bin/bash "$INSTALL_SH" --dry-run "$@" 2>&1
}

needs_admin() {
    case "$1" in
        *"needs administrator access"*) return 0 ;;
        *) return 1 ;;
    esac
}

# -------------------- 1. 目标可写：不提权 --------------------

ROOT=$(new_root writable)
out=$(dry_run "$ROOT" --ci)
if needs_admin "$out"; then
    fail "可写的目标树不该要求提权"
else
    pass "可写的目标树不提权"
fi
if [[ "$out" == *"$ROOT/opt/macwave"* ]]; then
    pass "安装根是写死的 /opt/macwave（测试根映射后）"
else
    fail "安装根不是 /opt/macwave：$out"
fi

# -------------------- 2. 目标写不了：要提权 --------------------

ROOT=$(new_root unwritable)
# 只把目标所在的那一层设成只读：测试根本身必须可写，否则 install.sh 连
# 「把 HOME 搬进测试根」都做不到（那是 MACWAVE_TEST 的准备工作，与提权无关）。
mkdir -p "$ROOT/opt"
RO_DIRS+=("$ROOT/opt")
chmod 555 "$ROOT/opt"
out=$(dry_run "$ROOT")
if needs_admin "$out"; then
    pass "只读的目标树要求提权"
else
    fail "只读的目标树没有被判定为需要提权：$out"
fi
chmod 755 "$ROOT/opt"

# -------------------- 3. 写探针本身 --------------------
#
# 上面的用例全走 --dry-run（承诺不写文件，因此只用 test -w）。
# 这一节把 mw_can_write 抠出来单独跑：真的建一个空文件再删掉，并确认没留下东西。

echo
echo "========== 写探针 =========="

probe_run() {
    # probe_run <目录> → 打印 "rc=<0|1|2> leftovers=<n>"
    /bin/bash -c '
mw_dry_run() { return 1; }
eval "$(sed -n "/^mw_mktemp()/,/^}/p" "$1")"
eval "$(sed -n "/^mw_can_write()/,/^}/p" "$1")"
dir="$2"
rc=0
mw_can_write "$dir" || rc=$?
leftovers=$(find "$dir" -maxdepth 1 -name ".macwave-write-probe.*" 2>/dev/null | wc -l | tr -d " ")
echo "rc=$rc leftovers=$leftovers"
' _ "$INSTALL_SH" "$1"
}

PROBE_ROOT=$(new_root probe)
mkdir -p "$PROBE_ROOT/writable"
out=$(probe_run "$PROBE_ROOT/writable")
if [[ "$out" == "rc=0 leftovers=0" ]]; then
    pass "可写目录：探针通过且不留下文件"
else
    fail "可写目录的探针结果不对：$out"
fi

out=$(probe_run "$PROBE_ROOT/writable/deep/nested")
if [[ "$out" == "rc=0 leftovers=0" ]]; then
    pass "不存在的路径：在最近的已存在祖先里探测"
else
    fail "不存在路径的探针结果不对：$out"
fi

mkdir -p "$PROBE_ROOT/locked"
RO_DIRS+=("$PROBE_ROOT/locked")
chmod 555 "$PROBE_ROOT/locked"
out=$(probe_run "$PROBE_ROOT/locked")
if [[ "$out" == "rc=1 leftovers=0" ]]; then
    pass "不可写目录：判定需要提权"
else
    fail "不可写目录的探针结果不对：$out"
fi
chmod 755 "$PROBE_ROOT/locked"

# -------------------- 4. --skip-probe --------------------

echo
echo "========== --skip-probe =========="

probe_run_flag() {
    # 与 probe_run 相同，但把 CLI_SKIP_PROBE 打开
    /bin/bash -c '
mw_dry_run() { return 1; }
CLI_SKIP_PROBE=true
eval "$(sed -n "/^mw_mktemp()/,/^}/p" "$1")"
eval "$(sed -n "/^mw_can_write()/,/^}/p" "$1")"
dir="$2"
rc=0
mw_can_write "$dir" || rc=$?
leftovers=$(find "$dir" -maxdepth 1 -name ".macwave-write-probe.*" 2>/dev/null | wc -l | tr -d " ")
echo "rc=$rc leftovers=$leftovers"
' _ "$INSTALL_SH" "$1"
}

SKIP_ROOT=$(new_root skip)
mkdir -p "$SKIP_ROOT/writable"
out=$(probe_run_flag "$SKIP_ROOT/writable")
if [[ "$out" == "rc=0 leftovers=0" ]]; then
    pass "--skip-probe：可写目录照常放行，且一个文件都不建"
else
    fail "--skip-probe 的可写目录结果不对：$out"
fi

mkdir -p "$SKIP_ROOT/locked"
RO_DIRS+=("$SKIP_ROOT/locked")
chmod 555 "$SKIP_ROOT/locked"
out=$(probe_run_flag "$SKIP_ROOT/locked")
if [[ "$out" == "rc=1 leftovers=0" ]]; then
    pass "--skip-probe：不可写目录仍要靠权限位判定为需要提权"
else
    fail "--skip-probe 的不可写目录结果不对：$out"
fi
chmod 755 "$SKIP_ROOT/locked"

# 帮助里必须列出来 —— 否则没人知道有这个开关
out=$(/bin/bash "$INSTALL_SH" --help 2>&1)
ok_contains() {
    if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3"; fi
}
ok_contains "$out" "--skip-probe" "英文帮助里列出了 --skip-probe"
out=$(/bin/bash "$INSTALL_SH" --help --zh 2>&1)
ok_contains "$out" "--skip-probe" "中文帮助里列出了 --skip-probe"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All install privilege tests passed${RESET}"
