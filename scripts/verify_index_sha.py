#!/usr/bin/env python3

# verify_index_sha.py
#
# 终极核对：索引里每条记录声明的 sha256，必须等于 Release 上那个资产的**实际字节**。
#
# 为什么非做不可：客户端的安装流程是「下载 → 算 sha256 → 与记录比对 → 不符就中止」。
# 索引与资产一旦错位（传的是旧字节、或者根本没传上去），用户看到的是「下载完成但校验
# 失败」，而站点看起来一切正常 —— 2026-11-28 就踩过：45 个产物被一份过期的
# source-built-names.txt 挡着没上传，索引却已经指向它们。
#
# 走 api.github.com 的 assets/<id>：github.com/.../releases/download/ 在国内连不上，
# 而 assets 接口 302 到 objects.githubusercontent.com 是通的。带 gh 的 token 提限流额度。
#
# 用法：
#   python3 scripts/verify_index_sha.py                      # 全量（943 个 / ~10.6 GB）
#   python3 scripts/verify_index_sha.py --os macos            # 只查 macOS
#   python3 scripts/verify_index_sha.py --only act,jq         # 只查几个包
#   python3 scripts/verify_index_sha.py --workers 16          # 并发度
#   python3 scripts/verify_index_sha.py --size-only            # 只比大小，不下载
#
# --size-only 先跑一遍很有用：它只读 API 的 size 字段，几秒出结果，能立刻抓出
# 「没上传」和「传错文件」这两类最常见的问题。之后再做全量 sha256。

import argparse
import concurrent.futures
import hashlib
import pathlib
import re
import subprocess
import sys
import threading

INDEX = pathlib.Path.home() / "Projects" / "SummerwaveOrg" / "SeaLane"
BOTTLE_REPO = "SummerwaveOrg/Bottle"
ASSET_API = f"https://api.github.com/repos/{BOTTLE_REPO}/releases/assets"
RECORD_RE = re.compile(r"^_([^@]+)@(.+)\.((?:linux|macos)-(?:arm64|amd64))$")
SHA_RE = re.compile(r'^sha256:\s*"([a-f0-9]+)"', re.M)
TIMEOUT = 600

TOKEN = ""
_lock = threading.Lock()


class Result:
    def __init__(self):
        self.ok = 0
        self.wrong = []          # (资产名, 记录值, 实际值)
        self.missing = []        # 记录在，资产不在
        self.no_record = []      # 资产在，索引没这条记录（不影响安装，只做提示）
        self.error = []


def github_token():
    for args in (["gh", "auth", "token"],):
        result = subprocess.run(args, capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    return ""


def load_assets():
    """资产名 → (id, size)。一次分页拉完。"""
    result = subprocess.run(
        ["gh", "api", f"repos/{BOTTLE_REPO}/releases", "--paginate",
         "-q", '.[] | .assets[] | "\\(.name)\\t\\(.id)\\t\\(.size)"'],
        capture_output=True, text=True, timeout=900)
    if result.returncode != 0:
        raise SystemExit(f"gh api 失败：{result.stderr.strip()[:300]}")
    assets = {}
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            assets[parts[0]] = (parts[1], int(parts[2]))
    return assets


def read_records(index_dir, oses, only):
    out = []
    for record in sorted(index_dir.glob("*/_*@*.linux-*")) + \
            sorted(index_dir.glob("*/_*@*.macos-*")):
        match = RECORD_RE.match(record.name)
        if not match:
            continue
        pkg, version, tag = match.groups()
        if tag.split("-")[0] not in oses:
            continue
        if only and pkg not in only:
            continue
        if pkg.startswith("test_"):
            continue
        sha = SHA_RE.search(record.read_text(errors="replace"))
        if not sha:
            continue
        out.append((pkg, f"{pkg}@{version}.{tag}.tar.bz2", sha.group(1)))
    return out


def download_sha(asset_id):
    """下载整份资产并算 sha256（同时返回字节数）。"""
    args = ["curl", "-fsSL", "--max-time", str(TIMEOUT),
            "-H", "Accept: application/octet-stream"]
    if TOKEN:
        args += ["-H", f"Authorization: Bearer {TOKEN}"]
    args.append(f"{ASSET_API}/{asset_id}")
    digest = hashlib.sha256()
    total = 0
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        while True:
            block = process.stdout.read(1 << 20)
            if not block:
                break
            digest.update(block)
            total += len(block)
    finally:
        process.stdout.close()
        code = process.wait()
    if code != 0:
        raise RuntimeError(f"curl exit {code}")
    return digest.hexdigest(), total


def check_one(asset, record_sha, assets, result, size_only):
    if asset not in assets:
        with _lock:
            result.missing.append(asset)
        return
    asset_id, size = assets[asset]
    if size_only:
        with _lock:
            result.ok += 1
        return
    try:
        digest, total = download_sha(asset_id)
    except Exception as error:
        with _lock:
            result.error.append((asset, f"{type(error).__name__}: {error}"))
        return
    with _lock:
        if digest == record_sha and total == size:
            result.ok += 1
        else:
            result.wrong.append((asset, record_sha, digest, size, total))


def main():
    global TOKEN
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--os", default="all", choices=["macos", "linux", "all"])
    parser.add_argument("--only", default="")
    parser.add_argument("--index", default=str(INDEX), type=pathlib.Path)
    parser.add_argument("--workers", type=int, default=12)
    parser.add_argument("--size-only", action="store_true",
                        help="只比大小（秒级），不下载")
    args = parser.parse_args()

    TOKEN = github_token()
    oses = {"macos", "linux"} if args.os == "all" else {args.os}
    only = {name.strip() for name in args.only.split(",") if name.strip()}

    print("🌊 拉 Release 资产清单…", flush=True)
    assets = load_assets()
    records = read_records(args.index, oses, only)
    total_bytes = sum(assets[a][1] for _, a, _ in records if a in assets)
    mode = "只看大小" if args.size_only else f"下载并算 sha256（约 {total_bytes / 1073741824:.1f} GB）"
    print(f"🌊 索引 {len(records)} 条，Release 资产 {len(assets)} 个，{mode}，"
          f"{args.workers} 路并发", flush=True)

    result = Result()
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(check_one, asset, sha, assets, result, args.size_only): asset
                   for _pkg, asset, sha in records}
        for future in concurrent.futures.as_completed(futures):
            future.result()
            done += 1
            if done % 50 == 0 or done == len(records):
                print(f"   [{done}/{len(records)}] ok={result.ok} 错={len(result.wrong)} "
                      f"缺={len(result.missing)} 异常={len(result.error)}", flush=True)

    used = {a for _, a, _ in records}
    result.no_record = sorted(set(assets) - used)

    print()
    if result.wrong:
        print(f"❌ sha256 不一致 {len(result.wrong)} 条：")
        for asset, want, got, expect_size, real_size in result.wrong:
            print(f"   {asset}")
            print(f"      记录 {want[:16]}…  ({expect_size} 字节)")
            print(f"      实际 {got[:16]}…  ({real_size} 字节)")
    if result.missing:
        print(f"❌ Release 上没有 {len(result.missing)} 条记录的资产：")
        for asset in result.missing[:20]:
            print(f"   {asset}")
        if len(result.missing) > 20:
            print(f"   …… 另有 {len(result.missing) - 20} 条")
    if result.error:
        print(f"⚠️  取不到 {len(result.error)} 条：")
        for asset, why in result.error[:10]:
            print(f"   {asset}  {why}")
    if result.no_record:
        print(f"ℹ️  {len(result.no_record)} 个资产在索引里没有对应记录（不影响安装）")

    print(f"\n一致 {result.ok} 条")
    bad = len(result.wrong) + len(result.missing)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
