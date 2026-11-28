#!/bin/bash

# taginfo_test.sh
# 发布 tag 协议的离线回归：`v1.2.3[@2026-11-26T1123Z]`，预览版带 `-rc.N` / `-beta.N`。
#
# 为什么值得单独一条：0.1.0 起 Selfupdate 仓库没有了，「该装哪一版」完全由 tag 决定。
# 解析错了不会报错，只会挑错版本 —— 这种错误装到用户机器上才发现。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON="${MACWAVE_PYTHON:-python3}"

FAILED=0; PASSED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1（期望 $3，实际 $2）"; fi; }

OUT="$("$PYTHON" - "$REPO_DIR" <<'PYEOF'
import sys, importlib.util
repo = sys.argv[1]
spec = importlib.util.spec_from_file_location("taginfo", f"{repo}/lib/taginfo.py")
taginfo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(taginfo)

def show(tag):
    info = taginfo.parse(tag)
    return f"{info.version}|{info.channel or 'stable'}|{info.channel_seq}|{info.stamp or '-'}"

print("plain:", show("v1.2.3"))
print("stamped:", show("v1.2.3@2026-11-26T1123Z"))
print("rc:", show("v1.2.3-rc.1@2026-11-26T1123Z"))
print("beta:", show("v1.2.3-beta.2@2026-11-26T1123Z"))
print("special:", show("v2.1.5-procursus@2026-01-02T0304Z"))
print("stamp_version:", show("v2026.11.26-15:52:43@2026-11-26T1552Z"))
print("stamp_rc:", show("v2026.11.26-15:52:43-rc.1@2026-11-26T1552Z"))
print("roundtrip:", taginfo.format_tag("1.2.3", "2026-11-26T1123Z", "rc", 1))

tags = ["v1.0.0@2026-11-01T0000Z", "v1.2.3@2026-11-26T1123Z", "v1.3.0-rc.1@2026-11-27T0900Z"]
print("latest_stable:", taginfo.pick_latest(tags)[0])
print("latest_any:", taginfo.pick_latest(tags, include_prerelease=True)[0])
print("latest_rc_only:", taginfo.pick_latest(["v1.3.0-rc.1@2026-11-27T0900Z"])[0])

# 同一版本号重发：时刻新的赢
print("republish:", taginfo.pick_latest(["v1.2.3@2026-11-20T0000Z", "v1.2.3@2026-11-26T1123Z"])[0])

# 不认识的一律抛错，不做猜测
for bad in ["1.2.3", "v", "v1.2.3@2026-11-26", "v1.2.3@2026-11-26T11:23+08:00", "v1.2.3-dev.1"]:
    try:
        taginfo.parse(bad)
        print(f"reject[{bad}]: accepted")
    except ValueError:
        print(f"reject[{bad}]: rejected")
PYEOF
)"

# 键里带 [ ] . @ 时不能进 sed 的正则，用固定串匹配再切掉前缀
g() { printf '%s\n' "$OUT" | grep -F "$1: " | head -1 | cut -d' ' -f2-; }

check "纯版本号" "$(g plain)" "1.2.3|stable|0|-"
check "带构建时刻" "$(g stamped)" "1.2.3|stable|0|2026-11-26T1123Z"
check "rc 渠道" "$(g rc)" "1.2.3|rc|1|2026-11-26T1123Z"
check "beta 渠道" "$(g beta)" "1.2.3|beta|2|2026-11-26T1123Z"
check "特殊版本仍可解析" "$(g special)" "2.1.5-procursus|stable|0|2026-01-02T0304Z"
check "时间戳版本号（0.1.0 的真实形状）" "$(g stamp_version)" "2026.11.26-15:52:43|stable|0|2026-11-26T1552Z"
check "时间戳版本号 + rc" "$(g stamp_rc)" "2026.11.26-15:52:43|rc|1|2026-11-26T1552Z"
check "往返一致" "$(g roundtrip)" "v1.2.3-rc.1@2026-11-26T1123Z"
check "latest 只认正式版" "$(g latest_stable)" "v1.2.3@2026-11-26T1123Z"
check "显式要预览时预览赢" "$(g latest_any)" "v1.3.0-rc.1@2026-11-27T0900Z"
check "只有预览版时退回预览" "$(g latest_rc_only)" "v1.3.0-rc.1@2026-11-27T0900Z"
check "同版本重发取新时刻" "$(g republish)" "v1.2.3@2026-11-26T1123Z"
check "拒绝没有 v 前缀" "$(g 'reject[1.2.3]')" "rejected"
check "拒绝只有 v" "$(g 'reject[v]')" "rejected"
check "拒绝缺 Z 的时刻" "$(g 'reject[v1.2.3@2026-11-26]')" "rejected"
check "拒绝非 UTC 时区" "$(g 'reject[v1.2.3@2026-11-26T11:23+08:00]')" "rejected"
check "拒绝未知渠道" "$(g 'reject[v1.2.3-dev.1]')" "rejected"

echo ""

# -------------------- 产出的 tag 必须能被 git 接受 --------------------
#
# 这条是防回归的：协议原本写成 ISO 8601 的 `T11:23Z`，漂亮但**含冒号**，
# `git tag` 直接拒绝 —— 于是 tag 打不出来，客户端也就无从寻址。改过一次之后
# 用 git 本身来把关，比肉眼检查正则可靠。
TAG_SAMPLE=$("$PYTHON" - "$REPO_DIR" <<'PYEOF2'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("taginfo", f"{sys.argv[1]}/lib/taginfo.py")
taginfo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(taginfo)
print(taginfo.format_tag("0.1.0", "2026-11-28T1554Z", "rc", 1))
PYEOF2
)
GIT_TMP=$(mktemp -d)
if git -C "$GIT_TMP" init -q 2>/dev/null \
   && git -C "$GIT_TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x 2>/dev/null \
   && git -C "$GIT_TMP" tag "$TAG_SAMPLE" 2>/dev/null; then
    pass "产出的 tag 能被 git 接受（$TAG_SAMPLE）"
else
    fail "产出的 tag 被 git 拒绝：$TAG_SAMPLE —— 是不是又用了 ref 非法字符（冒号 / 空格 / ~ ^ : ? * [ \\）"
fi
rm -rf "$GIT_TMP"


echo "=========================================="
echo "🌊 Passed: $PASSED"
echo -e "🌊 Failed: ${RED_BOLD}$FAILED${RESET}"
echo "=========================================="
[[ $FAILED -eq 0 ]] || exit 1
