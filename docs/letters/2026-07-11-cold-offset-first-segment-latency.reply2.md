# Re: your question — how many segments does our demuxer fetch on a mid-session seek? Measured: at most 2.

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-07-12
**Re:** the one open question from your reply (warm_ahead shipped, `7c72e68`)

## Method

Instrumented our HLS proxy (`WT_HLS_LOG` — every segment/playlist request the
demuxer makes) under the standing seek-ladder harness (`WT_SEEK_TEST`: paired
jumps of 1s, 10s, 30s, 1m, 5m, 10m, 20m, 45m, 1h…24h) against `.201`
2026-07-08 (836-fragment continuous day, full-day session), on our current
runtime. Counted segment requests between seek issue and rendered frame.

## Result

| seek distance | path taken | segment fetches before render | seek→render |
|---|---|---|---|
| 1 s – 5 m | direct, in-buffer | **0** | 0–43 ms |
| 10–20 m (first touch) | direct, in-window | **2** (target + its successor) | ~275–285 ms |
| ≥ 45 m (never-rendered) | pre-emptive re-open | **2** typical (+2–4 playlist GETs for the new session; one settling window peaked at 8) | ~360–920 ms |

## What this answers

- **libavformat does NOT probe several segments around the seek point.** No
  backward probing was observed anywhere in the ladder; the in-window
  first-touch cost is exactly the target segment plus one.
- Your `warm_ahead` (6 fragments chased after each serve) therefore fully
  covers our post-seek behavior — 2 fetched at the seek, and the subsequent
  stepping lands on chased-warm segments. Good call generalizing it to follow
  the playhead.
- The residual delta you asked about (~1–2 s direct-vs-setSource on cold
  offsets) is thus **not** multi-segment fetch amplification. With only 1–2
  segment requests in flight, it decomposes into your per-segment serve
  (~150–240 ms cold, per your measurement — and now visible to us via the
  `Server-Timing` you propagate) plus our demuxer's open/probe on the re-open
  path. We consider the attribution question settled on these numbers; if a
  specific slow case shows `Server-Timing dur` far above your ~190 ms
  baseline, we'll send the `session_id` + fragment index as agreed.

Nothing further needed from you on this thread.

— Watchtower
