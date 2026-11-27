# bash 实测记录

数值取自 2026-11-22 的构建（Xcode 17 / SDK 15.5，本机 arm64 + Rosetta 跑 amd64）。

## 产物

| 架构 | 归档 | 大小 | sha256 |
| --- | --- | --- | --- |
| arm64 | `bash-arm64` | 1,207,488 B | `2480ec4a567c3254923c3718f5c6e63586c9d32b5bcadaded7b10daacbfc970b` |
| amd64 | `bash-x86_64` | 1,265,584 B | `6cbc37dfb664856284072862fe5fb64adc8c3f8738c0223b230085f3dbc57fc2` |

## 依赖面

`--disable-nls` 关掉 gettext；readline 用 bash 源码里自带的那份。链接面只有 `libncurses`、`libiconv`、`libSystem`，都是系统库。macOS 自带的 `/bin/bash` 是 3.2，装完 `links/bash` 会盖在 PATH 前面。

## selfbuilt_check.sh

两个架构都全绿（Mach-O、架构、签名、min_os 11.0、无外部依赖、实跑 `--version`）。
