// dshss —— 通过 IOMobileFramebuffer / CARenderServer 直接抓屏
// 不依赖 SpringBoard 内部类，root 权限即可
//
// 用法: dshss <out.png>

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
#import <IOSurface/IOSurface.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

typedef int (*CARenderServerRenderDisplayFn)(uint32_t, CFStringRef, IOSurfaceRef);

static UIImage *captureRenderServer(void) {
    void *h = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    fprintf(stderr, "QuartzCore=%p\n", h);
    if (!h) return nil;

    CARenderServerRenderDisplayFn fn = (CARenderServerRenderDisplayFn)dlsym(h, "CARenderServerRenderDisplay");
    fprintf(stderr, "CARenderServerRenderDisplay=%p\n", (void *)fn);
    if (!fn) return nil;

    // 枚举所有可用 display（0 通常无效，从 1 开始）
    for (uint32_t disp = 1; disp <= 4; disp++) {
        for (int w = 1284, k = 0; k < 1; k++) {
            size_t W = (size_t)w, H = (size_t)2778;
            NSDictionary *props = @{
                @"IOSurfaceWidth":  @(W),
                @"IOSurfaceHeight": @(H),
                @"IOSurfaceBytesPerElement": @(4),
                @"IOSurfacePixelFormat": @((uint32_t)0x42475241),
            };
            IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
            if (!s) { fprintf(stderr, "surface fail\n"); return nil; }

            int rc = fn(disp, CFSTR("LCD"), s);
            fprintf(stderr, "display=%u rc=%d\n", disp, rc);
            if (rc == 0) {
                CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                CGContextRef c = CGBitmapContextCreate(
                    IOSurfaceGetBaseAddress(s), W, H, 8,
                    IOSurfaceGetBytesPerRow(s), cs,
                    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
                CGColorSpaceRelease(cs);
                UIImage *img = nil;
                if (c) {
                    CGImageRef cg = CGBitmapContextCreateImage(c);
                    if (cg) { img = [UIImage imageWithCGImage:cg scale:3.0 orientation:UIImageOrientationUp]; CGImageRelease(cg); }
                    CGContextRelease(c);
                }
                CFRelease(s);
                if (img) return img;
            }
            CFRelease(s);
        }
    }
    return nil;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *out = (argc > 1) ? argv[1] : "/var/mobile/dsh-cap.png";
        fprintf(stderr, "uid=%d\n", getuid());

        UIImage *img = captureRenderServer();
        if (!img) { fprintf(stderr, "capture failed\n"); return 1; }

        NSData *png = UIImagePNGRepresentation(img);
        fprintf(stderr, "png=%lu bytes size=%.0fx%.0f\n",
                (unsigned long)png.length, img.size.width, img.size.height);
        if (![png writeToFile:[NSString stringWithUTF8String:out] atomically:YES]) {
            fprintf(stderr, "write failed\n");
            return 2;
        }
        printf("OK %s\n", out);
        return 0;
    }
}
