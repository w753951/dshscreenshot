/*
 * DshAppHook —— 进程内 UI 点击（不走 HID）
 *
 * 注入目标 App（plist 里配 Bundles），提供 HTTP：
 *   GET /tap?x=<0..1>&y=<0..1>&key=dsh-go-screen-v1
 *   GET /swipe?...（用 setContentOffset 滚动）
 *   GET /info
 *
 * 原理：在 App 自己的进程里 hitTest 找到视图，然后
 *   - UIControl → sendActionsForControlEvents:UIControlEventTouchUpInside
 *   - UITableViewCell → 调 delegate 的 tableView:didSelectRowAtIndexPath:
 *   - UICollectionViewCell → 调 collectionView:didSelectItemAtIndexPath:
 *   - 其它 → 遍历 gestureRecognizers，触发其 target/action
 * 这是进程内调用，不需要任何系统权限。
 */

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>

#define DSH_PORT 47200
static const char *kKey = "dsh-go-screen-v1";
static const char *kLog = "/var/mobile/dsh-apphook.log";

static void lg(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], s];
    FILE *f = fopen(kLog, "a");
    if (f) { fputs([line UTF8String], f); fclose(f); }
}

#pragma mark - 视图查找

static UIView *dsh_hit(UIWindow *win, CGPoint p) {
    UIView *v = [win hitTest:p withEvent:nil];
    return v;
}

static UITableView *dsh_tableFor(UIView *v) {
    UIView *cur = v;
    while (cur) {
        if ([cur isKindOfClass:[UITableView class]]) return (UITableView *)cur;
        cur = cur.superview;
    }
    return nil;
}

static UICollectionView *dsh_collectionFor(UIView *v) {
    UIView *cur = v;
    while (cur) {
        if ([cur isKindOfClass:[UICollectionView class]]) return (UICollectionView *)cur;
        cur = cur.superview;
    }
    return nil;
}

#pragma mark - 点击

/* 直接调用手势识别器自己的 target/action —— 最贴近真实点击 */
static BOOL dsh_fire_gesture(UIGestureRecognizer *g) {
    if (!g) return NO;
    Ivar iv = class_getInstanceVariable([UIGestureRecognizer class], "_targets");
    if (!iv) return NO;
    NSArray *targets = (NSArray *)object_getIvar((id)g, iv);
    if (![targets isKindOfClass:[NSArray class]] || targets.count == 0) return NO;

    for (id t in targets) {
        Class tc = object_getClass(t);
        Ivar tt = class_getInstanceVariable(tc, "_target");
        Ivar ta = class_getInstanceVariable(tc, "_action");
        if (!tt || !ta) continue;
        id target = object_getIvar(t, tt);
        SEL action = (SEL)(__bridge void *)object_getIvar(t, ta);
        if (target && action && [target respondsToSelector:action]) {
            ((void (*)(id, SEL, id))objc_msgSend)(target, action, g);
            lg(@"fired gesture %@ on %@ -> %@", NSStringFromClass([g class]),
               NSStringFromClass([target class]), NSStringFromSelector(action));
            return YES;
        }
    }
    return NO;
}

/* 收集 cell 里的文字，便于确认点到了哪一行 */
static NSString *dsh_cell_text(UIView *cell) {
    NSMutableArray *parts = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
    int guard = 0;
    while (stack.count && guard++ < 400) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UILabel class]]) {
            NSString *t = ((UILabel *)v).text;
            if (t.length) [parts addObject:t];
        } else if ([v isKindOfClass:[UITextView class]]) {
            NSString *t = ((UITextView *)v).text;
            if (t.length) [parts addObject:t];
        }
        [stack addObjectsFromArray:v.subviews];
    }
    NSString *joined = [parts componentsJoinedByString:@" | "];
    if (joined.length > 80) joined = [joined substringToIndex:80];
    return joined.length ? joined : @"(空)";
}

/* 在整棵子树里找手势并触发 */
static BOOL dsh_fire_gesture_tree(UIView *root, int maxDepth) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count && guard++ < 300) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if ([g isKindOfClass:[UITapGestureRecognizer class]] && dsh_fire_gesture(g)) return YES;
        }
        if (maxDepth > 0) [stack addObjectsFromArray:v.subviews];
    }
    return NO;
}

#pragma mark - 点击位置可视化

static UIWindow *gDotWin = nil;

/* 在目标位置闪一个半透明红圈，0.9 秒消失 */
static void dsh_show_dot(CGPoint p) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gDotWin) {
            gDotWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            gDotWin.windowLevel = 10000001.0;
            gDotWin.userInteractionEnabled = NO;
            gDotWin.backgroundColor = [UIColor clearColor];
        }
        CGFloat R = 20.0;
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(p.x - R, p.y - R, R * 2, R * 2)];
        dot.backgroundColor = [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:0.55];
        dot.layer.cornerRadius = R;
        dot.layer.borderWidth = 2.0;
        dot.layer.borderColor = [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:0.9].CGColor;
        [gDotWin addSubview:dot];
        gDotWin.hidden = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [dot removeFromSuperview];
        });
        lg(@"dot at %.0f,%.0f", p.x, p.y);
    });
}

static NSString *dsh_tap(double nx, double ny) {
    __block NSString *result = @"no-window";
    void (^work)(void) = ^{
        UIWindow *win = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (!win) win = [UIApplication sharedApplication].windows.firstObject;
        if (!win) return;

        CGSize sz = win.bounds.size;
        CGPoint p = CGPointMake(nx * sz.width, ny * sz.height);
        dsh_show_dot(p);
        UIView *v = dsh_hit(win, p);
        if (!v) { result = @"no-view"; return; }
        lg(@"hit %.0f,%.0f -> %@", p.x, p.y, NSStringFromClass([v class]));

        /* 1) 手势优先：从命中视图往上，找 tap 手势并触发它的 target/action */
        UIView *cur = v;
        int depth = 0;
        while (cur && depth < 12) {
            for (UIGestureRecognizer *g in cur.gestureRecognizers) {
                if (![g isKindOfClass:[UITapGestureRecognizer class]]) continue;
                if (!g.enabled) continue;
                if (dsh_fire_gesture(g)) {
                    result = [NSString stringWithFormat:@"gesture:%@", NSStringFromClass([g class])];
                    return;
                }
            }
            cur = cur.superview;
            depth++;
        }

        /* 2) UIControl：sendActions */
        cur = v;
        while (cur) {
            if ([cur isKindOfClass:[UIControl class]]) {
                [(UIControl *)cur sendActionsForControlEvents:UIControlEventTouchUpInside];
                result = [NSString stringWithFormat:@"control:%@", NSStringFromClass([cur class])];
                return;
            }
            cur = cur.superview;
        }

        /* 3) 列表：优先 cell 内部手势，再 selectRow + delegate；同时回传会话名 */
        cur = v;
        while (cur) {
            if ([cur isKindOfClass:[UITableViewCell class]] || [cur isKindOfClass:[UICollectionViewCell class]]) {
                NSString *txt = dsh_cell_text(cur);
                /* 3a) cell 子树上的手势 */
                if (dsh_fire_gesture_tree(cur, 8)) {
                    result = [NSString stringWithFormat:@"cell-gesture:%@", txt];
                    return;
                }
                /* 3b) selectRow + delegate */
                if ([cur isKindOfClass:[UITableViewCell class]]) {
                    UITableView *tv = dsh_tableFor(cur);
                    NSIndexPath *ip = tv ? [tv indexPathForCell:(UITableViewCell *)cur] : nil;
                    if (tv && ip) {
                        [tv selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone];
                        id<UITableViewDelegate> del = tv.delegate;
                        if ([del respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                            [del tableView:tv didSelectRowAtIndexPath:ip];
                        }
                        result = [NSString stringWithFormat:@"table-row:%@", txt];
                        return;
                    }
                } else {
                    UICollectionView *cv = dsh_collectionFor(cur);
                    NSIndexPath *ip = cv ? [cv indexPathForCell:(UICollectionViewCell *)cur] : nil;
                    if (cv && ip) {
                        [cv selectItemAtIndexPath:ip animated:NO scrollPosition:UICollectionViewScrollPositionNone];
                        id<UICollectionViewDelegate> del = cv.delegate;
                        if ([del respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                            [del collectionView:cv didSelectItemAtIndexPath:ip];
                        }
                        result = [NSString stringWithFormat:@"collection-item:%@", txt];
                        return;
                    }
                }
            }
            cur = cur.superview;
        }

        /* 4) 任意手势兜底（非 tap 的也试一遍） */
        cur = v;
        depth = 0;
        while (cur && depth < 12) {
            for (UIGestureRecognizer *g in cur.gestureRecognizers) {
                if (dsh_fire_gesture(g)) {
                    result = [NSString stringWithFormat:@"gesture-any:%@", NSStringFromClass([g class])];
                    return;
                }
            }
            cur = cur.superview;
            depth++;
        }

        result = [NSString stringWithFormat:@"no-action:%@", NSStringFromClass([v class])];
    };

    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
    return result;
}

#pragma mark - HTTP

static void reply(int fd, int code, const char *reason, const char *ctype, const char *body) {
    char hdr[256];
    size_t n = strlen(body);
    int hl = snprintf(hdr, sizeof(hdr),
                      "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n",
                      code, reason, ctype, n);
    send(fd, hdr, hl, 0);
    send(fd, body, n, 0);
}

static double qnum(const char *req, const char *name, double def) {
    char pat[32]; snprintf(pat, sizeof(pat), "%s=", name);
    const char *p = strstr(req, pat);
    return p ? atof(p + strlen(pat)) : def;
}

/* 所有可见 UITableView / UICollectionView */
static NSArray *dsh_all_tables(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
        int g = 0;
        while (stack.count && g++ < 3000) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if ([v isKindOfClass:[UITableView class]] || [v isKindOfClass:[UICollectionView class]]) {
                [out addObject:v];
            }
            [stack addObjectsFromArray:v.subviews];
        }
    }
    return out;
}

/* 列出可见行：section-row | 文本 */
static NSString *dsh_list(void) {
    __block NSString *out = @"";
    void (^work)(void) = ^{
        NSMutableString *s = [NSMutableString string];
        for (id tv in dsh_all_tables()) {
            if ([tv isKindOfClass:[UITableView class]]) {
                UITableView *t = tv;
                for (UITableViewCell *c in t.visibleCells) {
                    NSIndexPath *ip = [t indexPathForCell:c];
                    if (!ip) continue;
                    [s appendFormat:@"%ld-%ld | %@\n", (long)ip.section, (long)ip.row, dsh_cell_text(c)];
                }
            } else {
                UICollectionView *t = tv;
                for (UICollectionViewCell *c in t.visibleCells) {
                    NSIndexPath *ip = [t indexPathForCell:c];
                    if (!ip) continue;
                    [s appendFormat:@"%ld-%ld | %@\n", (long)ip.section, (long)ip.item, dsh_cell_text(c)];
                }
            }
        }
        out = s.length ? s : @"(empty)";
    };
    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
    return out;
}

/* 按 indexPath 点一行 */
static NSString *dsh_tap_row(long sec, long row) {
    __block NSString *out = @"not-found";
    void (^work)(void) = ^{
        NSIndexPath *want = [NSIndexPath indexPathForRow:row inSection:sec];
        for (id tv in dsh_all_tables()) {
            if ([tv isKindOfClass:[UITableView class]]) {
                UITableView *t = tv;
                if (row < (long)[t numberOfRowsInSection:sec]) {
                    [t selectRowAtIndexPath:want animated:NO scrollPosition:UITableViewScrollPositionNone];
                    id<UITableViewDelegate> del = t.delegate;
                    if ([del respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                        [del tableView:t didSelectRowAtIndexPath:want];
                    }
                    UITableViewCell *c = [t cellForRowAtIndexPath:want];
                    out = [NSString stringWithFormat:@"row:%@", c ? dsh_cell_text(c) : @"?"];
                    return;
                }
            } else {
                UICollectionView *t = tv;
                NSIndexPath *wantI = [NSIndexPath indexPathForItem:row inSection:sec];
                if (row < (long)[t numberOfItemsInSection:sec]) {
                    [t selectItemAtIndexPath:wantI animated:NO scrollPosition:UICollectionViewScrollPositionNone];
                    id<UICollectionViewDelegate> del = t.delegate;
                    if ([del respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                        [del collectionView:t didSelectItemAtIndexPath:wantI];
                    }
                    UICollectionViewCell *c = [t cellForItemAtIndexPath:wantI];
                    out = [NSString stringWithFormat:@"item:%@", c ? dsh_cell_text(c) : @"?"];
                    return;
                }
            }
        }
    };
    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
    return out;
}

static void handle(int fd) {
    char buf[1536];
    ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) { close(fd); return; }
    buf[n] = 0;
    if (!strstr(buf, kKey)) { reply(fd, 403, "Forbidden", "text/plain", "no key"); close(fd); return; }

    char out[2048] = {0};
    if (strstr(buf, "GET /list")) {
        NSString *r = dsh_list();
        snprintf(out, sizeof(out), "%s", [r UTF8String]);
    } else if (strstr(buf, "GET /tap_row")) {
        long s = (long)qnum(buf, "s", 0), r = (long)qnum(buf, "r", 0);
        NSString *res = dsh_tap_row(s, r);
        snprintf(out, sizeof(out), "%s", [res UTF8String]);
    } else if (strstr(buf, "GET /tap")) {
        NSString *r = dsh_tap(qnum(buf, "x", 0.5), qnum(buf, "y", 0.5));
        snprintf(out, sizeof(out), "%s", [r UTF8String]);
    } else if (strstr(buf, "GET /info")) {
        snprintf(out, sizeof(out), "pid=%d windows=%lu", getpid(),
                 (unsigned long)[UIApplication sharedApplication].windows.count);
    } else {
        reply(fd, 400, "Bad Request", "text/plain", "bad");
        close(fd);
        return;
    }
    reply(fd, 200, "OK", "text/plain", out);
    lg(@"http -> %s", out);
    close(fd);
}

static void *server(void *arg) {
    (void)arg;
    sleep(3);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NULL;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET; a.sin_port = htons(DSH_PORT); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { lg(@"bind fail errno=%d", errno); close(fd); return NULL; }
    listen(fd, 8);
    lg(@"listening %d pid=%d", DSH_PORT, getpid());
    for (;;) {
        int c = accept(fd, NULL, NULL);
        if (c >= 0) handle(c);
    }
    return NULL;
}

__attribute__((constructor))
static void apphook_init(void) {
    lg(@"ctor pid=%d bundle=%@", getpid(), [[NSBundle mainBundle] bundleIdentifier]);
    pthread_t th; pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_create(&th, &at, server, NULL);
    pthread_attr_destroy(&at);
}
