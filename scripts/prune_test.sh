#!/bin/bash

# prune_test.sh
# `install.sh` 的声明式收敛：清单里没有的、躺在清单管理目录里的文件必须删掉。
#
# 为什么值得单独一条测试：`sync_tree` 只覆盖与新增、从不删除。升级到文件集合
# **变小**的版本（模块改名、拆文件、换目录）时，旧文件会留在原地 —— 旧模块待在
# lib/ 里就是「同一份代码两个副本」，sys.path 一变就跑到旧代码上。这类故障表现为
# 「升级成功但没生效」，比装不上难查得多。
#
# 同时钉住边界：只删清单管理目录里的文件，绝不碰 Shore/（已装包）、var/（状态）、
# venv/、python/、downloads/。
#
# 全程离线：只抽取 install.sh 里的那两个函数，不跑安装、不碰网络。

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

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# 只抽出 prune_tree 与那张目录白名单；整个 install.sh 的顶层会真的开始安装。
extract() {
    sed -n "/^$1() {/,/^}/p" "$INSTALL_SH"
}
PRUNE_BODY="$(extract prune_tree)"
ROOTS_LINE="$(grep -m1 '^MANAGED_ROOTS=' "$INSTALL_SH")"

if [[ -z "$PRUNE_BODY" || -z "$ROOTS_LINE" ]]; then
    echo -e "${RED_BOLD}🌊 Error: 没能从 install.sh 抽出 prune_tree / MANAGED_ROOTS${RESET}"
    exit 1
fi

# 造一棵树 + 一份清单，跑 prune_tree，然后回报删掉了什么。
run_prune() {
    local tree="$1" manifest="$2" dry="$3"
    DRY="$dry" BASE_DIR="$tree" MANIFEST_TMP="$manifest" /bin/bash -c '
        BASE_DIR="$BASE_DIR"; MANIFEST_TMP="$MANIFEST_TMP"
        mw_say() { printf "%s\n" "$1"; }
        mw_plan() { printf "%s\n" "$1"; }
        mw_dry_run() { [[ "$DRY" == "1" ]]; }
        install_failure_notice() { printf "FAILURE-NOTICE\n"; }
        '"$ROOTS_LINE"'
        '"$PRUNE_BODY"'
        prune_tree
    ' _ 2>&1
}

DRY=0

# -------------------- 1. 清单外的文件被删 --------------------

TREE="$WORK/t1"; mkdir -p "$TREE"/{lib,cli,net}
printf 'keep\n'  > "$TREE/lib/keep.py"
printf 'stale\n' > "$TREE/lib/stale.py"
printf 'gone\n'  > "$TREE/cli/removed.py"
MANIFEST="$WORK/m1"
printf 'lib/keep.py 0 %s\n' "$(printf keep | shasum -a 256 | cut -d' ' -f1)" > "$MANIFEST"

OUT="$(run_prune "$TREE" "$MANIFEST" 0)"
if [[ ! -e "$TREE/lib/stale.py" && ! -e "$TREE/cli/removed.py" ]]; then
    pass "清单外的文件被删掉（lib/stale.py、cli/removed.py）"
else
    fail "清单外的文件还在：$(ls "$TREE/lib" "$TREE/cli" 2>/dev/null | tr '\n' ' ')"
fi
if [[ -f "$TREE/lib/keep.py" ]]; then
    pass "清单里的文件保留"
else
    fail "清单里的文件被误删"
fi
if [[ "$OUT" == *"Removed 2 file"* ]]; then
    pass "计数正确（2 个）"
else
    fail "计数不对：$OUT"
fi

# -------------------- 2. 绝不越界 --------------------

TREE="$WORK/t2"
mkdir -p "$TREE"/{lib,Shore/jq/1.0,var,venv/bin,python/3.14/bin,downloads/tmp}
printf 'x\n' > "$TREE/lib/old.py"
printf 'pkg\n' > "$TREE/Shore/jq/1.0/jq"
printf "MACWAVE_VERSION='1'\n" > "$TREE/var/config.sh"
printf 'py\n' > "$TREE/venv/bin/python3"
printf 'py\n' > "$TREE/python/3.14/bin/python3"
printf 'part\n' > "$TREE/downloads/tmp/x.partial"
MANIFEST="$WORK/m2"; : > "$MANIFEST"

OUT="$(run_prune "$TREE" "$MANIFEST" 0)"
if [[ ! -e "$TREE/lib/old.py" ]]; then
    pass "清单管理目录里的多余文件被删"
else
    fail "lib/ 里的多余文件没删"
fi
if [[ -f "$TREE/Shore/jq/1.0/jq" ]]; then
    pass "Shore/（已装包）不动"
else
    fail "prune 删掉了已装包 —— 这会毁掉用户的软件"
fi
if [[ -f "$TREE/var/config.sh" && -f "$TREE/venv/bin/python3" \
      && -f "$TREE/python/3.14/bin/python3" && -f "$TREE/downloads/tmp/x.partial" ]]; then
    pass "var/、venv/、python/、downloads/ 都不动"
else
    fail "prune 越界删了状态或运行时目录"
fi

# -------------------- 3. 改名：旧目录整个被清 --------------------
#
# 这是 prune 真正要解决的场景：lib/ 改名成 core/ 之后，lib/ 已经不在新清单里，
# 从清单推不出它，只能靠写死的白名单。

TREE="$WORK/t3"
mkdir -p "$TREE"/{lib,core}
printf 'old\n' > "$TREE/lib/help.py"
printf 'new\n' > "$TREE/core/help.py"
MANIFEST="$WORK/m3"; printf 'core/help.py 0 -\n' > "$MANIFEST"
OUT="$(run_prune "$TREE" "$MANIFEST" 0)"
if [[ ! -e "$TREE/lib/help.py" && -f "$TREE/core/help.py" ]]; then
    pass "改名场景：旧目录里的文件被清掉，新目录保留"
else
    fail "改名场景没有收敛干净"
fi

# -------------------- 4. --dry-run 一个字节都不删 --------------------

TREE="$WORK/t4"; mkdir -p "$TREE/lib"
printf 'stale\n' > "$TREE/lib/stale.py"
MANIFEST="$WORK/m4"; : > "$MANIFEST"
OUT="$(run_prune "$TREE" "$MANIFEST" 1)"
if [[ -f "$TREE/lib/stale.py" ]]; then
    pass "--dry-run 不删文件"
else
    fail "--dry-run 删了文件"
fi
if [[ "$OUT" == *"would remove lib/stale.py"* ]]; then
    pass "--dry-run 说清会删什么"
else
    fail "--dry-run 没有报告：$OUT"
fi

# -------------------- 5. 清单里带转义空格 --------------------

TREE="$WORK/t5"; mkdir -p "$TREE/lib"
printf 'a\n' > "$TREE/lib/a b.py"
MANIFEST="$WORK/m5"; printf 'lib/a\\ b.py 0 -\n' > "$MANIFEST"
OUT="$(run_prune "$TREE" "$MANIFEST" 0)"
if [[ -f "$TREE/lib/a b.py" ]]; then
    pass "清单里的转义空格被还原，文件不被误删"
else
    fail "带空格的文件被误删了"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All prune checks passed${RESET}"
