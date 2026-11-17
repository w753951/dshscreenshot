// svc.m —— 阶段1：验证注入 + HTTP 服务可用（纯 C）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>

#include <dlfcn.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

extern void *dispatch_get_global_queue(long identifier, unsigned long flags);
extern void dispatch_async(void *queue, void *block);

static const int  kPort = 47191;
static const char *kLog = "/var/mobile/dsh-screen-plugin.log";

static void lg(const char *fmt, ...) {
    FILE *f = fopen(kLog, "a");
    if (!f) return;
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fclose(f);
}

static void probe_syms(void) {
    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    void *is = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
    void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    void *io = dlopen("/System/Library/Frameworks/ImageIO.framework/ImageIO", RTLD_LAZY);
    void *cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);

    void *rd  = qc ? dlsym(qc, "CARenderServerRenderDisplay") : NULL;
    void *isc = is ? dlsym(is, "IOSurfaceCreate") : NULL;
    void *dlg = NULL;
    if (io) dlg = dlsym(io, "CGImageDestinationCreateWithData");
    void *bmp = cg ? dlsym(cg, "CGBitmapContextCreate") : NULL;

    lg("[sym] qc=%p IoSurf=%p CG=%p ImageIO=%p CF=%p", qc, is, cg, io, cf);
    lg("[sym] renderDisplay=%p surfaceCreate=%p bitmapCtx=%p imgDest=%p", rd, isc, bmp, dlg);
}

static void handle_client(int fd) {
    char buf[1024];
    ssize_t n = recv(fd, buf, sizeof(buf)-1, 0);
    if (n <= 0) { close(fd); return; }
    buf[n] = 0;
    lg("[http] %.70s", buf);

    const char *body = "stage1-ok\n";
    char hdr[256];
    int len = (int)strlen(body);
    int hl = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n"
        "Cache-Control: no-store\r\nConnection: close\r\n\r\n", len);
    send(fd, hdr, hl, 0);
    send(fd, body, len, 0);
    close(fd);
}

static void server_main(void) {
    // 关键：等 SpringBoard 启动完成，避免在 dyld 初始化期间 dlopen 导致 load 重入
    sleep(10);
    lg("[svc] thread start uid=%d pid=%d", getuid(), getpid());
    probe_syms();
    lg("[svc] after probe");

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    lg("[svc] socket fd=%d errno=%d", fd, errno);
    if (fd < 0) { return; }
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(kPort);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(fd, (struct sockaddr*)&a, sizeof(a)) != 0) {
        lg("[svc] bind errno=%d", errno); close(fd); return;
    }
    if (listen(fd, 8) != 0) { lg("[svc] listen errno=%d", errno); close(fd); return; }
    lg("[svc] listening 127.0.0.1:%d", kPort);

    for (;;) {
        int c = accept(fd, NULL, NULL);
        if (c < 0) { if (errno == EINTR) continue; lg("[svc] accept errno=%d", errno); break; }
        handle_client(c);
    }
    return;
}

__attribute__((constructor))
static void svc_init(void) {
    FILE *f = fopen("/var/mobile/dsh-min.log", "a");
    if (f) { fprintf(f, "svc-ctor uid=%d pid=%d\n", getuid(), getpid()); fclose(f); }

    // QOS_CLASS_UTILITY = 0x11
    void *q = dispatch_get_global_queue(0x11, 0);
    dispatch_async(q, ^{ server_main(); });
}
