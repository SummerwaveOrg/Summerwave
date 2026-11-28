#!/usr/bin/env python3

# tsv_from_prebuilt.py
#
# 从一个产物目录反推出 prepare_bottle 的 `--tsv` 格式（kind/name/version/arch/file/sha256），
# 让 apply_rebuilt_records.py 能照常回填索引。
#
# 为什么需要它：`batch_linux_payloads.sh` 调 prepare_bottle 时**没有传 --tsv**，
# 于是批量跑完之后手上只有一堆 .tar.bz2，没有那张「谁对应哪条记录、sha256 是多少」
# 的流水账。这批产物动辄上百个，逐条手抄不现实；而 sha256 必须现场算 —— 索引里
# 那份是重打**之前**的，早就过期了。
#
# ⚠️ 必须在**上传之前**跑：上传脚本是「传一个删一个」，文件没了就算不出 sha256。
#
# 用法：
#   python3 scripts/tsv_from_prebuilt.py --dir ~/MacWaveOrg/bottle-1.0/macos-prebuilt \
#       --os macos --out ~/MacWaveOrg/bottle-1.0/macos-records.tsv
#
# 之后：
#   python3 scripts/apply_rebuilt_records.py --tsv <上面的 out> \
#       --prebuilt <同一个目录> --os macos --apply

import argparse
import hashlib
import re
import sys
from pathlib import Path

# act@0.2.98.macos-amd64.tar.bz2 → (act, 0.2.98, macos-amd64)
NAME_RE = re.compile(r"^(?P<name>.+?)@(?P<version>.+?)\.(?P<tag>(?:macos|linux)-(?:arm64|amd64))"
                     r"\.tar\.bz2$")


def sha256_of(path, chunk=1 << 20):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            block = handle.read(chunk)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Generate a prepare_bottle style --tsv "
                                                 "from an existing prebuilt directory.")
    parser.add_argument("--dir", required=True, type=Path, help="产物目录")
    parser.add_argument("--out", required=True, type=Path, help="写出的 tsv")
    parser.add_argument("--kind", default="pkg", choices=("pkg", "deps"))
    parser.add_argument("--os", default="", choices=("", "macos", "linux"),
                        help="只收这个平台的产物（空=都要）")
    args = parser.parse_args()

    if not args.dir.is_dir():
        print(f"🌊 Error: {args.dir} 不是一个目录", file=sys.stderr)
        return 2

    files = sorted(args.dir.glob("*.tar.bz2"))
    if not files:
        print(f"🌊 Error: {args.dir} 里没有 .tar.bz2", file=sys.stderr)
        return 2

    rows = []
    skipped = []
    for path in files:
        match = NAME_RE.match(path.name)
        if not match:
            skipped.append(path.name)
            continue
        tag = match.group("tag")
        if args.os and not tag.startswith(args.os + "-"):
            continue
        arch = tag.split("-", 1)[1]
        rows.append((args.kind, match.group("name"), match.group("version"),
                     arch, path.name, sha256_of(path)))

    if not rows:
        print("🌊 Error: 没有匹配的文件", file=sys.stderr)
        return 2

    lines = ["kind\tname\tversion\tarch\tfile\tsha256"]
    lines += ["\t".join(row) for row in rows]
    args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"🌊 写出 {len(rows)} 行 → {args.out}")
    if skipped:
        print(f"🌊 跳过 {len(skipped)} 个不匹配命名的文件：")
        for name in skipped[:10]:
            print(f"   {name}")
        if len(skipped) > 10:
            print(f"   …… 另有 {len(skipped) - 10} 个")
    return 0


if __name__ == "__main__":
    sys.exit(main())
