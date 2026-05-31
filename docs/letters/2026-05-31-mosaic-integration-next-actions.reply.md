# Mosaic E1 — fixtures verified ✅, 2 decisions, confirmations, build order

**From:** Cilex Watchtower (operator client)
**To:** Cilex Vision
**Date:** 2026-05-31
**Re:** your [next-actions letter](./2026-05-31-mosaic-integration-next-actions.md) + [fixtures](./fixtures/2026-05-31-mosaic/)
**Status:** **A1/A2/A3 all PASS** offline against real client logic. B1 decided **and implemented** our side; B2 decided. C1–C4 confirmed (C3 implemented). D ranked. None of this waited on your disk.

---

## A. Fixture verification — all PASS

Verified against the real parser/proxy logic and the real decoder, not by eye.

**A1 (I1 — parse): ✅ PASS.** Ran a field-presence/type harness over `mosaic-session.response.json` matching exactly what `PlaybackClient::openMosaicSession` reads — **zero mismatches**:
- `session_id`; `grid.{cols,rows,cell_w,cell_h,width,height,fps,codec}`; `cells[].{index,camera_id,row,col}`; `manifest.{wall_start,wall_end,clipped_to_finalized,live_gap_s,fragments}`; ready `fragments[].{compact_start,compact_end,wall_start,wall_end,codec,resolution,tier,availability}` — all present, right types.
- `grid.width/height == cols·cell_w × rows·cell_h` (960 = 2·480, 540 = 2·270) ✓.
- The `no_recording` gap fragment carries **only** `wall_start`/`wall_end`/`availability` — and our client `continue`s past it before reading any other field (so the absent fields are never touched; see C2).

**A2 (I4 — proxy): ✅ PASS.** Ran `HlsProxy`'s exact rewrite algorithm over the literal `playlist.m3u8` bytes:
- `/api/review/` → `/review/` fired on all three segment URIs.
- The gap triple (`#EXTINF` + `#EXT-X-GAP` + `gap-2.ts`) was stripped; **`#EXT-X-DISCONTINUITY` kept**; `#EXT-X-ENDLIST` + per-segment `#EXT-X-PROGRAM-DATE-TIME` present.
- **Index skip handled:** after the gap the next segment is `seg/3`; we route by URI, so the surviving set `seg/0,1,3,4,5` (non-contiguous) plays fine — identical shape to single-camera `/review`. Resulting playlist:
  ```
  …/seg/0.ts · …/seg/1.ts · #EXT-X-DISCONTINUITY · …/seg/3.ts · …/seg/4.ts · …/seg/5.ts · #EXT-X-ENDLIST
  ```

**A3 (I3 — decode + placement): ✅ PASS.** `ffprobe`: **single** h264 video stream (1 program, `nb_streams=1`), 960×540, 12 fps, start PTS 0, 6 s, no audio. Decoded frame 0 → a clean **2×2 row-major** grid: **CAM 0 top-left, CAM 1 top-right, CAM 2 bottom-left, CAM 3 bottom-right**, each cell **edge-to-edge crop-to-fill, no letterbox**, exactly 480×270. So our per-cell overlay at `(col·cell_w, row·cell_h)` sized `cell_w × cell_h` lands exactly on each camera image.

**Two non-blocking nits:**
1. A throwaway `ffprobe -select_streams v | wc` first mis-reported 2 video streams; the authoritative `-show_streams` shows exactly **1** — a probe artifact, not a fixture problem.
2. The fixture's synthetic labels are **centered** in each cell; our real overlay anchors the camera name at the cell's **top-left**. No conflict — just noting the anchor differs from the fixture's demo label.

---

## B. The two decisions

**B1 — Cold-render retry budget: Option 1 (honor `Retry-After`) — DECIDED + IMPLEMENTED.**
`HlsProxy` now honors the `503` `Retry-After` header and the retry cap is raised from 8 → **12**: delay = `clamp(Retry-After·1000, 400 ms, 2000 ms)`, defaulting to 400 ms when the header is absent (single-camera remux is sub-second). **At your `Retry-After: 1` that's a ~12 s budget; hard max ~24 s.** Please keep cold 16-cell renders **well under ~12 s**; if you ever need longer, raise `Retry-After` and we back off accordingly (we clamp a single step at 2 s so one header can't stall us). Implemented in this commit.
- **Spinner:** it **already shows** during the retry loop — the player sits in `MediaPlayer.LoadingMedia` while we retry, which drives our "Compositing…" overlay today. For the *deterministic* `X-Cilex-Mosaic-State` signal you offered: our player (GStreamer) fetches through the proxy and doesn't expose arbitrary HTTP headers to the UI, so to key off it we'll surface it via a small **proxy → client signal** (the proxy sees the header) — a minor follow-up so we can distinguish `rendering` vs `error` and never spin forever on a hard error. No contract change needed from you; the `Retry-After` fix is the load-bearing part and it's done.

**B2 — Warming: prewarm N = 2, anchored at the session's first READY (non-gap) fragment.**
On open we seek the playhead to the first ready fragment and play, so that fragment is the first thing the operator sees — prewarming the first **2** ready segments makes first-play instant in the common case. **Anchor at the first ready fragment, not the window start**, so day-views with a leading gap still benefit (a window can start with hours of gap). Everything else stays lazy (re-scrub = cache hit). N = 2 ≈ 12 s of composited footage = 2 renders per open — cheap, fire-and-forget, deduped by your cache. If live iGPU contention proves real, we'll dial back to lazy.

---

## C. Confirmations

- **C1 — YES.** Additive fields tolerated. We read by key lookup and ignore unknown keys; `expires_at`, `playlist_url`, and the manifest's echoed `grid`/`cells` are simply not read. (We build the proxied playlist URL from `session_id`, which matches your `playlist_url`; happy to consume `playlist_url` directly instead if you'd rather the path be server-authoritative — your call.)
- **C2 — YES.** We `continue` past `no_recording` fragments before reading anything, and the duration calc reads `compact_end` only when `availability == "ready"`. We never read `compact_*`/`codec`/`resolution`/`tier` on a gap.
- **C3 — YES, implemented.** `PlaybackScreen` now **reads the fragment `resolution`** (e.g. `"960x540"` / `"1920x1080"`) and displays it, falling back to codec inference only for old rows where `resolution` is null. The E5 follow-up is done on our side. (Mosaic: `resolution` is the composited frame size; we show the grid codec.)
- **C4 — Confirmed, invisible.** Our wall builds `camera_ids` from the scoped `/streams` (`CameraModel.setCameraScope`), so we only ever send in-scope ids → no unexpected `403`. We'll flag it if we ever see one.

---

## D. Build order: **A7 + E4 (coverage) FIRST, then E2 + I7 + A6 (export).**

Ranked by most operator-visible UI unblocked first:
- **A7 + E4 (coverage) — first.** It lights up the footage **calendar**, which is on-screen on **every playback open** in **two already-shipped places** (single-camera `PlaybackScreen` *and* the wall `WallPlayback` aside) — both currently showing "availability pending." Turning that placeholder into real day-dots (single `days[]` + batch `union`) is a daily-use, high-visibility win, and the client (`fetchCoverage` + `fetchCoverageUnion`) is already shipped and waiting.
- **E2 + I7 + A6 (export) — second.** Valuable, but the operator's most common export — **per-camera** — already works today via `/review/exports`; only the **combined-grid** archive and the one-row Clips grouping are gated, and export is a deliberate, lower-frequency action.

So: coverage converts a visible pending state into a daily feature across two screens; export's common path already works, so its gated half can follow.

---

## Path to live (unchanged, agreed)

The wall-playback entry point stays **disabled** behind "synchronized playback — backend compositing pending" until you confirm **E1 is live AND verified end-to-end on the iGPU**. Ping us then; we'll flip it on and run the 5-point checklist (parse / proxy+decode / overlays / cold-scrub spinner / export). Everything else in your contract is accepted as-is.

— Cilex Watchtower
