#!/usr/bin/env python3

# stage_audit.py —— 上传前的体检。**上游产物也要体检，不只是自编的。**
#
# 为什么需要它：绝大多数载荷不是我们编的，是上游 release / conda-forge 的产物
# 搬过来重打包（`scripts/prepare_bottle.py`）。字节来自别人，所以我们既不知道
# 它是用什么 sdk 编的，也不知道它有没有把构建机的东西烘进去：
#
#   * conda 包自带 `info/`（recipe、git、test、licenses，ncurses 一个就 848K）；
#   * `.la` 是 libtool 的描述文件，里面写着构建时的绝对路径；
#   * `__pycache__/` 与解释器版本绑定，换一个 Python 就是垃圾；
#   * 最要命的是 Mach-O 里 `LC_LOAD_DYLIB` 指向 `/opt/anaconda3/...` 这种绝对路径 ——
#     用户机上没有那个目录，`dyld` 直接拒开。这类问题「装得上」这一步完全正常，
#     只有真跑才暴露。
#
# 分级：
#   ERROR 会让包在用户机上坏掉 —— 悬空符号链接、`bin/` 下没有执行位、
#         Mach-O 引用构建机的绝对路径、conda 占位符没替换干净。
#   WARN  脏但不影响运行 —— 上游元数据目录、`.pyc`、`.la`、`.DS_Store`、
#         调试字符串里的构建机路径、空目录。
#
# 用法：
#   python3 scripts/stage_audit.py --stage /tmp/prepare-xxx/stage
#   python3 scripts/stage_audit.py --archive out/jq@1.8.2.macos-arm64.tar.bz2
#   python3 scripts/stage_audit.py --stage <dir> --smoke      # 再跑一遍 bin/ 里的命令
#   python3 scripts/stage_audit.py --stage <dir> --json
#
# 退出码：0 = 干净或只有 WARN；1 = 有 ERROR；2 = 用法错误。

import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
import tarfile
from pathlib import Path

# -------------------- 判据 --------------------

# 上游元数据与缓存：脏，但不影响运行
# 判据按**路径段**而不是整串前缀：conda 的 info/ 落在 `Shore/<名>/<版本>/info`，
# 整串匹配永远够不着它（曾经就是这么漏的）。
JUNK_RULES = (
    ("conda 元数据 info/", lambda parts: len(parts) >= 4 and parts[3] == "info"),
    ("conda-meta/", lambda parts: "conda-meta" in parts),
    ("字节码缓存", lambda parts: parts[-1].endswith(".pyc") or "__pycache__" in parts),
    ("libtool .la", lambda parts: parts[-1].endswith(".la")),
    ("Finder 垃圾", lambda parts: parts[-1] == ".DS_Store"),
)

# 构建机路径。出现在**文本**里只是脏；出现在 Mach-O 的 load command 里是致命。
BUILD_PATH_NEEDLES = (
    b"/opt/anaconda3/conda-bld",
    b"/usr/local/Cellar",
    b"/opt/homebrew/Cellar",
    b"/private/tmp/",
    b"/var/folders/",
    b"_h_env_placehold",
)

# conda 的占位符只该出现在替换之前；到了打包这一步还没换干净就是 bug
FATAL_NEEDLES = (b"_h_env_placehold",)

# `--version` 跑出来这些说明动态链接失败 —— 这才是「装完坏了」的直接证据
DYLD_FAILURES = (
    "Library not loaded",
    "Symbol not found",
    "bad CPU type",
    "Killed: 9",
    "code signature",
    "dyld: ",
    "Abort trap",
)

MACHO_MAGICS = (
    b"\xcf\xfa\xed\xfe",  # 64 位小端
    b"\xce\xfa\xed\xfe",  # 32 位小端
    b"\xfe\xed\xfa\xcf",  # 64 位大端
    b"\xfe\xed\xfa\xce",  # 32 位大端
    b"\xca\xfe\xba\xbe",  # universal / fat
)

CHUNK = 1 << 20
# 任何外部命令（lipo / otool / arch）都不许无限等
SUBPROCESS_TIMEOUT = 10


class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, kind, where, detail=""):
        self.errors.append({"kind": kind, "path": where, "detail": detail})

    def warn(self, kind, where, detail=""):
        self.warnings.append({"kind": kind, "path": where, "detail": detail})

    @property
    def clean(self):
        return not self.errors and not self.warnings


# -------------------- 统一遍历：目录与归档走同一套规则 --------------------


def _walk_stage(root):
    """产出 (相对路径, kind, 绝对路径或链接目标)。kind ∈ file/dir/symlink。"""
    root = Path(root)
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in list(dirnames):
            full = Path(dirpath) / name
            rel = str(full.relative_to(root))
            if full.is_symlink():
                yield rel, "symlink", os.readlink(full)
                dirnames.remove(name)  # 不跟进去，避免成环
            else:
                yield rel, "dir", full
        for name in filenames:
            full = Path(dirpath) / name
            rel = str(full.relative_to(root))
            yield (rel, "symlink", os.readlink(full)) if full.is_symlink() else (rel, "file", full)


def _walk_archive(path):
    """归档版：把成员流式读出来，返回 (rel, kind, payload_loader)。

    调用方只在真的要看内容时才 loader()，否则大包会被整份读进内存。
    """
    archive = tarfile.open(path)
    for member in archive:
        rel = member.name
        while rel.startswith("./"):
            rel = rel[2:]
        rel = rel.rstrip("/")
        if member.isdir():
            yield rel, "dir", None
        elif member.issym():
            yield rel, "symlink", member.linkname
        elif member.islnk():
            yield rel, "hardlink", member.linkname
        elif member.isfile():
            yield rel, "file", member
    archive.close()


def _read_member(archive_path, member):
    with tarfile.open(archive_path) as archive:
        stream = archive.extractfile(member)
        return stream.read() if stream else b""


# -------------------- 各项检查 --------------------


def _check_junk(report, entries):
    """上游元数据与缓存。已报过的目录里的东西不再逐个报 —— `__pycache__` 下有
    一百个 `.pyc` 时，一百行警告只会把真正的 ERROR 顶出屏幕。"""
    reported = []
    for rel, kind, _payload in entries:
        if any(rel.startswith(seen + "/") for seen in reported):
            continue
        parts = rel.split("/")
        for label, rule in JUNK_RULES:
            if rule(parts):
                report.warn(label, rel)
                reported.append(rel)
                break


def _check_empty_dirs(report, entries):
    """空目录：装完的用户树里躺着一片空壳，多半是上游打包时有目录没内容。"""
    dirs, populated = [], set()
    for rel, kind, _payload in entries:
        if kind == "dir":
            dirs.append(rel)
        elif rel:
            parts = rel.split("/")
            for i in range(1, len(parts)):
                populated.add("/".join(parts[:i]))
    for d in dirs:
        if d not in populated:
            report.warn("空目录", d)


def _check_dangling(report, entries):
    """悬空符号链接：指向 stage 里不存在的目标。装到用户机上必断。"""
    names = {rel for rel, kind, _p in entries if kind in ("file", "dir")}
    for rel, kind, target in entries:
        if kind != "symlink":
            continue
        # 归档里的链接可能是相对（相对所在目录）或绝对（绝对的一律可疑）
        if os.path.isabs(target):
            report.error("符号链接指向绝对路径", rel, target)
            continue
        resolved = os.path.normpath(os.path.join(os.path.dirname(rel), target))
        if resolved not in names:
            report.error("悬空符号链接", rel, target)


def _is_macho(head):
    return any(head.startswith(magic) for magic in MACHO_MAGICS)


def _check_build_paths(report, entries, read_bytes):
    """构建机路径：文本里是脏，Mach-O 里是致命（dyld 会去不存在的目录找库）。"""
    for rel, kind, payload in entries:
        if kind != "file":
            continue
        # `info/` 是 conda 的安装元数据（paths.json、has_prefix、recipe 之类），
        # 运行时一个字节都不会读到。它们**记录**着替换前的占位符是正常的 ——
        # 在这里报错只会逼人去改元数据，而真正该改的是 has_prefix 点名的文件。
        if "/info/" in rel or rel.startswith("info/"):
            continue
        data = read_bytes(rel, payload)
        if data is None:
            continue
        fatal = [n for n in FATAL_NEEDLES if n in data]
        for needle in fatal:
            report.error("conda 占位符没替换", rel, needle.decode("utf-8", "replace"))
        macho = _is_macho(data[:4])
        hits = [n for n in BUILD_PATH_NEEDLES if n in data and n not in FATAL_NEEDLES]
        if not hits:
            continue
        detail = ", ".join(n.decode("utf-8", "replace") for n in hits[:3])
        # 编译期烘进去的 `__FILE__`、调试串在文本段里，运行时不读 —— 只算脏。
        # 但 Mach-O 的 load command 里出现就是致命，那一项交给 otool 判（见下）。
        report.warn("构建机路径", rel, detail)


def _check_exec_bits(report, entries):
    """`Shore/<名>/<版本>/bin/` 下的东西必须有执行位 —— 否则装完敲不出来。"""
    for rel, kind, payload in entries:
        if kind != "file":
            continue
        parts = rel.split("/")
        # Shore/<名>/<版本>/bin/<文件>
        if len(parts) != 5 or parts[0] != "Shore" or parts[3] != "bin":
            continue
        if isinstance(payload, Path):
            mode = payload.stat().st_mode
            if not mode & stat.S_IXUSR:
                report.error("bin/ 下没有执行位", rel)
        else:
            if not payload.mode & stat.S_IXUSR:
                report.error("bin/ 下没有执行位", rel)


def _check_macho_refs(report, root):
    """Mach-O 的 `LC_LOAD_DYLIB` / `LC_ID_DYLIB` 不许指向构建机的绝对路径。

    这一项只在 stage 是真实目录、且有 `otool` 时做 —— 归档里没有可执行的二进制。
    与 `build/ports/scripts/selfbuilt_check.sh` 的同类检查判据一致，只是那边是给
    自编产物用的闸门，这里一样要拦上游产物。
    """
    if not shutil.which("otool"):
        return
    root = Path(root)
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            with open(path, "rb") as handle:
                if not _is_macho(handle.read(4)):
                    continue
        except OSError:
            continue
        code, out, _err, timed_out = _run_capture(["otool", "-L", str(path)])
        if timed_out or code != 0:
            continue
        for line in out.splitlines()[1:]:
            ref = line.strip().split(" (")[0]
            if not ref:
                continue
            if _is_build_path_ref(ref):
                report.error("Mach-O 引用构建机绝对路径",
                             str(path.relative_to(root)), ref)


def _is_build_path_ref(ref):
    """允许的系统库与相对路径；其余绝对路径一律可疑。"""
    allowed_prefixes = ("/usr/lib/", "/System/", "/Library/Apple/")
    if ref.startswith(("@loader_path", "@rpath", "@executable_path")):
        return False
    if ref.startswith(allowed_prefixes):
        return False
    return ref.startswith("/")


# -------------------- 冒烟：真跑一次 --------------------


def _run_capture(argv, timeout=SUBPROCESS_TIMEOUT):
    """跑一个外部命令，**保证返回**。返回 (returncode 或 None, stdout, stderr, timed_out)。

    为什么不用 `subprocess.run(..., timeout=)`：它在超时后 kill 子进程、再无条件
    `communicate()` —— 子进程若卡在内核/系统服务里不退出，这一步会**永久阻塞**，
    实测遇过（签名损坏的 Mach-O 会挂在 amfid 的评估上，`lipo` 跟着一起挂）。
    体检是"顺手跑一下"的东西，绝不该因为它把整批重打拖死。
    """
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                stdin=subprocess.DEVNULL, text=True, errors="replace")
    except OSError as exc:
        return None, "", str(exc), False
    try:
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, out or "", err or "", False
    except subprocess.TimeoutExpired:
        proc.kill()
        try:
            out, err = proc.communicate(timeout=2)
            return None, out or "", err or "", True
        except subprocess.TimeoutExpired:
            # 杀不掉就放弃这两根管道，绝不再等
            for stream in (proc.stdout, proc.stderr):
                try:
                    stream.close()
                except Exception:
                    pass
            return None, "", "", True


def _macho_archs(path):
    """用 `lipo -archs` 读产物架构；读不到返回空集。

    **必须带超时**：签名损坏的 Mach-O 会让 `amfid` 评估挂住，没有超时就会把整次
    体检（乃至批量重打）一起拖死 —— 这不是理论，是实测踩过的。
    """
    if not shutil.which("lipo"):
        return set()
    code, out, _err, timed_out = _run_capture(["lipo", "-archs", str(path)])
    if timed_out or code != 0:
        return set()
    return {a for a in out.split() if a in ("arm64", "x86_64", "aarch64", "amd64")}


def smoke(stage, timeout=5, host_arch=None):
    """把 `Shore/<名>/<版本>/bin/` 里每个可执行文件跑一次 `--version`。

    这是「装完是不是完好」最直接的判据：动态链接失败会以 dyld 报错的形式出现，
    而这类问题在静态检查里看不见（二进制看起来完全正常）。

    单文件产物（归档根就是那个可执行文件，没有 `bin/`）也要跑 —— 它们在 stage 里
    躺在版本目录根上，正是 147 个上游产物「装完一条链接都不建」的那种形状。

    返回 [{path, status, detail}]，status ∈ ok / dyld-error / timeout /
    exec-failed / skipped-cross-arch。**非 ok 的都不算通过，但也不在这里 exit** ——
    调用方决定是拦还是只报告（上游工具有的 `--version` 就是返回非零）。
    """
    host_arch = host_arch or os.uname().machine
    results = []
    root = Path(stage)
    candidates = sorted(root.glob("Shore/*/*/bin/*"))
    if not candidates:
        candidates = sorted(p for p in root.glob("Shore/*/*/*") if p.is_file())
    for exe in candidates:
        if exe.is_symlink() or not exe.is_file():
            continue
        if not os.access(exe, os.X_OK):
            continue
        archs = _macho_archs(exe)
        if archs and host_arch not in archs and not _rosetta_can_run(archs):
            results.append({"path": str(exe.relative_to(root)),
                            "status": "skipped-cross-arch",
                            "detail": ",".join(sorted(archs))})
            continue
        code, out, err, timed_out = _run_capture([str(exe), "--version"], timeout=timeout)
        if timed_out:
            results.append({"path": str(exe.relative_to(root)), "status": "timeout",
                            "detail": f"no answer within {timeout}s"})
            continue
        if code is None:
            results.append({"path": str(exe.relative_to(root)), "status": "exec-failed",
                            "detail": err.strip()[:160]})
            continue
        blob = err + out
        if code < 0:
            # 被信号打死（-9 = Killed）：签名失效或 AMFI 拒绝，用户机上一样起不来
            results.append({"path": str(exe.relative_to(root)), "status": "dyld-error",
                            "detail": f"killed by signal {-code}"})
            continue
        bad = next((marker for marker in DYLD_FAILURES if marker in blob), None)
        if bad:
            first = next((ln for ln in blob.splitlines() if bad in ln), bad)
            results.append({"path": str(exe.relative_to(root)), "status": "dyld-error",
                            "detail": first.strip()[:160]})
        else:
            results.append({"path": str(exe.relative_to(root)), "status": "ok", "detail": ""})
    return results


def _rosetta_can_run(archs):
    """宿主是 arm64、产物只有 x86_64 时，看 Rosetta 装了没有。"""
    if os.uname().machine != "arm64" or "x86_64" not in archs:
        return False
    code, _out, _err, timed_out = _run_capture(["arch", "-x86_64", "/usr/bin/true"])
    return code == 0 and not timed_out


# -------------------- 入口 --------------------


def audit_stage(root, with_macho_refs=True):
    report = Report()
    entries = list(_walk_stage(root))

    def read_bytes(rel, payload):
        try:
            return payload.read_bytes() if isinstance(payload, Path) else None
        except OSError:
            return None

    _check_junk(report, entries)
    _check_empty_dirs(report, entries)
    _check_dangling(report, entries)
    _check_build_paths(report, entries, read_bytes)
    _check_exec_bits(report, entries)
    if with_macho_refs:
        _check_macho_refs(report, root)
    return report


def audit_archive(path, with_macho_refs=False):
    report = Report()
    entries = list(_walk_archive(path))

    cache = {}

    def read_bytes(rel, member):
        if member not in cache:
            cache[member] = _read_member(path, member)
        return cache[member]

    _check_junk(report, entries)
    _check_empty_dirs(report, entries)
    _check_dangling(report, entries)
    _check_build_paths(report, entries, read_bytes)
    _check_exec_bits(report, entries)
    return report


def _print_human(report, smoke_results):
    if report.clean and not smoke_results:
        print("🌊 Audit: clean")
        return
    for item in report.errors:
        detail = f" — {item['detail']}" if item["detail"] else ""
        print(f"🌊 ERROR  {item['kind']}: {item['path']}{detail}")
    for item in report.warnings:
        detail = f" — {item['detail']}" if item["detail"] else ""
        print(f"🌊 warn   {item['kind']}: {item['path']}{detail}")
    for item in smoke_results:
        if item["status"] == "ok":
            continue
        detail = f" — {item['detail']}" if item["detail"] else ""
        print(f"🌊 smoke  {item['status']}: {item['path']}{detail}")
    ok = sum(1 for item in smoke_results if item["status"] == "ok")
    if smoke_results:
        print(f"🌊 smoke: {ok}/{len(smoke_results)} executable(s) started cleanly")
    print(f"🌊 Audit: {len(report.errors)} error(s), {len(report.warnings)} warning(s)")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Audit a staging tree or a repacked archive before it is uploaded.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--stage", help="staging tree (…/stage)")
    source.add_argument("--archive", help="repacked .tar.bz2 / .tar.gz / .tar.xz")
    parser.add_argument("--smoke", action="store_true",
                        help="also run every Shore/*/*/bin/* once (needs a real stage)")
    parser.add_argument("--json", action="store_true", dest="as_json")
    parser.add_argument("--allow-info", action="store_true",
                        help="treat conda's info/ as acceptable (it is only a warning anyway)")
    args = parser.parse_args(argv)

    if args.archive:
        if args.smoke:
            parser.error("--smoke needs --stage (an archive has no runnable tree)")
        report = audit_archive(args.archive)
    else:
        if not os.path.isdir(args.stage):
            parser.error(f"not a directory: {args.stage}")
        report = audit_stage(args.stage)

    if args.allow_info:
        report.warnings = [w for w in report.warnings if w["kind"] != "conda 元数据 info/"]

    results = smoke(args.stage) if args.smoke else []

    if args.as_json:
        print(json.dumps({"errors": report.errors, "warnings": report.warnings,
                          "smoke": results}, indent=2, ensure_ascii=False))
    else:
        _print_human(report, results)

    return 0 if not report.errors else 1


if __name__ == "__main__":
    sys.exit(main())
