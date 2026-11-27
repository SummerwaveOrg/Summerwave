#!/bin/bash

# git/build.sh —— 可复现地编出 git 的两个架构（整树产物）
#
# 上游：https://github.com/git/git
# 源码：https://www.kernel.org/pub/software/scm/git/git-<版本>.tar.xz
# 产物：git-<版本>-<架构>.tar.xz，里面是 bin/ + libexec/ + share/ 三棵目录
#
# 为什么要自建：git 官方从来不发布二进制产物（GitHub 上只有源码 tag），
# 而 conda-forge / Homebrew 的都是别人重编的、带各自前缀和 8 个外部动态库。
#
# 五条约束，别改：
#   1. 固定上游版本与源码 sha256 —— 索引里的 sha256 对应某一次具体构建；
#   2. 两个架构分别编，不要 universal：索引是「每架构一个产物」；
#   3. 编译时把 Homebrew / MacPorts 的默认搜索路径关掉（NO_DARWIN_PORTS /
#      NO_HOMEBREW），否则 git 会链到 /opt/local/lib/libz 这类构建机路径；
#   4. 编完给每个 Mach-O ad-hoc 签名（Apple 芯片拒绝执行未签名的 arm64），但
#      签名会断开 git-core 里那些硬链接，所以签完要按 LC_UUID 重新接回去 ——
#      否则整棵树会从 25 MB 涨到 594 MB。见 sign_and_dedupe；
#   5. 顺序只能是「编 → 重定位 → 签名 → 打包」。重定位（install_name_tool 改写
#      Mach-O）会作废已有签名，所以它必须在签名之前；stage 也必须摆成**运行时
#      布局** bin/git@<版本>/，否则 relocate_rpath.py 算出的相对路径是错的。
#
# 依赖面只留系统库：关掉 gettext / pcre2 / OpenSSL / Python / Rust，
# TLS 交给系统 libcurl（Secure Transport）。otool -L 里只剩
# libz / libiconv / libSystem 与 CoreFoundation、CoreServices。
#
# 用法：bash git/build.sh [输出目录]
# 依赖：Xcode 命令行工具（clang、make、codesign、lipo、tar、curl、patch）

set -eE
set -u
set -o pipefail

VERSION="2.56.1"
SRC_SHA256="f0b0bf89264b9bd2e1c640363e7529643989da76281600473c50745cd34a607f"
SRC_URL="https://www.kernel.org/pub/software/scm/git/git-${VERSION}.tar.xz"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$PWD/out}"

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

say() { printf '%b\n' "$*"; }
die() { printf '%b\n' "${RED_BOLD}🌊 Error: $*${RESET}" >&2; exit 1; }
FETCH="$HERE/../scripts/fetch.sh"
[ -f "$FETCH" ] || die "fetch.sh not found: $FETCH"
RELOCATE_SH="$HERE/../scripts/relocate_stage.sh"
[ -f "$RELOCATE_SH" ] || die "relocate_stage.sh not found: $RELOCATE_SH"

for tool in curl make clang codesign lipo patch tar python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found (install the Xcode command line tools)"
done


WORK="$(mktemp -d "${TMPDIR:-/tmp}/git-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "${GREEN}🌊 Downloading git ${VERSION}${RESET}"
bash "$FETCH" "$SRC_URL" "$WORK/git.tar.xz"
echo "${SRC_SHA256}  $WORK/git.tar.xz" | shasum -a 256 -c - >/dev/null \
    || die "source tarball does not match the published sha256"
tar -xJf "$WORK/git.tar.xz" -C "$WORK"
SRC="$WORK/git-${VERSION}"
[ -d "$SRC" ] || die "unpacked directory not found: $SRC"

# 让 RUNTIME_PREFIX 在「经软链启动」时仍然成立：MacWave 把包装成
# bin/git@<版本>/bin/git，再链 links/git 过去；不解析符号链接的话，git 会退回
# 编译期的 prefix，而用户机器上并没有那棵目录。
patch -d "$SRC" -p1 < "$HERE/runtime-prefix-symlink.patch"

SDK="$(xcrun --show-sdk-path)"

# 两份产物共用的 make 变量。每加一个功能就多一个用户机器上可能缺失的动态库，
# 加之前先想清楚。
MAKE_VARS=(
    NO_GETTEXT=YesPlease NO_LIBPCRE2=YesPlease NO_TCLTK=YesPlease
    NO_OPENSSL=YesPlease NO_PYTHON=YesPlease NO_RUST=YesPlease
    NO_DARWIN_PORTS=YesPlease NO_HOMEBREW=YesPlease
    NO_APPLE_COMMON_CRYPTO=YesPlease
    USE_LIBICONV=YesPlease
    USE_CURL=libcurl CURL_LIBCURL=-lcurl
    USE_EXPAT=YesPlease EXPAT_LIBEXPAT=-lexpat
    RUNTIME_PREFIX=YesPlease HAVE_NS_GET_EXECUTABLE_PATH=YesPlease
    CC=/usr/bin/clang
)

sign_and_dedupe() {
    # 整树里的每个 Mach-O 都要签，不只是 bin/git。麻烦的是 libexec/git-core 下
    # 那 140 个 git-XXX 本来是**同一份** bin/git 的硬链接（LC_UUID 相同），
    # 而 codesign 会重写文件、顺带断掉硬链接 —— 老实一个个签，包就从 25 MB 变成
    # 594 MB（140 份 3.9 MB 拷贝）。所以按 LC_UUID 分组：每组只签第一个，
    # 其余名字重新 ln 回去，内容与签名都一致。
    local stage="$1"
    local plan; plan="$(mktemp "${TMPDIR:-/tmp}/git-sign.XXXXXX")"

    while IFS= read -r file; do
        file "$file" | grep -q "Mach-O" || continue
        printf '%s\t%s\n' \
            "$(dwarfdump --uuid "$file" 2>/dev/null | awk 'NR==1 {print $2}')" \
            "$file"
    done < <(find "$stage" -type f) | sort > "$plan"

    local last_uuid="" last_file=""
    while IFS=$'\t' read -r uuid file; do
        if [[ -n "$uuid" && "$uuid" == "$last_uuid" ]]; then
            rm -f "$file"
            ln "$last_file" "$file"
        else
            codesign --force --sign - "$file" >/dev/null 2>&1
            last_uuid="$uuid" last_file="$file"
        fi
    done < "$plan"

    rm -f "$plan"
}

build_one() {
    local arch="$1" clang_arch="$2"
    # stage 摆成**运行时布局**：客户端把整树落到 <base>/bin/<名称>@<版本>/，
    # 所以这里就必须是 <stage>/bin/git@<版本>/{bin,libexec,share}，
    # relocate_rpath.py 才能按最终位置算出正确的相对路径。
    local stage="$WORK/stage-$arch"
    local tree="$stage/bin/git@${VERSION}"
    local cflags="-arch $clang_arch -O2 -mmacosx-version-min=12.0 -isysroot $SDK"
    # -headerpad_max_install_names 给 install_name_tool 留出改写空间，少了它
    # 重定位会报 "larger updated load commands do not fit"。
    local ldflags="$cflags -Wl,-headerpad_max_install_names"

    say "${GREEN}🌊 Building ${arch}${RESET}"
    mkdir -p "$tree"
    (
        cd "$SRC"
        make clean >/dev/null 2>&1 || true
        make -j"$(sysctl -n hw.ncpu)" "${MAKE_VARS[@]}" \
            CFLAGS="$cflags" LDFLAGS="$ldflags" prefix="$tree"
        make -j"$(sysctl -n hw.ncpu)" "${MAKE_VARS[@]}" \
            CFLAGS="$cflags" LDFLAGS="$ldflags" prefix="$tree" install >/dev/null
    )

    # git 的 Makefile 会把 $(prefix) 直接替换进三个**文本**脚本；而我们的 prefix 是
    # mktemp 出来的目录，编完就删，于是这三处指向一个不存在的路径。
    # install_name_tool 只管 Mach-O，改不到文本，所以只能在构建时重写：
    #   git-instaweb   默认 root      → 按脚本自身位置推 ../../share/gitweb
    #   git-sh-i18n    TEXTDOMAINDIR  → 按 GIT_EXEC_PATH 推（NLS 已关，本身是死代码）
    #   gitweb.cgi     $GIT           → FindBin 推 ../../bin/git
    python3 - "$tree" <<'PYEOF'
import pathlib, re, sys

tree = pathlib.Path(sys.argv[1])
prefix = str(tree)
# Path 会把 // 归一成 /，而 $TMPDIR 自带尾斜杠：二进制里可能是一者或另一者。
prefix_bytes_set = {prefix.encode(), str(tree).encode()}
changed = []


def rewrite(rel, pattern, replacement):
    path = tree / rel
    text = path.read_text()
    new_text, count = re.subn(pattern, replacement, text)
    if count == 0:
        raise SystemExit(f"pattern not found in {rel}: {pattern[:70]}")
    path.write_text(new_text)
    changed.append(f"{rel}({count})")


# 1) 默认 root：改成按脚本自身位置推（放 share/gitweb 的相对位置）
rewrite("libexec/git-core/git-instaweb",
        r"# Default is /[^\n]*/share/gitweb",
        "# Default is share/gitweb, resolved relative to this script")
rewrite("libexec/git-core/git-instaweb",
        r"""root='/[^']*/share/gitweb'""",
        'root="$(cd "$(dirname "$0")/../../share/gitweb" && pwd)"')

# 2) TEXTDOMAINDIR：按 GIT_EXEC_PATH 推（NLS 已关，本身是死代码，但不能留死路径）
rewrite("libexec/git-core/git-sh-i18n",
        r'TEXTDOMAINDIR="/[^"]*/share/locale"',
        'TEXTDOMAINDIR="${GIT_EXEC_PATH%/}/../share/locale"')

# 3) gitweb.cgi 的 $GIT：FindBin 推（cgi 的 cwd 不可靠，不能靠相对 cwd）
gitweb = tree / "share/gitweb/gitweb.cgi"
text = gitweb.read_text()
text, count = re.subn(r'our \$GIT = "/[^"]*/bin/git";',
                      'our $GIT = "$FindBin::Bin/../../bin/git";', text)
if count == 0:
    raise SystemExit("gitweb.cgi: $GIT 定义没找到")
if "use FindBin;" not in text:
    text, added = re.subn(r"^use strict;\nuse warnings;\n",
                          "use strict;\nuse warnings;\nuse FindBin;\n", text, count=1, flags=re.M)
    if added != 1:
        raise SystemExit("gitweb.cgi: 没能在 use 区插入 use FindBin")
gitweb.write_text(text)
changed.append("share/gitweb/gitweb.cgi")

# 兜底：文本文件里不该再有本次构建目录。
#
# 只看文本（跳过 Mach-O）是刻意的：git 用 RUNTIME_PREFIX 运行时自己算 exec path，
# 但编译期必须留一个兜底前缀 —— 那个字符串就嵌在二进制里，内容正是本次构建目录。
# 它只在「算不出自己的路径」时才会被用到（见 exec-cmd.c 的补丁），删不掉也不必删。
# selfbuilt_check.sh 的同类检查同样用 grep -I 跳过二进制，两边口径一致。
MACHO_MAGICS = {b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
                b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe"}
leaked = []
for p in tree.rglob("*"):
    if not p.is_file() or p.is_symlink():
        continue
    data = p.read_bytes()
    if data[:4] in MACHO_MAGICS:
        continue
    if any(n in data for n in prefix_bytes_set):
        leaked.append(str(p.relative_to(tree)))
if leaked:
    raise SystemExit(f"build prefix still present in text files: {leaked}")

print("  rewrote:", ", ".join(changed))
PYEOF

    bash "$RELOCATE_SH" "$stage"
    sign_and_dedupe "$tree"

    mkdir -p "$OUT"
    tar -cJf "$OUT/git-${VERSION}-${arch}.tar.xz" -C "$tree" bin libexec share
}

build_one arm64 arm64
build_one amd64 x86_64

say ""
say "${GREEN}🌊 Artifacts in $OUT${RESET}"
for file in "$OUT/git-${VERSION}-arm64.tar.xz" "$OUT/git-${VERSION}-amd64.tar.xz"; do
    printf '  %-28s %10s B  %s\n' "$(basename "$file")" "$(stat -f%z "$file")" \
        "$(shasum -a 256 "$file" | cut -d' ' -f1)"
done
say ""
say "下一步：对两个归档跑 scripts/selfbuilt_check.sh（在本仓库）："
say "        --arch arm64 / --arch amd64 --tree --main bin/git；索引记录要写 install: \"tree\"。"
