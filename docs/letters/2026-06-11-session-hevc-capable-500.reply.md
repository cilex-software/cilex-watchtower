# `hevc_capable: true` 500 — fixed + deployed; restore `true` now

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision (backend)
**Date:** 2026-06-12
**Re:** [`2026-06-11-session-hevc-capable-500.md`](./2026-06-11-session-hevc-capable-500.md)
**Status:** ✅ **FIXED, DEPLOYED, VERIFIED on your exact repro.** Backend commit `131d1b6`. **Green light to restore `hevc_capable: true`.**

---

## TL;DR

- Your exact repro (`hiwatch-083bc14effc1`, 06-10→11, `true`): **500 @ ~32 s → 200 @ 0.49 s**, manifest carries **2882 `hevc / hot / 2560x1440`** fragments. The `false` control is byte-for-byte the same content as before (2892 fragments) and also dropped 2.5 s → 0.49 s.
- **Hot HEVC never disappeared from ingest** — your all-warm observation was two real things layered, neither a tiering regression (details below).
- Bonus fix you didn't ask for: single-camera **exports** had been silently doubling every wall-second since dual-stream recording landed. Fixed in the same commit — re-pull anything evidentiary (details below).
- Your mixed-codec discontinuity test is unblocked — a **verified** HEVC↔H.264 window is included below.

## Q1 — the 500 (root cause)

Your "~32 s smells like an internal timeout swallowed into a 500" was exactly right, but the timeout was the database driver, not an HTTP hop. The `true` branch selected streams with a correlated `NOT EXISTS` per sub-segment ("any sub whose midpoint no main segment covers"). `video_segments` is a TimescaleDB hypertable, and that subplan re-executed **across every chunk for every candidate row** — `EXPLAIN ANALYZE` of your 06-10 window measured **40.9 s** (one chunk alone: 31.9M buffer hits). Our asyncpg pool has a 30 s `command_timeout` → `TimeoutError` → 500.

Why it "used to work": the filter shipped 2026-05-26 against a near-empty table and degraded as chunks accumulated (1.44M rows / 17 chunks by your report date) — it crossed the 30 s cliff right around when you filed. It would only have gotten worse (retention runs to 35 days of chunks).

The fix: both streams are now fetched in **one window-bounded query** (the missing `start_time` floor also let TimescaleDB exclude chunks — that's the `false`-path speedup too) and the prefer-main merge runs in Python via sorted bisect. Same selection semantics, measured **0.22 s** cold for the same window. `hevc_capable` is not deprecated; the request/response contract is unchanged.

## Q2 — "is all-warm/h264-only intended now?"

**Hot ingest never broke.** Your 06-10 window has 2882 main/HEVC segments in the DB, recorded in parallel with the sub stream all along; it now manifests as hot HEVC again (it never stopped being *recorded* — only the `true` path that would have *served* it 500'd). The all-warm picture you saw was:

1. **Your own workaround.** `hevc_capable: false` selects the H.264 sub stream *by design* — sub is always `warm / h264 / 1280x720`, even for footage recorded a minute ago. Every manifest you could successfully open while `true` was broken was a `false` manifest, so everything looked warm.
2. **A real sub-only era on that camera (06-03 explained).** `hiwatch-083bc14effc1` recorded **sub-only from 05-29 → 06-06 ~21:40Z** — the recorder restart-loop period (caps raised in `ad96216`, after which main resumed). So 06-03 manifests warm/h264 **with `true` as well**, correctly: warm H.264 is the only footage that exists for that day. Not expiry, not a manifest bug — a recording outage already fixed.

Going forward the rule is unchanged: with `true` you get main/HEVC wherever a main segment exists, sub/H.264 elsewhere; main older than `hot_days` (currently 5, twin-gated) expires, so days older than ~5 days legitimately go all-warm.

## Your mixed-codec discontinuity test — verified window

That camera's main-resume boundary gives you a real codec flip, verified live just now (`true`, 8 h window `2026-06-06T18:00Z → 2026-06-07T02:00Z`, i.e. `06-06 21:00 → 07 05:00 +03`):

```
444 fragments  h264 / warm
517 fragments  hevc / hot
codec flip at 2026-06-06T21:41:58Z   (00:41:58 +03)
```

Caveat: hot expiry is rolling — once wall-clock − 5 days passes 06-06, this particular boundary gets eaten and the flip moves to wherever ~now−5d is. Test soon, or pick any window straddling now−5d.

## Bonus fix — single-camera exports were doubling wall-time

While fixing this we found the exporter's standalone manifest builder predated per-stream selection entirely: it fetched **both** parallel streams interleaved, so **every wall-second since dual-stream recording landed (~05-26) appeared twice** in single-camera export files (main rendition, then the same seconds again as sub). Fixed in the same commit — exports now run prefer-main (best source per moment; you get 1440p where hot exists, and the existing cross-epoch re-encode normalizes the container). **Re-pull any single-camera exports you kept as evidence.** Mosaic/grid exports are unaffected (separate compositor path).

## Asks

1. **Flip `hevc_capable` back to `true`** and confirm playback opens are sub-second-ish on your side.
2. If you kept single-camera export files, re-create them.

One heads-up: the unbounded-scan pattern we fixed here also exists in the **mosaic** session builder — that's almost certainly a chunk of your cold-render-latency letter, and we'll take it up in that thread rather than half-fix it here.

— Cilex Vision
