#!/bin/bash

# install_flags_test.sh
# `--help` 与 `--print-usage` 的分工，以及 --help 的连用规则。
#
# 两条命令长得像，做的事不一样：
#
#   --help          打用法，**停**在这里（不安装）
#   --print-usage   打用法，然后**继续**（真的安装，或继续 --dry-run）
#
# 而且 --help 只允许单独出现，或与 --dry-run 连用（先打用法、再走一遍流程）。
# 与其它安装参数连用要报错：`--help --ci` 读起来像「按这些参数装」，
# 实际却只打帮助 —— 静默忽略比报错更容易让人以为装过了。
#
# 第 7 节另测「平台守卫」：非 macOS 时第一句就请用户去 LinuxWave，
# 连安装都不开始（给网站与安装命令，退出码 2）。
#
# 全程离线、隔离测试根、只用 --dry-run（或干脆什么都不做）。

# 语言：install.sh 会按 locale / 系统首选语言自动切中文，断言因此会随开发者的
# 系统语言漂（中文 Mac 上所有英文断言一起红）。这里钉成英文 + 清掉外层的覆盖，
# 专测语言的那几段自己显式给 LANG。
unset MACWAVE_LANG LC_ALL LC_MESSAGES
export LANG=en_US.UTF-8

# 这些用例用的是赝品镜像，里面没有 latest.toml.sig，而验签 4.7 起是强制的
# （不通过就不装）。真实验签由 signature_test.sh 单独覆盖，这里放开。
export MACWAVE_ALLOW_UNSIGNED=1

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="$REPO_DIR/lib/install.sh"

FAILED=0
PASSED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

if [[ ! -f "$INSTALL_SH" ]]; then
    echo -e "${RED_BOLD}🌊 Error: install.sh not found at $INSTALL_SH${RESET}"
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

has() { case "$1" in (*"$2"*) return 0 ;; (*) return 1 ;; esac; }
hasnt() { case "$1" in (*"$2"*) return 1 ;; (*) return 0 ;; esac; }

# 版本数据必须能读到：它在**参数解析之前**就会去取，读不到时安装器直接退出，
# 那样连 --help 都轮不到。这里用 file:// 指一份最小的 latest.toml —— 离线，
# 且不会因为线上换版本而变红。
SELFUPDATE_DIR="$WORK/selfupdate"
mkdir -p "$SELFUPDATE_DIR/macwavedata"
printf 'version = "9.9.9"\nrelease_date = "2026-01-01"\nbuild_number = "TEST"\nbranch = "9.9"\n' \
    > "$SELFUPDATE_DIR/macwavedata/latest.toml"

# run_install <测试根名> [参数...]：输出放 ${OUT}，rc 放 ${RC}。
run_install() {
    local root="$WORK/$1"; shift
    mkdir -p "$root"
    OUT=$(MACWAVE_TEST="$root" \
          MACWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
          /bin/bash "$INSTALL_SH" "$@" < /dev/null 2>&1)
    RC=$?
}

# -------------------- 1. --help 单独：打用法就停 --------------------

run_install help-alone --help
if [[ "$RC" -eq 0 ]] && has "$OUT" "Usage:" && hasnt "$OUT" "Dry run"; then
    pass "--help：只打用法，rc=0"
else
    fail "--help 的行为不对（rc=${RC}）"
fi

# 「不安装」的证据：没有安装树、也没有写配置。
# 注意 MACWAVE_TEST 的测试根里会先建一个 <根><HOME> 的空目录（那是隔离机制本身），
# 所以这里查的是「安装的产物」，不是「目录是否为空」。
if [[ ! -e "$WORK/help-alone/base" ]] \
   && [[ -z "$(find "$WORK/help-alone" -name config.json 2>/dev/null)" ]]; then
    pass "--help：没有安装树、也没有写配置"
else
    fail "--help 竟然产生了安装产物"
fi

# --help 不该碰网络：版本号请求排在参数解析之后，所以连版本源都连不上时，
# 它也必须能照常打出用法。这条是结构保证，不是巧合 —— 早先的写法是先取版本、
# 再解析参数，`--help` 在断网机器上会直接报「读不到版本号」。
OUT=$(MACWAVE_TEST="$WORK/help-offline" \
      MACWAVE_SELFUPDATE_DOMAIN="http://127.0.0.1:1" \
      /bin/bash "$INSTALL_SH" --help < /dev/null 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && has "$OUT" "Usage:" && hasnt "$OUT" "Cannot read the latest version"; then
    pass "--help 不联网：版本源不可达时仍能打用法"
else
    fail "--help 仍然依赖版本源（rc=${RC}）"
fi

# -------------------- 2. --help 与呈现类旗标 --------------------

run_install help-zh --help --zh
if [[ "$RC" -eq 0 ]] && has "$OUT" "用法："; then
    pass "--help --zh：中文用法"
else
    fail "--help --zh 没打中文（rc=${RC}）"
fi

run_install help-raw --help --raw
# 注意：帮助正文里**提到** 🌊（--raw 的说明），所以只查行首有没有。
if [[ "$RC" -eq 0 ]] && [[ "$(printf '%s\n' "$OUT" | grep -c '^🌊')" -eq 0 ]] \
   && [[ "$(printf '%s\n' "$OUT" | grep -c "$(printf '\033')")" -eq 0 ]]; then
    pass "--help --raw：行首无 🌊、无 ANSI"
else
    fail "--help --raw 的输出不干净"
fi

# -------------------- 3. --help 与 --dry-run：先用法、再走流程 --------------------

run_install help-dry --help --dry-run
if hasnt "$OUT" "cannot be combined" && has "$OUT" "Usage:" && has "$OUT" "Dry run"; then
    pass "--help --dry-run：允许，先打用法再走试运行"
else
    fail "--help --dry-run 被拒或没继续（rc=${RC}）"
fi

# -------------------- 4. --help 与其它参数：必须报错 --------------------

run_install help-ci --help --ci
if [[ "$RC" -eq 1 ]] && has "$OUT" "cannot be combined with '--ci'"; then
    pass "--help --ci：报错并点名 --ci"
else
    fail "--help --ci 没有报错（rc=${RC}）"
fi

run_install help-ci --help --ci
if [[ "$RC" -eq 1 ]] && has "$OUT" "cannot be combined with '--ci'"; then
    pass "--help --ci：报错并点名该参数"
else
    fail "--help --ci 没有报错（rc=${RC}）"
fi

if has "$OUT" "--print-usage"; then
    pass "报错时指出 --print-usage 这条出路"
else
    fail "报错里没有提到 --print-usage"
fi

# -------------------- 5. --print-usage：打用法后继续 --------------------

run_install pu-dry --print-usage --dry-run
if [[ "$RC" -eq 0 ]] && has "$OUT" "Usage:" && has "$OUT" "Dry run"; then
    pass "--print-usage --dry-run：先用法，再继续试运行"
else
    fail "--print-usage --dry-run 的行为不对（rc=${RC}）"
fi

run_install pu-zh-raw --print-usage --zh --raw --dry-run
if [[ "$RC" -eq 0 ]] && has "$OUT" "用法：" \
   && [[ "$(printf '%s\n' "$OUT" | grep -c '^🌊')" -eq 0 ]] \
   && [[ "$(printf '%s\n' "$OUT" | grep -c "$(printf '\033')")" -eq 0 ]]; then
    pass "--print-usage 也遵守 --zh 与 --raw"
else
    fail "--print-usage --zh --raw 的组合没按规矩输出（rc=${RC}）"
fi

# -------------------- 6. 未知选项仍然报错（回归） --------------------

run_install unknown --bogus-flag
if [[ "$RC" -eq 1 ]] && has "$OUT" "unknown option"; then
    pass "未知选项仍然报错"
else
    fail "未知选项没有报错（rc=${RC}）"
fi

# -------------------- 7. 平台守卫：非 macOS 请去 LinuxWave --------------------
#
# 用替身 uname 摆出「宿主是 Linux」：这个脚本里有太多 macOS 专属步骤
# （/usr/local 菜单项、SIP 与系统卷密封、csrutil、Xcode 工具），在 Linux 上装到
# 一半才报错是最差的形态。
#
# 这里**故意不设 MACWAVE_TEST** —— 那正是被绕过的条件（沙箱里宿主是不是 Linux
# 无所谓，CircleCI 的容器就这么跑）。

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/uname" <<'STUB'
#!/bin/sh
case "$1" in
    -s) echo Linux ;;
    *) exec /usr/bin/uname "$@" ;;
esac
STUB
chmod +x "$STUB_BIN/uname"

mklinux() {
    # mklinux [参数...]：在「Linux 宿主」下跑一次，输出进 OUT，退出码进 RC
    rm -rf "$WORK/linux-root"
    OUT=$(PATH="$STUB_BIN:$PATH" \
          MACWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
          /bin/bash "$INSTALL_SH" "$@" < /dev/null 2>&1)
    RC=$?
}

mklinux --dry-run
if [[ "$RC" -eq 2 ]] \
   && has "$OUT" "LinuxWave" \
   && has "$OUT" "https://linuxwave.org" \
   && has "$OUT" "https://github.com/LinuxWaveOrg/LinuxWave/releases/latest/download/install.sh"; then
    pass "非 macOS：请用户去 LinuxWave，给出官网与完整安装命令（rc=2）"
else
    fail "非 macOS 的提示不对（rc=${RC}）：$(printf '%s' "$OUT" | head -2)"
fi

if [[ ! -e "$WORK/linux-root" ]] && [[ -z "$(find "$WORK" -maxdepth 1 -name 'linux-*' 2>/dev/null)" ]]; then
    pass "非 macOS：拒绝发生在任何安装动作之前（没有测试根、没有产物）"
else
    fail "非 macOS 时还是动了文件"
fi

mklinux --zh
if [[ "$RC" -eq 2 ]] && has "$OUT" "请改用 LinuxWave"; then
    pass "非 macOS --zh：提示是中文的"
else
    fail "非 macOS --zh 没有中文提示（rc=${RC}）"
fi

mklinux --raw
if [[ "$RC" -eq 2 ]] && [[ "$(printf '%s\n' "$OUT" | grep -c '^🌊')" -eq 0 ]]; then
    pass "非 macOS --raw：行首无 🌊（走的是同一个过滤器）"
else
    fail "非 macOS --raw 的输出不干净（rc=${RC}）"
fi

mklinux --help
if [[ "$RC" -eq 0 ]] && has "$OUT" "Usage:" && hasnt "$OUT" "LinuxWave"; then
    pass "非 macOS --help：照常打用法，不被平台守卫拦住"
else
    fail "非 macOS --help 被拦住了（rc=${RC}）"
fi

# 沙箱里宿主是 Linux 完全正常：MACWAVE_TEST 一设，守卫就放行。
OUT=$(MACWAVE_TEST="$WORK/linux-sandbox" \
      MACWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
      PATH="$STUB_BIN:$PATH" \
      /bin/bash "$INSTALL_SH" --dry-run < /dev/null 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && has "$OUT" "Dry run" && hasnt "$OUT" "not macOS"; then
    pass "MACWAVE_TEST 下不判平台（沙箱里宿主是 Linux 也照跑）"
else
    fail "MACWAVE_TEST 下被平台守卫拦住了（rc=${RC}）"
fi

# -------------------- 7a2. 输出语言：能自动认中文，也能被 --zh/--en 压过 --------------------
#
# 自动识别只看环境：MACWAVE_LANG / LC_ALL / LC_MESSAGES / LANG，都没有才看 macOS 的
# 系统首选语言。测试一律显式给 LANG，否则结果会随开发者自己的系统语言漂。
run_lang() {
    # run_lang <LANG 值> [参数...]：干净环境里跑一次，别被外层的 MACWAVE_LANG 干扰
    local lang="$1"; shift
    OUT=$(env -u MACWAVE_LANG -u LC_ALL -u LC_MESSAGES LANG="$lang" \
          MACWAVE_TEST="$WORK/lang-$lang" \
          MACWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
          /bin/bash "$INSTALL_SH" "$@" < /dev/null 2>&1)
    RC=$?
}

run_lang zh_CN.UTF-8 --help
if [[ "$RC" -eq 0 ]] && has "$OUT" "用中文输出"; then
    pass "LANG=zh_CN.UTF-8：自动用中文"
else
    fail "中文 locale 没有自动切中文（rc=${RC}）"
fi

run_lang en_US.UTF-8 --help
if [[ "$RC" -eq 0 ]] && hasnt "$OUT" "用中文输出"; then
    pass "LANG=en_US.UTF-8：仍是英文"
else
    fail "英文 locale 被切成了中文（rc=${RC}）"
fi

# LANG=zh_CN.eucCN 这类非 UTF-8 的中文 locale：中文文案会糊成问号，给英文
run_lang zh_CN.eucCN --help
if [[ "$RC" -eq 0 ]] && hasnt "$OUT" "用中文输出"; then
    pass "非 UTF-8 的中文 locale：退回英文（避免乱码）"
else
    fail "非 UTF-8 的中文 locale 仍给了中文（rc=${RC}）"
fi

run_lang en_US.UTF-8 --zh --help
if [[ "$RC" -eq 0 ]] && has "$OUT" "用中文输出"; then
    pass "--zh 压过英文 locale"
else
    fail "--zh 没能压过英文 locale（rc=${RC}）"
fi

run_lang zh_CN.UTF-8 --en --help
if [[ "$RC" -eq 0 ]] && hasnt "$OUT" "用中文输出"; then
    pass "--en 压过中文 locale"
else
    fail "--en 没能压过中文 locale（rc=${RC}）"
fi

# MACWAVE_LANG 是调用方（update_commands.sh / CI）给的，优先级最高
OUT=$(env -u LC_ALL -u LC_MESSAGES LANG=en_US.UTF-8 MACWAVE_LANG=zh \
      MACWAVE_TEST="$WORK/lang-env" \
      MACWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
      /bin/bash "$INSTALL_SH" --help < /dev/null 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && has "$OUT" "用中文输出"; then
    pass "MACWAVE_LANG=zh 压过 LANG=en_US.UTF-8"
else
    fail "MACWAVE_LANG 没能压过 LANG（rc=${RC}）"
fi

# -------------------- 7b. 平台判断：只看内核 --------------------
#
# iOS / iPadOS / Android / ChromeOS 一概不单独识别 —— 这些设备上装不装得成由用户
# 自己保证（见 docs/DEVELOPING.md「平台判断」）。这里只钉三件事：Darwin 放行、
# Linux 指向 LinuxWave、其它报出 uname -s 的原值。
write_uname() {
    # write_uname <sys> [machine]：-m 也要能伪造，否则「按架构分的地板」测不出来
    printf '#!/bin/sh
case "$1" in
  -s) echo %s ;;
  -m) echo %s ;;
  *) exec /usr/bin/uname "$@" ;;
esac
' \
        "$1" "${2:-$(/usr/bin/uname -m)}" > "$STUB_BIN/uname"
    chmod +x "$STUB_BIN/uname"
}
write_sw_vers() {
    # write_sw_vers <productName> [productVersion]；版本默认给一个够新的值
    printf '#!/bin/sh\ncase "$1" in\n  -productName) echo "%s" ;;\n  -productVersion) echo "%s" ;;\n  *) exit 1 ;;\nesac\n' \
        "$1" "${2:-15.5}" > "$STUB_BIN/sw_vers"
    chmod +x "$STUB_BIN/sw_vers"
}
run_bare() {
    # run_bare [参数...]：不设 MACWAVE_TEST，平台判断才会真的跑起来
    OUT=$(PATH="$STUB_BIN:$PATH" MACWAVE_SW_VERS="$STUB_BIN/sw_vers" \
          MACWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
          /bin/bash "$INSTALL_SH" "$@" < /dev/null 2>&1)
    RC=$?
}

write_uname Darwin
write_sw_vers macOS
run_bare --dry-run
if [[ "$RC" -eq 0 ]] && has "$OUT" "Dry run"; then
    pass "Darwin：放行"
else
    fail "正常 macOS 被平台守卫误伤（rc=${RC}）"
fi

# -------------------- 7c. macOS 版本地板：按架构分 --------------------
#
# 对外承诺：Apple Silicon 要 Sequoia 15，Intel 要 Monterey 12。
# 为什么不同：任何 Apple Silicon Mac 都跑得动 15（这个地板只排除「能升不升」的人）；
# Intel 侧由构建机的 SDK 决定，天然是 12，白捡老 Intel Mac 的兼容面。
#
# 一张表两个地方用：install.sh（树还不存在，导入不了 python 常量）与
# config/platforminfo.py 的 MIN_SUPPORTED_OS（客户端与构建侧）。这里核对两边一致。

ARM64_FLOOR="$(sed -n 's/^MW_MIN_MACOS_ARM64="\(.*\)"$/\1/p' "$INSTALL_SH" | head -1)"
X86_FLOOR="$(sed -n 's/^MW_MIN_MACOS_X86_64="\(.*\)"$/\1/p' "$INSTALL_SH" | head -1)"
PLATFORM_FLOORS="$("${PYTHON:-python3}" - "$REPO_DIR" <<'PYEOF'
import sys
sys.path.insert(0, f"{sys.argv[1]}/config")
import platforminfo
arm = platforminfo.MIN_SUPPORTED_OS["arm64"]
x86 = platforminfo.MIN_SUPPORTED_OS["amd64"]
print(f"{arm[0]}.{arm[1]} {x86[0]}.{x86[1]}")
PYEOF
)"
if [[ "$ARM64_FLOOR $X86_FLOOR" == "$PLATFORM_FLOORS" ]]; then
    pass "install.sh 的地板表与 platforminfo.MIN_SUPPORTED_OS 一致（${PLATFORM_FLOORS}）"
else
    fail "地板表漂了：install.sh 是「${ARM64_FLOOR} ${X86_FLOOR}」，platforminfo 是「${PLATFORM_FLOORS}」"
fi

write_uname Darwin arm64
for old_version in 10.13.6 10.15.7 12.0 14.6.1; do
    write_sw_vers macOS "$old_version"
    run_bare --dry-run
    if [[ "$RC" -eq 2 ]] && has "$OUT" "$old_version" && has "$OUT" "15.0" && has "$OUT" "Sequoia"; then
        pass "arm64 + macOS ${old_version}：拒绝，并说明 Apple Silicon 要 15"
    else
        fail "arm64 + macOS ${old_version} 没有被拒绝（rc=${RC}）"
    fi
done

for ok_version in 15.0 15.5 26.0; do
    write_sw_vers macOS "$ok_version"
    run_bare --dry-run
    if [[ "$RC" -eq 0 ]] && has "$OUT" "Dry run" && hasnt "$OUT" "too old"; then
        pass "arm64 + macOS ${ok_version}：放行"
    else
        fail "arm64 + macOS ${ok_version} 被误拦（rc=${RC}）"
    fi
done

write_uname Darwin x86_64
for old_version in 10.13.6 11.7; do
    write_sw_vers macOS "$old_version"
    run_bare --dry-run
    if [[ "$RC" -eq 2 ]] && has "$OUT" "$old_version" && has "$OUT" "12.0" && has "$OUT" "Monterey"; then
        pass "Intel + macOS ${old_version}：拒绝，并说明 Intel 要 12"
    else
        fail "Intel + macOS ${old_version} 没有被拒绝（rc=${RC}）"
    fi
done

for ok_version in 12.0 12.7.6 14.4 26.0; do
    write_sw_vers macOS "$ok_version"
    run_bare --dry-run
    if [[ "$RC" -eq 0 ]] && has "$OUT" "Dry run" && hasnt "$OUT" "too old"; then
        pass "Intel + macOS ${ok_version}：放行"
    else
        fail "Intel + macOS ${ok_version} 被误拦（rc=${RC}）"
    fi
done

# 读不到版本号时不判：宁可放行，也不要在读不出信息时把正常机器挡在门外
printf '#!/bin/sh\ncase "$1" in\n  -productName) echo "macOS" ;;\n  *) exit 1 ;;\nesac\n' \
    > "$STUB_BIN/sw_vers"
chmod +x "$STUB_BIN/sw_vers"
run_bare --dry-run
if [[ "$RC" -eq 0 ]] && hasnt "$OUT" "too old"; then
    pass "读不到 macOS 版本号：不判、放行"
else
    fail "读不到版本号时把机器拦掉了（rc=${RC}）"
fi
write_sw_vers macOS

write_uname FreeBSD
run_bare --dry-run
if [[ "$RC" -eq 2 ]] && has "$OUT" "not recognised" && has "$OUT" "FreeBSD"; then
    pass "未知平台：报出 uname -s 的原值并拒绝（rc=2）"
else
    fail "未知平台的提示不对（rc=${RC}）"
fi

write_uname "$(uname -s)"
if [[ "$(uname -s)" == "Darwin" ]]; then
    run_install darwin-host --dry-run
    if [[ "$RC" -eq 0 ]] && hasnt "$OUT" "LinuxWave"; then
        pass "macOS 宿主：不出现 LinuxWave 提示"
    else
        fail "macOS 宿主上误报了 LinuxWave（rc=${RC}）"
    fi
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All install flag tests passed${RESET}"
