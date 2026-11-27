#!/bin/bash

# batch_linux_payloads.sh —— 把索引里的 Linux 记录批量重打（可选再上传）。
#
# 用法：
#   bash scripts/batch_linux_payloads.sh                    # 只重打，不上传
#   bash scripts/batch_linux_payloads.sh --upload            # 重打 + 传 Bottle
#   bash scripts/batch_linux_payloads.sh --limit 20          # 先试一小批
#   bash scripts/batch_linux_payloads.sh --only jq,rg,fd     # 只跑这几个包
#
# 为什么不用 `prepare_bottle.py --all`：那条路的记录来源是 sync_payloads.records()，
# 它按 macOS 的架构列记录。这里直接读索引文件名，只挑 `.linux-*`。
#
# 断点续跑：产物已在 OUT 里就跳过，所以中断之后重跑即可。
#
# 取件走 prepare_bottle 里新加的 gh 优先后端（GitHub release 资产走 api.github.com，
# 不碰 github.com —— 后者在校园网/家宽上十次有三次超时）。

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BASE="${BASE:-$HOME/MacWaveOrg/bottle-1.0}"

INFOSOURCE="${INFOSOURCE:-$HOME/Projects/SummerwaveOrg/SeaLane}"
OUT="${OUT:-$BASE/linux-prebuilt}"
CACHE="${CACHE:-$BASE/linux-cache}"
LOG="${LOG:-$BASE/linux-batch.log}"

LIMIT=0
UPLOAD=false
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit)  LIMIT="${2:-0}"; shift 2 ;;
        --only)   ONLY="${2:-}"; shift 2 ;;
        --upload) UPLOAD=true; shift ;;
        *) echo "usage: $0 [--limit N] [--only a,b,c] [--upload]" >&2; exit 2 ;;
    esac
done

mkdir -p "$OUT" "$CACHE" "$(dirname "$LOG")"
note() { printf '%s\n' "$*" | tee -a "$LOG"; }

# 索引里的 Linux 记录 → <名>@<版本>.<os>-<arch>
# 不用 mapfile：那是 bash 4 的内建，macOS 自带的 3.2 没有（shell_lint 第 4 项盯着）
RECORDS=()
while IFS= read -r _rec; do
    RECORDS+=("$_rec")
done < <(find "$INFOSOURCE" -type f -name '_*@*.linux-*' | sort)
note "$(date '+%Y-%m-%d %H:%M:%S') batch_linux_payloads: ${#RECORDS[@]} record(s)"

ok=0; skipped=0; failed=0; index=0
declare -a FAILED_LIST=()

for rec in "${RECORDS[@]}"; do
    base="$(basename "$rec")"; base="${base#_}"
    key="${base%.linux-*}"                 # <名>@<版本>
    arch="${rec##*.linux-}"                # arm64 | amd64
    name="${key%%@*}"
    version="${key#*@}"

    if [[ -n "$ONLY" && ",$ONLY," != *",$name,"* ]]; then
        continue
    fi
    index=$((index + 1))
    if [[ "$LIMIT" -gt 0 && "$index" -gt "$LIMIT" ]]; then break; fi

    expected="$OUT/${name}@${version}.linux-${arch}.tar.bz2"
    if [[ -f "$expected" ]]; then
        skipped=$((skipped + 1))
        continue
    fi

    note "$(date '+%H:%M:%S') [$index] ${name}@${version} ${arch}"
    if python3 "$SCRIPT_DIR/prepare_bottle.py" --kind pkg --name "$name" \
            --version "$version" --arch "$arch" --os linux \
            --infosource "$INFOSOURCE" --out "$OUT" --cache "$CACHE" \
            >> "$LOG" 2>&1; then
        ok=$((ok + 1))
    else
        failed=$((failed + 1))
        FAILED_LIST+=("${name}@${version}.${arch}")
        note "$(date '+%H:%M:%S')   FAILED ${name}@${version} ${arch}"
    fi
done

note "$(date '+%Y-%m-%d %H:%M:%S') rebuilt=${ok} skipped=${skipped} failed=${failed}"
if [[ "${#FAILED_LIST[@]}" -gt 0 ]]; then
    note "failed: ${FAILED_LIST[*]}"
fi

if [[ "$UPLOAD" == "true" && -d "$OUT" ]]; then
    note "$(date '+%H:%M:%S') uploading from $OUT"
    # upload-bottle.sh 是「传一个删一个」的节奏；Linux 与 macOS 同一条 release 通道
    if bash "$SCRIPT_DIR/../build/ports/scripts/upload-bottle.sh" "$OUT" >> "$LOG" 2>&1; then
        note "$(date '+%H:%M:%S') upload done"
    else
        note "$(date '+%H:%M:%S') upload FAILED — see $LOG"
    fi
fi

[[ "$failed" -eq 0 ]]
