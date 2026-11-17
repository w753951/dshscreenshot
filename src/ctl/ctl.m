/*
 * dshctl —— DSH Go 手机操控服务（arm64 CLI / 常驻守护）
 *
 * 设计目标：不再依赖 dshtool 那种「一次 dispatch 一个事件」的做法，
 * 而是按真实手指动作序列发事件：down → (move…) → up，每个事件独立 dispatch。
 *
 * 用法：
 *   dshctl tap   X Y [ms]                 点击（pt 坐标）
 *   dshctl swipe X1 Y1 X2 Y2 [ms]         滑动
 *   dshctl text  "ASCII 文本"             键盘注入（仅 ASCII，中文走剪贴板）
 *   dshctl launch com.tencent.xin         启动 App
 *   dshctl home                           回主屏（锁屏键语义）
 *   dshctl daemon [port]                  常驻，HTTP 控制面（默认 47192）
 *   dshctl info                           符号自检
 *
 * HTTP（daemon 模式，仅回环）：
 *   GET /tap?x=214&y=272&ms=80
 *   GET /swipe?x1=214&y1=700&x2=214&y2=420&ms=350
 *   GET /text?t=hello
 *   GET /launch?b=com.tencent.xin
 *   GET /home
 *   GET /info
 *
 * 编译（Linux + theos SDK，arm64 走 lld 即可）：
 *   clang -target arm64-apple-ios15.0 -isysroot iPhoneOS13.7.sdk -O2 \
 *         -framework CoreFoundation -framework IOKit \
 *         -o dshctl src/ctl/ctl.m
 *   设备上：ldid -S/var/jb/xina/entitlements_xina.xml dshctl
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>

/* ---------- IOKit 私有符号 ---------- */
typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDEventRef;
typedef float IOHIDFloat;
typedef uint64_t DshTime;   /* mach_absolute_time() 的返回类型 */

enum {
    EV_RANGE = 1 << 0,
    EV_TOUCH = 1 << 1,
    EV_POS   = 1 << 2,
};

static IOHIDEventSystemClientRef gClient;
static IOHIDEventRef (*pFinger)(CFAllocatorRef, DshTime, uint32_t, uint32_t, uint32_t,
                                uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                IOHIDFloat, Boolean, Boolean, CFOptionFlags);
static IOHIDEventRef (*pDigitizer)(CFAllocatorRef, DshTime, uint32_t, uint32_t, uint32_t,
                                   uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                   IOHIDFloat, Boolean, Boolean, CFOptionFlags);
static IOHIDEventSystemClientRef (*pCreate)(CFAllocatorRef);
static void (*pSetProp)(IOHIDEventSystemClientRef, CFStringRef, CFTypeRef);
static void (*pDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
static void (*pAppend)(IOHIDEventRef, IOHIDEventRef);
static IOHIDEventRef (*pKey)(CFAllocatorRef, DshTime, uint32_t usage, Boolean down, CFOptionFlags opts);

static void *find(const char *n) {
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

static int init_hid(void) {
    pFinger    = (void *)find("IOHIDEventCreateDigitizerFingerEvent");
    pDigitizer = (void *)find("IOHIDEventCreateDigitizerEvent");
    pCreate    = (void *)find("IOHIDEventSystemClientCreate");
    pSetProp   = (void *)find("IOHIDEventSystemClientSetProperty");
    pDispatch  = (void *)find("IOHIDEventSystemClientDispatchEvent");
    pAppend    = (void *)find("IOHIDEventAppendEvent");
    pKey       = (void *)find("IOHIDEventCreateKeyboardEvent");
    if (!pCreate || !pDispatch || (!pFinger && !pDigitizer)) return 0;
    gClient = pCreate(kCFAllocatorDefault);
    if (!gClient) return 0;
    if (pSetProp) pSetProp(gClient, CFSTR("AllowInstrumentation"), kCFBooleanTrue);
    return 1;
}

static void msleep(int ms) { if (ms > 0) usleep((useconds_t)ms * 1000); }

/* 发一次触摸：必须 hand 事件 + append finger 子事件，单独 finger 会被系统忽略 */
static void send_touch(int phase, double x, double y, uint32_t ident) {
    uint32_t mask; Boolean range, touch;
    if (phase == 2) { mask = EV_RANGE | EV_TOUCH;          range = 0; touch = 0; }
    else            { mask = EV_RANGE | EV_TOUCH | EV_POS; range = 1; touch = 1; }

    DshTime ts = mach_absolute_time();
    IOHIDEventRef finger = NULL;
    if (pFinger)
        finger = pFinger(kCFAllocatorDefault, ts, 0, ident, mask, 0,
                         (IOHIDFloat)x, (IOHIDFloat)y, 0.0f, 1.0f, 0.0f, range, touch, 0);
    if (!finger && pDigitizer)
        finger = pDigitizer(kCFAllocatorDefault, ts, 2 /*finger*/, 0, ident, mask, 0,
                            (IOHIDFloat)x, (IOHIDFloat)y, 0.0f, 1.0f, 0.0f, range, touch, 0);
    if (!finger) return;

    if (pDigitizer && pAppend) {
        IOHIDEventRef hand = pDigitizer(kCFAllocatorDefault, ts, 3 /*hand*/, 0, ident,
                                        EV_RANGE | EV_TOUCH, 0,
                                        0.0f, 0.0f, 0.0f, 0.0f, 0.0f, range, 0, 0);
        if (hand) { pAppend(hand, finger); pDispatch(gClient, hand); return; }
    }
    pDispatch(gClient, finger);
}

static int do_tap(double x, double y, int ms) {
    uint32_t id = 0x1001;
    send_touch(0, x, y, id);
    msleep(ms);
    send_touch(2, x, y, id);
    return 0;
}

static int do_swipe(double x1, double y1, double x2, double y2, int ms) {
    uint32_t id = 0x1002;
    const int steps = 18;
    int step_ms = ms / steps; if (step_ms < 1) step_ms = 1;
    send_touch(0, x1, y1, id);
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / steps;
        send_touch(1, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, id);
        msleep(step_ms);
    }
    send_touch(2, x2, y2, id);
    return 0;
}

/* ASCII → USB HID usage（不是直接拿 ASCII 当 usage） */
static uint32_t hid_usage(unsigned char c, Boolean *shift) {
    *shift = false;
    if (c >= 'a' && c <= 'z') return 0x04 + (uint32_t)(c - 'a');
    if (c >= 'A' && c <= 'Z') { *shift = true; return 0x04 + (uint32_t)(c - 'A'); }
    if (c >= '1' && c <= '9') return 0x1e + (uint32_t)(c - '1');
    if (c == '0') return 0x27;
    if (c == ' ') return 0x2c;
    if (c == '.') return 0x37;
    if (c == ',') return 0x36;
    if (c == '-') return 0x2d;
    if (c == '/') return 0x38;
    if (c == '@') { *shift = true; return 0x1f; }
    if (c == '?') { *shift = true; return 0x38; }
    return 0;   /* 未知字符跳过 */
}

/* 仅 ASCII：用键盘 HID 事件 */
static int do_text(const char *s) {
    if (!pKey || !pDispatch) return 5;
    for (const char *p = s; *p; p++) {
        Boolean shift = false;
        uint32_t code = hid_usage((unsigned char)*p, &shift);
        if (!code) continue;
        IOHIDEventRef d = pKey(kCFAllocatorDefault, mach_absolute_time(), code, true, 0);
        if (d) pDispatch(gClient, d);
        msleep(12);
        IOHIDEventRef u = pKey(kCFAllocatorDefault, mach_absolute_time(), code, false, 0);
        if (u) pDispatch(gClient, u);
        msleep(12);
    }
    return 0;
}

/* 启动 App：LSApplicationWorkspace */
static int do_launch(const char *bundle) {
    void *h = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    if (!h) h = dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    if (!h) return 6;
    void *(*objc_getClass_)(const char *) = dlsym(dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY), "objc_getClass");
    void *(*selReg)(const char *) = dlsym(dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY), "sel_registerName");
    void *(*msgSend)(void *, void *, ...) = dlsym(dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY), "objc_msgSend");
    if (!objc_getClass_ || !selReg || !msgSend) return 7;
    void *cls = objc_getClass_("LSApplicationWorkspace");
    void *ws = msgSend(cls, selReg("defaultWorkspace"));
    if (!ws) return 8;
    void *str = msgSend(objc_getClass_("NSString"), selReg("stringWithUTF8String:"), bundle);
    int ok = (int)(long)msgSend(ws, selReg("openApplicationWithBundleID:"), str);
    return ok ? 0 : 9;
}

/* ---------- daemon ---------- */
static const char *kKey = "dsh-go-screen-v1";

static double q(const char *req, const char *name, double def) {
    char pat[64]; snprintf(pat, sizeof(pat), "%s=", name);
    const char *p = strstr(req, pat);
    if (!p) return def;
    return atof(p + strlen(pat));
}
static void qs(const char *req, const char *name, char *out, size_t n) {
    char pat[64]; snprintf(pat, sizeof(pat), "%s=", name);
    const char *p = strstr(req, pat);
    if (!p) { out[0] = 0; return; }
    p += strlen(pat);
    size_t i = 0;
    while (*p && *p != '&' && *p != ' ' && i + 1 < n) out[i++] = *p++;
    out[i] = 0;
}
static void send_all(int fd, const char *s) { send(fd, s, strlen(s), 0); }

static void handle(int fd) {
    char buf[2048]; ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) { close(fd); return; }
    buf[n] = 0;
    if (!strstr(buf, kKey)) { send_all(fd, "HTTP/1.1 403 Forbidden\r\nContent-Length: 6\r\n\r\nno key"); close(fd); return; }

    char body[256] = {0};
    if (strstr(buf, "GET /tap")) {
        double x = q(buf, "x", 0), y = q(buf, "y", 0);
        int ms = (int)q(buf, "ms", 80);
        int rc = do_tap(x, y, ms);
        snprintf(body, sizeof(body), "tap %.0f,%.0f rc=%d", x, y, rc);
    } else if (strstr(buf, "GET /swipe")) {
        int rc = do_swipe(q(buf, "x1", 0), q(buf, "y1", 0), q(buf, "x2", 0), q(buf, "y2", 0), (int)q(buf, "ms", 300));
        snprintf(body, sizeof(body), "swipe rc=%d", rc);
    } else if (strstr(buf, "GET /text")) {
        char t[256]; qs(buf, "t", t, sizeof(t));
        int rc = do_text(t);
        snprintf(body, sizeof(body), "text rc=%d", rc);
    } else if (strstr(buf, "GET /launch")) {
        char b[256]; qs(buf, "b", b, sizeof(b));
        int rc = do_launch(b);
        snprintf(body, sizeof(body), "launch %s rc=%d", b, rc);
    } else if (strstr(buf, "GET /home")) {
        int rc = do_launch("com.apple.springboard");
        snprintf(body, sizeof(body), "home rc=%d", rc);
    } else if (strstr(buf, "GET /info")) {
        snprintf(body, sizeof(body), "client=%p finger=%p dispatch=%p key=%p",
                 (void *)gClient, (void *)pFinger, (void *)pDispatch, (void *)pKey);
    } else {
        send_all(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 3\r\n\r\nbad"); close(fd); return;
    }
    char hdr[256];
    int hl = snprintf(hdr, sizeof(hdr),
                      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n",
                      strlen(body));
    send(fd, hdr, hl, 0);
    send_all(fd, body);
    close(fd);
}

static int run_daemon(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 10;
    int on = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET; a.sin_port = htons(port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { close(fd); return 11; }
    if (listen(fd, 8) != 0) { close(fd); return 12; }
    for (;;) {
        int c = accept(fd, NULL, NULL);
        if (c < 0) { if (errno == EINTR) continue; break; }
        handle(c);
    }
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 2) {
        fprintf(stderr, "usage: dshctl tap X Y [ms] | swipe X1 Y1 X2 Y2 [ms] | text STR | launch BUNDLE | home | daemon [port] | info\n");
        return 2;
    }
    if (!init_hid()) { fprintf(stderr, "hid init failed\n"); return 4; }

    if (!strcmp(argv[1], "info")) {
        printf("client=%p finger=%p digitizer=%p dispatch=%p key=%p\n",
               (void *)gClient, (void *)pFinger, (void *)pDigitizer, (void *)pDispatch, (void *)pKey);
        return 0;
    }
    if (!strcmp(argv[1], "tap") && argc >= 4) {
        int ms = argc >= 5 ? atoi(argv[4]) : 80;
        printf("tap rc=%d\n", do_tap(atof(argv[2]), atof(argv[3]), ms));
        return 0;
    }
    if (!strcmp(argv[1], "swipe") && argc >= 6) {
        int ms = argc >= 7 ? atoi(argv[6]) : 300;
        printf("swipe rc=%d\n", do_swipe(atof(argv[2]), atof(argv[3]), atof(argv[4]), atof(argv[5]), ms));
        return 0;
    }
    if (!strcmp(argv[1], "text") && argc >= 3) { printf("text rc=%d\n", do_text(argv[2])); return 0; }
    if (!strcmp(argv[1], "launch") && argc >= 3) { printf("launch rc=%d\n", do_launch(argv[2])); return 0; }
    if (!strcmp(argv[1], "home")) { printf("home rc=%d\n", do_launch("com.apple.springboard")); return 0; }
    if (!strcmp(argv[1], "daemon")) { return run_daemon(argc >= 3 ? atoi(argv[2]) : 47192); }

    fprintf(stderr, "bad args\n");
    return 2;
}
