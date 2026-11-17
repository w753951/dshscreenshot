// probe.m —— 注入验证（纯 C 函数体，避免 Foundation 早调用崩溃）
#include <stdio.h>
#include <unistd.h>
#include <time.h>
#include <string.h>

__attribute__((constructor))
static void dsh_probe_init(void) {
    FILE *f = fopen("/var/mobile/dsh-min.log", "a");
    if (!f) return;
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    fprintf(f, "%02d:%02d:%02d uid=%d pid=%d ctor-ok\n",
            tmv.tm_hour, tmv.tm_min, tmv.tm_sec, getuid(), getpid());
    fflush(f);
    fclose(f);
}
