# patch

自建产物（单文件）。

- 上游：https://savannah.gnu.org/projects/patch/
- 源码：https://ftp.gnu.org/gnu/patch/patch-2.8.1.tar.xz
  （sha256 `3240c7959c5347c8ed347e3c4201c0337bf4240d5cf09d68889e58eeaba30e17`）
- 产物：`patch-arm64`, `patch-x86_64`
- 命令：patch

## 怎么重建

```bash
bash patch/build.sh out
```

两个架构分别编、编完 ad-hoc 签名、源码 sha256 校验。产物尺寸与 sha256 见 [notes.md](./notes.md)。

验证（在 MacWave 仓库里）：

```bash
bash scripts/selfbuilt_check.sh out/patch-arm64 --arch arm64 --bin-name patch
```
