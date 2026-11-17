// svc.m —— SpringBoard 截图服务（真 arm64e）
// GET http://127.0.0.1:47191/capture?key=dsh-go-screen-v1 -> image/png
//
// 设计要点：
//  1) constructor 只写日志 + 起线程，全部重活放线程里（并延时 8s 等 SpringBoard 启动完成）
//  2) 私有 API 全部 dlsym 运行时解析，任一缺失都不崩
//  3) 截图走 CARenderServerRenderDisplay；IOSurface 必须带 IOSurfaceIsGlobal 才能被渲染
//  4) PNG 编码走 ImageIO 的 CGImageDestination（纯 CF API，不用 ObjC）

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

typedef const void *CFRef;
typedef struct __IOSurface *IOSurfaceRef;
typedef struct CGContext *CGContextRef;
typedef struct CGImage *CGImageRef;
typedef struct CGColorSpace *CGColorSpaceRef;
typedef struct __CFDictionary *CFDictRef;
typedef struct __CFData *CFDataRef;
typedef struct __CFString *CFStringRef;

static const int  kPort = 47191;
static const char *kKey = "dsh-go-screen-v1";
static const char *kLog = "/var/mobile/dsh-screen-plugin.log";

static void lg(const char *fmt, ...) {
    FILE *f = fopen(kLog, "a");
    if (!f) return;
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fclose(f);
}

/* ---------- 符号 ---------- */
static int (*f_render)(unsigned, CFStringRef, IOSurfaceRef);
static IOSurfaceRef (*f_surfCreate)(CFDictRef);
static void *(*f_surfBase)(IOSurfaceRef);
static size_t (*f_surfBPR)(IOSurfaceRef);
static size_t (*f_surfW)(IOSurfaceRef);
static size_t (*f_surfH)(IOSurfaceRef);

static CGColorSpaceRef (*f_csRGB)(void);
static void (*f_csRelease)(CGColorSpaceRef);
static CGContextRef (*f_bmpCtx)(void*, size_t, size_t, size_t, size_t, CGColorSpaceRef, unsigned);
static CGImageRef (*f_ctxImage)(CGContextRef);
static void (*f_ctxRelease)(CGContextRef);
static void (*f_imgRelease)(CGImageRef);

static CFDataRef (*f_dataNew)(const void*, long);
static const void *(*f_dataBytes)(CFDataRef);
static long (*f_dataLen)(CFDataRef);
static void (*f_cfRelease)(const void*);
static CFStringRef (*f_str)(const void*, const char*, unsigned);
static CFRef (*f_num)(const void*, long, const void*);
static CFDictRef (*f_dict)(const void*, const void**, const void**, long, const void*, const void*);
static const void *kCb;

static void *(*f_destNew)(CFDataRef, CFStringRef, unsigned long, const void*);
static void (*f_destAdd)(void*, CGImageRef, const void*);
static int (*f_destFinal)(void*);

static int g_ready = 0;

static void load_syms(void) {
    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    void *is = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
    void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    void *cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
    void *io = dlopen("/System/Library/Frameworks/ImageIO.framework/ImageIO", RTLD_LAZY);
    lg("[sym] qc=%p is=%p cg=%p cf=%p io=%p", qc, is, cg, cf, io);

    if (qc) f_render = dlsym(qc, "CARenderServerRenderDisplay");
    if (is) {
        f_surfCreate = dlsym(is, "IOSurfaceCreate");
        f_surfBase   = dlsym(is, "IOSurfaceGetBaseAddress");
        f_surfBPR    = dlsym(is, "IOSurfaceGetBytesPerRow");
        f_surfW      = dlsym(is, "IOSurfaceGetWidth");
        f_surfH      = dlsym(is, "IOSurfaceGetHeight");
    }
    if (cg) {
        f_csRGB      = dlsym(cg, "CGColorSpaceCreateDeviceRGB");
        f_csRelease  = dlsym(cg, "CGColorSpaceRelease");
        f_bmpCtx     = dlsym(cg, "CGBitmapContextCreate");
        f_ctxImage   = dlsym(cg, "CGBitmapContextCreateImage");
        f_ctxRelease = dlsym(cg, "CGContextRelease");
        f_imgRelease = dlsym(cg, "CGImageRelease");
    }
    if (cf) {
        f_dataNew   = dlsym(cf, "CFDataCreateMutable");
        f_dataBytes = dlsym(cf, "CFDataGetBytePtr");
        f_dataLen   = dlsym(cf, "CFDataGetLength");
        f_cfRelease = dlsym(cf, "CFRelease");
        f_str       = dlsym(cf, "CFStringCreateWithCString");
        f_num       = dlsym(cf, "CFNumberCreate");
        f_dict      = dlsym(cf, "CFDictionaryCreate");
        kCb         = (const void *)dlsym(cf, "kCFTypeDictionaryKeyCallBacks");
    }
    if (io) {
        f_destNew   = dlsym(io, "CGImageDestinationCreateWithData");
        f_destAdd   = dlsym(io, "CGImageDestinationAddImage");
        f_destFinal = dlsym(io, "CGImageDestinationFinalize");
    }
    g_ready = f_render && f_surfCreate && f_surfBase && f_surfBPR &&
              f_csRGB && f_bmpCtx && f_ctxImage && f_dataNew &&
              f_dataBytes && f_dataLen && f_str && f_num && f_dict && kCb &&
              f_destNew && f_destAdd && f_destFinal;
    lg("[sym] ready=%d render=%p surfCreate=%p destNew=%p",
       g_ready, (void*)f_render, (void*)f_surfCreate, (void*)f_destNew);
}

static void screen_size(size_t *w, size_t *h) {
    *w = 1284; *h = 2778;
    FILE *f = fopen("/var/mobile/dsh-screen-size.txt", "r");
    if (f) { unsigned long a=0,b=0; if (fscanf(f,"%lu %lu",&a,&b)==2 && a&&b){*w=a;*h=b;} fclose(f); }
}

/* 返回 PNG（malloc，调用方 free），失败 NULL */
static unsigned char *capture_png(size_t *outLen) {
    *outLen = 0;
    if (!g_ready) { lg("[cap] not ready"); return NULL; }

    size_t W, H; screen_size(&W, &H);

    CFStringRef kW  = f_str(NULL, "IOSurfaceWidth", 0x08000100);
    CFStringRef kH  = f_str(NULL, "IOSurfaceHeight", 0x08000100);
    CFStringRef kB  = f_str(NULL, "IOSurfaceBytesPerElement", 0x08000100);
    CFStringRef kF  = f_str(NULL, "IOSurfacePixelFormat", 0x08000100);
    CFStringRef kR  = f_str(NULL, "IOSurfaceBytesPerRow", 0x08000100);
    CFStringRef kG  = f_str(NULL, "IOSurfaceIsGlobal", 0x08000100);
    if (!kW || !kH || !kB || !kF || !kR || !kG) { lg("[cap] key str fail"); return NULL; }

    int32_t vw=(int32_t)W, vh=(int32_t)H, vb=4, vr=(int32_t)(W*4), vg=1;
    uint32_t vf=0x42475241;
    CFRef nw=f_num(NULL,3,&vw), nh=f_num(NULL,3,&vh), nb=f_num(NULL,3,&vb);
    CFRef nf=f_num(NULL,3,&vf), nr=f_num(NULL,3,&vr), ng=f_num(NULL,3,&vg);

    const void *keys[6] = { kW, kH, kB, kF, kR, kG };
    const void *vals[6] = { nw, nh, nb, nf, nr, ng };
    CFDictRef props = f_dict(NULL, keys, vals, 6, kCb, kCb);
    if (!props) { lg("[cap] dict fail"); return NULL; }

    IOSurfaceRef surf = f_surfCreate(props);
    if (!surf) { lg("[cap] IOSurfaceCreate FAIL %zux%zu", W, H); return NULL; }

    size_t bw = f_surfW ? f_surfW(surf) : W;
    size_t bh = f_surfH ? f_surfH(surf) : H;
    size_t bpr = f_surfBPR(surf);
    void *base = f_surfBase(surf);
    lg("[cap] surf w=%zu h=%zu bpr=%zu base=%p", bw, bh, bpr, base);

    CFStringRef lcd = f_str(NULL, "LCD", 0x08000100);
    unsigned ctxTry[2] = { 0u, 1u };
    size_t nz = 0;
    for (int i = 0; i < 2; i++) {
        f_render(ctxTry[i], lcd, surf);
        usleep(120000);
        nz = 0;
        const unsigned char *p = (const unsigned char *)base;
        size_t tot = bpr * bh;
        if (p) for (size_t k = 0; k < tot; k += 53) if (p[k]) nz++;
        lg("[cap] ctx=%u sampled-nonzero=%zu", ctxTry[i], nz);
        if (nz > 50) break;
    }

    if (nz <= 50) { lg("[cap] still blank"); f_cfRelease(surf); return NULL; }

    CGColorSpaceRef cs = f_csRGB();
    CGContextRef c = f_bmpCtx(base, bw, bh, 8, bpr, cs,
        1 | (2 << 12));
    f_csRelease(cs);
    if (!c) { lg("[cap] ctx fail"); f_cfRelease(surf); return NULL; }

    CGImageRef ci = f_ctxImage(c);
    f_ctxRelease(c);
    if (!ci) { lg("[cap] image fail"); f_cfRelease(surf); return NULL; }

    CFDataRef data = f_dataNew(NULL, 0);
    CFStringRef pngType = f_str(NULL, "public.png", 0x08000100);
    void *dest = f_destNew(data, pngType, 1, NULL);
    unsigned char *out = NULL;
    if (dest) {
        f_destAdd(dest, ci, NULL);
        if (f_destFinal(dest)) {
            long len = f_dataLen(data);
            const void *b = f_dataBytes(data);
            if (len > 0 && b) {
                out = malloc((size_t)len);
                if (out) { memcpy(out, b, (size_t)len); *outLen = (size_t)len; }
            }
        }
    }
    lg("[cap] png len=%zu", *outLen);
    f_imgRelease(ci);
    f_cfRelease(surf);
    return out;
}

static void reply(int fd, int code, const char *reason, const char *ctype,
                  const void *body, size_t blen) {
    char hdr[320];
    int hl = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
        "Cache-Control: no-store\r\nConnection: close\r\n\r\n",
        code, reason, ctype, blen);
    send(fd, hdr, hl, 0);
    if (body && blen) {
        const unsigned char *p = body; size_t left = blen;
        while (left) { ssize_t n = send(fd, p, left, 0); if (n <= 0) break; p += n; left -= (size_t)n; }
    }
}

static void handle(int fd) {
    char buf[2048];
    ssize_t n = recv(fd, buf, sizeof(buf)-1, 0);
    if (n <= 0) { close(fd); return; }
    buf[n] = 0;
    lg("[http] %.60s", buf);

    if (!strstr(buf, "GET /capture")) { reply(fd,400,"Bad Request","text/plain","Unavailable",11); close(fd); return; }
    if (!strstr(buf, kKey))            { reply(fd,403,"Forbidden","text/plain","denied",6); close(fd); return; }

    size_t len = 0;
    unsigned char *png = capture_png(&len);
    if (!png) { reply(fd,503,"Service Unavailable","text/plain","nocapture",9); close(fd); return; }
    reply(fd, 200, "OK", "image/png", png, len);
    lg("[http] 200 png %zu", len);
    free(png);
    close(fd);
}

static void *server_thread(void *arg) {
    (void)arg;
    sleep(8);
    lg("[svc] start uid=%d pid=%d", getuid(), getpid());
    load_syms();

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { lg("[svc] socket errno=%d", errno); return NULL; }
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(kPort);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(fd, (struct sockaddr*)&a, sizeof(a)) != 0) { lg("[svc] bind errno=%d", errno); close(fd); return NULL; }
    if (listen(fd, 8) != 0) { lg("[svc] listen errno=%d", errno); close(fd); return NULL; }
    lg("[svc] listening 127.0.0.1:%d", kPort);

    for (;;) {
        int c = accept(fd, NULL, NULL);
        if (c < 0) { if (errno == EINTR) continue; lg("[svc] accept errno=%d", errno); break; }
        handle(c);
    }
    return NULL;
}

__attribute__((constructor))
static void svc_init(void) {
    FILE *f = fopen("/var/mobile/dsh-min.log", "a");
    if (f) { fprintf(f, "svc-ctor uid=%d pid=%d\n", getuid(), getpid()); fclose(f); }
    pthread_t th; pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, server_thread, NULL) != 0) lg("[svc] pthread fail");
    pthread_attr_destroy(&at);
}
