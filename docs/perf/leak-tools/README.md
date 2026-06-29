# Heap leak-localization tools (LD_PRELOAD)

heaptrack and valgrind/massif are unusable on Watchtower's VA-API/FFmpeg/Qt stack (crash / unusably slow).
These two tiny `LD_PRELOAD` interposers are the profilers that DO work here — they localized the per-open RSS
growth to **glibc arena retention + full-res snapshot decode** (see `../2026-06-29-qt-decode-leak-deepdive.md`
Revision 3), after black-box bisection had stalled.

## malloctrace.cpp — heap allocation sites
Interposes `malloc/calloc/realloc/posix_memalign/free`; records live allocations ≥ `MIN` (16 KB; edit the
constant) by backtrace; on **SIGUSR1** dumps the top sites by *still-live* bytes + a `mallinfo2` summary
(in_use / free / arena / mmap). **The `mallinfo2` line is the key tell:** if `in_use` is FLAT while RSS
climbs, the growth is glibc *retention/fragmentation*, not an unfreed leak — tune `mallopt`/`malloc_trim`, do
not chase an "unfreed" allocation.

## mmaptrace.cpp — large anonymous mmap sites
Same idea for `mmap/munmap` ≥ 1 MB anonymous. Use it to confirm whether the growth is in large mmaps (here it
was *not* — the retained memory is arena-backed, below the mmap threshold).

## Build + use
```
g++ -O2 -shared -fPIC -o libmalloctrace.so malloctrace.cpp -ldl
LD_PRELOAD=$PWD/libmalloctrace.so ./build68/watchtower &   # under WT_HERO_OPENONLY to loop recording-opens
kill -USR1 <pid>     # dump to the app's stderr; send twice (early + late) to see which site GROWS
```
