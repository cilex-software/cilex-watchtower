/* LD_PRELOAD seam: deterministically fail av_hwframe_transfer_data.
 * XFER_FAIL_AFTER=<n> first call to fail; XFER_FAIL_COUNT=<k> consecutive (default 1). */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <stdatomic.h>

typedef struct AVFrame AVFrame;
static int (*real_xfer)(AVFrame *, const AVFrame *, int) = 0;
static atomic_int g_calls = 0;
static int g_after = 0, g_count = 1;

__attribute__((constructor)) static void init(void)
{
    const char *a = getenv("XFER_FAIL_AFTER");
    const char *c = getenv("XFER_FAIL_COUNT");
    g_after = a ? atoi(a) : 0;
    g_count = c ? atoi(c) : 1;
    /* NOTE: libavutil is not loaded yet at preload-constructor time — resolve
     * lazily in the wrapper (first attempt here is allowed to fail). */
    real_xfer = (int (*)(AVFrame *, const AVFrame *, int))dlsym(RTLD_NEXT, "av_hwframe_transfer_data");
    fprintf(stderr, "[XFER] armed: fail_after=%d count=%d real(ctor)=%p\n", g_after, g_count, (void *)real_xfer);
}

int av_hwframe_transfer_data(AVFrame *dst, const AVFrame *src, int flags)
{
    if (!real_xfer) {
        real_xfer = (int (*)(AVFrame *, const AVFrame *, int))dlsym(RTLD_NEXT, "av_hwframe_transfer_data");
        if (!real_xfer) {
            /* Qt loads its bundled FFmpeg into the plugin's LOCAL scope —
             * RTLD_NEXT can't see it. Grab the already-loaded lib directly. */
            void *h = dlopen("libavutil.so.59", RTLD_LAZY | RTLD_NOLOAD);
            if (h)
                real_xfer = (int (*)(AVFrame *, const AVFrame *, int))dlsym(h, "av_hwframe_transfer_data");
        }
    }
    int n = atomic_fetch_add(&g_calls, 1) + 1;
    long tid = syscall(SYS_gettid);
    if ((g_after > 0 && n >= g_after && n < g_after + g_count) || !real_xfer) {
        fprintf(stderr, "[XFER] call#%d tid=%ld dst=%p FORCED_FAIL(-5)%s\n",
                n, tid, (void *)dst, real_xfer ? "" : " (no real sym)");
        return -5;
    }
    int ret = real_xfer(dst, src, flags);
    if (ret != 0)
        fprintf(stderr, "[XFER] call#%d tid=%ld dst=%p ret=%d (REAL failure)\n", n, tid, (void *)dst, ret);
    return ret;
}
