# build/ports —— 源码自建的配方与工具

上游不发 macOS 二进制、或者上游产物带着别人家前缀（conda-forge 的
`_h_env_placehold_…`）时，我们自己从源码编。这一层只管两件事：**怎么编**（`build.sh`
+ `notes.md` + `.patch`）和**怎么批量编**（`scripts/`）。

## 为什么它在主仓里（2026-11-27 从 `MacWaveOrg/Ports` 并进来）

它原先是一个独立仓库。并进来的理由：它**只产出软件包**，本体量是几百 KB 的文本，
跟 `scripts/` 属于同一类东西（「我们是怎么造出这些字节的」），没必要单独一个仓、
单独一次归档。

## 这里**不放产物**

产物走 `SummerwaveOrg/Bottle`（包与依赖同一个仓），索引记录里的 `file:` / `sha256:`
描述的就是那边的最终载荷。以前这个仓库还存了一份「重打包之前的中间产物」，0.1.0 取消：

* 那份东西不可复现，存着也证明不了什么；能追溯的是 recipe + 固定的上游版本；
* 客户端永远不下载它 —— 索引的 `url:` 字段在 0.1.0 **不参与安装**（`--install-from-source`
  已彻底删除）；
* 存两份 188 MB，唯一的效果是让仓库变重。

历史产物仍在 `MacWaveOrg/Ports` 的 Release 里（该仓已归档，资产照常可下）。

## 两种端口，别混

| | **整树端口（0.1.0 起）** | **单文件端口（4.x 遗留）** |
| --- | --- | --- |
| 产物名 | `<名>@<版本>.macos-<arch>.tar.bz2` | `<名>-<arch>`、`git-<版本>-<arch>.tar.xz` |
| 归档根 | 版本目录的内容（`bin/` `lib/` `include/` …） | 一个可执行文件 |
| stage 布局 | `<stage>/opt/macwave/Shore/<名>/<版本>/` | `<stage>/bin/<名>@<版本>/` |
| 重定位 | `mw_relocate_stage`（走 `relocate_rpath.py`） | `scripts/relocate_stage.sh` |
| 索引里的 `file` | `"<名>@<版本>.macos-<arch>.tar.bz2"` | `"<名>-<arch>"` |
| 现状 | `zlib` `openssl` `ncurses` `pcre2` `zstd` | `aria2c` `bash` `git` `fish` `patch` `tar` `dtc` `hx` `nu` `choma` `checkra1n` `testdisk` `xcodegen` `ast-grep` |

单文件端口是 4.x「`bin/<名>@<版本>/` 里躺一个裸文件」时代的写法，**0.1.0 的布局不支持**
（版本目录是整棵树，`install: "tree"`）。它们要用的上游版本没变，所以没有立刻重写；
真要重编某个包时，照 `zlib/build.sh` 的样子改造成整树端口，不要在旧脚本上打补丁。

## 构建环境一律走 `scripts/build-env.sh`

`-arch` / `-mmacosx-version-min` / `-isysroot` / `-Wl,-headerpad_max_install_names`
这四件不要在各家的 `build.sh` 里手写 —— 漏一个的表现都是「构建机上一切正常，用户
那边不行」。`source` 一次，全部就位：

```bash
source "$HERE/../scripts/build-env.sh"
mw_build_env arm64                                   # 导出 CC/CXX/CFLAGS/LDFLAGS/MACOSX_DEPLOYMENT_TARGET
./configure --prefix="$(mw_prefix ncurses 6.6)" ...
mw_relocate_stage "$STAGE_ROOT"                      # 重定位 + 自检
mw_verify_artifact out/x.tar.bz2 arm64               # 上传前的闸门
```

### 系统地板按架构分，不是全库一个值

| 架构 | 地板 | 理由 |
| --- | --- | --- |
| `arm64` | **15.0**（Sequoia） | 任何 Apple Silicon Mac 都跑得动 15，这个地板排除不了任何硬件，只排除「能升但不升」 |
| `x86_64` | **12.0**（Monterey） | 由 Intel 构建机的 SDK 决定；它让停更的老 Intel Mac 也能装 |

对外承诺就是这两条：**macOS 12（Intel）/ macOS 15（Apple Silicon）**。
构建机不能比目标地板更老（老 SDK 编不出新系统的产物），`mw_build_env` 直接拦。

`mw_prefix <名> <版本>` 给的是**装完之后的绝对路径**（`/opt/macwave/Shore/<名>/<版本>`）。
0.1.0 起安装位置写死，所以 `.pc`、`configure` 烘进去的前缀天生就是对的，不需要事后替换 ——
这正是「从源码编」相对「改写上游二进制」的核心好处。

### 二进制里只能有相对路径，文本里写绝对路径

| 类型 | 允许 | 为什么 |
| --- | --- | --- |
| Mach-O 的 `LC_LOAD_DYLIB` / `LC_ID_DYLIB` | `@loader_path` / `@rpath` / `@executable_path`，外加 `/usr/lib` `/System` `/Library/Apple` | 沙箱测试会把包装到 `$(mktemp -d)/opt/macwave` 再跑，写死 `/opt/macwave` 就炸 |
| 配置、`.pc`、wrapper 脚本 | 绝对路径 `/opt/macwave/Shore/…` | 安装根固定，绝对路径才稳定；相对路径反而会在 `cd` 之后失效 |

## 取件一律走 `scripts/fetch.sh`

国内网络（校园网、家宽）常年把 `github.com` 掐掉，而 `api.github.com` /
`codeload.github.com` 通常还通 —— 实测同一条链路 `github.com` 12 秒连不上，
`api.github.com` 0.3 秒 200。所以 build.sh 里不要直接写 `curl`：

```bash
bash "$FETCH" "<url>" "<output>"
```

- `github.com/<owner>/<repo>/releases/download/<tag>/<file>` → 走 `gh release download`
  （打 API 再重定向到 CDN，完全不碰 `github.com`）；`gh` 不可用时退回 curl。
- 其他（kernel.org、invisible-island、上游自有域名）→ curl，带重试。
- 要 `git clone` 的上游，改成取 `https://codeload.github.com/<owner>/<repo>/tar.gz/<ref>`。

取件方式换了不影响可信度：每个 build.sh 都按 sha256 锁死上游产物，下错了直接失败。

## 上传前必跑：`scripts/selfbuilt_check.sh`

| 检查 | 为什么 |
| --- | --- |
| 架构与 `--arch` 一致 | 拿 arm64 的产物发 amd64 的条目，用户那边直接 `Bad CPU type` |
| `codesign --verify` 通过 | 改过路径没重签，Apple Silicon 上根本不执行 |
| 引用里没有绝对路径 | 见上面「二进制相对 / 文本绝对」那张表 |
| 整树包的文本文件里没有**本次构建**的临时目录 | 例如烘进去的 `GIT_EXEC_PATH`、`icu-config` 的 `default_prefix`；Mach-O 检查看不见，换台机器就指向不存在的目录。上游源码里本来就有的 conda `croot` 路径不算 |
| `minos` 不超过该系统地板 | 忘了 `-mmacosx-version-min` 时 minos 就等于构建机的系统版本 —— `aria2c@1.37.0` 就是这么变成「声明支持 12、实际要求 15」的，构建机上完全看不出来 |

```bash
bash scripts/selfbuilt_check.sh out/x.tar.bz2 --arch arm64 --max-minos 15.0
```

退出码非 0 就不要上传。

## 三条硬顺序

1. **编 → 重定位 → 签名 → 打包**。`install_name_tool` 改写 Mach-O 会作废已有签名；
   先签后改，产物在 Apple Silicon 上直接不执行。`LDFLAGS` 里带
   `-Wl,-headerpad_max_install_names`，否则路径一变长就写不下。
2. **两个架构分别编**，不要 universal：索引是「每架构一个产物」，词表只有
   `macos|linux` + `arm64|amd64`（用 `mw_bottle_tag` 取，不要自己拼）。
3. **产物名决定索引记录名**：`<名>@<版本>.macos-<arch>.tar.bz2` ↔ `_<名>@<版本>.macos-<arch>`。
   名字对不上，客户端就找不到文件。

## 自建之后必须回填索引

源码编出来的产物与上游产物**必然不同**（sha256 变，`install:` 可能从单文件变整树，
`relocated` 变 `loader_path`）。所以编完不是结束，还要：

1. 上传到 Bottle/Deps 的 Release（tag = 包名，文件名 = 上面的产物名）；
2. 用 `Summerwave/scripts/apply_rebuilt_records.py` 把 `file` / `sha256` /
   `relocated` / `install` 写回 `infosource` 的记录；
3. 依赖引用若有版本抬升（例如 `zlib@1.2.13` → `zlib@1.3.1`），把所有下游记录的
   `deps` 一起改；
4. 重新生成镜像的 `versions` 列表。

顺序与细节见 `~/MD/Summerwave/1.0-切换操作手册-数据侧.md`。

## 已收录

### 整树端口（0.1.0）

| 包 | 上游 | 为什么自建 |
| --- | --- | --- |
| `zlib` | [madler/zlib](https://github.com/madler/zlib) | conda-forge 产物带 `info/has_prefix`；1.2.13 在现代 SDK 上编不过（`zutil.h` 把 `fdopen` 定义成宏），所以用 1.3.1 |
| `openssl` | [openssl/openssl](https://github.com/openssl/openssl) | 被依赖最多的库之一（git / curl / python 全链），一次编对胜过每次装都做二进制前缀替换 |
| `ncurses` | [invisible-island/ncurses](https://invisible-island.net/ncurses/) | htop / tmux / ncdu 的上游；只编宽字符版（`--enable-overwrite`），另补不带 `w` 的库名链接 |
| `pcre2` | [PCRE2Project/pcre2](https://github.com/PCRE2Project/pcre2) | conda-forge 产物带 `has_prefix`；8/16/32 三种宽度 + JIT 全开 |
| `zstd` | [facebook/zstd](https://github.com/facebook/zstd) | conda-forge 产物带 `has_prefix` |

### 单文件端口（4.x 遗留，待迁移）

`aria2c` `ast-grep` `bash` `checkra1n` `choma` `dtc` `fish` `git` `hx` `nu` `patch`
`tar` `testdisk` `xcodegen`

这些包的上游长期不发 macOS 二进制（或发的架构不对），所以自建；`notes.md` 里有
实测的 `otool -L`、`minos`、产物大小与 sha256。

## 许可

本仓（脚本与补丁）采用 **Apache License 2.0**，见 [LICENSE](../../LICENSE) 与
[NOTICE](../../NOTICE)。它编译出来的软件沿用各自上游的许可，不在 Apache-2.0 覆盖范围内。
