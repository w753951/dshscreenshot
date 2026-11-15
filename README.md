# DshScreenshotService (fixed)

给 DSH Go 提供整屏截图能力的 SpringBoard tweak。修复了原版在 iOS 15 上必崩的问题。

## 崩溃根因

原版 dylib 直接硬链接了两个私有符号：

```
_UICreateScreenUIImage
UIGetScreenImage
```

这两个符号在 **iOS 15 的 UIKit 中已被移除**（二进制里 grep 计数为 0）。dyld 绑定时拿到 NULL 指针，`__auth_stubs` 跳转过去立即触发：

```
EXC_BAD_ACCESS / SIGSEGV
KERN_INVALID_ADDRESS -> possible pointer authentication failure
```

所以原版不是签名问题，是符号解析问题。补签名只能让它真的被注入（从而真的崩），不补签名则被 amfid 拦截（从不注入、但也从不工作）。

## 修复方式

全部私有符号改为运行时 `dlsym` 探测，四级回退，任何一级缺失都不崩：

| 优先级 | 路径 | 适用 |
|---|---|---|
| 1 | `_UICreateScreenUIImage` | iOS 14 及更早 |
| 2 | `UIGetScreenImage` | 旧私有 API |
| 3 | `CARenderServerRenderDisplay` + IOSurface | **iOS 15 主路径** |
| 4 | `UIScreen snapshotView` | 最后兜底 |

注入 SpringBoard 后天然具备 `com.apple.QuartzCore.global-capture` 等 entitlement，`CARenderServerRenderDisplay` 可以正常工作 —— 这是从外部 root 进程（`dshtool`)做不到的，那正是 `ERR IOSurfaceCreate` 的原因。

## 接口

与 DSH Go App 端完全兼容，无需改 App：

```
GET http://127.0.0.1:47191/capture?key=dsh-go-screen-v1
```

| 情况 | 响应 |
|---|---|
| 成功 | `200 image/png` |
| key 错误 | `403 Forbidden` |
| 路径不对 | `400 Bad Request` |
| 截图失败 | `503 nocapture` |

日志：`/var/mobile/dsh-screen-plugin.log`

## 编译

GitHub Actions 自动构建（`.github/workflows/build.yml`）：产出 arm64 + arm64e fat dylib 并签名。

本地编译：

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
for ARCH in arm64 arm64e; do
  xcrun --sdk iphoneos clang -arch $ARCH -isysroot "$SDK" \
    -miphoneos-version-min=14.0 -dynamiclib -fobjc-arc -O2 \
    -framework Foundation -framework UIKit -framework CoreGraphics \
    -framework IOSurface -framework ImageIO -framework QuartzCore \
    -install_name /Library/MobileSubstrate/DynamicLibraries/DshScreenshotService.dylib \
    -o out/DshScreenshotService.$ARCH.dylib src/DshScreenshotService.m
done
lipo -create out/*.arm64.dylib out/*.arm64e.dylib -output out/DshScreenshotService.dylib
ldid -Ssrc/entitlements.plist out/DshScreenshotService.dylib
```

## 安装

```bash
# 1. 放 dylib 和 plist
cp DshScreenshotService.dylib /var/jb/Library/MobileSubstrate/DynamicLibraries/
cp DshScreenshotService.plist   /var/jb/Library/MobileSubstrate/DynamicLibraries/

# 2. 用设备自己的 Xina 证书重签（关键，GitHub 的签名手机不认）
ldid -S/var/jb/xina/entitlements_dylib.xml -M -K/var/jb/xina/signcert.p12 \
  /var/jb/Library/MobileSubstrate/DynamicLibraries/DshScreenshotService.dylib

# 3. 重载
killall -9 SpringBoard

# 4. 验证
cat /var/mobile/dsh-screen-plugin.log
curl "http://127.0.0.1:47191/capture?key=dsh-go-screen-v1" -o /tmp/shot.png
```

**务必用设备上的 `signcert.p12` 重签**。GitHub Actions 里签的 adhoc 签名，Xina 的 amfid（`TeamIdentifier=HACKERXINA`）不认，会被 SIGKILL。

## 安全提示

- 只监听 `127.0.0.1`，不对外网开放
- 需要正确 key 才返回图像
- 不做点按、不联网、不读其他数据
