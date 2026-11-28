# 0.1.0 的约定（唯一出处）

这份文件收集 0.1.0 定下来的、**跨仓库**的约定。改动成本很高（客户端、数据、产物、
发布脚本、文档都按它写），所以：

- 新约定先写进这里，再改代码；
- 代码与本文冲突时，以本文为准，并当场修代码；
- 4.x 的历史约定不在这里（见 `docs/RELEASE-4.*.md` 与 `docs/BRANCH-HISTORY.md`）。

---

## 一、发布 tag

```
v<版本>[@<构建时刻>][-<渠道>.<序号>]
```

| 例子 | 含义 |
| --- | --- |
| `v1.2.3@2026-11-26T11:23Z` | 正式版 |
| `v1.2.3-rc.1@2026-11-26T11:23Z` | 候选版 |
| `v1.2.3-beta.2@2026-11-26T11:23Z` | 测试版 |
| `v1.2.3` | 只有版本号（人工发的普通 tag，不带构建号） |

**一律 UTC，精确到分钟，必须带 `Z`。** 不接受 `+08:00` 之类 —— 同一个 tag 在不同
机器上解释出不同时间，排序就会错。

**为什么要有 `<构建时刻>`**：同一个版本号可能重发（修打包错误、换 SDK 重编），
只靠版本号分不出新旧。时刻在 tag 里，排序即时间排序。

**渠道只从 tag 来**。不再有 `rcdata/latest.toml` 那种「另一条流」，也不再有
`build_number` 字段。`latest` 只认正式版；只有当仓库里**一个正式版都没有**时才退回
预览版（刚起步的阶段）。

解析与挑选只有一处实现：`lib/taginfo.py`（`parse` / `format_tag` / `pick_latest`），
回归测试是 `scripts/taginfo_test.sh`。

---

## 二、自更新：没有 `Selfupdate` 仓库

4.x 的自更新要读 `MacWaveOrg/Selfupdate` 里的 `macwavedata/latest.toml`（版本指针）、
`<版本>/files.txt`（文件清单）、`<版本>/update_commands.sh`（要被 bash 执行的脚本）。
**0.1.0 全部取消**：

| 原来 | 现在 |
| --- | --- |
| `latest.toml` 指针 | 直接读 Summerwave 的 Release / tag（见第一节） |
| `files.txt` 文件清单 | install.sh 下载该 tag 的源码包，整树同步 |
| `update_commands.sh` | 客户端自己执行更新，不再 bash 任何下载来的脚本 |
| `latest.toml.sig` | 信任锚改为：HTTPS + tag 约定 + 产物 `sha256` |

自更新本身由 `lib/install.sh` 用**标记**完成（`Shore/` 下的版本目录、`Note` 收据、
`_RELOCATED` 标记），不依赖任何外部元数据。

---

## 三、索引（`SummerwaveOrg/SeaLane`）

```
<名>/_<名>@common                      元数据（bin_name / des / hom / lic / aut）
<名>/_<名>@<版本>.macos-<arch>         一条版本记录
```

- **单一命名空间，直接在仓库根**。没有 `pkg/` 与 `deps/` 之分，也没有按架构分目录。
  「是依赖」只体现在别的记录在 `deps:` 里列了它；包与依赖装到同一个
  `Shore/<名>/<版本>/`。
- **平台标签在记录名里**：`macos-arm64` / `macos-amd64`（词表封闭，见
  `config/platforminfo.py` 的 `bottle_tag`）。一个目录放所有平台的记录。
- 客户端默认地址：`raw.githubusercontent.com/SummerwaveOrg/SeaLane/HEAD`。

4.x 的索引 `MacWaveOrg/infosource`（`pkg/pkginfo_<arch>/…`）**冻结保留**，
只为让现存 4.x 机器继续工作。

---

## 四、载荷（`SummerwaveOrg/Bottle`）

- 一个仓库装全部产物（包与依赖同构），**一个 Release 一个包**，tag 就是包名。
- 资产名 `<名>@<版本>.macos-<arch>.tar.bz2`，归档根是**版本目录的内容**
  （`bin/` `lib/` `include/` …），与 `Shore/<名>/<版本>/` 同构。
- 客户端默认地址：
  `SUMMERWAVE_BOTTLE_DOMAIN` 与 `SUMMERWAVE_DEPS_DOMAIN` 都指向
  `https://github.com/SummerwaveOrg/Bottle/releases/download`。
- 4.x 的 `MacWaveOrg/Bottle`、`MacWaveOrg/Deps` 冻结保留。

---

## 五、产物（Bottle 里的东西长什么样）

三条铁律，顺序不能换：

1. **编 → 重定位 → 签名 → 打包**。`install_name_tool` 会作废签名，反序的产物在
   Apple Silicon 上直接不执行。
2. **两个架构分别编**，不做 universal。
3. **命令必须在 `<版本>/bin/` 下**（树模式只从 `bin/` 取命令；二进制躺在版本目录根上
   等于装完一条链接都不建，而且不报错）。

路径的两套规矩：

| 类型 | 允许写什么 |
| --- | --- |
| Mach-O 的 `LC_LOAD_DYLIB` / `LC_ID_DYLIB` | `@loader_path` / `@rpath` / `@executable_path`，外加 `/usr/lib` `/System` `/Library/Apple` |
| 文本（`.pc`、wrapper、配置） | 绝对路径 `/opt/macwave/Shore/…`（安装根写死，绝对路径才稳定） |

**不许引用本机临时目录**：构建期的 `/tmp`、`/var/folders` 路径一旦进产物，用户机上
就是死路径。`prepare_bottle.py` 的 `audit_archive()` 与
`Ports/scripts/selfbuilt_check.sh` 各有一道闸门。

---

## 六、安装位置与系统地板

- **只有一处**：macOS `/opt/macwave`（配置 `/opt/macwave_config`）、
  Linux `/home/linuxwave/.linuxwave`。没有自定义目录、没有用户级安装、没有 `--dir-option`。
- **系统地板按架构**：`arm64` = macOS 15.0、`x86_64` = macOS 13.0
  （`config/platforminfo.py` 的 `MIN_SUPPORTED_OS`，构建时由 `scripts/build-env.sh` 落成
  `-mmacosx-version-min`）。对外承诺就是这两句。
- 平台只认内核：`macos` / `linux` / `unknown`；iOS / Android / ChromeOS 不识别。

---

## 七、域名

| 用途 | 地址 |
| --- | --- |
| 官网 | <https://summerwave.org/>（GitHub Pages，仓库 `SummerwaveOrg/Pages`） |
| 索引 | `raw.githubusercontent.com/SummerwaveOrg/SeaLane/HEAD` |
| 载荷 | `github.com/SummerwaveOrg/Bottle/releases/download` |
| 自更新数据 | **无**（见第二节） |
| 用户协议 | <https://summerwave.org/#agreement> |

`macwave.org` 只作为**跳转**存在（`MacWaveOrg/Pages` 的 `index.html` → summerwave.org）；
`elysia.macwave.org`、`voanisa.macwave.org`、`sw.macwave.org` 是各自独立的站点，
不受这层跳转影响。

品牌：新文案一律写 **Summerwave**；路径、`MACWAVE_*` 环境变量、`wave` 命令名、
`/opt/macwave` 全都不改。

---

## 八、构建来源

**所有产物都从上游源码编**，不再转发别人编好的二进制：

- 每条记录的 `url` 指向该版本的源码包（`…/archive/refs/tags/<tag>.tar.gz`）；
- 构建用 `Ports/scripts/build-source.sh`（按构建系统分派：
  `go` / `cargo` / `cmake` / `meson` / `autotools` / `make`）；
- 测绘脚本 `scripts/source_census.py` 负责「这条记录的上游仓库是哪个、tag 在不在、
  用什么构建系统」。

例外：CI 的测试夹具（`test_*`）故意用假 URL，不参与构建。
