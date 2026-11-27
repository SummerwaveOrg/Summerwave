#!/bin/bash

# relocate_test.sh
# `scripts/relocate_rpath.py` 的判据回归：什么样的引用算「已经就位」。
#
# 为什么值得单独一条：这条判据同时是**闸门**（不通过就拒绝打包）和**跳过条件**
# （通过就不改写）。判宽了会静默放过坏产物 —— 旧瓶子里的
# `@loader_path/../../../deps/ncurses/ncurses@6.6/lib/…` 就是这种情况：
# 前缀是 @loader_path（看着「位置无关」），但那棵 deps/ 树在 0.1.0 里已经不存在，
# 重编时被当成「已经就位」放过，装完就是 Library not loaded。
#
# 离线：判据本身只做路径运算，不需要真的 Mach-O；这里用临时目录摆出「目标在 / 目标不在」
# 两种树，直接调那几个判断函数。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

FAILED=0
PASSED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1（期望 $3，实际 $2）"; fi; }

PYTHON="${MACWAVE_PYTHON:-python3}"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# 摆一棵 0.1.0 的运行时树，和一个「4.x 老树」的引用
mkdir -p "$WORK/root/Shore/htop/3.5.3/bin" "$WORK/root/Shore/ncurses/6.6/lib"
: > "$WORK/root/Shore/ncurses/6.6/lib/libncursesw.6.dylib"
HT=("$WORK/root/Shore/htop/3.5.3/bin/htop")

OUTPUT="$("$PYTHON" - "$REPO_DIR" "${HT[0]}" <<'PYEOF'
import sys
repo, file_path = sys.argv[1], sys.argv[2]
sys.path.insert(0, f"{repo}/scripts")
import importlib.util
spec = importlib.util.spec_from_file_location("reloc", f"{repo}/scripts/relocate_rpath.py")
reloc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reloc)

cases = [
    # (引用, 期望是否算「已就位」, 说明)
    ("@loader_path/../../../ncurses/6.6/lib/libncursesw.6.dylib", True,  "新布局、目标存在"),
    ("@loader_path/../../../deps/ncurses/ncurses@6.6/lib/libncursesw.6.dylib", False,
                                                                          "旧布局、目标不在"),
    # 多写一层 Shore 反而指错（这层前缀是相对 staging 根算的，不是绝对路径）
    ("@loader_path/../../../Shore/ncurses/6.6/lib/libncursesw.6.dylib", False,
                                                                          "多写一层 Shore 就指错了"),
    ("@loader_path/../lib/libmissing.dylib", False,                      "同包内目标不在"),
    ("@executable_path/../lib/x.dylib", True,                            "运行时才定的基准，构建时放行"),
    ("/usr/lib/libSystem.B.dylib", False,                                "系统库不算「已就位」（由调用方另行跳过）"),
]
for ref, expect, why in cases:
    got = reloc.is_position_independent(ref, file_path)
    print(f"{'OK' if got == expect else 'BAD'}\t{why}\t{got}")
PYEOF
)"

BAD="$(printf '%s\n' "$OUTPUT" | grep -c '^BAD' || true)"
check "6 条判据全对" "$BAD" "0"
printf '%s\n' "$OUTPUT" | grep '^BAD' | while IFS=$'\t' read -r _ why got; do
    echo "   ✗ $why → $got"
done

# 老引用必须被**改写**成能对上的那条：plan() 会给出一条 change 动作
mkdir -p "$WORK/root2/Shore/ncurses/6.6/lib"
: > "$WORK/root2/Shore/ncurses/6.6/lib/libncursesw.6.dylib"
echo ""
echo "========== 符号链接（soname）也算「树里有」 =========="
# conda 产物引用的是 soname libz.1.dylib，真实文件叫 libz.1.2.13.dylib ——
# 只按真实文件名建索引会把每个带版本号的 dylib 都判成缺依赖。
mkdir -p "$WORK/soname/Shore/zlib/1.2.13/lib"
printf '\xcf\xfa\xed\xfe0000' > "$WORK/soname/Shore/zlib/1.2.13/lib/libz.1.2.13.dylib"
ln -s libz.1.2.13.dylib "$WORK/soname/Shore/zlib/1.2.13/lib/libz.1.dylib"

INDEX_OUT="$("$PYTHON" - "$REPO_DIR" "$WORK/soname" <<'PYEOF'
import sys
repo, root = sys.argv[1], sys.argv[2]
import importlib.util
spec = importlib.util.spec_from_file_location("reloc", f"{repo}/scripts/relocate_rpath.py")
reloc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reloc)
index = reloc.build_index(root)
print("soname:", "libz.1.dylib" in index)
print('real:', 'libz.1.2.13.dylib' in index)
PYEOF
)"
check "soname（符号链接名）进了索引" "$(printf '%s\n' "$INDEX_OUT" | grep '^soname:' | awk '{print $2}')" "True"
check "真实文件名也在索引里" "$(printf '%s\n' "$INDEX_OUT" | grep '^real:' | awk '{print $2}')" "True"

echo ""
echo "========== plan() 确实打算改写旧引用 =========="
grep -q 'if ref == current_id' "$REPO_DIR/scripts/relocate_rpath.py" \
    && pass "plan() 的改写分支还在" || fail "plan() 结构变了，这条测试要跟着改"
grep -q 'os.path.exists(target)' "$REPO_DIR/scripts/relocate_rpath.py" \
    && pass "判据里有存在性检查（不是只看前缀）" || fail "判据又退回「只看前缀」了"

echo ""
echo "========== 同名 dylib 与 universal 可执行文件的两处误判 =========="

# 1. `otool -D` 对**没有 LC_ID_DYLIB 的 universal 可执行文件**只打头部
#    （`<路径> (architecture <arch>):`），旧实现取第二行 → 把文件名当成 id，
#    于是计划里多出一条 -id 改写，--check 又按这个假 id 拒绝打包
#    （ollama / llama-server / llama-quantize 就是这么卡住的）。
# 2. `@rpath/libmlx.dylib` 这类「同名多份」的引用，旧实现一律报 ambiguous，
#    但 ollama 的 v3/v4 两个后端本来就该各找各的。

if command -v clang >/dev/null 2>&1; then
    mkdir -p "$WORK/uni"
    printf 'int main(void){return 0;}\n' > "$WORK/uni/m.c"
    clang -arch arm64 -arch x86_64 -o "$WORK/uni/exe" "$WORK/uni/m.c" 2>/dev/null
    clang -arch arm64 -o "$WORK/uni/thin" "$WORK/uni/m.c" 2>/dev/null
    clang -arch arm64 -dynamiclib -install_name @rpath/libfoo.dylib \
        -o "$WORK/uni/libfoo.dylib" "$WORK/uni/m.c" 2>/dev/null

    ID_OUT="$("$PYTHON" - "$REPO_DIR" "$WORK/uni" <<'PYEOF'
import sys
repo, base = sys.argv[1], sys.argv[2]
import importlib.util
spec = importlib.util.spec_from_file_location("reloc", f"{repo}/scripts/relocate_rpath.py")
reloc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reloc)
print("universal_exe_id:", repr(reloc.dylib_id(f"{base}/exe")))
print("thin_exe_id:", repr(reloc.dylib_id(f"{base}/thin")))
print("dylib_id:", repr(reloc.dylib_id(f"{base}/libfoo.dylib")))
PYEOF
)"
    check "universal 可执行文件没有 id" \
        "$(printf '%s\n' "$ID_OUT" | grep '^universal_exe_id:' | sed "s/^universal_exe_id: //")" "''"
    check "thin 可执行文件也没有 id" \
        "$(printf '%s\n' "$ID_OUT" | grep '^thin_exe_id:' | sed "s/^thin_exe_id: //")" "''"
    check "dylib 的 id 照常读出" \
        "$(printf '%s\n' "$ID_OUT" | grep '^dylib_id:' | grep -c '@rpath/libfoo.dylib')" "1"

    # 同名两份：引用者在 v3 目录里，应该挑 v3 的那份
    mkdir -p "$WORK/dup/Shore/x/1.0/v3" "$WORK/dup/Shore/x/1.0/v4"
    cp "$WORK/uni/libfoo.dylib" "$WORK/dup/Shore/x/1.0/v3/libdup.dylib"
    cp "$WORK/uni/libfoo.dylib" "$WORK/dup/Shore/x/1.0/v4/libdup.dylib"
    cp "$WORK/uni/libfoo.dylib" "$WORK/dup/Shore/x/1.0/v3/libcaller.dylib"
    DUP_OUT="$("$PYTHON" - "$REPO_DIR" "$WORK/dup" <<'PYEOF'
import sys, os
repo, root = sys.argv[1], sys.argv[2]
import importlib.util
spec = importlib.util.spec_from_file_location("reloc", f"{repo}/scripts/relocate_rpath.py")
reloc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reloc)
index = reloc.build_index(root)
picked, err = reloc.pick_candidate(index["libdup.dylib"],
                                   os.path.join(root, "Shore/x/1.0/v3/libcaller.dylib"), root)
print("picked:", os.path.relpath(picked, root) if picked else "None")
print("error:", bool(err))
PYEOF
)"
    check "同名 dylib 按引用者所在目录裁决" \
        "$(printf '%s\n' "$DUP_OUT" | grep '^picked:' | awk '{print $2}')" \
        "Shore/x/1.0/v3/libdup.dylib"
    check "没有误报歧义" "$(printf '%s\n' "$DUP_OUT" | grep '^error:' | awk '{print $2}')" "False"
else
    echo "🌊 SKIP: 没有 clang，跳过编译类断言"
fi

echo ""
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo -e "🌊 Failed: ${RED_BOLD}$FAILED${RESET}"
echo "=========================================="
[[ $FAILED -eq 0 ]] || exit 1
