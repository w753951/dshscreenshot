// probe.m —— 最小注入验证（结构对齐 DshProbe2：ObjC + Foundation）
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

__attribute__((constructor))
static void dsh_probe_init(void) {
    @autoreleasepool {
        NSString *msg = [NSString stringWithFormat:
            @"loaded uid=%d pid=%d bundle=%@",
            getuid(), getpid(),
            [[NSBundle mainBundle] bundleIdentifier]];

        NSString *path = @"/var/mobile/dsh-min.log";
        NSString *old = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
        NSString *merged = [(old ?: @"") stringByAppendingFormat:@"%@\n", msg];
        [merged writeToFile:path atomically:YES
                   encoding:NSUTF8StringEncoding error:NULL];
    }
}
