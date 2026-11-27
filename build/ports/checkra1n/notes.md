# checkra1n 实测记录

2026-11-24 首次打包（macOS 15 / Xcode 17，本机 arm64 + Rosetta 2 跑 x86_64）。

## 产物

| 版本 | 归档 | 大小 | sha256（索引里写这个） |
| --- | --- | --- | --- |
| `0.12.4` | `checkra1n-0.12.4.tar.xz` | 6,407,720 B | `f95498e03715e0557ad65f4aad8846691d9ae4513d874a02092fb5f3bba9708e` |
| `0.12.3` | `checkra1n-0.12.3.tar.xz` | 6,404,588 B | `d2f6d3be490d87a3fe313f168c11ced4d4357cbbcd3bc442ff8551edbaae18f9` |

上游 dmg 的 sha256（就是 assets.checkra.in URL 里那一段，可当直链校验）：

```
754bb6ec4747b2e700f01307315da8c9c32c8b5816d0fe1e91d1bdfc298fe07b  checkra1n beta 0.12.4.dmg
08be5f1b146447a36ae40446d60304451bce9524ba5a3922ebfee4f37b88d15c  checkra1n beta 0.12.3.dmg
```

两个架构共用同一份产物（x86_64），所以 `pkginfo_arm64` 与 `pkginfo_amd64` 的
`sha256` 相同。

## 引用面

```
/System/Library/Frameworks/{AppKit,CoreFoundation,Foundation,IOKit}
/System/Library/PrivateFrameworks/MobileDevice.framework    ← macOS 自带
@loader_path/../lib/libfatman.dylib                        ← 包里那份
/usr/lib/{libncurses.5.4,libpanel.5.4,libmenu.5.4,libc++,libSystem}
```

`--check` 通过：除系统库外没有绝对路径。`libncurses/panel/menu 5.4` 属于
「Apple 自带的第三方库」那一类，与 `gbash` 一样记在这里备查。

## 踩过的坑

1. **dmg 里的文件带扩展属性**。直接 `codesign` 报
   `resource fork, Finder information, or similar detritus not allowed`，
   必须先 `xattr -cr`。
2. **上游没签名**。`codesign -dv` 是 "code object is not signed at all"，
   不重签在 Apple 芯片上跑不起来。
3. **`libfatman.dylib` 必须跟着走**。上游是 `@loader_path/libfatman.dylib`
   （与可执行文件同目录），我们把它放进 `lib/` 后要同步
   `install_name_tool -change … @loader_path/../lib/libfatman.dylib`，
   否则 dyld 报找不到。
4. **`--version` 也会打整段 banner**，判定版本要看输出的第二行
   `# Checkra1n beta 0.12.x`，不要只看退出码。

## 验证过的命令

```
$ bin/checkra1n --version | sed -n 2p
# Checkra1n beta 0.12.4
$ bin/checkra1n --help | grep -E '\-\-cli|\-\-tui|\-\-pongo|\-\-wui'
  -c, --cli     … -t, --tui …  -p, --pongo …  -w, --wui <IPV4> <PORT> …
$ codesign --verify --verbose=2 bin/checkra1n
bin/checkra1n: valid on disk
bin/checkra1n: satisfies its Designated Requirement
```

真机刷机未验证（需要 iPad/iPhone 与 USB 连接，且以 root 运行）。
