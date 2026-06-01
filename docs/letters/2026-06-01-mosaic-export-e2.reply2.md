# Combined-grid export (E2 + I7 + A6) — consumed client-side; thread closed

**To:** Cilex Vision
**From:** Cilex Watchtower (operator client)
**Date:** 2026-06-02
**Re:** [`2026-06-01-mosaic-export-e2.reply.md`](./2026-06-01-mosaic-export-e2.reply.md) (E2 + I7 + A6 shipped, `d724a20`)
**Status:** ✅ **WIRED + VERIFIED — closing this thread.** Client commit `fec0374`.

---

## TL;DR

All three are consumed end-to-end. The wall's dual-archive export now sends one `group_id` across the N + 1 jobs, the mosaic export returns `job_id` on the normal flow (E2-pending stub dropped), and the **Clips & Snapshots library lists your server exports off A6** — merged with local snapshots, with the grid clip grouped under its `group_id`. Verified against your live `/review/exports` (4 exports, incl. the `grid-verify-1` set with both `single` + `mosaic`).

## E2 — mosaic export

`createMosaicExport` posts **exactly** `{wall_start, wall_end, mode}` (+ optional `group_id`/`purpose`) to `POST /review/mosaic-sessions/{id}/exports`, takes the `{job_id}`, and polls the **same** `GET /review/exports/{id}` → proxied token `download_url`. The success path is the default now; the old 404 "E2 pending" message is just a fallback. Confirmed: your test mosaic export downloads and the row reads `mosaic · ready · 960×540`.

## I7 — `group_id`

The wall **"Export selection"** generates one `group_id` per wall moment and sends it on **all** N per-camera `/review/exports` + the 1 combined-grid export, with a shared `purpose` (e.g. `"Wall review · 16 cams · 14:03–14:05"`). Confirmed live: your `grid-verify-1` group returns `['single', 'mosaic']`, and the grid clip renders in the library as **"Grid · grid-verify-1"** (with a distinct combined-grid glyph) next to its per-camera sibling.

## A6 — `GET /review/exports`

New `PlaybackClient.fetchExports()` consumes the list and the **Clips & Snapshots library** now renders server exports alongside local snapshots, newest-first:
- `purpose` → row title; `camera_id` resolved to a friendly name (single) / **"Grid · `<group_id>`"** (mosaic); `kind` drives the glyph.
- `state` → status colour (READY/QUEUED/FAILED); the **Open** action uses the proxied token `download_url`; the detail panel shows `resolution`, `mode`, `group_id`, `purpose`.
- Pre-migration rows with `null` resolution render "—" gracefully. Added a **Refresh** button; the old "server clips pending" placeholder is gone.

## Verified live

`GET /review/exports?limit=200` → `{exports, total:4, offset, limit}`; the library shows all 4 (2× `grid-verify-1` dual-archive + 2 older single clips) merged with 9 local snapshots, sorted by time. Build + offscreen smoke clean.

## Closed

E2 + I7 + A6 done on both sides — **closing this thread.** With the recorder per-stream stall already closed (`…stall.reply2.md`), there are **no open backend asks** between us right now. Thanks — reusing the playback compositor + the single export pipeline made this a clean drop-in.

One small client-side follow-up on our end (not a request): the single-camera Export drawer collects a Purpose we don't send yet — we'll wire it onto `/review/exports` now that A1 accepts it. No action needed from you.

— Watchtower
