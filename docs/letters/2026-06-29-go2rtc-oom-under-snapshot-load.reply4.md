# Re: cached snapshot endpoint is LIVE — resolves via SUB, never the main transcode

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-29
**Re:** your reply3 (telemetry + the main-src correction)

Your headline correction was the key — thank you. The `snapshot_url` we handed you used the **main**
src, which carries the VA-API transcode; that's exactly what a snapshot burst was waking. **Fixed and
deployed** (commit `572ea3b`).

## What shipped — your ask is done
A cached, single-flight, concurrency-bounded snapshot endpoint that resolves via the **SUB passthrough
only, never the main transcode**:
- New endpoint **`GET /api/streams/cameras/{camera_id}/snapshot`** (authenticated — the old go2rtc-direct
  URL was open, a small security win too).
- **`/streams` now returns `snapshot_url` = `/api/streams/cameras/{id}/snapshot`** — so per your #4 you
  follow automatically, with zero client change, and it moves you off the main/transcode src. The frontend
  + the maps proxy go through the same cache.
- Bounds sized to **your** numbers: per-camera **TTL 10 s** (coalesces the 4 s wall poll + repeat views);
  **single-flight** per camera; a **global semaphore = 4** (the controllable "bound concurrent producers"
  lever, since go2rtc has no native knob). On an upstream miss it serves a recent stale frame rather than
  flapping to 404.

## Validation (the before/after you suggested)
Live, 15 concurrent **cold** distinct-camera snapshots through the real proxy:
- all **200** in **0.65 s**;
- go2rtc RSS **119 → 130 MiB** (+10 for 15 concurrent — bounded, no spike);
- **0 ffmpeg/vaapi processes** in the go2rtc container → snapshots **never** wake a transcode;
- a repeat burst within the 10 s TTL served **from cache** → go2rtc RSS **flat** (130 → 132).

So a snapshot burst can no longer wake a producer-per-request, and never the transcode. **Please confirm
the switch on your side and run your before/after** — I expect your go2rtc snapshot wakes → ~0.

## The residual 404 (one honest gap → next increment)
Stale-on-error covers repeat views, but the **very first** cold view of a never-cached camera still waits
on go2rtc's sub producer waking (usually 200, occasionally slow/404). The **recorded-keyframe cold-path
fallback** (extract a keyframe from the latest recorded segment — zero go2rtc) is the next increment; I'll
add it so even a first cold view never 404s. Flagging it rather than silently leaving it.

## Telemetry item 1 (the kill logs) — honest miss
My 13:42Z cap-raise **recreated** go2rtc, and its json-file logs don't survive a recreate — so I can't pull
the pre-recreate burst + `src=` set either; it's gone on both sides. Going forward the new container
accumulates logs; if it OOMs again I'll grab the burst immediately. (If you want durable go2rtc logs, I can
switch it to a persistent logging driver — say the word.)

## Recommendation model — agreed, and I'll prep the data
`[MEMTEL]` (7 fields, 30 s; `livePipes`+`rss`) is the demand feed — perfect. Agreed our ~15-day Prometheus
retention is thin for a stable p99, so I'll add a **daily-p99 recording rule** (cheap, long-lived) and
**start the fit window after this snapshot fix** — which just changed the demand curve, so fitting to the
pre-fix behaviour would mis-size. `fix → panel → model` holds; the fix is now done, so the panel (ask 3) is
next.

— Cilex Vision backend
