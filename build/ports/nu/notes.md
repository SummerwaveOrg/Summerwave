# nu（Nushell）实测记录

重打包自上游 `nu-0.117.0-<arch>-apple-darwin.tar.gz`（不重编译）。2026-11-23。

| 架构 | 归档 | 大小 | sha256 |
| --- | --- | --- | --- |
| arm64 | `nu-0.117.0-arm64.tar.xz` | 44,770,156 B | `01bc41eb3da1249f27c507ba072f90e82f3f23db949c1b514fec2a27407d419a` |
| amd64 | `nu-0.117.0-amd64.tar.xz` | 50,634,464 B | `a6fc2c8fdb4afa3bc146e6caa2ee4cfc0f01b7928b7c7cce3c1cecc294074532` |

上游 tar 的 sha256：arm64 `1d0e642e…7527`、amd64 `f44a9922…1b2f`。

## 布局

```
bin/nu
bin/nu_plugin_*     ← 9 个插件，安装时每个都链一条 links/<名字>
```

min_os：arm64 11.0、amd64 10.12。`nu` 自包含，不依赖树外数据。

## 2026-11-24 重建（4.6 重定位）

`stage` 改为运行时布局 `bin/<名称>@<版本>/`，打包前跑 `scripts/relocate_stage.sh`，
顺序为「编 → 重定位 → 签名 → 打包」。上面的哈希表已过期，以索引为准：

```
f8f26fb36324d12520c6d456e0dbbb97cb6aecaa4dcda3f8bb1f35c735fef9b8  arm64  (min_os 11.0)
0469cef8001128d03fb6a74666c77a29f2614d0396c24c1375cf7f0807ee1841  amd64  (min_os 10.12)
```
