#!/bin/bash

# configpath_test.sh
# 安装根解析回归（离线，不碰网络、不碰真实的 /opt 与 ${HOME}）：
#   安装根是写死的（config/platforminfo.py 的 DEFAULT_BASE_DIR），
#   没有配置文件、没有候选目录、也没有环境变量覆盖；
#   MACWAVE_TEST 只做一件事：把这个绝对路径映射进测试根。
#   版本号只从树内 <base>/var/config.sh 读。

set -e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIGPATHS_PY="$REPO_DIR/config/configpaths.py"

if [[ ! -f "$CONFIGPATHS_PY" ]]; then
    echo -e "${RED_BOLD}🌊 Error: configpaths.py not found at $CONFIGPATHS_PY${RESET}"
    exit 1
fi

FAILED=0
PASSED=0

pass() {
    echo -e "${GREEN}🌊 PASS: $1${RESET}"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"
    FAILED=$((FAILED + 1))
}

echo "========== install root resolution =========="

TMP_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

if MACWAVE_TEST="$TMP_ROOT" python3 - "$CONFIGPATHS_PY" << 'PYEOF'
import importlib.util
import sys
from pathlib import Path

# configpaths 会 import 同目录的 envvar / platforminfo，所以它所在目录要在
# sys.path 上 —— 生产环境里这一步由 lib/wave.py 做。
sys.path.insert(0, str(Path(sys.argv[1]).parent))

spec = importlib.util.spec_from_file_location('configpaths_module', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

import platforminfo

# 1) 写死的路径；MACWAVE_TEST 只把它映射进测试根
root = module.TEST_ROOT
assert root is not None
expected = root / platforminfo.DEFAULT_BASE_DIR.lstrip("/")
assert module.load_base_dir() == expected, (module.load_base_dir(), expected)

# 2) 候选目录与配置文件读取这一整套都不存在了
for gone in ("SYSTEM_CONFIG_DIR", "USER_CONFIG_DIR", "config_dir_candidates",
             "find_config_dir", "CONFIG_FILE_NAME", "VERSION_FILE"):
    assert not hasattr(module, gone), gone

# 3) 配置文件出现在任何地方都不会改变安装根
(root / "opt" / "macwave_config").mkdir(parents=True)
(root / "opt" / "macwave_config" / "config.json").write_text('{"base_dir": "/tmp/elsewhere"}')
assert module.load_base_dir() == expected

# 4) 状态目录：var/config.sh 在就是它，不在就没有
base = expected
assert module.internal_state_dir() is None
(base / "var").mkdir(parents=True)
(base / "var" / "config.sh").write_text(
    "# comment\nMACWAVE_VERSION='1.2.3'\nMACWAVE_BUILD='9ABC'\n")
assert module.internal_state_dir() == base / "var"
assert module.installed_version() == "1.2.3"
assert module.installed_build() == "9ABC"

# 5) 状态文件里没有版本号时是 None，不当成 "unknown"
(base / "var" / "config.sh").write_text("MACWAVE_INSTALLED_AT='2026-01-01T00:00:00Z'\n")
assert module.installed_version() is None
assert module.installed_build() is None

print('🌊 install root is fixed and state is read from var/config.sh')
PYEOF
then
    pass "固定安装根 / 测试根映射 / 状态读取"
else
    fail "install root resolution"
fi

echo ""
echo "🌊 configpath test: $PASSED passed, $FAILED failed"

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi
