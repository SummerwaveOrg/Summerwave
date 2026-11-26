#!/usr/bin/env python3

# basedir.py
# `wave basedir` —— 打印 MacWave 的安装根目录。
#
# 安装根是**写死**的（config/platforminfo.py）：macOS 是 /opt/macwave，Linux 是
# /home/linuxwave/.linuxwave。没有配置文件可读，也没有 `--set` 可搬 —— 位置是
# 产品决定，不是用户配置。这条命令剩下的唯一用处是回答「包装在哪」：
# 排查问题、写脚本、卸载前确认目标。
#
# 两个形态：
#   wave basedir           → 🌊 /opt/macwave   （家目录下的路径会折成 ~）
#   wave basedir --raw     → /opt/macwave      （不折、不带 🌊，给脚本用）
#
# `--raw` 只去掉 🌊 与颜色，不改变内容 —— 与 `wave mirror --raw` 一致。
#
# 刻意不接 `-s/--silent`：这条命令存在的目的就是输出，静默它等于把命令废掉，
# 与 `wave list -s` 被拒绝是同一条理由（见 cli/silent.py 的说明）。真给了就明确
# 报错，而不是静默忽略 —— 被忽略时用户会以为「生效了、只是没输出」。

import sys

from configpaths import load_base_dir, to_tilde

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
RESET = '\033[0m'


def render(base_dir, raw=False):
    text = str(base_dir)
    if raw:
        # 不折成 ~：`~` 只在词首且未加引号时才展开，
        # `cd "$(wave basedir --raw)"` 会把它当字面量。脚本要的是绝对路径。
        return text
    return f"🌊 {to_tilde(text)}"


def parse_args(words):
    raw = False
    index = 0
    while index < len(words):
        word = words[index]
        if word == "--raw":
            raw = True
        elif word == "--set" or word.startswith("--set="):
            sys.stderr.write(f"{RED_BOLD}🌊 Error: --set has been removed{RESET}\n")
            sys.stderr.write(
                f"{GREEN}🌊 The install directory is fixed at {load_base_dir()}; "
                f"it cannot be moved{RESET}\n")
            sys.exit(1)
        elif word in ("-n", "--dry-run"):
            sys.stderr.write(f"{RED_BOLD}🌊 Error: {word} only made sense with --set{RESET}\n")
            sys.stderr.write(f"{GREEN}🌊 wave basedir [--raw]{RESET}\n")
            sys.exit(1)
        elif word in ("-s", "--silent", "-S", "--show-error"):
            sys.stderr.write(f"{RED_BOLD}🌊 Error: {word} cannot be used with basedir{RESET}\n")
            sys.stderr.write(
                f"{GREEN}🌊 basedir always prints a path; use --raw for the bare value{RESET}\n")
            sys.exit(1)
        else:
            sys.stderr.write(f"{RED_BOLD}🌊 Error: unknown option {word}{RESET}\n")
            sys.stderr.write(f"{GREEN}🌊 wave basedir --help{RESET} lists the flags it accepts\n")
            sys.exit(1)
        index += 1
    return raw


def handle_basedir(input_string=""):
    words = input_string.split()
    # 分发层传进来的是 "wave basedir …"，把头两个词剥掉
    if words and words[0] == "wave":
        words = words[1:]
    if words and words[0] == "basedir":
        words = words[1:]

    print(render(load_base_dir(), raw=parse_args(words)))
    return 0


if __name__ == "__main__":
    sys.exit(handle_basedir())
