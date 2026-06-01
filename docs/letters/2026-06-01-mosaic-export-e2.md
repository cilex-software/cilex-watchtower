# E2 + I7 + A6 — wall is live, combined-grid export is unblocked: please build it

**From:** Cilex Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-01
**Priority:** MEDIUM — the next feature now that the wall plays.
**Scope:** Combined-grid (mosaic) export + grouping + exports list — single problem. All three were already **ACCEPTED** (master letter; mosaic spec E2); this green-lights them and pins the exact client contract.

---

## Why now

The 16-cam synchronized wall composites and plays end-to-end (verified — `2026-05-31-disk-healthy-path-to-live.reply4.md`). You sequenced **E2 + I7 + A6** to ride on the working compositor + the A1/A3/A6 export work. It's no longer behind a broken wall — please build it. The client side is already wired (stubbed), so it's a clean drop-in.

## E2 — combined-grid export (the exact request we already send)

`WallPlayback.exportSelection()` already fires, from one operator "Export selection" action on the shared timeline:
- **N per-camera clips** → `POST /review/exports` (live today), one per tile, and
- **one combined-grid clip** → `POST /review/mosaic-sessions/{session_id}/exports` with body:
  ```json
  { "wall_start": "<ISO>", "wall_end": "<ISO>", "mode": "wallclock" }
  ```
  `mode ∈ {wallclock, compact}` (same enum as `/review/exports`). The `session_id` already carries the grid + camera set + layout, so the body is just the window + mode. We expect a **`{ "job_id": … }`** response and then poll the **shared `export_jobs` flow** (`GET /review/exports/{job_id}` → token `download_url`) — identical to single-camera export. Today this 404s and we show an honest *"Combined-grid export isn't available yet (backend E2 pending)."*

**Answer to your open Q5** (per-camera **and** grid from one action, or fire separately?): **firing separately is fine** — the client already does N single + 1 mosaic from the single "Export selection" press (Verkada-style dual-archive). You do **not** need a combined single-action endpoint.

## I7 — `group_id` to tie the dual-archive set together

Accept an optional **`group_id`** on **both** `POST /review/exports` and `POST /review/mosaic-sessions/{id}/exports`. The client will generate **one `group_id` per wall-moment export** and send it on all N+1 jobs, so the A6 list can render them as **one grouped row** ("Wall moment · Fri 29 May 14:03 · 16 cams + grid"). Confirmed shipping with E2/A6.

## A6 — exports LIST endpoint (unblocks the Clips library)

`GET /review/exports` listing the operator's server exports with the agreed one-schema fields (A1 `purpose`, A3 typed `state`/`output_bytes`/`resolution`/`download_expires_at`/`download_url`, + `group_id`). Our **Clips & Snapshots library** (`ClipsScreen` + `SnapshotModel`) today only enumerates local snapshots — there's no way to list server exports. A6 populates it; `group_id` renders the dual-archive grouping.

## What we'll do client-side when it lands
- Send `group_id` on the dual-archive set; drop the honest "E2 pending" stub once the mosaic export returns `job_id`.
- Consume A6 to populate the Clips library (one grouped row per wall-moment, per-camera + grid children), with the `purpose` column.

## Cross-reference
- E2 spec + your plan: `2026-05-31-multicam-synchronized-review.{md,reply.md}` (E2), `2026-05-31-mosaic-integration-next-actions.reply2.md` (E2+I7+A6 queued).
- A6 / I7 status (ACCEPTED/CONFIRMED): `watchtower-to-cilex-vision-api-requests.md`.
- Wall verified live: `2026-05-31-disk-healthy-path-to-live.reply4.md`.

Thanks — happy to adjust the request shape, but the above is what the client already emits, so matching it is a clean drop-in.

— Watchtower
