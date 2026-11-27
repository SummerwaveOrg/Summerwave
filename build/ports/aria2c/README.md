# aria2c

**上游：** [aria2/aria2](https://github.com/aria2/aria2) —— 多协议命令行下载器（HTTP/FTP/BitTorrent）。
**命令：** `aria2c`（`bin_name: "aria2c"`，与二进制同名；**包名也用 `aria2c`**）。
**为什么自建：** 上游从 1.36.0 起不再发布 macOS 产物；1.35.0 的 `osx-darwin.tar.bz2` 是 2022 年的 x86_64，不能当 arm64 用。

## 包名为什么不是 `aria2`

索引里有一条硬规则（infosource `60e8376`「Name every package after the command the user types」）：
**包名 = 用户在终端敲的命令名**，46 个包的 `bin_name` 全部等于包名。安装目录是
`bin/<bin_name>@<版本>/`，两者不一致会让 `wave list` 显示错名字、`wave uninstall <包名>`
报「未安装」、link 系命令找不到版本。

所以这里跟 Homebrew / MacPorts 的 `aria2` 叫法不同 —— 它们可以在 formula 里另指
二进制名，MacWave 不能。`wave search aria2` 仍能命中，因为搜索是子串匹配。

## 产物

| 架构 | 文件名 | 大小 | sha256 |
| --- | --- | --- | --- |
| arm64 | `aria2c-arm64` | 3,590,976 B | `b8804c86956fca3377039d0016d361143fd4dbed6fa164a4f15f18d0fda5dbba` |
| amd64 | `aria2c-x86_64` | 3,233,456 B | `9124d9aa2943d29a69e5775f98a8f7c3fbe2ad5d2fc89f14e4383189bd04d66e` |

**没有 `deps:`** —— 只链系统库（`libz`、`Security`、`CoreFoundation`、`libc++`、`libSystem`），
`otool -L` 里没有任何 Homebrew / MacPorts 路径。这是刻意用 `--with-appletls` 换来的：
TLS 走 Secure Transport，不引 openssl（对比 `choma` 必须声明 `deps: "openssl@3.0.15"`）。

## 怎么编的

见 `build.sh`。两个架构分别编，产物是裸可执行文件（不带扩展名），于是
`payload_filename()` 拼出来正好是 `aria2c@1.37.0.<架构>`。

## 索引记录

`infosource/pkg/pkginfo_<架构>/aria2c/`：

```
_aria2c@common
bin_name: "aria2c"
des: "aria2 - The ultra fast download utility"
hom: "https://aria2.github.io/"
lic: "GPL-2.0-or-later"
aut: "Tatsuhiro Tsujikawa"

_aria2c@1.37.0
sha256: "<上表>"
file: "aria2c_<架构>"     ← 裸可执行文件，无扩展名 → aria2c@1.37.0.<架构>
url: "https://github.com/MacWaveOrg/Ports/releases/download/aria2c/aria2c-<架构>"
min_os: "15.0"
```
