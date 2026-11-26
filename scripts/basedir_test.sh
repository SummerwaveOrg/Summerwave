#!/bin/bash

# basedir_test.sh
# `wave basedir` 的四条不变量：
#
#   1. 默认输出带 🌊，内容是写死的安装根（MACWAVE_TEST 下映射进测试根）；
#   2. `--raw` 输出**原样**的绝对路径 —— 不折 ~、不带 🌊、不带颜色，
#      因为 `~` 只在词首、未加引号时才展开，`cd "$(wave basedir --raw)"`
#      会把它当字面量；
#   3. `--set` 已经删除：路径写死，搬不动，命令必须明确报错而不是静默忽略；
#   4. 未知旗标指向 --help；`-s/--silent` 不许用在 basedir 上（这条命令存在的
#      意义就是输出，静默它等于把命令废掉）。
#
# 自带隔离：MACWAVE_TEST 临时根，不碰真实的 /opt。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

PASSED=0
FAILED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }

# shellcheck source=./components.sh
source "$SCRIPT_DIR/components.sh"

# 物理路径：configpaths 会 resolve() 测试根，/var → /private/var 的差异
# 会让后面的字符串比对全部落空。
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# 组件拷进 <root>/opt/macwave，并放一份状态文件 —— 没有它，configerror 会把
# 「在 git 仓库里直接跑」当成装了一半。
ROOT="$WORK/root"
BASE="$ROOT/opt/macwave"
mkdir -p "$BASE/var"
copy_components "$BASE/"
printf "MACWAVE_VERSION='9.9.9'\n" > "$BASE/var/config.sh"

run_wave() {
    MACWAVE_TEST="$ROOT" "$PYTHON" "$REPO_DIR/lib/wave.py" "$@"
}

echo "========== 1. 默认形态与 --raw =========="

DEFAULT_OUT="$(run_wave basedir 2>&1)"
RAW_OUT="$(run_wave basedir --raw 2>&1)"

if [[ "$DEFAULT_OUT" == "🌊 $BASE" ]]; then
    pass "默认输出是写死的安装根（${DEFAULT_OUT}）"
else
    fail "默认输出不对：$DEFAULT_OUT"
fi

if [[ "$RAW_OUT" == "$BASE" ]]; then
    pass "--raw 输出原样的绝对路径"
else
    fail "--raw 输出不对：$RAW_OUT"
fi

if [[ "$RAW_OUT" == *"🌊"* || "$RAW_OUT" == *$'\033'* ]]; then
    fail "--raw 的输出里还有 🌊 或颜色码"
else
    pass "--raw 不带 🌊、不带颜色"
fi

# --raw 的用途就是喂给 shell：它必须能直接 cd 进去
if [[ -d "$RAW_OUT" ]] && ( cd "$RAW_OUT" ); then
    pass "--raw 的路径可以直接 cd"
else
    fail "--raw 的路径 cd 不进去：$RAW_OUT"
fi

echo
echo "========== 2. 配置文件不再影响结果 =========="

mkdir -p "$ROOT/opt/macwave_config"
printf '{"base_dir": "/tmp/elsewhere"}\n' > "$ROOT/opt/macwave_config/config.json"
DECOY_OUT="$(run_wave basedir --raw 2>&1)"
if [[ "$DECOY_OUT" == "$BASE" ]]; then
    pass "config.json 里的 base_dir 被忽略"
else
    fail "config.json 仍然影响了结果：$DECOY_OUT"
fi
rm -rf "$ROOT/opt/macwave_config"

echo
echo "========== 3. 该拒绝的几处 =========="

SET_OUT="$(run_wave basedir --set "$WORK/moved" 2>&1)"; SET_RC=$?
if [[ $SET_RC -eq 1 && "$SET_OUT" == *"--set has been removed"* && "$SET_OUT" == *"$BASE"* ]]; then
    pass "--set 报错、点名已删除、并说出写死的路径"
else
    fail "--set 的处理不对（exit ${SET_RC}）：$SET_OUT"
fi

SET2_OUT="$(run_wave basedir --set="$WORK/moved" 2>&1)"; SET2_RC=$?
if [[ $SET2_RC -eq 1 && "$SET2_OUT" == *"--set has been removed"* ]]; then
    pass "--set=<路径> 同样被拒绝"
else
    fail "--set=<路径> 的处理不对（exit ${SET2_RC}）：$SET2_OUT"
fi

DRY_OUT="$(run_wave basedir --dry-run 2>&1)"; DRY_RC=$?
if [[ $DRY_RC -eq 1 && "$DRY_OUT" == *"--set"* ]]; then
    pass "--dry-run 只在 --set 下有意义，单独给要报错"
else
    fail "--dry-run 的处理不对（exit ${DRY_RC}）：$DRY_OUT"
fi

BAD="$(run_wave basedir --bogus 2>&1)"; BAD_RC=$?
if [[ $BAD_RC -eq 1 && "$BAD" == *"--help"* ]]; then
    pass "未知旗标报错并指向 --help"
else
    fail "未知旗标的处理不对（exit ${BAD_RC}）：$BAD"
fi

SILENT="$(run_wave basedir -s 2>&1)"; SILENT_RC=$?
if [[ $SILENT_RC -eq 1 && "$SILENT" != *"$BASE"* ]]; then
    pass "-s 被拒绝，且没有把路径打出来"
else
    fail "-s 的处理不对（exit ${SILENT_RC}）：$SILENT"
fi

echo
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo "🌊 Failed: $FAILED"
echo "=========================================="

if [[ $FAILED -eq 0 ]]; then
    echo "🌊 All basedir checks passed"
    exit 0
else
    echo "🌊 basedir checks failed"
    exit 1
fi
