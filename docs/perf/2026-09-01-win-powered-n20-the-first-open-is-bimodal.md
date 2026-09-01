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

## Method note

n=20, single configuration, no A/B. Splitting 20 samples into arms would give n=10
per cell, which on this station is not enough: the same request has been measured
varying 567× with our own concurrency, and six hypotheses at n=3–4 on 2026-09-01
produced five reversals. Characterising the deployed state with all 20 samples was
worth more than a weak comparison.

**Every performance figure in this repo dated 2026-09-01 and not from this run
should be treated as provisional.**
