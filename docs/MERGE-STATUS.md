# 合并状态：MacWave + LinuxWave → Summerwave

> 目标：**一个核心、两个平台**。这一步只把「两边的历史」和「两边的代码」放进同一个仓库，
> **还没有开始合并代码**——代码合并按模块来，见文末的清单。

---

## 一、现在的形状

```
SummerwaveOrg/Summerwave
├── main                  ← 继承下来的 MacWave 4.6.1 发布线（历史锚点）
├── 1.0                   ← 工作分支：布局重构 + 这次的历史合并
├── platform/linux/       ← LinuxWave 4.6 的整棵树（**过渡目录**，不是终态）
└── tag import/linuxwave-4.6 → 4d59d42（LinuxWave 的提交点）
```

`platform/linux/` 的 224 个文件与 `LinuxWaveOrg/LinuxWave@4d59d42` **逐字节一致**
（`diff` 验证过）。它是"先把东西搬进来、再按模块消化"的落点，不属于最终布局。

---

## 二、历史怎么查（两边都能查）

**MacWave 侧**：就是本仓库的主线。

```sh
git log --oneline 1.0
git log --oneline -20 4.6.1   # 旧线不在本仓库，见 docs/BRANCH-HISTORY.md
```

**LinuxWave 侧**：`493` 个提交全部保留，SHA 未改写：

```sh
git log --oneline import/linuxwave-4.6 | head
git log import/linuxwave-4.6 -- lib/install.sh     # 看某个文件在 LinuxWave 里的历史
git show import/linuxwave-4.6:<path>
```

> ⚠️ 为什么不用 `git log -- platform/linux`：那次合并是「`-s ours` + `read-tree --prefix`」，
> 第二个父提交里的路径是**根目录**（`lib/install.sh`），不是 `platform/linux/lib/install.sh`。
> git 的路径限制遍历在第二个父里找不到这个前缀，于是只停在合并提交上。
> 这是**预期行为**，不是历史丢了——用 `import/linuxwave-4.6` 这个引用查即可。
>
> 如果哪天需要 `git log`/`git blame` 直接按 `platform/linux/` 前缀工作，正确做法是先用
> `git filter-repo --to-subdirectory-filter platform/linux` 重写一份历史再合并——**代价是
> LinuxWave 的 SHA 会全部改变**。现在没做，是因为"SHA 可追溯"比"命令顺手"更值钱。

---

## 三、合并代码的顺序（还没做）

按「先让该相同的相同，再动结构」：

| # | 模块 | 两边现状 | 目标 |
| --- | --- | --- | --- |
| 1 | `config/`（`configpaths`、`envvar`、`configerror`） | 差异最小（~35%） | 直接对齐成一份，`Shore`/`Note` 的常量放在这里 |
| 2 | `lib/`（`versioncompare`、`steplog`、`lock`、`basedir`、`shellenv`） | 与平台无关 | 一份 |
| 3 | `net/`（`domains`、`tls`） | 域名与默认值不同，逻辑相同 | 一份 + 每平台一份默认值表 |
| 4 | `pkg/`（`pkginstaller`、`linker`、`uninstaller`、`doctor`…） | **重定位/签名是平台差异** | 一份 + `mw_relocate`/`mw_sign` 接口 |
| 5 | `surfboard/`（`transfer`、`depsmanager`、`depsinstaller`） | 同上，shell 侧差异最大 | 一份 + 平台脚本按接口分派 |
| 6 | `cli/` | 子命令集合几乎相同 | 一份 |
| 7 | `lib/install.sh` / `selfupdate.sh` / `uninstall.sh` | 差异 58%~79% | 一份，平台差异收进一个 `platform` 脚本 |

判据（来自合并评估）：**98 个同名文件里只有 5 个逐字节相同**；目标是先让第 1~3 行
（约 3000 行）变成逐字节相同，再谈 4~7。

---

## 三之二、平台判断：**只许一处**

合并最容易发生的退化是"这里加个 `if darwin`"。所以定死：

| 允许出现 `sys.platform` 的地方 | 内容 |
| --- | --- |
| **`config/platforminfo.py`**（唯一） | `IS_MAC`、`DEFAULT_BASE_DIR`、`system_version()`、`describe()` |
| 别的差异 | 走**能力探测**（`shutil.which("patchelf")`）或**文件类型判定**（Mach-O / ELF magic），不判断"当前是什么系统" |

已经按这条改过的两处：

| 原处 | 原来 | 现在 |
| --- | --- | --- |
| `lib/basedir.py` 搬家 | `if sys.platform == "darwin": cp -Rc` | 直接试 `cp -Rc`，失败回退 `copytree`（本身就是能力探测） |
| `pkg/pkginstaller.py` | `if sys.platform != "darwin": return None` | `platforminfo.system_version()` |

CI 守则（TODO，接 `shell_lint.sh` 一起上）：

```sh
grep -rn 'sys.platform\|platform.system()\|os.uname' --include=*.py \
     config lib net cli pkg surfboard \
  | grep -v '^config/platforminfo.py:' && exit 1
```

---

## 三之三、模块账本

方向：**以 MacWave 为基线**，逐模块把 LinuxWave 的差异搬进来（LinuxWave 普遍落后一次重构）。

### `config/`（1040 行）—— 已裁定：采用我方

| 文件 | 差异 | 性质 | 裁定 |
| --- | --- | --- | --- |
| `envvar.py` | 40 行 | 100% 前缀与组织名（`MACWAVE_*` vs `LINUXWAVE_*`） | 采用我方 |
| `configerror.py` | 30 行 | 100% 文案 | 采用我方 |
| `configpaths.py` | 382 行 | LinuxWave 多 `proxy_value_from` / `apply_proxy_from_command_line` | **采用我方**：`--proxy` 解析已搬去 `cli/common.py`，LinuxWave 是落后一次重构 |

### `lib/`（14 个文件）

| 文件 | 差异行 | 裁定 |
| --- | ---: | --- |
| `downloads.py` | 0 | 逐字节相同 |
| `lock.py` | 6 | 采用我方（差异只在注释里的历史叙述） |
| `steplog.py` | 11 | 采用我方（我方已抽 `envvar.kinds()`） |
| `mirrorinfo.py` | 20 | 采用我方（`PIP_ENV` 走 `envvar`，不再硬编码） |
| `shellenv.py` | 26 | **功能零差异**（26 行全是注释）→ 采用我方 |
| `versioncompare.py` | 31 | **已合并**：社区后缀两个都认（`macwaveteam` / `linuxwaveteam`），`suffix_type` 保留原值 |
| `basedir.py` | 91 | **已合并**：`RESERVED_ROOTS` 取两平台并集（并集比按平台切换更安全） |
| `latest.py` | 49 | 待办：采用我方（layout 助手），**移植 Linux 的 `UNREADABLE` / "could not be checked" 报告** |
| `wave.py` | 99 | 采用我方（文案与安装 URL 等品牌切换时统一） |
| `selfupdate.py` | 596 | 待合并（大工程） |
| `uninstall.sh` / `selfupdate.sh` / `install.sh` | 657 / 1598 / 4931 | 待合并（最后做，和 `Shore` 布局一起） |

---

## 四、不能忘的两条

1. **旧仓库不动**：`MacWaveOrg/*` 与 `LinuxWaveOrg/*` 保持现状，新线路出问题随时能回退
   （旧线的客户端只认旧域名，互不影响）。
2. **Actions 在新仓库是关闭的**（`enabled=false`）：继承来的工作流里有
   `sync-release-branch.yml` 会按发布线把分支建回来。等 0.1.0 的 CI 重新设计后再开。

## 0.1.0 只装一处：`/opt/macwave`

2026-11-26 定。安装位置不再是一道选择题，也不再支持三/四个候选：

- **唯一位置** `/opt/macwave`，配置 `/opt/macwave_config`。`~/.local/macwave`、
  `/usr/local/macwave`、自定义目录全部取消。
- `--dir-option` 随之删除；`--ci` 与交互式装到同一处（拿不到提权就明确报错退出）。
- **CI 不许装到自定义目录**：路径一变，排查问题时日志里的路径就对不上，收益为零。
- 要一起拿掉的连带逻辑：位置菜单与候选校验、SIP/SSV 里「目标在保护范围」的分支
  （`/opt` 从不被保护）、提权判定里「用户级不需要 sudo」的分支、`RESERVED_ROOTS`
  的一大半、配置目录的「系统级优先」。

删除顺序（每步 `bash -n` + 跑对应测试，不整块盲删）：① 先删候选位置，`--dir-option`
只认 1；② 再删依赖位置判断的分支；③ 最后删 `--dir-option` 本身，并改 6 个测试
（`install_flags` / `sandbox` / `install_privilege` / `raw` / `multi_install` / `upgrade`）、
帮助文案与 README/docs。

沙箱测试的前提已经具备：`MACWAVE_TEST` 把任意目录当作 `/`，所以 `/opt/macwave`
在沙箱里照样能端到端跑。

### 执行结果（2026-11-26，已完成）

上面那三步都做完了，而且范围比原计划更大——顺带把「配置文件」整个删掉了
（用户决定：路径写死，不要任何配置）。

**落地的东西**

| 变更 | 结果 |
| --- | --- |
| 安装根 | 写死：`config/platforminfo.py` 的 `DEFAULT_BASE_DIR`（`/opt/macwave` / `/home/linuxwave/.linuxwave`）|
| 唯一读取入口 | `configpaths.load_base_dir()` → `rooted(DEFAULT_BASE_DIR)` |
| 删除 | `--dir-option`、位置菜单、`print_install_targets`、`resolve_custom_dir`、`validate_custom_dir`、`CUSTOM_OPTION` |
| 删除 | SIP / SSV 判定（`/opt` 从不被保护）、`RESERVED_ROOTS`、提权判定里的「用户级免 sudo」分支 |
| 删除 | `config.json` 读取链、`config_dir_candidates` / `find_config_dir`、`/opt/macwave_config` 与 `~/.config/macwave_config`、`MACWAVE_BASE_DIR` |
| 删除 | `wave basedir --set`（含整树搬家、APFS clone、三段逐字确认）、`lib/basedir.py` 430 → 82 行 |
| 状态 | 只剩树内 `<base>/var/config.sh`（`MACWAVE_VERSION` / `MACWAVE_BUILD` / `MACWAVE_INSTALLED_AT`）|
| 顺带修掉 | `shellenv` 与启动器里残留的 `links/`（0.1.0 已并入 `bin/`）|
| 顺带修掉 | `index_list_url(arch)` 这个「收了 arch 却不用」的死参数 |

**连带决策**（原摘要里没有，这次一并做完）

- 不兼容任何旧内容：`update_commands.template.sh` 里的 `mq_migrate_legacy_config`
  与 `MACWAVE_INSTALLER_OWNS_CLEANUP` 删除。
- 平台标签收尾：`build_versions_index.py` / `sync_payloads.records()` / `audit_deps.py`
  全部改到 `pkg/pkginfo`、`deps/depsinfo`（不再分架构目录），记录名带 `.<os>-<arch>`。
- `platforminfo.strip_bottle_tag()`：索引里列出的是 `_jq@1.8.2.macos-arm64`，
  客户端选版本时要剥掉标签。

**规模**：43+ 个文件，净删除约 2400 行；`install.sh` 3042 → 2519，
`basedir.py` 430 → 82，`dir_guard_test.sh`（654 行）与 `basedir_set_test.sh`（315 行）整份删除。

**验证**：34 个离线测试全绿 + `sandbox_test.sh` 52/0（真装真卸，走 `sandbox-exec`）。
需要联网/外部数据仓库的 `format_test` / `deps_test` / `random_test` 未在本次运行。
