// probe.m —— 最小注入验证
// 只写一行日志，不依赖任何框架（连 Foundation 都不 import）
#include <stdio.h>
#include <unistd.h>
#include <time.h>

__attribute__((constructor))
static void dsh_probe_init(void) {
    FILE *f = fopen("/var/mobile/dsh-min.log", "a");
    if (!f) return;
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    fprintf(f, "%02d:%02d:%02d constructor uid=%d pid=%d\n",
            tm->tm_hour, tm->tm_min, tm->tm_sec, getuid(), getpid());
    fclose(f);
}
