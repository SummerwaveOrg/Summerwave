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

## 四、不能忘的两条

1. **旧仓库不动**：`MacWaveOrg/*` 与 `LinuxWaveOrg/*` 保持现状，新线路出问题随时能回退
   （旧线的客户端只认旧域名，互不影响）。
2. **Actions 在新仓库是关闭的**（`enabled=false`）：继承来的工作流里有
   `sync-release-branch.yml` 会按发布线把分支建回来。等 1.0 的 CI 重新设计后再开。
