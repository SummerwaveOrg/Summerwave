#!/usr/bin/env python3

# build_installer.py
#
# 生成「这一版」的 install.sh —— 把这一版的文件清单内嵌进模板。
#
# 为什么要有它：0.1.0 起清单不再放在 Selfupdate 仓库里（那个仓库下线了）。清单跟着安装器
# 走，好处是三件事同时成立：
#   * 装什么由一份被签名的文件说了算（读一个文件就能审计「这次会写哪些字节」）；
#   * 客户端仍然能「逐文件比对哈希、只下变化的那些」—— 升级不必重下整棵树；
#   * 少一次网络往返：清单不需要取。
#
# 清单格式（与 4.7 的 files.txt 同形）：
#
#     <仓库内路径> <0|1 是否 +x> <sha256>
#
# 与 4.7 的差别只有一处：**可执行位取自 git 的 mode（100755）**，不再靠 `.sh` 后缀猜。
# 以前能跑通是运气 —— 安装集合里恰好没有非 .sh 的可执行文件。
#
# 用法：
#   python3 scripts/build_installer.py --version 1.2.3@2026-11-26T11:23Z --out dist/install.sh
#   python3 scripts/build_installer.py --version 1.2.3@2026-11-26T11:23Z --ref v1.2.3@2026-11-26T11:23Z
#
# 只读仓库、只写 --out；不签名、不发版。签名与上传由发布流水线做。

import argparse
import hashlib
import re
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

import build_update_commands as buc  # noqa: E402  —— 清单的「装什么」只此一份

# 生成物里的信号：安装器靠它判断「这份脚本自带清单」，无需联网取。
MANIFEST_SIGNAL = "MACWAVE_MANIFEST_VERSION"
MANIFEST_OPEN = "MANIFEST_EOF"
HEADER = """\
# ==========================================
# 内嵌清单 —— 由 scripts/build_installer.py 生成，不要手工编辑
# ==========================================
#
# 这一版的安装树该长什么样，只写在下面这一段里：每行
#     <仓库内路径> <0|1 是否 +x> <sha256>
# 安装器据此逐条比对本地文件，只下载与清单不一致的那些。
"""


def git(args):
    result = subprocess.run(["git", "-C", str(REPO_DIR)] + args,
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"🌊 Error: git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def files_with_mode(ref):
    """返回 [(仓库内路径, 是否可执行)] —— 可执行位取自 git mode，不靠后缀猜。

    「装什么」不在这里判断：`EXCLUDED`、`__pycache__`、资源目录里的 README/description
    这些过滤全走 `build_update_commands.sanitize` —— 那份判断只许有一处，多抄一遍
    就会在某个边界上漂（2026-11-19 的 Keys/README.md 404 就是这么来的）。
    """
    entries = []
    for directory in buc.INSTALLED_DIRS:
        # -r 必须：不加时子目录只会出现它的名字，清单里就会多出一条「文件」，
        # 客户端去取它必然 404。
        listing = subprocess.run(
            ["git", "-C", str(REPO_DIR), "ls-tree", "-r", f"{ref}:{directory}"],
            capture_output=True, text=True)
        if listing.returncode != 0:
            raise SystemExit(
                f"🌊 Error: cannot list {directory} at {ref} "
                f"（这个 ref 里没有该目录？）\n{listing.stderr.strip()}")
        for line in listing.stdout.splitlines():
            meta, _, path = line.partition("\t")
            mode = meta.split()[0] if meta else ""
            entries.append((f"{directory}/{path}", mode == "100755"))

    kept, _dropped = buc.sanitize([path for path, _exec in entries], "git")
    kept_set = set(kept)
    return [(path, executable) for path, executable in entries if path in kept_set]


def manifest_block(version, entries, ref):
    digests = buc.file_digests([path for path, _exec in entries], REPO_DIR, ref)
    missing = [path for path, _exec in entries if not digests.get(path)]
    if missing:
        raise SystemExit("🌊 Error: cannot read blob digest for:\n  " + "\n  ".join(missing[:5]))
    lines = []
    for path, executable in entries:
        digest = digests[path]
        lines.append(f"{path.replace(' ', chr(92) + ' ')} {'1' if executable else '0'} {digest}")
    return "\n".join(lines), len([1 for _p, ex in entries if ex])


def inject(template, version, manifest):
    """把清单块插在 shebang 之后。

    为什么必须插在文件里而不是「运行时从 $0 读自己」：`curl … | bash` 时 `$0` 是 `bash`
    而不是文件，任何 read-self 的做法都读不到。heredoc 是管道执行下唯一可靠的形式。
    """
    # 只看「行首的赋值」：模板里本来就会提到这个变量名（模板守卫要读它），
    # 按子串判断会把模板自己当成生成物。
    if re.search(rf"^{MANIFEST_SIGNAL}=", template, re.MULTILINE):
        raise SystemExit("🌊 Error: the template already carries an embedded manifest "
                         "（用 lib/install.sh 作模板，别拿生成物再生成一次）")

    lines = template.splitlines(keepends=True)
    cut = 1 if lines and lines[0].startswith("#!") else 0
    block = (
        f"{HEADER}"
        f"{MANIFEST_SIGNAL}=1\n"
        f'MACWAVE_VERSION="{version}"\n'
        # set -u / set -e 都会让 read 的退出码变成致命错误：显式兜住。
        f"read -r -d '' MANIFEST <<'{MANIFEST_OPEN}' || true\n"
        f"{manifest}\n"
        f"{MANIFEST_OPEN}\n"
        "\n"
    )
    return "".join(lines[:cut]) + block + "".join(lines[cut:])


def main():
    parser = argparse.ArgumentParser(
        description="Build the release install.sh with this version's file list embedded.")
    parser.add_argument("--version", required=True,
                        help="version as it appears in the tag, without the leading v "
                             "(e.g. 1.2.3@2026-11-26T11:23Z)")
    parser.add_argument("--ref", default="",
                        help="git ref to read the tree from (default: v<version>)")
    parser.add_argument("--template", default=str(REPO_DIR / "lib" / "install.sh"))
    parser.add_argument("--out", default=str(REPO_DIR / "dist" / "install.sh"))
    args = parser.parse_args()

    # 版本号是协议的一部分：这里用 taginfo 校验，不合规就在打包时炸，别等客户端。
    sys.path.insert(0, str(REPO_DIR / "lib"))
    import taginfo  # noqa: E402

    try:
        taginfo.parse("v" + args.version)
    except ValueError as error:
        raise SystemExit(f"🌊 Error: {error}")

    ref = args.ref or f"v{args.version}"
    template_path = Path(args.template)
    if not template_path.is_file():
        raise SystemExit(f"🌊 Error: template not found: {template_path}")

    entries = files_with_mode(ref)
    if not entries:
        raise SystemExit(f"🌊 Error: {ref} has no installable file")

    manifest, exec_count = manifest_block(args.version, entries, ref)

    output = inject(template_path.read_text(encoding="utf-8"), args.version, manifest)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(output, encoding="utf-8")
    out_path.chmod(0o755)

    digest = hashlib.sha256(output.encode("utf-8")).hexdigest()
    print(f"🌊 version  {args.version}")
    print(f"🌊 ref      {ref}")
    print(f"🌊 files    {len(entries)}（其中 +x {exec_count}）")
    print(f"🌊 out      {out_path}")
    print(f"🌊 sha256   {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
