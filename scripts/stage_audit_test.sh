#!/bin/bash

# stage_audit_test.sh
# 上传前体检（scripts/stage_audit.py）的离线回归。
#
# 为什么值得单独一条：体检的对象是**上游产物**，不是我们编的。上游把什么烘进
# 二进制我们不知道，所以每一类脏都必须有一条断言盯着 —— 少了哪条，那一类脏就会
# 静默通过，等到用户机上才炸（「装得上」这一步永远正常）。
#
# 覆盖两类判据：
#   ERROR（会坏）—— 悬空符号链接、bin/ 下没有执行位、conda 占位符没换干净、
#                   Mach-O 引用构建机绝对路径
#   WARN（脏）  —— 上游元数据 info/、.pyc、.la、.DS_Store、构建机路径字符串、空目录
# 外加冒烟：能跑起来 / dyld 失败必须分得开。
#
# 需要 clang 与 otool（macOS 自带）。两者都没有时整条跳过，不算失败。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${MACWAVE_PYTHON:-python3}"
AUDIT="$SCRIPT_DIR/stage_audit.py"

FAILED=0
PASSED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1（期望「$3」，实际「$2」）"; fi; }
contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1（输出里没有「$3」）"; fi; }
absent() { if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1（输出里不该有「$3」）"; fi; }

if ! command -v clang >/dev/null 2>&1 || ! command -v otool >/dev/null 2>&1; then
    echo -e "${YELLOW}🌊 SKIP: 需要 clang 与 otool${RESET}"
    exit 0
fi

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# 造一棵最小但完整的 stage：Shore/<名>/<版本>/bin/<名>
new_stage() {
    local stage="$1"
    mkdir -p "$stage/Shore/foo/1.0/bin"
    printf '#!/bin/sh\necho foo 1.0\n' > "$stage/Shore/foo/1.0/bin/foo"
    chmod +x "$stage/Shore/foo/1.0/bin/foo"
}

run_audit() {  # run_audit <stage-or-archive>; 结果写进 OUT / RC
    if [[ -d "$1" ]]; then
        OUT="$("$PYTHON" "$AUDIT" --stage "$1" 2>&1)"
    else
        OUT="$("$PYTHON" "$AUDIT" --archive "$1" 2>&1)"
    fi
    RC=$?
}

echo "========== 1. 干净的树 =========="
S="$WORK/clean"; new_stage "$S"
run_audit "$S"
check "干净树退出码为 0" "$RC" "0"
contains "干净树报告 clean" "$OUT" "clean"
absent "干净树没有 ERROR" "$OUT" "ERROR"

echo ""
echo "========== 2. ERROR：悬空符号链接 =========="
S="$WORK/dangling"; new_stage "$S"
ln -s ../../../nowhere "$S/Shore/foo/1.0/bin/gone"
run_audit "$S"
check "悬空链接退出码非 0" "$RC" "1"
contains "抓到悬空链接" "$OUT" "悬空符号链接"

echo ""
echo "========== 3. ERROR：bin/ 下没有执行位 =========="
S="$WORK/noexec"; new_stage "$S"
printf '#!/bin/sh\n' > "$S/Shore/foo/1.0/bin/nox"
chmod -x "$S/Shore/foo/1.0/bin/nox"
run_audit "$S"
check "缺执行位退出码非 0" "$RC" "1"
contains "抓到缺执行位" "$OUT" "bin/ 下没有执行位"

echo ""
echo "========== 4. ERROR：conda 占位符没替换 =========="
S="$WORK/placeholder"; new_stage "$S"
mkdir -p "$S/Shore/foo/1.0/lib/pkgconfig"
printf 'prefix=_h_env_placehold_xxxxxxxxxxxxxxxxxxxx\n' \
    > "$S/Shore/foo/1.0/lib/pkgconfig/foo.pc"
run_audit "$S"
check "占位符残留退出码非 0" "$RC" "1"
contains "抓到占位符" "$OUT" "conda 占位符没替换"

echo ""
echo "========== 5. ERROR：Mach-O 引用构建机绝对路径 =========="
S="$WORK/machoref"; new_stage "$S"
mkdir -p "$S/Shore/foo/1.0/lib"
clang -dynamiclib -o "$S/Shore/foo/1.0/lib/libbad.dylib" -x c - <<'EOF' 2>/dev/null
int probe(void) { return 1; }
EOF
install_name_tool -id /opt/anaconda3/lib/libbad.dylib "$S/Shore/foo/1.0/lib/libbad.dylib" 2>/dev/null
run_audit "$S"
check "绝对路径引用退出码非 0" "$RC" "1"
contains "抓到 Mach-O 构建机路径" "$OUT" "Mach-O 引用构建机绝对路径"

echo ""
echo "========== 6. WARN：上游元数据与缓存（不拦，只报） =========="
S="$WORK/junk"; new_stage "$S"
mkdir -p "$S/Shore/foo/1.0/info" "$S/Shore/foo/1.0/lib/__pycache__"
printf '{}' > "$S/Shore/foo/1.0/info/index.json"
printf 'x' > "$S/Shore/foo/1.0/lib/x.la"
printf 'x' > "$S/Shore/foo/1.0/lib/__pycache__/a.cpython-314.pyc"
printf 'x' > "$S/Shore/foo/1.0/.DS_Store"
run_audit "$S"
check "只有 WARN 时退出码为 0" "$RC" "0"
contains "报 info/" "$OUT" "conda 元数据 info/"
contains "报 .la" "$OUT" "libtool .la"
contains "报 .DS_Store" "$OUT" "Finder 垃圾"
contains "报字节码缓存" "$OUT" "字节码缓存"
absent "__pycache__ 里不再逐个报 pyc" "$OUT" "a.cpython-314.pyc"

echo ""
echo "========== 7. WARN：空目录与构建机路径字符串 =========="
S="$WORK/paths"; new_stage "$S"
mkdir -p "$S/Shore/foo/1.0/emptydir" "$S/Shore/foo/1.0/lib/pkgconfig"
printf 'prefix=/opt/anaconda3/conda-bld/foo_1/work\n' \
    > "$S/Shore/foo/1.0/lib/pkgconfig/foo.pc"
run_audit "$S"
check "构建机路径只是 WARN（退出码 0）" "$RC" "0"
contains "报空目录" "$OUT" "空目录"
contains "报构建机路径" "$OUT" "构建机路径"

echo ""
echo "========== 8. 归档模式与目录模式结论一致 =========="
S="$WORK/arc"; new_stage "$S"
mkdir -p "$S/Shore/foo/1.0/info"
printf '{}' > "$S/Shore/foo/1.0/info/index.json"
ln -s ../../../nowhere "$S/Shore/foo/1.0/bin/gone"
( cd "$S" && tar -cjf "$WORK/bad.tar.bz2" . ) 2>/dev/null
run_audit "$WORK/bad.tar.bz2"
check "归档里的悬空链接也能抓到" "$RC" "1"
contains "归档报告悬空链接" "$OUT" "悬空符号链接"
contains "归档报告 info/" "$OUT" "conda 元数据 info/"

echo ""
echo "========== 9. 冒烟：分类逻辑（ok / dyld-error / timeout） =========="
S="$WORK/smoke"; new_stage "$S"
clang -o "$S/Shore/foo/1.0/bin/real" -x c - <<'EOF' 2>/dev/null
#include <stdio.h>
int main(void) { printf("real 1.0\n"); return 0; }
EOF
# 真的 dyld 失败在这里没法稳定复现：引用不存在的 dylib 会让 amfid 评估挂住
# （沙箱里等系统服务），表现是超时而不是报错。所以这一条测的是**分类器**：
# 输出里带 dyld 标记就必须判成 dyld-error，而不是 ok。
printf '#!/bin/sh\necho "dyld: Library not loaded: /opt/anaconda3/lib/libnope.dylib" >&2\nexit 134\n' \
    > "$S/Shore/foo/1.0/bin/broken"
chmod +x "$S/Shore/foo/1.0/bin/broken"
printf '#!/bin/sh\nsleep 30\n' > "$S/Shore/foo/1.0/bin/slow"
chmod +x "$S/Shore/foo/1.0/bin/slow"
OUT="$("$PYTHON" - "$S" "$AUDIT" <<'PYEOF'
import json, sys
sys.path.insert(0, sys.argv[2].rsplit("/", 1)[0])
import stage_audit
print(json.dumps(stage_audit.smoke(sys.argv[1], timeout=1), ensure_ascii=False))
PYEOF
)"
contains "冒烟抓到 dyld 失败" "$OUT" '"status": "dyld-error"'
contains "冒烟放过能跑的" "$OUT" '"status": "ok"'
contains "冒烟把挂住的判成 timeout" "$OUT" '"status": "timeout"'

echo "========== 10. 单文件产物（没有 bin/）也要冒烟 =========="
S="$WORK/single"; mkdir -p "$S/Shore/bar/2.0"
clang -o "$S/Shore/bar/2.0/bar" -x c - <<'EOF' 2>/dev/null
#include <stdio.h>
int main(void) { printf("bar 2.0\n"); return 0; }
EOF
OUT="$(cd "$S" && "$PYTHON" "$AUDIT" --stage "$S" --smoke --json 2>&1)"
contains "版本目录根上的可执行文件也被跑到" "$OUT" 'Shore/bar/2.0/bar'
contains "单文件产物冒烟通过" "$OUT" '"status": "ok"'

echo ""
echo "=========================================="
echo -e "${GREEN}Passed: $PASSED${RESET}"
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}Failed: $FAILED${RESET}"
    exit 1
fi
echo "Failed: 0"
exit 0
