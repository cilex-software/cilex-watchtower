# Combined-grid export (E2) + group_id (I7) + exports list (A6) — shipped, verified end-to-end

**To:** Cilex Watchtower
**From:** Cilex Vision
**Date:** 2026-06-02
**Re:** [`2026-06-01-mosaic-export-e2.md`](./2026-06-01-mosaic-export-e2.md) (your green-light + exact client contract)
**Status:** ✅ **BUILT + DEPLOYED + verified live.** Commit `d724a20`. Drop the "E2 pending" stub — the mosaic export returns `job_id` and downloads a playable grid.

---

## TL;DR

All three ride the **existing `export_jobs` pipeline + token download** — single-camera `/review/exports` is unchanged (only backward-compatible additive fields). Verified live: a 2×2 mosaic session → exported a 1-min window → job `ready` in ~7s → token download → `ffprobe` = **h264 960×540, 720 frames, 60.0 s**. The A6 list shows the mosaic + per-camera siblings under one `group_id`.

## E2 — `POST /review/mosaic-sessions/{session_id}/exports`

Accepts **exactly the body you send**:
```json
{ "wall_start": "<ISO>", "wall_end": "<ISO>", "mode": "wallclock", "group_id": "...", "purpose": "..." }
```
(`group_id` + `purpose` optional; `mode ∈ {wallclock, compact}`, same enum + 2-h window cap as `/review/exports`.) Returns **`{ "job_id": …, "state": "queued" }`**, then you poll the **same** `GET /review/exports/{job_id}` → `download_url` — identical to single-camera. Scoped via the same owner/scope check as the mosaic playback routes (403/404 out of scope).

How it renders (no new pipeline): the worker loads the session by id and renders each manifest fragment overlapping your window through the **same compositor as mosaic playback** (`ensure_composite_segment` — it **reuses the on-disk segment cache**, so a wall you already scrubbed exports almost instantly), then concatenates to one MP4 (stream-copy; re-encode to the session codec only when `wallclock` gaps insert black fillers) and uploads to the token-gated download. `mode`: `wallclock` freezes gaps as black grid fillers; `compact` drops them — same semantics as single-camera.

Note: it loads the session **ignoring the 30-min playback TTL** (the row lives ~1 day), so a queued export still resolves after the playback session expires. Window selection is fragment-granular (≤6 s edge fragments), matching single-camera.

## I7 — `group_id`

Optional `group_id` on **both** `POST /review/exports` and the mosaic export; persisted on the job and echoed in the job response **and** the A6 list. Send one `group_id` across the N + 1 dual-archive jobs and they come back as one group. Verified: a mosaic job + a single-camera job sent with `group_id="grid-verify-1"` both list under that id (`mosaic` + `single`).

## A6 — `GET /review/exports`

```
GET /review/exports?limit&offset&mine&since   ->  { exports: [ <job> ], total, offset, limit }
```
Per-user scoped (D5 — each operator sees only their own exports), newest first, paged. `since` filters `created_at`; `mine` accepted (always own-scoped today). Each `<job>` is the **one schema** also returned by `GET /review/exports/{id}`:

`job_id, kind ("single"|"mosaic"), state, mode, wall_start, wall_end, output_bytes, resolution ("WxH"), group_id, purpose, download_expires_at, download_url (null until ready), created_by, created_at, started_at, finished_at, error_msg, camera_id (single) | mosaic_session_id (mosaic)`.

`download_url` is the `/api/review/exports/{id}/download?token=…` proxy path (raw token never leaked). This populates your Clips & Snapshots library; `group_id` renders the dual-archive grouping; `purpose` is the Purpose column. (`resolution` is set going forward; exports created before this migration list `null` resolution.)

## Did a real grid export download + play?

Yes — end to end on the live iGPU:
1. `POST /review/mosaic-sessions` (4 cams, 2×2) → session; grid `960×540`, h264, 12 fps.
2. `POST …/exports {wall_start, wall_end, mode:"wallclock", group_id, purpose}` → `{job_id, state:"queued"}`.
3. `GET /review/exports/{job_id}` → `ready` in ~7 s; `resolution:"960x540"`, `group_id`, `purpose`, `download_url`, `output_bytes:3,403,137`.
4. Downloaded via the token URL (bytes matched) → **`ffprobe`: `mp4`, `h264`, `960×540`, `nb_frames=720`, `duration=60.0 s`** — a valid, seekable combined-grid clip.

Tests: query-api 39 (6 new export-contract), playback 32 green. The mosaic **playback** compositor (`51c7b4d`) and single-camera playback/coverage are untouched (reused, not forked).

## Single-problem

Combined-grid export + grouping + list only, as scoped. The recorder per-stream stall is the separate handoff (`2026-06-01-recorder-per-stream-stall.md` → reply `…stall.reply.md`, commit `0ab548f`).

You're clear to send `group_id` on the dual-archive set, drop the E2-pending stub, and wire the Clips library off A6. Commit `d724a20` (migration 0030 + query-api + playback rebuilt + live).

— Cilex Vision
