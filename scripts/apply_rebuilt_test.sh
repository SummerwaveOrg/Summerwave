#!/bin/bash

# apply_rebuilt_test.sh
# `scripts/apply_rebuilt_records.py` 的离线回归：把重打后的 file / sha256 写回索引。
#
# 为什么值得单独一条：重打必然改字节，索引里的 sha256 立刻过期。「上传资产」与
# 「回填索引」错位的症状是用户下到字节校验不过、报「装到一半失败」，而索引本身
# 看起来完全正常 —— 这种不一致只能靠工具两边对账发现。
#
# 钉住四件事：
#   1. 默认只报告，一个字节都不写
#   2. file / sha256 / relocated 被更新，其它字段（含 deps、min_os）逐字保留
#   3. 安装形态按归档的实际形状决定：有 bin/ → tree；单文件 → 删掉 install 字段
#   4. 依赖记录不动 install（依赖安装器固定用 tree，那个字段没人读）
#
# 全程离线：造假的 infosource、假的 tsv、真的 tar.bz2。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY="$SCRIPT_DIR/apply_rebuilt_records.py"
PYTHON="${MACWAVE_PYTHON:-python3}"

FAILED=0
PASSED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1（期望 $3，实际 $2）"; fi; }

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

INFO="$WORK/infosource"
PRE="$WORK/prebuilt"
mkdir -p "$INFO/pkg/pkginfo/tree-pkg" "$INFO/pkg/pkginfo/single" \
         "$INFO/deps/depsinfo/zlib" "$PRE"

# 造三个归档：整树（有 bin/）、单文件（根目录就一个文件）、依赖整树
mkdir -p "$WORK/stage/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/stage/bin/tree-pkg"
tar cjf "$PRE/tree-pkg@1.0.macos-arm64.tar.bz2" -C "$WORK/stage" bin
printf '#!/bin/sh\nexit 0\n' > "$WORK/onefile"
tar cjf "$PRE/single@2.0.macos-arm64.tar.bz2" -C "$WORK" onefile
mkdir -p "$WORK/dstage/lib"
printf 'x' > "$WORK/dstage/lib/libz.dylib"
tar cjf "$PRE/zlib@1.3.macos-arm64.tar.bz2" -C "$WORK/dstage" lib

# 记录：故意把 file/sha256 写成旧的，并带上必须被保留的其它字段
printf 'bin_name: "tree-pkg"\ndes: "tree"\n' > "$INFO/pkg/pkginfo/tree-pkg/_tree-pkg@common"
printf 'sha256: "%064d"\nfile: "old"\nurl: "https://x/y"\nmin_os: "15.0"\ndeps: "zlib@1.3"\n' 0 \
    > "$INFO/pkg/pkginfo/tree-pkg/_tree-pkg@1.0.macos-arm64"
printf 'sha256: "%064d"\nfile: "old"\ninstall: "tree"\n' 0 \
    > "$INFO/pkg/pkginfo/single/_single@2.0.macos-arm64"
printf 'sha256: "%064d"\nfile: "old"\n' 0 > "$INFO/deps/depsinfo/zlib/_zlib@1.3.macos-arm64"

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
TSV="$WORK/rows.tsv"
{
    printf 'kind\tname\tversion\tarch\tfile\tsha256\n'
    printf 'pkg\ttree-pkg\t1.0\tarm64\ttree-pkg@1.0.macos-arm64.tar.bz2\t%s\n' "$(sha_of "$PRE/tree-pkg@1.0.macos-arm64.tar.bz2")"
    printf 'pkg\tsingle\t2.0\tarm64\tsingle@2.0.macos-arm64.tar.bz2\t%s\n' "$(sha_of "$PRE/single@2.0.macos-arm64.tar.bz2")"
    printf 'deps\tzlib\t1.3\tarm64\tzlib@1.3.macos-arm64.tar.bz2\t%s\n' "$(sha_of "$PRE/zlib@1.3.macos-arm64.tar.bz2")"
} > "$TSV"

BEFORE="$(cd "$INFO" && find . -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"; done)"

echo "========== 1. 默认只报告 =========="
OUT="$("$PYTHON" "$APPLY" --tsv "$TSV" --prebuilt "$PRE" --infosource "$INFO" 2>&1)"; RC=$?
check "退出码 0" "$RC" "0"
AFTER="$(cd "$INFO" && find . -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"; done)"
check "一个字节都没写" "$AFTER" "$BEFORE"
[[ "$OUT" == *"would update 3"* ]] && pass "报告了 3 条待更新" || fail "计数不对：$OUT"

echo
echo "========== 2. --apply 写回，其它字段保留 =========="
"$PYTHON" "$APPLY" --tsv "$TSV" --prebuilt "$PRE" --infosource "$INFO" --apply > /dev/null 2>&1

REC="$INFO/pkg/pkginfo/tree-pkg/_tree-pkg@1.0.macos-arm64"
check "file 换成新产物名" "$(grep -c '^file: "tree-pkg@1.0.macos-arm64.tar.bz2"' "$REC")" "1"
check "sha256 换成真实值" \
    "$(grep -c "^sha256: \"$(sha_of "$PRE/tree-pkg@1.0.macos-arm64.tar.bz2")\"" "$REC")" "1"
check "补上 relocated" "$(grep -c '^relocated: "loader_path"' "$REC")" "1"
check "min_os 原样保留" "$(grep -c '^min_os: "15.0"' "$REC")" "1"
check "deps 边原样保留" "$(grep -c '^deps: "zlib@1.3"' "$REC")" "1"
check "url 原样保留" "$(grep -c '^url: "https://x/y"' "$REC")" "1"

echo
echo "========== 3. 安装形态按归档形状决定 =========="
check "有 bin/ 的包 → install: tree" "$(grep -c '^install: "tree"' "$REC")" "1"
SINGLE="$INFO/pkg/pkginfo/single/_single@2.0.macos-arm64"
check "单文件包 → 删掉 install 字段" "$(grep -c '^install:' "$SINGLE")" "0"
DEP="$INFO/deps/depsinfo/zlib/_zlib@1.3.macos-arm64"
check "依赖记录不加 install 字段" "$(grep -c '^install:' "$DEP")" "0"
check "依赖记录的 sha256 仍然被更新" \
    "$(grep -c "^sha256: \"$(sha_of "$PRE/zlib@1.3.macos-arm64.tar.bz2")\"" "$DEP")" "1"

echo
echo "========== 4. 幂等 + 对账 =========="
OUT="$("$PYTHON" "$APPLY" --tsv "$TSV" --prebuilt "$PRE" --infosource "$INFO" --apply 2>&1)"
[[ "$OUT" == *"already current 3"* ]] && pass "再跑一次全部是「已是最新」" || fail "不幂等：$OUT"

# sha 对不上必须报出来（上传/回填错位的典型症状）
printf 'kind\tname\tversion\tarch\tfile\tsha256\npkg\ttree-pkg\t1.0\tarm64\ttree-pkg@1.0.macos-arm64.tar.bz2\t%s\n' \
    "$(printf 'b%.0s' {1..64})" > "$WORK/bad.tsv"
OUT="$("$PYTHON" "$APPLY" --tsv "$WORK/bad.tsv" --prebuilt "$PRE" --infosource "$INFO" 2>&1)"; RC=$?
check "sha 不符时退出码 1" "$RC" "1"
[[ "$OUT" == *"does not match the tsv"* ]] && pass "点明了 sha256 不符" || fail "没说清原因：$OUT"

echo ""
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo -e "🌊 Failed: ${RED_BOLD}$FAILED${RESET}"
echo "=========================================="
[[ $FAILED -eq 0 ]] || exit 1
