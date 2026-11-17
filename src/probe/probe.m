// probe.m —— 二分定位：纯线程，不 dlopen，不做任何间接调用之外的事
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>
#include <stdarg.h>

static void plog(const char *fmt, ...) {
    FILE *f = fopen("/var/mobile/dsh-min.log", "a");
    if (!f) return;
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fclose(f);
}

static void *worker(void *arg) {
    (void)arg;
    sleep(3);
    plog("[worker] alive tid-in-thread");
    for (int i = 0; i < 6; i++) {
        sleep(5);
        plog("[worker] tick %d", i);
    }
    plog("[worker] done");
    return NULL;
}

__attribute__((constructor))
static void probe_init(void) {
    plog("ctor uid=%d pid=%d", getuid(), getpid());
    pthread_t th;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    int rc = pthread_create(&th, &at, worker, NULL);
    plog("pthread_create rc=%d", rc);
    pthread_attr_destroy(&at);
}
