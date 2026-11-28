#!/bin/bash

# verify-on-target.sh
# 在一台干净的机器上把 Summerwave 装一遍，并把该验的都验一遍。
#
#   sudo /bin/bash /Volumes/SUMMERWAVE/Summerwave-0.1.0/verify-on-target.sh
#
# 它做四件事，每一步都单独记 PASS/FAIL，不会因为前一步失败就整体中断：
#   1. 记录基线（系统版本、架构、有没有系统 python3）
#   2. 清掉 /opt/macwave 里的旧东西（安装器故意不 prune，得先清）
#   3. 跑安装器
#   4. 验证：自带解释器、命令行入口、索引可达性、装两个包（一个该成、一个该拦）
#
# 默认会删 /opt/macwave。想留着就先看一遍：SUMMERWAVE_KEEP_OLD=1 sudo -E /bin/bash ...

set -uo pipefail

RED='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

pass() { echo -e "${GREEN}  ✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}  ❌ $1${RESET}"; FAILED=$((FAILED + 1)); }
skip() { echo -e "${YELLOW}  ⏭  $1${RESET}"; SKIPPED=$((SKIPPED + 1)); }
step() { echo; echo "=== $1 ==="; }

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$SELF_DIR/install.sh"
BASE_DIR="/opt/macwave"

# ---- 日志：写到真实用户的家目录，别写进 /var/root ----
REAL_USER="${SUDO_USER:-$(id -un)}"
if [[ "$(id -u)" -eq 0 && "$REAL_USER" != "root" ]]; then
    LOG_DIR="$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
else
    LOG_DIR="$HOME"
fi
[[ -d "${LOG_DIR:-}" ]] || LOG_DIR="/tmp"
LOG="$LOG_DIR/summerwave-verify-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee "$LOG") 2>&1

echo "🌊 Summerwave 目标机验证"
echo "🌊 日志：$LOG"

# ==========================================
step "0. 前置条件"
# ==========================================
if [[ "$(id -u)" -ne 0 ]]; then
    fail "需要 root：请用 sudo 运行"
    echo "🌊   sudo /bin/bash $0"
    exit 1
fi
pass "以 root 运行"

if [[ -f "$INSTALLER" ]]; then
    pass "安装器在 $INSTALLER"
else
    fail "同目录下没有 install.sh（$SELF_DIR）"
    exit 1
fi

# ==========================================
step "1. 基线"
# ==========================================
OS_VERSION="$(sw_vers -productVersion 2>/dev/null)"
ARCH="$(uname -m)"
echo "🌊 macOS $OS_VERSION / $ARCH"

# PATH 上的 python3 来自哪里，会影响「自带解释器到底有没有生效」的判断：
# Intel Mac 上 Homebrew 装在 /usr/local，所以 /usr/local/bin/python3 多半是它。
if command -v python3 > /dev/null 2>&1; then
    PY_PREFIX="$(python3 -c 'import sys; print(sys.base_prefix)' 2>/dev/null)"
    echo "🌊 PATH 上的 python3：$(command -v python3) ($(python3 -V 2>&1))"
    case "$PY_PREFIX" in
        */Cellar/*|/opt/homebrew/*) echo "🌊 来源：Homebrew（$PY_PREFIX）" ;;
        /Library/Frameworks/*)      echo "🌊 来源：python.org 安装包（$PY_PREFIX）" ;;
        /Applications/Xcode*|/Library/Developer/*) echo "🌊 来源：Xcode 命令行工具（$PY_PREFIX）" ;;
        *) echo "🌊 来源：$PY_PREFIX" ;;
    esac
else
    echo "🌊 PATH 上的 python3：没有（正好检验自带解释器）"
fi

# ==========================================
step "2. 旧安装"
# ==========================================
if [[ -d "$BASE_DIR" ]]; then
    if [[ "${SUMMERWAVE_KEEP_OLD:-}" == "1" ]]; then
        skip "保留了 $BASE_DIR（SUMMERWAVE_KEEP_OLD=1）"
    else
        echo "🌊 清掉 $BASE_DIR 里的旧内容："
        ls -1 "$BASE_DIR" 2>/dev/null | head -10 | sed 's/^/     /'
        if rm -rf "$BASE_DIR"; then
            pass "已清空 $BASE_DIR"
        else
            fail "清不掉 $BASE_DIR"
            exit 1
        fi
    fi
else
    pass "$BASE_DIR 本来就是空的"
fi

# ==========================================
step "3. 安装"
# ==========================================
if /bin/bash "$INSTALLER" --ci; then
    pass "安装器正常结束"
else
    fail "安装器失败了（看上面的输出）"
    echo
    echo "🌊 到此为止：装不上就没有可验的东西。"
    echo "🌊 若是取件 404，检查 install.sh 里的 MACWAVE_CORE_REF 是否真的推到了远端。"
    exit 1
fi

# ==========================================
step "4. 自带解释器"
# ==========================================
PY="$BASE_DIR/python/current/bin/python3"
if [[ -x "$PY" ]]; then
    PY_VERSION="$("$PY" -V 2>&1)"
    echo "🌊 $PY → $PY_VERSION"
    if "$PY" -c 'import ssl, sqlite3, zlib; print("ok")' > /dev/null 2>&1; then
        pass "自带解释器能跑，且 ssl/sqlite3/zlib 都在"
    else
        fail "自带解释器起得来但缺少标准模块（ssl/sqlite3/zlib）"
    fi
else
    fail "没有 $PY —— 自带解释器没装上"
fi

# ==========================================
step "5. 命令行入口"
# ==========================================
WAVE="$BASE_DIR/bin/wave"
if [[ -x "$WAVE" ]] && WAVE_OUT="$("$WAVE" --version 2>&1)"; then
    echo "🌊 $WAVE_OUT"
    pass "wave 能跑"
else
    fail "wave 跑不起来（$WAVE）"
fi

if BASE_OUT="$("$WAVE" basedir --raw 2>&1)" && [[ "$BASE_OUT" == "$BASE_DIR" ]]; then
    pass "basedir 指向 $BASE_OUT"
else
    fail "basedir 返回了 '$BASE_OUT'"
fi

# wave 到底用了哪个解释器。启动器的顺序是 venv → 自带 → 安装时记录 → PATH，
# 所以「venv 建在谁身上」就是答案。自带 Python 在目标系统上跑不起来时，安装会
# 静默回退到 PATH 上的那个（很可能是 Homebrew），表面上看一切正常 —— 这一步就是
# 把那种假绿认出来。
if [[ -x "$BASE_DIR/venv/bin/python3" ]]; then
    VENV_BASE="$("$BASE_DIR/venv/bin/python3" -c 'import sys; print(sys.base_prefix)' 2>/dev/null)"
    VENV_VERSION="$("$BASE_DIR/venv/bin/python3" -V 2>&1)"
    echo "🌊 venv 解释器：$VENV_VERSION，base_prefix=$VENV_BASE"
    case "$VENV_BASE" in
        "$BASE_DIR"/*) pass "venv 建在自带解释器上（自带 Python 真的生效了）" ;;
        *)
            fail "venv 建在 $VENV_BASE —— 自带 Python 没生效，回退到了系统的那个"
            echo "🌊   这意味着这套安装依赖目标机上原有的 Python，换台没装过的机器就会坏。"
            ;;
    esac
else
    fail "没有 $BASE_DIR/venv/bin/python3"
fi

# ==========================================
step "6. 索引可达性"
# ==========================================
# 这一步只判断「网络通不通」，它红了不代表安装有问题 —— 装包才会用到它。
if "$WAVE" info jq > /dev/null 2>&1; then
    pass "能读到索引记录"
    INDEX_OK=yes
else
    fail "读不到索引记录（域名不通，或镜像没同步）"
    INDEX_OK=no
fi

# ==========================================
step "7. 装一个带动态库的包"
# ==========================================
if [[ "$INDEX_OK" != "yes" ]]; then
    skip "跳过后面的装包：索引读不到"
else
    if "$WAVE" install openssl@3.0.15 < /dev/null; then
        pass "openssl@3.0.15 装上了"
        if OPENSSL_OUT="$("$BASE_DIR/bin/openssl" version 2>&1)"; then
            echo "🌊 $OPENSSL_OUT"
            pass "装上之后能执行（rpath 重定位没问题）"
        else
            fail "二进制起不来：$OPENSSL_OUT"
        fi
    else
        fail "openssl@3.0.15 装不上"
    fi

    # ==========================================
    step "8. 装一个 min_os 更高的包（应该被拦住）"
    # ==========================================
    # jq 的记录写着 min_os 14.0，本机若是 12.x 就该被明确拒绝。装上去了反而要查。
    JQ_LOG="$("$WAVE" install jq@1.8.2 < /dev/null 2>&1)"
    echo "$JQ_LOG" | sed 's/^/     /'
    if echo "$JQ_LOG" | grep -q "declares macOS"; then
        pass "被正确拦下并说明了原因"
    elif echo "$JQ_LOG" | grep -qi "already installed"; then
        skip "本机系统版本足够新，jq 正常安装了（不算失败）"
    else
        fail "既没被拦、也没装成（看上面的输出）"
    fi
fi

# ==========================================
step "结果"
# ==========================================
echo "🌊 通过 $PASSED ／ 失败 $FAILED ／ 跳过 $SKIPPED"
echo "🌊 系统：macOS $OS_VERSION $ARCH"
echo "🌊 日志：$LOG"

if [[ "$FAILED" -eq 0 ]]; then
    echo -e "${GREEN}🌊 全部通过。${RESET}"
    exit 0
fi
echo -e "${RED}🌊 有 $FAILED 项没过，把这份日志发回去。${RESET}"
exit 1
