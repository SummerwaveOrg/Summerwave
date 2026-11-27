# aria2c 实测记录

数值取自 2026-11-21 第一次构建（macOS 15.0，本机 arm64 + Rosetta 跑 amd64）。

## 产物

| 架构 | lipo -archs | 大小 | min_os | sha256 |
| --- | --- | --- | --- | --- |
| arm64 | arm64 | 3,590,976 B | 15.0（`LC_BUILD_VERSION`） | `b8804c86956fca3377039d0016d361143fd4dbed6fa164a4f15f18d0fda5dbba` |
| amd64 | x86_64 | 3,233,456 B | 15.0（`LC_BUILD_VERSION`） | `9124d9aa2943d29a69e5775f98a8f7c3fbe2ad5d2fc89f14e4383189bd04d66e` |

两个架构的 `min_os` 都是 **15.0**：本机 SDK 是 15.0，没有显式传
`-mmacosx-version-min`，所以 Mach-O 里写的就是这个值。

这会让 macOS 14 及更旧的用户看到「要求 15.0」的黄字询问（`min_os` 是提示不是硬拦，
`-F` 可越过，见 AGENTS.md 的行为矩阵）。**要放宽必须先实测**：
`CFLAGS="-mmacosx-version-min=12.0"` 重编，再在 12.x 真机上跑一遍
`aria2c --version` 与一次真实下载，通过了才把记录里的 `min_os` 改小。
不要因为「它只是调用了老 API」就把数字写低 —— 那是猜的。

## 依赖面：为什么没有 `deps:`

`otool -L` 两个架构完全一样：

```
/usr/lib/libz.1.dylib
/System/Library/Frameworks/Security.framework/Versions/A/Security
/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
/usr/lib/libc++.1.dylib
/usr/lib/libSystem.B.dylib
```

没有一条落在 `/opt/homebrew` 或 `/opt/local`。这是 configure 开关的直接结果：

| 开关 | 砍掉了什么 | 代价 |
| --- | --- | --- |
| `--with-appletls` + `--without-gnutls/--without-openssl` | libssl / libcrypto | 无（TLS 走 Secure Transport） |
| `--without-libcares` | c-ares | DNS 退回同步 `getaddrinfo` |
| `--without-libssh2` | libssh2 | 没有 SFTP 下载 |
| `--without-libxml2` + `--without-libexpat` | libxml2 / expat | Metalink 关闭（configure 输出里 `Metalink: no`） |
| `--without-libnettle` | libnettle / gmp / gcrypt | 无（消息摘要用 CommonCrypto，`Message Digest: apple`） |
| `--without-sqlite3` | sqlite3 | 没有 `--save-session` 的 SQLite 后端 |
| `--disable-nls` | gettext | 界面只有英文（本来也是英文） |

**BitTorrent 保留**，它不引外部库，而且那是 aria2 的主要用途之一。

## 构建输出里的两处「看起来像问题」

```
checking for pkg-config... /opt/homebrew/bin/pkg-config
```

`pkg-config` 来自 Homebrew，但它只在探测阶段跑，所有可选库的检测结果都是 `no`
（见 configure 摘要）。最终 `LIBS` 只有 `-lz -framework CoreFoundation -framework Security`，
`otool -L` 也已确认。**想复核就只看 `otool -L`，不要看 configure 日志里出现过什么路径。**

## 当时跑过的验证

```
$ /tmp/aria2-out/aria2c-arm64 --version | head -2
aria2 version 1.37.0
Copyright (C) 2006, 2019 Tatsuhiro Tsujikawa

$ /tmp/aria2-out/aria2c-x86_64 --version | head -2     # Rosetta
aria2 version 1.37.0

$ bash scripts/selfbuilt_check.sh /tmp/aria2-out/aria2c-arm64 \
      --arch arm64 --bin-name aria2c --run-args "--version"
✅ 可以上线
```

闸门脚本第一次跑 amd64 时报过一条 `❌ 架构不符：产物是 x86_64（amd64），索引记录要的是 x86_64` ——
那是把 `--arch x86_64` 当成了合法取值。**`--arch` 只认 `arm64` / `amd64`**，
写 `x86_64` 会被当成另一个架构。

## 2026-11-24 重建（4.6 重定位）

`stage` 改为运行时布局 `bin/<名称>@<版本>/`，打包前跑 `scripts/relocate_stage.sh`，
顺序为「编 → 重定位 → 签名 → 打包」。上面的哈希表已过期，以索引为准：

```
7f268fb97212624788f1da2a3a7efe7522264834e747b0da323a370628376e9f  arm64  (min_os 15.0)
883f85bb4d4cda5f451a433532624914f4c10cd5e70a54e9c16f867075872f01  amd64  (min_os 15.0)
```
