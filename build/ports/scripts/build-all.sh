#!/bin/bash

# build-all.sh —— 把 census.tsv 里的版本逐个从源码编出来（可断点续跑）
#
# 用法：
#   bash scripts/build-all.sh go,cargo            # 只编这几类构建系统
#   bash scripts/build-all.sh go,cargo,cmake      # 再带上 cmake
#   ARCH=arm64 bash scripts/build-all.sh ...      # 默认就是 arm64
#
# 输入：~/MacWaveOrg/bottle-1.0/census.tsv（scripts/source_census.py 产出）
# 产物：out/<名>@<版本>.macos-<arch>.tar.bz2
# 日志：~/MacWaveOrg/bottle-1.0/source-build.log
#
# `out/` 里已有同名产物的直接跳过 —— 这就是断点：中途崩了、或改了某个包再跑一遍，
# 不会把几百个已经编好的重编。
#
# 失败不中断：一条条往下走，最后汇总。

set -u
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTS="$(cd "$HERE/.." && pwd)"
ARCH="${ARCH:-arm64}"
WORKDIR="${WORKDIR:-$HOME/MacWaveOrg/bottle-1.0}"
CENSUS="${CENSUS:-$WORKDIR/census.tsv}"
LOG="${LOG:-$WORKDIR/source-build.log}"
KINDS="${1:-go,cargo}"

TAG="$(python3 - "$HOME/Projects/SummerwaveOrg/Summerwave" "$ARCH" <<'PY'
import sys, pathlib
repo, arch = pathlib.Path(sys.argv[1]), sys.argv[2]
sys.path.insert(0, str(repo / "config"))
import platforminfo
print(platforminfo.bottle_tag(arch, os_name="macos"))
PY
)"

[ -f "$CENSUS" ] || { echo "🌊 census not found: $CENSUS" >&2; exit 2; }

# 磁盘闸门：Go 的构建缓存与模块缓存能吃掉十几 G，写满之后 curl 会报
# `Failure writing output to destination`，看起来像网络错误。每轮开工前先看一眼。
free_mb() { df -m "$HOME" | awk 'NR==2{print $4}'; }
if (( $(free_mb) < 8000 )); then
    echo "🌊 磁盘只剩 $(free_mb) MB，清 Go 缓存" | tee -a "$LOG"
    go clean -cache >/dev/null 2>&1 || true
    (( $(free_mb) < 8000 )) && { go clean -modcache >/dev/null 2>&1 || true; }
    echo "🌊 清理后 $(free_mb) MB" | tee -a "$LOG"
fi

total=$(awk -F'\t' -v kinds=",$KINDS," 'NR>1 && index(kinds, ","$4",")' "$CENSUS" | wc -l | tr -d ' ')
echo "🌊 待编 $total 条（构建系统：$KINDS，目标 $TAG）" | tee -a "$LOG"

built=0; skipped=0; failed=0; n=0
while IFS=$'\t' read -r kind name version system source note; do
    [[ "$kind" == "kind" ]] && continue
    case ",$KINDS," in *",$system,"*) ;; *) continue ;; esac
    [[ -n "$source" ]] || continue

    n=$((n + 1))
    artifact="$PORTS/out/$name@$version.$TAG.tar.bz2"
    if [[ -f "$artifact" ]]; then
        skipped=$((skipped + 1))
        echo "🌊 [$n/$total] skip  $name@$version" >> "$LOG"
        continue
    fi

    echo "" >> "$LOG"
    echo "=== [$n/$total] $name@$version ($system) ===" >> "$LOG"
    if bash "$HERE/build-source.sh" "$name" "$version" "$source" "$system" >> "$LOG" 2>&1; then
        built=$((built + 1))
        echo "🌊 [$n/$total] ok    $name@$version" | tee -a "$LOG"
    else
        failed=$((failed + 1))
        echo "🌊 [$n/$total] FAIL  $name@$version ($system)" | tee -a "$LOG"
    fi
done < "$CENSUS"

echo "" | tee -a "$LOG"
echo "🌊 built $built, skipped $skipped, failed $failed（共 $total）" | tee -a "$LOG"
