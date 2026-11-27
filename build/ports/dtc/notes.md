# dtc 实测记录

数值取自 2026-11-22 的构建（Xcode 17 / SDK 15.5，本机 arm64 + Rosetta 跑 amd64）。

## 产物

| 架构 | 归档 | 大小 | sha256 |
| --- | --- | --- | --- |
| arm64 | `dtc-1.7.2-arm64.tar.xz` | 91,204 B | `2ae16f489ae43514997a828d4b0e06b04c471219a0a8c7ec432cb0693824f4b4` |
| amd64 | `dtc-1.7.2-x86_64.tar.xz` | 99,588 B | `a6ff81402a02a7bd26ea1b929c857e8023c2e1a35dfb66d2cba2b48401e8a23d` |

## 依赖面

用 1.7.2 而不是 1.8.x（1.8 的 Makefile 只剩「请用 meson」的壳）。装了 Homebrew 的 libyaml 时，Makefile 的 pkg-config 探测会打开 yaml 支持却不链 yaml.o，所以构建脚本里 `PKG_CONFIG=/usr/bin/false` + 显式 `-DNO_YAML`。

## selfbuilt_check.sh

两个架构都全绿（Mach-O、架构、签名、min_os 11.0、无外部依赖、实跑 `--version`）。

## 2026-11-24 重建（4.6 重定位）

`stage` 改为运行时布局 `bin/<名称>@<版本>/`，打包前跑 `scripts/relocate_stage.sh`，
顺序为「编 → 重定位 → 签名 → 打包」。上面的哈希表已过期，以索引为准：

```
bd2a03d64d4459a9d9d44dc6f8e9a9e9a04027ba8e421c9b92bf054ce8c4aaca  arm64  (min_os 11.0)
612087bd213df2b3573925f88eb1937dfe11c957ef7a6c01f1f3aafc51c317ba  amd64  (min_os 11.0)
```

libfdt 的裸 soname `libfdt.dylib.1` 指向 `lib/` 软链，先 `install_name_tool` 改成真文件绝对路径，再重定位成 `@loader_path/../lib/libfdt.dylib.1.7.2`。LDFLAGS 加了 `-headerpad_max_install_names`。
