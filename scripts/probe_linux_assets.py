#!/usr/bin/env python3

# probe_linux_assets.py —— 为已有的 macOS 记录找同一个 release 里的 Linux 产物。
#
# 为什么从 macOS 记录的 `url:` 出发，而不是从 census.tsv 的 source 列：那条 url 已经
# 精确指向「哪一个 release 的哪一个资产」，把它解析成 <owner>/<repo>/<tag> 就免去了
# 「猜这个包对应哪个 tag」—— 而猜 tag 是这类工具最容易出错的地方（v1.2.3 / 1.2.3 /
# jq-1.8.2 / release-1.2.3 四种写法都真实存在）。
#
# 用法：
#   python3 scripts/probe_linux_assets.py --infosource ~/Projects/SummerwaveOrg/SeaLane \
#       --out /tmp/linux-assets.tsv [--limit 20] [--jobs 8]
#
# 输出 TSV（表头固定）：
#   name\tversion\tarch\turl\tsha256\tsize
#
# sha256 取 GitHub 资产的 `digest` 字段（`sha256:…`）。取不到就留空 —— 那种记录
# 下一步会自己下载算，不在这里猜。

import argparse
import concurrent.futures
import json
import re
import subprocess
import sys
from pathlib import Path

# 一个 release 里往往有十几个平台。判据必须「先排除别的平台，再看是不是目标平台」，
# 否则 `x86_64` 会把 darwin 的 x86_64 也算进来（几乎所有 Go 项目都发那个）。
NOT_LINUX = ("darwin", "macos", "osx", "apple", "windows", "win32", "win64",
             "freebsd", "openbsd", "netbsd", "android", "ios")
UNSUPPORTED_ARCH = ("armv6", "armv7", "armhf", "armel", "arm32", "i386", "i686",
                    "mips", "riscv", "ppc64", "s390x", "loong", "v2", "v3")
ARM64_HINTS = ("aarch64", "arm64")
AMD64_HINTS = ("x86_64", "amd64", "x64", "linux64")
# 明显不是可安装产物的东西
NOT_PAYLOAD = (".deb", ".rpm", ".apk", ".sig", ".asc", ".sha256", ".sha256sum",
               ".txt", ".json", ".sbom", ".pem", ".cert", ".intoto.jsonl")

URL_RE = re.compile(r"^https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/releases/download/(?P<tag>[^/]+)/")


def classify(asset_name):
    """这个资产属于哪个 Linux 架构；不属于返回 None。"""
    n = asset_name.lower()
    if any(hint in n for hint in NOT_LINUX):
        return None
    if any(hint in n for hint in UNSUPPORTED_ARCH):
        return None
    if not n.endswith(NOT_PAYLOAD) and any(hint in n for hint in NOT_PAYLOAD):
        return None
    # 「linux」必须出现，或者名字里带 .so/.tar.xz 这类同时又带架构提示。
    # 只靠架构提示不够：`tool_x86_64` 可能是 FreeBSD 的。
    if "linux" not in n:
        return None
    if any(hint in n for hint in ARM64_HINTS):
        return "arm64"
    if any(hint in n for hint in AMD64_HINTS):
        return "amd64"
    return None


def gh_json(args):
    result = subprocess.run(["gh", "api"] + args, capture_output=True, text=True)
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def parse_release_url(url):
    match = URL_RE.match(url or "")
    if not match:
        return None
    return match.group("owner"), match.group("repo"), match.group("tag")


def read_records(infosource):
    """把索引里每条 macos 记录读成 (name, version, arch, url)。"""
    for path in sorted(Path(infosource).glob("*/*")):
        if not path.is_file() or not path.name.startswith("_"):
            continue
        match = re.match(r"^_(?P<name>.+)@(?P<version>.+)\.macos-(?P<arch>arm64|amd64)$", path.name)
        if not match:
            continue
        url = ""
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("url:"):
                url = line.split(":", 1)[1].strip().strip('"')
                break
        yield match.group("name"), match.group("version"), match.group("arch"), url


def probe(item):
    name, version, arch, url = item
    target = parse_release_url(url)
    if target is None:
        return []
    owner, repo, tag = target
    data = gh_json([f"repos/{owner}/{repo}/releases/tags/{tag}"])
    if not data or "assets" not in data:
        return []
    found = {}
    for asset in data["assets"]:
        which = classify(asset["name"])
        if which is None or which in found:
            continue
        digest = (asset.get("digest") or "")
        found[which] = (asset["browser_download_url"],
                        digest.split(":", 1)[1] if digest.startswith("sha256:") else "",
                        asset.get("size", 0))
    return [(name, version, which, *found[which]) for which in found]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--infosource", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()

    # 同一个包有 arm64 / amd64 两条记录，url 相同 —— 只探一次就够
    seen, items = set(), []
    for item in read_records(args.infosource):
        key = (item[0], item[1])
        if key in seen:
            continue
        seen.add(key)
        items.append(item)
    if args.limit:
        items = items[:args.limit]

    print(f"🌊 probing {len(items)} package version(s) for Linux assets", flush=True)
    rows, hits, dry = [], 0, 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for index, result in enumerate(pool.map(probe, items), 1):
            if result:
                hits += 1
                rows.extend(result)
            else:
                dry += 1
            if index % 20 == 0:
                print(f"🌊   {index}/{len(items)}  matched={hits} none={dry}", flush=True)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8") as handle:
        handle.write("name\tversion\tarch\turl\tsha256\tsize\n")
        for row in sorted(rows):
            handle.write("\t".join(str(field) for field in row) + "\n")

    print(f"🌊 {len(rows)} asset(s) across {hits} package version(s); "
          f"{dry} had no Linux asset")
    print(f"🌊 wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
