#!/usr/bin/env python3

# migrate_index_layout.py
#
# 把 infosource 的旧索引布局（4.x）搬到 0.1.0 的布局上。
#
#   旧：pkg/pkginfo_arm64/<包名>/_<包名>@<版本>          （每个架构一个目录）
#       deps/depsinfo_amd64/<依赖名>/_<依赖名>@<版本>
#   新：pkg/pkginfo/<包名>/_<包名>@<版本>.<os>-<arch>    （单目录，标签在名字里）
#       deps/depsinfo/<依赖名>/_<依赖名>@<版本>.<os>-<arch>
#
# 为什么需要：0.1.0 的客户端只认新形状（见 net/domains.payload_filename 与
# sync_payloads.records）。旧目录在新客户端眼里**不存在** —— 不是报错，是「没有这个包」，
# 故障位置离原因太远，所以这里先把索引搬过去。
#
# 两件事分开做，因为代价完全不同：
#
#   ① 索引记录搬家 —— 纯文件操作，本脚本 --apply 一次搞定。
#   ② 产物改名   —— GitHub Release 的资产不能改名，只能「下载 → 按新名上传 → 删旧的」。
#                    本脚本只打印计划（或写成一个脚本），真的跑要人盯着：几百个文件，
#                    大的单个 172MB，而且旧名字删太早会让 4.x 用户装不上。
#
# 用法：
#   # 只看计划（默认，什么都不改）
#   python3 scripts/migrate_index_layout.py --infosource ~/Projects/SummerwaveOrg/SeaLane
#
#   # 真的搬索引记录（产物改名仍然只打印）
#   python3 scripts/migrate_index_layout.py --infosource … --apply
#
#   # 顺便生成产物改名脚本（默认保留旧资产，避免打断 4.x）
#   python3 scripts/migrate_index_layout.py --infosource … --emit-gh-script /tmp/rename-assets.sh
#
# 搬完之后还要做两件事（本脚本会提醒）：
#   - `scripts/build_versions_index.py` 重新生成镜像的 versions 清单
#   - `scripts/sync_payloads.py` 把产物按新名字抓一遍，核对 sha256

import argparse
import re
import shutil
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import components  # noqa: E402

components.add_to_sys_path()

import domains  # noqa: E402  —— 产物命名只此一份
import platforminfo  # noqa: E402

# (kind, 顶层目录名, 新索引目录名)
KINDS = (
    ("bottle", "pkg", "pkginfo"),
    ("deps", "deps", "depsinfo"),
)

ARCH_SUFFIX_RE = re.compile(r"^(pkginfo|depsinfo)_(arm64|amd64|x86_64)$")
FILE_FIELD_RE = re.compile(r'^file:\s*"([^"]+)"\s*$', re.M)


class Conflict:
    """搬不动的一条，必须人看。"""

    def __init__(self, path, reason):
        self.path = path
        self.reason = reason


def old_index_dirs(infosource):
    # 返回 [(kind, 旧目录, arch, 新目录)]
    found = []
    for kind, top, new_name in KINDS:
        root = infosource / top
        if not root.is_dir():
            continue
        for directory in sorted(root.iterdir()):
            match = ARCH_SUFFIX_RE.match(directory.name)
            if not match or not directory.is_dir():
                continue
            arch = platforminfo.bottle_tag(match.group(2), os_name="macos").split("-", 1)[1]
            found.append((kind, directory, arch, root / new_name))
    return found


def plan_records(infosource, os_name):
    """返回 (搬运表, 冲突表, 需要重新生成的 versions 文件)。

    搬运表里每项是 (旧路径, 新路径)，新路径的内容与旧路径逐字节相同。
    """
    moves = []
    conflicts = []
    generated = []

    for kind, old_dir, arch, new_dir in old_index_dirs(infosource):
        tag = platforminfo.bottle_tag(arch, os_name=os_name)

        for package_dir in sorted(p for p in old_dir.iterdir() if p.is_dir()):
            name = package_dir.name

            for path in sorted(package_dir.iterdir()):
                if path.name == "versions":
                    # 镜像生成的清单，里面的记录名也带了架构；搬完重新生成即可
                    generated.append(path)
                    continue
                if not path.is_file():
                    continue

                if path.name == f"_{name}@common":
                    # 两个架构原本各有一份，元数据应当相同 —— 不同就得人看
                    moves.append((path, new_dir / name / path.name))
                    continue

                stem = path.name[1:]
                record_name, _, version = stem.partition("@")

                # 已经是新形状（带标签）的记录不要重复加标签
                if platforminfo.strip_bottle_tag(version) != version:
                    if version.endswith(f".{tag}"):
                        moves.append((path, new_dir / name / path.name))
                        continue
                    conflicts.append(Conflict(
                        path, f"record already carries a foreign bottle tag ({version})"))
                    continue

                target = new_dir / name / f"_{record_name}@{version}.{tag}"
                moves.append((path, target))

    return moves, conflicts, generated


COMMON_FIELD_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"(.*)"\s*$')


def parse_common(text):
    """`field: "value"` 平铺文本 → [(字段, 值)]，保持原顺序。"""
    fields = []
    for line in text.splitlines():
        match = COMMON_FIELD_RE.match(line.strip())
        if match:
            fields.append((match.group(1), match.group(2)))
    return fields


def arch_of(path):
    for part in path.parts:
        match = ARCH_SUFFIX_RE.match(part)
        if match:
            return "arm64" if match.group(2) in ("arm64", "aarch64") else "amd64"
    return ""


def merge_common(texts, prefer):
    """把几份 @common 合成一份：字段取并集，同名字段取值不同时按 prefer 定。

    为什么允许合成：@common 是**跨架构**的元数据，两个架构各存一份本身就是历史遗留。
    两份只在字段顺序或某个描述性字段（如 aut）上有别时，合并不丢信息 ——
    丢掉字段才是真损失，所以并集优先、冲突只记录不中止。
    """
    merged = {}
    order = []
    conflicts = []
    for arch, text in texts:
        for key, value in parse_common(text):
            if key not in merged:
                merged[key] = (value, arch)
                order.append(key)
                continue
            current_value, current_arch = merged[key]
            if current_value == value:
                continue
            # 同一字段两个值：prefer 那一侧胜出（默认 arm64）
            if arch == prefer:
                merged[key] = (value, arch)
                conflicts.append((key, value, arch, current_value, current_arch))
            else:
                conflicts.append((key, current_value, current_arch, value, arch))
    body = "".join(f'{key}: "{merged[key][0]}"\n' for key in order)
    return body, conflicts


def dedupe_common(moves, prefer=None):
    """同一个 @common 被两个架构各搬一次 —— 内容相同就只留一份。

    prefer 给了就合成（字段并集），没给就报冲突让人看。
    """
    by_target = {}
    kept, conflicts, merges = [], [], []
    for source, target in moves:
        if not target.name.endswith("@common"):
            kept.append((source, target))
            continue
        first = by_target.get(target)
        if first is None:
            by_target[target] = source
            kept.append((source, target))
            continue
        if first.read_bytes() == source.read_bytes():
            kept.append((source, None))     # 第二份：只删不搬
            continue
        if prefer is None:
            conflicts.append(Conflict(
                source, f"differs from {first} but both map to {target}"))
            continue
        body, field_conflicts = merge_common(
            [(arch_of(first), first.read_text()), (arch_of(source), source.read_text())], prefer)
        # 合成结果写进第一份的位置，第二份只删不搬
        merges.append((target, body))
        kept.append((source, None))
        for key, winner, winner_arch, loser, loser_arch in field_conflicts:
            merges.append((target, f"    ! {key}: kept {winner!r} ({winner_arch}), "
                                   f"dropped {loser!r} ({loser_arch})"))
    return kept, conflicts, merges


def plan_payloads(infosource, os_name):
    """返回 (改名计划, 冲突)。改名计划每项是 (kind, 名字, 旧资产名, 新资产名)。

    旧资产名从记录的 `file:` 字段推出来：4.x 用的是 `<名>@<版本>.<arch><扩展名>`。
    `file:` 缺失的记录推不出来（那是数据缺陷，先跑 backfill_file_field.py）。
    """
    plan, conflicts = [], []

    for kind, old_dir, arch, _new_dir in old_index_dirs(infosource):
        for package_dir in sorted(p for p in old_dir.iterdir() if p.is_dir()):
            for path in sorted(package_dir.iterdir()):
                if not path.is_file() or path.name.endswith("@common"):
                    continue
                if path.name == "versions":
                    continue

                stem = path.name[1:]
                name, _, version = stem.partition("@")
                if platforminfo.strip_bottle_tag(version) != version:
                    continue            # 已经搬过

                match = FILE_FIELD_RE.search(path.read_text())
                if not match:
                    conflicts.append(Conflict(path, "no file field, cannot name the payload"))
                    continue

                suffix = domains.payload_suffix(match.group(1))
                old = f"{name}@{version}.{arch}{suffix}"
                new = domains.payload_filename(name, version, arch, match.group(1))
                if old == new:
                    continue
                plan.append((kind, name, old, new))

    return plan, conflicts


def apply_moves(moves, root, rewrites=None):
    rewrites = rewrites or {}
    for source, target in moves:
        if target is None:                  # 重复的 @common
            source.unlink()
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if target in rewrites:
            target.write_text(rewrites[target], encoding="utf-8")
            source.unlink()
            continue
        if target.exists():
            # 目标已经在了：内容相同就当搬运完成，不同就报出来别覆盖
            if target.read_bytes() != source.read_bytes():
                raise SystemExit(f"🌊 Error: {target} already exists with different content")
            source.unlink()
            continue
        source.rename(target)

    # 旧目录里可能还剩东西（versions 清单、空壳包目录），整体删掉
    for _kind, old_dir, _arch, _new_dir in old_index_dirs(root):
        shutil.rmtree(old_dir, ignore_errors=True)


def emit_gh_script(path, plan, keep_old):
    # 资产不能改名：只能下载 → 改名上传 → （可选）删旧的。
    # 默认 keep_old=True：4.x 用户还在用旧名字，删早了等于把他们踢下线。
    lines = [
        "#!/bin/bash",
        "# 由 scripts/migrate_index_layout.py 生成 —— 产物改名计划。",
        "#",
        "# 每个资产：下载 → 本地改名 → 按新名字上传 → " +
        ("保留旧名字（4.x 用户仍需要它）。" if keep_old else "删掉旧名字。"),
        "# 跑之前确认 gh 已登录（gh auth status），并留足磁盘：大文件单个 172MB。",
        "set -euo pipefail",
        "",
        'WORK="${WORK:-$(mktemp -d)}"',
        "trap 'rm -rf \"$WORK\"' EXIT",
        "",
    ]
    for index, (kind, name, old, new) in enumerate(plan):
        repo = "MacWaveOrg/Bottle" if kind == "bottle" else "MacWaveOrg/Deps"
        work = f'"$WORK/{index}"'
        lines += [
            f'echo "==> {kind}/{name}: {old} -> {new}"',
            f'mkdir -p {work}',
            f'if ! gh release download "{name}" -R {repo} -p "{old}" -D {work} --clobber; then',
            f'    echo "    skipped: {old} is not in the release (known-bad record?)"',
            f'    continue',
            f'fi',
            f'cp {work}/"{old}" {work}/"{new}"',
            f'gh release upload "{name}" -R {repo} {work}/"{new}" --clobber',
            "",
        ]
    if not keep_old:
        lines += ["", "# 旧名字的清理放在确认新版可用之后再做："]
        for kind, name, old, new in plan:
            repo = "MacWaveOrg/Bottle" if kind == "bottle" else "MacWaveOrg/Deps"
            lines.append(
                f'gh release delete-asset "{name}" -R {repo} "{old}" --yes')

    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
    Path(path).chmod(0o755)


def main():
    parser = argparse.ArgumentParser(
        description="Migrate an infosource checkout to the 0.1.0 index layout.")
    parser.add_argument("--infosource", required=True, type=Path,
                        help="path to a checkout of SummerwaveOrg/SeaLane (modified in place with --apply)")
    parser.add_argument("--os", default="macos", choices=list(platforminfo.BOTTLE_OSES),
                        help="platform the payloads belong to (default: macos)")
    parser.add_argument("--apply", action="store_true",
                        help="move the index records (payload renaming is never applied here)")
    parser.add_argument("--merge-common", action="store_true",
                        help="merge the two per-arch copies of @common (union of fields) "
                             "instead of refusing; conflicting values follow --prefer-arch")
    parser.add_argument("--prefer-arch", default="arm64", choices=["arm64", "amd64"],
                        help="which arch wins when @common carries the same field with different "
                             "values (only with --merge-common; default: arm64)")
    parser.add_argument("--emit-gh-script", type=Path, default=None,
                        help="write the payload rename plan as a gh script")
    parser.add_argument("--delete-old-assets", action="store_true",
                        help="in the emitted script, delete the old asset names (breaks 4.x clients)")
    args = parser.parse_args()

    infosource = args.infosource.resolve()
    if not (infosource / "pkg").is_dir():
        print(f"🌊 Error: {infosource} does not look like the infosource repository.")
        return 1

    moves, conflicts, generated = plan_records(infosource, args.os)
    moves, common_conflicts, merges = dedupe_common(
        moves, args.prefer_arch if args.merge_common else None)
    conflicts += common_conflicts
    payloads, payload_conflicts = plan_payloads(infosource, args.os)
    conflicts += payload_conflicts

    if not moves and not payloads:
        print("🌊 Nothing to migrate — this checkout is already in the 0.1.0 layout.")
        return 0

    records = [m for m in moves if m[1] is not None]
    dropped = len(moves) - len(records)
    print(f"🌊 {len(records)} record(s) to move, {dropped} duplicate @common to drop, "
          f"{len(payloads)} payload(s) to rename, {len(generated)} generated versions file(s).")

    for source, target in records[:20]:
        print(f"   {source.relative_to(infosource)}  ->  {target.relative_to(infosource)}")
    if len(records) > 20:
        print(f"   … and {len(records) - 20} more")

    if merges:
        print("🌊 @common merged (union of fields, see the ! lines for resolved conflicts):")
        for target, line in merges:
            if line.lstrip().startswith("!"):
                print(line)
            else:
                print(f"   {target.relative_to(infosource)}:")
                for row in line.rstrip("\n").splitlines():
                    print(f"       {row}")

    if generated:
        print("🌊 versions files found (regenerate after migrating):")
        for path in generated[:10]:
            print(f"   {path.relative_to(infosource)}")

    if conflicts:
        print(f"🌊 {len(conflicts)} conflict(s) — these need a human:")
        for conflict in conflicts[:20]:
            print(f"   {conflict.path.relative_to(infosource)}: {conflict.reason}")
        if args.apply:
            print("🌊 Refusing to --apply while there are conflicts.")
            return 1

    if args.emit_gh_script:
        emit_gh_script(args.emit_gh_script, payloads, not args.delete_old_assets)
        print(f"🌊 Payload rename plan written to {args.emit_gh_script}")

    if not args.apply:
        print("🌊 Dry run — nothing changed. Re-run with --apply to move the records.")
        return 0

    rewrites = {target: body for target, body in merges if not body.lstrip().startswith("!")}
    apply_moves(records, infosource, rewrites)
    print("🌊 Index records migrated. Next:")
    print("   1. scripts/build_versions_index.py   (regenerate the mirror's versions lists)")
    print("   2. run the emitted gh script         (rename the payload assets)")
    print("   3. scripts/sync_payloads.py          (re-fetch and verify sha256)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
