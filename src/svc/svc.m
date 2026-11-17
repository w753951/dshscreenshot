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

    // 方案 C：让 SpringBoard 自己截图（SBScreenShotter / SBScreenshotManager）
    void *libobjc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY);
    void *(*o_getClass)(const char*) = libobjc ? dlsym(libobjc, "objc_getClass") : NULL;
    void *(*o_msgSend)(void*, void*, ...) = libobjc ? dlsym(libobjc, "objc_msgSend") : NULL;
    void *(*o_sel)(const char*) = libobjc ? dlsym(libobjc, "sel_registerName") : NULL;
    lg("[cap] objc getClass=%p msgSend=%p sel=%p", (void*)o_getClass, (void*)o_msgSend, (void*)o_sel);

    const char *cls_names[] = { "SBScreenShotter", "SBScreenshotManager", "SBScreenFlash", NULL };
    for (int i = 0; cls_names[i]; i++) {
        void *c = o_getClass ? o_getClass(cls_names[i]) : NULL;
        lg("[cap] class %s = %p", cls_names[i], c);
    }

    int triggered = 0;
    if (o_getClass && o_msgSend && o_sel) {
        void *shotter = o_getClass("SBScreenShotter");
        if (shotter) {
            void *inst = o_msgSend(shotter, o_sel("sharedInstance"));
            lg("[cap] shotter inst=%p", inst);
            if (inst) {
                o_msgSend(inst, o_sel("saveScreenshot:"), 1);
                lg("[cap] saveScreenshot: called");
                triggered = 1;
            }
        }
        if (!triggered) {
            void *mgr = o_getClass("SBScreenshotManager");
            if (mgr) {
                void *inst = o_msgSend(mgr, o_sel("sharedInstance"));
                lg("[cap] screenshotManager inst=%p", inst);
                if (inst) {
                    o_msgSend(inst, o_sel("saveScreenshots"));
                    lg("[cap] saveScreenshots called");
                    triggered = 1;
                }
            }
        }
    }

    if (!triggered) { lg("[cap] no screenshot trigger available"); f_cfRelease(surf); return NULL; }

    // 等相册出现新文件
    char newest[512] = {0};
    for (int w = 0; w < 40; w++) {
        usleep(100000);
        // 用 popen 找最新 PNG（简单可靠）
        FILE *pp = popen("ls -t /var/mobile/Media/DCIM/*/*.PNG 2>/dev/null | head -1", "r");
        if (pp) {
            char line[512] = {0};
            if (fgets(line, sizeof(line), pp)) {
                size_t L = strlen(line);
                while (L && (line[L-1]=='\n'||line[L-1]=='\r')) line[--L]=0;
                if (L && strcmp(line, newest) != 0) {
                    if (newest[0] == 0) { strncpy(newest, line, sizeof(newest)-1); }
                    else {
                        strncpy(newest, line, sizeof(newest)-1);
                        pclose(pp);
                        lg("[cap] new file: %s", newest);
                        break;
                    }
                }
            }
            pclose(pp);
        }
    }
    lg("[cap] newest=%s", newest);

    if (!newest[0]) { f_cfRelease(surf); return NULL; }

    FILE *fp = fopen(newest, "rb");
    if (!fp) { lg("[cap] open file fail"); f_cfRelease(surf); return NULL; }
    fseek(fp, 0, SEEK_END);
    long flen = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    unsigned char *buf = malloc((size_t)flen);
    if (buf && fread(buf, 1, (size_t)flen, fp) == (size_t)flen) {
        *outLen = (size_t)flen;
    } else { free(buf); buf = NULL; }
    fclose(fp);
    f_cfRelease(surf);
    lg("[cap] return png %zu bytes", *outLen);
    return buf;
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
