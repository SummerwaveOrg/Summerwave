#!/usr/bin/env python3

# selfupdate.py

import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'


# -------------------- 常量 --------------------

from configpaths import (installed_build, installed_channel, installed_version,
                         internal_state_dir, load_base_dir)
import domains
import versioncompare
import tls

FETCH_TIMEOUT = 30
UPDATE_TIMEOUT = 1800


# -------------------- 超时 --------------------

# 旗标名 → 传给 selfupdate.sh 的环境变量。原样传文本，让脚本自己再解析一次，
# 保证「命令行怎么写就怎么生效」，两边不会各算一套。
TIMEOUT_ENV = {
    "--max-time": "MACWAVE_MAX_TIME",
    "--connect-timeout": "MACWAVE_CONNECT_TIMEOUT",
    "--content-time": "MACWAVE_CONTENT_TIME",
}


def options_from(input_string):
    """公共旗标走唯一的解析入口（cli/common.py）。

    与 install 的差别只剩「拿了值怎么用」：这里把三档超时的**原始文本**原样交给
    selfupdate.sh（它才是真正发请求的一层），预算则留给本层取版本数据时用。
    --proxy 由 wave.py 在分发前写进环境变量，子脚本的 curl 直接继承。

    返回 common.Options。
    """
    import common
    return common.parse(input_string or "")


def curl_seconds(timeout):
    # curl 收小数，但 0 表示「不限」，所以至少给 1 秒
    return max(1, int(round(timeout)))


def curl_limit_args(budget):
    """把 Budget 翻成 curl 的旗标。

    curl 侧一一对应：握手是 --connect-timeout，总额是 --max-time；
    「连上了多久收不到数据算失败」没有同名旗标，用 --speed-limit 1 --speed-time N
    表达 —— 阈值压到 1 字节/秒，等价于「只要还在收数据就不算超时」。
    """
    return ["--max-time", str(curl_seconds(budget.total)),
            "--connect-timeout", str(curl_seconds(budget.connect)),
            "--speed-limit", "1", "--speed-time", str(curl_seconds(budget.content))]


# -------------------- 版本数据 --------------------

# 最近一次取数失败的原因（诊断用）：返回值是 None，而「为什么」正是要分诊的东西。
LAST_ERROR = ""


def fetch_text(url, budget, raws=()):
    # 优先用标准库；本地 Python 缺根证书（macOS 常见）时改走 curl。
    # 带凭据的 URL 直走 curl：urllib 不认 user:pass@，会把它当主机名，白失败一次。
    #
    # 但 urllib 只有一个 socket 超时（连接与每次读共用），分不出三档。所以**只要
    # 命令行里给了任意一档超时就走 curl** —— 只有它能把三档分别表达出来。
    # 没给任何一档时照旧优先标准库，默认行为与以前一致。
    global LAST_ERROR

    LAST_ERROR = ""
    if not raws and not domains._has_userinfo(url):
        try:
            with urllib.request.urlopen(url, timeout=budget.total,
                                        **tls.urlopen_kwargs()) as response:
                return response.read().decode()
        except (urllib.error.URLError, UnicodeDecodeError, OSError) as error:
            LAST_ERROR = str(error)

    argv = ['curl', '-fsSL', '--retry', '2', '--retry-delay', '2',
            '--retry-connrefused', *curl_limit_args(budget), *tls.curl_flags(), url]
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode != 0:
        # curl 的 stderr 里带着真正的证书原因（"certificate has expired" 之类），
        # 比 urllib 那句 "CERTIFICATE_VERIFY_FAILED" 更好分诊；有就用它。
        LAST_ERROR = (result.stderr or "").strip() or LAST_ERROR
        return None
    return result.stdout


def fetch_version_data(budget, raws=(), url=None):
    return fetch_text(url or domains.selfupdate_latest_url(), budget, raws)


# 探针里的构建号字段名与已发布的 macwavedata/latest.toml 一致（`build_number`）。
# `build` 只作为读入时的兜底，不再写进任何文档或数据。
BUILD_KEYS = ("build_number", "build")


def data_build(data):
    """探针里的构建号；两个键都认，是为了不因为一次改名把已有数据读丢。"""
    for key in BUILD_KEYS:
        value = data.get(key, "")
        if value:
            return value
    return ""


# 指针可以用 selfupdate = "blocked" 声明「不要用自更新装进这一版」。
#
# 只留给真正做不到的情形（布局变更到 prune 也不敢自动删、需要新解释器、换了仓库或
# 分支、给老版本线的回溯修复包）。**缺省是允许** —— 字段缺失、写错、值为空，一律按
# 允许处理：一个笔误不该让所有客户端卡死。
#
# 它描述的是「装进这一版」这件事，不是「这一版能不能跑」：`install.sh` 直接装同一版
# 完全不受影响。
BLOCKED_VALUE = "blocked"

# 声明 blocked 时要给用户的出路。与安装文档、官网写的是同一条命令。
INSTALL_URL = "https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh"
INSTALL_TIMEOUT = "--max-time 60"


def selfupdate_blocked(data):
    """这份指针有没有声明「不能通过自更新装进去」。返回 (是否阻止, 原因)。"""
    raw = str(data.get("selfupdate", "") or "").strip().lower()
    if raw != BLOCKED_VALUE:
        return False, ""
    reason = str(data.get("selfupdate_reason", "") or "").strip()
    return True, reason


def refuse_blocked(current, latest, reason):
    """目标版本声明了 blocked：不下载任何东西，说清原因与出路。"""
    print(f"{YELLOW}🌊 The newest release ({latest}) cannot be installed with selfupdate.{RESET}")
    if reason:
        print(f"{YELLOW}🌊 Why       {reason}{RESET}")
    print(f"{YELLOW}🌊 Next      run the installer once; it replaces every file:{RESET}")
    print(f"{YELLOW}🌊           /bin/bash -c \"$(curl -fsSL {INSTALL_TIMEOUT} {INSTALL_URL})\"{RESET}")
    print(f"{GREEN}🌊 Your current installation ({current or 'unknown'}) has not been changed.{RESET}")


def probe_is_newer(data, current, current_build):
    """这份探针里的版本比本机新吗（版本优先，版本相同看构建号）。"""
    return versioncompare.newer_release(data.get("version", ""), data_build(data),
                                        current, current_build)


def run_script(environment, overall_timeout):
    # 编排脚本（lib/selfupdate.sh）随安装树一起发布，文件下载由它再去取
    # macwavedata/<版本>/update_commands.sh 完成。
    #
    # **必须从临时副本执行**：更新过程会覆盖 lib/selfupdate.sh 自己，而 bash 是
    # 边读边执行的，被覆盖的正文会让运行中的脚本读到半截内容。复制一份再跑，
    # 覆盖就发生在「已经读完的副本」之外，不影响本次执行。
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "selfupdate.sh")

    print("🌊 Preparing the update script for this version...")

    try:
        with open(source, encoding="utf-8") as stream:
            text = stream.read()
    except OSError:
        print(f"{RED_BOLD}🌊 Error: Cannot read the update script.{RESET}")
        print(f"{RED_BOLD}🌊 {source}{RESET}")
        sys.exit(1)

    handle, path = tempfile.mkstemp(prefix="macwave-selfupdate-", suffix=".sh")
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(text)
        return subprocess.run(['/bin/bash', path], env=environment, timeout=overall_timeout)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def version_data(text):
    # 4.0 的版本数据是 macwavedata/latest.toml，平铺的 key = "value"。
    # 3.x 那种「冒号 + 可选 update_command 块」的格式随 files_info 一起退休了。
    try:
        return domains.parse_simple_toml(text)
    except ValueError as error:
        print(f"{RED_BOLD}🌊 Error: The version data is not valid TOML ({error}).{RESET}")
        sys.exit(1)


# -------------------- 用户协议 --------------------
#
# 4.7 起**不再询问、也不再记录**同意：
#
#   * 全新安装时 install.sh 会问一次「Have you read and agreed …?」——
#     用户按下 y、程序继续，这本身就是同意。再把它写进磁盘读回来，只是给自己
#     制造一个「记录过期了要不要再问」的问题。
#   * 升级时用户执行 `wave selfupdate`，这本身就是选择继续使用新版本。
#
# 所以这里只留协议地址，用来在升级前说一句「协议在这儿」——
# 没有闸门、没有 AGREEMENT.json、没有「已同意过」这种状态。
AGREEMENT_URL = "https://macwave.org/#agreement"


def print_agreement_notice():
    """升级前说一句协议地址。只说一次，不提问、不写文件。"""
    print(f"🌊 User agreement: {AGREEMENT_URL}")


# 版本比较只看一处（lib/versioncompare.py）。客户端版本是发布时刻，用 client_key；
# 软件包版本走 pkg 那一套 —— 两者混用会得出「老客户端比新客户端新」。
version_key = versioncompare.client_key

DRY_RUN_FLAG = "--dry-run"


def wants_dry_run(input_string):
    return DRY_RUN_FLAG in (input_string or "").split()


def report_dry_run(current, latest, data, options, overall_timeout,
                   channel=versioncompare.CHANNEL_STABLE, crossed=False):
    """`--dry-run`：把「会做什么」打印出来，然后什么都不做。

    只读：本地版本、刚取到的版本数据、命令行里的旗标。**不**问协议、**不**写
    AGREEMENT.json、**不**建临时脚本、**不**跑 selfupdate.sh —— 所以它在任何机器上
    都能安全地跑一遍（代价只有一次取 latest.toml 的 GET）。
    """
    budget = options.timeouts

    def line(label, text):
        print(f"🌊   {label:<12} {text}")

    print(f"🌊 Dry run: MacWave would be updated from {current or 'unknown'} to {latest}.")

    if channel == versioncompare.CHANNEL_PREVIEW:
        line("channel", "preview (follows prerelease/latest.toml)")
    else:
        line("channel", "stable")
    if data_build(data):
        line("build", data_build(data))
    if crossed:
        line("switch", "preview → stable as a *full* install (every file replaced)")
    blocked, blocked_reason = selfupdate_blocked(data)
    if blocked:
        line("selfupdate", "blocked by this release" + (f": {blocked_reason}" if blocked_reason else "")
             + " — run the installer instead")
    if data.get("branch"):
        line("branch", data["branch"])
    # 4.7 起不问也不记：安装时按过一次 y 就算同意，升级是用户主动执行的动作。
    line("agreement", f"not asked (notice only): {AGREEMENT_URL}")
    line("skip-ssl", "on" if tls.enabled() else "off")
    raws = ", ".join(f"{flag} {value}" for flag, value in options.timeout_raws.items())
    line("timeouts", f"connect {budget.connect:g}s, content {budget.content:g}s, "
                     f"total {budget.total:g}s" + (f" (from {raws})" if raws else " (defaults)"))
    if options.install_python_from_source:
        line("python", "fetched from its upstream URL")
    line("script", f"a temporary copy of lib/selfupdate.sh, overall timeout {overall_timeout}s")

    print(f"{GREEN}🌊 Nothing was downloaded and nothing was changed.{RESET}")




# -------------------- 主流程 --------------------

def handle_selfupdate(input_string=""):
    if internal_state_dir() is None:
        print(f"{RED_BOLD}🌊 Error: MacWave is not installed at "
              f"{load_base_dir()}. Run lib/install.sh first.{RESET}")
        sys.exit(1)

    # 自更新会替换安装树里的程序文件：与装包/卸载互斥，否则两边同时写 pkg/ 与 lib/。
    # --dry-run 只看不动，不占锁。
    if wants_dry_run(input_string):
        return _handle_selfupdate_locked(input_string)
    from lock import tree_lock
    with tree_lock("selfupdate"):
        return _handle_selfupdate_locked(input_string)


def _handle_selfupdate_locked(input_string=""):

    # 先看本机装的是什么，再决定要不要联网 —— 判断渠道不需要网络，
    # 早退一步就少一次「Fetching the latest version...」之后的失败。
    #
    # 渠道是**这棵树跟的是哪条流**，记在 <base>/var/config.sh 的 MACWAVE_CHANNEL 里。
    # 1.0 起版本号是发布时刻，没有再能从版本串推出渠道的后缀。
    current = installed_version()
    current_build = installed_build()
    channel = versioncompare.normalize_channel(installed_channel())

    options = options_from(input_string)
    timeout_raws = options.timeout_raws
    budget = options.timeouts
    install_python_from_source = options.install_python_from_source
    dry_run = wants_dry_run(input_string)

    print("🌊 Fetching the latest version...")

    data = None
    crossed_stream = False
    if channel == versioncompare.CHANNEL_PREVIEW:
        text = fetch_version_data(budget, timeout_raws,
                                  domains.selfupdate_prerelease_latest_url())
        if text is not None:
            candidate = version_data(text)
            if probe_is_newer(candidate, current, current_build):
                data = candidate
            # 否则预发布流没有更新的构建，接着看正式版 —— 预发布收尾之后，
            # 正式版就是出路（走全量，见下面 MACWAVE_FULL_INSTALL）。

    if data is None:
        stable_url = domains.selfupdate_latest_url()
        text = fetch_version_data(budget, timeout_raws, stable_url)
        if text is None:
            print(f"{RED_BOLD}🌊 Error: Cannot reach the MacWave version data.{RESET}")
            print(f"{RED_BOLD}🌊 {domains.redact_url(stable_url)}{RESET}")
            # 证书过期 / 自签 / 链不完整 / 主机名不匹配 / 纯网络：五种的下一步不同
            explained = tls.explain(LAST_ERROR, stable_url)
            if explained is not None:
                for index, line in enumerate([explained[0]] + explained[1]):
                    prefix = "🌊 Next      " if index == 0 else "🌊           "
                    print(f"{RED_BOLD}{prefix}{line}{RESET}")
            sys.exit(1)
        data = version_data(text)
        crossed_stream = (channel == versioncompare.CHANNEL_PREVIEW
                          and probe_is_newer(data, current, current_build))
    latest = data.get("version", "")
    latest_build = data_build(data)
    if not latest:
        print(f"{RED_BOLD}🌊 Error: The version data has no 'version' field.{RESET}")
        sys.exit(1)

    if channel == versioncompare.CHANNEL_PREVIEW:
        print("🌊 Channel: preview — updates follow prerelease/latest.toml")
    else:
        print("🌊 Channel: stable")
    print(f"🌊 Latest version found: {latest}"
          + (f" (build {latest_build})" if latest_build else ""))

    if not probe_is_newer(data, current, current_build):
        where = f"build {current_build}" if current_build else "no build number"
        print(f"{GREEN}🌊 MacWave is already up to date (current: {current}, {where}).{RESET}")
        if dry_run:
            print("🌊 Dry run: nothing would be downloaded or changed.")
        sys.exit(0)

    # 目标版本声明了 blocked：新版确实存在，但不能用自更新装进去。这不是错误，
    # 是「换一种装法」，所以退出码是 0 —— 与「已是最新」同一个语义层。
    blocked, blocked_reason = selfupdate_blocked(data)
    if blocked:
        refuse_blocked(current, latest, blocked_reason)
        sys.exit(0)

    if channel == versioncompare.CHANNEL_PREVIEW and not crossed_stream:
        print("🌊 The preview channel has no newer build, and the stable release is not newer either.")

    if crossed_stream:
        print(f"{YELLOW}🌊 The preview channel has no newer build; the stable release "
              f"{latest} is newer.{RESET}")
        print(f"{YELLOW}🌊 Moving to it as a full install: every file is replaced, so no "
              f"preview and stable files end up in the same tree.{RESET}")

    # 试运行在**问协议之前**结束：它既不该弹询问，也不该写 AGREEMENT.json。
    # 这一段的判断全是只读的（版本比较、协议是否已记录）。
    if dry_run:
        report_dry_run(current, latest, data, options,
                       max(UPDATE_TIMEOUT, int(budget.total) * 20),
                       channel=versioncompare.CHANNEL_STABLE if crossed_stream else channel,
                       crossed=crossed_stream)
        sys.exit(0)

    # 「确实要更新」之后才问协议：没东西可装的时候不打扰人。
    # 也正因为这个位置，问的是「要不要跨过这道门槛去做这次更新」——
    # 与协议第 2 条给的选项（放弃更新 / 继续用已同意的那一版）对得上。
    # 只提示，不提问：同意已由「安装时按 y」或「主动执行本次升级」表达。
    print_agreement_notice()

    if current:
        print(f"🌊 Updating MacWave from {current} to {latest}...")
    else:
        print(f"{YELLOW}🌊 No installed version found, updating to {latest}...{RESET}")

    # 分支与目标版本通过环境变量传给 selfupdate.sh，避免脚本自己去猜。
    # --max-time 也这样传：原样传文本，让脚本自己解析（它才是真正发请求的那一层）。
    #
    # 安装根不传：它是写死的（config/platforminfo.py），脚本自己就知道，
    # 不必再靠环境变量捎带 —— 脚本会被复制到临时目录执行，传一个值反而多一处漂移。
    environment = dict(os.environ)
    environment["MACWAVE_UPDATE_VERSION"] = latest
    # 编排脚本还要自己取一份 latest.toml（验签与哈希都对着那份），所以渠道也得传，
    # 否则它会去读正式版探针，验的是另一份数据。
    environment["MACWAVE_UPDATE_CHANNEL"] = (
        versioncompare.CHANNEL_STABLE if crossed_stream else channel)
    if latest_build:
        environment["MACWAVE_UPDATE_BUILD"] = latest_build
    if crossed_stream:
        # 跨流必须全量：增量按目标分支的文件列表铺，盖在预发布树上就是两条线混装。
        environment["MACWAVE_FULL_INSTALL"] = "1"
    if data.get("branch"):
        environment["MACWAVE_UPDATE_BRANCH"] = data["branch"]
    if install_python_from_source:
        # 解释器默认从我们自己的 Python 仓库取；这个开关让 selfupdate.sh 回上游取
        environment["MACWAVE_INSTALL_PYTHON_FROM_SOURCE"] = "1"
    # 三档超时原样交给脚本，由它自己再解析一次
    for flag, value in timeout_raws.items():
        environment[TIMEOUT_ENV[flag]] = value
    if tls.enabled():
        # 脚本里的 curl 也要知道：-k 与 requests 的 verify=False 同义
        environment["MACWAVE_SKIP_SSL"] = "1"

    # 一轮更新要串行下载十几个文件，每个最多重试几次；单次超时被调大时，
    # 整体上限也要跟着放大，否则会在一半的地方被这里杀掉。
    overall_timeout = max(UPDATE_TIMEOUT, int(budget.total) * 20)

    try:
        result = run_script(environment, overall_timeout)
    except subprocess.TimeoutExpired:
        print(f"{RED_BOLD}🌊 Error: The update command timed out.{RESET}")
        sys.exit(1)

    if result.returncode != 0:
        print(f"{RED_BOLD}🌊 Error: The update command failed (exit code {result.returncode}).{RESET}")
        sys.exit(1)

    # 下载由 update_commands.sh 完成，它可能在某些路径上吞掉非零退出码，
    # 所以这里以树内状态（var/config.sh）的实际内容为准，避免误报成功
    final = installed_version()
    final_build = installed_build()
    reached = bool(final) and version_key(final) >= version_key(latest) and (
        version_key(final) != version_key(latest)
        or not versioncompare.is_newer_build(latest_build, final_build))
    if not reached:
        print(f"{RED_BOLD}🌊 Error: The update did not complete (still on "
              f"{final or 'unknown'}"
              f"{f', build {final_build}' if final_build else ''}).{RESET}")
        sys.exit(1)

    print("")
    print(f"{GREEN}🌊 MacWave has been updated to {final}"
          f"{f' (build {final_build})' if final_build else ''}!{RESET}")

    # wave.py 会被覆盖，但当前进程已经加载完了，直接退出即可
    sys.exit(0)


if __name__ == "__main__":
    handle_selfupdate()
