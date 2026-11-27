# testdisk 实测记录

数值取自 2026-11-22 的构建（Xcode 17 / SDK 15.5，本机 arm64 + Rosetta 跑 amd64）。

## 产物

| 架构 | 归档 | 大小 | sha256 |
| --- | --- | --- | --- |
| arm64 | `testdisk-7.2-arm64.tar.xz` | 362,672 B | `07c3b63046ac3e550a5cc21419e0cc795cec444ee3dfe11b789b9b9fc1e56185` |
| amd64 | `testdisk-7.2-x86_64.tar.xz` | 394,096 B | `54c2c68d8bdf1df5a2511197f57a68db440e299a6830fac51cd982b458d41b15` |

## 依赖面

上游只发 intel 与 ppc 的 macOS 二进制，arm64 必须自编 —— 这是自建而不是「收上游产物」的原因。关掉 libewf / ntfs3g / ntfs 三个可选依赖后，依赖面只剩 `libncurses`、`libz`、`libiconv`、`libSystem`。

## selfbuilt_check.sh

两个架构都全绿（Mach-O、架构、签名、min_os 11.0、无外部依赖、实跑 `--version`）。

## 2026-11-24 重建（4.6 重定位）

`stage` 改为运行时布局 `bin/<名称>@<版本>/`，打包前跑 `scripts/relocate_stage.sh`，
顺序为「编 → 重定位 → 签名 → 打包」。上面的哈希表已过期，以索引为准：

```
16fc927ab48428d94726841b3cabb8f7b06c4394e2d6e8ff77d5fd064be8503a  arm64  (min_os 11.0)
54a64c2a737a8fe2678368269e2e8a5f666c9eb02aad4a6122819a7bf74e568a  amd64  (min_os 11.0)
```
