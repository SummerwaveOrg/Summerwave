#!/bin/bash

# make-usb-installer.sh
# 构建一份 release 安装器，并把它（连同使用说明）放进 U 盘。
#
# 用法：
#   bash scripts/make-usb-installer.sh              # 自动找可写的外部卷
#   bash scripts/make-usb-installer.sh --list       # 只列出候选卷，不写
#   bash scripts/make-usb-installer.sh --to /Volumes/U盘名
#   bash scripts/make-usb-installer.sh --ref 1.0 --version 0.1.0@2026-11-28T05:00Z
#
# 为什么要在 Mac（有 git + python3 的那台）上构建：
#   build_installer.py 用 `git ls-tree` 读清单，并且要 python3。目标机若是刚装的
#   Monterey，这两样都可能没有 —— 在那边构建会先卡在工具链上，而不是卡在我们要
#   验证的事情上。产物 install.sh 是纯文本 + 哈希，与构建机的架构无关。

set -o pipefail

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TARGET=""
LIST_ONLY=no
REF=""
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --to)      TARGET="${2:-}"; shift 2 ;;
        --to=*)    TARGET="${1#*=}"; shift ;;
        --ref)     REF="${2:-}"; shift 2 ;;
        --ref=*)   REF="${1#*=}"; shift ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        --list)    LIST_ONLY=yes; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "🌊 Error: unknown option '$1'. Try --help." >&2; exit 1 ;;
    esac
done

[[ -n "$REF" ]] || REF="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 1.0)"
[[ -n "$VERSION" ]] || VERSION="0.1.0@$(date -u +%Y-%m-%dT%H:%MZ)"

# ==========================================
# 卷的探测
# ==========================================
#
# 只认「外部物理盘上的、可写的」卷。判据是**真的试着写一个空文件**，而不是看
# df 的字段或 diskutil 的措辞 —— ISO9660、只读挂载的 UDF、以及被别的进程冻住的
# 卷，三者在文案上长得都像「能用」，只有写一下才知道。

describe_volume() {
    # describe_volume <挂载点> → "可写" / "只读(<文件系统>)"
    local mount="$1" line fs probe
    line="$(mount | grep -F " on ${mount} " | head -n 1)"
    fs="$(printf '%s' "$line" | sed -n 's/.*(\([^,)]*\).*/\1/p')"

    if printf '%s' "$line" | grep -q "read-only"; then
        echo "只读(${fs:-unknown})"
        return
    fi
    probe="$mount/.summerwave-probe.$$"
    if : > "$probe" 2>/dev/null; then
        rm -f "$probe"
        echo "可写"
    else
        echo "只读(${fs:-unknown}, 写入被拒)"
    fi
}

list_volumes() {
    local mount state
    for mount in /Volumes/*; do
        [[ -d "$mount" ]] || continue
        [[ "$mount" == "/Volumes/Macintosh HD" ]] && continue
        state="$(describe_volume "$mount")"
        printf '  %-40s %s\n' "$mount" "$state"
    done
}

if [[ "$LIST_ONLY" == "yes" ]]; then
    echo "🌊 候选卷："
    list_volumes
    exit 0
fi

if [[ -z "$TARGET" ]]; then
    # 自动挑：第一个「可写」的卷。挑不到就把候选连同原因全打出来。
    for mount in /Volumes/*; do
        [[ -d "$mount" ]] || continue
        [[ "$mount" == "/Volumes/Macintosh HD" ]] && continue
        if [[ "$(describe_volume "$mount")" == "可写" ]]; then
            TARGET="$mount"
            break
        fi
    done
    if [[ -z "$TARGET" ]]; then
        echo -e "${RED_BOLD}🌊 Error: no writable volume found under /Volumes.${RESET}" >&2
        echo "🌊 看到的有：" >&2
        list_volumes >&2
        cat >&2 <<'HINT'

🌊 如果那支 U 盘现在是 ISO9660 / UDF（刻录盘、或「磁盘工具」抹成了 ISO），
🌊 macOS 会以**只读**挂载它，任何脚本都写不进去。三种解法：

   1) 换一个普通 U 盘（exFAT 或 MS-DOS(FAT) 分区）
   2) 重新格式化：磁盘工具 → 选中该盘 → 抹掉 → 格式选 exFAT
        命令行等价：diskutil eraseDisk ExFAT SUMMERWAVE /dev/diskN
      （这会清空整支盘，先确认里面没有要留的东西）
   3) 你只是想把安装器塞进「U 盘里的某个 .iso 文件」——那做不到，
      ISO 是只读映像，要改就得重新生成一份再刻录（见下面的说明）。
HINT
        exit 2
    fi
fi

if [[ ! -d "$TARGET" ]]; then
    echo -e "${RED_BOLD}🌊 Error: $TARGET is not a directory.${RESET}" >&2
    exit 2
fi
STATE="$(describe_volume "$TARGET")"
if [[ "$STATE" != "可写" ]]; then
    echo -e "${RED_BOLD}🌊 Error: $TARGET is $STATE; nothing can be written there.${RESET}" >&2
    echo "🌊 见 --help 末尾关于 ISO9660 / UDF 的说明，或换一支普通 U 盘。" >&2
    exit 2
fi

# ==========================================
# 构建
# ==========================================

for tool in git python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo -e "${RED_BOLD}🌊 Error: $tool is required to build the installer.${RESET}" >&2
        echo "🌊 这一步要在有 git 与 python3 的机器上做（例如你的开发机），" >&2
        echo "🌊 然后把结果拷到 U 盘 —— 目标机可能两样都没有。" >&2
        [[ "$tool" == "python3" ]] && echo "🌊   xcode-select --install    # 装完就有 python3 与 git" >&2
        exit 1
    fi
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "🌊 Building the installer for $VERSION (ref $REF)..."
if ! python3 "$SCRIPT_DIR/build_installer.py" \
        --version "$VERSION" --ref "$REF" --out "$STAGE/install.sh"; then
    echo -e "${RED_BOLD}🌊 Error: build failed; nothing was written to $TARGET.${RESET}" >&2
    exit 1
fi

DIGEST="$(python3 - "$STAGE/install.sh" <<'PY'
import hashlib
import sys

print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)"

# ==========================================
# 写进 U 盘
# ==========================================
#
# 用一个带版本号的目录装着，别散在根上：U 盘常常还有别的东西，而且下次构建
# 会覆盖同名文件，放目录里至少能看出来是哪一次打的。

FOLDER="$TARGET/Summerwave-$VERSION"
mkdir -p "$FOLDER" || exit 2
cp "$STAGE/install.sh" "$FOLDER/install.sh" || exit 2
chmod 755 "$FOLDER/install.sh"

cat > "$FOLDER/README.txt" <<EOF
Summerwave installer
====================

version  $VERSION
built    $(date -u +%Y-%m-%dT%H:%M:%SZ) (UTC)
sha256   $DIGEST

Install on the target machine
-----------------------------
    sudo /bin/bash install.sh --ci

Then check that the bundled interpreter works:

    /opt/macwave/python/current/bin/python3 -V
    /opt/macwave/bin/wave --version

Uninstall
---------
    sudo /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/SummerwaveOrg/Summerwave/1.0/lib/uninstall.sh)" -- --force

Notes
-----
* install.sh carries its own file list and checksums; it downloads the rest.
  So the target machine needs network access to the mirror or to GitHub.
* Nothing here is architecture-specific: the same file installs on Intel
  and Apple Silicon.
EOF

# 写完回读一次，确认字节真的落到那支盘上（缓存没刷下去时 cp 也会返回 0）
if ! cmp -s "$STAGE/install.sh" "$FOLDER/install.sh"; then
    echo -e "${RED_BOLD}🌊 Error: the copy on $TARGET does not match what was built.${RESET}" >&2
    exit 2
fi
sync

echo ""
echo -e "${GREEN}🌊 Done.${RESET}"
echo "🌊 folder   $FOLDER"
echo "🌊 sha256   $DIGEST"
echo ""
echo "🌊 在目标机上："
echo "🌊   sudo /bin/bash \"$FOLDER/install.sh\" --ci"
