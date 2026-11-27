# dtc

自建产物（整树（install: "tree"））。

- 上游：https://git.kernel.org/pub/scm/utils/dtc/dtc.git
- 源码：https://www.kernel.org/pub/software/utils/dtc/dtc-1.7.2.tar.xz
  （sha256 `92d8ca769805ae1f176204230438fe52808f4e1c7944053c9eec0e649b237539`）
- 产物：`dtc-1.7.2-arm64.tar.xz`, `dtc-1.7.2-x86_64.tar.xz`
- 命令：dtc、fdtget、fdtput、fdtdump、fdtoverlay、convert-dtsv0、dtdiff

## 怎么重建

```bash
bash dtc/build.sh out
```

两个架构分别编、编完 ad-hoc 签名、源码 sha256 校验。产物尺寸与 sha256 见 [notes.md](./notes.md)。

验证（在 MacWave 仓库里）：

```bash
bash scripts/selfbuilt_check.sh out/dtc-1.7.2-arm64.tar.xz --arch arm64 --bin-name dtc
```
