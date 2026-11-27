# testdisk

自建产物（整树（install: "tree"））。

- 上游：https://www.cgsecurity.org/wiki/TestDisk
- 源码：https://www.cgsecurity.org/testdisk-7.2.tar.bz2
  （sha256 `f8343be20cb4001c5d91a2e3bcd918398f00ae6d8310894a5a9f2feb813c283f`）
- 产物：`testdisk-7.2-arm64.tar.xz`, `testdisk-7.2-x86_64.tar.xz`
- 命令：testdisk、photorec、fidentify

## 怎么重建

```bash
bash testdisk/build.sh out
```

两个架构分别编、编完 ad-hoc 签名、源码 sha256 校验。产物尺寸与 sha256 见 [notes.md](./notes.md)。

验证（在 MacWave 仓库里）：

```bash
bash scripts/selfbuilt_check.sh out/testdisk-7.2-arm64.tar.xz --arch arm64 --bin-name testdisk
```
