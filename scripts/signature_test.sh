#!/bin/bash

# signature_test.sh
# GPG 验签的约定：公钥放在哪、怎么验、验不过怎么办。
#
# 为什么值得一条测试：验签决定「装不装得下去」，是一票否决的闸门。
# 等它真被接上那天，坏掉的表现会是「所有人安装都失败」或者更糟 —— 「签名不匹配」
# 被当成「没签名」放过去。所以这里的断言写的是语义，不是实现细节：
#
#   好签名 → ok；数据被改 → bad-signature；没签名对 → no-signature；
#   Keys/ 空 → no-keys；没有 gpg → no-gpg（不是失败）。
#
# 用一次性密钥对（临时 GNUPGHOME），不碰本机钥匙环，也不碰仓库里的 Keys/。

# 语言：install.sh 会按 locale / 系统首选语言自动切中文，断言因此会随开发者的
# 系统语言漂（中文 Mac 上所有英文断言一起红）。这里钉成英文 + 清掉外层的覆盖，
# 专测语言的那几段自己显式给 LANG。
unset MACWAVE_LANG LC_ALL LC_MESSAGES
export LANG=en_US.UTF-8

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"

PASSED=0
FAILED=0
SKIPPED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }
skip() { echo -e "  ${YELLOW}⏭  $1${RESET}"; SKIPPED=$((SKIPPED + 1)); }
YELLOW='\033[33m'

echo "========== 1. 公钥放在哪：仓库 Keys/ 与安装树 <base_dir>/Keys/ =========="

if [[ -d "$REPO_DIR/Keys" ]]; then
    pass "仓库里有 Keys/"
else
    fail "仓库里没有 Keys/"
fi

if grep -qx "Keys" <(sed -e 's/#.*//' "$REPO_DIR/scripts/assets.txt" | tr -d ' ');
then
    pass "Keys/ 列在 scripts/assets.txt 里（随安装清单下发）"
else
    fail "Keys/ 不在 scripts/assets.txt 里，装上之后就没有公钥可验"
fi

# 只有公钥该在这里：私钥（BEGIN PGP PRIVATE KEY BLOCK）出现在仓库里就是事故
if grep -rl "BEGIN PGP PRIVATE KEY" "$REPO_DIR/Keys" 2>/dev/null | grep -q .; then
    fail "Keys/ 里有私钥（BEGIN PGP PRIVATE KEY）—— 私钥不进仓库"
else
    pass "Keys/ 里没有私钥"
fi

# 目录里只该有公钥与说明；散落的其它文件会被当成「公钥」去 import
# 说明文件叫 README.md 还是 description.md 都算「说明」（2026-11-19 从前者改名成后者，
# 下个版本才随发布线铺开，所以两个名字都要认）。
STRAY=$(find "$REPO_DIR/Keys" -type f ! -name '*.asc' ! -name '*.gpg' ! -name '*.pub' \
        ! -name '*.pem' ! -name 'README.md' ! -name 'description.md' 2>/dev/null)
if [[ -z "$STRAY" ]]; then
    pass "Keys/ 里只有公钥（*.asc / *.gpg / *.pub / *.pem）与说明文件"
else
    fail "Keys/ 里有不认的文件：$STRAY"
fi

echo "========== 2. 安装器会准备 <base_dir>/Keys =========="

if grep -q 'KEYS_DIR="\$BASE_DIR/Keys"' "$REPO_DIR/lib/install.sh"; then
    pass "install.sh 定义了 KEYS_DIR=\$BASE_DIR/Keys"
else
    fail "install.sh 没有定义 KEYS_DIR=\$BASE_DIR/Keys"
fi
if grep -q 'mkdir -p "\$KEYS_DIR"' "$REPO_DIR/lib/install.sh"; then
    pass "install.sh 会建这个目录"
else
    fail "install.sh 没有建 Keys 目录"
fi
# 资源目录不该进 sys.path：Keys 里没有 .py，进了只会让 import 去翻它
if grep -q 'BASE_DIR / "Keys"' "$REPO_DIR/lib/wave.py"; then
    fail "lib/wave.py 把 Keys 加进了 sys.path（它是资源目录）"
else
    pass "lib/wave.py 没有把 Keys 当成组件"
fi

echo "========== 3. 验签语义（一次性密钥对，测 lib/selfupdate.py 的 _verify）=========="
#
# 验签在 0.1.0 挪到了 Python：自更新是「取目标 tag 的 install.sh 与它的 .sig、
# 验签、执行」（lib/selfupdate.py 的 run_installer）。这里用一次性 RSA 密钥对钉住
# 语义，不碰仓库里的 Keys/ —— 那把私钥按设计不在仓库里。

WORK_RSA="$(mktemp -d)"
trap 'rm -rf "$WORK_RSA"' EXIT

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$WORK_RSA/priv.pem" 2>/dev/null
openssl pkey -in "$WORK_RSA/priv.pem" -pubout -out "$WORK_RSA/pub.pem" 2>/dev/null
printf 'version = "0.1.0"\n' > "$WORK_RSA/data"
openssl dgst -sha256 -sign "$WORK_RSA/priv.pem" \
    -out "$WORK_RSA/data.sig" "$WORK_RSA/data" 2>/dev/null
printf 'version = "9.9.9"\n' > "$WORK_RSA/tampered"

verify_with_python() {
    # verify_with_python <data> <sig> <pub> → 打印 ok / bad
    PYTHONPATH="$(component_paths)" python3 -c '
import sys
import selfupdate
sys.exit(0 if selfupdate._verify(sys.argv[1], sys.argv[2], sys.argv[3]) else 1)
' "$1" "$2" "$3" > /dev/null 2>&1 && echo ok || echo bad
}

check_verify() {
    # check_verify <说明> <数据> <签名> <期望 ok|bad>
    local label="$1" data="$2" sig="$3" want="$4" got
    got="$(verify_with_python "$data" "$sig" "$WORK_RSA/pub.pem")"
    if [[ "$got" == "$want" ]]; then
        pass "$label"
    else
        fail "${label}（期望 ${want}，实际 ${got}）"
    fi
}

check_verify "好签名 → 通过" "$WORK_RSA/data" "$WORK_RSA/data.sig" "ok"
check_verify "数据被改 → 不通过" "$WORK_RSA/tampered" "$WORK_RSA/data.sig" "bad"
check_verify "签名对不上 → 不通过" "$WORK_RSA/data" "$WORK_RSA/tampered" "bad"

echo
echo "========== 4. 内嵌 RSA 公钥与仓库里那份必须一致 =========="

if python3 "$SCRIPT_DIR/embed_rsa_pub.py" --check > /dev/null 2>&1; then
    pass "lib/install.sh 内置的公钥与 Keys/macwave-rsa.pub.pem 一致"
else
    fail "内置公钥与 Keys/macwave-rsa.pub.pem 不一致（跑 python3 scripts/embed_rsa_pub.py）"
fi

if [[ -f "$REPO_DIR/Keys/macwave-rsa.pub.pem" ]] &&
    openssl pkey -pubin -in "$REPO_DIR/Keys/macwave-rsa.pub.pem" -noout 2> /dev/null
then
    pass "Keys/macwave-rsa.pub.pem 是可解析的 PEM 公钥"
else
    fail "Keys/macwave-rsa.pub.pem 缺失或解析不了"
fi

# Python 侧从安装树里的 lib/install.sh 抠这把公钥当锚点（不从 Keys/ 读 —— 那是自证）
if PYTHONPATH="$(component_paths)" python3 -c '
import sys
import selfupdate
sys.exit(0 if selfupdate._trusted_pub() else 1)
' > /dev/null 2>&1; then
    pass "lib/selfupdate.py 能从 lib/install.sh 里找到公钥锚点"
else
    fail "lib/selfupdate.py 找不到公钥锚点"
fi

echo
echo "=========================================="
