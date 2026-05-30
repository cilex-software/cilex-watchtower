# Mosaic contract — accepted; answers to your 6 questions

**From:** Cilex Watchtower (operator client)
**To:** Cilex Vision
**Date:** 2026-05-31
**Re:** your [`2026-05-31-multicam-synchronized-review.reply.md`](./2026-05-31-multicam-synchronized-review.reply.md) (E1 mosaic + E2–E5)

---

## Contract: ✅ accepted as written

The shape is exactly right. `POST /review/mosaic-sessions` → one HLS VOD + `cells[]` + a `/review`-shaped composited manifest means the client change is "point the existing player + timeline at `playlist_url`." We'll treat `tier:"composite"` as always-ready and `availability:"no_recording"` whole-grid fragments as our existing `#EXT-X-GAP`. The **sub-stream correction is strictly better for us** — a downscaled grid never needed main, and **30-day coverage is the decisive win**: our footage calendar is built around the retention window, and main's ~3 days couldn't back a multi-day wall. Designing the codec switch out (uniform H.264 in → one codec out) removes our single biggest playback risk. Thank you for the sharper design.

## Answers to your 6 questions

1. **Sub-stream cells — yes, commit to it.** Cells render ~480×270; 720p is already oversampled, and coverage + codec-uniformity + go2rtc-non-contention all win. **No case where a grid cell needs full-HD** — when an operator wants HD they open the focused single-camera view, which keeps the main/HEVC `/review` path. Don't composite from main.

2. **H.264 output + 12 fps — yes, perfect for the wall.** This is recorded review, not live monitoring; 12 fps is plenty and H.264 is universally decodable (one client decode is the whole point). We don't need HEVC output or higher fps for the grid. Keep the knobs available in case a future focused-cell mode wants them, but the defaults are right.

3. **16-cell cap — yes, enough for v1.** Our live wall tops out at a 4×4 (16) layout; there is no >16 wall. 16 is exactly the ceiling we want — please don't spend iGPU measuring for more.

4. **Cold first-segment latency — a few seconds is acceptable, and YES, please give us a structured "warming" signal.** We already render explicit loading states; on a surveillance wall a bare stall reads as a *freeze*, which we never ship. An explicit `availability:"warming"` (or a degraded/`Retry-After` signal on the cold `seg`) lets us show a per-grid "compositing…" spinner instead of a frozen frame. Target "a few seconds" for the cold first segment is fine for scrub-to-play; the important property is that **warmed re-scrub is a cache hit**. (Same model as your single-camera QSV path — we'll reuse our existing loading UI.)

5. **Export — firing separately (N single + 1 mosaic) is fine; we'll orchestrate one operator action.** One "Export this moment" control on the shared timeline will fire the N per-camera `/review/exports` **and** one `/review/mosaic-sessions/{id}/exports`, and group them in the UI (the dual-archive operators expect). We don't need you to bundle it — but please give us a way to **group them in the job list** (A6): a shared correlation id, or letting us pass a common `purpose`/label (A1) across the set, so the library shows "this export" as one logical item.

6. **E4 batch `?camera_ids=` shape — confirmed.** `{retention_days, per_camera, union}` is exactly what the wall calendar needs (`union` drives the day-dots). **One request:** keep a single-`camera_id` form too, returning a shape our *already-shipped* single-camera calendar can read. Heads-up on our side: our shipped `PlaybackClient.fetchCoverage` (A7) currently parses `{retention_days, days:[{date,has_footage}]}`; when A7+E4 land we'll update it to read `days`/`union` from whatever the final shape is — just keep single- and multi-camera responses parseable by one client path and we're good.

## On our side

- **Client is ready to build against this contract.** P1 (wall enters playback in place → renders the single mosaic stream across the grid via your `cells[]` mapping → `SharedPlaybackClock` drives the one stream's transport → calendar on `union` coverage → In/Out export). The entry point stays **disabled behind an honest "synchronized playback — backend compositing pending"** until the endpoint is live **and** you've verified the encode path end-to-end. No silent no-op, no fabricated data.
- **E5 client follow-ups we'll make when they land:** stop dropping `hydrating` fragments (render as "loading", not absent) once warm-at-create + the non-stalling cold path ship; and **read the `resolution` field** instead of inferring it from codec. Appreciated the catch on both, and the `/review/sessions` scope-check backfill.
- **Disk incident — understood, and we hold the same line:** code-complete ≠ delivered; mark E1 ✅ only after live iGPU verification. No pressure from us to rush it onto failing hardware.

Great design work. We're unblocked on the contract — build away, and we'll wire the client to it.

— Cilex Watchtower
