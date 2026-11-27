# git

自建产物。上游 `git/git` **从不发布二进制**（GitHub 上只有源码 tag），
所以 MacWave 的 git 只能自己编。

- 上游：https://github.com/git/git
- 源码：https://www.kernel.org/pub/software/scm/git/git-2.56.1.tar.xz
  （sha256 `f0b0bf89264b9bd2e1c640363e7529643989da76281600473c50745cd34a607f`，
  与 kernel.org 的 `sha256sums.asc` 一致）
- 产物：`git-2.56.1-arm64.tar.xz` / `git-2.56.1-amd64.tar.xz`，
  里面是整棵树：`bin/` + `libexec/` + `share/`

## 这是一个「整树软件包」

git 不是一个文件：`git clone https://…` 要 `libexec/git-core/git-remote-http`，
`git init` 要 `share/git-core/templates`。所以索引里的记录写：

```
install: "tree"
min_os: "12.0"
```

装完的布局：

```
~/.local/macwave/bin/git@2.56.1/
├── bin/git
├── libexec/git-core/…
└── share/git-core/templates/…
~/.local/macwave/links/git -> ../bin/git@2.56.1/bin/git
```

## 为什么没有 `deps:`

依赖面被刻意砍到只剩系统库：`NO_GETTEXT`、`NO_LIBPCRE2`、`NO_OPENSSL`、
`NO_PYTHON`、`NO_RUST`，TLS 交给系统 libcurl（Secure Transport），
`NO_DARWIN_PORTS` / `NO_HOMEBREW` 关掉构建机上的 /opt/local、/opt/homebrew 搜索路径。

```
$ otool -L bin/git
	/System/Library/Frameworks/CoreServices.framework/…
	/usr/lib/libz.1.dylib
	/usr/lib/libiconv.2.dylib
	/usr/lib/libSystem.B.dylib
	/System/Library/Frameworks/CoreFoundation.framework/…
```

## 编译期路径：一个必须打的补丁

git 的 `--libexecdir` 是编译期写死的绝对路径。MacWave 把包装到
`bin/git@<版本>/` 再软链过去，所以这里用 git 自带的 `RUNTIME_PREFIX`
（按可执行文件位置推算 prefix）。但 macOS 的 `_NSGetExecutablePath()`
返回的是**exec 时的路径**，也就是那条软链，于是 prefix 推算失败、退回编译期的
prefix —— 用户机器上并没有那棵目录。

`runtime-prefix-symlink.patch` 让它在 Darwin 上先 `realpath()`：

```
links/git -> bin/git@2.56.1/bin/git
$ links/git --exec-path
/Users/<你>/.local/macwave/bin/git@2.56.1/libexec/git-core
```

## 怎么重建

```bash
bash git/build.sh out
```

两个架构分别编、每个 Mach-O 都 ad-hoc 签名（`sign_and_dedupe`：签名后按 LC_UUID
把 git-core 里的硬链接接回去，否则整棵树会从 25 MB 涨到 594 MB）、
源码 sha256 校验、补丁自动应用。
产物尺寸与 sha256 见 [notes.md](./notes.md)。

验证（在 MacWave 仓库里）：

```bash
tar -xJf out/git-2.56.1-arm64.tar.xz -C /tmp/g
bash scripts/selfbuilt_check.sh /tmp/g/bin/git --arch arm64 --bin-name git
```
