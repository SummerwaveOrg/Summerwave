# gnu-prefix —— GNU 包的 g 前缀版本

`gtar` / `gpatch` / `gbash` / `gwget` 都是**同一份二进制改了名字**，不重新编译，
用 `relabel.sh` 生成。对应的包定义在 `infosource` 里，`bin_name` 带 g。

## 为什么

MacWave 里的 `bash`、`tar`、`patch`、`wget` 都是 GNU 软件，而系统里那份是**另一个实现**：

| 命令 | 系统自带 | MacWave 装的 |
| --- | --- | --- |
| `bash` | `/bin/bash` 3.2.57（Apple 卡在 GPLv3 之前） | GNU bash 5.3 |
| `tar` | `/usr/bin/tar` = **bsdtar 3.5.3** | GNU tar 1.35 |
| `patch` | `/usr/bin/patch` 2.0-12u11-Apple（旧 GNU 派生） | GNU patch 2.8.1 |
| `wget` | 没有（这条列在这里是为了统一规则） | GNU Wget 1.25.0 |

同名安装会把系统那份顶掉（`links/` 在 `PATH` 里靠前），而用户装 GNU 版的通常意图是
「额外有一个更强的版本」，不是「换掉系统工具」——脚本里写 `#!/usr/bin/env bash`
的第三方软件会突然拿到 5.3，行为差异可能很隐蔽。

g 前缀让两者**并存**：`tar`（系统）+ `gtar`（GNU）、`bash`（3.2）+ `gbash`（5.3）。
这是 Homebrew 的 `gtar`/`gpatch`/`gmake`、MacPorts 的 `gsed`/`gawk` 一直以来的做法。

## 规则（写进索引纪律）

**凡上游是 GNU 项目的包，包名与 `bin_name` 一律带 `g` 前缀**，不管当前是否撞车 ——
撞车与否取决于用户装的发行版/系统版本，而包名一旦发布就不好再改。

不是 GNU 的不要加：`git`（自有项目，只是用 GPL）、`ffmpeg`、`tmux`、`dtc`、
`testdisk` 都不带。

## 生成

```bash
bash gnu-prefix/relabel.sh out
```

`gwget` 的来源（conda 归档）本仓库不构建，缺件时脚本跳过它，不影响 `gtar`/`gpatch`/`gbash`。

`gtar`/`gpatch`/`gbash` 是裸二进制，改名后重新 ad-hoc 签名即可；`gwget` 的产物是
conda 归档，除了把 `bin/wget` 改成 `bin/gwget`，还要把 `info/` 里登记的路径一起改掉
（否则 conda 的路径校验会对不上）。

## gwget 的 CA 证书（已知限制，与改名无关）

`gwget` 沿用 conda 的 `wget` 包，它编译时把证书路径指向 `$PREFIX/ssl/cacert.pem`，
装到 MacWave 之后那个路径不存在，于是直接 `wget https://…` 会报：

```
ERROR: cannot verify …'s certificate
```

给一个系统根证书文件就能用（macOS 自带 `/etc/ssl/cert.pem`）：

```bash
SSL_CERT_FILE=/etc/ssl/cert.pem gwget -O file https://example.com/
```

这是 conda 打包方式带来的，原始 `wget` 包一样有；要彻底解决得让包带
`ca-certificates` 依赖，或在 `bin/gwget` 外面包一层设好 `SSL_CERT_FILE` 的 wrapper。
