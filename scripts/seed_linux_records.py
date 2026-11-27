#!/usr/bin/env python3

# seed_linux_records.py —— 把 probe_linux_assets.py 探到的 Linux 资产写进索引。
#
# 一条 Linux 记录比 macOS 的简单得多：没有 min_os（那是 macOS 的 SDK 地板）、
# 没有 min_client_version（那是给 4.x 客户端设的闸门）、通常也没有 deps
# （上游的 Linux 产物要么静态链接，要么依赖发行版自带的 glibc/libstdc++）。
#
# 用法：
#   python3 scripts/seed_linux_records.py --assets /tmp/linux-assets.tsv \
#       --infosource ~/Projects/SummerwaveOrg/SeaLane            # 只看统计
#   python3 scripts/seed_linux_records.py ... --write             # 真写
#   python3 scripts/seed_linux_records.py ... --write --fetch-hashes
#
# --fetch-hashes：GitHub 的资产 digest 字段是近两年才有的，老 release 取不到。
# 那些行默认跳过（不写残缺记录），加上这个开关就去下载算一遍再写。

import argparse
import hashlib
import subprocess
import sys
import tempfile
from pathlib import Path


def existing(infosource, name, version, arch):
    return (Path(infosource) / name / f"_{name}@{version}.linux-{arch}").is_file()


def fetch_hash(url):
    """下载到临时文件算 sha256；失败返回空串。"""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "payload"
        result = subprocess.run(["curl", "-fsSL", "--http1.1", "--retry", "3",
                                 "--max-time", "600", "-o", str(out), url],
                                capture_output=True)
        if result.returncode != 0 or not out.is_file():
            return ""
        digest = hashlib.sha256()
        with out.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        return digest.hexdigest()


def record_text(url, filename, sha256):
    # 与 macOS 记录同一套 DSL：`字段: "值"`，一个字段一行。
    return (f'sha256: "{sha256}"\n'
            f'file: "{filename}"\n'
            f'url: "{url}"\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--assets", required=True)
    parser.add_argument("--infosource", required=True)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--fetch-hashes", action="store_true")
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    lines = Path(args.assets).read_text(encoding="utf-8").splitlines()[1:]
    rows = [line.split("\t") for line in lines if line.strip()]
    if args.limit:
        rows = rows[: args.limit]

    created, skipped_existing, skipped_hash, failed = 0, 0, 0, 0
    for name, version, arch, url, sha256, _size in rows:
        if existing(args.infosource, name, version, arch):
            skipped_existing += 1
            continue
        if not sha256:
            if not args.fetch_hashes:
                skipped_hash += 1
                continue
            sha256 = fetch_hash(url)
            if not sha256:
                failed += 1
                print(f"🌊   hash failed: {name}@{version} {arch}", file=sys.stderr)
                continue
        filename = url.split("/")[-1]
        text = record_text(url, filename, sha256)
        if args.write:
            target = Path(args.infosource) / name / f"_{name}@{version}.linux-{arch}"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
        created += 1

    verb = "wrote" if args.write else "would write"
    print(f"🌊 {verb} {created} record(s)")
    print(f"🌊   already present: {skipped_existing}")
    print(f"🌊   missing sha256:  {skipped_hash}"
          + ("" if args.fetch_hashes else "  (rerun with --fetch-hashes)"))
    if failed:
        print(f"🌊   download failed: {failed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
