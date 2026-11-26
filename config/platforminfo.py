#!/usr/bin/env python3

# platforminfo.py
#
# **本仓库唯一允许判断平台的地方。**
#
# 合并 MacWave / LinuxWave 时最容易发生的退化是「这里加个 if darwin」——于是平台判断
# 从一处扩散到几十处，谁也不知道哪些路径在 Linux 上没测过。所以定一条规矩：
#
#   * 只有这个文件可以出现 `sys.platform`；
#   * 别的差异一律走**能力探测**（`shutil.which("patchelf")`）或**文件类型判定**
#     （Mach-O / ELF 的 magic），而不是"当前是什么系统"；
#   * CI 用 `scripts/shell_lint.sh` 之外的一条 grep 守住（见 docs/MERGE-STATUS.md）。
#
# 这个文件应当**一直很小**：目前只有三样东西是"平台值"而不是"能力"。

import platform
import sys

IS_MAC = sys.platform == "darwin"
IS_LINUX = sys.platform.startswith("linux")

# 默认安装根。两个平台的共享安装位置不同，理由见 docs 里「共享安装放在哪里」：
# macOS 用 /opt（没人占的空地、不受 SIP 保护）；Linux 用服务账户的家目录。
DEFAULT_BASE_DIR = "/opt/macwave" if IS_MAC else "/home/linuxwave/.linuxwave"


def system_version():

    # 本机系统版本号（字符串）。macOS 的 min_os 需要它；其它平台没有这个概念。
    # 读不到时返回空串 —— 调用方按"无法判断"处理，不要当成"版本 0"。

    if IS_MAC:
        return platform.mac_ver()[0] or ""
    return ""


def describe():

    # 给诊断输出用的一句话，例如 "macOS 15.5 (arm64)" / "Linux (x86_64)"。

    version = system_version()
    machine = platform.machine() or "unknown"
    name = "macOS" if IS_MAC else ("Linux" if IS_LINUX else platform.system())
    return f"{name} {version} ({machine})".replace("  ", " ")
