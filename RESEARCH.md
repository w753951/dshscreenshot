# 越狱注入研究报告（XinaA15 / iOS 15.0 / iPhone14,3 arm64e）

## 一、已确认的硬事实

### 1. libhooker 对架构的强制要求
- SpringBoard 是 arm64e 进程。
- **thin arm64 的 tweak 不会被加载**（已用官方 DshProbe2 的 arm64 slice 单独验证：不加载）。
- fat(arm64 + arm64e) 会加载 —— libhooker 要求存在匹配 arm64e 的 slice。

### 2. plist 键名
- Xina 的注入配置键是 **`WBundles`**（不是 `Bundles`）。
- 用 `Bundles` 写的 plist 完全不生效，且不会报错。

```xml
<key>Filter</key>
<dict>
  <key>WBundles</key>
  <array><string>com.apple.springboard</string></array>
</dict>
```

### 3. 签名要求
- dylib 必须带 entitlements（空 entitlements 不加载）。
- 必须用设备证书签名：
  `ldid -S/var/jb/xina/entitlements_dylib.xml -I<名字>.dylib -M -K/var/jb/xina/signcert.p12 <file>`
- 可执行文件（CLI）要用另一套：
  `ldid -S/var/jb/xina/entitlements_xina.xml -M -K/var/jb/xina/signcert.p12 <file>`
  用错会被 SIGKILL（exit 137）。

### 4. 加载成功的最短证明
dylib 里放一个 constructor 写日志：

```c
__attribute__((constructor))
static void probe(void) {
    FILE *f = fopen("/var/mobile/dsh-min.log", "a");
    if (!f) return;
    fprintf(f, "uid=%d pid=%d\n", getuid(), getpid());
    fclose(f);
}
```

日志出现即证明注入成功。

## 二、卡住的地方：arm64e 代码生成

### 现象
| 方案 | 加载 | 稳定性 |
|---|---|---|
| thin arm64（lld） | 不加载 | - |
| thin arm64 + subtype 改 0x80000000 | 不加载 | - |
| thin arm64e（lld, DYLD_INFO） | 不加载 | - |
| thin arm64（lld, chained fixups）+ subtype 改 0x80000002 | **加载** | **加载后 SpringBoard 崩溃** |
| fat(arm64+arm64e) 各 slice 单独签名 | 不加载 | - |

### 根因推断
lld 无法为 arm64e 生成正确的重定位：
```
ld64.lld: error: INVALID relocation has width 8 bytes, but must be 0 bytes
          at offset N of __DATA,__cfstring
ld64.lld: error: -fixup_chains is only supported on x86_64 and arm64 targets
```
- arm64e 的 authenticated pointer 重定位 lld 不支持。
- `-fixup_chains` 不支持 arm64e。
- 把 arm64 二进制标成 arm64e 可以骗过加载，但 dyld 按 arm64e 规则解析 chained fixups，导致内存损坏 → SIGABRT。

### 结论
**必须用 Apple 的 ld64 链接 arm64e**，lld 不行。

### 已排除的获取途径
- GitHub macOS runner：本仓库所有 macOS job 均被瞬间 cancelled（`runner=-`），账号无 macOS 额度。
- cctools-port 源码编译：卡在 `Required library libdispatch not installed`，Ubuntu 无该包。
- conda-forge `ld64_osx-64`：在 linux-64 环境里只装了 man page，bin 目录无二进制。

### 可行路径（未验证）
1. 在真正的 Mac 上编译（Xcode 自带 Apple ld64）。
2. 给 GitHub 账号开通 macOS runner 额度后重试。
3. 自行在 Ubuntu 编译 swift-corelibs-libdispatch，再编译 cctools-port。

## 三、当前可用的读屏方案（不依赖注入）

`dsh-shot-watch` 守护进程（LaunchDaemon `com.dshgo.shotwatch`）：

```
用户截图 → /var/mobile/Media/DCIM/125APPLE/IMG_xxxx.PNG
        → 守护 2 秒内复制到 App Group
        → /var/mobile/Containers/Shared/AppGroup/27EB168F-.../dsh-shot.png
        → DSH Go 读图
```

注意点（原脚本的问题，已修）：
- 原脚本写死 `124APPLE`，实际是 `125APPLE`。
- 本机 `stat -f '%m'` 不支持，改用 `ls -t` 排序。
- LaunchDaemon 里必须自己 `export PATH`，否则 `head`/`date`/`sleep` 找不到。
- 进程用 `launchctl list | grep shotwatch` 查，`ps` 的 comm 字段会被截断。

## 四、已安装的工具

| 工具 | 路径 | 状态 |
|---|---|---|
| dshtool（点按/前台/按键） | /var/jb/usr/bin/dshtool | 可用，需 xina 证书重签 |
| dshss（CARenderServer 抓屏） | /var/jb/usr/bin/dshss | 可运行但输出全白（root 无 WindowServer 会话） |
| dsh-shot-watch | /var/jb/usr/bin/dsh-shot-watch | 运行中 |
