#!/usr/bin/env python3

# publish_payloads.py
# 把 sync_payloads.py 生成的暂存目录发布到 Bottle / Deps 仓库的 Release。
#
# 约定（与 net/domains.py 的 payload_url 一一对应）：
#
#   <包名>/<包名>@<版本>.<架构><扩展名>
#   ↓
#   https://github.com/MacWaveOrg/Bottle/releases/download/<包名>/<文件名>
#
# 所以 **tag = 包名**，一个包一个 Release，架构靠文件名区分（arm64 / amd64 同名同版本）。
#
# 三条不可违反的规则：
#   1. 只增不删。旧版本必须一直可下载 —— 多版本共存是 MacWave 的设计前提，
#      删掉一个资产就等于让 `wave install <包>@<旧版本>` 永久失效。
#   2. 已存在且大小相同的资产跳过，不重复上传（省时间也省配额）。
#   3. 校验在下载阶段就做过了（sync_payloads.py 对 sha256），这里只负责发布。
#
# 用法：
#   python3 scripts/publish_payloads.py --staging ./mirror            # 报告，不发布
#   python3 scripts/publish_payloads.py --staging ./mirror --write    # 真正上传
#   python3 scripts/publish_payloads.py --staging ./mirror --write --only jq
#
# 需要 gh CLI 已登录（凭据要有目标仓库的 contents:write）。

import argparse
import json
import subprocess
import sys
from pathlib import Path

# 0.1.0 起包与依赖同构，共用一个载荷仓库（4.x 的 MacWaveOrg/Bottle、MacWaveOrg/Deps 已冻结）
KIND_REPO = {
    "bottle": "SummerwaveOrg/Bottle",
    "deps": "SummerwaveOrg/Bottle",
}


# GitHub 的写接口偶尔会返回 5xx 或 429。一次 30 分钟的任务不该被这种抖动整个打死：
# 发布本身是幂等的（同名资产不覆盖、已存在就跳过），所以重试是安全的。
TRANSIENT_MARKERS = ("HTTP 500", "HTTP 502", "HTTP 503", "HTTP 504", "HTTP 429")
RUN_ATTEMPTS = 5


def run(args, check=True):
    import time

    result = None
    for attempt in range(1, RUN_ATTEMPTS + 1):
        result = subprocess.run(args, capture_output=True, text=True)
        if not check or result.returncode == 0:
            return result

        transient = any(marker in result.stderr for marker in TRANSIENT_MARKERS)
        if not transient or attempt == RUN_ATTEMPTS:
            break
        delay = 2 ** attempt
        print(f"  ↩ {args[1] if len(args) > 1 else args[0]} returned a transient error; "
              f"retrying in {delay}s ({attempt}/{RUN_ATTEMPTS - 1})")
        time.sleep(delay)

    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(args)}\n{result.stderr.strip()}")
    return result


def existing_assets(repo, tag):
    # Release 不存在时 gh 返回 404，这里当作「空」而不是错误。
    result = run(["gh", "api", f"repos/{repo}/releases/tags/{tag}"], check=False)
    if result.returncode != 0:
        return None
    try:
        return {asset["name"]: asset["size"] for asset in json.loads(result.stdout).get("assets", [])}
    except ValueError:
        return None


def ensure_release(repo, tag, write):
    # 一个包一个 Release。标题与说明刻意朴素：这是数据仓库，不是发布公告页。
    assets = existing_assets(repo, tag)
    if assets is not None:
        return assets, False

    if not write:
        return {}, True

    run(["gh", "release", "create", tag,
         "--repo", repo,
         "--title", tag,
         "--notes", f"Payloads for `{tag}`.\n\n"
                    f"Served to MacWave 4.0 clients as "
                    f"`<SUMMERWAVE_BOTTLE_DOMAIN or SUMMERWAVE_DEPS_DOMAIN>/{tag}/<file>`.\n"
                    f"Assets are byte-for-byte copies of the upstream artifacts; "
                    f"their checksums are recorded in the `infosource` index.\n"
                    f"Nothing here is ever replaced: a rebuild gets a new version suffix."])
    return {}, True


def publish(kind, staging, write, only):
    root = staging / kind
    if not root.is_dir():
        return 0, 0, []

    repo = KIND_REPO[kind]
    uploaded = 0
    skipped = 0
    problems = []

    for package_dir in sorted(path for path in root.iterdir() if path.is_dir()):
        package = package_dir.name
        if only and package not in only:
            continue

        files = sorted(path for path in package_dir.iterdir() if path.is_file())
        if not files:
            continue

        sub_uploaded, sub_skipped, sub_problems = upload_files(
            repo, package, files, ensure_release(repo, package, write), write)
        uploaded += sub_uploaded
        skipped += sub_skipped
        problems.extend(sub_problems)

    return uploaded, skipped, problems


def upload_files(repo, package, files, release, write):
    """把一个包的若干文件推进它的 Release。两种输入（sync 树 / 重打目录）共用。"""
    assets, created = release
    if created:
        print(f"  + release {repo}:{package}")
    assets = assets or {}

    uploaded = skipped = 0
    problems = []

    for path in files:
        size = path.stat().st_size
        if path.name in assets:
            # 同名同大小视为已发布。内容正确性由 sha256 保证（索引里那条）。
            if assets[path.name] == size:
                skipped += 1
                continue
            problems.append(f"{repo}:{package}/{path.name} exists with a different size; "
                            f"assets are immutable, publish a new version suffix instead")
            continue

        if not write:
            print(f"  ≈ would upload {repo}:{package}/{path.name} ({size} bytes)")
            uploaded += 1
            continue

        run(["gh", "release", "upload", package, str(path), "--repo", repo, "--clobber"])
        print(f"  ↑ {repo}:{package}/{path.name} ({size} bytes)")
        uploaded += 1

    return uploaded, skipped, problems


def publish_flat(flat, tsv, write, only):
    """发布 prepare_bottle.py 的输出：平铺目录 + 它的 --tsv。

    sync_payloads 那棵树是 `<kind>/<包名>/<文件>`；重打的输出是平铺的
    `<名>@<版本>.<标签>.tar.bz2`。归档形状不一样，但索引里那条记录已经把
    「哪个包、哪个文件」写清楚了，所以这里按 TSV 分组，不需要目录结构。
    """
    rows = {}
    for line in Path(tsv).read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) != 6 or fields[0] == "kind":
            continue
        kind, name, _version, _arch, filename, _sha = fields
        path = flat / filename
        if not path.is_file():
            continue
        # 同一个包可能被重打过多次（tsv 是追加写的），后写的赢
        rows[(kind, name, filename)] = (kind, name, path)

    groups = {}
    for kind, name, path in rows.values():
        if only and name not in only:
            continue
        groups.setdefault((kind, name), []).append(path)

    uploaded = skipped = 0
    problems = []

    for (kind, name) in sorted(groups):
        repo = KIND_REPO["bottle" if kind in ("pkg", "bottle") else "deps"]
        files = sorted(groups[(kind, name)])
        sub_uploaded, sub_skipped, sub_problems = upload_files(
            repo, name, files, ensure_release(repo, name, write), write)
        uploaded += sub_uploaded
        skipped += sub_skipped
        problems.extend(sub_problems)

    return uploaded, skipped, problems


def main():
    parser = argparse.ArgumentParser(description="Publish payloads to GitHub Releases.")
    parser.add_argument("--staging", type=Path,
                        help="directory produced by sync_payloads.py")
    parser.add_argument("--flat", type=Path,
                        help="directory produced by prepare_bottle.py (needs --tsv)")
    parser.add_argument("--tsv", type=Path,
                        help="the --tsv file prepare_bottle.py wrote")
    parser.add_argument("--write", action="store_true", help="actually create releases and upload")
    parser.add_argument("--kinds", default="bottle,deps")
    parser.add_argument("--only", default="", help="comma separated package names")
    args = parser.parse_args()

    kinds = [kind.strip() for kind in args.kinds.split(",") if kind.strip()]
    only = {name.strip() for name in args.only.split(",") if name.strip()}

    if bool(args.staging) == bool(args.flat):
        parser.error("give exactly one of --staging / --flat (+ --tsv)")
    if args.flat and not args.tsv:
        parser.error("--flat needs --tsv (it says which package each archive belongs to)")

    total_uploaded = total_skipped = 0
    all_problems = []

    if args.flat:
        total_uploaded, total_skipped, all_problems = publish_flat(
            args.flat, args.tsv, args.write, only)

    for kind in ([] if args.flat else kinds):
        uploaded, skipped, problems = publish(kind, args.staging, args.write, only)
        total_uploaded += uploaded
        total_skipped += skipped
        all_problems.extend(problems)

    verb = "uploaded" if args.write else "would upload"
    print(f"\n🌊 {verb} {total_uploaded}, already present {total_skipped}")

    for problem in all_problems:
        print(f"  ❌ {problem}")

    if all_problems:
        return 1
    if not args.write and total_uploaded:
        print("🌊 Re-run with --write to publish.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
