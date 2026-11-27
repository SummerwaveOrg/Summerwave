#!/bin/bash

# versions_index_test.sh
# `scripts/build_versions_index.py` 的离线回归 —— 镜像自备的 versions 清单。
#
# 为什么值得单独一条：设了 MACWAVE_API_DOMAIN 之后，客户端「列出版本 / 列出软件包」
# 全靠这两类文件（`pkginfo/versions` 与 `pkginfo/<包名>/versions`）。它们不在数据仓库里，
# 是镜像生成出来的；生成逻辑错位的表现是「包在，但一个版本都列不出来」或
# 「列出来了却下不到」—— 两种都要等用户下载阶段才炸。
#
# 这里钉住三件事：
#   1. 清单里写的是**新布局的记录名**（`_jq@1.8.2.macos-arm64`），两个架构都进同一份
#   2. 镜像里没有产物的记录**不进清单**（宁可说「没有这个版本」，也不给一个下不到的）
#   3. 重复跑是幂等的；镜像清空后清单也跟着清空（不能留着上一次的结果）
#
# 全程离线：造一棵假的 infosource 与假的镜像目录，不联网。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$SCRIPT_DIR/build_versions_index.py"

FAILED=0
PASSED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1（期望 $3，实际 $2）"; fi; }

if [[ ! -f "$BUILD" ]]; then
    echo -e "${RED_BOLD}🌊 Error: build_versions_index.py not found${RESET}"
    exit 1
fi

PYTHON="${MACWAVE_PYTHON:-python3}"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

INFO="$WORK/infosource"
MIRROR="$WORK/mirror"
mkdir -p "$INFO/jq" "$INFO/yq" \
         "$MIRROR/bottle/jq" "$MIRROR/bottle/yq" "$MIRROR/deps"

# 记录：名字带瓶子标签，`file:` 决定扩展名（产物名就是按它算的）
record() {   # $1=路径 $2=sha $3=file
    cat > "$1" <<EOF
sha256: "$2"
file: "$3"
url: "https://example.invalid/$3"
EOF
}

SHA="$(printf 'a%.0s' {1..64})"
printf 'bin_name: "jq"\n' > "$INFO/jq/_jq@common"
record "$INFO/jq/_jq@1.8.2.macos-arm64" "$SHA" "jq-macos-arm64"
record "$INFO/jq/_jq@1.8.2.macos-amd64" "$SHA" "jq-macos-amd64"
# yq 有记录但镜像里没有产物 —— 必须被排除
record "$INFO/yq/_yq@4.45.1.macos-arm64" "$SHA" "yq.tar.gz"

# 镜像里只放 jq 两份（按新命名规则：<名>@<版本>.<os>-<arch><扩展名>）
: > "$MIRROR/bottle/jq/jq@1.8.2.macos-arm64"
: > "$MIRROR/bottle/jq/jq@1.8.2.macos-amd64"
rm -rf "$INFO/yq"

echo "========== 1. 清单按新布局生成 =========="

OUT="$("$PYTHON" "$BUILD" --infosource "$INFO" --mirror "$MIRROR" 2>&1)"; RC=$?
check "退出码 0" "$RC" "0"
check "包名清单写成 jq" "$(cat "$INFO/versions")" "jq"
# 清单里写的是「记录名去掉前导下划线」（与线上镜像一致，客户端 split("@") 后只用版本段）
check "两个架构都进同一份版本清单" \
    "$(tr '\n' ' ' < "$INFO/jq/versions")" \
    "jq@1.8.2.macos-amd64 jq@1.8.2.macos-arm64 "

echo
echo "========== 1b. 根目录的 INDEX.md（给人看的） =========="

check "INDEX.md 生成在索引根" \
    "$([[ -f "$INFO/INDEX.md" ]] && echo present || echo gone)" "present"
check "表里有 jq 这一行（两架构同版本 → 版本数 1）" \
    "$(grep -c '^| `jq` | 1 | `1.8.2` |$' "$INFO/INDEX.md")" "1"
check "按首字母分组出了 J 这一节" \
    "$(grep -c '^## J$' "$INFO/INDEX.md")" "1"
check "标题写明共 1 个名字、2 条记录" \
    "$(grep -c '共 1 个名字、2 条记录' "$INFO/INDEX.md")" "1"

echo
echo "========== 2. 镜像里没有产物的记录不进清单 =========="

# 再塞一条 yq 记录，但镜像里没有它的产物
mkdir -p "$INFO/yq"
record "$INFO/yq/_yq@4.45.1.macos-arm64" "$SHA" "yq.tar.gz"
"$PYTHON" "$BUILD" --infosource "$INFO" --mirror "$MIRROR" > "$WORK/out2.log" 2>&1
check "只有产物的包才进清单" "$(cat "$INFO/versions")" "jq"
check "缺产物时给出了说明" \
    "$(grep -c '未列入' "$WORK/out2.log")" "1"
[[ "$(cat "$WORK/out2.log")" == *"yq"* ]] \
    && pass "点出了是哪个包缺产物" || fail "没说清缺的是哪个包：$(cat "$WORK/out2.log")"
check "缺产物的包也不进 INDEX.md" \
    "$(grep -c '`yq`' "$INFO/INDEX.md")" "0"

echo
echo "========== 3. 幂等 =========="

FIRST="$(cat "$INFO/versions"; cat "$INFO/jq/versions"; cat "$INFO/INDEX.md")"
"$PYTHON" "$BUILD" --infosource "$INFO" --mirror "$MIRROR" > /dev/null 2>&1
SECOND="$(cat "$INFO/versions"; cat "$INFO/jq/versions"; cat "$INFO/INDEX.md")"
check "重复跑结果不变" "$SECOND" "$FIRST"

echo
echo "========== 4. 镜像清空后清单也清空 =========="

rm -rf "$MIRROR/bottle/jq"
OUT="$("$PYTHON" "$BUILD" --infosource "$INFO" --mirror "$MIRROR" 2>&1)"; RC=$?
check "空镜像退出码非 0（当作没准备好）" "$([[ $RC -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "旧的包名清单已删掉（不留下一个下不到的包）" \
    "$([[ -f "$INFO/versions" ]] && echo present || echo gone)" "gone"
check "旧的版本清单也删掉了" \
    "$([[ -f "$INFO/jq/versions" ]] && echo present || echo gone)" "gone"
check "INDEX.md 也跟着删掉（不留下一个指向空索引的总览）" \
    "$([[ -f "$INFO/INDEX.md" ]] && echo present || echo gone)" "gone"

echo
echo "========== 5. 参数校验 =========="

"$PYTHON" "$BUILD" --infosource "$WORK/nope" --mirror "$MIRROR" > /dev/null 2>&1
check "不是 infosource 仓库时退出码 1" "$?" "1"
"$PYTHON" "$BUILD" --infosource "$INFO" --mirror "$WORK/nope" > /dev/null 2>&1
check "不是镜像根时退出码 1" "$?" "1"

echo ""
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo -e "🌊 Failed: ${RED_BOLD}$FAILED${RESET}"
echo "=========================================="
[[ $FAILED -eq 0 ]] || exit 1
