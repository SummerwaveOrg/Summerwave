#!/bin/bash

# selfupdate_test.sh
# selfupdate 回归：版本数据解析 → 已是最新时的短路 → 跨大版本被拒绝 → 同大版本的端到端自更新
# 最后一步会真的把安装目录更新一遍，所以放在 CI 的最后执行。

# 语言：install.sh 会按 locale / 系统首选语言自动切中文，断言因此会随开发者的
# 系统语言漂（中文 Mac 上所有英文断言一起红）。这里钉成英文 + 清掉外层的覆盖，
# 专测语言的那几段自己显式给 LANG。
unset MACWAVE_LANG LC_ALL LC_MESSAGES
export LANG=en_US.UTF-8

# 这些用例用的是赝品镜像，里面没有 latest.toml.sig，而验签 4.7 起是强制的
# （不通过就不装）。真实验签由 signature_test.sh 单独覆盖，这里放开。
export MACWAVE_ALLOW_UNSIGNED=1

set -e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"
WAVE_BIN="$REPO_DIR/lib/wave.py"
SELFUPDATE_PY="$REPO_DIR/lib/selfupdate.py"

if [[ ! -f "$WAVE_BIN" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found at $WAVE_BIN${RESET}"
    exit 1
fi

# ==========================================
# 隔离：这个测试会**真的**跑一次 selfupdate（下载文件、落盘、写 var/config.sh 与
# 状态目录），所以它必须在自己的沙箱里跑。
#
# 2026-11-24 之前它用的是真实配置目录与真实安装树，于是「跑一次测试」=
# 「把现有安装刷成测试版本」：`<base>/var/config.sh` 被写成
# 4.0.1/TEST，真实安装树也被换成了 4.0.1。
# AGENTS.md 里那条「会改动系统的测试必须先设 MACWAVE_TEST」说的就是这件事。
#
# MACWAVE_TEST 会让 configpaths 把测试根当 /：安装根写死在 <root>/opt/macwave，
# 所以这里先把组件**拷**进去（不是软链 —— 自更新会往这棵树里写文件，
# 软链会把改动写回仓库）。
# ==========================================

SU_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/selfupdate_test.XXXXXX")"
export MACWAVE_TEST="$SU_ROOT"

SANDBOX_BASE="$SU_ROOT/opt/macwave"
mkdir -p "$SANDBOX_BASE" "$SANDBOX_BASE/var"

for component in $(components) man info Keys; do
    [[ -d "$REPO_DIR/$component" ]] || continue
    mkdir -p "$SANDBOX_BASE/$component"
    cp -R "$REPO_DIR/$component"/. "$SANDBOX_BASE/$component"/ 2>/dev/null || true
done

# 状态只有一份：<base>/var/config.sh。
STATE_FILE="$SANDBOX_BASE/var/config.sh"
write_state_version() {
    printf "MACWAVE_VERSION='%s'\n" "$1" > "$STATE_FILE"
}
state_version() {
    sed -n "s/^MACWAVE_VERSION='\(.*\)'$/\1/p" "$STATE_FILE" 2>/dev/null | head -n 1
}
write_state_version "4.0.0"

FAILED=0

# ==========================================
# 0. 本地假发布站点（下面几段都靠它，全程离线）
# ==========================================
#
# 换轨之后，「该装哪一版」只有一处来源：GitHub 的发布接口。测试把它整体换成
# file:// 上的几个 JSON 与文件，客户端走的仍是真代码（探针解析、版本比较、取件、
# 验签、执行）。这样既离线，又不依赖线上已发布的版本号。

SU_WORK="$(mktemp -d)"
trap 'kill "$SU_SERVER_PID" 2>/dev/null; wait "$SU_SERVER_PID" 2>/dev/null; rm -rf "$SU_WORK" "$SU_ROOT"' EXIT

SU_RELEASE_ROOT="$SU_WORK/release"
SU_TAG="v4.0.1@2026-01-01T00:00Z"
SU_VERSION="4.0.1"
mkdir -p "$SU_RELEASE_ROOT/releases/tags" "$SU_RELEASE_ROOT/releases/assets"

# 安装器本体：被执行就留下一个标记文件，供断言「到底跑没跑」
INSTALLER_MARKER="$SU_WORK/installer-ran"
{
    printf '#!/bin/bash\n'
    printf 'touch "%s"\n' "$INSTALLER_MARKER"
} > "$SU_RELEASE_ROOT/releases/assets/1"
: > "$SU_RELEASE_ROOT/releases/assets/2"     # .sig：文件头放开了验签，内容不重要

# 造一次「发布了 <tag>」：latest 指针 + tag 详情 + 两个资产
create_release() {
    # create_release <tag> [body]
    local tag="$1" body="${2:-}"
    python3 - "$tag" "$body" "$SU_RELEASE_ROOT" <<'PY'
import json
import pathlib
import sys

tag, body, root = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
item = {"tag_name": tag, "prerelease": False, "draft": False, "body": body}
(root / "releases" / "latest").write_text(json.dumps(item))
(root / "releases" / "tags" / tag).write_text(json.dumps(dict(item, assets=[
    {"name": "install.sh", "id": 1},
    {"name": "install.sh.sig", "id": 2},
])))
PY
}

create_release "$SU_TAG"

# 假站点起在 loopback 上：curl 带 --proto '=https'（TLS 收紧那段），file:// 会被拒，
# 而明文 http 只对回环放行 —— 正好是给离线测试留的那条缝。
SU_PORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"
python3 -m http.server "$SU_PORT" --bind 127.0.0.1 --directory "$SU_RELEASE_ROOT" \
    > /dev/null 2>&1 &
SU_SERVER_PID=$!
for _ in $(seq 100); do
    curl -fsS "http://127.0.0.1:$SU_PORT/releases/latest" > /dev/null 2>&1 && break
    sleep 0.1
done

export SUMMERWAVE_RELEASE_DOMAIN="http://127.0.0.1:$SU_PORT"

# 假站点必须真的能应答，否则后面每一段都会以「连不上」变红，分不清是谁的问题
if ! curl -fsS "$SUMMERWAVE_RELEASE_DOMAIN/releases/latest" > /dev/null; then
    echo "fixture error: the fake release site is not answering" >&2
    exit 1
fi
# 解释器数据不存在时安装器会警告并回退到系统 python3，安装不中断
export SUMMERWAVE_PYTHON_DOMAIN="file://$SU_WORK/python"

# ==========================================
# 1. 版本数据解析与版本比较（离线，不碰网络）
# ==========================================

echo "========== parse version data =========="

if python3 - "$SELFUPDATE_PY" << 'PYEOF'
import importlib.util
import os
import sys
from pathlib import Path

selfupdate_py = Path(sys.argv[1])
# selfupdate.py 会 import configpaths（lib/）与 domains/tls（net/），两处都要在路径上。
sys.path[:0] = os.environ["MACWAVE_COMPONENT_PATHS"].split(os.pathsep) + [str(selfupdate_py.parent)]
spec = importlib.util.spec_from_file_location('selfupdate_module', selfupdate_py)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# 4.0 的版本数据是 TOML（macwavedata/latest.toml）。3.x 的「冒号 + <<< >>> 命令块」
# 随 files_info 一起退休了，所以这里只校验 key = "value" 这一种形态。
single = (
    'version = "9.9.9"\n'
    'release_date = "2026-01-01"\n'
    'build_number = "X1"\n'
    'branch = "main"\n'
)
data = module.version_data(single)
assert data['version'] == '9.9.9', data
assert data['branch'] == 'main', data
assert data['release_date'] == '2026-01-01', data
assert data['build_number'] == 'X1', data

# 线上文件带注释：注释里的「version =」不能被当成字段
commented = (
    '# version = "should-not-win"\n'
    '# 说明文字\n'
    'version = "1.0"\n'
)
parsed = module.version_data(commented)
assert parsed['version'] == '1.0', parsed

# 解析器是**故意宽松**的：认不出的行直接跳过，不报错。
# 这样有人在数据文件里留了说明、或以后加了新字段，旧客户端仍能读到 version，
# 而不是整个自更新停摆。坏处是拼错也不会被告知，所以这里把行为钉住：
lenient = module.version_data('version "1.0"\nversion = "2.0"\nunknown-key = "x"\n')
assert lenient['version'] == '2.0', lenient
assert lenient['unknown-key'] == 'x', lenient

# 版本比较：PEP 440（packaging），见 lib/versioncompare.py
assert module.version_key('2.3') == module.version_key('2.3.0')
assert module.version_key('2.2.0') < module.version_key('2.3')
assert module.version_key('2.10.0') > module.version_key('2.9.0')
assert module.version_key('2.3') >= module.version_key('2.3')

# 客户端版本是**发布时刻**（2026.11.26-15:52:43）：只按时间排序。
assert module.version_key('2026.11.26-15:52:43') < module.version_key('2026.11.26-15:52:44')
assert module.version_key('2026.11.27-00:00:00') > module.version_key('2026.11.26-23:59:59')
assert module.version_key('2027.01.01-00:00:00') > module.version_key('2026.12.31-23:59:59')
# 发布标志永远比老式版本号新，升级方向天然单向
assert module.version_key('2026.11.26-15:52:43') > module.version_key('4.4.1')
# 老版本号之间仍按 PEP 440（老机器、老数据还要读得懂）
assert module.version_key('4.4.0') > module.version_key('4.4.0-beta1')

print('🌊 Parsing and version comparison OK')
PYEOF
then
    echo -e "${GREEN}🌊 OK: parse version data${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: parse version data${RESET}"
    FAILED=$((FAILED + 1))
fi

# ==========================================
# 2. 已是最新时必须短路（不会去执行 update_command）
# ==========================================

echo "========== already up to date =========="

write_state_version "9999.0"

LOG_FILE="$(mktemp)"
RC=0
python3 "$WAVE_BIN" selfupdate > "$LOG_FILE" 2>&1 || RC=$?
cat "$LOG_FILE"

if [[ "$RC" -eq 0 ]] && grep -q 'already up to date' "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: reports up to date${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: expected an up-to-date short circuit (exit $RC)${RESET}"
    FAILED=$((FAILED + 1))
fi
rm -f "$LOG_FILE"

# ==========================================
# 2.5 --dry-run：只说会做什么，什么都不做
# ==========================================

echo "========== --dry-run changes nothing =========="

# 装的是 4.0.0、上面那份版本数据是 4.0.1：同大版本、确实有得升。
# 协议这一段也该被「问一次」——dry run 只许说，不许问（下面喂 /dev/null，
# 一旦它真去 input() 就会拿到 EOF 并按拒绝退出，测试随之变红）。
write_state_version "4.0.0"

LOG_FILE="$(mktemp)"
RC=0
python3 "$WAVE_BIN" selfupdate --dry-run < /dev/null > "$LOG_FILE" 2>&1 || RC=$?
cat "$LOG_FILE"

DRY_OK=yes
grep -q 'Dry run: MacWave would be updated from 4.0.0 to 4.0.1' "$LOG_FILE" || DRY_OK=no
grep -q 'Nothing was downloaded and nothing was changed' "$LOG_FILE" || DRY_OK=no
# 真更新才会打印这句（run_installer 的第一行）
grep -q 'Downloading the installer' "$LOG_FILE" && DRY_OK=no
if [[ "$RC" -eq 0 && "$DRY_OK" == "yes" ]]; then
    echo -e "${GREEN}🌊 OK: dry run reports the plan and exits 0${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: --dry-run did not behave (exit $RC)${RESET}"
    FAILED=$((FAILED + 1))
fi

if [[ "$(state_version)" == "4.0.0" ]]; then
    echo -e "${GREEN}🌊 OK: state untouched by --dry-run${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: --dry-run changed the state file${RESET}"
    FAILED=$((FAILED + 1))
fi

rm -f "$LOG_FILE"

# ==========================================
# 3.5 指针声明 selfupdate = "blocked" 时不许自更新
# ==========================================
#
# 新版确实存在，但不能用自更新装进去（布局变更到 prune 也不敢自动删、需要新解释器、
# 换了仓库/分支、给老版本线的回溯修复包）。入口只有一个：wave selfupdate。

echo "========== a blocked release is not self-updated =========="

cp "$STATE_FILE" "$SU_WORK/config.sh.bak"
# 装的是比目标更旧的版本，于是「确实有新版」这条路径走得通
INSTALLED_VERSION_FOR_BLOCK="4.0.0"
write_state_version "$INSTALLED_VERSION_FOR_BLOCK"

# 让这次发布的说明把目标版本声明成 blocked
create_release "$SU_TAG" 'selfupdate = "blocked"
selfupdate_reason = "layout changed"'

LOG_FILE="$(mktemp)"
RC=0
python3 "$WAVE_BIN" selfupdate > "$LOG_FILE" 2>&1 || RC=$?
cat "$LOG_FILE"

if [[ "$RC" -eq 0 ]] && grep -q 'cannot be installed with selfupdate' "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: wave selfupdate refuses a blocked release${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: expected a refusal for a blocked release (exit $RC)${RESET}"
    FAILED=$((FAILED + 1))
fi
if grep -q 'layout changed' "$LOG_FILE" && grep -q 'install.sh' "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: the refusal carries the reason and the way out${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: the refusal does not say why or what to do${RESET}"
    FAILED=$((FAILED + 1))
fi
rm -f "$LOG_FILE"

if [[ "$(state_version)" == "$INSTALLED_VERSION_FOR_BLOCK" ]]; then
    echo -e "${GREEN}🌊 OK: state untouched by the refusal${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: the refusal changed the state file${RESET}"
    FAILED=$((FAILED + 1))
fi

create_release "$SU_TAG"
cp "$SU_WORK/config.sh.bak" "$STATE_FILE"

# ==========================================
# 3.6 协议更新：装的是 4.4.0 或更早时必须问一次
# ==========================================

echo "========== every command resolves to a module =========="

if python3 - "$BASE_DIR" << 'PYEOF'
import os
import sys

base_dir = sys.argv[1]

# 子命令元数据住在 cli/commands.py（那一张表同时喂分发、帮助与手册）。
# 直接按文件加载：命令行模块刻意不 import 任何东西，所以在没有安装树的
# 解释器里也能读。
import importlib.util

path = os.path.join(base_dir, 'cli', 'commands.py')
spec = importlib.util.spec_from_file_location('commands_module', path)
commands_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(commands_module)

commands = [(entry.name, entry.module) for entry in commands_module.COMMANDS]
if not commands:
    print('🌊 Error: could not read any entry from cli/commands.py')
    sys.exit(1)

missing = []
for command, module in commands:
    if not any(os.path.exists(os.path.join(base_dir, folder, module + '.py'))
               for folder in os.environ["MACWAVE_COMPONENT_NAMES"].split()):
        missing.append(f'{command} -> {module}.py')

if missing:
    print('🌊 Error: these commands have no module file: ' + ', '.join(missing))
    sys.exit(1)

print(f'🌊 All {len(commands)} command(s) resolve to a module file')
PYEOF
then
    echo -e "${GREEN}🌊 OK: every command module exists${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: a command module is missing after selfupdate${RESET}"
    FAILED=$((FAILED + 1))
fi

# ==========================================
# 汇总
# ==========================================

echo ""
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 selfupdate tests failed: $FAILED${RESET}"
    echo "=========================================="
    exit 1
fi

echo -e "${GREEN}🌊 All selfupdate tests passed.${RESET}"
echo "=========================================="
exit 0
