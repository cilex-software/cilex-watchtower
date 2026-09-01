# Powered n=20: the first open is BIMODAL, and 5 of 20 are sub-second

**Station:** `wt-sm-vnutri-01` (guard booth, Win 11) · **Date:** 2026-09-01, 14:20
**Build:** 1.1.320 as deployed (coverage + ip-map disk cache on, no overrides)
**Method:** 20 launches, first open of each process measured. This supersedes every
n=3–4 figure from earlier the same day.

## Result

    first-open TTFF, 20 samples, sorted:
      672   798   837   959   970  1181  1201  1368
                 <- nothing between 1,368 and 4,374 ->
     4374  4711  5147  5297  5303  5332  5560  5928  5965  7710  7825  8806

    min 672    p50 4,929    max 8,806
    under 1,000 ms:  5/20
    under 2,000 ms:  8/20

**The median is close to meaningless here.** There is no central tendency — there
are two modes and an empty gap between them. Reporting "p50 4,929 ms" describes a
value that never actually occurs.

## The goal IS reached, 25 % of the time

Five first opens landed under one second: **672, 798, 837, 959, 970 ms**. On a cold
process, on this link, with the 100 Mbit device still in place.

So sub-second on a first open is not out of reach on this hardware. It is
**intermittent**, and the question is what selects the mode.

## What is NOT the cause

**Not the FAST OPEN gate.** `gate=FAST` in **20 of 20** — the deployed cache fires
every time and the 2.25 MB / 2,882-fragment whole-day manifest is never fetched on a
first open. That change is confirmed at n=20.

**Not CV's session time.** `serve;dur` for the bounded session, by mode:

    fast mode   2326, 3005, 60, 579, 179, 68, 60, 225 ms
    slow mode   2711, 92, 1900, 124, 163, 3254, 51, 604, 135, 1782, 129, 1903 ms

The same range in both. CV's API is not what costs the four seconds.

**Not our request concurrency at dispatch.** `inflight_shared=6` in all 20 launches —
no variation to correlate with.

## So it is downstream of the API

With the session created quickly and the gate always taking the bounded window, the
4.4–8.8 s in the slow mode is spent in the media pipeline: fetching and decoding the
first fragment(s). The `seg/0` column in this run cannot settle it — the harness
takes the first `seg/0.ts` anywhere in the log, which is not reliably the first
open's fragment. **That is the next thing to instrument: tie the segment fetch to the
open that is waiting on it.**

A plausible mechanism, consistent with the earlier camera-118 finding: the slow mode
needs an extra segment before the first frame (~4.5 s at this link's ~15 Mbit/s
effective segment throughput), and the fast mode does not. Unproven.

## What selects the mode: waiting for a full-size fragment

Traced per launch — segments that COMPLETED before `first_frame` of the first open:

| segments completed before first frame | fast (<1.4 s) | slow (>4.3 s) |
|---|---|---|
| **0** | 6 — L01, L02, L03, L06, L07, L16 | 2 — L19, L20 |
| **≥1, full-size (4–7 MB)** | 2 — L05, L08 | 10 |

**10 of 12** launches that consumed a full fragment before first frame were slow;
**6 of 8** that consumed none were fast. Four exceptions, so this is the dominant
cause and not the only one.

The two traces side by side:

    L02  (672 ms)              L13  (8,806 ms)
      +137 session_ready         +2,531 session_ready
      +204 playlist 4,873 B      +2,624 playlist 4,873 B
      +672 FIRST FRAME           +8,659 seg/0  7,386,896 B in 6,033 ms
           (no fetch completed)  +8,663 seg/1  6,100,036 B in 5,918 ms
                                 +8,806 FIRST FRAME  (147 ms after seg/0 landed)

**The fast mode never waits for a fetch to finish** — the proxy's streaming path
(added 2026-08-30) hands the decoder early bytes and it renders. **The slow mode
consumes an entire 6–7 MB fragment first**, and first frame follows within ~150 ms
of that fetch completing.

So the lever LOOKED like fragment-0 SIZE. **A powered test says otherwise — see the
next section. Do not act on this paragraph.**

**What is still unexplained:** L19 and L20 were slow (5,147 / 5,303 ms) with NO
segment completing first, and L05/L08 were fast (1,201 / 837 ms) despite consuming
one. Whatever accounts for those four is a second, smaller effect.

## REFUTED at n=20: trimming fragment 0 makes it WORSE

`WT_PB_HEAD_OFFSET_MS=15000` aims the window head ~15 s into the footage so it lands
mid-segment and the fragment gets trimmed. Twenty launches, same conditions, against
the twenty-launch baseline above:

    metric                    baseline      head-offset ON
    sub-second first opens       5/20             0/20
    under 2,000 ms               8/20             4/20
    min                        672 ms          1,511 ms
    p50                      4,929 ms          4,510 ms

**It eliminated every sub-second open.**

And the trim itself worked — `seg/0` came back at ~1.0–1.6 MB across the ON arm
against the baseline's mix of ~1 MB and 7.4 MB. So fragment 0 was genuinely smaller
and first-frame time still got worse.

### Why, most likely

**The day's first footage instant is a keyframe** — the recording starts there. The
shipped default (`first − 2 s`, clamped to day start) therefore lands the window on
a clean decode start. Aiming +15 s in lands mid-GOP, and waiting for the next
keyframe costs more than the smaller fragment saves.

**The shipped default is correct**, and the reasoning that motivated the offset —
"the head lands on a boundary, so `head_split` has nothing to cut" — had it exactly
backwards: landing on that boundary is the *good* case.

### What this means for the bimodality

Fragment-0 size correlates with the mode but does not cause it. The correlation in
the section above is real (10/12 and 6/8) and the causal reading of it was wrong.
The likely true variable is **whether the first fragment begins on a keyframe**,
which the size reflects only incidentally.

`WT_PB_HEAD_OFFSET_MS` stays in the tree at default 0 (= `−2000`, today's
behaviour). **It is a measured dead end, not an unexplored option.**

## Method note

n=20, single configuration, no A/B. Splitting 20 samples into arms would give n=10
per cell, which on this station is not enough: the same request has been measured
varying 567× with our own concurrency, and six hypotheses at n=3–4 on 2026-09-01
produced five reversals. Characterising the deployed state with all 20 samples was
worth more than a weak comparison.

**Every performance figure in this repo dated 2026-09-01 and not from this run
should be treated as provisional.**
