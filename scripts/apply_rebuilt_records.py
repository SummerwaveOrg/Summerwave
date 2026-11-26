#!/usr/bin/env python3

# apply_rebuilt_records.py
#
# 把 prepare_bottle.py 重打出来的产物写回索引记录：`file` 与 `sha256` 换成新产物的那一份，
# 并补上 `relocated: "loader_path"`；安装形态按**归档的实际形状**决定，不靠人记。
#
# 为什么需要它：重打必然改字节（重定位 + 前缀改写），于是索引里的 `sha256` 立刻过期。
# 「上传资产」与「回填索引」必须成对完成，错位的症状是用户下到字节校验不过、
# 报「装到一半失败」，而索引本身看起来完全正常。
#
# 用法：
#   python3 scripts/apply_rebuilt_records.py --tsv ~/bottle-1.0/records.tsv \
#       --prebuilt ~/bottle-1.0/prebuilt --infosource ~/Projects/MacWaveOrg/infosource
#   …… 加上 --apply 才真的写；默认只报告。
#
# 安装形态的判据：
#   * 依赖（kind=deps）：不用管 —— 依赖安装器固定用 tree，记录里那个字段没人读；
#   * 软件包（kind=pkg）：归档里有 `bin/<bin_name>` 就是 tree；否则是单文件（binary），
#     此时把记录里的 `install:` 删掉（缺省即 binary）。

import argparse
import hashlib
import os
import re
import sys
import tarfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import components  # noqa: E402

components.add_to_sys_path()

import platforminfo  # noqa: E402  —— 记录名里的瓶子标签与客户端同源

DEFAULT_INFOSOURCE = Path.home() / "Projects" / "MacWaveOrg" / "infosource"

FIELD_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"(.*)"\s*$', re.M)


def record_path(infosource, kind, name, version, arch):
    root = "pkg/pkginfo" if kind == "pkg" else "deps/depsinfo"
    tag = platforminfo.bottle_tag(arch)
    return infosource / root / name / f"_{name}@{version}.{tag}"


def read_field(text, key):
    for match in FIELD_RE.finditer(text):
        if match.group(1) == key:
            return match.group(2)
    return None


def set_field(text, key, value):
    line = f'{key}: "{value}"'
    pattern = re.compile(rf'^{key}\s*:.*$', re.M)
    if pattern.search(text):
        return pattern.sub(line, text, count=1)
    if text and not text.endswith("\n"):
        text += "\n"
    return text + line + "\n"


def drop_field(text, key):
    return re.sub(rf'^{key}\s*:.*\n?', "", text, flags=re.M)


def archive_shape(path):
    """返回 (有没有 bin/<任意可执行>, 顶层文件列表)。"""
    top = []
    has_bin = False
    with tarfile.open(path) as archive:
        for member in archive:
            name = member.name
            if "/" not in name.rstrip("/"):
                if member.isfile():
                    top.append(name)
                continue
            if name.startswith("bin/") and member.isfile():
                has_bin = True
    return has_bin, top


def desired_install(kind, record_text, archive, name):
    """这个产物该用哪种安装形态；None 表示「记录里不用写这个字段」。"""
    if kind != "pkg":
        return None                     # 依赖由安装器固定用 tree
    has_bin, top = archive_shape(archive)
    if has_bin:
        return "tree"
    # 单文件上游：归档里就是那一个可执行文件，binary 模式会取到它
    return "" if top else None


def main():
    parser = argparse.ArgumentParser(
        description="Write rebuilt payload names/checksums back into the infosource records.")
    parser.add_argument("--tsv", required=True, type=Path,
                        help="the --tsv file prepare_bottle.py wrote")
    parser.add_argument("--prebuilt", required=True, type=Path,
                        help="directory holding the rebuilt archives")
    parser.add_argument("--infosource", default=str(DEFAULT_INFOSOURCE), type=Path)
    parser.add_argument("--apply", action="store_true", help="actually rewrite the records")
    parser.add_argument("--only", default="", help="comma separated package names")
    args = parser.parse_args()

    if not (args.infosource / "pkg" / "pkginfo").is_dir():
        print(f"🌊 Error: {args.infosource} does not look like the 1.0 index "
              f"(expected pkg/pkginfo/). Run migrate_index_layout.py first.")
        return 1

    only = {name.strip() for name in args.only.split(",") if name.strip()}

    rows = {}
    for line in args.tsv.read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) != 6 or fields[0] == "kind":
            continue
        kind, name, version, arch, filename, sha = fields
        rows[(kind, name, version, arch)] = (filename, sha)

    updated = unchanged = missing = broken = 0
    problems = []

    for (kind, name, version, arch), (filename, sha) in sorted(rows.items()):
        if only and name not in only:
            continue

        archive = args.prebuilt / filename
        record = record_path(args.infosource, kind, name, version, arch)

        if not archive.is_file():
            problems.append(f"{name}@{version}.{arch}: archive missing ({archive})")
            missing += 1
            continue
        if not record.is_file():
            problems.append(f"{name}@{version}.{arch}: no index record at {record}")
            missing += 1
            continue

        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != sha:
            problems.append(f"{name}@{version}.{arch}: archive sha256 {digest[:12]}… "
                            f"does not match the tsv ({sha[:12]}…)")
            broken += 1
            continue

        text = record.read_text(encoding="utf-8")
        before = text
        text = set_field(text, "file", filename)
        text = set_field(text, "sha256", digest)
        text = set_field(text, "relocated", "loader_path")
        install = desired_install(kind, text, archive, name)
        if install == "tree":
            text = set_field(text, "install", "tree")
        elif install == "":
            text = drop_field(text, "install")

        if text == before:
            unchanged += 1
            continue

        if args.apply:
            record.write_text(text, encoding="utf-8")
        updated += 1

    verb = "updated" if args.apply else "would update"
    print(f"🌊 {verb} {updated}, already current {unchanged}, "
          f"missing {missing}, broken {broken}")
    for problem in problems[:20]:
        print(f"  ❌ {problem}")
    if len(problems) > 20:
        print(f"  … and {len(problems) - 20} more")
    if not args.apply and updated:
        print("🌊 Re-run with --apply to write the records.")
    return 0 if not (missing or broken) else 1


if __name__ == "__main__":
    sys.exit(main())
