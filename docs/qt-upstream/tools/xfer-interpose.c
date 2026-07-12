/* LD_PRELOAD seam: deterministically fail av_hwframe_transfer_data().
 *
 * Env:
 *   XFER_FAIL_AFTER=<n>   first call number to force-fail (0/unset: never)
 *   XFER_FAIL_COUNT=<k>   consecutive forced failures (default 1)
 *   AVUTIL_SONAME=<name>  real libavutil soname (default "libavutil.so.59")
 *
 * Build:   gcc -shared -fPIC -O2 -o xfer-interpose.so xfer-interpose.c
 * Run:     LD_PRELOAD=./xfer-interpose.so XFER_FAIL_AFTER=200 <app>
 *
 * Notes: Qt loads its bundled FFmpeg into the plugin's LOCAL scope, so
 * RTLD_NEXT cannot see it from a preloaded object — the real symbol is
 * resolved from the already-loaded soname via dlopen(RTLD_NOLOAD). Forced
 * failures return -EIO (matches AVERROR(EIO) on Linux). If a passthrough is
 * required and the real symbol cannot be resolved, this aborts loudly rather
 * than silently failing every transfer.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <stdatomic.h>

typedef struct AVFrame AVFrame;
typedef int (*xfer_fn)(AVFrame *, const AVFrame *, int);

static xfer_fn g_real = 0;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static atomic_int g_calls = 0;
static atomic_int g_recovery_logged = 0;
static int g_after = 0, g_count = 1;

static void resolve_real(void)
{
    const char *a = getenv("XFER_FAIL_AFTER");
    const char *c = getenv("XFER_FAIL_COUNT");
    const char *so = getenv("AVUTIL_SONAME");
    g_after = a ? atoi(a) : 0;
    g_count = c ? atoi(c) : 1;
    g_real = (xfer_fn)dlsym(RTLD_NEXT, "av_hwframe_transfer_data");
    if (!g_real) {
        void *h = dlopen(so ? so : "libavutil.so.59", RTLD_LAZY | RTLD_NOLOAD);
        if (h)
            g_real = (xfer_fn)dlsym(h, "av_hwframe_transfer_data");
    }
    fprintf(stderr, "[XFER] armed fail_after=%d count=%d real=%p\n",
            g_after, g_count, (void *)g_real);
}

int av_hwframe_transfer_data(AVFrame *dst, const AVFrame *src, int flags)
{
    pthread_once(&g_once, resolve_real);
    int n = atomic_fetch_add(&g_calls, 1) + 1;
    long tid = syscall(SYS_gettid);
    if (g_after > 0 && n >= g_after && n < g_after + g_count) {
        fprintf(stderr, "[XFER] call#%d tid=%ld dst=%p FORCED_FAIL(-EIO=%d)\n",
                n, tid, (void *)dst, -EIO);
        return -EIO;
    }
    if (!g_real) {
        fprintf(stderr, "[XFER] FATAL: real av_hwframe_transfer_data unresolved "
                        "(set AVUTIL_SONAME?) — aborting rather than lying\n");
        abort();
    }
    int ret = g_real(dst, src, flags);
    if (g_after > 0 && n >= g_after + g_count
        && atomic_exchange(&g_recovery_logged, 1) == 0)
        fprintf(stderr, "[XFER] call#%d tid=%ld first REAL transfer after forced window ret=%d\n",
                n, tid, ret);
    if (ret != 0)
        fprintf(stderr, "[XFER] call#%d tid=%ld dst=%p ret=%d (REAL failure)\n",
                n, tid, (void *)dst, ret);
    return ret;
}
