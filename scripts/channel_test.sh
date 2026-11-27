#!/bin/bash

# channel_test.sh
# 两条流的隔离：装的是 preview 就只读 prerelease/latest.toml，正式版永远看不到
# 预发布探针；preview 流没有更新的版本时，正式版更新则以**全量**方式切过去。
#
# 为什么值得一条测试：这条逻辑只在「跟 preview 流的人」身上跑，而那是少数人。坏了的表现
# 两头都不好看 —— 要么正式版用户被 RC 卷进来（渠道串了），要么 RC 用户永远停在
# 那一版（构建号没参与比较）。两种都只会在发版之后才被发现。
#
# 全程离线：起一个本地 http.server 当镜像，用 --dry-run 只读地跑一遍。
# 最后一条断言要的是「正式版客户端不请求 prerelease」，这条只能从服务器日志里看出来。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"

PASSED=0
FAILED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
cleanup() {
    [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

SITE="$WORK/srv"
HOME_DIR="$WORK/home"
# 安装根写死成 /opt/macwave：MACWAVE_TEST 把它映射进测试根，组件也拷进那棵树。
TEST_ROOT="$WORK/root"
TREE="$TEST_ROOT/opt/macwave"
mkdir -p "$SITE/prerelease" "$SITE/macwavedata" "$HOME_DIR" "$TREE/var"
copy_components "$TREE"
printf "MACWAVE_VERSION='2026.11.26-15:52:43'\nMACWAVE_CHANNEL='preview'\n" > "$TREE/var/config.sh"

USER_SITE=$(python3 -c 'import site; print(site.getusersitepackages())' 2>/dev/null)
PYTHONPATH="$(component_paths)"
export PYTHONPATH
[[ -d "$USER_SITE" ]] && export PYTHONPATH="$PYTHONPATH:$USER_SITE"

PORT=$(python3 - <<'PY'
import socket

s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
( cd "$SITE" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 > "$WORK/http.log" 2>&1 ) &
HTTP_PID=$!
for _ in $(seq 1 40); do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/macwavedata/latest.toml" && break
    sleep 0.1
done

# 探针内容：四个参数分别是预发布版本/构建号、正式版版本/构建号
probe() {
    printf 'channel = "preview"\nversion = "%s"\nbuild_number = "%s"\nbranch = "preview"\n' "$1" "$2" \
        > "$SITE/prerelease/latest.toml"
    printf 'channel = "stable"\nversion = "%s"\nbuild_number = "%s"\nbranch = "main"\n' "$3" "$4" \
        > "$SITE/macwavedata/latest.toml"
}

# 本机装的是什么（渠道要一起写：版本号是发布时刻，推不出渠道）
installed() {
    printf "MACWAVE_VERSION='%s'\nMACWAVE_BUILD='%s'\nMACWAVE_CHANNEL='%s'\n" "$1" "$2" "${3:-preview}" \
        > "$TREE/var/config.sh"
}

wave() {
    env -u SUMMERWAVE_API_DOMAIN -u SUMMERWAVE_BOTTLE_DOMAIN -u SUMMERWAVE_DEPS_DOMAIN \
        -u SUMMERWAVE_CORE_DOMAIN -u SUMMERWAVE_PYTHON_DOMAIN \
        HOME="$HOME_DIR" \
        MACWAVE_TEST="$TEST_ROOT" \
        SUMMERWAVE_SELFUPDATE_DOMAIN="http://127.0.0.1:$PORT" \
        python3 "$TREE/lib/wave.py" selfupdate --dry-run 2>&1
}

echo "========== 1. preview 客户端只读预发布探针 =========="

installed "2026.11.26-10:00:00" "323R1200"
probe "2026.11.26-15:52:43" "323R1300" "2026.11.25-09:00:00" "324D0900"
OUT=$(wave)
if grep -q "Channel: preview" <<< "$OUT" && grep -q "2026.11.26-15:52:43" <<< "$OUT"; then
    pass "preview 客户端读到预发布探针里更新的版本"
else
    fail "preview 客户端没有读到预发布探针的新版本：$OUT"
fi
if grep -q "branch *preview" <<< "$OUT"; then
    pass "用的是预发布探针里的分支"
else
    fail "分支不是预发布探针里的那条：$OUT"
fi

echo "========== 2. 构建号相同 = 已是最新 =========="

probe "2026.11.26-10:00:00" "323R1200" "2026.11.25-09:00:00" "320D0900"
OUT=$(wave)
if grep -q "already up to date" <<< "$OUT"; then
    pass "同一个版本、同一个构建号 → 已是最新（不会被反复重装）"
else
    fail "同构建号时不该更新：$OUT"
fi

echo "========== 3. preview 收尾：全量切到正式版 =========="

installed "2026.11.26-10:00:00" "323R1200"
probe "2026.11.26-09:00:00" "323R1100" "2026.11.27-08:00:00" "324D0900"
OUT=$(wave)
if grep -q "preview channel has no newer build" <<< "$OUT" && grep -q "full install" <<< "$OUT"; then
    pass "preview 没有更新版本、正式版更新 → 提示走全量切换"
else
    fail "preview 收尾时没有走全量切换：$OUT"
fi

echo "========== 4. 正式版客户端永远不碰预发布探针 =========="

installed "2026.11.25-09:00:00" "320D0900" stable
probe "2026.12.31-23:59:59" "330R1200" "2026.11.25-09:00:00" "320D0900"
: > "$WORK/http.log"
OUT=$(wave)
if grep -q "already up to date" <<< "$OUT"; then
    pass "正式版客户端不受更新的 RC 影响"
else
    fail "正式版客户端被 RC 探针影响了：$OUT"
fi
if grep -q "prerelease" "$WORK/http.log"; then
    fail "正式版客户端请求了 prerelease（渠道隔离失效）：$(grep prerelease "$WORK/http.log" | head -2)"
else
    pass "正式版客户端一次都没有请求 prerelease"
fi

echo "========== 5. 没有预发布探针时不炸 =========="

installed "2026.11.26-10:00:00" "323R1200"
rm -f "$SITE/prerelease/latest.toml"
printf 'version = "2026.11.27-08:00:00"\nbuild_number = "324D0900"\nbranch = "main"\n' \
    > "$SITE/macwavedata/latest.toml"
OUT=$(wave)
if grep -q "full install" <<< "$OUT" && grep -q "2026.11.27-08:00:00" <<< "$OUT"; then
    pass "预发布探针 404 时退到正式版，并仍按全量切换"
else
    fail "预发布探针缺失时行为不对：$OUT"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 Channel isolation is intact${RESET}"
