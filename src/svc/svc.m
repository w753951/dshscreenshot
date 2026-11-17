// svc.m —— SpringBoard 截图服务（真 arm64e，纯 C + dlopen 私有 API）
// GET http://127.0.0.1:47191/capture?key=dsh-go-screen-v1 -> image/png

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
typedef struct __CFNumber *CFNumberRef;
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

// ---- 符号 ----
static int (*f_renderDisplay)(unsigned, CFStringRef, IOSurfaceRef);
static IOSurfaceRef (*f_surfaceCreate)(CFDictRef);
static void *(*f_surfaceBase)(IOSurfaceRef);
static size_t (*f_surfaceBPR)(IOSurfaceRef);
static size_t (*f_surfaceW)(IOSurfaceRef);
static size_t (*f_surfaceH)(IOSurfaceRef);

static CGColorSpaceRef (*f_csDeviceRGB)(void);
static void (*f_csRelease)(CGColorSpaceRef);
static CGContextRef (*f_bitmapCtxCreate)(void*, size_t, size_t, size_t, size_t, CGColorSpaceRef, unsigned);
static CGImageRef (*f_ctxCreateImage)(CGContextRef);
static void (*f_ctxRelease)(CGContextRef);
static void (*f_imgRelease)(CGImageRef);

static CFDataRef (*f_dataCreateMutable)(const void*, long);
static const void *(*f_dataBytes)(CFDataRef);
static long (*f_dataLen)(CFDataRef);
static void (*f_cfRelease)(const void*);
static CFStringRef (*f_strCreate)(const void*, const char*, unsigned);
static CFNumberRef (*f_numCreate)(const void*, long, const void*);
static CFDictRef (*f_dictCreate)(const void*, const void**, const void**, long, const void*, const void*);
static void (*f_dictSet)(CFDictRef, const void*, const void*);
static const void *kDictKeyCB;

static int (*f_dispCount)(void);
static CFStringRef (*f_dispName)(long);
static int (*f_strGetCString)(CFStringRef, char*, long, unsigned);

static void *(*f_imgDestCreate)(CFDataRef, CFStringRef, unsigned long, const void*);
static void (*f_imgDestAdd)(void*, CGImageRef, const void*);
static int (*f_imgDestFinal)(void*);

static int g_ready = 0;

static void load_syms(void) {
    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    void *is = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
    void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    void *cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
    void *io = dlopen("/System/Library/Frameworks/ImageIO.framework/ImageIO", RTLD_LAZY);

    lg("[sym] qc=%p is=%p cg=%p cf=%p io=%p", qc, is, cg, cf, io);

    if (qc) {
        f_renderDisplay = dlsym(qc, "CARenderServerRenderDisplay");
        f_dispCount     = dlsym(qc, "CARenderServerGetDisplayCount");
        f_dispName      = dlsym(qc, "CARenderServerCopyDisplayName");
        lg("[sym] dispCount=%p dispName=%p", (void*)f_dispCount, (void*)f_dispName);
    }
    if (is) {
        f_surfaceCreate = dlsym(is, "IOSurfaceCreate");
        f_surfaceBase   = dlsym(is, "IOSurfaceGetBaseAddress");
        f_surfaceBPR    = dlsym(is, "IOSurfaceGetBytesPerRow");
        f_surfaceW      = dlsym(is, "IOSurfaceGetWidth");
        f_surfaceH      = dlsym(is, "IOSurfaceGetHeight");
    }
    if (cg) {
        f_csDeviceRGB     = dlsym(cg, "CGColorSpaceCreateDeviceRGB");
        f_csRelease       = dlsym(cg, "CGColorSpaceRelease");
        f_bitmapCtxCreate = dlsym(cg, "CGBitmapContextCreate");
        f_ctxCreateImage  = dlsym(cg, "CGBitmapContextCreateImage");
        f_ctxRelease      = dlsym(cg, "CGContextRelease");
        f_imgRelease      = dlsym(cg, "CGImageRelease");
    }
    if (cf) {
        f_dataCreateMutable = dlsym(cf, "CFDataCreateMutable");
        f_dataBytes         = dlsym(cf, "CFDataGetBytePtr");
        f_dataLen           = dlsym(cf, "CFDataGetLength");
        f_cfRelease         = dlsym(cf, "CFRelease");
        f_strCreate         = dlsym(cf, "CFStringCreateWithCString");
        f_strGetCString     = dlsym(cf, "CFStringGetCString");
        f_numCreate         = dlsym(cf, "CFNumberCreate");
        f_dictCreate        = dlsym(cf, "CFDictionaryCreate");
        f_dictSet           = dlsym(cf, "CFDictionarySetValue");
        kDictKeyCB          = (const void *)dlsym(cf, "kCFTypeDictionaryKeyCallBacks");
    }
    if (io) {
        f_imgDestCreate = dlsym(io, "CGImageDestinationCreateWithData");
        f_imgDestAdd    = dlsym(io, "CGImageDestinationAddImage");
        f_imgDestFinal  = dlsym(io, "CGImageDestinationFinalize");
    }

    g_ready = f_renderDisplay && f_surfaceCreate && f_surfaceBase && f_surfaceBPR &&
              f_csDeviceRGB && f_bitmapCtxCreate && f_ctxCreateImage &&
              f_dataCreateMutable && f_dataBytes && f_dataLen && f_strCreate &&
              f_numCreate && f_dictCreate && kDictKeyCB &&
              f_imgDestCreate && f_imgDestAdd && f_imgDestFinal;
    lg("[sym] ready=%d render=%p surf=%p dest=%p", g_ready,
       (void*)f_renderDisplay, (void*)f_surfaceCreate, (void*)f_imgDestCreate);
}

static void screen_size(size_t *w, size_t *h) {
    *w = 1284; *h = 2778;
    FILE *f = fopen("/var/mobile/dsh-screen-size.txt", "r");
    if (f) { unsigned long a=0,b=0; if (fscanf(f,"%lu %lu",&a,&b)==2 && a&&b){*w=a;*h=b;} fclose(f); }
}

// 返回 PNG 数据（malloc 分配，调用方 free），失败返回 NULL
static unsigned char *capture_png(size_t *outLen) {
    *outLen = 0;
    if (!g_ready) return NULL;

    size_t W, H; screen_size(&W, &H);

    CFStringRef kWidth  = f_strCreate(NULL, "IOSurfaceWidth", 0x08000100);
    CFStringRef kHeight = f_strCreate(NULL, "IOSurfaceHeight", 0x08000100);
    CFStringRef kBytes  = f_strCreate(NULL, "IOSurfaceBytesPerElement", 0x08000100);
    CFStringRef kFormat = f_strCreate(NULL, "IOSurfacePixelFormat", 0x08000100);
    CFStringRef kRow    = f_strCreate(NULL, "IOSurfaceBytesPerRow", 0x08000100);
    CFStringRef kAlloc  = f_strCreate(NULL, "IOSurfaceAllocSize", 0x08000100);
    if (!kWidth||!kHeight||!kBytes||!kFormat) { lg("[cap] keystr fail"); return NULL; }

    int32_t vw=(int32_t)W, vh=(int32_t)H, vb=4, vrow=(int32_t)(W*4);
    uint32_t vf=0x42475241; /* 'BGRA' */
    int32_t valloc=(int32_t)(W*H*4);
    CFNumberRef nw = f_numCreate(NULL, 3, &vw);
    CFNumberRef nh = f_numCreate(NULL, 3, &vh);
    CFNumberRef nb = f_numCreate(NULL, 3, &vb);
    CFNumberRef nf = f_numCreate(NULL, 3, &vf);
    CFNumberRef nr = f_numCreate(NULL, 3, &vrow);
    CFNumberRef na = f_numCreate(NULL, 3, &valloc);

    const void *keys[6] = { kWidth, kHeight, kBytes, kFormat, kRow, kAlloc };
    const void *vals[6] = { nw, nh, nb, nf, nr, na };
    CFDictRef props = f_dictCreate(NULL, keys, vals, 6, kDictKeyCB, kDictKeyCB);
    if (!props) { lg("[cap] dict fail"); return NULL; }

    IOSurfaceRef surf = f_surfaceCreate(props);
    if (!surf) { lg("[cap] IOSurfaceCreate fail %zux%zu", W, H); return NULL; }

    size_t bw0 = f_surfaceW ? f_surfaceW(surf) : 0;
    size_t bh0 = f_surfaceH ? f_surfaceH(surf) : 0;
    size_t bpr0 = f_surfaceBPR(surf);
    void *base0 = f_surfaceBase(surf);
    lg("[cap] surf w=%zu h=%zu bpr=%zu base=%p", bw0, bh0, bpr0, base0);

    // 方案 B：IOMobileFramebuffer 直接拿主屏 surface
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    void *imf   = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_LAZY);
    lg("[cap] iokit=%p imf=%p", iokit, imf);

    unsigned (*fb_open)(void) = imf ? dlsym(imf, "IOMobileFramebufferOpen") : NULL;
    int (*fb_getMain)(unsigned*) = imf ? dlsym(imf, "IOMobileFramebufferGetMainDisplay") : NULL;
    int (*fb_getLayer)(unsigned, int, IOSurfaceRef*) = imf ? dlsym(imf, "IOMobileFramebufferGetLayerDefaultSurface") : NULL;
    lg("[cap] fb_open=%p getMain=%p getLayer=%p", (void*)fb_open, (void*)fb_getMain, (void*)fb_getLayer);

    IOSurfaceRef fbSurf = NULL;

    // 优先用 GetMainDisplay
    if (fb_getMain) {
        unsigned fb = 0;
        int r = fb_getMain(&fb);
        lg("[cap] getMain rc=%d fb=%u", r, fb);
        if (fb && fb_getLayer) {
            int r2 = fb_getLayer(fb, 0, &fbSurf);
            lg("[cap] getLayer rc=%d surf=%p", r2, (void*)fbSurf);
        }
    }
    // 退化到 Open
    if (!fbSurf && fb_open && fb_getLayer) {
        unsigned fb = fb_open();
        lg("[cap] fb_open -> %u", fb);
        if (fb) {
            int r = fb_getLayer(fb, 0, &fbSurf);
            lg("[cap] getLayer(open) rc=%d surf=%p", r, (void*)fbSurf);
        }
    }

    if (!fbSurf) { lg("[cap] no fb surface"); f_cfRelease(surf); return NULL; }

    size_t fbw = f_surfaceW ? f_surfaceW(fbSurf) : 0;
    size_t fbh = f_surfaceH ? f_surfaceH(fbSurf) : 0;
    size_t fbpr = f_surfaceBPR(fbSurf);
    void *fbbase = f_surfaceBase(fbSurf);
    lg("[cap] fb surface w=%zu h=%zu bpr=%zu base=%p", fbw, fbh, fbpr, fbbase);
    if (!fbw || !fbh || !fbbase) { lg("[cap] bad fb surface"); f_cfRelease(surf); return NULL; }

    // 采样确认非空
    size_t nz2 = 0;
    const unsigned char *pfb = (const unsigned char*)fbbase;
    size_t tot2 = fbpr * fbh;
    for (size_t i = 0; i < tot2; i += 97) if (pfb[i]) nz2++;
    lg("[cap] fb sampled-nonzero=%zu", nz2);

    size_t bw = fbw, bh = fbh, bpr = fbpr;
    void *base = fbbase;

    CGColorSpaceRef cs = f_csDeviceRGB();
    CGContextRef ctx = f_bitmapCtxCreate(base, bw, bh, 8, bpr, cs,
        1 /*kCGImageAlphaPremultipliedFirst*/ | (2<<12) /*ByteOrder32Little*/);
    f_csRelease(cs);
    if (!ctx) { lg("[cap] ctx fail"); f_cfRelease(surf); return NULL; }

    CGImageRef cg = f_ctxCreateImage(ctx);
    f_ctxRelease(ctx);
    if (!cg) { lg("[cap] cgimg fail"); f_cfRelease(surf); return NULL; }

    CFDataRef data = f_dataCreateMutable(NULL, 0);
    CFStringRef pngType = f_strCreate(NULL, "public.png", 0x08000100);
    void *dest = f_imgDestCreate(data, pngType, 1, NULL);
    unsigned char *out = NULL;
    if (dest) {
        f_imgDestAdd(dest, cg, NULL);
        if (f_imgDestFinal(dest)) {
            long len = f_dataLen(data);
            const void *bytes = f_dataBytes(data);
            if (len > 0 && bytes) {
                out = malloc((size_t)len);
                if (out) { memcpy(out, bytes, (size_t)len); *outLen = (size_t)len; }
            }
        }
    }
    lg("[cap] png len=%zu", *outLen);

    f_imgRelease(cg);
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
        while (left) { ssize_t n = send(fd, p, left, 0); if (n<=0) break; p+=n; left-=(size_t)n; }
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
    lg("[http] 200 png %zu bytes", len);
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

    if (bind(fd, (struct sockaddr*)&a, sizeof(a)) != 0) {
        lg("[svc] bind errno=%d", errno); close(fd); return NULL;
    }
    if (listen(fd, 8) != 0) { lg("[svc] listen errno=%d", errno); close(fd); return NULL; }
    lg("[svc] listening 127.0.0.1:%d", kPort);

    for (;;) {
        int c = accept(fd, NULL, NULL);
        if (c < 0) { if (errno==EINTR) continue; lg("[svc] accept errno=%d", errno); break; }
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
