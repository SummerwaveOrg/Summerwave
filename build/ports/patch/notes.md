# patch 实测记录

数值取自 2026-11-22 的构建（Xcode 17 / SDK 15.5，本机 arm64 + Rosetta 跑 amd64）。

## 产物

| 架构 | 归档 | 大小 | sha256 |
| --- | --- | --- | --- |
| arm64 | `patch-arm64` | 229,808 B | `947fe79fb1c79a78fc7d1d5294b21f08957c516d281c907f02ffeff4fc11a306` |
| amd64 | `patch-x86_64` | 209,328 B | `3c0afe2468193420d7e700fbecdf0296c80f8b5c7c68a077de133dc0bde783e7` |

## 依赖面

两个架构都只链 libSystem。`ftp.gnu.org` 慢的时候可以换镜像，构建前会校验源码 sha256。

## selfbuilt_check.sh

两个架构都全绿（Mach-O、架构、签名、min_os 11.0、无外部依赖、实跑 `--version`）。
