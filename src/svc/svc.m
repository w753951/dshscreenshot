// svc.m —— SpringBoard 截图服务（真 arm64e）
// GET http://127.0.0.1:47191/capture?key=dsh-go-screen-v1 -> image/png
//
// 抓屏：UIKit 私有函数 _UICreateScreenUIImageWithRotation（Snapper3 同款）
// 关键：整个 UIKit 调用必须放主线程，用 dispatch_sync_f（函数指针版，不需要 block）

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <CoreFoundation/CoreFoundation.h>

static const int  kPort = 47191;
static const char *kKey = "dsh-go-screen-v1";
static const char *kLog = "/var/mobile/dsh-screen-plugin.log";

static void lg(const char *fmt, ...) {
    FILE *f = fopen(kLog, "a");
    if (!f) return;
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fclose(f);
}

/* ---- 在主线程上执行的抓屏核心 ---- */
struct CapCtx {
    unsigned char *out;
    size_t len;
    void *uikit;
    void *(*create)(int);
    void *(*pngRep)(void *);
    dispatch_semaphore_t sem;
};

static void cap_body(void *p) {
    struct CapCtx *c = (struct CapCtx *)p;
    c->out = NULL; c->len = 0;

    void *img = c->create(1);
    lg("[core] image=%p", img);
    if (!img) return;

    /* 不走 UIImagePNGRepresentation（会崩），改为取 CGImage + ImageIO 编码 */
    void *libobjc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY);
    void *(*msgSend)(void*, void*, ...) = libobjc ? dlsym(libobjc, "objc_msgSend") : NULL;
    void *(*selReg)(const char*) = libobjc ? dlsym(libobjc, "sel_registerName") : NULL;
    lg("[core] objc msgSend=%p sel=%p", (void*)msgSend, (void*)selReg);
    if (!msgSend || !selReg) return;

    void *cgImage = msgSend(img, selReg("CGImage"));
    lg("[core] cgImage=%p", cgImage);
    if (!cgImage) return;

    void *cf  = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
    void *io  = dlopen("/System/Library/Frameworks/ImageIO.framework/ImageIO", RTLD_LAZY);
    lg("[core] cf=%p io=%p", cf, io);
    if (!cf || !io) return;

    typedef void *CFDataRef;
    CFDataRef (*dataNew)(const void*, long)          = dlsym(cf, "CFDataCreateMutable");
    const void *(*dataBytes)(CFDataRef)              = dlsym(cf, "CFDataGetBytePtr");
    long (*dataLen)(CFDataRef)                       = dlsym(cf, "CFDataGetLength");
    void *(*strCreate)(const void*, const char*, unsigned) = dlsym(cf, "CFStringCreateWithCString");
    void *(*destNew)(CFDataRef, void*, unsigned long, const void*) = dlsym(io, "CGImageDestinationCreateWithData");
    void (*destAdd)(void*, void*, const void*)       = dlsym(io, "CGImageDestinationAddImage");
    int  (*destFinal)(void*)                         = dlsym(io, "CGImageDestinationFinalize");
    lg("[core] dataNew=%p destNew=%p destAdd=%p destFinal=%p",
       (void*)dataNew, (void*)destNew, (void*)destAdd, (void*)destFinal);
    if (!dataNew || !dataBytes || !dataLen || !strCreate || !destNew || !destAdd || !destFinal) return;

    CFDataRef data = dataNew(NULL, 0);
    void *pngType = strCreate(NULL, "public.png", 0x08000100);
    void *dest = destNew(data, pngType, 1, NULL);
    lg("[core] data=%p dest=%p", (void*)data, dest);
    if (!dest) return;

    destAdd(dest, cgImage, NULL);
    int ok = destFinal(dest);
    lg("[core] finalize=%d", ok);
    if (!ok) return;

    long len = dataLen(data);
    const void *b = dataBytes(data);
    lg("[core] png len=%ld", len);
    if (len <= 8 || !b) return;

    unsigned char *buf = malloc((size_t)len);
    if (!buf) return;
    memcpy(buf, b, (size_t)len);
    c->out = buf;
    c->len = (size_t)len;
}

/* 主队列执行体：保证一定会 signal，哪怕中间提前 return */
static void capture_core(void *p) {
    struct CapCtx *c = (struct CapCtx *)p;
    cap_body(p);
    if (c && c->sem) dispatch_semaphore_signal(c->sem);
}

static unsigned char *capture_png(size_t *outLen) {
    *outLen = 0;

    void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
    if (!uikit) { lg("[cap] no UIKit"); return NULL; }

    void *(*create)(int) = dlsym(uikit, "_UICreateScreenUIImageWithRotation");
    if (!create) create = dlsym(uikit, "__UICreateScreenUIImageWithRotation");
    void *(*pngRep)(void *) = dlsym(uikit, "UIImagePNGRepresentation");
    lg("[cap] create=%p pngRep=%p", (void*)create, (void*)pngRep);
    if (!create || !pngRep) return NULL;

    /* 堆上分配：超时后 worker 仍可能在使用，不能放栈 */
    struct CapCtx *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    ctx->uikit = uikit;
    ctx->create = create;
    ctx->pngRep = pngRep;
    ctx->sem = dispatch_semaphore_create(0);

    /* 主队列 + dispatch_async_f + 3s 超时：
       主线程一旦卡住，服务线程不会跟着死锁，直接回 503 */
    void *mainQ = (void *)dlsym(RTLD_DEFAULT, "_dispatch_main_q");
    void (*async_f)(void *, void *, void (*)(void *)) =
        (void (*)(void *, void *, void (*)(void *)))dlsym(RTLD_DEFAULT, "dispatch_async_f");
    lg("[cap] mainQ=%p async_f=%p", mainQ, (void*)async_f);

    if (mainQ && async_f) {
        async_f(mainQ, ctx, capture_core);
        long r = dispatch_semaphore_wait(ctx->sem,
                                         dispatch_time(DISPATCH_TIME_NOW, 3LL * NSEC_PER_SEC));
        if (r != 0) {
            lg("[cap] timeout, return 503");
            return NULL;          /* ctx 交由 worker 收尾，故意不 free */
        }
        lg("[cap] ran on main queue");
    } else {
        capture_core(ctx);
        lg("[cap] ran on caller thread");
    }

    *outLen = ctx->len;
    return ctx->out;
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

/* ================= 触摸注入（在 SpringBoard 里发，权限最高） ================= */
#include <mach/mach_time.h>

typedef void *HIDClient;
static HIDClient gHid = NULL;
static HIDClient (*xCreate)(CFAllocatorRef);
static void   (*xSetProp)(HIDClient, CFStringRef, CFTypeRef);
static void   (*xDispatch)(HIDClient, void *);
static void  *(*xFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t,
                         float, float, float, float, float, int, int, unsigned long);
static void  *(*xDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t,
                            uint32_t, float, float, float, float, float, int, int, unsigned long);
static void   (*xAppend)(void *, void *);

static void *iofind(const char *n) {
    static const char *libs[] = {
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        "/System/Library/PrivateFrameworks/IOKit.framework/IOKit",
        NULL
    };
    for (int i = 0; libs[i]; i++) {
        void *h = dlopen(libs[i], RTLD_LAZY);
        if (!h) continue;
        void *s = dlsym(h, n);
        if (s) return s;
    }
    return NULL;
}

static void touch_init(void) {
    xCreate    = (void *)iofind("IOHIDEventSystemClientCreate");
    xSetProp   = (void *)iofind("IOHIDEventSystemClientSetProperty");
    xDispatch  = (void *)iofind("IOHIDEventSystemClientDispatchEvent");
    xFinger    = (void *)iofind("IOHIDEventCreateDigitizerFingerEvent");
    xDigitizer = (void *)iofind("IOHIDEventCreateDigitizerEvent");
    xAppend    = (void *)iofind("IOHIDEventAppendEvent");
    if (!xCreate || !xDispatch) { lg("[touch] no symbols"); return; }
    gHid = xCreate(kCFAllocatorDefault);
    if (gHid && xSetProp) xSetProp(gHid, CFSTR("AllowInstrumentation"), kCFBooleanTrue);
    lg("[touch] client=%p finger=%p digit=%p dispatch=%p append=%p",
       (void *)gHid, (void *)xFinger, (void *)xDigitizer, (void *)xDispatch, (void *)xAppend);
}

static void send_touch(int phase, double x, double y, uint32_t ident) {
    if (!gHid) return;
    uint32_t mask; int range, touch;
    if (phase == 2) { mask = 1 | 2;       range = 0; touch = 0; }
    else            { mask = 1 | 2 | 4;   range = 1; touch = 1; }
    uint64_t ts = mach_absolute_time();

    void *finger = NULL;
    if (xFinger)
        finger = xFinger(kCFAllocatorDefault, ts, 0, ident, mask, 0,
                         (float)x, (float)y, 0.f, 1.f, 0.f, range, touch, 0);
    if (!finger && xDigitizer)
        finger = xDigitizer(kCFAllocatorDefault, ts, 2, 0, ident, mask, 0,
                            (float)x, (float)y, 0.f, 1.f, 0.f, range, touch, 0);
    if (!finger) return;

    if (xDigitizer && xAppend) {
        void *hand = xDigitizer(kCFAllocatorDefault, ts, 3, 0, ident, 1 | 2, 0,
                                0.f, 0.f, 0.f, 0.f, 0.f, range, 0, 0);
        if (hand) { xAppend(hand, finger); xDispatch(gHid, hand); return; }
    }
    xDispatch(gHid, finger);
}

static void show_dot(double nx, double ny);   /* 定义在后面 */

static void do_tap(double x, double y, int ms) {
    show_dot(x, y);                    /* 先亮圆点：用户能看见 AI 打算点哪儿 */
    send_touch(0, x, y, 0x2001);
    usleep(ms * 1000);
    send_touch(2, x, y, 0x2001);
}

static void do_swipe(double x1, double y1, double x2, double y2, int ms) {
    const int steps = 18;
    int step_ms = ms / steps; if (step_ms < 1) step_ms = 1;
    show_dot(x1, y1);
    send_touch(0, x1, y1, 0x2002);
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / steps;
        double cx = x1 + (x2 - x1) * t, cy = y1 + (y2 - y1) * t;
        show_dot(cx, cy);              /* 圆点跟着滑动轨迹走 */
        send_touch(1, cx, cy, 0x2002);
        usleep(step_ms * 1000);
    }
    send_touch(2, x2, y2, 0x2002);
}

static double qnum(const char *req, const char *name, double def) {
    char pat[48]; snprintf(pat, sizeof(pat), "%s=", name);
    const char *p = strstr(req, pat);
    return p ? atof(p + strlen(pat)) : def;
}

/* ================= 触摸圆点：在 SpringBoard 里画一个可见的触点 ================= */
typedef struct { double x, y, w, h; } DshRect;

static void *gDotWin = NULL;
static void *gDotView = NULL;
static void *gMsg = NULL;
static void *(*gSel)(const char *) = NULL;
static void *(*gGetClass)(const char *) = NULL;

static void dot_load(void) {
    void *libobjc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY);
    if (libobjc) {
        gGetClass = dlsym(libobjc, "objc_getClass");
        gSel = dlsym(libobjc, "sel_registerName");
        gMsg = dlsym(libobjc, "objc_msgSend");
    }
    dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
}

#define SEND(obj, name) ((void *(*)(void *, void *))gMsg)((obj), gSel(name))
#define SEND1(obj, name, a) ((void *(*)(void *, void *, void *))gMsg)((obj), gSel(name), (void *)(a))
#define SEND1D(obj, name, d) ((void *(*)(void *, void *, double))gMsg)((obj), gSel(name), (d))
#define SEND1R(obj, name, r) ((void *(*)(void *, void *, DshRect))gMsg)((obj), gSel(name), (r))

static DshRect dot_bounds(void) {
    DshRect b = {0, 0, 428, 926};
    void *screen = SEND(gGetClass("UIScreen"), "mainScreen");
    if (screen) {
        DshRect r = ((DshRect (*)(void *, void *))gMsg)(screen, gSel("bounds"));
        if (r.w > 1 && r.h > 1) b = r;
    }
    return b;
}

/* 在 (nx, ny) 归一化位置显示一个红点；保持 1.6 秒后自动隐藏 */
#define R 18.0   /* 圆点半径（pt），小而精准 */

/* 窗口只占圆点大小，避免挡住所层；用户可以用手指拖它 */
static void dsh_pan(void *self, void *cmd, void *gr) {
    (void)cmd;
    if (!gMsg || !gSel) return;
    void *window = SEND(self, "window");
    void *superview = window ? SEND(window, "superview") : NULL;
    DshRect t = ((DshRect (*)(void *, void *, void *))gMsg)(gr, gSel("translationInView:"), superview);
    DshRect f = ((DshRect (*)(void *, void *))gMsg)(self, gSel("frame"));
    f.x += t.x; f.y += t.y;
    SEND1R(self, "setFrame:", f);
    void *zero = SEND(gGetClass("NSValue"), "valueWithCGPoint:");
    (void)zero;
    ((void (*)(void *, void *, DshRect, void *))gMsg)(gr, gSel("setTranslation:inView:"), (DshRect){0,0,0,0}, superview);
    if (window) SEND1R(window, "setFrame:", f);
    lg("[dot] dragged to %.0f,%.0f", f.x, f.y);
}

static void show_dot_impl(double nx, double ny) {
    if (!gMsg || !gSel || !gGetClass) { lg("[dot] no objc"); return; }
    DshRect b = dot_bounds();
    DshRect fr = { nx * b.w - R, ny * b.h - R, R * 2.0, R * 2.0 };

    if (!gDotWin) {
        void *win = SEND(gGetClass("UIWindow"), "alloc");
        win = SEND1R(win, "initWithFrame:", fr);
        if (!win) { lg("[dot] no window"); return; }
        SEND1D(win, "setWindowLevel:", 10000001.0);
        SEND1(win, "setHidden:", NULL);
        gDotWin = win;
        lg("[dot] window created %p", win);
    } else {
        SEND1R(gDotWin, "setFrame:", fr);
    }

    if (!gDotView) {
        void *v = SEND(gGetClass("UIView"), "alloc");
        DshRect local = { 0, 0, R * 2.0, R * 2.0 };
        v = SEND1R(v, "initWithFrame:", local);
        void *red = SEND(gGetClass("UIColor"), "redColor");
        SEND1(v, "setBackgroundColor:", red);
        void *layer = SEND(v, "layer");
        if (layer) { SEND1D(layer, "setCornerRadius:", R); SEND1D(layer, "setBorderWidth:", 2.5); }

        /* 让圆点能被手指拖动：动态造一个带 pan 手势的类 */
        void *(*allocClassPair)(void *, const char *, size_t) = dlsym(RTLD_DEFAULT, "objc_allocateClassPair");
        unsigned char (*addMethod)(void *, void *, void *, const char *) = dlsym(RTLD_DEFAULT, "class_addMethod");
        void (*regPair)(void *) = dlsym(RTLD_DEFAULT, "objc_registerClassPair");
        if (allocClassPair && addMethod && regPair) {
            void *cls = allocClassPair(gGetClass("UIView"), "DshDotView", 0);
            if (cls) {
                addMethod(cls, gSel("dshPan:"), (void *)dsh_pan, "v@:@");
                regPair(cls);
                void *dv = SEND(cls, "alloc");
                dv = SEND1R(dv, "initWithFrame:", local);
                if (dv) v = dv;
                lg("[dot] draggable class installed");
            }
        }

        SEND1(gDotWin, "addSubview:", v);
        gDotView = v;

        void *pan = SEND(gGetClass("UIPanGestureRecognizer"), "alloc");
        pan = ((void *(*)(void *, void *, void *, void *))gMsg)(pan, gSel("initWithTarget:action:"), v, gSel("dshPan:"));
        if (pan) SEND1(v, "addGestureRecognizer:", pan);
        SEND1(gDotWin, "setUserInteractionEnabled:", (void *)1);
        SEND1(v, "setUserInteractionEnabled:", (void *)1);
    }
    SEND1(gDotWin, "setHidden:", NULL);
    lg("[dot] shown at %.3f,%.3f", nx, ny);
}

static void hide_dot_impl(void) {
    if (gDotWin) SEND1(gDotWin, "setHidden:", (void *)1);
    lg("[dot] hidden");
}

/* UIKit 必须在主线程，包一层 dispatch_sync_f */
struct DotReq { double nx, ny; };

static void dot_core(void *p) {
    struct DotReq *r = (struct DotReq *)p;
    show_dot_impl(r->nx, r->ny);
}
static void nodot_core(void *p) { (void)p; hide_dot_impl(); }

static void on_main(void (*fn)(void *), void *arg) {
    void *mainQ = (void *)dlsym(RTLD_DEFAULT, "_dispatch_main_q");
    void (*sync_f)(void *, void *, void (*)(void *)) =
        (void (*)(void *, void *, void (*)(void *)))dlsym(RTLD_DEFAULT, "dispatch_sync_f");
    if (mainQ && sync_f) sync_f(mainQ, arg, fn);
    else fn(arg);
}

static void show_dot(double nx, double ny) {
    struct DotReq req = { nx, ny };
    on_main(dot_core, &req);
}
static void hide_dot(void) { on_main(nodot_core, NULL); }

static void handle(int fd) {
    char buf[2048];
    ssize_t n = recv(fd, buf, sizeof(buf)-1, 0);
    if (n <= 0) { close(fd); return; }
    buf[n] = 0;
    lg("[http] %.60s", buf);

    if (!strstr(buf, kKey)) { reply(fd,403,"Forbidden","text/plain","denied",6); close(fd); return; }

    if (strstr(buf, "GET /dot")) {
        show_dot(qnum(buf, "x", 0.5), qnum(buf, "y", 0.5));
        reply(fd, 200, "OK", "text/plain", "dot ok", 6);
        close(fd); return;
    }
    if (strstr(buf, "GET /nodot")) {
        hide_dot();
        reply(fd, 200, "OK", "text/plain", "nodot ok", 8);
        close(fd); return;
    }
    if (strstr(buf, "GET /tap")) {
        double x = qnum(buf, "x", 0), y = qnum(buf, "y", 0);
        int ms = (int)qnum(buf, "ms", 80);
        do_tap(x, y, ms);
        lg("[tap] %.0f,%.0f", x, y);
        reply(fd, 200, "OK", "text/plain", "tap ok", 6);
        close(fd); return;
    }
    if (strstr(buf, "GET /swipe")) {
        do_swipe(qnum(buf,"x1",0), qnum(buf,"y1",0), qnum(buf,"x2",0), qnum(buf,"y2",0),
                 (int)qnum(buf,"ms",300));
        lg("[swipe] done");
        reply(fd, 200, "OK", "text/plain", "swipe ok", 8);
        close(fd); return;
    }
    if (!strstr(buf, "GET /capture")) { reply(fd,400,"Bad Request","text/plain","Unavailable",11); close(fd); return; }

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
    touch_init();
    dot_load();
    pthread_t th; pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, server_thread, NULL) != 0) lg("[svc] pthread fail");
    pthread_attr_destroy(&at);
}
