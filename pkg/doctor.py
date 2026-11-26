#!/usr/bin/env python3

# doctor.py

# `wave doctor` —— 只读体检：把安装树里「已经坏了、但平时没人会发现」的地方找出来。
#
# 为什么需要：真出问题时用户看到的是下游症状 —— `jq: command not found`、
# `dyld: Library not loaded`、`wave uninstall x` 说「没装」。原因可能是一周前一次
# 被打断的安装，而那时没有任何东西提醒过。这里把这几种状态集中检查一遍。
#
# 设计上的三条：
#
#   1. **只读**。不修、不删、不改字节。每条发现后面给出该跑哪条 `wave` 命令 ——
#      与 `brew doctor` 学到的最有用的一点：发现的价值在于「下一步做什么」。
#   2. **退出码 = 发现的问题数**，0 表示全绿。可以进脚本、进 CI。
#   3. **拿不准就说拿不准**。唯一需要外部工具的判断记成 note，不当成坏包。
#
# 位置无关性（4.x 的 `wave transfer` / `transfer.sh --check`）不再检查：1.0 起
# 重定位只在打包时做（scripts/relocate_rpath.py），运行时没有可查的偏差来源。

import os
import sys

from configpaths import bin_dir, load_base_dir, payload_root
from receipt import read_note
import silent

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'

BASE_DIR = load_base_dir()
# 1.0 起：PAYLOAD 是解开的包（<根>/Shore/<名>/<版本>），BIN_DIR 只放链接。
PAYLOAD = payload_root()
BIN_DIR = bin_dir()
DOWNLOAD_TMP = BASE_DIR / "downloads" / "tmp"
COMPONENTS = ("cli", "config", "lib", "net", "pkg", "surfboard")
TREE_MARKER = ".is_a_tree"


# -------------------- 发现 --------------------

class Finding:
    """一条发现。severity 只有两档：problem 计入退出码，note 只是提醒。"""

    def __init__(self, check, text, fix="", severity="problem"):
        self.check = check
        self.text = text
        self.fix = fix
        self.severity = severity

    def line(self):
        return f"{self.text} — {self.fix}" if self.fix else self.text


def _installed_dirs():
    """[(包名, 版本)]，按名字排序。看 Shore/<名>/<版本> 这一层。"""
    if not PAYLOAD.is_dir():
        return []
    pairs = []
    for name in sorted(os.listdir(str(PAYLOAD))):
        package = PAYLOAD / name
        if not package.is_dir():
            continue
        for version in sorted(os.listdir(str(package))):
            if (package / version).is_dir():
                pairs.append((name, version))
    return pairs


def _highest(versions):
    from versioncompare import get_max_version
    return get_max_version(versions)


# -------------------- 检查项 --------------------

def check_base_dir():
    """安装根存在、可写 —— 「装不上包」最常见的原因是这里。"""
    findings = []
    if not BASE_DIR.is_dir():
        return [Finding("base-dir", f"install root {BASE_DIR} is missing",
                        "run the installer again (lib/install.sh)")]
    if not os.access(str(BASE_DIR), os.W_OK):
        findings.append(Finding("base-dir", f"install root {BASE_DIR} is not writable",
                                "fix the permissions of that directory, or run "
                                "'sudo <base>/lib/wave doctor'"))
    return findings


def check_tree():
    """六个组件目录齐不齐 —— 缺一个就是半装状态，wave 会 ImportError。"""
    missing = [name for name in COMPONENTS if not (BASE_DIR / name).is_dir()]
    if not missing:
        return []
    return [Finding("tree", f"component(s) missing from the install tree: {', '.join(missing)}",
                    "run 'wave selfupdate' to repair the install tree")]


def check_installed():
    """每个 Shore/<名>/<版本>/ 里真的有那个可执行文件吗。"""
    findings = []
    for name, version in _installed_dirs():
        directory = PAYLOAD / name / version
        note = read_note(directory)
        if note is not None and not note.get("requested", True):
            # 依赖树：里面的东西是库与自己的 bin/，不保证有同名可执行文件。
            continue
        if (directory / TREE_MARKER).is_file():
            target = directory / "bin" / name
        else:
            target = directory / name
        if target.exists():
            continue
        findings.append(Finding("installed", f"{name}@{version} has no {target.name}",
                                f"wave reinstall {name}@{version}"))
    for name, version in _installed_dirs():
        if version.endswith(".bak"):
            findings.append(Finding("installed", f"leftover backup directory Shore/{name}/{version}",
                                    "delete it once you are sure the package works"))
    return findings


def check_links():
    """bin/ 里的悬空链接，以及该有却没有的不带版本号链接。"""
    findings = []
    if not BIN_DIR.is_dir():
        if _installed_dirs():
            findings.append(Finding("links", "the bin/ directory is missing",
                                    "wave link --all"))
        return findings

    linked = {}
    for entry in sorted(os.listdir(str(BIN_DIR))):
        path = BIN_DIR / entry
        if not path.is_symlink():
            continue
        if not os.path.exists(str(path)):
            findings.append(Finding("links", f"bin/{entry} points at something that is gone",
                                    f"wave link {entry.partition('@')[0]}"))
            continue
        if "@" in entry:
            continue
        linked[entry] = os.readlink(str(path))

    by_name = {}
    for name, version in _installed_dirs():
        note = read_note(PAYLOAD / name / version)
        if note is not None and not note.get("requested", True):
            # 依赖树不要求有不带版本号的链接：它进 PATH 的东西由依赖它的包决定。
            continue
        by_name.setdefault(name, []).append(version)
    for name, versions in sorted(by_name.items()):
        if name in linked:
            continue
        findings.append(Finding("links", f"{name} is installed but has no unversioned link",
                                f"wave link {name}"))
    return findings


def check_dependencies():
    """Shore/ 里没有一个 .depped_* 标记的依赖树（没人引用它了）。"""
    findings = []
    for owner, entry in _installed_dirs():
        version_dir = PAYLOAD / owner / entry
        marks = [name for name in os.listdir(str(version_dir))
                 if name.startswith(".depped_")]
        if marks:
            continue
        note = read_note(version_dir)
        if note is None or note.get("requested", True):
            # 没有收据、或用户显式装的：都不该按「没人引用的依赖」报出来。
            continue
        findings.append(Finding("dependencies",
                                f"Shore/{owner}/{entry} is not referenced by anything",
                                f"wave uninstall {owner} (then it is removed with the "
                                f"package that pulled it in)"))
    return findings


def check_downloads():
    """下载暂存目录里的残渣。只是提醒：install/uninstall 会自己清理。"""
    if not DOWNLOAD_TMP.is_dir():
        return []
    partials = [name for name in os.listdir(str(DOWNLOAD_TMP)) if name.endswith(".partial")]
    if not partials:
        return []
    return [Finding("downloads",
                    f"{len(partials)} unfinished download(s) in downloads/tmp",
                    "they are removed automatically once they are 7 days old",
                    severity="note")]


CHECKS = (
    ("base-dir", check_base_dir, "install root exists and is writable"),
    ("tree", check_tree, "the six component directories are present"),
    ("installed", check_installed, "every version directory has its executable"),
    ("links", check_links, "unversioned links exist and point at something"),
    ("dependencies", check_dependencies, "no dependency tree is orphaned"),
    ("downloads", check_downloads, "downloads/tmp is not full of abandoned partials"),
)


# -------------------- 输出 --------------------

def _report(findings, raw=False):
    problems = [item for item in findings if item.severity == "problem"]
    if raw:
        for item in findings:
            print(f"{item.severity}\t{item.check}\t{item.line()}")
        return problems

    if not findings:
        print(f"{GREEN}🌊 No problems found in {len(CHECKS)} checks.{RESET}")
        return problems

    for check, _function, _description in CHECKS:
        current = [item for item in findings if item.check == check]
        if not current:
            continue
        print(f"🌊 {check}")
        for item in current:
            colour = RED_BOLD if item.severity == "problem" else YELLOW
            print(f"{colour}🌊   {item.text}{RESET}")
            if item.fix:
                print(f"🌊   fix: {item.fix}")

    notes = len(findings) - len(problems)
    summary = f"{len(problems)} problem(s) found"
    if notes:
        summary += f", {notes} note(s)"
    print()
    print(f"{RED_BOLD}🌊 Doctor: {summary}.{RESET}" if problems
          else f"{YELLOW}🌊 Doctor: no problems, {notes} note(s).{RESET}")
    return problems


# -------------------- 命令入口 --------------------

def handle_doctor(input_string=""):
    words = input_string.split()[2:]

    if "--list-checks" in words:
        for name, _function, description in CHECKS:
            print(f"{name}\t{description}")
        return

    raw = "--raw" in words
    for word in words:
        if word.startswith("-") and word not in ("--raw", "--list-checks"):
            print(f"{RED_BOLD}🌊 Error: unknown flag '{word}'.{RESET}")
            print(f"{RED_BOLD}🌊 Try: wave doctor [--raw] [--list-checks]{RESET}")
            sys.exit(1)

    if not raw:
        silent.say(f"🌊 Examining {BASE_DIR} ...")

    findings = []
    for name, function, _description in CHECKS:
        selected = [word for word in words if not word.startswith("-")]
        if selected and name not in selected:
            continue
        if not raw:
            silent.say(f"🌊 Checking {name} ...")
        findings.extend(function())

    problems = _report(findings, raw=raw)
    sys.exit(len(problems))


if __name__ == "__main__":
    handle_doctor(" ".join(sys.argv[1:]))
