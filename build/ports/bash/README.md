# bash

自建产物（单文件）。

- 上游：https://savannah.gnu.org/projects/bash/
- 源码：https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz
  （sha256 `0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba`）
- 产物：`bash-arm64`, `bash-x86_64`
- 命令：bash（tarball 里的 bashbug 不装 —— 单文件包只取一个可执行文件）

## 怎么重建

```bash
bash bash/build.sh out
```

两个架构分别编、编完 ad-hoc 签名、源码 sha256 校验。产物尺寸与 sha256 见 [notes.md](./notes.md)。

验证（在 MacWave 仓库里）：

```bash
bash scripts/selfbuilt_check.sh out/bash-arm64 --arch arm64 --bin-name bash
```
