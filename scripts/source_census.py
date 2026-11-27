#!/usr/bin/env python3

# source_census.py
# 把索引里每条记录「换成它上游的源码发布」这件事，做成一张可核对的表。
#
# 为什么需要：索引里的 `url` 以前指向**别人编好的二进制**（conda、continuum、上游 release
# 里的 .tar.gz 资产），只有一部分指向源码。自建之后唯一的可信来源是「每个版本对应的
# sourcecode.tar.gz」，所以先要一条条确认：
#
#   1. 这条记录的上游仓库是哪个（能从现在的 url 推出来吗）；
#   2. 那个 tag 有没有源码包（有就记下最终地址）；
#   3. 源码树用的是什么构建系统（决定怎么编）。
#
# 三个问题一次答完：**只把源码包流式过一遍 `tar tz`，不落盘**，所以几百条也不会撑爆磁盘。
#
# 用法：
#   python3 scripts/source_census.py                       # 全量，输出到 stdout（TSV）
#   python3 scripts/source_census.py --out census.tsv --jobs 6
#   python3 scripts/source_census.py --only jq,htop
#
# 输出列：kind / name / version / build / source / note
#   build  = go | cargo | cmake | autotools | make | meson | unknown
#   source = 可用的源码包地址（推不出来时为空）
#   note   = 需要人看一眼的原因（third-party-only / tag-not-found / …）

import argparse
import concurrent.futures
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_INDEX = pathlib.Path.home() / "Projects/SummerwaveOrg/SeaLane"

GH_RELEASE = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/")
GH_RAW = re.compile(r"^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/")
# 构建系统的判定顺序：越专有越先判（一个仓库里常常同时有 CMakeLists 和 Makefile）
BUILD_MARKERS = [
    ("go", lambda names: any(n.endswith("/go.mod") or n == "go.mod" for n in names[:400])),
    ("cargo", lambda names: any(n.endswith("/Cargo.toml") or n == "Cargo.toml" for n in names[:400])),
    ("cmake", lambda names: any(n.endswith("/CMakeLists.txt") or n == "CMakeLists.txt" for n in names[:400])),
    ("meson", lambda names: any(n.endswith("/meson.build") or n == "meson.build" for n in names[:400])),
    # git archive 出来的源码包**没有** configure（那是生成物），只有 configure.ac /
    # Makefile.am，所以要认这两个；release 的 tarball 才会带现成的 configure。
    ("autotools", lambda names: any(n.rsplit("/", 1)[-1] in ("configure", "configure.ac", "Makefile.am")
                                   for n in names[:400])),
    ("make", lambda names: any(n.rsplit("/", 1)[-1] in ("Makefile", "makefile", "GNUmakefile") for n in names[:400])),
]


def records(index):
    """(kind, name, version, url) 一行一条，跳过 @common。"""
    # 单一命名空间：包与依赖都在仓库根，路径上不再区分 kind（这里统一记 "pkg"）
    if True:
        root = index
        for path in sorted(root.rglob("_*")):
            if path.name.endswith("@common"):
                continue
            match = re.match(r"_(.+)@([^@]+)\.macos-(arm64|amd64)$", path.name)
            if not match:
                continue
            name, version, _arch = match.groups()
            text = path.read_text(errors="replace")
            url = re.search(r'url:\s*"([^"]*)"', text)
            yield "pkg", name, version, (url.group(1) if url else "")


def source_candidates(name, version, url):
    """从记录里的 url 推源码包候选地址，按可信度排序。"""
    found = []
    match = GH_RELEASE.match(url)
    if match:
        owner, repo, tag = match.groups()
        for t in (tag, tag.lstrip("v"), "v" + tag.lstrip("v")):
            found.append(f"https://github.com/{owner}/{repo}/archive/refs/tags/{t}.tar.gz")
    else:
        match = GH_RAW.match(url)
        if match:
            owner, repo = match.groups()
            for t in (version, "v" + version, version.lstrip("v")):
                found.append(f"https://github.com/{owner}/{repo}/archive/refs/tags/{t}.tar.gz")
    return list(dict.fromkeys(found))


def probe(url, timeout=180):
    """流式取回源码包的成员名；失败返回 (None, 原因)。不落盘。"""
    # `tar tz` 只读头部，几百条也不会把磁盘写满；`--http1.1` 是这台机器上 github 的必需项
    shell = (f"curl -fsSL --http1.1 --retry 2 --max-time {timeout} {url!r} "
             f"| tar tz 2>/dev/null | head -400")
    result = subprocess.run(["bash", "-c", shell], capture_output=True, text=True)
    names = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if not names:
        return None, "unreachable-or-empty"
    return names, ""


def classify(names):
    for label, check in BUILD_MARKERS:
        if check(names):
            return label
    return "unknown"


def survey(item):
    kind, name, version, url = item
    for candidate in source_candidates(name, version, url):
        names, why = probe(candidate)
        if names:
            return kind, name, version, classify(names), candidate, ""
    if not source_candidates(name, version, url):
        host = re.sub(r"^https?://([^/]+).*", r"\1", url) or "no-url"
        return kind, name, version, "unknown", "", f"third-party-only ({host})"
    return kind, name, version, "unknown", "", "tag-not-found"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", default=str(DEFAULT_INDEX))
    parser.add_argument("--only", default="")
    parser.add_argument("--out", default="")
    parser.add_argument("--jobs", type=int, default=6)
    args = parser.parse_args()

    index = pathlib.Path(args.index)
    only = {s.strip() for s in args.only.split(",") if s.strip()}

    items = []
    seen = set()
    for kind, name, version, url in records(index):
        if only and name not in only:
            continue
        if (kind, name, version) in seen:
            continue
        seen.add((kind, name, version))
        items.append((kind, name, version, url))

    print(f"🌊 {len(items)} 条 name@version 待核对", file=sys.stderr, flush=True)

    rows = []
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for row in pool.map(survey, items):
            rows.append(row)
            done += 1
            print(f"🌊 [{done}/{len(items)}] {row[1]}@{row[2]} → {row[3]}"
                  f"{'  ⚠ ' + row[5] if row[5] else ''}", file=sys.stderr, flush=True)

    rows.sort()
    text = "kind\tname\tversion\tbuild\tsource\tnote\n" + "".join("\t".join(r) + "\n" for r in rows)
    if args.out:
        pathlib.Path(args.out).write_text(text)
        print(f"🌊 写到 {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
