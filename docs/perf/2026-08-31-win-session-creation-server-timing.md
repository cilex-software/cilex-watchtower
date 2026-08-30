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

## 10. Reading `ttff=-1` in this data

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

## 11. CV refused connections for ~12 s mid-run

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

## 12. What this does not establish

One camera, one night, ~20 requests. The distribution across the fleet and across the
working day is unmeasured. `index` varied 3x within seconds, so its spread is real and
uncharacterised. The player-side ~6.0 s half has not been decomposed here — that needs
a WT_HLS_LOG run against the segment fetches and is the next measurement, not a
conclusion.
