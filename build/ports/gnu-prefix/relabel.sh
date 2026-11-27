#!/bin/bash

# gnu-prefix/relabel.sh —— 把已有的 Ports 产物改名成 g 前缀版本（**不重新编译**）
#
# 为什么：MacWave 里 bash / tar / patch / wget 都是 GNU 软件。GNU 版装进来会顶掉
# 系统里那份**不同实现**（/bin/bash 3.2、/usr/bin/tar 是 bsdtar、/usr/bin/patch 是
# Apple 的旧 patch），而用户装 GNU 版的本意通常是「额外有一个」，不是「把系统那份
# 换掉」。所以 GNU 包一律带 g 前缀：gtar / gpatch / gbash / gwget —— 与 Homebrew
# 的 gtar/gpatch/gmake、MacPorts 的 gsed/gawk 是同一个惯例。
#
# 改名只动文件名，二进制字节不变（重新 ad-hoc 签名会把签名段重写，所以 sha256 变）。
# 对归档型产物（wget 的 conda 包）还要把 info/ 里登记的路径一起改掉。
#
# 用法：bash gnu-prefix/relabel.sh <输出目录>
#   需要先把原产物准备好：<输出目录>/{tar,patch,bash}-{arm64,x86_64}
#   以及 wget 的 conda 包解压后的树 <输出目录>/wget-{arm64,amd64}/

set -eEuo pipefail
OUT="${1:-$PWD/out}"
GREEN='\033[32m'; RED='\033[1;31m'; RESET='\033[0m'
say() { printf '%b\n' "$*"; }
die() { printf '%b\n' "${RED}🌊 Error: $*${RESET}" >&2; exit 1; }

relabel_bare() { # 旧名 新名 → 裸二进制直接改名重签
    local old="$1" new="$2"
    [[ -f "$OUT/$old" ]] || die "missing $OUT/$old"
    cp "$OUT/$old" "$OUT/$new"
    chmod +x "$OUT/$new"
    codesign --force --sign - "$OUT/$new" >/dev/null 2>&1
    say "  $old → $new"
}

relabel_bare tar-arm64    gtar-arm64
relabel_bare tar-x86_64   gtar-x86_64
relabel_bare patch-arm64  gpatch-arm64
relabel_bare patch-x86_64 gpatch-x86_64
relabel_bare bash-arm64   gbash-arm64
relabel_bare bash-x86_64  gbash-x86_64

relabel_archive() { # 架构 → wget 的 conda 树改名后重打包
    local arch="$1"
    local dir="$OUT/wget-$arch"   # 分两行：同一行里 $arch 会在赋值前展开，set -u 直接报错
    # gwget 来自 conda 归档，本仓库不构建它；没有就跳过，不要拦住 gtar/gpatch/gbash。
    if [[ ! -d "$dir" ]]; then
        say "  skip gwget-$arch (no $dir)"
        return 0
    fi
    mv "$dir/bin/wget" "$dir/bin/gwget"
    grep -rl "bin/wget" "$dir/info" 2>/dev/null | while read -r f; do
        perl -pi -e 's{bin/wget\b}{bin/gwget}g' "$f"
    done
    codesign --force --sign - "$dir/bin/gwget" >/dev/null 2>&1
    tar -cjf "$OUT/gwget-$arch.tar.bz2" -C "$dir" .
    say "  wget-$arch → gwget-$arch.tar.bz2"
}

relabel_archive arm64
relabel_archive amd64

say ""
say "校验（应全部等于原版版本号）"
for f in "$OUT"/gtar-arm64 "$OUT"/gpatch-arm64 "$OUT"/gbash-arm64 \
         "$OUT"/gtar-x86_64 "$OUT"/gpatch-x86_64 "$OUT"/gbash-x86_64; do
    [[ -f "$f" ]] || continue
    printf '  %-14s %s\n' "$(basename "$f")" "$("$f" --version | head -1)"
done
