# After `shared_buffers` 128 → 512 MB: the queries are fixed and `acquire` is the new floor — booth measurements

    Station:  wt-sm-vnutri-01 (guard booth, Win 11), offscreen harness, WT_TRACE=1
    Build:    1.1.263 (FAST OPEN + read-ahead hold + head_split, all deployed)
    Backend:  http://192.168.1.79:8000, after CV raised shared_buffers tonight
    Date:     2026-08-31, ~05:30-06:10 local

CV applied `shared_buffers` 128 → 512 MB and `effective_cache_size` 512 MB → 3 GB
tonight, on the operator's approval. Postgres was back in 6 s and recording never
stopped. Their bench, 20 opens on untouched cameras: **median 64 ms, 75 % under 300 ms,
max 781**. They asked for the same distribution over the booth's real wire.

## 1. The headline: their fix worked, and the bottleneck moved

**The queries are fixed.** `q1;dur` — 76 % of `index` before, and the thing their 08-21
letter promised to bound — now comes back at **6.2 / 7.2 ms**. It was 353.5 ms.

**Session creation did not follow.** 12 instant opens across 5 cameras at instants never
opened this session:

    session_http   8,255  9,092  9,196  10,263  10,489  15,960  19,785  20,897  22,849 ms
                   MEDIAN 10,489 ms          (their bench: 64 ms)
    index            909  2,538  3,386  3,474  3,851  5,529  5,530  7,307  9,583 ms
                   MEDIAN  3,851 ms
    TTFF          16,580 - 36,170 ms         MEDIAN ~25,469 ms

## 2. Where it actually goes now — `acquire`, not the queries

The full header on the first open, which is representative:

    serve=11034.6  index=5529.0  persist=5498.5  queue=6.5
    acquire=5203.8  q1=7.2  q2=257.9  streams=0.1  q3=62.5  walk=1.1  q4=2.8

    real query work  q1+q2+q3+q4+walk  =  ~331 ms
    acquire (waiting for a DB connection) =  5,203.8 ms
    persist (second acquire + JSONB write) = 5,498.5 ms

Second open: `acquire=8,536.1` of `index=9,582.7`, `q1=6.2`.

**`acquire` + `persist` are ~10 of the ~11 seconds. The queries are ~0.3 s.** This is
connection-pool contention, not cache and not disk — so it needs neither another restart
nor more RAM, which is the good news buried in a bad number.

## 3. Why our number and CV's differ by 160x — and it is probably us

Their bench called the endpoint directly on a quiet box. **Our harness launches a fresh
app per open, and at the moment we dispatch the session we have 9-11 requests already in
flight against CV:**

    session_dispatch inflight_own=3 inflight_shared=8
    session_dispatch inflight_own=3 inflight_shared=8
    session_dispatch inflight_own=3 inflight_shared=6

Coverage, events, thumbnails, health and the station registry all fire during startup and
compete for the same pool. A pool that serialises under ~11 concurrent requests would
produce exactly the `acquire` values above.

**THIS REINSTATES AN ASK I WITHDREW, AND I WAS WRONG TO WITHDRAW IT.** My 2026-08-30
brief §4 asked for open-time concurrency to be cut. I retracted that on 2026-08-31 on the
grounds that `queue;dur` was idle (under 4 ms throughout). That reasoning was sound for
`queue` and wrong for the conclusion: **`queue` measures waiting to be scheduled, while
`acquire` measures waiting for a connection**, and CV only exposed `acquire` tonight. The
concurrency hypothesis was right in substance and I could not see its mechanism.

## 4. Two caveats on this data, stated rather than buried

- **The harness over-states the burst.** It has no station token, so `/client/stations`
  403s and retries three times per launch, adding load a production wall would not.
- **Every measurement here is a "first open after boot."** One open per app launch means
  none of them benefit from a settled client. The production wall had no playback opens
  overnight, so a real-world burst number could not be captured. A companion run
  (`warmapp`) opens several days inside ONE running app to separate the two, and is the
  measurement that decides whether this is CV's pool sizing or our burst.

## 4a. THE ATTRIBUTION, ANSWERED: it is OUR burst, not CV's pool

The companion run: 3 launches, 6 day-opens inside each ONE running app, so only the
first open of a launch pays the startup burst. Session creation, all 16:

    110  180  211  219  464  480  503  528  559  590  661  749  815  965  1197  1396 ms
    MEDIAN ~515 ms       min 110       max 1,396       none above 1.4 s

    index: 7.1  20.9  98.2  160.7  264.8  356.4  356.5  361.0  368.6  449.2
           462.0  472.5  560.2  877.1  999.0  1109.5      MEDIAN ~365 ms

Against **10,489 ms** median when every open got its own fresh app (§1).

**`acquire` collapses once our startup burst subsides. The contention is ours.** CV's
pool is not undersized for one settled client; it is overwhelmed by the 9-11 requests we
fire while the app is starting — coverage, events, thumbnails, health and the station
registry all at once.

**This also invalidates §1 as a measure of what a guard experiences**, and I would rather
say that than let the 10,489 ms number travel. A guard's app is already running when they
click; the fresh-app case only occurs right after a restart. **The honest current number
for session creation is ~515 ms median, and CV's `shared_buffers` change is working.**

TTFF over the same 18 opens:

    999  2,327  2,402  5,001  5,476  5,519  6,318  6,383  6,731  6,918
    7,241  7,288  7,818  7,962  8,981  14,716  16,337  27,157 ms
    MEDIAN ~6,550 ms      BEST 999 ms

Median TTFF ~6,550 minus median session ~515 leaves **~6 s in segment 0** — which is the
head_split build (§5), now the single dominant remaining cost.

## 5. head_split under the same conditions

`frag0s=1.200` engaged on 9 of 12 opens. Segment 0, with the build split out by `hdr=`:

    465 ms (build   404) /   448 KB
    2,077 (build   146) / 4,446 KB   <- not engaged, full segment
    2,223 (build 1,900) /   526 KB
    2,517 (build 1,930) / 1,296 KB
    3,634 (build 2,786) / 1,198 KB
    3,753 (build 3,505) / 1,139 KB
    4,743 (build 4,285) / 1,076 KB
    6,878 (build 6,499) /   605 KB
    8,548 (build 8,066) / 1,288 KB

**The build is nearly the whole of it** — 404 to 8,066 ms, against transfers of 61-848 ms.
One open fetched 605 KB and spent 6,499 ms building it. This is the same conclusion as
earlier tonight, now with nine samples instead of two: **the transfer half is reliably
fixed and the build half is unbounded**, which is why the precomputed-head-piece ask
matters more than the flag itself.
