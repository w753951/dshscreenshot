// dshss —— 调用 SpringBoard 的 SBScreenshotManager 生成整屏截图
// 动态 dlopen + objc runtime，不链接私有框架
//
// 用法: dshss [out.png]

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        fprintf(stderr, "SpringBoardServices handle=%p err=%s\n", h, h ? "-" : dlerror());

        Class mgrCls = objc_getClass("SBScreenshotManager");
        fprintf(stderr, "SBScreenshotManager=%p\n", (void *)mgrCls);
        if (!mgrCls) { return 2; }

        unsigned int n = 0;
        Method *ms = class_copyMethodList(mgrCls, &n);
        fprintf(stderr, "instance methods (%u):\n", n);
        for (unsigned int i = 0; i < n; i++)
            fprintf(stderr, "  -%s\n", sel_getName(method_getName(ms[i])));
        free(ms);

        Class meta = object_getClass((id)mgrCls);
        unsigned int cn = 0;
        Method *cms = class_copyMethodList(meta, &cn);
        fprintf(stderr, "class methods (%u):\n", cn);
        for (unsigned int i = 0; i < cn; i++)
            fprintf(stderr, "  +%s\n", sel_getName(method_getName(cms[i])));
        free(cms);

        id mgr = ((id (*)(id, SEL))objc_msgSend)((id)mgrCls, sel_registerName("new"));
        if (!mgr) mgr = ((id (*)(id, SEL))objc_msgSend)((id)mgrCls, sel_registerName("sharedInstance"));
        fprintf(stderr, "manager=%p\n", (void *)mgr);
        if (!mgr) return 3;

        SEL selSave = sel_registerName("saveScreenshots");
        if ([mgr respondsToSelector:selSave]) {
            fprintf(stderr, "-> saveScreenshots\n");
            ((void (*)(id, SEL))objc_msgSend)(mgr, selSave);
            printf("OK saveScreenshots\n");
            for (int i = 0; i < 30; i++) usleep(100000);
            return 0;
        }

        SEL selSaveC = sel_registerName("saveScreenshotsWithCompletion:");
        if ([mgr respondsToSelector:selSaveC]) {
            fprintf(stderr, "-> saveScreenshotsWithCompletion:\n");
            void (^done)(id) = ^(id result) {
                fprintf(stderr, "completion: %s\n", [[result description] UTF8String]);
            };
            ((void (*)(id, SEL, id))objc_msgSend)(mgr, selSaveC, done);
            for (int i = 0; i < 60; i++) usleep(100000);
            printf("OK saveScreenshotsWithCompletion\n");
            return 0;
        }

        fprintf(stderr, "no usable selector\n");
        return 4;
    }
}
