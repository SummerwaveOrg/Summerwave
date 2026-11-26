#!/bin/bash

# migrate_index_layout_test.sh
# 索引迁移脚本的离线回归：旧布局（pkg/pkginfo_<arch>/…）搬到 1.0 布局
# （pkg/pkginfo/<名>/_<名>@<版本>.<os>-<arch>）。
#
# 为什么值得单独一条：这一步搬的是**数据仓库**。搬错的后果是「记录还在但客户端看不见」，
# 或者两份 @common 互相覆盖把元数据悄悄改掉 —— 两种都比报错难查。这里把四条边界钉死：
#
#   1. 默认（不加 --apply）一个字节都不改
#   2. 记录内容逐字节保留，只有文件名与目录变
#   3. 两个架构各有一份的 @common 只留一份；内容不同时**停下报冲突**，不覆盖
#   4. 产物改名只出计划（GitHub 资产不能改名），且计划里的新旧名字符合瓶子标签规则
#
# 全程离线：造一棵假的 infosource，不联网、不碰真实数据仓库。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
MIGRATE="$SCRIPT_DIR/migrate_index_layout.py"

FAILED=0
PASSED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1（期望 $3，实际 $2）"; fi; }

if [[ ! -f "$MIGRATE" ]]; then
    echo -e "${RED_BOLD}🌊 Error: migrate_index_layout.py not found${RESET}"
    exit 1
fi

PYTHON="${MACWAVE_PYTHON:-python3}"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# -------------------- 造一棵假的 infosource --------------------

build_fake() {
    local root="$1"
    rm -rf "$root"
    mkdir -p "$root/pkg/pkginfo_arm64/jq" "$root/pkg/pkginfo_amd64/jq" \
             "$root/pkg/pkginfo_arm64/yq" "$root/pkg/pkginfo_amd64/yq" \
             "$root/deps/depsinfo_arm64/zlib" "$root/deps/depsinfo_amd64/zlib"

    printf 'bin_name: "jq"\ndes: "a JSON processor"\n' > "$root/pkg/pkginfo_arm64/jq/_jq@common"
    printf 'bin_name: "jq"\ndes: "a JSON processor"\n' > "$root/pkg/pkginfo_amd64/jq/_jq@common"

    printf 'sha256: "%064d"\nfile: "jq-macos-arm64"\nurl: "https://x/jq-arm64"\n' 0 \
        > "$root/pkg/pkginfo_arm64/jq/_jq@1.8.2"
    printf 'sha256: "%064d"\nfile: "jq-macos-amd64"\nurl: "https://x/jq-amd64"\n' 0 \
        > "$root/pkg/pkginfo_amd64/jq/_jq@1.8.2"

    # 两个架构的 @common 不同 —— 这一条必须被报成冲突，不许静默覆盖
    printf 'bin_name: "yq"\ndes: "arm64 says hi"\n' > "$root/pkg/pkginfo_arm64/yq/_yq@common"
    printf 'bin_name: "yq"\ndes: "amd64 says something else"\n' > "$root/pkg/pkginfo_amd64/yq/_yq@common"
    printf 'sha256: "%064d"\nfile: "yq_linux_arm64.tar.gz"\nurl: "https://x/yq"\n' 0 \
        > "$root/pkg/pkginfo_arm64/yq/_yq@4.45.1"

    printf 'dep_name: "zlib"\n' > "$root/deps/depsinfo_arm64/zlib/_zlib@common"
    printf 'dep_name: "zlib"\n' > "$root/deps/depsinfo_amd64/zlib/_zlib@common"
    printf 'sha256: "%064d"\nfile: "zlib.tar.gz"\nurl: "https://x/zlib"\n' 0 \
        > "$root/deps/depsinfo_arm64/zlib/_zlib@1.3"
}

TREE="$WORK/fake"
build_fake "$TREE"
BEFORE="$(cd "$TREE" && find . -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"; done)"

echo "========== 1. 默认是 dry run =========="

OUT="$("$PYTHON" "$MIGRATE" --infosource "$TREE" 2>&1)"; RC=$?
check "退出码 0（有冲突但没 --apply）" "$RC" "0"
AFTER="$(cd "$TREE" && find . -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"; done)"
check "dry run 一个文件都没动" "$AFTER" "$BEFORE"
[[ "$OUT" == *"would"* || "$OUT" == *"Dry run"* ]] \
    && pass "提示这是 dry run" || fail "没说清是 dry run：$OUT"

echo
echo "========== 2. 冲突必须报出来 =========="

[[ "$OUT" == *"yq"* && "$OUT" == *"conflict"* ]] \
    && pass "两个架构 @common 不同 → 报冲突" || fail "冲突没报出来：$OUT"

OUT_APPLY="$("$PYTHON" "$MIGRATE" --infosource "$TREE" --apply 2>&1)"; RC_APPLY=$?
check "有冲突时 --apply 拒绝执行" "$RC_APPLY" "1"
AFTER="$(cd "$TREE" && find . -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"; done)"
check "被拒绝时也没动文件" "$AFTER" "$BEFORE"

echo
echo "========== 3. 没有冲突时才真的搬 =========="

rm -rf "$TREE/pkg/pkginfo_arm64/yq" "$TREE/pkg/pkginfo_amd64/yq"
build_fake "$WORK/clean"
rm -rf "$WORK/clean/pkg/pkginfo_arm64/yq" "$WORK/clean/pkg/pkginfo_amd64/yq"
CLEAN="$WORK/clean"

OUT="$("$PYTHON" "$MIGRATE" --infosource "$CLEAN" --apply 2>&1)"; RC=$?
check "--apply 退出码 0" "$RC" "0"

check "arm64 记录换成带标签的名字" \
    "$([[ -f "$CLEAN/pkg/pkginfo/jq/_jq@1.8.2.macos-arm64" ]] && echo yes || echo no)" "yes"
check "amd64 记录换成带标签的名字" \
    "$([[ -f "$CLEAN/pkg/pkginfo/jq/_jq@1.8.2.macos-amd64" ]] && echo yes || echo no)" "yes"
check "@common 只留一份" \
    "$(find "$CLEAN" -name '_jq@common' | wc -l | tr -d ' ')" "1"
check "依赖记录也换了" \
    "$([[ -f "$CLEAN/deps/depsinfo/zlib/_zlib@1.3.macos-arm64" ]] && echo yes || echo no)" "yes"
check "旧目录已经清掉" \
    "$(find "$CLEAN" -maxdepth 2 -name 'pkginfo_*' -o -maxdepth 2 -name 'depsinfo_*' | wc -l | tr -d ' ')" "0"
check "记录内容逐字节保留" \
    "$(grep -c 'jq-macos-arm64' "$CLEAN/pkg/pkginfo/jq/_jq@1.8.2.macos-arm64" 2>/dev/null)" "1"

echo
echo "========== 4. 产物改名只出计划 =========="

build_fake "$WORK/plan"
rm -rf "$WORK/plan/pkg/pkginfo_arm64/yq" "$WORK/plan/pkg/pkginfo_amd64/yq"
"$PYTHON" "$MIGRATE" --infosource "$WORK/plan" --emit-gh-script "$WORK/rename.sh" > /dev/null 2>&1
check "生成了改名脚本" "$([[ -s "$WORK/rename.sh" ]] && echo yes || echo no)" "yes"
check "脚本不碰数据仓库（只调 gh）" \
    "$(grep -c 'gh release upload' "$WORK/rename.sh")" "3"
check "旧名字只有架构，新名字带 os-arch" \
    "$(grep -o 'jq@1\.8\.2\.[a-z0-9-]*' "$WORK/rename.sh" | sort -u | tr '\n' ' ')" \
    "jq@1.8.2.amd64 jq@1.8.2.arm64 jq@1.8.2.macos-amd64 jq@1.8.2.macos-arm64 "
check "默认不删旧资产" \
    "$(grep -c 'delete-asset' "$WORK/rename.sh")" "0"

echo
echo "========== 5. 已经搬过的仓库是幂等的 =========="

OUT="$("$PYTHON" "$MIGRATE" --infosource "$CLEAN" 2>&1)"; RC=$?
check "第二次跑退出码 0" "$RC" "0"
[[ "$OUT" == *"already in the 1.0 layout"* ]] \
    && pass "报告「已经是新布局」" || fail "没识别出已经搬过：$OUT"

echo ""
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo -e "🌊 Failed: ${RED_BOLD}$FAILED${RESET}"
echo "=========================================="
[[ $FAILED -eq 0 ]] || exit 1
