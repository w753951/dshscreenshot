// svc.m —— SpringBoard 截图服务（真 arm64e）
// GET http://127.0.0.1:47191/capture?key=dsh-go-screen-v1 -> image/png
//
// 抓屏策略：用 IOHID 模拟「电源键 + 音量上」组合键，走系统自带截图流程，
// 系统会把 PNG 存进 DCIM，我们再读回来。
// 这条路与你手动按键截图完全一致，成功率最高。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <dirent.h>
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

/* ---------- IOKit HID ---------- */
static void *(*p_clientCreate)(const void*);
static void  (*p_clientDispatch)(void*, void*);
static int   (*p_clientSetProp)(void*, const void*, const void*);
static void *(*p_kbdEvent)(const void*, unsigned long long, unsigned, unsigned, int, unsigned);
static void *(*p_eventCreate)(unsigned, unsigned, int);

/* 在 DCIM 里找最新 PNG 文件名（不含路径），失败返回 0 */
static void newest_png(char *out, size_t cap) {
    out[0] = 0;
    const char *dirs[] = {
        "/var/mobile/Media/DCIM/125APPLE",
        "/var/mobile/Media/DCIM/124APPLE",
        "/var/mobile/Media/DCIM/100APPLE",
        NULL
    };
    for (int d = 0; dirs[d]; d++) {
        DIR *dp = opendir(dirs[d]);
        if (!dp) continue;
        struct dirent *e;
        while ((e = readdir(dp)) != NULL) {
            size_t L = strlen(e->d_name);
            if (L < 5) continue;
            if (!(strstr(e->d_name, ".PNG") || strstr(e->d_name, ".png"))) continue;
            if (out[0] == 0 || strcmp(e->d_name, out) > 0) {
                snprintf(out, cap, "%s", e->d_name);
            }
        }
        closedir(dp);
    }
}

/* 在 DCIM 里拼出完整路径 */
static int find_path(const char *name, char *out, size_t cap) {
    const char *dirs[] = {
        "/var/mobile/Media/DCIM/125APPLE",
        "/var/mobile/Media/DCIM/124APPLE",
        "/var/mobile/Media/DCIM/100APPLE",
        NULL
    };
    for (int d = 0; dirs[d]; d++) {
        snprintf(out, cap, "%s/%s", dirs[d], name);
        if (access(out, R_OK) == 0) return 1;
    }
    return 0;
}

static int load_hid(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    lg("[hid] IOKit=%p", iokit);
    if (!iokit) return 0;

    p_clientCreate   = dlsym(iokit, "IOHIDEventSystemClientCreate");
    p_clientDispatch = dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");
    p_clientSetProp  = dlsym(iokit, "IOHIDEventSystemClientSetProperty");
    p_kbdEvent       = dlsym(iokit, "IOHIDEventCreateKeyboardEvent");
    p_eventCreate    = dlsym(iokit, "IOHIDEventCreate");

    lg("[hid] clientCreate=%p dispatch=%p kbdEvent=%p",
       (void*)p_clientCreate, (void*)p_clientDispatch, (void*)p_kbdEvent);
    return p_clientCreate && p_clientDispatch && p_kbdEvent;
}

/* 派发一个按键事件：page/usage, down=1按下
 * 用 IOHIDEventCreateKeyboardEvent，然后交给 HID system client 派发 */
static void send_key(void *client, unsigned page, unsigned usage, int down) {
    if (!p_kbdEvent || !client) return;
    /* (allocator, timestamp, usagePage, usage, down, options) */
    void *ev = p_kbdEvent(NULL, 0, page, usage, down ? 1 : 0, 0);
    if (!ev) { lg("[hid] event null page=0x%x usage=0x%x", page, usage); return; }
    p_clientDispatch(client, ev);
}

/* 模拟「电源 + 音量上」截图组合键 */
static int trigger_screenshot(void) {
    if (!p_clientCreate) { lg("[hid] not loaded"); return 0; }
    void *client = p_clientCreate(NULL);
    lg("[hid] client=%p", client);
    if (!client) return 0;

    /* AllowInstrumentation 让 client 能派发事件 */
    void *cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
    void *(*boolOf)(int) = cf ? dlsym(cf, "CFBooleanGetValue") : NULL;
    const void *kTrue = (cf ? dlsym(cf, "kCFBooleanTrue") : NULL);
    (void)boolOf; (void)kTrue;

    if (p_clientSetProp && cf) {
        const void *kbn = (const void *)dlsym(cf, "kCFBooleanTrue");
        if (kbn) {
            CFStringRef (*mkstr)(const void*, const char*, unsigned) = dlsym(cf, "CFStringCreateWithCString");
            if (mkstr) {
                const void *key = mkstr(NULL, "AllowInstrumentation", 0x08000100);
                p_clientSetProp(client, key, kbn);
                lg("[hid] AllowInstrumentation set");
            }
        }
    }

    /* Consumer page = 0x0C；Power = 0x30；Volume Increment = 0xE9 */
    const unsigned PAGE = 0x0C, POWER = 0x30, VOLUP = 0xE9;

    lg("[hid] press power");
    send_key(client, PAGE, POWER, 1);
    usleep(20000);
    lg("[hid] press volup");
    send_key(client, PAGE, VOLUP, 1);
    usleep(60000);
    lg("[hid] release volup");
    send_key(client, PAGE, VOLUP, 0);
    usleep(20000);
    lg("[hid] release power");
    send_key(client, PAGE, POWER, 0);

    return 1;
}

// ---- HTTP ----
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

static unsigned char *capture_png(size_t *outLen) {
    *outLen = 0;

    char base[256] = {0};
    newest_png(base, sizeof(base));
    lg("[cap] baseline=%s", base);

    if (!trigger_screenshot()) { lg("[cap] trigger failed"); return NULL; }

    char now[256] = {0};
    char path[512] = {0};
    int found = 0;
    for (int i = 0; i < 50; i++) {
        usleep(100000);
        now[0] = 0;
        newest_png(now, sizeof(now));
        if (now[0] && strcmp(now, base) != 0) {
            if (find_path(now, path, sizeof(path))) { found = 1; break; }
        }
    }
    if (!found) { lg("[cap] no new file after 5s"); return NULL; }
    lg("[cap] new file %s", path);

    FILE *fp = fopen(path, "rb");
    if (!fp) { lg("[cap] open fail"); return NULL; }
    fseek(fp, 0, SEEK_END);
    long len = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (len <= 0) { fclose(fp); return NULL; }
    unsigned char *buf = malloc((size_t)len);
    if (buf && fread(buf, 1, (size_t)len, fp) != (size_t)len) { free(buf); buf = NULL; }
    fclose(fp);
    if (buf) { *outLen = (size_t)len; lg("[cap] png %zu bytes", *outLen); }
    return buf;
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
    int hidok = load_hid();
    lg("[svc] hid ready=%d", hidok);

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
