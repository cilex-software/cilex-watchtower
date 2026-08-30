# Where the time goes when a guard opens a recording — CV's own Server-Timing, booth measurements

    Station:  wt-sm-vnutri-01 (guard booth, Win 11), offscreen harness, WT_TRACE=1
    Build:    1.1.239 + the session-ownership fix (see the branch)
    Backend:  http://192.168.1.79:8000 over the direct LAN link
    Date:     2026-08-31, 00:00-00:50 local
    Camera:   192.168.1.126 (one camera — see §9)

Written down because production logs rotate and this is the dataset the
2026-08-31 letter to CV rests on. Every line here was logged, not derived.

## 1. What made this measurable

`[PBTIME] session_http` now logs CV's `Server-Timing` (1.1.238). We had been reading
that header in the segment proxy and on thumbnails since 2026-08-29 but not on session
creation — which is the largest single item on the open path. `ms=` is our full round
trip, `serve=` is CV's own accounting of the same request.

## 2. Session creation, uncontended

`queue;dur` under 4 ms on every line below; 0-1 requests in flight.

| our ms | bytes | serve | index | frags | note |
|---|---|---|---|---|---|
| 15,804 | 92,567 | 14,020.7 | 5,723.9 | 119 | |
| 11,704 | 510 | 9,608.8 | 5,331.0 | 1 | one fragment, 9.6 s |
| 2,389 | 510 | 2,324.8 | 1,785.8 | 1 | same shape, 4x faster |
| 84 | 414 | 11.1 | −33.7 | 0 | nothing to index → 11 ms |
| 2,758 | 140,827 | 2,654.1 | 2,616.1 | 173 | index = 98.5 % of serve |
| 3,344 | 2,252,683 | 2,772.6 | 2,396.3 | 2,881 | the 2.25 MB day manifest |
| 3,557 | 2,059,523 | 3,156.9 | 2,779.5 | 2,701 | |
| 591 | 48,513 | 379.1 | 290.4 | 61 | bounded 30 min window |
| 1,080 | 48,038 | 982.4 | 851.3 | 61 | same window, 2.6x slower |

Earlier the same night, three requests whose payloads spanned 1000x — 2,010 B /
48,481 B / 2,252,683 B — took 7,785 / 7,714 / 7,481 ms.

**Three things hold on every line:**

- **`serve` dominates our round trip.** On the 92 KB line CV accounts for 14.0 s of
  our 15.8 s; transport is ~1.8 s.
- **`queue` is idle.** Under 4 ms throughout. Our in-flight burst is not what makes
  session creation slow — which retracts §4 of the 2026-08-30 implementation brief.
- **Payload does not predict cost.** 510 bytes cost 9.6 s; 2.25 MB cost 2.8 s.

Cost tracks `index`, which is payload-independent and varied 3x between two identical
one-fragment requests seconds apart. **A single number for `index` would be
dishonest** — what is established is its dominance, not its value.

`index;dur=-33.7` on the empty case is negative: a sign or ordering bug in CV's
instrumentation, reported.

## 3. Time-of-night variance

The same endpoint, same camera, ~4 minutes apart:

    00:04   serve 9,608 - 14,020 ms
    00:08   serve   379 -  3,156 ms

CV was 3-25x faster at 00:08 than at 00:04. Any single-run comparison across that
gap is worthless; this is why the A/B interleaves its arms rather than running one
after the other.

## 4. What a day click costs, day-first path (control arm)

11 days opened on a warm app via `WT_TTFF_DAYS`, `WT_PB_NO_FAST_OPEN=1`:

| day | fragments | sessions | TTFF |
|---|---|---|---|
| 2026-08-20 .. 08-27 | none | — | no footage |
| 2026-08-28 | 170 | 1 (2,758 ms) | 4,262 ms |
| 2026-08-29 | 2,876 | 2 (3,344 + 591 ms) | 9,988 ms |
| 2026-08-30 | 2,595 | 2 (3,557 + 1,080 ms) | 9,547 ms |

`[TTFF] SUMMARY n=11 played=3 meanTtff=7932ms`

A heavy day pays **two sequential session creations** on this path: the whole-day
manifest, then the bounded bootstrap that actually feeds the player. Roughly 3.9 s of
the 10.0 s is session creation; the remaining ~6.0 s is the player's own fetch to
first buffered frame.

## 5. Retention: corroborates CV's 5.5 days, it is not a new finding

Camera .126 holds **nothing at all** on 2026-08-20..08-27, and 170 fragments on 08-28
against 2,876 on 08-29 — about three days of usable history.

This is **already explained** and was not discovered here.
`docs/letters/2026-08-21-session-open-is-the-playback-bottleneck.reply.md` §7: the live
`storage_tier_config` reads `hot_days = 1, retention_days = 5.5`, written 2026-08-20.
CV asked us to raise it if anyone on this side had built an expectation on 35 days.
`CLAUDE.md` still states the warm tier holds 35 — **that belief and the config have
still not met**, and this measurement is one more instance of the gap.

The practical consequence for this work: most days a guard can open are LIGHT, which
is why the day-click fast open is gated to heavy days.

## 6. Once the day manifest is off the critical path (SUPERSEDED IN PART BY SECTION 9)

The cleanest open captured, camera .126, day 2026-08-29, fast open engaged
(`fast_open win=30min tgt=00:00:19`), CV warm:

| stage | at | delta | share |
|---|---:|---:|---:|
| session dispatched → `session_ready` | 380 ms | 380 | 7 % |
| → `source_set` (marshal 40 ms) | 420 ms | 40 | 1 % |
| → `mediaStatus=2` (BufferedMedia) | 5,402 ms | **4,982** | **91 %** |
| → `first_frame` | 5,494 ms | 92 | 2 % |

That session cost `ms=377` with `serve;dur=270.2` — **already inside the ≤300 ms
budget §7 of the letter asks CV for.** The deferred day timeline (2.25 MB, 3,558 ms)
landed afterwards, off the critical path, exactly as FAST OPEN intends.

**CORRECTION — an earlier draft of this section read the 4,982 ms as "91 % of the open
is the player, and that half is ours."** That was wrong, and the run that disproved it
is below. `source_set → buffered` is the player fetching segments **through our proxy
from CV**, so it carries CV's cold/warm state exactly as session creation does. It is
not evidence about our player at all.

The same camera, day 2026-08-30, launch 04, with CV warm:

| stage | at | delta |
|---|---:|---:|
| `session_http ms=110` (serve 58.3, index 42.5, 62 frags) → `session_ready` | 112 ms | 112 |
| → `source_set` (marshal 59 ms) | 171 ms | 59 |
| → `mediaStatus=2` (BufferedMedia) | 525 ms | **354** |
| → **`first_frame`** | **614 ms** | 89 |

Same code, same camera, same gesture. `source_set → buffered` was **354 ms here against
4,982 ms there — 14×** — and it moved in lockstep with `index` (42.5 ms vs 241 ms) and
with everything else CV served that minute.

I then read that as "both halves of the open track CV's state". **Section 9 disproves
it.** The `WT_HLS_LOG` run I called for shows CV serving each segment in ~58 ms while we
spend ~5,100 ms transferring 6.7 MB — CV is 1.1 % of that half. The correlation with
`index` was real but coincidental: both got slower when the box was busy.

What survives from this section: session creation genuinely was 112 ms here, the
deferred day manifest genuinely is off the critical path, and 614 ms genuinely happened.
What does not survive: the attribution of the `source_set -> buffered` stage. Read
section 9 for it.

## 7. The A/B: does day-click FAST OPEN actually pay?

8 launches, arms interleaved (`fix,ctl,ctl,fix,fix,ctl,ctl,fix`) so CV's minute-to-minute
drift hits both. Same build in both arms; `WT_PB_NO_FAST_OPEN=1` is the only difference.
`WT_TTFF_DAYS` drives the real `openForDay(day)` gesture. 24 observations.

**Heavy days (2026-08-29, 2026-08-30) — where the gate lets fast open engage:**

| arm | n | median | min | max | censored |
|---|---:|---:|---:|---:|---:|
| **fix** | 7 | **6,128** | **614** | 8,614 | 1 |
| ctl | 8 | 12,454 | 7,126 | 23,817 | 0 |

**Median halved: 12,454 -> 6,128 ms.** The fix arm's whole range (614-8,614) sits below
the control's median, and its best open is 12x faster than the control's worst.

**Light day (2026-08-28) — where the gate declines and behaviour should be unchanged:**

| arm | n | median | min | max | censored |
|---|---:|---:|---:|---:|---:|
| fix | 4 | 11,014 | 4,388 | 21,289 | 0 |
| ctl | 3 | 13,979 | 8,899 | 23,453 | 1 |

Overlapping ranges, no separation. That is the intended result, not a disappointing
one: the gate declines here, both arms run identical code, and the spread is CV's.
It is also the control that shows the gate is not silently firing everywhere.

**Per-day counts:**

    2026-08-28  fix 4388, 9466, 12563, 21289      ctl 8899, 13979, 23453
    2026-08-29  fix 1892, 5494, 7053              ctl 9306, 9528, 12567, 20651
    2026-08-30  fix 614, 6128, 6967, 8614         ctl 7126, 12440, 12467, 23817

**The sub-second bar was met once (614 ms) and missed at the median.** Both facts
belong together: the client work is done and the remaining distance is CV's cold
path. See section 6 for that open's full decomposition.

## 8. Warming does not work, and this closes off the obvious client-side workaround

The natural client response to "cold is slow, warm is fast" is to warm it: prefetch the
session on hover, or on camera select, so the guard's click lands on hot pages. **That
does not work here, and it is worth knowing before someone builds it.**

Ten consecutive opens of the SAME heavy day (2026-08-30, camera .126), fast open on, so
the bounded window request is byte-identical every time (`bytes=49051, frags=62`):

    ms=  7856   serve=  7734.2   index= 7269.7
    ms=  7924   serve=  6022.3   index= 2605.4
    ms=  2588   serve=  1659.2   index= 1156.6
    ms=  8006   serve=  7867.5   index= 5193.9
    ms=  6006   serve=  5588.8   index= 4003.9
    ms=  3771   serve=  2789.6   index= 2449.3
    ms=   970   serve=   845.9   index=  736.3
    ms=  5242   serve=  3085.7   index= 2351.2
    ms= 11802   serve= 11653.1   index= 9767.4

**No warming trend. The slowest request is the last one.** TTFF across the ten:
`-1, 13130, 16362, 10768, 13819, 8105, 6507, 2328, 9137, 17051` — median 10,768 ms,
min 2,328 ms, **zero sub-second opens**.

This is exactly what CV predicted in `2026-08-21-session-open-is-the-playback-bottleneck.reply.md`
§3: *"the recorder continuously writes new chunks that evict the old ones ... any
historical day is cold on first touch, every time."* Their in-process test warmed
7,138 -> 43.5 ms because nothing evicted between back-to-back calls; on the live box
something does.

**Consequence for us:** prefetch-on-hover, speculative session creation and any other
"warm it first" scheme are dead on arrival. A guard does not hover for six seconds, and
even if they did, the warmth would not survive to the click. Do not build it.

CONFOUND, stated: ten opens in ~5 minutes each also deferred-fetch a 2 MB day manifest,
so this run put more load on CV than a guard would. That could depress the absolute
numbers. It does not affect the finding — if warming worked, the trend would fall
despite the load, and it does not.

## 9. THE SECOND HALF IS SEGMENT SIZE, NOT CV's SERVE — and this is the road to sub-second

Section 6 concluded that `source_set -> buffered` "carries CV's cold/warm state" because
it correlated with `index`. **That was inference from correlation and it is wrong.** The
`WT_HLS_LOG` data settles it. 20 segment fetches from the ten-open run:

| | value |
|---|---|
| mean segment size | **6.74 MB** (min 6.10, max 7.39) |
| our mean round trip | **5,117 ms** (min 3,765, max 7,165) |
| CV's mean `serve;dur` | **58 ms** (min 9.1, max 306.5) |
| **CV's share of our time** | **1.1 %** |
| single-stream throughput | **10.5 Mbit/s** |

Two representative lines, both `cache;desc="hit"` so no remux was involved:

    0.ts  ms=3765  hdr=471   bytes=7,386,896  st=[serve;dur=61.4, cache;desc="hit"]
    1.ts  ms=5008  hdr=3124  bytes=6,100,036  st=[serve;dur=63.6, cache;desc="hit"]

CV served each in ~60 ms. Everything else was us pulling 6-7 MB down a link giving
~10.5 Mbit/s single-stream.

**Why this is the answer to "why does YouTube start instantly".** The bounded 30 min
window holds ~62 fragments, i.e. roughly **30 seconds of video per segment, ~6.7 MB**.
The player must have a whole segment (in practice two, before it reports BufferedMedia)
before it can show frame one. YouTube starts fast because its initial segments are
seconds, not half a minute — it needs a few hundred KB, not thirteen megabytes.

**The arithmetic for the operator's bar.** At the measured 10.5 Mbit/s:

    6.74 MB segment  ->  ~5.1 s   (today)
    0.45 MB segment  ->  ~0.34 s  (2 s of video at the same bitrate)

With session creation warm (measured as low as 110 ms) a 2-second first segment puts
first frame around **0.5 s**. That is the whole gap, and it is one server-side setting
rather than a performance mystery.

**Is there a client-side version of this fix?** Two exist and neither is worth doing
before CV answers:

- *Serve a shorter playlist so the player buffers one segment instead of two.* Our proxy
  already rewrites playlists, so presenting fewer entries is cheap. It could roughly
  halve this stage (~5 s -> ~2.5 s) but cannot approach 1 s, and it risks the scrubber's
  duration and seek behaviour — the exact things this station cannot verify.
- *Split one upstream segment into byte-range entries (`EXT-X-BYTERANGE`).* This is the
  real equivalent of short segments, but it means parsing TS packet and keyframe
  boundaries in the proxy. Substantial work and substantial risk, to reimplement client-
  side what one server setting does correctly.

Both are strictly worse than a `target_duration` change. Recorded so the option is
known, not as a recommendation.

Caveat on the throughput figure: it is per-request (bytes / that request's ms), so it is
the single-stream rate, not the link's aggregate capacity. The booth NIC is also
negotiated at 100 Mbps on gigabit hardware, so ~10.5 Mbit/s is about a tenth of even
that. Worth chasing separately, but note that **even at a full 100 Mbit/s a 6.74 MB
segment still costs ~540 ms** and cannot by itself reach the bar. Segment duration is
the lever; link speed only widens the margin.

## 10. I TESTED THE SHORTER-SEGMENT FIX AND IT MADE THINGS WORSE — the real cost is ~1.5 s of fixed per-request overhead

Section 9 predicted that a 2 s segment would give ~0.34 s of transfer and put first
frame near 0.5 s. **That prediction is wrong, and the measurement that disproves it is
mine.** Recorded in full because I had already sent CV an ask built on it.

`WT_HLS_FIRST_SEG_BYTES=<n>` (measurement hook, default off) truncates the body handed
to the player to n bytes and advertises `Content-Length: n`, which is what a shorter
`target_duration` looks like from the player's side.

**Attempt 1 — client-side truncation only.** No effect: 7.7-27.9 s truncated vs
5.1-11.4 s control. The flaw was mine: I truncated what the player saw while still
pulling the whole 7.4 MB from CV, so the link — the actual bottleneck — was unchanged.

**Attempt 2 — also abort the upstream fetch**, so we genuinely stop paying for the tail.
The abort works: mean bytes per segment fell from 6,743,466 to 501,126, and a single
segment fetch fell from ~4,523 ms to as little as 465 ms. And yet:

| arm | segment stage `source_set -> first_frame` | fetches/open | mean bytes | mean ms/fetch |
|---|---:|---:|---:|---:|
| trunc (500 KB) | **6,725 ms** median (n=5) | ~5 | 501,126 | 1,353-2,288 |
| norm (6.7 MB) | **3,677 ms** median (n=4) | ~2 | 6,743,466 | 5,145-5,816 |

**Smaller segments were worse.** The player buffers by DURATION, not by segment count,
so 2 s segments mean ~5 fetches where 30 s segments mean ~2 — and each fetch carries a
large fixed cost. Solving the two arms simultaneously:

    6.24 MB / B = 3.7 s        ->  B  ~ 13.5 Mbit/s   (true transfer bandwidth)
    O = 1.8 s - 0.30 s         ->  O  ~ 1.5 s          (fixed cost per request)

**~1.5 s of fixed overhead per HTTP request to CV.** That is the number that matters,
and no segment size defeats it, because reaching a first frame requires at least one
fetch. It also explains why the 6.7 MB segments look "bandwidth bound": at 13.5 Mbit/s
the transfer is ~4.0 s and the overhead ~1.5 s, and I attributed all 5.5 s to transfer.

**Where the 1.5 s is NOT.** `hdr=` (our time to response headers) ran 141-3,124 ms while
CV's own `serve;dur` on the same responses was ~61 ms, and `cache;desc="hit"`. So it is
not remux, not disk, and not CV's measured handler. It is the same unnamed remainder as
section 2's `serve` minus its own sub-terms — visible now on a second, independent path.

**CONFOUND, and it is a real limit on this experiment.** Aborting a reply destroys the
TCP connection, so the truncated arm pays a fresh handshake per segment, while genuinely
short segments from CV would close cleanly and could be served over a reused connection.
So this does NOT cleanly refute shorter segments — it refutes *emulating* them by
abort, and it establishes the ~1.5 s per-request floor. The honest statement to CV is
"here is the overhead; shorter segments only help if that overhead comes down", which is
what the letter now says.

**What this closes off for us:** there is no client-side segment-size trick. Both the
truncation and byte-range ideas from section 9 are dead for the same reason — they
multiply requests against a backend charging ~1.5 s each.

## 11. The ~1.5 s is NOT the network — baseline round trip to CV is 8 ms

Ten plain HTTP requests to `http://192.168.1.79:8000/review/coverage` from this booth,
outside our proxy, while the wall was running:

    401 in 109 ms  (first, connection setup)
    401 in 9, 7, 6, 5, 6, 8, 9, 7, 9 ms
    median 8 ms

Network round trip **8 ms**. CV's own `serve;dur` on segment cache hits **~61 ms**. An
unqueued segment fetch should therefore reach headers in ~70 ms. We measure `hdr=`
between **141 and 3,124 ms**.

**That gap is up to 3 seconds, and it is neither the link nor CV's measured handler.**
Two candidates remain, on opposite sides of the wire:

1. **Ours.** `fetchTimer.start()` runs immediately *after* `m_nam->get(req)`
   (`HlsProxy.cpp`), and Qt's QNetworkAccessManager queues internally once the per-host
   connection limit is reached — so `hdr=` **includes our own queueing**.
   `prefetchAround()` fires `kReadAhead` independent concurrent fetches on that same
   manager, each now a 6.7 MB segment rather than the ~204 ms one its
   "DO NOT SERIALISE" note was measured against on 2026-07-12.
2. **Theirs, but invisible to them.** Time in the OS accept queue before ASGI sees the
   request would not appear in `queue;dur`, which is stamped in middleware.

This also narrows the retraction in section 2. `queue;dur` under 4 ms proves **CV** is
not queueing; it says nothing about whether **we** are, because a request still sitting
in our own NAM has not reached CV and no timer of theirs is running. Section 12 tests
candidate 1 directly.

## 12. PART OF THE "1.5 s PER REQUEST" IS OURS — our own read-ahead was racing the segment the guard waits for

Candidate 1 from section 11, tested with the existing `WT_NO_PREFETCH` flag. No code
change, 4 interleaved launches, 3 opens each, camera .126, day 2026-08-30:

| arm | mean `hdr=` | mean segment fetch | segs |
|---|---:|---:|---:|
| prefetch ON | 1,121 / 796 ms | 4,777 / 4,910 ms | 6 / 4 |
| prefetch OFF | 440 / **94** ms | 2,258 / **1,942** ms | 6 / 6 |

**Read-ahead was inflating our own time-to-response-headers ~3.6x and the whole segment
fetch ~2.3x.** With a network baseline of 8 ms (section 11), a `hdr=` of 94 ms is about
what CV's ~61 ms handler predicts — and 1,121 ms is not. The difference is queueing
**inside our own QNetworkAccessManager**, before the request ever left this box.

The mechanism is plain once measured: `kReadAhead = 2`, so serving a segment starts
**two more 6.7 MB fetches** on the same manager. That is 13.4 MB racing the 6.7 MB the
player is actually blocked on, over a ~13.5 Mbit/s link.

**This corrects two earlier conclusions of mine, both reached by reading rather than
measuring:**

- I recorded that WT-29 ("defer prefetch") "would have made things worse; the
  DO NOT SERIALISE comment was right". Wrong. That comment was measured on 2026-07-12
  against a **~204 ms** cold segment, where a concurrent successor genuinely did hide in
  the target's shadow. At 6.7 MB and ~5 s per segment it no longer hides — it competes.
- Section 10 attributed the whole ~1.5 s fixed per-request cost to CV. Part of it is
  ours.

**The change shipped** is narrower than the probe: read-ahead is held only for a
session's **first** segment — the one a guard's first frame waits on — and resumes from
the second segment, so the mid-session behaviour the 2026-07-12 note measured is
untouched. `WT_PREFETCH_AT_OPEN=1` restores the old unconditional read-ahead.

### 12a. Validating the narrow change (not the probe)

4 interleaved launches, `hold` (default) vs `WT_PREFETCH_AT_OPEN=1`. The hold fired
3 times per launch, as designed. Measured on **segment 0 specifically**, because that is
the fetch a first frame waits on — a mean across all fetches dilutes it with prefetches:

| arm | seg 0 fetch, median | range | `hdr=` median |
|---|---:|---|---:|
| hold | **4,432 ms** | 3,873-5,167 | **405 ms** |
| old | 4,925 ms | 4,543-7,255 | 783 ms |

Time-to-headers nearly halved and the spread tightened (max 5,167 vs 7,255 ms).

**The gain is modest, and the reason is the useful part: 4,432 ms IS THE BANDWIDTH
FLOOR.** 6.7 MB at the measured 13.5 Mbit/s is ~4.0 s. The hold removes our
self-inflicted contention and lands segment 0 on that floor; nothing else client-side
can go below it. The old arm sat above the floor precisely because our own prefetches
were taking a share of the link.

**Whole-open TTFF did NOT separate** at this sample size: hold median 7,949 ms vs old
5,986 ms (n=5 each), swamped by CV session creation ranging 0.1-14 s on the night. The
change is justified by the mechanism and by `hdr=`/seg-0, **not** by a TTFF win, and it
would be dishonest to claim one.

### 12b. The shorter-segment test deserves a re-run

Section 10 concluded shorter segments made things worse, partly because each extra
request carried ~1.5 s of overhead. **Some of that overhead was our own prefetch
contention, which is now gone.** That test should be repeated with the hold in place
before the idea is written off — the arithmetic that motivated it (fewer bytes to the
first frame) is untouched, and only the per-request penalty argued against it. Not done
here; flagged so the next session starts from it.

## 13. The link is healthy; segment bodies still arrive at 15-26 Mbit/s

With our own read-ahead contention removed (section 12), segment 0 sits on a transfer
floor. That floor is not the booth's network:

    Get-NetAdapter   Ethernet   linkSpeed = 100 Mbps   fullDuplex = True
    Get-NetAdapterStatistics    rcvErr=14  outErr=68  rcvDisc=14  outDisc=0
    baseline RTT to CV          8 ms (section 11)

Full duplex, negligible errors, low latency. A duplex mismatch — the classic cause of
exactly this symptom — is ruled out.

Throughput computed from clean WTHLS lines as `ms - hdr` (body transfer only, excluding
time-to-headers):

    0.ts   3765 - 471  = 3,294 ms for 7,386,896 B  ->  17.9 Mbit/s
    1.ts   5008 - 3124 = 1,884 ms for 6,100,036 B  ->  25.9 Mbit/s
    seg0   4432 - 405  = 4,027 ms for ~7.39 MB     ->  14.7 Mbit/s

**15-26 Mbit/s of a 100 Mbps link.** For contrast, session responses on the same night
transferred far faster — `ms - serve` on the day manifests:

    3344 - 2772.6 =  571 ms for 2,252,683 B  ->  31.5 Mbit/s
    3557 - 3156.9 =  400 ms for 2,059,523 B  ->  41.2 Mbit/s

Same box, same link, same minute: **session bodies move at 31-41 Mbit/s while segment
bodies move at 15-26.** So this is not the link and not a client-wide cap — it is the
rate at which segment bodies are produced upstream. CV's `serve;dur` cannot see it,
because that timer stops when the response begins, not when it ends.

Two candidates, neither testable from here: CV's send path for segment bodies (chunk
size, or a SeaweedFS read behind it), or something between that treats the two
differently. Worth their measurement, not our guess.

**Why it matters for the bar:** at 94 Mbit/s a 6.7 MB segment costs ~570 ms and the
one-second bar is arithmetically reachable with no segment change at all. At 15 Mbit/s
it costs ~4.0 s and no client change can rescue it.

## 14. Concurrency does not buy throughput — which closes the last client-side lever

The obvious remaining client trick is to fetch segment 0 as N parallel HTTP Range
requests, since session bodies get 31-41 Mbit/s while segment bodies get 15-26. Before
building it, the premise was tested against data already captured: with read-ahead on,
three fetches run concurrently by construction.

From `holdab/02-old`, the first burst, measured as union-of-window bytes over wall time:

    3 concurrent fetches   20 MB over 14,758 ms  ->  11.5 Mbit/s AGGREGATE
    single stream                                ->   9.7 Mbit/s

**Three connections bought 19 %, not 3x.** The ceiling is shared and upstream, so
parallel Range requests would gain roughly a fifth — not the 3-4x that would matter,
and not enough to reach the bar. Not built.

This also explains section 12 from the other direction: three streams splitting
~11.5 Mbit/s leave the segment the guard is blocked on with about a third of the link,
which is exactly the ~2.3x inflation the prefetch A/B measured.

**With this, the client side is exhausted, and it is exhausted by measurement rather
than assertion:**

| lever | status |
|---|---|
| stop fetching the whole day first | DONE (1.1.239), median 12,454 -> 6,128 ms |
| stop paying two session creations | DONE (1.1.237/239) |
| stop our read-ahead racing segment 0 | DONE (1.1.248), seg0 to its bandwidth floor |
| warm CV's cache from the client | TESTED, does not work (section 8) |
| shorter segments, emulated client-side | TESTED, worse (section 10); re-test flagged |
| parallel Range fetch of segment 0 | TESTED via premise, buys ~19 % (this section) |

What is left is two server-side numbers: session creation (0.1-14 s) and the rate
segment bodies are produced (section 13).

## 15. Reading `ttff=-1` in this data

`ttff=-1` means **no frame arrived within the harness's fixed 30 s dwell**, not a
product failure. The one control-arm instance (08-28, launch 02) shows why:

    session_http ms=24629  serve=20190.5  index=13976.4  frags="119"
    session_http ms=19478  serve=14961.6  index=11476.9  frags="173"
    session_ready dt=19480ms   source_set dt=19494ms
    [TTFF] day=2026-08-28 ttff=-1ms err=-

`err=-` — no error state was reached. CV was simply very cold; the session took 19.5 s
to create, the source was set at 19.5 s, and the dwell ended before the player could
buffer. Counting that as a failure would overstate breakage; counting it as a fast open
would understate the cost. It is a censored observation and is reported as such.

It also brackets the night's spread: `index;dur` ranged from **241 ms to 13,976 ms** —
58× — on the same endpoint and the same camera within about an hour.

## 16. CV refused connections for ~12 s mid-run

Launch 05, ~00:41, immediately after a normal open on the previous day:

    [PBTIME] open tag=day:2026-08-29
    [PBTIME] fast_open win=30min tgt=00:00:19
    [PBTIME] session_http ms=4092 code=0 bytes=0 attempt=0 st=[]
    [PBTIME] session_http ms=4156 code=0 bytes=0 attempt=1 st=[]
    [PBTIME] session_http ms=4093 code=0 bytes=0 attempt=2 st=[]
    [TTFF] day=2026-08-29 ttff=-1ms err=Couldn't reach the recording backend (Отказано в соединении)

`code=0`, no body, no `Server-Timing` — **connection refused**, three times, ~4 s
apart. Not a timeout and not a client fault; the socket was rejected. It recovered
without intervention.

Reported rather than diagnosed: from this station we cannot tell a query-api restart
from a crash from a deploy. It is worth CV's attention on two counts — the guards'
console depends on that service, and a restart would also explain part of the night's
cold/warm swing, since a fresh process starts with an empty PostgreSQL buffer cache.

The client behaved correctly throughout: three attempts, then an honest error naming
the backend, no invented state.

## 17. What this does not establish

One camera, one night, ~20 requests. The distribution across the fleet and across the
working day is unmeasured. `index` varied 3x within seconds, so its spread is real and
uncharacterised. The player-side ~6.0 s half has not been decomposed here — that needs
a WT_HLS_LOG run against the segment fetches and is the next measurement, not a
conclusion.
