# choma 实测记录

数值取自 2026-11-21 迁移时的核对（对个人账户时代的产物逐字节比对，见 README）。

## 产物

| 架构 | lipo -archs | 大小 | min_os | sha256 |
| --- | --- | --- | --- | --- |
| arm64 | arm64 | 134,296 B | 11.0（`LC_BUILD_VERSION`） | `090031020461775f3ff818681e838ca44c7ab535925b605e6bafca6da70abbf8` |
| amd64 | x86_64 | 116,408 B | 10.13（`LC_VERSION_MIN_MACOSX`，老工具链写法） | `4e4b2e94ff42109f53c403facfcbaecc55cd2313135fe25a26e47bad220762d6` |

两个架构的 `min_os` **不一样**：amd64 那份是 2026-08 用旧工具链编的，写的是
`LC_VERSION_MIN_MACOSX 10.13`；arm64 那份是 `LC_BUILD_VERSION 11.0`。索引记录
照实测值写，别统一成一个数。

## 索引记录

`infosource/pkg/pkginfo_<架构>/choma/_choma@1.0-macwaveteam2`：

```
sha256: "<上表>"
file: "ChOma_<架构>"      ← 裸可执行文件，没有扩展名，所以 payload_filename 拼出
                            choma@1.0-macwaveteam2.<架构>
url: "https://github.com/MacWaveOrg/Ports/releases/download/choma/ChOma_<架构>"
deps: "openssl@3.0.15"    ← 2026-11-21 补的，之前漏了（见下）
min_os: "11.0"            ← arm64；amd64 是 "10.13"
```

### `deps` 那一行是后补的，漏了会坏

产物**动态**链着 libcrypto：

```
arm64: /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib     ← 构建机的 Homebrew
amd64: /opt/local/libexec/openssl3/lib/libcrypto.3.dylib     ← MacPorts 的路径
```

原来记录里没有 `deps:`，于是 `wave install choma` 不会装 openssl，
安装时的路径改写（`transfer.sh`，按 basename 在 deps 树里找）也没有目标可指 ——
没装 Homebrew 的机器上直接 `dyld: Library not loaded`。

补上 `deps: "openssl@3.0.15"` 之后实测：openssl 被自动装进
`~/.local/macwave/deps/openssl/openssl@3.0.15/`，`otool -L` 里的引用被改写成
`…/deps/openssl/openssl@3.0.15/lib/libcrypto.3.dylib`，`choma` 跑通。

**以后重编时建议静态链 libcrypto**，那样就不必再声明 openssl —— 代价是 openssl
的安全更新要跟着重编一次。这条写在这里，供下次决定。

## 当时跑过的验证

```
$ ./choma 2>&1 | head -2        # 打印用法，退出码 0
$ otool -L choma                # 只有 /usr/lib/*，没有第三方 dylib
```

（库链接是静态进可执行文件的，所以 `otool -L` 干净。）

## 2026-11-24 重建（4.6 重定位）

`stage` 改为运行时布局 `bin/<名称>@<版本>/`，打包前跑 `scripts/relocate_stage.sh`，
顺序为「编 → 重定位 → 签名 → 打包」。上面的哈希表已过期，以索引为准：

```
24084ac081259407ac9835aaeb8454c3ff23d64cddb382afef9908d6fc0f7d28  arm64  (min_os 11.0)
34726335e0c87080ba94cf059bc16ed4bf73ed7d60933d44552e26fc7173f025  amd64  (min_os 10.13)
```

改为钉 commit SHA（上游没有 tag），取件走 codeload/`gh api`。libcrypto 静态链入，产物只依赖 CoreFoundation + libSystem，索引里的 `deps: openssl@3.0.15` 已删。

### 抓错产物：发出去的是 dylib 不是命令

第一次重建时 `build.sh` 用 `find output -maxdepth 2 -perm -111 | head -1` 取产物，
而脚本同时设了 `DISABLE_TESTS=1` —— CLI 在 `output/tests/choma_cli`，关掉测试就只剩
`output/lib/libchoma.dylib`，于是包里塞进一个动态库，`bin_name: choma` 解析出来的
`ChOma_<arch>` 根本不能执行（`file` 报 "dynamically linked shared library"）。

修法：分两步 make —— 先 `DISABLE_TESTS=1` 编库，再 `DISABLE_TESTS=0 output/tests/choma_cli`
只点那一个目标（整体开测试编不过：`tests/choma_sign` 用的是旧 API）。

闸门也补了一条：单文件产物必须 `file` 认成 executable，否则报
`not an executable`。这条检查在修之前跑过、确认能复现该缺陷。
