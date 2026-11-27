# tar

自建产物（单文件）。

- 上游：https://www.gnu.org/software/tar/
- 源码：https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz
  （sha256 `4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16`）
- 产物：`tar-arm64`, `tar-x86_64`
- 命令：tar

## 怎么重建

```bash
bash tar/build.sh out
```

两个架构分别编、编完 ad-hoc 签名、源码 sha256 校验。产物尺寸与 sha256 见 [notes.md](./notes.md)。

验证（在 MacWave 仓库里）：

```bash
bash scripts/selfbuilt_check.sh out/tar-arm64 --arch arm64 --bin-name tar
```
