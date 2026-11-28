#!/usr/bin/env python3

# verify_payload_arch.py
#
# 核对「索引声明」与「产物实际架构」是否一致。
#
# 为什么需要它：记录写着 `linux-arm64`，产物却是 macOS 或另一个架构的二进制 ——
# 这种错配**下载时不会报错，装完才炸**（`cannot execute binary file`）。ollama
# 那 6 条就是活例子：名字里明明是 `linux-arm64`，指向的却是 NVIDIA Jetson 专用的
# `jetpack5` 变体，普通 ARM64 Linux 上根本跑不起来。
#
# 做法：只取每个产物的**前 1 MB**（HTTP Range），解压出包里的第一个普通文件，
# 读它的魔数判断真实平台与架构。不下载整包，所以 880 个产物也就几百 MB 流量。
#
#   ELF    `\x7fELF`            e_machine: 0x3E=x86-64, 0xB7=AArch64
#   Mach-O `\xcf\xfa\xed\xfe`   cputype:   0x01000007=x86_64, 0x0100000C=arm64
#   fat    `\xca\xfe\xba\xbe`   通用二进制，任一架构都算对
#
# 用法：
#   python3 scripts/verify_payload_arch.py --os linux              # 只查 Linux
#   python3 scripts/verify_payload_arch.py --os all                # 两个平台
#   python3 scripts/verify_payload_arch.py --os linux --only jq,rg # 只查这几个包
#   python3 scripts/verify_payload_arch.py --os linux --limit 20   # 抽样
#
# 退出码：0 = 没发现错配（未判定的不算错配），1 = 有错配。

import argparse
import bz2
import concurrent.futures
import gzip
import io
import lzma
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.request

INDEX = pathlib.Path.home() / "Projects/SummerwaveOrg/SeaLane"
# 走 api.github.com 的 assets/<id>，不走 github.com/.../releases/download/：
# 后者在国内实测**连不上**（2026-11-28：api.github.com 200 / 0.56s，github.com 超时），
# 而 assets 接口会 302 到 objects.githubusercontent.com，那个域名是通的。
BOTTLE_REPO = "SummerwaveOrg/Bottle"
ASSET_API = f"https://api.github.com/repos/{BOTTLE_REPO}/releases/assets"
PREFIX_BYTES = 1 << 20          # 只取前 1 MB
TIMEOUT = 20
# api.github.com 对匿名请求只给 60 次/小时 —— 四百多个产物会被限流打成一片
# 403。复用 gh 的 token 提到 5000 次/小时。
TOKEN = ""


def github_token():
    result = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""
WORKERS = 8              # GitHub 在国内不稳，并发把总时长从「条数×超时」压下来
UA = "Summerwave/verify-payload-arch"

# 平台标签 → 期望的二进制格式
EXPECT = {
    "linux-arm64": ("elf", "arm64"),
    "linux-amd64": ("elf", "x86_64"),
    "macos-arm64": ("macho", "arm64"),
    "macos-amd64": ("macho", "x86_64"),
}

RECORD_RE = re.compile(r"^_([^@]+)@(.+)\.((?:linux|macos)-(?:arm64|amd64))$")

ELF_MACHINE = {0x3E: "x86_64", 0xB7: "arm64", 0x03: "x86", 0x28: "arm"}
MACHO_CPU = {
    0x01000007: "x86_64",
    0x0100000C: "arm64",
    0x00000007: "x86",
    0x0000000C: "arm",
}

# 后缀 → 解压器的 open 函数（**不是模块本身**：模块不可调用）。
# zip / zst 先不处理：zip 要完整文件，zst 要额外模块。
SUFFIX_OPENER = {".gz": gzip.open, ".tgz": gzip.open, ".bz2": bz2.open, ".xz": lzma.open}


IDS = {}


class Stat:
    def __init__(self):
        self.ok = 0
        self.wrong = []
        self.unknown = []
        self.error = []
        self.skipped = 0


def read_records(index_dir, oses, only):
    """返回 [(包名, 记录名, 平台标签, 版本)]，记录名形如 jq@1.8.2.linux-arm64。"""
    out = []
    for record in sorted(index_dir.glob("*/_*@*.linux-*")) + \
            sorted(index_dir.glob("*/_*@*.macos-*")):
        match = RECORD_RE.match(record.name)
        if not match:
            continue
        pkg, version, tag = match.group(1), match.group(2), match.group(3)
        if tag.split("-")[0] not in oses:
            continue
        if only and pkg not in only:
            continue
        if pkg.startswith("test_"):
            continue
        out.append((pkg, record.name[1:], tag, version))
    return out


def asset_ids():
    """资产名 → asset id。一次 gh api 分页拉完，之后每个文件只发一条 Range 请求。"""
    result = subprocess.run(
        ["gh", "api", f"repos/{BOTTLE_REPO}/releases", "--paginate",
         "-q", '.[] | .assets[] | "\\(.name)\\t\\(.id)"'],
        capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        raise SystemExit(f"gh api 失败：{result.stderr.strip()[:200]}")
    mapping = {}
    for line in result.stdout.splitlines():
        if "\t" in line:
            name, _, ident = line.partition("\t")
            mapping[name] = ident.strip()
    return mapping


def fetch_prefix(url, nbytes=PREFIX_BYTES):
    """用 curl 而不是 urllib。

    这台机器的 Python 3.14（Homebrew）没有配 CA 证书库，urllib 一律报
    `CERTIFICATE_VERIFY_FAILED`，而 curl 自带证书所以正常 —— net/domains.py 里
    「urllib 失败回落 curl」处理的也是同一件事，这里直接走 curl 省一次失败。
    """
    headers = ["-H", "Accept: application/octet-stream", "-A", UA]
    if TOKEN:
        headers += ["-H", f"Authorization: Bearer {TOKEN}"]
    result = subprocess.run(
        ["curl", "-fsSL", "--max-time", str(TIMEOUT),
         "-r", f"0-{nbytes - 1}", *headers, url],
        capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(f"curl exit {result.returncode}")
    return result.stdout[:nbytes]


def decompress_prefix(blob, suffix):
    """解压前若干字节。流被截断时解压器会抛异常，但已解出的部分照样能用。"""
    opener = SUFFIX_OPENER.get(suffix)
    if opener is None:
        return None
    out = bytearray()
    try:
        stream = opener(io.BytesIO(blob), "rb")
        while len(out) < 8 << 20:
            chunk = stream.read(1 << 16)
            if not chunk:
                break
            out += chunk
    except Exception:
        pass
    return bytes(out) or None


def first_binary_bytes(tar_bytes, limit=40):
    """tar 里第一个**可识别的二进制**的前 64 字节。

    不能只看第一个普通文件：产物包里排在最前面的通常是 LICENSE / README，
    真正的可执行文件在后面（`act` 包里第三个才是 act，20 MB）。
    也不用 tarfile —— 流是被截断的（只下了前 1 MB），tarfile 一遇 EOF 就把
    整个归档判为损坏、什么都不给；而 tar 的 header 是固定 512 字节块，自己
    走一遍就能在任意位置停下。
    """
    offset = 0
    seen = 0
    while offset + 512 <= len(tar_bytes) and seen < limit:
        header = tar_bytes[offset:offset + 512]
        if not header[:100].strip(b"\0"):
            break                                  # 结束块
        name = header[:100].split(b"\0")[0].decode("utf-8", "replace")
        raw_size = header[124:136].split(b"\0")[0].strip() or b"0"
        try:
            size = int(raw_size, 8)
        except ValueError:
            return None
        typeflag = header[156:157]
        body = offset + 512
        if typeflag in (b"0", b"\0", b"7"):       # 普通文件 / 连续文件
            seen += 1
            head = tar_bytes[body:body + 64]
            if probe(head)[0] in ("elf", "macho", "fat"):
                return name, head
        offset = body + (size + 511) // 512 * 512  # 跳过这个成员的数据块
    return None


def probe(blob):
    """判 (格式, 架构)；认不出来返回 (None, None)。"""
    if len(blob) < 8:
        return None, None
    if blob[:4] == b"\x7fELF":
        if len(blob) < 20:
            return "elf", None
        machine = int.from_bytes(blob[18:20], "little")
        return "elf", ELF_MACHINE.get(machine, f"machine-{machine:#x}")
    if blob[:4] == b"\xcf\xfa\xed\xfe" or blob[:4] == b"\xce\xfa\xed\xfe":
        if len(blob) < 8:
            return "macho", None
        cpu = int.from_bytes(blob[4:8], "little")
        return "macho", MACHO_CPU.get(cpu, f"cpu-{cpu:#x}")
    if blob[:4] == b"\xca\xfe\xba\xbe":
        return "fat", "universal"
    if blob[:2] == b"#!":
        return "script", None
    return None, None


def check_one(pkg, stem, tag, stat):
    want_format, want_arch = EXPECT[tag]
    # 产物一律是 prepare_bottle 重打出来的 .tar.bz2（实测 882 个全是），不跟上
    # 游原文件的后缀走 —— 记录里的 `file:` 指上游，我们的产物名另有规则。
    suffix = ".bz2"
    asset = f"{stem}.tar.bz2"
    ident = IDS.get(asset)
    if ident is None:
        stat.error.append((asset, "Release 里没有这个资产"))
        return
    url = f"{ASSET_API}/{ident}"
    try:
        blob = fetch_prefix(url)
    except Exception as error:
        stat.error.append((stem, type(error).__name__))
        return

    tar_bytes = decompress_prefix(blob, suffix)
    if not tar_bytes:
        stat.skipped += 1
        return
    found = first_binary_bytes(tar_bytes)
    if not found:
        stat.skipped += 1
        return

    name, head = found
    fmt, arch = probe(head)
    if fmt in ("script", None):
        stat.skipped += 1
        return
    if fmt == "fat" or (fmt == want_format and arch == want_arch):
        stat.ok += 1
        return
    stat.wrong.append((stem, f"{name}: {fmt}/{arch}", f"期望 {want_format}/{want_arch}"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--os", default="linux", choices=["linux", "macos", "all"])
    parser.add_argument("--only", default="", help="逗号分隔的包名")
    parser.add_argument("--limit", type=int, default=0, help="只查前 N 条（抽样）")
    parser.add_argument("--index", default=str(INDEX), help="索引仓库路径")
    args = parser.parse_args()

    global IDS, TOKEN
    TOKEN = github_token()
    print(f"🌊 凭据：{'gh token（5000 次/小时）' if TOKEN else '匿名（60 次/小时，会被限流）'}")
    IDS = asset_ids()
    print(f"🌊 Release 资产 {len(IDS)} 个")
    oses = {"linux", "macos"} if args.os == "all" else {args.os}
    only = {name.strip() for name in args.only.split(",") if name.strip()}
    records = read_records(pathlib.Path(args.index), oses, only)
    if args.limit:
        records = records[: args.limit]
    if not records:
        print("没有匹配的记录。", file=sys.stderr)
        return 1

    print(f"🌊 待查 {len(records)} 条（平台 {'/'.join(sorted(oses))}），"
          f"每条只取前 {PREFIX_BYTES >> 20} MB，{WORKERS} 路并发")
    stat = Stat()
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = [pool.submit(check_one, pkg, stem, tag, stat)
                   for pkg, stem, tag, _version in records]
        for future in concurrent.futures.as_completed(futures):
            future.result()
            done += 1
            if done % 20 == 0 or done == len(records):
                print(f"   [{done}/{len(records)}] ok={stat.ok} "
                      f"错配={len(stat.wrong)} 跳过={stat.skipped} 失败={len(stat.error)}",
                      flush=True)

    print()
    if stat.wrong:
        print(f"❌ 架构错配 {len(stat.wrong)} 条：")
        for stem, got, want in stat.wrong:
            print(f"   {stem}\n      {got}  ←  {want}")
    if stat.error:
        print(f"⚠️  取不到 {len(stat.error)} 条（网络或资产缺失）：")
        for stem, why in stat.error[:15]:
            print(f"   {stem}  {why}")
        if len(stat.error) > 15:
            print(f"   …… 另有 {len(stat.error) - 15} 条")
    print(f"\n一致 {stat.ok} 条，跳过 {stat.skipped} 条（脚本/无法解包）")
    return 1 if stat.wrong else 0


if __name__ == "__main__":
    sys.exit(main())
