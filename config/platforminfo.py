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
import re
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


# 瓶子标签的 os 一侧（arch 一侧见 _ARCH_ALIASES）。词表封闭，多一个就要审一遍
# 「客户端会不会因此去请求一个永远不存在的地址」。
BOTTLE_OSES = ("macos", "linux")
_ARCH_ALIASES = {"x86_64": "amd64", "amd64": "amd64", "x64": "amd64",
                 "arm64": "arm64", "aarch64": "arm64"}


# 对外承诺的支持范围：Apple Silicon 要 Sequoia 15，Intel 要 Monterey 12。
#
# 为什么按架构分而不是全库一个值：任何 Apple Silicon Mac 都跑得动 15，所以 15 这个
# 地板排除不了任何硬件，只排除「能升但不升」的人；而 Intel 侧由构建机的 SDK 决定
# （Ports 用一台 Monterey 12 的机器），天然就是 12，白捡了老 Intel Mac 的兼容面。
# 理由与构建侧的地板表见 Ports/README.md。
MIN_SUPPORTED_OS = {"arm64": (15, 0), "amd64": (12, 0)}


def arch_of(machine=None):
    """把 `uname -m` / `platform.machine()` 的值归一成 arm64 / amd64 / 原值。"""
    import platform as _platform

    raw = (machine or _platform.machine() or "").lower()
    return _ARCH_ALIASES.get(raw, raw or "unknown")


def minimum_supported_os(machine=None):
    """这台机器受支持的最低 macOS 版本，返回 (major, minor)。"""
    return MIN_SUPPORTED_OS.get(arch_of(machine), (0, 0))


def bottle_tag(machine=None, os_name=None):
    """0.1.0 的产物标签：`<os>-<arch>`，如 `macos-arm64` / `linux-amd64`。

    词表封闭（macos|linux、arm64|amd64）。客户端与索引生成脚本共用这一份，
    免得两边各写一遍正则；`x86_64` / `amd64` 归一成 `amd64`。
    os 取本模块的判断，机器类型默认取 `platform.machine()`（调用方有更权威的
    来源时可以传进来）。`os_name` 只给「为另一个平台造索引」的工具用
    （scripts/migrate_index_layout.py），取值必须在 BOTTLE_OSES 里。
    """
    import platform as _platform

    if os_name is not None and os_name not in BOTTLE_OSES:
        raise ValueError(f"unknown os {os_name!r}, expected one of {BOTTLE_OSES}")

    return f"{os_name or ('macos' if IS_MAC else 'linux')}-{arch_of(machine)}"


_BOTTLE_TAG_RE = re.compile(r"\.(?:macos|linux)-(?:arm64|amd64)$")


def strip_bottle_tag(text):
    """去掉记录名里的平台标签：`1.8.2.macos-arm64` → `1.8.2`。

    索引里的版本记录叫 `_<名>@<版本>.<os>-<arch>`，而逻辑版本号不含标签；
    读 `versions` 清单、解析命令行上的版本号时都要经过这里。
    """
    return _BOTTLE_TAG_RE.sub("", text)
