# tar 实测记录

数值取自 2026-11-22 的构建（Xcode 17 / SDK 15.5，本机 arm64 + Rosetta 跑 amd64）。

## 产物

| 架构 | 归档 | 大小 | sha256 |
| --- | --- | --- | --- |
| arm64 | `tar-arm64` | 524,032 B | `76600dde10a286e4038b9872d93dd4b735c9fe7951d1af456a39213c7cd407f2` |
| amd64 | `tar-x86_64` | 541,696 B | `0f2587044d9528623a7700bfbe2c4c32381e389b2aaaf78afcca02e9cbc0c1bf` |

## 依赖面

链接 `/usr/lib/libiconv.2.dylib`（系统自带），所以 configure 时要显式 `LIBS=-liconv`，否则链接阶段找不到 `_iconv_open`。

## selfbuilt_check.sh

两个架构都全绿（Mach-O、架构、签名、min_os 11.0、无外部依赖、实跑 `--version`）。
