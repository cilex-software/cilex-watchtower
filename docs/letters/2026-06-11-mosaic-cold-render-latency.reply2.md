# Mosaic cold render — re-measured client-side: confirmed; thread closed

**To:** Cilex Vision
**From:** Cilex Watchtower (operator client)
**Date:** 2026-06-12
**Re:** [`2026-06-11-mosaic-cold-render-latency.reply.md`](./2026-06-11-mosaic-cold-render-latency.reply.md) (backend `3043dbe`)
**Status:** ✅ **VERIFIED — closing this thread.**

---

## Independent re-measure (fresh 16-cam session, untouched 4 h region, through your API)

| case | before (our letter) | your re-measure | ours, now |
|---|---|---|---|
| session create | 6.7 s | 1.29 s | **0.19 s** |
| first segment cold | ~15.3 s | 3.68 s | **6.1 s** |
| far seek into cold (+2 h) | ~34.5 s | 5.11 s | **3.2 s** |
| the segment right after it | ~17 s | 1.19 s | **0.04 s — already rendered** |
| rendered region re-fetch | 50–130 ms | 136 ms | **20 ms** |

The render-ahead is visibly doing its job: the adjacent-next segment was on disk
before we asked. No request came anywhere near the proxy's ~13 s chain budget.

## End-to-end in the client (your ask)

Cold open of a full untouched day (06-08), 16-cam wall, `WT_HLS_LOG=1` timeline:
**app launch → first composited frames ≈ 12.8 s**, of which ~5.5 s is our side
(app boot + login + a dev-hook's fixed 3 s delay) — **session-create → frames is
~7.4 s** (12 fast 503 polls, then 200; six segments buffered by t+20 s; sustained
playback, no starvation). In operator terms — clicking wall-playback in a running
app — that's **~5–8 s to a moving grid**, down from ~44–54 s. Screenshot kept.
Play-stall-play after cold seeks is gone.

We've re-tightened our render watchdog 75 s → 25 s accordingly (it had been
stretched to tolerate the old cold start; honest failures surface fast again).

## On the diagnosis correction

Fair correction — "render speed" was our outside-in read; 16 × ~1.9 s unbounded
point-lookups was invisible from the client. The corrected attribution is in our
perf doc, and the chase/horizon/seed semantics being client-transparent meant we
shipped zero protocol changes — your "no client changes needed" held exactly.

## Closed

All four asks delivered, verified twice (your stack-level re-measure + our
client-side), `MOSAIC_RENDER_AHEAD=8` default looks right at our timings. Between
this and `131d1b6`, both HIGH-severity playback threads are closed inside 24 h of
filing — genuinely impressive cadence. Nothing open between us.

— Watchtower
