<!--
Handoff prompt for the Cilex Vision backend agent. Paste the block below into a
cilex-vision session so it picks up the E1 mosaic integration-alignment letter
(2026-05-31-mosaic-integration-alignment.md), produces offline test fixtures,
defines the warming signal (I2), and confirms integration items I1–I9. The letter
also carries Watchtower's detailed answers to the backend's own 6 questions.
-->

# Handoff prompt — E1 mosaic integration alignment

You're working in the **cilex-vision** backend (`/home/cilex-vision/projects/cilex-vision`). You accepted Watchtower's **E1 synchronized-mosaic** request and built the first increment (`migration 0029`, `query-api/routers/review_mosaic.py`, `playback-service/mosaic_filtergraph.py`, `playback-service/composite.py`, serving in `playback-service/main.py`). Watchtower has now built its **entire client** against your contract and filed an **integration-alignment letter** — the seams that must match exactly for first-contact integration to work. Your job is to address it.

**Read these, in order:**
1. **PRIMARY — action this:** `/home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-05-31-mosaic-integration-alignment.md`. It contains three things: **(a)** a fixtures request, **(b)** integration items **I1–I9**, and **(c)** detailed answers to your own 6 "Questions back to Watchtower" — **treat those answers as Watchtower's confirmations; do NOT re-ask them.** The only question still needing a decision from you is **Q4 (the warming signal)**, which maps to item **I2**.
2. Your contract reply (the agreed shape): `.../2026-05-31-multicam-synchronized-review.reply.md`.
3. The original ask + the client's earlier answers: `.../2026-05-31-multicam-synchronized-review.md` and `.../2026-05-31-multicam-synchronized-review.reply2.md`.
4. Cross-check everything against your **actual implementation** (`review_mosaic.py`, `composite.py`, `mosaic_filtergraph.py`, the `0029` migration) — answer from the code, not from memory.

(All paths are on this machine; the cilex-watchtower letters are also on GitHub at `github.com/romayankin/cilex-watchtower`.)

**Context / why now:** Watchtower's wall-playback client is complete and sitting behind an honest "compositing pending" state. Your recorder/playback stack is mid-incident (WD Purple disk), so *live* verification is paused — but the tasks below are **doable offline** and let both sides reach integration-ready before the stack returns. Recording being down does **not** block producing fixtures from a unit test or a one-off dev render. Hold the discipline you used for D6/E1: mark an item ✅ only after the fixture (or a live run) actually proves it — never on code-complete alone.

**Guardrail:** single-camera `/review` playback is **live in Watchtower today — do not regress it.** Where an answer touches shared surface (the coverage shapes in **I8**, and the `create_session` scope-check backfill you mentioned in your reply), keep `/review/sessions` and the existing single-camera `/review/coverage?camera_id=` shape working.

## PRIORITY 1 — Produce three offline test fixtures (the unblocker)
Generate these from a unit test or a single dev render and **commit them where Watchtower can consume them** — preferably `cilex-watchtower/docs/letters/fixtures/2026-05-31-mosaic/` (versioned next to the letter) — and reference the path in your reply:

1. **`mosaic-session.response.json`** — a real captured `200` body from `POST /review/mosaic-sessions` for **4 cameras, a 2×2 grid**. Must include the full `grid`, `cells[]`, and `manifest` with **several `fragments`**, including at least one `availability:"no_recording"` whole-grid gap fragment if you can synthesize one. This settles **I1** (exact field names/types) definitively.
2. **`playlist.m3u8`** — the actual bytes your server serves for that session: show how segment URIs are written (relative vs `/api/review/...`), `#EXT-X-PLAYLIST-TYPE:VOD`, `#EXT-X-PROGRAM-DATE-TIME` per segment, `#EXT-X-ENDLIST`, and an `#EXT-X-GAP` example if a whole-grid gap exists. This settles **I4**.
3. **One composited `.ts` segment** (~6 s, the `h264_qsv` output) — so Watchtower confirms its player decodes your output and its loopback proxy serves it. Keep it short.

## PRIORITY 2 — Define the warming signal (I2 / your Q4)
This is a **real design decision, not a confirmation.** When an operator scrubs to a cold (un-rendered) region, specify exactly what the client observes, and implement it:
- (a) a fragment `availability` value the client should treat as "warming" (e.g. `"warming"`/`"rendering"`), and/or
- (b) the cold-segment HTTP behavior: a bounded **block-and-serve**, or a **`503` + `Retry-After`** the client should back off on (Watchtower's proxy already retries `503` up to 8× at 400 ms — confirm that's correct, or give the exact header/seconds to honor).

State which you'll emit and the precise values, so Watchtower shows a spinner instead of a freeze. Note your reply said composited segments are "served ready, never hydrating" — clarify how that reconciles with first-touch cold-render latency (your own "target a few seconds").

## PRIORITY 3 — Confirm or correct each remaining item, from the code
For every one, answer **CONFIRM** (matches) or **CORRECT** (give the actual shape):

- **I1** — the literal field names Watchtower parses: top `session_id|grid|cells|manifest`; `grid.{cols,rows,cell_w,cell_h,width,height,fps,codec}`; `cells[].{index,camera_id,row,col}`; `manifest.{wall_start,wall_end,clipped_to_finalized,live_gap_s,fragments}`; `fragments[].{compact_start,compact_end,wall_start,wall_end,codec,resolution,tier,availability}`. (Fixture #1 is the proof.)
- **I3** — intra-cell layout (decides overlay alignment). Watchtower assumes the composited frame is exactly `cols·cell_w × rows·cell_h`, cells in strict row-major at `(col·cell_w, row·cell_h)`, each fully filled. Your filtergraph says "scale→pad→tile" — if there's intra-cell letterbox/pad, give the exact pad rule; ideally **crop-to-fill** so cells are uniform and gap-free. Confirm the packing in `mosaic_filtergraph.py`.
- **I4** — playlist routing (Watchtower proxies only `/review/` paths, rewrites `/api/review/`→`/review/`, strips `#EXT-X-GAP`+its segment, keeps `#EXT-X-DISCONTINUITY`): confirm segment URIs are relative or `/api/review/...` (not an opaque CDN host), gaps use `#EXT-X-GAP`, VOD playlist. (Fixture #2 is the proof.)
- **I5** — a camera with **no footage** in the window → that **cell renders black** and the session still returns `200`; only an **out-of-scope** camera → `403` the whole request. Confirm.
- **I6** — combined-grid export: `POST /review/mosaic-sessions/{id}/exports {wall_start, wall_end, mode}` → poll `GET /review/exports/{job_id}` → token-gated `download_url` shaped like single-camera (so the `/api/review/`→`/review/` rewrite + proxy fetch work). Confirm the session_id carries the camera-set/grid (no resend of `camera_ids`/`layout`). (404 today is fine — Watchtower shows honest "E2 pending".)
- **I7** — export grouping: add an optional `group_id` on both `/review/exports` and `/review/mosaic-sessions/{id}/exports`, echoed in the job + the A6 list response, so one operator "Export selection" (N per-camera + 1 mosaic) shows as **one logical item** in the Clips library. Confirm you'll add it (or that `purpose`/A1 can carry a shared label).
- **I8** — coverage shapes: confirm `GET /review/coverage?camera_id=X` → `{retention_days, days:[{date,has_footage}]}` (A7) and `?camera_ids=X,Y` → `{retention_days, per_camera, union}` (E4), so Watchtower's two parsers each have a fixed shape. Confirm `retention_days` reflects **sub-stream** retention (~30).
- **I9** — confirm the mosaic accepts UTC ISO-8601 (`…Z`) `wall_start`/`wall_end`, windows ≤24 h, same rules as `/review/sessions`.

## How to respond
Write a reply file in the cilex-watchtower repo — `docs/letters/2026-05-31-mosaic-integration-alignment.reply.md` — with a **per-item disposition (I1–I9 + the warming signal)**, the **committed fixture paths**, and any pushback. Commit the fixtures alongside it. Then log it in the master rollup (`watchtower-to-cilex-vision-api-requests.md`) as you did for the E1 response. If you can't write into the cilex-watchtower repo, put the reply + fixtures in your own repo and state the paths so Watchtower can relay them.

## Done means
Watchtower can parse fixture #1 with zero field mismatches, serve fixtures #2 + #3 through its proxy and decode them, position per-cell overlays correctly from the grid geometry, and key its warming spinner off your defined signal — all verified **offline, now**, ahead of live integration when the disk is healthy.
