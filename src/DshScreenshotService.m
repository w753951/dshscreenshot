// DshScreenshotService.m
// 注入 com.apple.springboard，在 127.0.0.1:47191 提供 GET /capture?key=... 截图接口
// 协议与 DSH Go App 端完全兼容：http://127.0.0.1:47191/capture?key=dsh-go-screen-v1
//
// 与旧版的关键差异（修复崩溃）：
//   旧版硬链接 _UICreateScreenUIImage / UIGetScreenImage，这两个私有符号在 iOS 15
//   已从 UIKit 移除，dyld 绑定得到 NULL，调用即 EXC_BAD_ACCESS / PAC 失败。
//   新版全部改为运行时 dlsym 探测 + 多级回退，任何一级缺失都不崩。
//
// 截图优先级：
//   1. _UICreateScreenUIImage        （存在则用，iOS 14 及更早）
//   2. UIGetScreenImage              （存在则用，旧私有 API）
//   3. CARenderServerRenderDisplay   （iOS 15 主路径，走 IOSurface + CARenderer）
//   4. UIScreen snapshotView         （最后兜底）
//
// 所有 UIKit 调用统一切到主线程执行。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdarg.h>
#import <math.h>

#import <CoreGraphics/CoreGraphics.h>

static const int      kDshPort     = 47191;
static NSString *const kDshLogPath = @"/var/mobile/dsh-screen-plugin.log";
static NSString *const kDshKey     = @"dsh-go-screen-v1";


// ---- IOSurface 私有 API 自声明（theos SDK 不含该头文件）----
typedef struct __IOSurface *IOSurfaceRef;
typedef CFStringRef IOSurfacePropertyKey;

extern IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
extern void        *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
extern size_t       IOSurfaceGetBytesPerRow(IOSurfaceRef buffer);

// 属性键的实际字符串值，用 CFSTR 直接构造，不依赖头文件里的 extern 常量
static CFStringRef DshKeyWidth(void)      { return CFSTR("IOSurfaceWidth"); }
static CFStringRef DshKeyHeight(void)     { return CFSTR("IOSurfaceHeight"); }
static CFStringRef DshKeyBytesPerElem(void){ return CFSTR("IOSurfaceBytesPerElement"); }
static CFStringRef DshKeyPixelFormat(void){ return CFSTR("IOSurfacePixelFormat"); }

#pragma mark - 日志

static void DshLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];

    NSString *old = [NSString stringWithContentsOfFile:kDshLogPath
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
    if (old.length > 200000) old = [old substringFromIndex:old.length - 100000];

    NSString *merged = [(old ?: @"") stringByAppendingString:line];
    [merged writeToFile:kDshLogPath atomically:YES
               encoding:NSUTF8StringEncoding error:NULL];
}

#pragma mark - 截图实现（全部必须主线程）

// 方案 1/2：私有符号，dlsym 探测
static UIImage *DshLegacyScreenImage(void) {
    typedef UIImage *(*NoArgImageFn)(void);
    static NoArgImageFn createFn = NULL;
    static NoArgImageFn getFn    = NULL;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        createFn = (NoArgImageFn)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
        getFn    = (NoArgImageFn)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
        DshLog(@"[legacy] _UICreateScreenUIImage=%p UIGetScreenImage=%p",
               (void *)createFn, (void *)getFn);
    });

    if (createFn) {
        UIImage *img = createFn();
        if (img) return img;
    }
    if (getFn) {
        UIImage *img = getFn();
        if (img) return img;
    }
    return nil;
}

// 方案 3：CARenderServerRenderDisplay —— iOS 15 主路径
typedef int (*CARenderServerRenderDisplayFn)(uint32_t ctx, CFStringRef name, IOSurfaceRef surface);

static UIImage *DshRenderServerImage(void) {
    static CARenderServerRenderDisplayFn renderFn = NULL;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
                         RTLD_LAZY);
        if (h) {
            renderFn = (CARenderServerRenderDisplayFn)
                dlsym(h, "CARenderServerRenderDisplay");
        }
        DshLog(@"[renderserver] handle=%p fn=%p", h, (void *)renderFn);
    });

    if (!renderFn) return nil;

    CGSize pts = CGSizeZero;
    CGFloat scale = 1.0;
    Class UIScreenCls = NSClassFromString(@"UIScreen");
    if (UIScreenCls) {
        id screen = ((id (*)(id, SEL))objc_msgSend)(UIScreenCls, @selector(mainScreen));
        if (screen) {
            CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(screen, @selector(bounds));
            pts   = b.size;
            scale = ((CGFloat (*)(id, SEL))objc_msgSend)(screen, @selector(scale));
        }
    }
    if (pts.width <= 0 || pts.height <= 0) { pts = CGSizeMake(428, 926); scale = 3.0; }

    size_t w = (size_t)llround(pts.width  * scale);
    size_t h = (size_t)llround(pts.height * scale);

    NSDictionary *props = @{
        (__bridge NSString *)DshKeyWidth():        @(w),
        (__bridge NSString *)DshKeyHeight():       @(h),
        (__bridge NSString *)DshKeyBytesPerElem(): @(4),
        (__bridge NSString *)DshKeyPixelFormat():  @((uint32_t)0x42475241),  // 'BGRA'
    };

    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!surf) {
        DshLog(@"[renderserver] IOSurfaceCreate failed w=%zu h=%zu", w, h);
        return nil;
    }

    int rc = renderFn(0, CFSTR("LCD"), surf);
    if (rc != 0) {
        DshLog(@"[renderserver] render rc=%d", rc);
        CFRelease(surf);
        return nil;
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        IOSurfaceGetBaseAddress(surf), w, h, 8,
        IOSurfaceGetBytesPerRow(surf), cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);

    UIImage *out = nil;
    if (ctx) {
        CGImageRef cg = CGBitmapContextCreateImage(ctx);
        if (cg) {
            out = [UIImage imageWithCGImage:cg scale:scale orientation:UIImageOrientationUp];
            CGImageRelease(cg);
        }
        CGContextRelease(ctx);
    }
    CFRelease(surf);
    DshLog(@"[renderserver] ok w=%zu h=%zu image=%p", w, h, (void *)out);
    return out;
}

// 方案 4：UIScreen snapshotView 兜底
static UIImage *DshSnapshotImage(void) {
    Class UIScreenCls = NSClassFromString(@"UIScreen");
    if (!UIScreenCls) return nil;
    id screen = ((id (*)(id, SEL))objc_msgSend)(UIScreenCls, @selector(mainScreen));
    if (!screen) return nil;

    UIView *view = ((id (*)(id, SEL))objc_msgSend)(screen,
                                                   @selector(snapshotViewAfterScreenUpdates:),
                                                   (BOOL)YES);
    if (!view) return nil;

    UIGraphicsBeginImageContextWithOptions(view.bounds.size, NO, 0);
    [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:YES];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    DshLog(@"[snapshot] image=%p", (void *)img);
    return img;
}

static UIImage *DshCaptureOnMain(void) {
    UIImage *img = DshLegacyScreenImage();
    if (img) { DshLog(@"[capture] via legacy"); return img; }

    img = DshRenderServerImage();
    if (img) { DshLog(@"[capture] via renderserver"); return img; }

    img = DshSnapshotImage();
    if (img) { DshLog(@"[capture] via snapshot"); return img; }

    DshLog(@"[capture] all strategies failed");
    return nil;
}

// 统一调度到主线程
static UIImage *DshCapture(void) {
    if ([NSThread isMainThread]) return DshCaptureOnMain();

    __block UIImage *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        result = DshCaptureOnMain();
    });
    return result;
}

#pragma mark - HTTP

static void DshWriteAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = send(fd, p, len, 0);
        if (n <= 0) return;
        p   += n;
        len -= (size_t)n;
    }
}

static NSData *DshBuildHeader(int code, NSString *reason, NSString *ctype, NSUInteger clen) {
    NSString *h = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
         "Content-Type: %@\r\n"
         "Content-Length: %lu\r\n"
         "Cache-Control: no-store\r\n"
         "Connection: close\r\n"
         "\r\n",
        code, reason, ctype, (unsigned long)clen];
    return [h dataUsingEncoding:NSUTF8StringEncoding];
}

static void DshReplyPlain(int fd, int code, NSString *reason, NSString *body) {
    NSData *b = [body dataUsingEncoding:NSUTF8StringEncoding];
    NSData *h = DshBuildHeader(code, reason, @"text/plain", b.length);
    DshWriteAll(fd, h.bytes, h.length);
    DshWriteAll(fd, b.bytes, b.length);
}

static void DshHandleClient(int fd) {
    @autoreleasepool {
        char buf[2048] = {0};
        ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
        if (n <= 0) { close(fd); return; }
        buf[n] = 0;

        NSString *req = [NSString stringWithUTF8String:buf] ?: @"";

        if (![req hasPrefix:@"GET /capture"]) {
            DshReplyPlain(fd, 400, @"Bad Request", @"Unavailable");
            close(fd);
            return;
        }
        if ([req rangeOfString:kDshKey].location == NSNotFound) {
            DshReplyPlain(fd, 403, @"Forbidden", @"denied");
            close(fd);
            return;
        }

        UIImage *img = DshCapture();
        NSData *png = img ? UIImagePNGRepresentation(img) : nil;
        if (!png) {
            DshReplyPlain(fd, 503, @"Service Unavailable", @"nocapture");
            close(fd);
            return;
        }

        NSData *h = DshBuildHeader(200, @"OK", @"image/png", png.length);
        DshWriteAll(fd, h.bytes, h.length);
        DshWriteAll(fd, png.bytes, png.length);
        DshLog(@"[http] 200 image/png %lu bytes", (unsigned long)png.length);
        close(fd);
    }
}

#pragma mark - 服务主体

@interface DshScreenshotService : NSObject
@property (nonatomic, assign) int listenFD;
@property (nonatomic, strong) id queue;
+ (instancetype)shared;
- (void)startWithLog:(NSString *)path;
@end

@implementation DshScreenshotService

+ (instancetype)shared {
    static DshScreenshotService *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[DshScreenshotService alloc] init]; });
    return s;
}

- (void)startWithLog:(NSString *)path {
    DshLog(@"constructor entered uid=%d pid=%d", getuid(), getpid());

    dispatch_queue_t q = dispatch_queue_create("dsh.screen.service", DISPATCH_QUEUE_SERIAL);
    self.queue = q;

    dispatch_async(q, ^{
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) { DshLog(@"socket failed errno=%d", errno); return; }

        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family      = AF_INET;
        addr.sin_port        = htons(kDshPort);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            DshLog(@"bind failed errno=%d port=%d", errno, kDshPort);
            close(fd);
            return;
        }
        if (listen(fd, 8) != 0) {
            DshLog(@"listen failed errno=%d", errno);
            close(fd);
            return;
        }
        self.listenFD = fd;
        DshLog(@"listening on 127.0.0.1:%d", kDshPort);

        while (1) {
            int c = accept(fd, NULL, NULL);
            if (c < 0) {
                if (errno == EINTR) continue;
                DshLog(@"accept failed errno=%d", errno);
                break;
            }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                DshHandleClient(c);
            });
        }
    });
}

@end

#pragma mark - 注入入口

__attribute__((constructor))
static void DshScreenshotServiceInit(void) {
    @autoreleasepool {
        [[DshScreenshotService shared] startWithLog:kDshLogPath];
    }
}
