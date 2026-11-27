#!/bin/bash

# build_installer_test.sh
# `scripts/build_installer.py` 的离线回归 —— 发布用的 install.sh 是怎么生成的。
#
# 为什么值得单独一条：生成物是**用户真正执行的那个文件**。它写错了不会在 CI 里报错，
# 只会在别人机器上炸：清单少一行 = 装完缺文件（wave 起不来）；多一行 = 取不到的路径；
# heredoc 写坏 = 脚本连语法都过不了。
#
# 这里钉住：
#   1. 生成物语法正确（bash -n），清单每条都是 `<路径> <0|1> <64 位哈希>`
#   2. 清单条目数与 4.7 那套 files.txt 完全相同（同一份「装什么」）
#   3. 三个运行时生成的文件不在清单里（lib/wave / lib/install.sh / lib/uninstall.sh）
#   4. 可执行位取自 git mode，不再靠 `.sh` 后缀猜
#   5. 版本号不合规、或拿生成物当模板再生成 → 直接失败
#
# 全程离线：只用本地 git 仓库，不联网。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$SCRIPT_DIR/build_installer.py"
LEGACY="$SCRIPT_DIR/build_update_commands.py"
PYTHON="${MACWAVE_PYTHON:-python3}"

FAILED=0
PASSED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1（期望 $3，实际 $2）"; fi; }

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/install.sh"
VERSION="9.9.9@2026-11-27T09:00Z"

echo "========== 1. 生成 + 语法 =========="

gen() { "$PYTHON" "$BUILD" --version "$1" --ref HEAD --out "$2" 2>&1; }
OUTPUT="$(gen "$VERSION" "$OUT")"; RC=$?
check "退出码 0" "$RC" "0"
check "文件已生成" "$([[ -f "$OUT" ]] && echo present || echo gone)" "present"
bash -n "$OUT" 2>/dev/null && pass "bash -n 通过（heredoc 没写坏）" || fail "bash -n 失败"
check "shebang 与模板一致" \
    "$(head -1 "$OUT")" "$(head -1 "$REPO_DIR/lib/install.sh")"
sed -n '2p' "$OUT" | grep -qE '^# =+$' \
    && pass "清单块紧跟在 shebang 之后" || fail "第 2 行不是清单块起始横线：$(sed -n '2p' "$OUT")"
check "有信号变量" "$(grep -c '^MACWAVE_MANIFEST_VERSION=1$' "$OUT")" "1"
check "版本写进脚本" "$(grep -c "^MACWAVE_VERSION=\"$VERSION\"\$" "$OUT")" "1"
check "heredoc 收尾只有一行" "$(grep -c '^MANIFEST_EOF$' "$OUT")" "1"

echo
echo "========== 2. 清单内容 =========="

# 清单 = 两个 MANIFEST_EOF 之间那一段
sed -n "/<<'MANIFEST_EOF'/,/^MANIFEST_EOF$/p" "$OUT" | sed '1d;$d' > "$WORK/manifest.txt"
LINES="$(wc -l < "$WORK/manifest.txt" | tr -d ' ')"
check "每条都是 <路径> <0|1> <sha256>" \
    "$(grep -cvE '^[^ ]+ [01] [0-9a-f]{64}$' "$WORK/manifest.txt")" "0"

# 与 4.7 那套 files.txt 对齐：同一份「装什么」不能因为换了生成器而变
"$PYTHON" "$LEGACY" --version 9.9.9 --ref HEAD --out "$WORK/legacy/update_commands.sh" \
    >/dev/null 2>&1
check "条目数与 files.txt 相同" "$LINES" "$(wc -l < "$WORK/legacy/files.txt" | tr -d ' ')"
check "路径集合与 files.txt 相同" \
    "$(cut -d' ' -f1 "$WORK/manifest.txt" | sort | md5)" \
    "$(cut -d' ' -f1 "$WORK/legacy/files.txt" | sort | md5)"

for skipped in lib/wave lib/install.sh lib/uninstall.sh; do
    check "$skipped 不在清单里" "$(grep -c "^$skipped " "$WORK/manifest.txt")" "0"
done

echo
echo "========== 3. 可执行位来自 git mode，不靠后缀 =========="

# 这几个 .sh 在仓库里是 100644（由 Python 用 bash 调用），后缀法会把它们标成 1
check "pkg/pkgunzip.sh 标成 0（git 里不是 755）" \
    "$(awk '$1=="pkg/pkgunzip.sh"{print $2}' "$WORK/manifest.txt")" "0"
check "surfboard/tagger.sh 标成 0" \
    "$(awk '$1=="surfboard/tagger.sh"{print $2}' "$WORK/manifest.txt")" "0"

echo
echo "========== 4. 拒绝坏输入 =========="

"$PYTHON" "$BUILD" --version "not a version" --ref HEAD --out "$WORK/bad.sh" >/dev/null 2>&1
check "版本号不合规 → 退出码 1" "$?" "1"
"$PYTHON" "$BUILD" --version "1.2.3-dev.1" --ref HEAD --out "$WORK/bad2.sh" >/dev/null 2>&1
check "未知渠道（1.2.3-dev.1）→ 退出码 1" "$?" "1"
"$PYTHON" "$BUILD" --version "$VERSION" --ref "refs/tags/does-not-exist" \
    --out "$WORK/bad3.sh" >/dev/null 2>&1
check "ref 不存在 → 非 0" "$([[ $? -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
"$PYTHON" "$BUILD" --version "$VERSION" --ref HEAD --template "$OUT" \
    --out "$WORK/bad4.sh" >/dev/null 2>&1
check "拿生成物当模板 → 拒绝（不许叠两层清单）" "$?" "1"

echo ""
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo -e "🌊 Failed: ${RED_BOLD}$FAILED${RESET}"
echo "=========================================="
[[ $FAILED -eq 0 ]] || exit 1
