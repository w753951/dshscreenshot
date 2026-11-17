// dshss —— dlopen 诊断工具
// 用法: dshss <dylib路径>
// 输出: dlopen 成功/失败、dlerror、镜像信息
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <unistd.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: %s <dylib>\n", argv[0]); return 64; }
        const char *path = argv[1];
        fprintf(stderr, "uid=%d path=%s\n", getuid(), path);

        // 先清空错误
        dlerror();

        void *h = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
        const char *err = dlerror();

        fprintf(stderr, "dlopen -> %p\n", h);
        if (err) fprintf(stderr, "dlerror: %s\n", err);

        if (h) {
            // 打印该镜像的 header 信息
            uint32_t cnt = _dyld_image_count();
            for (uint32_t i = 0; i < cnt; i++) {
                const char *name = _dyld_get_image_name(i);
                if (name && strstr(name, "DshMin")) {
                    const struct mach_header *mh = _dyld_get_image_header(i);
                    fprintf(stderr, "image[%u] %s hdr=%p magic=0x%x cputype=0x%x cpusubtype=0x%x ncmds=%u\n",
                            i, name, mh, mh->magic, mh->cputype, mh->cpusubtype, mh->ncmds);
                }
            }
            printf("OK loaded\n");
            return 0;
        }
        printf("FAILED\n");
        return 1;
    }
}
