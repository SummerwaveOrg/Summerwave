#!/bin/bash

# uninstall_gate_test.sh
# 卸载闸：不许把一个还被别的软件依赖着的东西直接删掉。
#
# 钉住四件事：
#   1. 目录里有 .depped_* 标记时，卸载被拒绝，并说出是谁在依赖它；
#   2. -F/--force 越过这道闸；
#   3. 没人依赖时照常卸载；
#   4. 0.1.0 之前那种带 pkg_ / dep_ 前缀的旧标记仍然认（装过旧版本的机器上还留着）。
#
# 全程离线：只在沙箱里造目录与标记文件，不下载任何东西。

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

source "$SCRIPT_DIR/components.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ROOT="$WORK/root"
BASE="$ROOT/opt/macwave"
mkdir -p "$BASE/var"
copy_components "$BASE/" > /dev/null
printf "MACWAVE_VERSION='0.1.0'\n" > "$BASE/var/config.sh"

export MACWAVE_TEST="$ROOT"

wave() { "$PYTHON" "$REPO_DIR/lib/wave.py" "$@" 2>&1; }

# 一个「依赖」目录 + 一个依赖者留下的标记
make_dep() {
    # make_dep <名字> <版本> [标记名]
    local name="$1" version="$2" mark="${3:-}"
    mkdir -p "$BASE/Shore/$name/$version"
    if [[ -n "$mark" ]]; then
        : > "$BASE/Shore/$name/$version/.depped_$mark"
    fi
}

echo "========== 1. 没人依赖 → 照常卸载 =========="
make_dep orphan 1.0
OUT=$(wave uninstall orphan@1.0)
RC=$?
if [[ "$RC" -eq 0 ]] && [[ ! -d "$BASE/Shore/orphan/1.0" ]]; then
    pass "没有标记时正常卸载"
else
    fail "应该能卸载（rc=${RC}）：$OUT"
fi

echo "========== 2. 有依赖者 → 拒绝 =========="
make_dep oniguruma 6.9.9 "wget@1.25.0"
OUT=$(wave uninstall oniguruma@6.9.9)
RC=$?
if [[ "$RC" -ne 0 ]] && [[ -d "$BASE/Shore/oniguruma/6.9.9" ]]; then
    pass "被依赖时拒绝卸载"
else
    fail "应该拒绝（rc=${RC}）：$OUT"
fi
if echo "$OUT" | grep -q "wget@1.25.0"; then
    pass "拒绝时说明了是谁在依赖它"
else
    fail "没有说明依赖者：$OUT"
fi
if echo "$OUT" | grep -q "force"; then
    pass "拒绝时给出了 --force 的出路"
else
    fail "没有提到 --force：$OUT"
fi

echo "========== 3. -F 越过 =========="
OUT=$(wave uninstall oniguruma@6.9.9 -F)
RC=$?
if [[ "$RC" -eq 0 ]] && [[ ! -d "$BASE/Shore/oniguruma/6.9.9" ]]; then
    pass "-F 之后真的删掉了"
else
    fail "-F 应该能删（rc=${RC}）：$OUT"
fi
if echo "$OUT" | grep -qi "still required"; then
    pass "-F 仍然警告了一句"
else
    fail "-F 应保留警告：$OUT"
fi

echo "========== 4. 旧格式标记仍然认 =========="
make_dep libidn2 2.3.8 "pkg_wget@1.25.0"
OUT=$(wave uninstall libidn2@2.3.8)
RC=$?
if [[ "$RC" -ne 0 ]] && [[ -d "$BASE/Shore/libidn2/2.3.8" ]]; then
    pass "带 pkg_ 前缀的旧标记也能拦住"
else
    fail "旧格式标记没认出来（rc=${RC}）：$OUT"
fi
if echo "$OUT" | grep -q "wget@1.25.0" && ! echo "$OUT" | grep -q "pkg_wget"; then
    pass "旧标记里的前缀被剥掉了"
else
    fail "旧标记的显示不对：$OUT"
fi

echo "========== 5. --force 长写法 =========="
make_dep ncurses 6.6 "jq@1.8.2"
wave uninstall ncurses@6.6 --force > /dev/null
if [[ ! -d "$BASE/Shore/ncurses/6.6" ]]; then
    pass "--force 与 -F 等价"
else
    fail "--force 没生效"
fi

echo
echo "=========================================="
if [[ "$FAILED" -eq 0 ]]; then
    echo -e "${GREEN}🌊 All uninstall gate checks passed${RESET}"
else
    echo -e "${RED_BOLD}🌊 uninstall gate: $FAILED failed${RESET}"
fi
echo "  Passed: $PASSED"
echo "  Failed: $FAILED"
[[ "$FAILED" -eq 0 ]]
