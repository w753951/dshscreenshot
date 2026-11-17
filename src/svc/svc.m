// svc.m —— SpringBoard 截图服务（真 arm64e）
// GET http://127.0.0.1:47191/capture?key=dsh-go-screen-v1 -> image/png
//
// 抓屏用 UIKit 私有 C 函数 __UICreateScreenUIImageWithRotation
// （与越狱插件 Snapper3 完全相同的 API，已确认该符号存在于本机）

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

static const int  kPort = 47191;
static const char *kKey = "dsh-go-screen-v1";
static const char *kLog = "/var/mobile/dsh-screen-plugin.log";

static void lg(const char *fmt, ...) {
    FILE *f = fopen(kLog, "a");
    if (!f) return;
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fclose(f);
}

/* 取屏幕 PNG（malloc，调用方 free） */
static unsigned char *capture_png(size_t *outLen) {
    *outLen = 0;

    void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
    lg("[cap] UIKit=%p", uikit);
    if (!uikit) return NULL;

    void *(*createScreen)(int)  = dlsym(uikit, "__UICreateScreenUIImageWithRotation");
    void *(*createScreen2)(int) = dlsym(uikit, "_UICreateScreenUIImageWithRotation");
    void *(*pngRep)(void *)     = dlsym(uikit, "UIImagePNGRepresentation");
    lg("[cap] createScreen=%p alt=%p pngRep=%p",
       (void*)createScreen, (void*)createScreen2, (void*)pngRep);

    void *img = NULL;
    if (createScreen)       img = createScreen(1);
    else if (createScreen2) img = createScreen2(1);
    lg("[cap] image=%p", img);
    if (!img) { lg("[cap] no image"); return NULL; }
    if (!pngRep) { lg("[cap] no pngRep"); return NULL; }

    void *data = pngRep(img);
    lg("[cap] nsdata=%p", data);
    if (!data) { lg("[cap] no data"); return NULL; }

    void *cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
    const void *(*getBytes)(void*) = cf ? dlsym(cf, "CFDataGetBytePtr") : NULL;
    long (*getLen)(void*)          = cf ? dlsym(cf, "CFDataGetLength") : NULL;
    if (!getBytes || !getLen) { lg("[cap] CFData syms missing"); return NULL; }

    long len = getLen(data);
    const void *b = getBytes(data);
    lg("[cap] png len=%ld", len);
    if (len <= 8 || !b) return NULL;

    unsigned char *out = malloc((size_t)len);
    if (!out) return NULL;
    memcpy(out, b, (size_t)len);
    *outLen = (size_t)len;
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
