// svc.m —— SpringBoard 截图服务（真 arm64e）
// GET http://127.0.0.1:47191/capture?key=dsh-go-screen-v1 -> image/png
//
// 抓屏：UIKit 私有函数 _UICreateScreenUIImageWithRotation（Snapper3 同款）
// 关键：整个 UIKit 调用必须放主线程，用 dispatch_sync_f（函数指针版，不需要 block）

#include <stdio.h>
#include <stdlib.h>
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
