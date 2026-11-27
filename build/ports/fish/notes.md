# fish 实测记录

从上游 `fish-4.9.3.app.zip` 里取出 prefix 树重打包（不重编译），并按架构 `lipo -thin`。2026-11-23。

| 架构 | 归档 | 大小 | sha256 |
| --- | --- | --- | --- |
| arm64 | `fish-4.9.3-arm64.tar.xz` | 8,189,328 B | `a4943cf7653d5efb737e44d9d4ac1579639cfbec760e34a7bc33d7944c478d9b` |
| amd64 | `fish-4.9.3-amd64.tar.xz` | 8,440,384 B | `4c3aac727ed7c2c8ec0766169b1ffb248d621cbec68c79fc1acb709eb4e1dbc8` |

上游 `.app.zip` 的 sha256：`3619fa92d540…e9a8`（17,049,060 B）。

## 为什么能重打包（关键结论）

fish 4 编译期虽然带 `/usr/local/share/fish`，但运行时按**可执行文件自身位置**推算 prefix。
实测把整棵树放到 `/tmp/sbx/bin/fish@4.9.3/`、再经 `links/fish` 软链启动：

```
$ links/fish -c 'echo $__fish_data_dir'
/…/bin/fish@4.9.3/share/fish
$ links/fish -c 'type -q ls; and echo FUNCS_OK'
FUNCS_OK
$ links/fish -c 'count $fish_complete_path'
6
```

所以不需要给 fish 打补丁，也不需要把 prefix 对齐用户机器。

## 布局

```
bin/fish
bin/fish_indent
bin/fish_key_reader
share/fish/{functions,completions,conf.d,...}
etc/fish/config.fish
```

`fish_indent` / `fish_key_reader` 上游就是瘦二进制，脚本里按 `lipo -archs` 判断后再决定 thin 还是直接拷。

## 2026-11-24 重建（4.6 重定位）

`stage` 改为运行时布局 `bin/<名称>@<版本>/`，打包前跑 `scripts/relocate_stage.sh`，
顺序为「编 → 重定位 → 签名 → 打包」。上面的哈希表已过期，以索引为准：

```
f0d9451c94bf3afcd2f49bf177c949ddb87bf72f394245cd3b2c0d9f2a553d45  arm64  (min_os 11.0)
957302014c6a9a0fb67a8e54c390cb309a30193b0cdea147eeb7628c1aa935a0  amd64  (min_os 10.12)
```

`--check` 判定已位置无关。amd64 不再打包 `fish_indent`/`fish_key_reader`：上游 .app 里这两个只有 arm64。
