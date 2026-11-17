/*
 * DshAppHook —— 进程内 UI 操作（不走 HID）
 *
 * 注入目标 App（plist 里配 WBundles），提供 HTTP 服务：
 *
 *   GET /info                                  pid / windows
 *   GET /list                                  列出可见行：section-row | 文本
 *   GET /tree?all=1                            视图树：depth|class|x,y,w,h|可点|文本
 *   GET /tap?x=<0..1>&y=<0..1>[&mode=N]        归一化坐标点击（红圈可视化）
 *   GET /tap_row?s=&r=                         按 indexPath 点行（零坐标）
 *   GET /type?text=你好                        往当前输入框写文字
 *   GET /press?title=发送                      按标题触发 UIButton
 *   GET /scroll?dy=<pt>                         直接改 contentOffset 滚动
 *   GET /scrollTo?text=神奇[&dy=]               滚动直到目标行出现（找不到就翻页找死循环上限 12 次）
 *
 * 为什么不用 IOHIDEvent：
 *   iOS 15 + XinaA15 上，从 root CLI / App 进程用 IOHIDEventSystemClient 派发事件，
 *   返回 rc=0 但界面零反应（连 dshctl home 都不回主屏），senderID / backboard 路由被拦。
 *   只有「进程内直接调用 UIKit」才生效，这也是唯一稳的路。
 *
 * 红点：以前用独立 UIWindow(windowLevel=1e7)，iOS 13+ 多 scene 下没 bind windowScene
 *   就根本不显示。现在改成挂到当前 keyWindow 最上层，tag=0xD5D0，0.9 秒自消。
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

static void onMain(void (^blk)(void)) {
    if ([NSThread isMainThread]) blk();
    else dispatch_sync(dispatch_get_main_queue(), blk);
}

#pragma mark - window

static UIWindow *dsh_window(void) {
    {
        UIWindow *big = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            NSString *cls = NSStringFromClass([w class]);
            if ([cls containsString:@"Keyboard"]) continue;
            if (w.hidden || w.alpha < 0.01) continue;
            if (!big || w.bounds.size.height > big.bounds.size.height) big = w;
        }
        if (big) return big;
    }
    /* 键盘弹出时 keyWindow 会变成键盘窗口（高度只有 300 多），先取「最高的非键盘窗口」 */
    {
        UIWindow *big = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.hidden || w.alpha < 0.01) continue;
            if (w.bounds.size.height < 700) continue;
            if (!big || w.bounds.size.height > big.bounds.size.height) big = w;
        }
        if (big) return big;
    }
    UIApplication *app = [UIApplication sharedApplication];
    for (UIWindow *w in app.windows) {
        if (w.isKeyWindow && !w.isHidden && w.alpha > 0.01) return w;
    }
    UIWindow *best = nil;
    for (UIWindow *w in app.windows) {
        if (w.isHidden || w.alpha < 0.01) continue;
        if (w.bounds.size.width <= 1) continue;
        if (!best || w.windowLevel >= best.windowLevel) best = w;
    }
    if (best) return best;
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) return w;
            if (!best) best = w;
        }
    }
    return best ?: app.windows.firstObject;
}

#pragma mark - 文本

static NSString *dsh_view_text(UIView *v) {
    NSString *t = nil;
    if ([v isKindOfClass:[UILabel class]]) {
        t = ((UILabel *)v).text;
    } else if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        t = [b titleForState:UIControlStateNormal] ?: b.currentTitle;
    } else if ([v isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)v;
        t = tf.text.length ? tf.text : tf.placeholder;
    } else if ([v isKindOfClass:[UITextView class]]) {
        t = ((UITextView *)v).text;
    }
    if (!t.length) {
        NSArray *keys = @[@"text", @"title", @"attributedText"];
        for (NSString *k in keys) {
            if (![v respondsToSelector:NSSelectorFromString(k)]) continue;
            @try {
                id o = [v valueForKey:k];
                if ([o isKindOfClass:[NSString class]] && [o length]) { t = o; break; }
                if ([o isKindOfClass:[NSAttributedString class]] && [o length]) { t = [o string]; break; }
            } @catch (__unused NSException *e) {}
        }
    }
    return t;
}

static NSArray *dsh_all_windows(void) {
    return [UIApplication sharedApplication].windows ?: @[];
}

/* 所有可见 UITableView / UICollectionView */
static NSArray *dsh_all_tables(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIWindow *w in dsh_all_windows()) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
        int g = 0;
        while (stack.count && g++ < 4000) {
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

/* cell 里的文字，用 | 连起来，截到 100 字 */
static NSString *dsh_cell_text(UIView *cell) {
    NSMutableArray *parts = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
    int guard = 0;
    while (stack.count && guard++ < 500) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        NSString *t = dsh_view_text(v);
        if (t.length) [parts addObject:t];
        [stack addObjectsFromArray:v.subviews];
    }
    NSString *joined = [parts componentsJoinedByString:@" | "];
    if (joined.length > 100) joined = [joined substringToIndex:100];
    return joined.length ? joined : @"(空)";
}

#pragma mark - 红圈

static void dsh_dot(CGPoint p) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = dsh_window();
        if (!win) return;
        [[win viewWithTag:0xD5D0] removeFromSuperview];
        CGFloat R = 22.0;
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(p.x - R, p.y - R, R * 2, R * 2)];
        dot.tag = 0xD5D0;
        dot.userInteractionEnabled = NO;
        dot.backgroundColor = [UIColor colorWithRed:1.0 green:0.1 blue:0.15 alpha:0.45];
        dot.layer.cornerRadius = R;
        dot.layer.borderWidth = 3.0;
        dot.layer.borderColor = [UIColor colorWithRed:1.0 green:0.1 blue:0.15 alpha:0.95].CGColor;
        [win addSubview:dot];
        lg(@"dot %.0f,%.0f on %@", p.x, p.y, NSStringFromClass([win class]));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [dot removeFromSuperview]; });
    });
}

#pragma mark - 手势

static BOOL dsh_fire_gesture(UIGestureRecognizer *g) {
    if (!g) return NO;
    Ivar iv = class_getInstanceVariable([UIGestureRecognizer class], "_targets");
    if (!iv) return NO;
    NSArray *targets = (NSArray *)object_getIvar((id)g, iv);
    if (![targets isKindOfClass:[NSArray class]] || !targets.count) return NO;

    for (id t in targets) {
        Class tc = object_getClass(t);
        Ivar tt = class_getInstanceVariable(tc, "_target");
        Ivar ta = class_getInstanceVariable(tc, "_action");
        if (!tt || !ta) continue;
        id target = object_getIvar(t, tt);
        SEL action = (SEL)(__bridge void *)object_getIvar(t, ta);
        if (target && action && [target respondsToSelector:action]) {
            ((void (*)(id, SEL, id))objc_msgSend)(target, action, g);
            return YES;
        }
    }
    return NO;
}

static BOOL dsh_fire_gesture_tree(UIView *root, int maxDepth) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count && guard++ < 400) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if ([g isKindOfClass:[UITapGestureRecognizer class]] && dsh_fire_gesture(g)) return YES;
        }
        if (maxDepth > 0) [stack addObjectsFromArray:v.subviews];
    }
    return NO;
}

#pragma mark - 点击

static NSString *dsh_tap(double nx, double ny) {
    __block NSString *result = @"no-window";
    onMain(^{
        UIWindow *win = dsh_window();
        if (!win) return;
        CGSize sz = [UIScreen mainScreen].bounds.size;   /* 截图为整屏，归一化必须按整屏算 */
        CGPoint p = CGPointMake(nx * sz.width, ny * sz.height);
        dsh_dot(p);

        UIView *v = nil;
        for (UIWindow *hw in [UIApplication sharedApplication].windows) {
            @try {
                UIView *h = [hw hitTest:p withEvent:nil];
                if (h && h != hw) { v = h; break; }
            } @catch (__unused NSException *e) {}
        }
        if (!v) { result = @"no-view"; return; }
        lg(@"hit %.0f,%.0f -> %@", p.x, p.y, NSStringFromClass([v class]));

        /* 1) tap 手势 */
        UIView *cur = v; int depth = 0;
        while (cur && depth++ < 12) {
            for (UIGestureRecognizer *g in cur.gestureRecognizers) {
                if (![g isKindOfClass:[UITapGestureRecognizer class]] || !g.enabled) continue;
                if (dsh_fire_gesture(g)) {
                    result = [NSString stringWithFormat:@"gesture:%@", NSStringFromClass([g class])];
                    return;
                }
            }
            cur = cur.superview;
        }

        /* 2) UIControl */
        for (cur = v; cur; cur = cur.superview) {
            if ([cur isKindOfClass:[UIControl class]]) {
                [(UIControl *)cur sendActionsForControlEvents:UIControlEventTouchUpInside];
                result = [NSString stringWithFormat:@"control:%@", NSStringFromClass([cur class])];
                return;
            }
        }

        /* 3) 列表 cell */
        for (cur = v; cur; cur = cur.superview) {
            if ([cur isKindOfClass:[UITableViewCell class]]) {
                NSString *txt = dsh_cell_text(cur);
                if (dsh_fire_gesture_tree(cur, 8)) {
                    result = [NSString stringWithFormat:@"cell-gesture:%@", txt];
                    return;
                }
                UIView *pv = cur.superview;
                while (pv && ![pv isKindOfClass:[UITableView class]]) pv = pv.superview;
                UITableView *tv = (UITableView *)pv;
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
            }
            if ([cur isKindOfClass:[UICollectionViewCell class]]) {
                NSString *txt = dsh_cell_text(cur);
                UIView *pv = cur.superview;
                while (pv && ![pv isKindOfClass:[UICollectionView class]]) pv = pv.superview;
                UICollectionView *cv = (UICollectionView *)pv;
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

        /* 4) 任意手势兜底 */
        cur = v; depth = 0;
        while (cur && depth++ < 12) {
            for (UIGestureRecognizer *g in cur.gestureRecognizers) {
                if (dsh_fire_gesture(g)) {
                    result = [NSString stringWithFormat:@"gesture-any:%@", NSStringFromClass([g class])];
                    return;
                }
            }
            cur = cur.superview;
        }

        result = [NSString stringWithFormat:@"no-action:%@", NSStringFromClass([v class])];
    });
    return result;
}

/* 按 indexPath 精确点行 */
static NSString *dsh_tap_row(long sec, long row) {
    __block NSString *out = @"not-found";
    onMain(^{
        NSIndexPath *want = [NSIndexPath indexPathForRow:row inSection:sec];
        for (id tv in dsh_all_tables()) {
            if ([tv isKindOfClass:[UITableView class]]) {
                UITableView *t = (UITableView *)tv;
                if (sec >= (long)[t numberOfSections]) continue;
                if (row >= (long)[t numberOfRowsInSection:sec]) continue;
                UITableViewCell *c = [t cellForRowAtIndexPath:want];
                CGRect r = c ? [c convertRect:c.bounds toView:nil] : CGRectZero;
                if (c) dsh_dot(CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)));
                [t selectRowAtIndexPath:want animated:NO scrollPosition:UITableViewScrollPositionNone];
                id<UITableViewDelegate> del = t.delegate;
                if ([del respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                    [del tableView:t didSelectRowAtIndexPath:want];
                }
                out = [NSString stringWithFormat:@"row:%@", c ? dsh_cell_text(c) : @"(offscreen)"];
                return;
            } else {
                UICollectionView *t = (UICollectionView *)tv;
                NSIndexPath *wantI = [NSIndexPath indexPathForItem:row inSection:sec];
                if (sec >= (long)[t numberOfSections]) continue;
                if (row >= (long)[t numberOfItemsInSection:sec]) continue;
                UICollectionViewCell *c = [t cellForItemAtIndexPath:wantI];
                [t selectItemAtIndexPath:wantI animated:NO scrollPosition:UICollectionViewScrollPositionNone];
                id<UICollectionViewDelegate> del = t.delegate;
                if ([del respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                    [del collectionView:t didSelectItemAtIndexPath:wantI];
                }
                out = [NSString stringWithFormat:@"item:%@", c ? dsh_cell_text(c) : @"(offscreen)"];
                return;
            }
        }
    });
    return out;
}

#pragma mark - 按文本直接找行（不依赖坐标、不依赖行号）

/* 列出所有可见行里文本匹配的行：每行 "序号|section:row|文本" */
static NSString *dsh_find_rows(NSString *needle, BOOL tail) {
    __block NSString *out = @"";
    onMain(^{
        NSMutableString *s = [NSMutableString string];
        int idx = 0;
        for (id tv in dsh_all_tables()) {
            if ([tv isKindOfClass:[UITableView class]]) {
                UITableView *t = (UITableView *)tv;
                for (UITableViewCell *c in t.visibleCells) {
                    NSString *txt = dsh_cell_text(c);
                    if (tail ? ![txt hasSuffix:needle] : ([txt rangeOfString:needle].location == NSNotFound)) continue;
                    NSIndexPath *ip = [t indexPathForCell:c];
                    [s appendFormat:@"%d|%ld:%ld|%@\n", idx++, (long)ip.section, (long)ip.row, txt];
                }
            } else {
                UICollectionView *t = (UICollectionView *)tv;
                for (UICollectionViewCell *c in t.visibleCells) {
                    NSString *txt = dsh_cell_text(c);
                    if (tail ? ![txt hasSuffix:needle] : ([txt rangeOfString:needle].location == NSNotFound)) continue;
                    NSIndexPath *ip = [t indexPathForCell:c];
                    [s appendFormat:@"%d|%ld:%ld|%@\n", idx++, (long)ip.section, (long)ip.item, txt];
                }
            }
        }
        out = s.length ? s : @"(none)";
    });
    return out;
}

/* 点第 skip 个文本匹配的行：直接对该 cell 走 delegate，绕开坐标和列表刷新 */
static NSString *dsh_tap_text(NSString *needle, int skip, BOOL tail) {
    __block NSString *out = @"not-found";
    onMain(^{
        int idx = 0;
        for (id tv in dsh_all_tables()) {
            if ([tv isKindOfClass:[UITableView class]]) {
                UITableView *t = (UITableView *)tv;
                for (UITableViewCell *c in t.visibleCells) {
                    NSString *txt = dsh_cell_text(c);
                    if (tail ? ![txt hasSuffix:needle] : ([txt rangeOfString:needle].location == NSNotFound)) continue;
                    if (idx++ < skip) continue;
                    NSIndexPath *ip = [t indexPathForCell:c];
                    CGRect r = [c convertRect:c.bounds toView:nil];
                    dsh_dot(CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)));
                    [t selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone];
                    id<UITableViewDelegate> dg = t.delegate;
                    if ([dg respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                        [dg tableView:t didSelectRowAtIndexPath:ip];
                    }
                    out = [NSString stringWithFormat:@"table-row:%@", txt];
                    return;
                }
            } else {
                UICollectionView *t = (UICollectionView *)tv;
                for (UICollectionViewCell *c in t.visibleCells) {
                    NSString *txt = dsh_cell_text(c);
                    if (tail ? ![txt hasSuffix:needle] : ([txt rangeOfString:needle].location == NSNotFound)) continue;
                    if (idx++ < skip) continue;
                    NSIndexPath *ip = [t indexPathForCell:c];
                    CGRect r = [c convertRect:c.bounds toView:nil];
                    dsh_dot(CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)));
                    [t selectItemAtIndexPath:ip animated:NO scrollPosition:UICollectionViewScrollPositionNone];
                    id<UICollectionViewDelegate> dg = t.delegate;
                    if ([dg respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                        [dg collectionView:t didSelectItemAtIndexPath:ip];
                    }
                    out = [NSString stringWithFormat:@"collection-item:%@", txt];
                    return;
                }
            }
        }
    });
    return out;
}

#pragma mark - 滚动

static UIScrollView *dsh_top_scroll(void) {
    UIScrollView *best = nil;
    NSMutableArray *stack = [NSMutableArray array];
    for (UIWindow *w in dsh_all_windows()) [stack addObject:w];
    int g = 0;
    while (stack.count && g++ < 5000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v.hidden || v.alpha < 0.02) continue;
        if ([v isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)v;
            if (sv.contentSize.height > sv.bounds.size.height + 4) best = sv;
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return best;
}

static NSString *dsh_scroll(double dy) {
    __block NSString *out = @"no-scrollview";
    onMain(^{
        UIScrollView *sv = dsh_top_scroll();
        if (!sv) return;
        CGFloat maxY = sv.contentSize.height - sv.bounds.size.height;
        if (maxY < 0) maxY = 0;
        CGFloat y = sv.contentOffset.y + dy;
        if (y < 0) y = 0;
        if (y > maxY) y = maxY;
        [sv setContentOffset:CGPointMake(sv.contentOffset.x, y) animated:NO];
        /* 滑动可视化：在滚动区域中心画红点，向下滚偏上、向上滚偏下，一眼看出方向 */
        CGRect vis = [sv convertRect:sv.bounds toView:nil];
        CGPoint c = CGPointMake(CGRectGetMidX(vis), CGRectGetMidY(vis) + (dy > 0 ? -70 : 70));
        dsh_dot(c);
        out = [NSString stringWithFormat:@"scroll:%.0f/%.0f (dot %.0f,%.0f)", y, maxY, c.x, c.y];
        lg(@"scroll -> %@", out);
    });
    return out;
}

/* 在可见行里找文本，找到就滚到中间并返回 indexPath；找不到返回 not-visible
   注意：所有 UIKit 访问必须在主线程，否则微信会在后台线程 brk 掉（SIGTRAP / EXC_BREAKPOINT） */
static NSString *dsh_locate(NSString *needle) {
    __block NSString *out = @"not-visible";
    onMain(^{
        for (id tv in dsh_all_tables()) {
            if ([tv isKindOfClass:[UITableView class]]) {
                UITableView *t = (UITableView *)tv;
                for (UITableViewCell *c in t.visibleCells) {
                    NSString *txt = dsh_cell_text(c);
                    if ([txt rangeOfString:needle].location != NSNotFound) {
                        NSIndexPath *ip = [t indexPathForCell:c];
                        if (ip) {
                            [t scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
                            out = [NSString stringWithFormat:@"%ld:%ld|%@", (long)ip.section, (long)ip.row, txt];
                            return;
                        }
                    }
                }
            } else {
                UICollectionView *t = (UICollectionView *)tv;
                for (UICollectionViewCell *c in t.visibleCells) {
                    NSString *txt = dsh_cell_text(c);
                    if ([txt rangeOfString:needle].location != NSNotFound) {
                        NSIndexPath *ip = [t indexPathForCell:c];
                        if (ip) {
                            out = [NSString stringWithFormat:@"%ld:%ld|%@", (long)ip.section, (long)ip.item, txt];
                            return;
                        }
                    }
                }
            }
        }
    });
    return out;
}

/* 一步步滚，最多 maxStep 次，找到就停 */
static NSString *dsh_scroll_to(NSString *needle, double step, int maxStep) {
    __block NSString *out = @"not-found";
    NSString *hit = dsh_locate(needle);
    if (![hit isEqualToString:@"not-visible"]) return hit;

    for (int i = 0; i < maxStep; i++) {
        __block BOOL moved = NO;
        onMain(^{
            UIScrollView *sv = dsh_top_scroll();
            if (!sv) return;
            CGFloat maxY = sv.contentSize.height - sv.bounds.size.height;
            if (maxY <= 0) return;
            CGFloat y = sv.contentOffset.y + step;
            if (y < 0) y = 0;
            if (y > maxY) y = maxY;
            if (fabs(y - sv.contentOffset.y) < 1) return;
            [sv setContentOffset:CGPointMake(sv.contentOffset.x, y) animated:NO];
            moved = YES;
        });
        if (!moved) break;
        usleep(180 * 1000);
        hit = dsh_locate(needle);
        if (![hit isEqualToString:@"not-visible"]) {
            out = [NSString stringWithFormat:@"%@ (step %d)", hit, i + 1];
            break;
        }
    }
    return out;
}

#pragma mark - 文本输入

static UIView *dsh_find_input(void) {
    UIView *any = nil;
    NSMutableArray *stack = [NSMutableArray array];
    for (UIWindow *w in dsh_all_windows()) [stack addObject:w];
    int g = 0;
    while (stack.count && g++ < 4000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v.hidden || v.alpha < 0.02) continue;
        if ([v isKindOfClass:[UITextView class]] && ((UITextView *)v).editable) {
            if (v.isFirstResponder) return v;
            if (!any) any = v;
        } else if ([v isKindOfClass:[UITextField class]] && ((UITextField *)v).enabled) {
            if (v.isFirstResponder) return v;
            if (!any) any = v;
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return any;
}

static NSString *dsh_type(NSString *text) {
    __block NSString *out = @"no-input";
    onMain(^{
        UIView *in = dsh_find_input();
        if (!in) return;
        [in becomeFirstResponder];
        if ([in isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)in;
            [tv insertText:text];
            if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)]) [tv.delegate textViewDidChange:tv];
            [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:tv];
        } else {
            UITextField *tf = (UITextField *)in;
            tf.text = text;
            [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        }
        CGRect r = [in convertRect:in.bounds toView:nil];
        dsh_dot(CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)));
        out = [NSString stringWithFormat:@"typed:%@:%@", NSStringFromClass([in class]), text];
        lg(@"type -> %@", out);
    });
    return out;
}

static NSString *dsh_press(NSString *title) {
    __block NSString *out = @"no-button";
    onMain(^{
        NSMutableArray *stack = [NSMutableArray array];
        for (UIWindow *w in dsh_all_windows()) [stack addObject:w];
        int g = 0;
        while (stack.count && g++ < 8000) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if (v.alpha < 0.01) continue;   /* 不按 hidden 过滤：微信发送键常以 hidden=YES 待命 */
            if ([v isKindOfClass:[UIControl class]]) {
                NSString *t = dsh_view_text(v);
                if (t.length && ([t isEqualToString:title] || [t rangeOfString:title].location != NSNotFound)) {
                    CGRect r = [v convertRect:v.bounds toView:nil];
                    dsh_dot(CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)));
                    [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
                    out = [NSString stringWithFormat:@"pressed:%@:%@ hidden=%d",
                           t, NSStringFromClass([v class]), (int)v.hidden];
                    lg(@"press -> %@", out);
                    return;
                }
            }
            [stack addObjectsFromArray:v.subviews];
        }
    });
    return out;
}

#pragma mark - 查询

static NSString *dsh_list(void) {
    __block NSString *out = @"(empty)";
    onMain(^{
        NSMutableString *s = [NSMutableString string];
        for (id tv in dsh_all_tables()) {
            if ([tv isKindOfClass:[UITableView class]]) {
                UITableView *t = (UITableView *)tv;
                for (UITableViewCell *c in t.visibleCells) {
                    NSIndexPath *ip = [t indexPathForCell:c];
                    if (!ip) continue;
                    [s appendFormat:@"%ld-%ld | %@\n", (long)ip.section, (long)ip.row, dsh_cell_text(c)];
                }
            } else {
                UICollectionView *t = (UICollectionView *)tv;
                for (UICollectionViewCell *c in t.visibleCells) {
                    NSIndexPath *ip = [t indexPathForCell:c];
                    if (!ip) continue;
                    [s appendFormat:@"%ld-%ld | %@\n", (long)ip.section, (long)ip.item, dsh_cell_text(c)];
                }
            }
        }
        out = s.length ? s : @"(empty)";
    });
    return out;
}

static void dsh_dump(UIView *v, int depth, NSMutableString *out, BOOL all) {
    if (!v || v.hidden || v.alpha < 0.02) return;
    if (v.frame.size.width <= 0.5 || v.frame.size.height <= 0.5) return;
    CGRect r = [v convertRect:v.bounds toView:nil];
    NSString *txt = dsh_view_text(v);
    BOOL ia = [v isKindOfClass:[UIControl class]] || v.gestureRecognizers.count > 0;
    if (all || txt.length || ia) {
        [out appendFormat:@"%d|%s|%.0f,%.0f,%.0f,%.0f|%d|%@\n",
            depth, NSStringFromClass([v class]).UTF8String,
            r.origin.x, r.origin.y, r.size.width, r.size.height,
            ia ? 1 : 0,
            txt ? [txt stringByReplacingOccurrencesOfString:@"\n" withString:@" "] : @""];
    }
    if (depth >= 60) return;
    for (UIView *s in v.subviews) dsh_dump(s, depth + 1, out, all);
}

#pragma mark - query 解析

static void dsh_url_decode(const char *src, char *dst, size_t n) {
    size_t i = 0;
    while (*src && i + 1 < n) {
        if (*src == '%' && src[1] && src[2]) {
            char h[3] = { src[1], src[2], 0 };
            dst[i++] = (char)strtol(h, NULL, 16);
            src += 3;
        } else if (*src == '+') { dst[i++] = ' '; src++; }
        else { dst[i++] = *src++; }
    }
    dst[i] = 0;
}

static double qnum(const char *req, const char *name, double def) {
    char pat[32]; snprintf(pat, sizeof(pat), "%s=", name);
    const char *p = strstr(req, pat);
    return p ? atof(p + strlen(pat)) : def;
}

static const char *qstr(const char *req, const char *name) {
    static char buf[1024];
    char pat[32]; snprintf(pat, sizeof(pat), "%s=", name);
    const char *p = strstr(req, pat);
    if (!p) { buf[0] = 0; return buf; }
    p += strlen(pat);
    char raw[1024]; size_t i = 0;
    while (*p && *p != '&' && *p != ' ' && i + 1 < sizeof(raw)) raw[i++] = *p++;
    raw[i] = 0;
    dsh_url_decode(raw, buf, sizeof(buf));
    return buf;
}

#pragma mark - HTTP

static void reply(int fd, int code, const char *reason, const char *ctype, const char *body) {
    size_t n = body ? strlen(body) : 0;
    char hdr[256];
    int hl = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n",
        code, reason, ctype, n);
    send(fd, hdr, hl, 0);
    if (body && n) send(fd, body, n, 0);
}

static void handle(int fd) {
    char buf[1536];
    ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) { close(fd); return; }
    buf[n] = 0;
    if (!strstr(buf, kKey)) { reply(fd, 403, "Forbidden", "text/plain", "no key"); close(fd); return; }

    NSString *res = @"bad";
    if (strstr(buf, "GET /info")) {
        res = [NSString stringWithFormat:@"pid=%d windows=%lu", getpid(),
               (unsigned long)dsh_all_windows().count];
    } else if (strstr(buf, "GET /list")) {
        res = dsh_list();
    } else if (strstr(buf, "GET /tree")) {
        __block NSString *o = @"";
        BOOL all = qnum(buf, "all", 0) != 0;
        onMain(^{
            NSMutableString *s = [NSMutableString string];
            UIWindow *w = dsh_window();
            /* 只 dump 一个窗口：多窗口遍历会在微信里炸内存，v13 就是这么崩的 */
            [s appendFormat:@"# window=%s %.0fx%.0f\n",
                w ? NSStringFromClass([w class]).UTF8String : "nil",
                w ? w.bounds.size.width : 0, w ? w.bounds.size.height : 0];
            if (w) dsh_dump(w, 0, s, all);
            o = s;
        });
        res = o;
    } else if (strstr(buf, "GET /scrollTo")) {
        double dy = qnum(buf, "dy", 600);
        res = dsh_scroll_to([NSString stringWithUTF8String:qstr(buf, "text")], dy > 0 ? -dy : dy, 12);
    } else if (strstr(buf, "GET /scroll")) {
        res = dsh_scroll(qnum(buf, "dy", 600));
    } else if (strstr(buf, "GET /find")) {
        res = dsh_find_rows([NSString stringWithUTF8String:qstr(buf, "text")], qnum(buf, "tail", 0) != 0);
    } else if (strstr(buf, "GET /tap_text")) {
        res = dsh_tap_text([NSString stringWithUTF8String:qstr(buf, "text")], (int)qnum(buf, "skip", 0), qnum(buf, "tail", 0) != 0);
    } else if (strstr(buf, "GET /tap_row")) {
        long s = (long)qnum(buf, "s", 0), r = (long)qnum(buf, "r", 0);
        res = dsh_tap_row(s, r);
    } else if (strstr(buf, "GET /type")) {
        res = dsh_type([NSString stringWithUTF8String:qstr(buf, "text")]);
    } else if (strstr(buf, "GET /press")) {
        res = dsh_press([NSString stringWithUTF8String:qstr(buf, "title")]);
    } else if (strstr(buf, "GET /tap")) {
        res = dsh_tap(qnum(buf, "x", 0.5), qnum(buf, "y", 0.5));
    } else {
        reply(fd, 400, "Bad Request", "text/plain", "bad");
        close(fd);
        return;
    }

    const char *utf = [res UTF8String];
    if (!utf) utf = "";
    reply(fd, 200, "OK", "text/plain; charset=utf-8", utf);
    lg(@"http -> %.300s", utf);
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
