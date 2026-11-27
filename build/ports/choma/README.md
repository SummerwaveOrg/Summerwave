# choma

**上游：** [opa334/ChOma](https://github.com/opa334/ChOma) —— 代码签名与 Mach-O 操作库。
**命令：** `choma`（`bin_name: "choma"`，与二进制同名）。
**为什么自建：** 上游只发布源码，从不提供 macOS 二进制。

## 历史上放在哪

最早编出来放在个人账户 `Sha0huaZhang/ChOma-macwave`（tag `v1.0-macwaveteam2`），
2026-11-21 迁到本仓库的 `choma` release，**字节完全相同**：

| 架构 | 文件名 | 大小 | sha256 |
| --- | --- | --- | --- |
| arm64 | `ChOma_arm64` | 134,296 B | `090031020461775f3ff818681e838ca44c7ab535925b605e6bafca6da70abbf8` |
| amd64 | `ChOma_amd64` | 116,408 B | `4e4b2e94ff42109f53c403facfcbaecc55cd2313135fe25a26e47bad220762d6` |

索引记录里的 `min_os: "11.0"` 来自 `vtool -show-build`；构建时
`-mmacosx-version-min=10.13`（库本身），CLI 的可执行文件按实际读到的值写。

## 怎么编的

见 `build.sh`。两个架构分别编，产物是裸可执行文件（不带扩展名），这样
`payload_filename()` 拼出来正好是 `choma@<版本>.<架构>`。
