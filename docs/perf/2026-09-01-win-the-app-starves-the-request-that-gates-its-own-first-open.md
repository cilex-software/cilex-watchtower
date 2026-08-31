# The app starves the one request that gates its own first open

**Station:** `wt-sm-vnutri-01` (guard booth, Win 11) · **Date:** 2026-09-01
**Build:** 1.1.300 · **Backend:** `192.168.1.4:8000` (LAN)

## The chain, measured end to end

1. The first day-open of a process costs a median **22,316 ms**; the second in the
   same process, **2,840 ms** — with CV's cache held warm in every cell, so the
   server is not the variable.
2. The first open is the one that skips FAST OPEN — 4/4 launches, twice over, in
   two independent harnesses.
3. It skips for a named reason: **`why=no-dayinfo dayKeys=0`**. Coverage has not
   populated a single day at click time.
4. Without `dayInfo[date].firstMs` the open falls through to the whole-day
   manifest: **2,253,507 bytes, 2,882 fragments**, `index;dur=11764.8`.
5. When coverage HAS landed first, the same first open costs **3,745–7,123 ms**
   instead of 14,025–22,833 ms.

## Why coverage is late — and it is us

`/review/coverage` returns **1,051 bytes**. Measured latency:

    during app startup     9,847 / 12,504 / 15,027 / 27,678 ms
    warm and idle (L3)             1,030 ms

Same endpoint, same camera, same payload size. **9.6× slower under our own startup
burst.** `[PBTIME] session_dispatch` reports `inflight_own=3 inflight_shared=6` at
click time, and CV reports `acquire;dur=6274.1` — their connection pool waiting —
on requests issued in that same window. Qt's QNetworkAccessManager also caps at 6
connections per host, so a queued request's wait is counted inside our `ms=`.

The margin is brutal in L3: coverage arrived at **+12,662 ms** and the click landed
at **+12,434 ms**. It lost by **228 ms** and cost the guard ~12 s.

## Coverage is fetched TWICE per open

Every launch produced two `coverage_http` responses ~2 ms apart (L1 logs both
dispatches at +18,966 and +18,968 ms; elsewhere the duplicate `coverage_dispatch`
line is collapsed by the flight recorder's repeat suppression, but the two
responses are always there).

One of the two is waste, and it is waste aimed directly at the 6-connection limit
that is already starving this request. Cause not yet established — do not "fix" it
before finding out which caller is duplicating.

## What this does NOT say

- It does **not** say CV's coverage endpoint is slow. 1,030 ms idle for 1 KB is
  not fast, but it is 9.6× better than what we measure under our own load, and
  **`/review/coverage` sends no `Server-Timing`** (`st=[]` on every response), so
  their serve time cannot be separated from our queueing. Asked in a letter.
- It does **not** validate `WT_PB_WAIT_COVERAGE`. That change waits 2,500 ms for
  coverage and **timed out 2 times out of 2** — coverage takes 10–28 s under load,
  so the wait never resolved. It added 2.5 s of dead time and fell through to the
  same whole-day path. **Default OFF; do not ship it in this form.** Waiting 12 s
  to avoid a 12 s manifest is a wash; the fix is to stop starving the request.

## Where the fix belongs

Client-side, in priority order:

1. **Stop issuing coverage twice.**
2. **Get coverage off the back of the startup burst** — issue it before or ahead of
   the events/snapshot traffic, or hold a connection for it. It is 1 KB and it
   gates the first open; nothing else in the burst does.
3. Only then reconsider waiting, and only with a bound derived from the measured
   latency rather than a guessed 2,500 ms.

## Result of the first fix (single-flight + HighPriority), build 1.1.302

Two changes: drop a coverage request when one for the same camera is already in
flight, and mark it `HighPriority` so it leads our own queue.

**The duplicate is gone** — `coverage_dedup` in 4/4 launches, one `coverage_http`
per screen entry where there were always two.

**FAST OPEN on the first open: 2 of 4, against 0 of 4 before.**

    launch   coverage arrives   first open
    L1       +28,296 ms         SKIP  -> failed      (dispatch itself was +14,588)
    L2       +12,683 ms         SKIP  -> 10,069 ms   (lost the click by 238 ms)
    L3        +7,430 ms         FAST  ->  4,579 ms
    L4        +2,436 ms         FAST  ->  6,273 ms

    first-open TTFF, valid samples   17,076 ms -> 6,273 ms median   (2.7x)
    coverage latency                 13,765 ms -> 8,091 ms median

**This is progress, not a fix.** n=4 per arm with a very wide spread, and the
first open still misses FAST OPEN half the time.

### The second delay, now separated

`fetchCoverage` cannot dispatch until `camerasResolved`. That wait alone measured
**952 / 1,539 / 2,977 / 14,588 ms**. In L1 coverage was *dispatched* two seconds
AFTER the guard's click — no request priority can rescue that, because the request
had not been made yet.

So the remaining work is in two parts, and they are different problems:

1. **Dispatch latency** — why does `camerasResolved` take up to 14.6 s? That is the
   `/streams` resolve, also inside the startup burst. Coverage inherits its worst
   case.
2. **Request latency** — still 896–13,708 ms for 1,051 bytes. Whether that is our
   remaining queueing or CV's serve time cannot be split until `/review/coverage`
   carries `Server-Timing` (asked 2026-09-01).

## Method note

Every number here comes from `[PBTIME]` marks with offsets from the process start
banner: `coverage_deferred` → `coverage_dispatch` → `coverage_http ms=`. The split
exists because "coverage is slow" has two owners — waiting to dispatch is ours,
waiting on the wire is CV's — and the previous version of this investigation could
not tell them apart.
