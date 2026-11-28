#!/usr/bin/env python3

# taginfo.py
# 发布 tag 的唯一解释口：`v1.2.3@2026-11-26T11:23Z`（预览版可带 `-rc.1` / `-beta.2`）。
#
# 为什么要有这个文件：0.1.0 起**不再有 Selfupdate 仓库**，客户端问「该装哪一版」时直接读
# Summerwave 的 Release/Tag —— 于是 tag 本身就是协议。协议只写在一处、只解析一次，
# 否则发布脚本、客户端、文档三边迟早漂。
#
# 格式（全部 UTC，别的时区一律不接受）：
#
#     v<版本>[@<构建时刻>][-<渠道>.<序号>]
#
#     v1.2.3                        只有版本号（人工发的普通 tag，不带构建号）
#     v1.2.3@2026-11-26T1123Z       正式版：版本号 + 构建时刻
#     v1.2.3-rc.1@2026-11-26T1123Z  预览版
#     v1.2.3-beta.2@2026-11-26T1123Z
#
# 为什么时刻写成 `T1123Z` 而不是 ISO 8601 的 `T11:23Z`：**冒号是 git ref 的非法
# 字符**，`git tag 'v1.2.3@2026-11-26T11:23Z'` 会被直接拒绝 —— 协议最漂亮但落不了地
# 就没有意义。日期部分保留 `-`（合法且醒目），时分的冒号去掉，长度与可读性都保住了。
#
# 为什么要 <构建时刻>：同一个版本号可能重发（修打包错误、换 SDK 重编），
# 只靠版本号无法判断「哪一次是新的」。时刻精确到分钟、带 Z，排序即时间排序。
#
# 渠道从 tag 里来，不再有独立的 rcdata/latest.toml：
#   正式版 = 没有渠道段。`latest` 只认正式版，预览版要显式申请。

import re
from typing import NamedTuple

CHANNELS = ("rc", "beta")

# 版本段允许 1.2 / 1.2.3 / 1.2.3.4，以及 4.x 时代的「特殊版本」（例如 2.1.5-procursus）。
# 版本号本身也可能是时间戳（0.1.0 起就是 `2026.11.26-15:52:43`），所以冒号也算合法字符
_VERSION = r"[0-9][0-9A-Za-z.+_:\-]*"
_STAMP = r"\d{4}-\d{2}-\d{2}T\d{4}Z"

TAG_RE = re.compile(
    rf"^v(?P<version>{_VERSION}?)"
    rf"(?:-(?P<channel>{'|'.join(CHANNELS)})\.(?P<seq>\d+))?"
    rf"(?:@(?P<stamp>{_STAMP}))?$"
)


class TagInfo(NamedTuple):
    version: str            # 去掉 v 前缀的版本号
    channel: str            # "" 表示正式版，否则 rc / beta
    channel_seq: int        # 渠道序号；正式版为 0
    stamp: str              # UTC 构建时刻，YYYY-MM-DDTHHMMZ；没有就是 ""

    @property
    def is_prerelease(self) -> bool:
        return bool(self.channel)

    @property
    def key(self) -> tuple:
        """排序键：先比时刻（没有时刻的排最后），再比渠道（正式版优先），最后比版本号。

        为什么时刻优先：同一版本号重发时，时刻才是「哪个更新」的唯一依据；而不同版本之间
        时刻通常也随发布单调递增。没有时刻的人工 tag 只能靠版本号比较，排在有时刻的后面。
        """
        return (1 if not self.stamp else 0, self.stamp, 0 if not self.channel else 1)


def parse(tag: str) -> TagInfo:
    """解析发布 tag；不认识就抛 ValueError（不做「猜一个」的兜底）。"""
    text = (tag or "").strip()
    match = TAG_RE.match(text)
    if not match:
        raise ValueError(f"not a release tag: {tag!r} (expected v<version>[@YYYY-MM-DDTHHMMZ])")
    version = match.group("version") or ""
    if not version:
        raise ValueError(f"release tag has no version: {tag!r}")
    # 版本号里允许 `-`（4.x 有 2.1.5-procursus 这类），但那让「未知渠道」也能混进来：
    # `v1.2.3-dev.1` 会被当成版本号 1.2.3-dev.1。凡是 `<词>.<数字>` 结尾的，
    # 只认 rc / beta，其余一律拒绝 —— 猜错了会挑错版本，而且不报错。
    if re.search(r"-[A-Za-z][A-Za-z0-9_]*\.\d+$", version):
        raise ValueError(f"unknown release channel in tag: {tag!r} (only rc / beta are allowed)")
    channel = match.group("channel") or ""
    return TagInfo(
        version=version,
        channel=channel,
        channel_seq=int(match.group("seq") or 0),
        stamp=match.group("stamp") or "",
    )


def format_tag(version: str, stamp: str, channel: str = "", seq: int = 1) -> str:
    """上面的反向操作。发布脚本用它造 tag，客户端测试用它造样本。"""
    if channel and channel not in CHANNELS:
        raise ValueError(f"unknown channel: {channel!r} (expected one of {CHANNELS})")
    if stamp and not re.fullmatch(_STAMP, stamp):
        raise ValueError(f"build stamp must be UTC 'YYYY-MM-DDTHHMMZ', got: {stamp!r}")
    out = f"v{version}"
    if channel:
        out += f"-{channel}.{seq}"
    if stamp:
        out += f"@{stamp}"
    return out


def pick_latest(tags, include_prerelease=False):
    """从一堆 tag 里挑出「该装的那个」；挑不出返回 None。

    正式版优先：只要有一个不带渠道段的 tag，就只在正式版里挑 —— 预览版不会顶掉它。
    """
    parsed = []
    for tag in tags:
        try:
            parsed.append((tag, parse(tag)))
        except ValueError:
            continue
    if not parsed:
        return None
    stable = [(tag, info) for tag, info in parsed if not info.is_prerelease]
    # 没有正式版时退回预览版：仓库刚起步、或只在推 RC 的阶段，光看 `latest` 会一无所获
    pool = parsed if (include_prerelease or not stable) else stable
    if not pool:
        return None
    return max(pool, key=lambda pair: pair[1].key)
