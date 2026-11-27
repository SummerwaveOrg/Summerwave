#!/bin/bash

# fetch.sh —— 统一的上游取件口，所有 build.sh 都走这里
#
# 用法：bash scripts/fetch.sh <url> <output>
#
# 为什么不直接用 curl：国内网络（校园网、家宽）常年把 `github.com` 本身掐掉，
# 而 `api.github.com` / `codeload.github.com` / `release-assets.githubusercontent.com`
# 通常还是通的。实测同一条链路：github.com 12 秒连不上，api.github.com 0.3 秒 200。
#
# 所以：
#   - `github.com/<owner>/<repo>/releases/download/<tag>/<file>`
#     → 走 `gh release download`（打 API，再重定向到 CDN，不碰 github.com）
#   - 其他（kernel.org、codeload、上游自有域名）
#     → curl，带重试
#
# 校验不在这里做：每个 build.sh 都自己按 sha256 锁死上游产物，取件方式换了也不影响
# 可信度 —— 下错了直接 die。

set -u
set -o pipefail

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'
say() { printf '%b\n' "$*"; }
die() { printf '%b\n' "${RED_BOLD}🌊 Error: $*${RESET}" >&2; exit 1; }

URL="${1:-}"
OUT="${2:-}"
[ -n "$URL" ] && [ -n "$OUT" ] || die "usage: fetch.sh <url> <output>"

curl_with_retry() {
    # --http1.1 是这台机器上必需的：直连 github 走 HTTP/2 会报
    # `curl: (16) Error in the HTTP2 framing layer`。
    curl -fsSL --http1.1 --retry 3 --retry-all-errors --retry-delay 2 \
        --connect-timeout 20 --max-time 1800 -o "$OUT" "$1"
}

case "$URL" in
    https://codeload.github.com/*/*/tar.gz/*)
        # codeload 用 curl 常常在校园网/家宽上被 reset（实测卡十几分钟），
        # 而 api.github.com 的 tarball 端点 5 秒内就能拿完 —— 优先走 API。
        rest="${URL#https://codeload.github.com/}"
        owner="${rest%%/*}"; rest="${rest#*/}"
        repo="${rest%%/*}"; ref="${rest#*/tar.gz/}"

        if command -v gh >/dev/null 2>&1; then
            say "${GREEN}🌊 gh api tarball ${owner}/${repo}@${ref}${RESET}"
            if gh api "repos/$owner/$repo/tarball/$ref" > "$OUT" 2>/dev/null && [ -s "$OUT" ]; then
                exit 0
            fi
            say "🌊 fallback to plain curl (gh failed)"
        fi
        ;;
    https://github.com/*/archive/refs/tags/*)
        # 源码包（`<owner>/<repo>/archive/refs/tags/<tag>.tar.gz`）跟 codeload 是一回事：
        # 直连 github.com 常年被掐，走 API 的 tarball 端点最稳。
        rest="${URL#https://github.com/}"
        owner="${rest%%/*}"; rest="${rest#*/}"
        repo="${rest%%/*}"; tag="${rest#*/archive/refs/tags/}"; tag="${tag%%.tar.gz}"; tag="${tag%%.tar.xz}"
        if command -v gh >/dev/null 2>&1; then
            say "${GREEN}🌊 gh api tarball ${owner}/${repo}@${tag}${RESET}"
            if gh api "repos/$owner/$repo/tarball/$tag" > "$OUT" 2>/dev/null && [ -s "$OUT" ]; then
                exit 0
            fi
            say "🌊 fallback to plain curl (gh failed)"
        fi
        ;;
    https://github.com/*/releases/download/*)
        rest="${URL#https://github.com/}"
        owner="${rest%%/*}"; rest="${rest#*/}"
        repo="${rest%%/*}"; rest="${rest#*/releases/download/}"
        tag="${rest%%/*}"; file="${rest#*/}"

        if command -v gh >/dev/null 2>&1; then
            tmp="$(mktemp -d "${TMPDIR:-/tmp}/fetch.XXXXXX")"
            say "${GREEN}🌊 gh release download ${owner}/${repo} ${tag}: ${file}${RESET}"
            if gh release download "$tag" --repo "$owner/$repo" \
                --pattern "$file" --dir "$tmp" --clobber; then
                mv "$tmp/$file" "$OUT"
                rm -rf "$tmp"
                exit 0
            fi
            rm -rf "$tmp"
            say "🌊 fallback to plain curl (gh failed)"
        fi
        ;;
esac

say "${GREEN}🌊 curl ${URL}${RESET}"
curl_with_retry "$URL" || die "cannot download $URL"
