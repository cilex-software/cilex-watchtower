// LD_PRELOAD leak localizer (heap): tracks live >=64KB allocations by call site (malloc/calloc/realloc/
// posix_memalign), removing on free/realloc. On SIGUSR1 dumps the sites holding the most STILL-LIVE bytes.
// Build: g++ -O2 -shared -fPIC -o libmalloctrace.so malloctrace.cpp -ldl
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <cstdio>
#include <cstdlib>
#include <malloc.h>
#include <mutex>
#include <unordered_map>
#include <map>
#include <array>
#include <vector>
#include <algorithm>

extern "C" { void *__libc_malloc(size_t); void __libc_free(void *); void *__libc_calloc(size_t, size_t); void *__libc_realloc(void *, size_t); }

namespace {
constexpr int BT = 16;
constexpr size_t MIN = 16 * 1024;          // track >= 64 KB
struct Rec { size_t size; int n; void *bt[BT]; };
std::unordered_map<void *, Rec> *g_live = nullptr;
std::mutex g_mtx;
volatile sig_atomic_t g_dump = 0;
thread_local int g_in = 0;
using pma_t = int (*)(void **, size_t, size_t);
pma_t real_pma = nullptr;

void record(void *p, size_t size) {
    if (!p || size < MIN || g_in) return;
    g_in++;
    if (!g_live) g_live = new std::unordered_map<void *, Rec>();
    { std::lock_guard<std::mutex> lk(g_mtx); Rec r; r.size = size; r.n = backtrace(r.bt, BT); (*g_live)[p] = r; }
    g_in--;
}
void unrecord(void *p) {
    if (!p || g_in || !g_live) return;
    g_in++;
    { std::lock_guard<std::mutex> lk(g_mtx); g_live->erase(p); }
    g_in--;
}
void do_dump() {
    g_in++;
    std::lock_guard<std::mutex> lk(g_mtx);
    if (g_live) {
        std::map<std::array<void *, BT>, std::pair<size_t, size_t>> agg; size_t total = 0;
        for (auto &kv : *g_live) { std::array<void *, BT> k{}; for (int i = 0; i < BT; i++) k[i] = i < kv.second.n ? kv.second.bt[i] : nullptr;
            agg[k].first += kv.second.size; agg[k].second++; total += kv.second.size; }
        std::vector<std::pair<std::array<void *, BT>, std::pair<size_t, size_t>>> v(agg.begin(), agg.end());
        std::sort(v.begin(), v.end(), [](auto &a, auto &b) { return a.second.first > b.second.first; });
        struct mallinfo2 mi = mallinfo2();
        fprintf(stderr, "\n=== MALLOCTRACE: in_use=%zuMB  tracked-live(>=64KB)=%zuMB in %zu allocs ===\n",
                mi.uordblks >> 20, total >> 20, g_live->size());
        int shown = 0;
        for (auto &e : v) { if (shown++ >= 12) break; auto &k = const_cast<std::array<void *, BT> &>(e.first);
            int n = 0; while (n < BT && k[n]) n++;
            fprintf(stderr, "--- %zu MB in %zu live allocs ---\n", e.second.first >> 20, e.second.second);
            char **s = backtrace_symbols(k.data(), n); if (s) { for (int i = 0; i < n; i++) fprintf(stderr, "    %s\n", s[i]); free(s); } }
        fflush(stderr);
    }
    g_in--;
}
void on_sig(int) { g_dump = 1; }
struct Init { Init() { signal(SIGUSR1, on_sig); atexit(do_dump); } } g_init;
inline void chk() { if (g_dump) { g_dump = 0; do_dump(); } }
}  // namespace

extern "C" void *malloc(size_t s) { void *p = __libc_malloc(s); record(p, s); chk(); return p; }
extern "C" void free(void *p) { unrecord(p); __libc_free(p); }
extern "C" void *calloc(size_t n, size_t s) { void *p = __libc_calloc(n, s); record(p, n * s); return p; }
extern "C" void *realloc(void *o, size_t s) { unrecord(o); void *p = __libc_realloc(o, s); record(p, s); return p; }
extern "C" int posix_memalign(void **mp, size_t a, size_t s) {
    if (!real_pma) real_pma = (pma_t)dlsym(RTLD_NEXT, "posix_memalign");
    int r = real_pma(mp, a, s); if (r == 0) record(*mp, s); return r;
}
