# git 实测记录

数值取自 2026-11-24 的构建（macOS Xcode 17 / SDK 15.5，本机 arm64 + Rosetta 跑 amd64）。
这一版把 stage 摆成运行时布局 `bin/git@<版本>/` 并在打包前跑了重定位，所以哈希与
2026-11-22 那版不同。

## 产物

| 架构 | 归档 | 大小 | `bin/git` sha256 | min_os |
| --- | --- | --- | --- | --- |
| arm64 | `git-2.56.1-arm64.tar.xz` | 3,520,556 B | `e7fd8a9b3a321c4cbab7d2f4ee4bc4089041ad73353c3f7987beaba9489d3e88` | 12.0 |
| amd64 | `git-2.56.1-amd64.tar.xz` | 3,873,408 B | `e7c6979d696a18f7f5cf7cec0c0d154be487c5d52a6348b047278bf95b22898d` | 12.0 |

归档本身的 sha256（索引记录里写这两个）：

```
ed1ff710f183dddbc6098cfe0288d1f8caa5feeaeef65aebca5cf2ef4b68c6ad  git-2.56.1-arm64.tar.xz
793681d40b654fff678c7f49d3a45f3850963adb7cc9b4ec3630465de56208a7  git-2.56.1-amd64.tar.xz
```

注意 `bin/git` 的 sha256 与归档的不同：索引要写**归档**的哈希（客户端校验的是下载到的那个文件）。

## 重定位（2026-11-24）

`build.sh` 现在把 stage 装成 `<stage>/bin/git@<版本>/{bin,libexec,share}` ——和客户端
落到 `<base>/bin/<名称>@<版本>/` 的形状一致 ——然后跑
`MacWave/scripts/relocate_rpath.py <stage> --check`，有绝对路径才改写，最后才签名、
打包。顺序是「编 → 重定位 → 签名 → 打包」，反过来签名会作废。

这一版 `--check` 直接判定「已经位置无关」：git 只链
`libz / libiconv / libSystem / CoreServices / CoreFoundation`，全在系统路径里。
所以这一步目前是**闸门**而不是修复——哪天有人加了个 `--with-*`，`--check` 会当场报出来。
`-Wl,-headerpad_max_install_names` 已经加进 LDFLAGS，真需要改写时 install_name_tool
才有地方写更长的 `@loader_path/...`。

## 签名的坑：594 MB 从哪来（2026-11-22 修正）

`libexec/git-core` 下那 140 个 `git-XXX` 本来是同一份二进制的**硬链接**（LC_UUID 相同），
而 `codesign` 会重写文件、按文件名生成 ad-hoc identifier，于是每个名字都被签成独立一份：

```
逐个签（错）   594 MB，解包后 140 份 3.9 MB 拷贝
按 UUID 签名  25 MB，140 个名字仍是硬链接
```

`build.sh` 里的 `sign_and_dedupe` 按 LC_UUID 分组，每组只签第一个，其余 `ln` 回去。
先发出去的那版（`2ff8bdc1…` / `ecf8a4d9…`）就是逐个签的，已用瘦身版替换。

2026-11-24 实测：`libexec/git-core` 下 203 个文件只占 55 个 inode，整棵树 25 MB（arm64）。

## selfbuilt_check.sh

```
✅ 164 个 Mach-O，架构 arm64 / amd64
✅ ad-hoc 签名有效（codesign --verify 通过 Designated Requirement）
✅ min_os 12.0（LC_BUILD_VERSION）
✅ 除系统库外没有引用（otool -L 只有 /usr/lib 与 /System）
✅ 实跑：arm64 原生、amd64 走 Rosetta，`--version` 与 `--exec-path` 都指向解包目录
```

历史遗留的三处**文本**文件把构建前缀写死了（见坑 5），闸门把它们记为 note 而非
problem，所以退出码仍是 0。

## 实测过的命令

沙箱装了一次（`install: "tree"` → `bin/git@2.56.1/` 整棵 + `links/git@2.56.1`），然后：

```
$ links/git@2.56.1 --version
git version 2.56.1
$ links/git@2.56.1 --exec-path
/tmp/mwgit/bin/git@2.56.1/libexec/git-core      ← 指向安装目录，不是构建目录
$ links/git@2.56.1 clone --depth 1 https://github.com/octocat/Hello-World.git /tmp/c
$ links/git@2.56.1 -C /tmp/c log --oneline -1
7fd1a60 Merge pull request #6 from Spaceghost/patch-1
```

## 踩过的坑

1. **`-arch amd64` 不存在。** clang 只认 `x86_64`；索引里叫 amd64 是 MacWave 的命名。
   `selfbuilt_check.sh --arch amd64` 已做归一化，别再手改成 `x86_64` 去绕。
2. **默认会链 `clang` 是 MacPorts 的。** 本机 PATH 里 `/opt/local/bin` 排在前面，
   直接用 `clang` 编出来的 `otool -L` 是 `/opt/local/lib/libz.1.dylib`。必须写
   `/usr/bin/clang`，并加 `NO_DARWIN_PORTS` / `NO_HOMEBREW`（git 的 Makefile 会
   主动把 `/opt/local/include`、`/opt/local/lib` 加进搜索路径）。
3. **默认编 Rust 组件。** `varint.c` 只在 `NO_RUST` 时进 `LIB_OBJS`，否则符号由
   Rust 静态库提供；交叉编 x86_64 时那部分没编出来，链接报
   `_encode_varint` 未定义。加 `NO_RUST=YesPlease`。
4. **`RUNTIME_PREFIX` 在软链下失效。** 见 README 的补丁一节；不补的话
   `--exec-path` 指向构建机的 `/Users/…/stage-arm64/libexec/git-core`。
5. **三个文本文件把构建前缀编了进去（2026-11-24 发现，尚未修）。** Mach-O 干净，
   但 `make install` 会把 `prefix` 替换进这三个文件：

   ```
   libexec/git-core/git-instaweb     root='/var/folders/…/stage-arm64/bin/git@2.56.1/share/gitweb'
   libexec/git-core/git-sh-i18n      TEXTDOMAINDIR='/var/folders/…/share/locale'
   share/gitweb/gitweb.cgi           our $GIT = "/var/folders/…/stage-arm64/bin/git@2.56.1/bin/git"
   ```

   影响：`git instaweb` 默认 path 失效（`--local` 可绕）；NLS 已关，`git-sh-i18n` 用不到；
   `gitweb.cgi` 装到用户机器上跑不起来。都属于边角功能，主命令不受影响。
   之前一直没发现，是因为闸门只搜 `/Users/` 与 `/opt/local`，而 stage 在 `$TMPDIR`
   （`/var/folders/…`）下 —— 现在闸门已加上 `/var/folders/`。

## 2026-11-24 重建（4.6 重定位）

`stage` 改为运行时布局 `bin/<名称>@<版本>/`，打包前跑 `scripts/relocate_stage.sh`，
顺序为「编 → 重定位 → 签名 → 打包」。上面的哈希表已过期，以索引为准：

```
5beda5b63fe29451273409348d7ccd41995748564711e6005492203c2aa7fafd  arm64  (min_os 12.0)
33f4e446851f3757aaa9de29302bee29ebda1eba0240d8409b5dfe432f183557  amd64  (min_os 12.0)
```

`--check` 判定已位置无关（只链系统库），本步为空转、作为闸门存在。

## 三处文本文件里的构建前缀（2026-11-24 修）

`make install` 会把 `$(prefix)` 直接替换进三个**文本**脚本。构建时 prefix 是
`mktemp -d` 出来的目录，编完即删，所以这三处指向不存在的路径。`install_name_tool`
只管 Mach-O，改不到文本 —— 只能在构建时重写：

| 文件 | 原来 | 现在 |
| --- | --- | --- |
| `libexec/git-core/git-instaweb` | `root='<构建目录>/share/gitweb'` | `root="$(cd "$(dirname "$0")/../../share/gitweb" && pwd)"` |
| `libexec/git-core/git-sh-i18n` | `TEXTDOMAINDIR="<构建目录>/share/locale"` | `TEXTDOMAINDIR="${GIT_EXEC_PATH%/}/../share/locale"`（NLS 已关，本身是死代码） |
| `share/gitweb/gitweb.cgi` | `our $GIT = "<构建目录>/bin/git";` | `our $GIT = "$FindBin::Bin/../../bin/git";`（另加 `use FindBin;`） |

gitweb.cgi 不用「`$GIT = "git"` 走 PATH」：CGI 的 `PATH` 不可指望；用 FindBin 推
包内相对位置，和这次重定位的思路一致。

### 二进制里仍然嵌着构建目录，这是**故意保留**的

`bin/git`（以及 libexec 下那些硬链接）里能 `strings` 出
`<构建目录>/bin/git@2.56.1` —— 那是 `RUNTIME_PREFIX` 的**编译期兜底**：运行时
git 自己算 exec path，算不出来才用它。删不掉也不必删（源码里必须有这个值）。

所以 `build.sh` 末尾那条「整棵树不该再有构建目录」的断言**只看文本文件**，
跳过 Mach-O —— 与 `selfbuilt_check.sh` 里 `grep -I` 的口径一致。

### 断言本身踩过的坑（记下来免得重犯）

- `pathlib.Path` 会把 `//` 归一成 `/`，而 macOS 的 `$TMPDIR` 自带尾斜杠，
  二进制里是 `T//git-build…`：只比 `str(Path(argv))` 会**静默漏检**。
  两个写法都要比。
- 它第一版就因为这个原因通过了 —— 断言打印「通过」不代表它真的在查东西。

