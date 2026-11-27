#!/bin/bash

# 把本地产物推到 SummerwaveOrg/Bottle 的 Release（tag = 包名），
# 逐个包「上传 → 核对 → 删本地」，让磁盘一路往下降而不是等全部传完。
#
# 用法：bash scripts/upload-bottle.sh <产物目录> [--keep]
#
# 为什么自己写而不是用 publish_payloads.py：那个是一次性传完的，
# 而这台机器已经撑不住了 —— 需要「传一个删一个」的增量节奏。

set -u
set -o pipefail

SRC="${1:-}"
KEEP="${2:-}"
BACKUP="${BACKUP:-$HOME/MacWaveOrg/bottle-1.0}"
REPO="${REPO:-SummerwaveOrg/Bottle}"
LOG="$BACKUP/upload-bottle.log"

[ -d "$SRC" ] || { echo "usage: upload-bottle.sh <dir> [--keep]" >&2; exit 2; }

note() { printf '%s\n' "$*" | tee -a "$LOG"; }

# 同名@同版本的源码自建产物优先：重打的 prebuilt 里若有同一份，跳过它
SKIP_LIST="$BACKUP/source-built-names.txt"
have_source_build() {
    [[ -f "$SKIP_LIST" ]] && grep -qxF "$1" "$SKIP_LIST"
}

uploaded=0; skipped=0; failed=0; freed=0

# 大的先传，磁盘降得最快
while IFS= read -r artifact; do
    base="$(basename "$artifact")"
    name="${base%%@*}"
    key="${base%.macos-*}"          # <名>@<版本>
    [[ "$key" == "$base" ]] && key="${base%.linux-*}"   # Linux 产物同一条通道

    # 只有传「重打的 prebuilt」时才按源码自建名单跳过；传 out/（源码自建本身）不跳
    if [[ "$(basename "$SRC")" != "out" ]] && have_source_build "$key"; then
        skipped=$((skipped + 1))
        note "🌊 skip  $base（已有源码自建版）"
        continue
    fi

    size=$(stat -f%z "$artifact")

    # 刚建好的 release 立刻上传偶尔会 404/422（API 还没就绪），重试三次
    attempt=0
    while (( attempt < 3 )); do
        attempt=$((attempt + 1))
        if gh release view "$name" --repo "$REPO" >/dev/null 2>&1; then
            gh release upload "$name" "$artifact" --repo "$REPO" --clobber >/dev/null 2>>"$LOG" && break
        else
            gh release create "$name" "$artifact" --repo "$REPO" \
                --title "$name" \
                --notes "Summerwave payload for $name (built from source; see the index record for sha256)." \
                >/dev/null 2>>"$LOG" && break
        fi
        sleep $((attempt * 3))
    done

    # 核对：远端确实有同名、同大小的资产，才删本地
    remote_size=$(gh release view "$name" --repo "$REPO" --json assets \
        --jq ".assets[] | select(.name==\"$base\") | .size" 2>/dev/null)
    if [[ "$remote_size" == "$size" ]]; then
        [[ "$KEEP" == "--keep" ]] || rm -f "$artifact"
        uploaded=$((uploaded + 1)); freed=$((freed + size))
        note "🌊 ok    $base  ($((size / 1048576))M)  已释放 $((freed / 1048576))M"
    else
        failed=$((failed + 1))
        note "🌊 FAIL  $base  远端 size=${remote_size:-none} 本地=$size（保留本地）"
    fi
done < <(find "$SRC" -maxdepth 1 -name "*.tar.bz2" -type f -print0 | xargs -0 ls -S 2>/dev/null)

note ""
note "🌊 上传 $uploaded，跳过 $skipped，失败 $failed，共释放 $((freed / 1048576))MB"
df -h "$HOME" | tail -1 | tee -a "$LOG"
