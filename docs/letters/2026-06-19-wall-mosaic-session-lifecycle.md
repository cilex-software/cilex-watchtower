# Wall (mosaic) playback stalls under repeated day/window changes — session lifecycle

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend / compositing)
**Date:** 2026-06-19
**Re:** `POST /review/mosaic-sessions` has no disposal/reuse, so repeated wall navigation piles up composite
jobs and new sessions open-then-stall. Full data: `docs/perf/2026-06-19-wall-playback-stress.md`.

## TL;DR

I stress-tested the 16-camera synchronized wall (real VA-API decode), moving the playhead 240 times and timing
when the composited grid replays. **Seeking inside an open session is great — ~105 ms, 100% reliable.** But
**"jump to another day" (re-open) is slow (median ~8 s) and fails 56% of the time**: the new session opens fine
(`onMosaicSessionReady` always fires, no error), then its HLS stream produces **no frames for ~20 s** and
recovers in bursts. Root cause looks like compositing-resource backpressure: each re-open does
`POST /review/mosaic-sessions` (a fresh 16-cam ffmpeg composite) and **nothing ever disposes the previous
session**, so under repeated navigation jobs accumulate faster than they render + idle-reap.

## Evidence

- 56% of 80 re-opens timed out (22 s) with the video sink's frame counter **frozen** across consecutive jumps
  (stuck at the same value, e.g. 1824 → 1952 → 2048, then jumping when it recovers) — i.e. the composite stream
  is dead, not merely slow. Successful re-opens still cost 3–23 s.
- **No HTTP 5xx and no GStreamer errors** during the stalls — silent backpressure.
- After the run, `query-api` / `playback-service` show **0 mosaic ffmpeg** — so abandoned sessions *are*
  eventually reaped (idle timeout), it's the **transient pile-up** during bursts that exhausts the renderer.
- Client side: `PlaybackClient::openMosaicSession()` only ever POSTs; there is **no close/DELETE** call, and
  `GET /review/mosaic-sessions` returns *Method Not Allowed*, so we have no way to release or even list a session.

## What would help (in rough priority)

1. **(B1) Disposal endpoint** — `DELETE /review/mosaic-sessions/{id}` (idempotent). We'll call it when the wall
   re-opens a different window and when the operator leaves the wall, so you can free that composite immediately
   instead of waiting for the idle timeout.

2. **(B2) One-wall-one-session + bounded concurrency** — when a client opens a new mosaic session, **reap/replace
   its previous one** server-side (we can pass a `replaces=<old_sid>` or a stable `wall_client_id` if that's
   easier than us calling DELETE). And cap concurrent composite jobs so a burst **rejects fast** (or queues with a
   clear status) rather than opening sessions that then stall with no frames. A fast, honest failure we can show
   beats a 20 s silent freeze.

3. **(B3) Faster cold start / pre-warm** — the first frame after a cold seek (even *within* a session) is ~3.3 s,
   independent of jump distance, so it's the cost of compositing+buffering one cold 16-cell segment. Anything that
   pre-warms a few segments around the requested playhead (or speeds the cold composite) directly cuts both the
   re-open time and the in-session cold-seek time.

## What we're doing on our side (no backend dependency)

- **Widening the default wall window** (1 h → ~12–24 h) so day-scale navigation becomes an in-stream seek
  (~0.1 s) instead of a re-open — this alone removes most re-opens. Lazy compositing means the wider window costs
  nothing until the operator actually seeks there. (Confirm that's fine — we're relying on segments being
  composited on demand, not eagerly for the whole window.)
- **Debouncing** window/zoom changes so a flurry of clicks creates one session.
- Keeping the last frame + a "compositing…" affordance visible so a slow re-open never looks frozen.

## One question (Q1)

For **B2**, do you prefer we **call `DELETE` ourselves** (needs B1), or pass a **`wall_client_id` / `replaces`**
so you reap the prior session on the next open? Either works for us — whichever is cleaner for the renderer's
bookkeeping.

— Watchtower
