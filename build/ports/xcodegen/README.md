# xcodegen

上游发布 macOS 产物，但那版**经软链启动会丢预设**，所以这里是自建（唯一区别是一个补丁）。

- 上游：https://github.com/yonaskolb/XcodeGen
- 源码：`git clone --branch 2.48.0`
- 产物：`xcodegen-2.48.0-arm64.tar.xz` / `xcodegen-2.48.0-x86_64.tar.xz`
  （整树：`bin/xcodegen` + `share/xcodegen/SettingPresets/`）

## 为什么不用官方 zip

xcodegen 找预设用的是 `Bundle.main.bundlePath`，而 macOS 的 `_NSGetExecutablePath()`
返回的是**软链的路径**。MacWave 把包装进 `bin/xcodegen@<版本>/`、再软链
`links/xcodegen` 过去，于是那句 `bundlePath + "../share/xcodegen/SettingPresets/…"`
落到 `links/../share` 上 —— 预设全部找不到，`xcodegen generate` 生成的工程**静默**
缺少 base/config/platform 的默认构建设置（实测少 125 行）：

```
$ links/xcodegen generate
No "base" settings found
No "debug config" settings found
No "release config" settings found
No "macOS" settings found
```

`presets-symlink.patch` 只是把 `bundlePath` 先 `resolvingSymlinksInPath()` 一次，
再加两个候选路径。其余原样。

## 这是一个「整树软件包」

`bin/xcodegen` 之外还要 `share/xcodegen/SettingPresets/`（base/config/platform/products
四类默认设置），所以索引记录写：

```
install: "tree"
min_os: "14.0"
min_client_version: "4.5.0"
```

`min_client_version` 是必须的：4.4 及更早的客户端不认识 `install`，会按单文件装，
只取 `bin/xcodegen`，于是又回到「找不到预设」的状态。上游客观要求：`Package.swift`
里 `platforms: [.macOS(.v14)]`，所以 min_os 就是 14.0，与官方 zip 一致。

## 怎么重建

```bash
bash xcodegen/build.sh out
```

依赖 Xcode（`swift` 命令）。产物尺寸与 sha256 见 [notes.md](./notes.md)。

验证（在 MacWave 仓库里）：

```bash
tar -xJf out/xcodegen-2.48.0-arm64.tar.xz -C /tmp/x
bash scripts/selfbuilt_check.sh /tmp/x/bin/xcodegen --arch arm64 --bin-name xcodegen
```
