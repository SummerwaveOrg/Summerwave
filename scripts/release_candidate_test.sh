#!/bin/bash

# release_candidate_test.sh
# 「该装哪一版」现在从 GitHub 发布里读，不再是 Selfupdate 仓库的 latest.toml。
# 这条测试用假 JSON 覆盖那条判断链，全程离线。
#
# 为什么值得单独一条：这一步选错版本不会报错，只会安静地装错 ——
# 装上一个更旧的版本、或者把预发布塞给正式渠道的用户。

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
import sys, importlib.util, json, pathlib

repo = pathlib.Path(sys.argv[1])
# 与客户端一致：lib / config / net 都要在路径上（selfupdate 会 import domains）
sys.path.insert(0, str(repo / "lib"))
sys.path.insert(0, str(repo / "config"))
sys.path.insert(0, str(repo / "net"))

spec = importlib.util.spec_from_file_location("selfupdate", repo / "lib/selfupdate.py")
su = importlib.util.module_from_spec(spec)
spec.loader.exec_module(su)

RELEASES = [
    {"tag_name": "v2026.11.26-15:52:43@2026-11-26T15:52Z", "prerelease": False, "draft": False},
    {"tag_name": "v2026.11.20-10:00:00@2026-11-20T10:00Z", "prerelease": False, "draft": False},
    {"tag_name": "v2026.11.27-09:00:00-rc.1@2026-11-27T09:00Z", "prerelease": True, "draft": False},
    {"tag_name": "v2026.11.28-00:00:00@2026-11-28T00:00Z", "prerelease": False, "draft": True},
]

def with_payload(payload):
    su.fetch_text = lambda url, budget, raws=(): json.dumps(payload)
    return su

# 正式渠道：读 /releases/latest（单对象）。最新的 draft 不算 —— 接口不会返回，这里再兜一层。
data, url = with_payload(RELEASES[0]).release_candidate("stable", {}, ())
print("stable:", data["version"], "|", data["build_number"], "|", data["prerelease"], "|", url)

# 预览渠道：读列表，取最新的预发布
data, _ = with_payload(RELEASES).release_candidate("preview", {}, ())
print("preview:", data["version"], "|", data["prerelease"])

# 正式渠道给了列表（真实场景里 /latest 只回一个对象），也要正确忽略预发布与 draft
data, _ = with_payload(RELEASES).release_candidate("stable", {}, ())
print("stable_from_list:", data["version"], "|", data["prerelease"])

# 一个发布都没有
su.fetch_text = lambda url, budget, raws=(): json.dumps([])
data, _ = su.release_candidate("preview", {}, ())
print("empty:", data)

# 拿不到（网络错误返回 None）
su.fetch_text = lambda url, budget, raws=(): None
data, url = su.release_candidate("stable", {}, ())
print("unreachable:", data, "|", url)
PYEOF
)"

g() { printf '%s\n' "$OUT" | grep -F "$1: " | head -1 | cut -d' ' -f2-; }

check "正式渠道取最新发布" "$(g stable)" "2026.11.26-15:52:43 | 2026-11-26T15:52Z | False | $(printf 'https://api.github.com/repos/SummerwaveOrg/Summerwave/releases/latest')"
check "预览渠道取最新预发布" "$(g preview)" "2026.11.27-09:00:00 | True"
check "列表里也只会挑正式版" "$(g stable_from_list)" "2026.11.26-15:52:43 | False"
check "没有发布时返回空" "$(g empty)" "None"
check "连不上时如实报告" "$(g unreachable)" "None | https://api.github.com/repos/SummerwaveOrg/Summerwave/releases/latest"

echo ""
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo -e "🌊 Failed: ${RED_BOLD}$FAILED${RESET}"
echo "=========================================="
[[ $FAILED -eq 0 ]] || exit 1
