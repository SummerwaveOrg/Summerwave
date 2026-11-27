#!/usr/bin/env python3
"""把 Keys/macwave-rsa.pub.pem 嵌进 lib/install.sh。

`lib/install.sh` 是被 curl 下来直接执行的，没法 source，所以自更新验签时用的
公钥只能是脚本里自带的一份（lib/selfupdate.py 从它里面抠出来当锚点）。公钥变了
（轮换）就跑这个脚本重嵌一次，别手工改 —— 少一个字符就是验不过，验不过就不装，
用户当场卡住。

    python3 scripts/embed_rsa_pub.py           # 重嵌
    python3 scripts/embed_rsa_pub.py --check   # 只检查是否同步（测试用）
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBKEY = ROOT / "Keys" / "macwave-rsa.pub.pem"
TARGETS = (ROOT / "lib" / "install.sh",)

BEGIN = "# >>> RSA public key"
END = "# <<< RSA public key"
BLOCK_HEAD = "# >>> RSA public key (managed by scripts/embed_rsa_pub.py) >>>"


def block(pem: str) -> str:
    body = pem.strip("\n")
    return f"{BLOCK_HEAD}\nMW_RSA_PUB_PEM='{body}'\n# <<< RSA public key <<<"


def spliced(text: str, replacement: str, path: Path) -> str:
    start = text.find(BEGIN)
    end = text.find(END)
    if start < 0 or end < 0 or end < start:
        sys.exit(f"error: {path} 里找不到 RSA public key 标记")
    end += len(END)
    # 标记行自身的结尾换行保留在原位
    newline = text.find("\n", end)
    return text[:start] + replacement + text[newline:]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="只检查，不写文件")
    args = parser.parse_args()

    if not PUBKEY.is_file():
        sys.exit(f"error: 找不到 {PUBKEY.relative_to(ROOT)}")

    pem = PUBKEY.read_text()
    want = block(pem)
    stale = []
    for path in TARGETS:
        text = path.read_text()
        updated = spliced(text, want, path)
        if updated == text:
            continue
        stale.append(path.relative_to(ROOT))
        if not args.check:
            path.write_text(updated)

    if stale and args.check:
        print("❌ 内置公钥与 Keys/macwave-rsa.pub.pem 不一致：" + ", ".join(map(str, stale)))
        print("   跑 python3 scripts/embed_rsa_pub.py 重嵌")
        return 1
    if stale:
        print("已重嵌：" + ", ".join(map(str, stale)))
    else:
        print("内置公钥已同步")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
