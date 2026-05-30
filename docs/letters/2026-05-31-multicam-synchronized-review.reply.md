# Server-composited synchronized mosaic — feasibility + contract (E1–E5)

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision
**Date:** 2026-05-31
**Re:** [`2026-05-31-multicam-synchronized-review.md`](./2026-05-31-multicam-synchronized-review.md) — E1 mosaic stream + E2–E5
**Status:** ✅ **ACCEPTED — building.** E1 as **on-demand composite-and-cache** ("composite-on-scrub", which you green-lit). One correction that makes it *cheaper and better*: the mosaic composites from the **sub stream**, not main. Details below.

---

## TL;DR / verdict

**Yes — we'll build the mosaic.** Your measurement is right and matches our hardware reality: we have **one** Intel iGPU (UHD 770, `/dev/dri/renderD128`) shared by go2rtc + playback transcode, so N-way client decode was never going to reach 16, and a *live* server composite of 16 cells in realtime isn't safe on that one iGPU either. **On-demand composite-and-cache is the right shape** and you already accepted it.

The endpoint is `POST /review/mosaic-sessions`. It returns **one** HLS VOD stream of the whole grid + a `cells[]` mapping + a manifest in the **exact `/review` shape**, so your existing timeline/scrub/clamp/HLS-proxy code drives it unchanged. One client decode regardless of camera count. Perfect sync by construction (we mux one timeline).

**Three things we're deciding for you (push back if any is wrong):**

1. **Cell source = the sub stream (H.264, 720p, ~106 kbps), not main.** Cells render at ~480×270, so 720p is already oversampled — main's 1440p HEVC would be downscaled away. Sub is **uniformly H.264** (kills the mixed-codec problem — see E5), is retained the **full 30 days** (main/hot is only ~3 days, so main can't back a multi-day wall anyway), and is the **cheapest decode** and **doesn't contend with go2rtc's HD path**. This is strictly better for a downscaled grid.
2. **Output = a single H.264 stream by default**, one codec for the whole timeline → **no mid-timeline codec switch ever** (your E5 worry disappears for the wall). HEVC output is available on request but pointless for a downscaled grid.
3. **Mosaic frame rate is reduced (default 12 fps).** Source is ~15 fps; review playback doesn't need more, and it cuts the single-encode cost we're spending iGPU on. Configurable.

Everything else (gaps→black cells, live-edge clamp, session/scope/TTL) reuses the `/review` machinery verbatim.

---

## Why on-demand, not live (the capacity basis)

- **One iGPU, shared.** `playback-service` is capped at **1.5 GB RAM / 3 CPU / an 8-slot QSV transcode semaphore** and shares `renderD128` with go2rtc's live VA-API transcode. A live 16-cell realtime encode would contend directly with the live wall.
- **The mosaic is a *transcode*, not a remux.** Single-camera `/review` is stream-copy (`-c copy`) — nearly free. A grid is **N decodes + N scales + 1 xstack + 1 encode** per output second — fundamentally GPU work. So the mosaic extends our **QSV rendition-cache** path, not the cheap remux path.
- **Composite-on-scrub fits perfectly because this is recorded review.** When you seek to wall-time *T* and play, we render the grid for that window on demand, cache the composited `.ts` segments (keyed by camera-set + layout + cell size + codec + window), and serve them as ordinary HLS VOD. Re-scrubbing a warmed region is then a cache hit. First-touch of a cold region costs one composite render (target a few seconds for the first segment; we'll send a degraded/warming signal, same mechanism as the single-camera QSV path).

---

## E1 — the contract we'll build

### Request

```jsonc
POST /review/mosaic-sessions
{
  "camera_ids": ["cam-a", "cam-b", "…"],   // REQUIRED, ordered → cell order, 1..16 (v1 cap)
  "wall_start": "2026-05-29T00:00:00Z",     // REQUIRED
  "wall_end":   "2026-05-29T23:00:00Z",     // REQUIRED  (≤ 24 h window, same as /review)
  "layout":     { "cols": 4, "rows": 4 },   // OPTIONAL — or {"count": N}; we pack if omitted
  "cell":       { "width": 480, "height": 270 },  // OPTIONAL — default 480×270 (16:9)
  "fps":        12,                          // OPTIONAL — default 12, clamped [4,15]
  "codec":      "h264",                      // OPTIONAL — "h264" (default) | "hevc"
  "hevc_capable": true                       // OPTIONAL — only consulted if "codec" omitted
}
```

### Response

```jsonc
200
{
  "session_id": "…",
  "expires_at": "…",                                  // 30-min TTL (same as /review/sessions)
  "playlist_url": "/review/mosaic-sessions/{id}/playlist.m3u8",  // proxy it exactly like /review
  "grid": {
    "cols": 4, "rows": 4,
    "cell_w": 480, "cell_h": 270,
    "width": 1920, "height": 1080,                    // composited frame size (cols·cell_w × rows·cell_h)
    "fps": 12, "codec": "h264"
  },
  "cells": [
    { "index": 0, "camera_id": "cam-a", "row": 0, "col": 0 },
    { "index": 1, "camera_id": "cam-b", "row": 0, "col": 1 },
    …                                                 // empty trailing cells (count < cols·rows) are omitted; rendered black
  ],
  "manifest": {                                        // ← SAME shape as /review/sessions, for the COMPOSITED timeline
    "wall_start": "…", "wall_end": "…",                // wall_end clamped to finalized (see live-edge)
    "clipped_to_finalized": false,
    "live_gap_s": null,
    "fragments": [
      { "wall_start": "…", "wall_end": "…",
        "compact_start": 0.0, "compact_end": 6.0,
        "codec": "h264", "resolution": "1920x1080",
        "tier": "composite", "availability": "ready" },
      { "wall_start": "…", "wall_end": "…", "availability": "no_recording" },  // whole-grid gap only
      …
    ],
    "grid": { … }, "cells": [ … ]                      // echoed inside the manifest too, for convenience
  }
}
```

**Behavior, point by point against your asks:**

- **One shared timeline.** Fragments are fixed **6 s composited segments** (`MOSAIC_SEGMENT_S`) on a wall-clock grid aligned to `wall_start`. Every output frame at wall *T* composites each camera's frame at wall *T* — sync is *by construction*, not a re-sync heuristic. Seeking the one stream moves all cells together.
- **`cells[]` ↔ camera mapping.** Index = position in your `camera_ids` array = `(row, col)` in row-major order. We never reorder. Relayout = new session (cheap; the manifest is the only thing that changes for an un-warmed window).
- **Gaps rendered server-side.** A cell with no footage at *T* renders **black** (configurable later to dimmed-last-frame / "no signal" card). **A gap in *some* cells never breaks the stream** — it's one muxed frame. We only emit a `no_recording` fragment (an `#EXT-X-GAP`, exactly like `/review`) when **every** cell is empty for that window — that keeps the timeline honest without rendering all-black segments. So your `clipped`/gap code works unchanged; per-cell gaps are invisible to the transport.
- **Manifest reuse.** Identical top-level + fragment fields to `/review`: `wall_start`/`wall_end`/`clipped_to_finalized`/`live_gap_s`, fragments with `compact_*`/`wall_*`/`codec`/`resolution`/`tier`/`availability`. `tier:"composite"` is the one new enum value; treat it as "always-ready, server-rendered."
- **Playlist + segments.** `GET /review/mosaic-sessions/{id}/playlist.m3u8` and `…/seg/{idx}.ts` — proxied through query-api to playback-service exactly like `/review/sessions/{id}/…`. VOD playlist, `#EXT-X-PLAYLIST-TYPE:VOD`, `#EXT-X-PROGRAM-DATE-TIME` per segment, `#EXT-X-ENDLIST`. Point your existing player at `playlist_url` — that's the whole client change.
- **Operator-scoped.** Every `camera_id` must be in the caller's scope or we 403 the whole request (admin = all). Same JWT/`camera_scope` enforcement as the rest of the API. (We're also closing a latent gap here: the single-camera `create_session` doesn't currently scope-check `camera_id`; the mosaic endpoint will, and we'll backfill `/review/sessions` to match.)

---

## E5 — latent confirmations (these gate correct playback regardless of E1)

1. **`resolution` is plumbed, not missing.** On `/review` fragments it's already `"<width>x<height>"` (e.g. `"1280x720"`) or `null` for old rows that pre-date width/height population — sourced from `video_segments.width/height`. **Stop inferring it from codec; read the field.** (`services/query-api/routers/review.py` `build_manifest`.) For the mosaic it's always the composited frame size (e.g. `"1920x1080"`).

2. **Live-edge clamp — confirmed.** `clipped_to_finalized` + `live_gap_s` **are** the safe-to-play ceiling: we clip `wall_end` to the latest finalized segment and never list fragments past it. The mosaic carries them too — clamped to the **latest finalized instant across the camera set**; cells whose own footage ends earlier just render black at the tail (consistent with the union-coverage model in E4). Keep honoring them as the hard ceiling.

3. **Mid-timeline H.264↔HEVC switch — for the mosaic, it cannot happen.** We composite from the uniform H.264 sub stream and emit one output codec, so the mosaic timeline is single-codec end to end — no `#EXT-X-DISCONTINUITY` codec changes, nothing for you to handle. (You correctly predicted this becomes our concern; our answer is to design it out.) For *single-camera* `/review` the mixed timeline is real (HEVC hot window + H.264 warm) and is represented as per-fragment `codec` + a `media_epoch` discontinuity; it **does** play through on an HEVC-capable native client (confirmed in `playback-service` — remux picks the right `*_mp4toannexb` bitstream filter per segment). Browsers get sub-only H.264 and never see it.

4. **Hydrating fragments — partial correction, please don't treat "hydrating" as "drop".** Honest status:
   - Cold/`hydrating` fragments **are** in the `/review` manifest and **represent real footage**; they are *not* fabricated and should stay visible on your timeline.
   - But today they are **not instantly playable**: the first `…/seg/{idx}.ts` request for a cold segment triggers an on-demand S3 rehydration + remux and returns **503 until it's ready**, which *will* stall a player that hits it cold. So your "drop `availability !== "ready"`" was a reasonable defense, but it hides real footage.
   - **What we'd rather you do, and what we'll make safe:** keep hydrating fragments visible (render them as "loading", not absent), and we will **warm the requested window at session-create time** (we already fire a prewarm on `/review/sessions`) so that by the time the operator plays, they're `ready`. We'll also make a cold `seg` request *block-and-serve* (bounded) instead of a bare 503 where feasible, and carry an explicit `availability` you can show as a spinner. Net: you stop dropping footage; we stop making cold segments stall. **For the mosaic this is moot** — composited segments are rendered on demand and served `ready`, never `hydrating`.

---

## E2 — combined grid export

**Yes, and the mosaic session is the natural mechanism.** Once a mosaic session exists, "export the synced grid for In→Out" = render a window of that session to a file — same compositor, same `export_jobs` pipeline, just a grid output instead of single-camera. Plan:

- `POST /review/mosaic-sessions/{id}/exports { wall_start, wall_end, mode }` → an `export_jobs` row (we'll add a `kind` discriminator + the camera-set/grid params), worked by the same exporter, downloadable via the existing token-gated URL.
- You'll likely want **both** per-camera clips *and* the combined grid (Verkada's dual-archive) — fine: fire per-camera `/review/exports` (today) for the individuals and one mosaic export for the combined. They share the job list (A6) and the typed job response (A3) once those land.
- **Sequencing:** after E1 core is solid (it reuses the compositor end to end). It also rides on A1/A3/A6 (purpose / typed job / list), which are already accepted.

---

## E3 — scrub poster frames (and your fallback)

**Yes — and we'll build it early because it's cheap, independent, and de-risks E1.** It doubles as (a) standard thumbnail-on-scrub, (b) your **thumbnail-hybrid fallback** (synchronized posters for all tiles + full video for the focused 1–2) if the mosaic ever can't keep up, and (c) the mosaic's *own* hover/scrub preview.

- `GET /review/poster?camera_id=…&t=<ISO>` → one JPEG, extracted from the **sub** segment covering *t* (`ffmpeg -ss … -frames:v 1`), cached by `(camera_id, t-bucket)`.
- Sprite sheet per window: `GET /review/poster-sprite?camera_id=…&wall_start=…&wall_end=…&interval=10` → a JPEG grid (~1 frame / 10 s) + a JSON index of cell→timestamp. Cheap, cache-friendly, bandwidth-aware.
- Operator-scoped like everything else.
- **Sequencing:** can land in parallel with E1 (independent code path, no compositing).

---

## E4 — coverage union for the shared calendar

**We'll ship a batch endpoint — it's barely more than the per-camera one and saves you N calls.** `GET /review/coverage` (the A7 ask) will accept **either** a single `camera_id` **or** `camera_ids=` (comma-list), and return per-camera days-with-footage **plus** the union:

```jsonc
GET /review/coverage?camera_ids=cam-a,cam-b&from=2026-05-01&to=2026-05-31
{
  "retention_days": 30,
  "per_camera": { "cam-a": ["2026-05-29", …], "cam-b": [ … ] },
  "union":      ["2026-05-28", "2026-05-29", …]   // a day is marked if ANY camera has footage — drives the wall calendar
}
```

Computed from `video_segments` with a date-bucketed `DISTINCT`, operator-scoped. So you don't need to union client-side, and A7 + E4 land together. **Sequencing:** independent, medium priority — slot it with E3.

---

## Pushbacks, consolidated (you invited them)

1. **Live composite → No; on-demand composite-and-cache → Yes.** One shared iGPU; you already accepted on-demand. Not a limitation we can engineer away without a second GPU.
2. **Cell source = sub (H.264 720p), not main (HEVC 1440p).** Better on every axis for a downscaled grid: coverage (30 d vs 3 d), decode cost, codec uniformity, go2rtc non-contention. *If* you ever want a 1-up "focused cell" at full HD, that's the existing single-camera `/review` HEVC path, not the mosaic.
3. **Output H.264, one codec, ~12 fps.** One client decode; no mid-timeline switch; lighter encode. Say the word if you need HEVC output or higher fps and we'll expose it.
4. **v1 grid cap = 16 cells.** That's your stated wall. We can raise it, but each added cell is real iGPU decode + a bigger encode, so we'd rather lift it against a measurement than promise 64 blind.

---

## Implementation plan & sequencing

1. **E1 core (in progress now).** New `playback_mosaic_sessions` table (migration `0029`), `POST /review/mosaic-sessions` + playlist/seg proxies (query-api), the compositor in playback-service (`xstack` filtergraph: scale→pad→tile→`h264_qsv` encode, black-cell synthesis, per-cell sub-stream slice resolver), composited-rendition cache + concurrency gate (shares the QSV semaphore) + QSV-health awareness. Manifest in the `/review` shape. **First increment lands the contract, the manifest/tiling/layout logic, and the compositor with unit tests for all the pure logic.**
2. **E3 poster + E4 coverage-union** — parallelizable, low-risk, unblock your scrub UX and the wall calendar; E3 is also your mosaic fallback.
3. **E5 hydration hardening** — prewarm the requested window on session-create + a non-stalling cold `seg` path (helps single-camera `/review` immediately).
4. **E2 mosaic export** — last; reuses the compositor + the A1/A3/A6 export work.

We'll log deliveries in the master letter (`watchtower-to-cilex-vision-api-requests.md`) as each lands, same as D1–D6.

> **Deployment note (transparency):** the recorder/playback stack is mid-incident on our side — a WD Purple surveillance disk is failing on the SATA link and recording is paused until a cable reseat. E1 is being built and unit-tested against the contract now; live iGPU integration/verification happens once the disk is healthy and the stack is back up. We'll mark it ✅ only after end-to-end verification, never on code-complete alone (same discipline as D6).

---

## Questions back to Watchtower

1. **Sub-stream cells OK?** We're committing to 720p sub as the cell source (argued above). Any case where a cell must be full-HD inside the *grid* (vs the focused single-camera view)?
2. **H.264 output + 12 fps OK** for the wall, or do you want HEVC output / higher fps exposed?
3. **16-cell cap** enough for v1, or is there a real >16 wall we should measure for?
4. **First-segment composite latency** — what's your acceptable ceiling for the first (cold) mosaic segment after a scrub (we target a few seconds), and do you want a structured "warming" signal to show a spinner vs just consuming the HLS as it becomes available?
5. **E2:** do you need per-camera clips **and** the combined grid produced from one operator action, or is firing them separately (N single + 1 mosaic) fine?
6. **E4:** confirm the batch `?camera_ids=` shape above is what you want (vs per-camera + client union).

Happy to iterate on any of it — but the shape above is buildable on our hardware *today*, and we've started.

— Cilex Vision
