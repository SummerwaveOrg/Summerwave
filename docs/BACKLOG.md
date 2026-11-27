# 待办与已记录的需求

这里只记「已经想清楚、还没做」的东西。做完一项就把条目删掉，结论落到代码与文档里 ——
不要把它养成第二份文档。

---

## 1.0

### 数据侧切换：索引搬家 + 产物改名（已备好工具，未执行）

**现状。** 1.0 的代码只认新布局（`pkg/pkginfo/<包>/_<包>@<版本>.<os>-<arch>`、
产物名 `jq@1.8.2.macos-arm64.tar.gz`），但真实的 `SeaLane` 还是
`pkg/pkginfo_arm64/` + `jq@1.8.2.arm64.tar.gz`。于是 `wave install <任何包>` 报「没有这个包」——
不是 bug，是数据还没搬。

**已经有的。** `scripts/migrate_index_layout.py`（带离线回归
`scripts/migrate_index_layout_test.sh`）：dry run 出计划、`--apply` 只搬记录、产物改名单独
生成 gh 脚本。真实数据上实测：830 条记录、145 份重复 `@common`、682 个产物待改名。

**剩下的。**
1. 解决 1 处真冲突（`test_001` 两个架构的 `@common` 内容不同 —— 留哪份是人的决定）
2. 跑 682 个产物的改名（下载 → 新名上传 → 默认保留旧名，避免打断 4.x）
3. `build_versions_index.py` 重生成镜像的 `versions` 清单
4. 端到端装一次验证

完整步骤见 `~/MD/Summerwave/1.0-切换操作手册-数据侧.md`。

### `Selfupdate` 缺 `prerelease/` 探针（卡在签名口令）

**现状。** 1.0 的 `preview` 渠道读 `Selfupdate/prerelease/latest.toml`，仓库里只有
`macwavedata/` 与 `rcdata/`（后者的头部还在解释 `channel_for`，那个函数已经删了）。
验签是强制的（`.sig` 缺失或不对 → 拒绝安装），而私钥带口令，脚本代签不了。

**要做的。** 建 `prerelease/latest.toml` + 用 `~/MD/密钥/private/macwave-rsa.key` 签一份
`latest.toml.sig`；`rcdata/` 要么删掉，要么在 README 里注明只服务 4.x 客户端。

### `selfupdate = "blocked"` 还没有真实样本

两处执行点（`lib/selfupdate.py` / `lib/selfupdate.sh`）都实现了，但只用赝品探针测过。
需要在一份**签名齐全**的 `prerelease/latest.toml` 上验：退出码 0、一个字节都不改、打印原因。
与上一条同一个卡点。

### 镜像拓扑在文档里自相矛盾（需要拍板）

`docs/MIRROR-SETUP.md` 说 `LinuxWave/` 只是预留、本文任何一步都不需要建它；
`docs/MIRROR-ONBOARDING.md` 在逐条描述一个已经有 69 个产物的 LinuxWave 镜像。
合并成 Summerwave 之后是单层 `Summerwave/` 还是继续 `MacWave/` + `LinuxWave/`，
会影响所有 `MACWAVE_*_DOMAIN` 的默认值与镜像 rsync 路径。**未定，不要擅自改。**

### `platform/linux/` 的终态（需要拍板）

`224` 个文件与 `LinuxWaveOrg/LinuxWave@4d59d42` 逐字节一致（2026-11-26 用 tree hash 复核过）。
它是「先把东西搬进来、再按模块消化」的过渡目录，但消化到什么程度没定：
Linux 的 `surfboard/depsmanager.sh` 与 macOS 那份是两套实现，合成一套是大工程。
在那之前它是只读的：`shell_lint` / `structure_test` 都不该把它当自己的代码对待。

---

## 4.4.1

### 进度条占一行刷新，用户按过回车才另起一行

**现状。** 下载进度有两种画法，各说各的：

| 场景 | 实现 | 表现 |
| --- | --- | --- |
| 交互（非 `--raw`） | `rich` 的 `Progress`（`pkg/pkginstaller.py:594`） | 原地刷新，天然只占一行 |
| `--raw` | `pkg/pkginstaller.py` 的 `_emit()`（`:504`） | 每 10% **打一行** `####....  30%` |

用户看到的就是后者：`wave install test_bin_gz --raw` 打了 10 行。

**需求。** 进度条始终在**同一行**上刷新（`\r` + 覆盖），不要刷屏；例外是用户自己按过
回车 —— 这时不能再覆盖（会吃掉用户刚敲的东西 / 那一行已经是一个新行），改为另起一行继续。

**要一起想清楚的三点。**

1. **`--raw` 的契约会被改掉。** 现在 `--raw` 的定义是「机器可读：没有光标控制，每 10%
   一行」。改成 `\r` 就是**引入光标控制**，与「日志可以原样重定向到文件」矛盾 ——
   重定向到文件时 `\r` 会把所有进度挤成一行超长文本。
   建议：**TTY 上才用 `\r`，非 TTY（管道/重定向）保持每 10% 一行**。这样 `--raw` 的
   契约变成「无颜色、无艺术字、无 spinner；进度行在终端里原地刷新，重定向时逐行」。
2. **「用户按过回车」怎么判。** 纯 Python 拿不到「刚才有人敲了回车」这个事件（除非
   读 stdin，会与 `--ci` / 管道冲突）。可行的近似：每次刷新前查终端宽度，若当前行
   已经超过宽度则换行；或者干脆用一个**行内标记**：`\r` 之前若检测到别的东西写过
   这一行（记录上次写出的字节数，实际列宽变了）就换行。
   如果做不到，就把这条降级成「**只保证 TTY 下原地刷新**，任何其它写入自然打断它」，
   并在文档里写明 —— 不要假装能检测按键。
3. **测试要跟着改。** `scripts/raw_test.sh:169` 断言「至少一行形如 `rawpkg: ####.... 40%`
   并且最后到 100%」。重定向到文件时行为不变（逐行），所以它**应该仍然通过** ——
   如果改成无条件 `\r`，它会红，那就说明第 1 点没做对。

**验收。**

- `wave install <pkg> --raw` 在终端里只占一行，`30%` 被 `40%` 覆盖。
- `wave install <pkg> --raw > /tmp/log` 时 `/tmp/log` 里仍是逐行 10 条（可 `grep ' 100%'`）。
- `wave install <pkg>`（非 raw）表现不变。
- 进度进行中按回车，后续刷新另起一行，不回退覆盖。

### `wave manual --colour`：接受英式拼写

**现状。** 手册上色只认 `--color`（`cli/manual.py:113` 直接比字符串 `"--color"`，
`cli/flags.py:88` 的白名单里也只有它），文档里写的是 `Colour headings and flags` ——
说明文字用的是英式拼写，旗标却是美式，看着别扭。有人因此敲了 `--colour` 被当成
「不认的旗标」拒掉。

**需求。** `--colour` 与 `--color` 等价。

**落点（三处，别漏）。**

1. `cli/flags.py` 的 `manual = {"--color"}` 加上 `--colour`。**注意别直接塞进
   `ALIASES`**：那条机制是给「改名」用的，`describe()` 会说 `<旧名> is the old name of
   <新名>`（`:196`），而对拼写变体这是**错的** —— 需要一个新的映射（例如
   `SPELLINGS = {"--colour": "--color"}`），让 `describe()` 答
   `--colour is the British spelling of --color`。
2. `cli/manual.py` 的判定改成「两个名字任意一个出现即上色」，`rest` 过滤也要同时
   去掉两者（`:113`、`:114`）。
3. 文档：`cli/commands.py:332/336/342` 的用法行与示例、`cli/help_zh.py:161` 的中文
   说明、`man/` 里对应条目、README 若提到。

**验收。**

- `wave manual install --colour` 与 `--color` 输出一致（有颜色）。
- `wave manual install --colour` 不报「不认的旗标」。
- `wave -h` 里 `manual` 那一行仍只显示规范写法 `--color`（别名不进帮助，只进白名单）。
- `scripts/commands_test.sh`（帮助里的旗标必须在 `flags.ALL` 里）与 `flags_test.sh`
  （`describe()` 的措辞）都要跟着补一条。

