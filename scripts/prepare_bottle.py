#!/usr/bin/env python3

# prepare_bottle.py
# 把一个上游原样搬运的产物重打成「构建时就重定位好」的 prebuilt 产物。
#
# 为什么需要它：Deps / 一部分 Bottle 的字节与上游一致（conda、上游 release），
# 它们的引用是 `@rpath/<名>` + `LC_RPATH=@loader_path/../lib/` —— 装完之后库在
# `Shore/<名>/<版本>/lib/` 下，那串 rpath 解析不到，所以必须改写。
# 本脚本在**服务端**把这一步做掉，产物里就是显式的 `@loader_path/../../<名>/<版本>/lib/...`，
# 客户端只剩「下载 + 解包」——运行时不再改字节，也就不再需要 `wave transfer`。
#
# 布局必须是运行时布局（0.1.0 起包与依赖同构，见 config/configpaths.py）：
#
#     <stage>/Shore/<名>/<版本>/...            软件包与依赖都在这里
#
# 于是相对路径在用户机上同样成立（安装根写死也不受影响：全相对）。
#
# 用法：
#   python3 scripts/prepare_bottle.py --kind deps --name libidn2 --version 2.3.8
#   python3 scripts/prepare_bottle.py --kind pkg  --name htop   --version 3.5.3 --arch arm64
#
# 只下载、重打、打印结果；**不上传、不改索引**。打印出来的就是需要写进记录的三行：
#   sha256、file、relocated: "loader_path"（外加 install: "tree"）。
#
# 索引记录默认从本地 infosource 检出读（--infosource 指定，默认 ~/Projects/SummerwaveOrg/SeaLane），
# 产物默认从镜像站取（与客户端同一组环境变量）。

import argparse
import bz2
import gzip
import hashlib
import os
import re
import lzma
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path
from urllib.parse import quote, unquote

REPO = Path(__file__).resolve().parent.parent
RELOCATE = REPO / "scripts" / "relocate_rpath.py"
sys.path.insert(0, str(REPO / "scripts"))
import components  # noqa: E402

components.add_to_sys_path()

import domains  # noqa: E402  —— 产物命名只此一份（与客户端同一个函数）
# 平台标签与客户端同源（config/platforminfo.bottle_tag），不在这里再抄一份词表。
import platforminfo  # noqa: E402
import stage_audit  # noqa: E402  —— 上传前的体检与冒烟（上游产物同样要过）
DEFAULT_INFOSOURCE = Path.home() / "Projects" / "SummerwaveOrg" / "SeaLane"
MARKER = "_RELOCATED"


# -------------------- 索引 --------------------

def record_path(infosource, kind, arch, name, version, os_name=None):
    # 0.1.0 起索引是单一命名空间：包与依赖同一个目录结构，平台标签编在记录名里。
    # kind 只用来区分「这条记录是包还是依赖」，不再影响落盘位置。
    tag = platforminfo.bottle_tag(arch, os_name=os_name)
    return infosource / name / f"_{name}@{version}.{tag}"


def parse_fields(text):
    # infosource 的简易 DSL，与客户端 pkg/pkginfohelper 的 parse_common_fields 同一套规则：
    # 行内第一个引号前有 `字段:` 就开一个新字段；否则这一行是上一个字段的续行
    # （`deps:` 就是这样跨多行的，漏了续行会把依赖边丢掉）。
    fields = {}
    current = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        head = line.split('"', 1)[0]
        if ':' in head:
            current = head.split(':', 1)[0].strip()
            values = [part.strip('"') for part in line[len(head):].split('"') if part.strip('"')]
            fields.setdefault(current, [])
            fields[current].extend(values)
        elif current and line.startswith('"'):
            fields[current].append(line.strip('"'))
    return {key: "\n".join(values) for key, values in fields.items()}


def read_record(infosource, kind, arch, name, version, os_name=None):
    path = record_path(infosource, kind, arch, name, version, os_name=os_name)
    if not path.is_file():
        sys.exit(f"🌊 Error: no index record at {path}")
    return parse_fields(path.read_text(encoding="utf-8"))


def dep_list(fields):
    raw = fields.get("deps", "")
    return [line.strip() for line in raw.splitlines() if line.strip()]


# -------------------- 取产物 --------------------

def domain(kind):
    name = "SUMMERWAVE_BOTTLE_DOMAIN" if kind == "pkg" else "SUMMERWAVE_DEPS_DOMAIN"
    base = os.environ.get(name, "").rstrip("/")
    if not base:
        sys.exit(f"🌊 Error: {name} is not set; point it at a mirror or leave the tool to "
                 f"download from the record's url (not implemented yet)")
    return base


def legacy_stored_name(name, version, arch, filename):
    """4.x 时代存在 Bottle/Deps Release 里的名字：<名>@<版本>.<架构><扩展名>。

    0.1.0 的产物名换了（带完整瓶子标签），但**旧资产还在**能被这里取件 ——
    重编不依赖任何人先改名。
    """
    for marker in (".tar.xz", ".tar.bz2", ".tar.gz", ".conda", ".zip"):
        if filename.endswith(marker):
            ext = marker
            break
    else:
        ext = os.path.splitext(filename)[1]
    return f"{name}@{version}.{arch}{ext}"


def repacked_name(name, version, arch, os_name=None):
    """重打之后的产物名：<名>@<版本>.<os>-<arch>.tar.bz2（repack 只出 bz2）。

    os_name 不传时按宿主推断（macOS 上就是 macos），所以老用法完全不变。
    """
    out = f"{name}@{version}.{platforminfo.bottle_tag(arch, os_name=os_name)}.tar.bz2"
    # 与客户端拼地址用的是同一个函数，这里当场对齐 —— 一旦两边漂了，宁可在打包时炸
    assert domains.payload_filename(name, version, arch, out, os_name=os_name) == out, out
    return out


def extension_of(filename):
    for marker in (".tar.zst", ".tar.xz", ".tar.bz2", ".tar.gz", ".conda", ".zip"):
        if filename.endswith(marker):
            return marker
    return os.path.splitext(filename)[1]


def candidate_sources(kind, name, version, arch, fields, source, os_name=None):
    """可能存着我们这份字节的地方，按可信度排好。

    为什么不止一个：索引记录里的 `sha256` 描述的是**我们发布的那个文件**，而
    `file:` 记的是**上游**文件名（客户端靠它推扩展名）。两者不是同一个名字 ——
    历史上 `prepare_bottle` 一次就把记录从上游名改成了重打包的 `.tar.bz2`，
    于是「再跑一遍」没有唯一入口可猜。这里把可能的名字都列出来，用 sha256 挑出对的那份：
    对得上就用，对不上就换下一个。sha256 一直在校验，所以猜名字不降低安全性。
    """
    ext = extension_of(fields.get("file", ""))
    tag = platforminfo.bottle_tag(arch, os_name=os_name)
    storage = [
        f"{name}@{version}.{arch}.tar.bz2",     # prepare_bottle 曾经产出的名字
        f"{name}@{version}.{tag}.tar.bz2",      # 0.1.0 改名之后
        f"{name}@{version}.{arch}{ext}",        # 字节原样搬运的旧名字
        f"{name}@{version}.{tag}{ext}",         # 字节原样搬运的新名字
    ]
    candidates = []
    base = os.environ.get("SUMMERWAVE_BOTTLE_DOMAIN" if kind == "pkg" else "SUMMERWAVE_DEPS_DOMAIN", "").rstrip("/")
    if base and source in ("auto", "storage"):
        for stored in dict.fromkeys(storage):        # dict 保序 + 去重
            candidates.append((f"{base}/{name}/{quote(stored)}", stored))
    url = fields.get("url", "")
    if url.startswith("https://") and source in ("auto", "upstream"):
        candidates.append((url, url.split("/")[-1]))
    return candidates


def fetch(kind, name, version, arch, fields, work, source="auto", cache=None, os_name=None):
    """取一份「索引里写的 sha256」对应的字节。

    source=auto     ：先问我们自己的存储（按几个可能的名字试），再回记录里的 url。
    source=storage  ：只问存储。
    source=upstream ：只回上游（字节原样搬运的记录才是同一次哈希）。
    """
    filename = fields.get("file")
    if not filename:
        sys.exit(f"🌊 Error: record for {name}@{version} has no file field")
    expect = fields.get("sha256", "")
    if not expect:
        sys.exit(f"🌊 Error: record for {name}@{version} has no sha256; cannot verify")

    candidates = candidate_sources(kind, name, version, arch, fields, source, os_name=os_name)
    if not candidates:
        sys.exit(f"🌊 Error: no source for {name}@{version} "
                 f"(set SUMMERWAVE_BOTTLE_DOMAIN / SUMMERWAVE_DEPS_DOMAIN, or the record needs a url)")

    for url, basename in candidates:
        out = (cache or work) / f"{name}@{version}.{arch}-{basename}"
        if out.is_file():
            if hashlib.sha256(out.read_bytes()).hexdigest() == expect:
                print(f"🌊 cached  {out.name}")
                return out, filename
            out.unlink()
        print(f"🌊 fetching {url[:120]}", flush=True)
        if not download_to(url, out):
            continue
        if hashlib.sha256(out.read_bytes()).hexdigest() == expect:
            return out, filename
        out.unlink(missing_ok=True)

    sys.exit(f"🌊 Error: none of the {len(candidates)} candidate(s) matched sha256 {expect[:12]}… "
             f"for {name}@{version}.{arch}")


# GitHub release 资产的规范地址：`…/releases/download/<tag>/<file>`。
# 取件的上限。必须设：`gh release download` 与 curl 都没有默认超时，一个卡住的
# 连接会把整批重打永久挂在那里 —— 实测遇上过（flyctl 的包在 10 分钟里一动不动，
# 而批处理只是「在等」）。
FETCH_TIMEOUT = 900

GH_RELEASE_RE = re.compile(
    r"^https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/releases/download/"
    r"(?P<tag>[^/]+)/(?P<asset>.+)$")


def download_to(url, out):
    """把 url 取到 out，成功返回 True。

    GitHub 的 release 资产优先走 `gh release download`：它先打 api.github.com 拿重定向，
    完全不碰 github.com 这个域名。实测同一条链路里 `github.com:443` 十次有三次超时
    （校园网与家宽都会掐它），而 api 一直通 —— 批量重打时那三次就是一整批失败。

    `gh` 不可用、或地址不是 GitHub release 形态时回落 curl，行为与以前完全一致。
    """
    out.parent.mkdir(parents=True, exist_ok=True)
    match = GH_RELEASE_RE.match(url)
    if match and shutil.which("gh"):
        asset = unquote(match.group("asset"))
        try:
            result = subprocess.run(
                ["gh", "release", "download", unquote(match.group("tag")),
                 "-R", f"{match.group('owner')}/{match.group('repo')}",
                 "-p", asset, "-D", str(out.parent), "--clobber"],
                capture_output=True, timeout=FETCH_TIMEOUT)
        except subprocess.TimeoutExpired:
            print(f"🌊   gh timed out after {FETCH_TIMEOUT}s; falling back to curl",
                  file=sys.stderr)
            result = None
        if result is not None and result.returncode == 0:
            produced = out.parent / asset
            if produced.is_file():
                if produced != out:
                    produced.replace(out)
                return True
    return subprocess.run(
        ["curl", "-fsSL", "--http1.1", "--retry", "3",
         "--max-time", str(FETCH_TIMEOUT), "-o", str(out), url]).returncode == 0


# -------------------- 解包 / 打包 --------------------

def extract(path, dest, name_hint=None):
    # name_hint 是记录里的 `file:`（上游发布名）。单文件产物必须按它落地：
    # 下载缓存的临时名是 `<名>@<版本>.<arch>-<上游名>`，直接落盘会让用户看到
    # `Shore/jq/1.8.2/jq@1.8.2.arm64-jq-linux-arm64` 这种东西。
    name = path.name
    # `.tgz` / `.tbz2` / `.txz` 是同一种东西的短写法，而 `tarfile` 按内容认格式、不看后缀，
    # 所以这里必须把后缀也列全：漏掉 `.tgz` 的后果是**整个压缩包被原样拷进 stage**，
    # 重打出来的产物里躺着一个压缩包（cloudflared 就是这样），而 relocate 看不见它、
    # 闸门也不报错 —— 装到用户机上才发现是个空壳。
    if name.endswith((".tar.xz", ".tar.bz2", ".tar.gz", ".tar.zst",
                      ".tgz", ".tbz2", ".txz")):
        with tarfile.open(path) as archive:
            archive.extractall(dest)
        return
    if name.endswith(".zip"):
        with zipfile.ZipFile(path) as archive:
            archive.extractall(dest)
        return
    if name.endswith(".conda"):
        # .conda = zip 里装着 pkg-*.tar.zst（Python 3.14+ 的 compression.zstd 能解）
        inner = dest.parent / (dest.name + "-conda")
        inner.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path) as archive:
            archive.extractall(inner)
        # `.conda` 里有两个成员：`pkg-*.tar.zst`（真正的产物）与 `info-*.tar.zst`
        # （包元数据）。两个都要解 —— 只解第一个会把产物解成空树，而空树「检查通过」，
        # 于是被误判为 already-prebuilt（2026-11-26 踩过）。
        members = sorted(p for p in inner.iterdir() if p.name.endswith(".tar.zst"))
        if not members:
            sys.exit(f"🌊 Error: {path.name} has no .tar.zst member")
        for member in members:
            rc = subprocess.run(["tar", "--zstd", "-xf", str(member), "-C", str(dest)]).returncode
            if rc != 0:
                sys.exit(f"🌊 Error: cannot extract {member.name} (needs bsdtar with zstd)")
        return
    # 单文件压缩（`ffmpeg-darwin-arm64.gz`、CI 夹具 `test_bin.bz2`）：**没有成员名**，
    # 解出来的名字只能从文件名推 —— 去掉压缩后缀就是目标名，与上游发布习惯一致。
    single = next((s for s in (".gz", ".xz", ".bz2")
                   if name.endswith(s) and not name.endswith(
                       (".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2"))), None)
    if single:
        dest.mkdir(parents=True, exist_ok=True)
        base = name_hint or name
        if base.endswith(single):
            base = base[: -len(single)]
        opener = {".gz": gzip.open, ".xz": lzma.open, ".bz2": bz2.open}[single]
        with opener(path, "rb") as src, open(dest / base, "wb") as out:
            shutil.copyfileobj(src, out)
        return
    shutil.copy2(path, dest / (name_hint or name))

def parse_has_prefix(path):
    entries = []
    if not path.is_file():
        return entries
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) == 3:
            placeholder, mode, relative = parts
        elif len(parts) == 2:          # 老格式：省略 mode，默认 text
            placeholder, relative = parts
            mode = "text"
        else:
            continue
        entries.append((placeholder, mode, relative))
    return entries


def apply_has_prefix(target, install_prefix):
    """把 info/has_prefix 列出的占位符换成安装后的绝对路径。返回 (改动数, 遗留列表)。"""
    entries = parse_has_prefix(target / "info" / "has_prefix")
    if not entries:
        return 0, []

    prefix_bytes = install_prefix.encode()
    touched = 0
    leftovers = []
    for placeholder, mode, relative in entries:
        path = target / relative
        if not path.is_file() or path.is_symlink():
            continue
        needle = placeholder.encode()
        if mode == "binary":
            data = path.read_bytes()
            if needle not in data:
                continue
            # 同长度替换：前缀 + NUL 补齐，保证文件长度与偏移不变
            if len(prefix_bytes) > len(needle):
                leftovers.append(f"{relative}（前缀比占位符长，binary 模式放不下）")
                continue
            data = data.replace(needle, prefix_bytes + b"\x00" * (len(needle) - len(prefix_bytes)))
            path.write_bytes(data)
            touched += 1
            continue

        text = path.read_text(errors="surrogateescape")
        if needle.decode() not in text:
            continue
        if mode == "script":
            # shebang 只在首行；其余行里的前缀属于同一件事，一起换也无害
            text = text.replace(needle.decode(), install_prefix)
        else:
            text = text.replace(needle.decode(), install_prefix)
        path.write_text(text, errors="surrogateescape")
        touched += 1

    # 复查：has_prefix 点过名的文件里不许再有占位符
    for placeholder, _mode, relative in entries:
        path = target / relative
        if path.is_file() and not path.is_symlink():
            if placeholder.encode() in path.read_bytes():
                leftovers.append(relative)
    return touched, leftovers


def install_prefix_for(kind, name, version):
    """安装后的绝对路径：<安装根>/Shore/<名>/<版本>（根写死，所以构建时就能算）。"""
    base = os.environ.get("MACWAVE_PREBUILT_PREFIX_ROOT", "")
    if not base:
        base = platforminfo.DEFAULT_BASE_DIR if platforminfo.IS_MAC else "/home/linuxwave/.linuxwave"
    base = base.rstrip("/")
    return f"{base}/Shore/{name}/{version}"


# 解压 staging 之后、打包之前，产物里绝不能出现「本次解压用的临时路径」——
# 那个目录在打包结束就被删掉，产物里一旦写进它，用户机上就是一条死路
# （典型症状：跑起来才 "Library not loaded"，或者 .pc / wrapper 指向不存在的目录）。
# 判据是**我们自己这一轮的 work/stage 路径**，不是所有临时路径：conda 产物里本来就
# 烙着上游构建机的 /private/var/folders/.../croot/...，那是历史包袱，不是缺陷。
AUDIT_CHUNK = 1 << 20


def audit_archive(out_file, roots):
    """返回写进了「本轮临时路径」的成员名列表；空列表表示干净。"""
    needles = [os.fsencode(str(root)) for root in roots if root]
    if not needles:
        return []
    overlap = max(len(n) for n in needles) - 1
    found = []
    with tarfile.open(out_file) as archive:
        for member in archive:
            if not member.isfile():
                continue
            stream = archive.extractfile(member)
            if stream is None:
                continue
            tail = b""
            while True:
                chunk = stream.read(AUDIT_CHUNK)
                if not chunk:
                    break
                window = tail + chunk
                if any(needle in window for needle in needles):
                    found.append(member.name)
                    break
                tail = window[-overlap:] if overlap else b""
    return found


def repack(version_dir, out_file):
    # 以版本目录的内容为根打包：客户端解包后就是 <版本目录>/bin/...、<版本目录>/lib/...
    #
    # `_RELOCATED` 不进产物。它原本是给 4.x 客户端看的「这棵树已经重定位过」的标记，
    # 而 0.1.0 的客户端只做「下载 + 解包」，从不读它；留着反而有害：sorted() 让下划线
    # 排在字母前面，于是单文件产物里它成了 tar 的第一个成员，而客户端在找不到与
    # bin_name 同名的文件时会「用第一个」—— 那个「第一个」就是这行 13 字节的文本。
    with tarfile.open(out_file, "w:bz2") as archive:
        for entry in sorted(version_dir.iterdir()):
            if entry.name == MARKER:
                continue
            archive.add(entry, arcname=entry.name)
    return hashlib.sha256(out_file.read_bytes()).hexdigest()


# -------------------- 主流程 --------------------

MACHO_MAGICS = {"feedface", "feedfacf", "cefaedfe", "cffaedfe", "cafebabe"}


def _is_macho(path):
    try:
        with open(path, "rb") as handle:
            return handle.read(4).hex() in MACHO_MAGICS
    except OSError:
        return False


def _has_macho(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if not os.path.islink(path) and _is_macho(path):
                return True
    return False


# 源码 tarball 的特征文件。出现任何一个、并且树里一个 Mach-O 都没有，就说明这条记录
# 的 `url` 指向上游**源码**发布，而不是可安装产物。
SOURCE_MARKERS = ("configure.ac", "CMakeLists.txt", "Makefile.am", "meson.build",
                  "configure", "Makefile.in")


def looks_like_source(root):
    markers = 0
    for entry in os.scandir(root):
        if entry.is_file() and entry.name in SOURCE_MARKERS:
            markers += 1
    if not markers:
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                if name.endswith((".c", ".h", ".cc", ".cpp")):
                    return True
        return False
    return True


def stage_target(stage, kind, name, version):
    # 包与依赖同构（0.1.0 起）：<stage>/Shore/<名>/<版本>/。kind 只影响记录字段，
    # 不影响落盘位置 —— 这正是「卸载只要看一个根」的来源。
    return stage / "Shore" / name / version


def prepare(infosource, kind, name, version, arch, out_dir, keep,
            source="auto", cache=None, smoke=True, audit=True, os_name=None):
    work = Path(tempfile.mkdtemp(prefix=f"prepare-{name}-"))
    try:
        stage = work / "stage"
        # 1. 先把依赖闭包摆好：重定位要按「运行时布局」算相对路径，
        #    缺了兄弟依赖就既算不出路径、也判断不了 @rpath 能不能解析。
        todo = [(kind, name, version)]
        seen = set()
        while todo:
            current_kind, current_name, current_version = todo.pop()
            key = (current_kind, current_name, current_version)
            if key in seen:
                continue
            seen.add(key)
            fields = read_record(infosource, current_kind, arch, current_name,
                                 current_version, os_name=os_name)
            target = stage_target(stage, current_kind, current_name, current_version)
            target.mkdir(parents=True, exist_ok=True)
            payload, upstream_name = fetch(current_kind, current_name, current_version, arch,
                                           fields, work, source=source, cache=cache,
                                           os_name=os_name)
            extract(payload, target, upstream_name)
            # 记录里的 `url` 有时指向上游**源码**发布（那说明这条从来没发过 macOS 产物，
            # oniguruma 就是这样）。这种包重打没有意义：源码树搬过去也跑不起来。
            # 不拦的话产物里会躺着一棵源码树，而 relocate 只认 Mach-O，看不见它，
            # 结果一路「检查通过」到最后。
            if not _has_macho(target) and looks_like_source(target):
                sys.exit(
                    f"🌊 Error: {current_name}@{current_version} ({current_kind}, {arch}) "
                    f"resolves to an upstream **source** tarball ({payload.name}), not an "
                    "installable payload.\n"
                    "   这条记录从来没有发过 macOS 产物 —— 要走源码编：在 MacWaveOrg/Ports "
                    "下加一个整树端口（照 zlib/build.sh），再把产物当 prebuilt 回填。")
            for ref in dep_list(fields):
                dep_name, _, dep_version = ref.partition("@")
                todo.append(("deps", dep_name, dep_version))

        # 2. 重定位整棵 stage，并确认真的位置无关了
        target = stage_target(stage, kind, name, version)

        print(f"🌊 relocating {len(seen)} artifact(s) in the staging tree")
        rc = subprocess.run([sys.executable, str(RELOCATE), str(stage)])
        if rc.returncode != 0:
            sys.exit("🌊 Error: relocation failed; nothing was written")
        rc = subprocess.run([sys.executable, str(RELOCATE), str(stage), "--check"])
        if rc.returncode != 0:
            sys.exit("🌊 Error: staging tree is still not position-independent")

        # 2.5 conda 的占位前缀 → 安装后的绝对路径（.pc / wrapper / 编译进去的资源目录）
        touched, leftovers = apply_has_prefix(target, install_prefix_for(kind, name, version))
        if touched:
            print(f"🌊 rewrote prefixes in {touched} file(s) listed by info/has_prefix")
        if leftovers:
            sys.exit("🌊 Error: has_prefix placeholders survive in "
                     + ", ".join(leftovers[:5]) + " — the payload would point at the build machine")

        # 2.6 静态体检：悬空链接、执行位、Mach-O 引用构建机路径这类「装完才炸」
        #     的东西，必须在打包之前拦住。上游产物不是我们编的，这些都可能带着。
        if audit:
            stage_report = stage_audit.audit_stage(stage)
            for item in stage_report.errors:
                detail = f" — {item['detail']}" if item["detail"] else ""
                print(f"🌊 ERROR  {item['kind']}: {item['path']}{detail}", file=sys.stderr)
            if stage_report.errors:
                sys.exit("🌊 Error: the staging tree is not installable (see errors above)")
            for item in stage_report.warnings:
                detail = f" — {item['detail']}" if item["detail"] else ""
                print(f"🌊 warn   {item['kind']}: {item['path']}{detail}")

        # 2.7 冒烟：真跑一次。上游产物把 /tmp 或构建机路径烘进了 load command、
        #     或者依赖闭包不全，静态检查都看不出来 —— dyld 要到执行那一刻才说话。
        #
        # 跨平台重打时跳过：在 macOS 上执行 Linux 的 ELF 必然 exec format error，
        # 那不是产物坏了。真验证要在目标平台上跑（见 docs/ADD-PACKAGE-CHECKLIST）。
        host_os = "macos" if platforminfo.IS_MAC else "linux"
        if smoke and (os_name or host_os) != host_os:
            print(f"🌊 smoke: skipped — the payload is for {os_name or host_os}, "
                  f"this host is {host_os}")
        elif smoke:
            results = stage_audit.smoke(stage)
            broken = [r for r in results if r["status"] in ("dyld-error", "exec-failed")]
            for item in broken:
                print(f"🌊 smoke {item['status']}: {item['path']} — {item['detail']}",
                      file=sys.stderr)
            if broken:
                sys.exit("🌊 Error: the payload cannot start on this machine; "
                         "it would be just as broken on the user's")
            started = sum(1 for r in results if r["status"] == "ok")
            if results:
                print(f"🌊 smoke: {started}/{len(results)} executable(s) started cleanly")

        # 3. 打标记 + 只重打目标产物（依赖由它们自己那一轮处理）
        (target / MARKER).write_text("@loader_path\n", encoding="utf-8")
        out_dir.mkdir(parents=True, exist_ok=True)
        out_file = out_dir / repacked_name(name, version, arch, os_name=os_name)
        digest = repack(target, out_file)

        if audit:
            packed = stage_audit.audit_archive(out_file)
            for item in packed.errors:
                detail = f" — {item['detail']}" if item["detail"] else ""
                print(f"🌊 ERROR  {item['kind']}: {item['path']}{detail}", file=sys.stderr)
            if packed.errors:
                out_file.unlink(missing_ok=True)
                sys.exit("🌊 Error: the repacked archive is not installable "
                         "(see errors above); nothing was kept")

        leaks = audit_archive(out_file, (stage, work))
        if leaks:
            out_file.unlink(missing_ok=True)
            sys.exit("🌊 Error: the archive baked in this run's temporary path "
                     f"({work}); it would be dead on the user's machine.\n"
                     "   offending members: " + ", ".join(leaks[:5]))

        print()
        print("🌊 Done. Write these into the record (and upload the archive):")
        print(f"   file:  \"{out_file.name}\"")
        print(f"   sha256: \"{digest}\"")
        print('   relocated: "loader_path"')
        if (target / "bin").is_dir():
            print('   install: "tree"        # 归档里有 bin/，按整树解包')
        else:
            # 单文件上游（例如 Golang/Rust 的裸二进制）：归档根就是那个文件，
            # 写 install: "tree" 反而会让安装器去找 bin/<名> 然后失败。
            print('   install: （不要写）     # 归档根是单个文件，按 binary 模式装')
        print(f"   archive: {out_file}")
        if keep:
            print(f"   staging: {stage}")
        return {"kind": kind, "name": name, "version": version, "arch": arch,
                "file": out_file.name, "sha256": digest, "archive": str(out_file),
                "staged": len(seen)}
    finally:
        if not keep:
            shutil.rmtree(work, ignore_errors=True)


def batch(infosource, out_dir, source, cache, only, limit, kinds, tsv, skip_existing,
          smoke=True, audit=True, os_name=None):
    """把索引里所有记录重打一遍。断点续跑：产物已在 out_dir 就跳过。"""
    from sync_payloads import records

    todo = []
    for kind, arch, name, version, record in records(infosource):
        # sync_payloads 用 bottle/deps 命名（产物侧），索引与记录用 pkg/deps
        kind = "pkg" if kind == "bottle" else "deps"
        if kinds and kind not in kinds:
            continue
        if only and name not in only:
            continue
        todo.append((kind, arch, name, version, record))
    if limit:
        todo = todo[:limit]

    print(f"🌊 {len(todo)} payload(s) to rebuild (source: {source})", flush=True)
    done = skipped = 0
    failures = []
    if tsv and not Path(tsv).exists():
        Path(tsv).write_text("kind\tname\tversion\tarch\tfile\tsha256\n", encoding="utf-8")

    for index, (kind, arch, name, version, record) in enumerate(todo, 1):
        expected = out_dir / repacked_name(name, version, arch, os_name=os_name)
        if skip_existing and expected.is_file():
            skipped += 1
            continue
        print(f"\n=== [{index}/{len(todo)}] {name}@{version} ({kind}, {arch}) ===", flush=True)
        try:
            result = prepare(infosource, kind, name, version, arch, out_dir,
                             keep=False, source=source, cache=cache,
                             smoke=smoke, audit=audit, os_name=os_name)
        except SystemExit as error:            # prepare() 用 sys.exit 报错
            failures.append((f"{name}@{version}.{arch}", str(error)))
            print(f"🌊 FAILED: {error}", flush=True)
            continue
        done += 1
        if tsv:
            with open(tsv, "a", encoding="utf-8") as stream:
                stream.write("\t".join([result["kind"], result["name"], result["version"],
                                        result["arch"], result["file"], result["sha256"]]) + "\n")

    print()
    print(f"🌊 rebuilt {done}, skipped {skipped}, failed {len(failures)}", flush=True)
    for label, reason in failures[:20]:
        print(f"   ✗ {label}: {reason.splitlines()[0] if reason else 'unknown'}")
    if len(failures) > 20:
        print(f"   … and {len(failures) - 20} more")
    return 0 if not failures else 1


def main():
    parser = argparse.ArgumentParser(
        description="Repack upstream payloads into prebuilt artifacts (build-time relocation)")
    parser.add_argument("--kind", choices=("pkg", "deps"))
    parser.add_argument("--name")
    parser.add_argument("--version")
    parser.add_argument("--arch", default="arm64", choices=("arm64", "amd64"))
    parser.add_argument("--os", default=None, choices=("macos", "linux"),
                        help="target platform; defaults to the host "
                             "(only matters when naming the artifact and picking the record)")
    parser.add_argument("--all", action="store_true",
                        help="rebuild every record in the index (use --only/--limit/--kinds to narrow)")
    parser.add_argument("--only", default="", help="comma-separated package names (with --all)")
    parser.add_argument("--limit", type=int, default=0, help="stop after N payloads (with --all)")
    parser.add_argument("--kinds", default="", help="comma-separated: pkg,deps (with --all)")
    parser.add_argument("--source", default="auto", choices=("auto", "upstream", "storage"),
                        help="auto = our storage first, then the record's url (default); "
                             "storage = only Bottle/Deps; upstream = only the record's url")
    parser.add_argument("--cache", default="", help="keep downloaded payloads here (batch mode)")
    parser.add_argument("--tsv", default="", help="append kind/name/version/arch/file/sha256 rows here")
    parser.add_argument("--resume", action="store_true",
                        help="skip payloads whose rebuilt archive already exists (with --all)")
    parser.add_argument("--infosource", default=str(DEFAULT_INFOSOURCE))
    parser.add_argument("--out", default=str(Path.cwd() / "prebuilt"))
    parser.add_argument("--keep", action="store_true", help="keep the staging tree for inspection")
    parser.add_argument("--no-smoke", action="store_true",
                        help="skip running every executable once (faster batch runs)")
    parser.add_argument("--no-audit", action="store_true",
                        help="skip the static staging/archive audit (not recommended)")
    args = parser.parse_args()

    if not RELOCATE.is_file():
        sys.exit(f"🌊 Error: {RELOCATE} not found")

    cache = Path(args.cache) if args.cache else None
    if cache:
        cache.mkdir(parents=True, exist_ok=True)

    if args.all:
        only = {n.strip() for n in args.only.split(",") if n.strip()}
        kinds = {k.strip() for k in args.kinds.split(",") if k.strip()}
        return batch(Path(args.infosource), Path(args.out), args.source, cache,
                     only, args.limit, kinds, args.tsv, args.resume,
                     smoke=not args.no_smoke, audit=not args.no_audit, os_name=args.os)

    if not (args.kind and args.name and args.version):
        parser.error("either --all, or --kind + --name + --version")
    prepare(Path(args.infosource), args.kind, args.name, args.version,
            args.arch, Path(args.out), args.keep, source=args.source, cache=cache,
            smoke=not args.no_smoke, audit=not args.no_audit, os_name=args.os)
    return 0


if __name__ == "__main__":
    sys.exit(main())
