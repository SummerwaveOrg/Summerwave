# checkra1n —— 从上游 dmg 里取出 CLI

上游只发 `.dmg`（里面是 `checkra1n.app`），官方安装方式是让用户把 app 拖进
`/Applications`。而它的二进制本身就是个完整 CLI：

```
$ checkra1n --help
  -c, --cli        Force command line
  -t, --tui        Start a terminal graphical user interface
  -p, --pongo      Boots to a Pongo shell
  -w, --wui <IPV4> <PORT>   Start webra1n
```

所以这个包做的是「取出 + 摆位置 + 重签」，不重新编译：

```
bin/checkra1n              ← 上游 checkra1n.app/Contents/MacOS/checkra1n
lib/libfatman.dylib        ← 同目录那个 dylib，引用改成 @loader_path/../lib/
```

## 为什么需要重打包

不只是「省一次拖拽」：上游产物**完全没签名**（`codesign -dv` 报
"code object is not signed at all"），在 Apple 芯片上跑不起来；重打时统一做了
ad-hoc 签名。另外 app 里的二进制和 `libfatman.dylib` 必须保持相对位置，散装下载
容易只拿走一半。

## 版本

| 版本 | 说明 |
| --- | --- |
| `0.12.4` | 当前主流版本（默认） |
| `0.12.3` | 留作退路，对部分机型的 pongo 行为与 0.12.4 不同 |

上游所有版本都还是 beta，版本号里不写 beta。新增版本要在 `build.sh` 顶部那张
「版本 → dmg sha256」表里加一行。

## 三个限制（不是缺陷）

1. **只有 x86_64**。上游 0.12.4 仍只发 Intel 版，Apple 芯片靠 Rosetta 2 跑。
   索引因此两个架构共用同一份产物。
2. **需要 root**：`sudo checkra1n -c`。它走 USB 与设备通信、改 rootfs，
   普通用户跑只会报权限错误。
3. **依赖私有框架** `MobileDevice.framework`（路径在 `/System/Library/PrivateFrameworks`），
   这是 macOS 自带的，不是我们要打包的东西。

## 法律

产物**不开源**，dmg 里也没有 LICENSE 文件，站点未声明可否再分发。这里把它放进
Bottle 是「与我们其它自建包一样由镜像提供」的处理方式，是否合适需要项目自己判断；
真要规避，只能让客户端在安装时回上游取（4.0 起客户端只从 Bottle 下载，那意味着
要单独开一条口子）。
