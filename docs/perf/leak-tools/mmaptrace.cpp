// LD_PRELOAD leak localizer: tracks live large ANONYMOUS mmaps by call site.
// On SIGUSR1 (or exit) it dumps the call sites holding the most still-live mmap'd bytes — i.e. the leak.
// Build: g++ -O2 -shared -fPIC -o libmmaptrace.so mmaptrace.cpp -ldl
// Use:   LD_PRELOAD=/path/libmmaptrace.so <app> ;  kill -USR1 <pid>  to dump.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <sys/mman.h>
#include <signal.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <malloc.h>
#include <mutex>
#include <unordered_map>
#include <map>
#include <array>
#include <vector>
#include <algorithm>

namespace {
using mmap_t   = void *(*)(void *, size_t, int, int, int, off_t);
using munmap_t = int (*)(void *, size_t);
mmap_t   real_mmap   = nullptr;
munmap_t real_munmap = nullptr;
constexpr int BT = 14;
struct Rec { size_t size; int n; void *bt[BT]; };
std::unordered_map<void *, Rec> *g_live = nullptr;
std::mutex g_mtx;
volatile sig_atomic_t g_dump = 0;
const size_t g_min = 1u << 20;          // only track >= 1 MB (the leak is ~4-5 MB chunks)
thread_local bool g_inside = false;

void ensure() {
    if (!real_mmap)   real_mmap   = (mmap_t)dlsym(RTLD_NEXT, "mmap");
    if (!real_munmap) real_munmap = (munmap_t)dlsym(RTLD_NEXT, "munmap");
    if (!g_live)      g_live      = new std::unordered_map<void *, Rec>();
}
void do_dump() {
    std::lock_guard<std::mutex> lk(g_mtx);
    if (!g_live) return;
    std::map<std::array<void *, BT>, std::pair<size_t, size_t>> agg;
    size_t total = 0;
    for (auto &kv : *g_live) {
        std::array<void *, BT> key{};
        for (int i = 0; i < BT; i++) key[i] = i < kv.second.n ? kv.second.bt[i] : nullptr;
        agg[key].first += kv.second.size; agg[key].second += 1; total += kv.second.size;
    }
    std::vector<std::pair<std::array<void *, BT>, std::pair<size_t, size_t>>> v(agg.begin(), agg.end());
    std::sort(v.begin(), v.end(), [](auto &a, auto &b) { return a.second.first > b.second.first; });
    struct mallinfo2 mi = mallinfo2();
    fprintf(stderr, "\n=== MALLINFO2: in_use(uordblks)=%zu MB  free(fordblks)=%zu MB  arena=%zu MB  mmap(hblkhd)=%zu MB  mmap_n=%zu ===\n",
            mi.uordblks >> 20, mi.fordblks >> 20, mi.arena >> 20, mi.hblkhd >> 20, mi.hblks);
    fprintf(stderr, "=== MMAPTRACE: %zu live >=1MB anon mmaps, %zu MB total ===\n", g_live->size(), total >> 20);
    int shown = 0;
    for (auto &e : v) {
        if (shown++ >= 12) break;
        auto &k = const_cast<std::array<void *, BT> &>(e.first);
        int n = 0; while (n < BT && k[n]) n++;
        fprintf(stderr, "--- %zu MB in %zu live allocs ---\n", e.second.first >> 20, e.second.second);
        char **s = backtrace_symbols(k.data(), n);
        if (s) { for (int i = 0; i < n; i++) fprintf(stderr, "    %s\n", s[i]); free(s); }
    }
    fflush(stderr);
}
void on_sig(int) { g_dump = 1; }
struct Init { Init() { ensure(); signal(SIGUSR1, on_sig); atexit(do_dump); } } g_init;
}  // namespace

extern "C" void *mmap(void *a, size_t len, int prot, int flags, int fd, off_t off) {
    ensure();
    void *p = real_mmap(a, len, prot, flags, fd, off);
    if (!g_inside && p != MAP_FAILED && len >= g_min && (flags & MAP_ANONYMOUS)) {
        g_inside = true;
        { std::lock_guard<std::mutex> lk(g_mtx); Rec r; r.size = len; r.n = backtrace(r.bt, BT); (*g_live)[p] = r; }
        g_inside = false;
    }
    if (g_dump) { g_dump = 0; do_dump(); }
    return p;
}
extern "C" void *mmap64(void *a, size_t len, int prot, int flags, int fd, off_t off)
    __attribute__((alias("mmap")));
extern "C" int munmap(void *p, size_t len) {
    ensure();
    if (!g_inside && g_live) { g_inside = true; { std::lock_guard<std::mutex> lk(g_mtx); g_live->erase(p); } g_inside = false; }
    return real_munmap(p, len);
}
