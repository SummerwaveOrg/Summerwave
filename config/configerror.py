#!/usr/bin/env python3

# configerror.py

import sys
import subprocess

from configpaths import STATE_DIR_NAME, STATE_FILE_NAME, load_base_dir


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
YELLOW = '\033[33m'
RESET = '\033[0m'


# -------------------- 运行期依赖 --------------------

REQUIRED_MODULES = (
    ("requests", "HTTPS 请求"),
    ("packaging", "版本号比较"),
    ("rich", "下载进度条"),
)


def check_dependencies():
    # 在真正分发命令之前检查第三方依赖。
    # 换过 Python 解释器（例如 Homebrew 升级 python3）之后，这些包往往还在旧
    # 解释器下，命令会以各种奇怪的方式失败 —— 提前拦住并给出可执行的修复命令，
    # 比让某个子模块在导入阶段报「模块不可用」清楚得多。

    missing = []
    for name, purpose in REQUIRED_MODULES:
        try:
            __import__(name)
        except ImportError:
            missing.append(f"{name}（{purpose}）")

    if not missing:
        return

    print(f"{RED_BOLD}🌊 Error: Missing Python dependencies: {', '.join(missing)}.{RESET}")
    print(f"{RED_BOLD}🌊 The current interpreter cannot run Summerwave:{RESET}")
    print(f"{YELLOW}   {sys.executable}{RESET}")
    print(f"{RED_BOLD}🌊 Install them and try again:{RESET}")
    print(f"{YELLOW}   python3 -m pip install --user requests packaging rich{RESET}")
    print(f"{YELLOW}   (Homebrew's Python needs --break-system-packages){RESET}")
    sys.exit(1)


# -------------------- 环境检测与报错 --------------------

def check_environment():

    # 检测当前环境
    # - 安装根（写死的，见 config/platforminfo.py）里有 var/config.sh，说明已正式
    #   安装，正常继续。
    # - 没有，且当前在 git 仓库里，报错并退出。

    base_dir = load_base_dir()
    if (base_dir / STATE_DIR_NAME / STATE_FILE_NAME).is_file():
        return

    try:
        result = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0 or result.stdout.strip() != "true":
            return
    except Exception:
        return

    try:
        shallow_result = subprocess.run(
            ["git", "rev-parse", "--is-shallow-repository"],
            capture_output=True, text=True, timeout=5
        )
        is_shallow = shallow_result.stdout.strip() == "true"
    except Exception:
        is_shallow = False

    try:
        root_result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5
        )
        repo_root = root_result.stdout.strip()
    except Exception:
        repo_root = ""

    if is_shallow:
        print(f"{RED_BOLD}🌊 Error: Summerwave is a shallow clone!{RESET}")
    else:
        print(f"{RED_BOLD}🌊 Error: Summerwave is a git clone!{RESET}")

    config_paths = str(base_dir / STATE_DIR_NAME / STATE_FILE_NAME)

    print("")
    print(f"Summerwave is not distributed as a shallow clone. Instead, it uses install.sh to download various files to {base_dir}. Among other things, install.sh writes a state file to {config_paths}, which records the installed version. Without it, many programs will not be able to find the installation.")
    print("")
    if is_shallow:
        print("We have detected that you are using a shallow clone, which will cause Summerwave to fail to work properly. To continue using it, please run $ /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/SummerwaveOrg/Summerwave/HEAD/lib/install.sh)\". You can also run $ bash " + repo_root + "/lib/install.sh or $ /bin/bash " + repo_root + "/lib/install.sh to fully install Summerwave.")
    else:
        print("We have detected that you are using a git clone, which will cause Summerwave to fail to work properly. To continue using it, please run $ /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/SummerwaveOrg/Summerwave/HEAD/lib/install.sh)\". You can also run $ bash " + repo_root + "/lib/install.sh or $ /bin/bash " + repo_root + "/lib/install.sh to fully install Summerwave.")
    print("")
    print("If you are a collaborator of Summerwave, or if you cloned the source code for a specific purpose, please do not run it locally, or at least do not run it in the Git directory.")
    print("")
    print("If you have any other questions, please contact hi@macwave.org.")

    sys.exit(1)


if __name__ == "__main__":
    print("🌊 This module is not meant to be run directly.")
    print("🌊 It is used internally by wave.py.")
    sys.exit(1)
