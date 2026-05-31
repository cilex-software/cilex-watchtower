<!--
Handoff prompt for the Cilex Vision backend agent. Paste the block below into a
cilex-vision session so it picks up the E1 mosaic integration-alignment letter
(2026-05-31-mosaic-integration-alignment.md), produces offline test fixtures,
defines the warming signal, and confirms integration items I1–I9. The letter
also contains Watchtower's detailed answers to the backend's own 6 questions.
-->

# Handoff prompt — E1 mosaic integration alignment

You're working in the **cilex-vision** backend (`/home/cilex-vision/projects/cilex-vision`). You accepted Watchtower's **E1 synchronized-mosaic** request and built the first increment (`migration 0029`, `query-api/routers/review_mosaic.py`, `playback-service/mosaic_filtergraph.py`, `playback-service/composite.py`, serving in `playback-service/main.py`). Watchtower has now built its **entire client** against your contract and filed an **integration-alignment letter** you need to action.

**Read these, in order:**
1. **PRIMARY — action this:** `/home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-05-31-mosaic-integration-alignment.md`. It has three things: (a) a **fixtures request**, (b) integration items **I1–I9**, and (c) **detailed answers to your own 6 "Questions back to Watchtower"** — read those answers as Watchtower's confirmations; **do not re-ask them.** Only **Q4's warming signal** needs a decision from you (it maps to item **I2**).
2. Your contract reply (the agreed shape): `.../2026-05-31-multicam-synchronized-review.reply.md`.
3. The original ask + client's first answers: `.../2026-05-31-multicam-synchronized-review.md`, `.../2026-05-31-multicam-synchronized-review.reply2.md`.
4. Cross-check against your **actual code** (`review_mosaic.py`, `composite.py`, `mosaic_filtergraph.py`, `0029`) — answer from the code, not memory.

(All paths are on this machine; the cilex-watchtower letters are also on GitHub: `github.com/romayankin/cilex-watchtower`.)

**Context / why now:** Watchtower's wall-playback client is complete, behind an honest "compositing pending" state. Your stack is mid-incident (WD Purple disk), so *live* verification is paused — but everything below is **doable offline** (fixtures from a unit test or one-off dev render) and gets both sides to integration-ready before the stack returns.

## PRIORITY 1 — Produce three offline fixtures (the unblocker)
Commit them where Watchtower can consume them — preferably `cilex-watchtower/docs/letters/fixtures/2026-05-31-mosaic/` — and reference the path in your reply:
1. `mosaic-session.response.json` — a real `200` body from `POST /review/mosaic-sessions` for **4 cameras, 2×2 grid**, with full `grid`, `cells[]`, and a `manifest` containing **several `fragments`** (include an `availability:"no_recording"` whole-grid gap if you can synthesize one). Settles **I1**.
2. `playlist.m3u8` — the actual bytes you serve: segment-URI style (relative vs `/api/review/...`), `#EXT-X-PLAYLIST-TYPE:VOD`, `#EXT-X-PROGRAM-DATE-TIME`, `#EXT-X-ENDLIST`, an `#EXT-X-GAP` example if present. Settles **I4**.
3. One composited `.ts` segment (~6 s, your `h264_qsv` output) — so Watchtower confirms its player decodes it and its proxy serves it.

## PRIORITY 2 — Decide and implement the warming signal (I2 / your Q4)
This is the one open design decision. Specify exactly what the client observes on a cold scrub: (a) a fragment `availability` value to treat as "warming" (e.g. `"warming"`/`"rendering"`), and/or (b) the cold-segment HTTP behavior — bounded **block-and-serve** or **`503` + `Retry-After`** (Watchtower's proxy already retries `503` up to 8× at 400 ms; confirm or give the header). State the precise values so the client shows a spinner, not a freeze. Reconcile with your "served ready, never hydrating" claim vs first-touch cold-render latency.

## PRIORITY 3 — Confirm (or correct, from the code) each remaining item
- **I1** field names (fixture #1 proves it).
- **I3** intra-cell layout — confirm the composited frame is exactly `cols·cell_w × rows·cell_h`, strict row-major, cells fully filled (crop-to-fill, no intra-cell pad) so per-cell overlays align.
- **I4** playlist routing (relative/`/api/review` URIs, `#EXT-X-GAP`, VOD).
- **I5** no-footage camera → black cell + `200`; only out-of-scope → `403`.
- **I6** combined-export reuses `/review/exports` poll/download; the session carries the camera-set/grid (no resend of `camera_ids`/`layout`).
- **I7** add `group_id` to both export requests, echoed in the A6 list, so N+1 jobs show as one library item.
- **I8** confirm single-`camera_id` → `{retention_days, days[]}` and `?camera_ids=` → `{retention_days, per_camera, union}`; `retention_days` reflects sub-stream (~30).
- **I9** UTC ISO `wall_start`/`wall_end`, ≤24 h, same rules as `/review/sessions`.

## How to respond
Write `docs/letters/2026-05-31-mosaic-integration-alignment.reply.md` in the cilex-watchtower repo with a **per-item disposition (I1–I9 + the warming-signal mechanism)** and the **committed fixture paths**; commit the fixtures alongside; log it in the master rollup (`watchtower-to-cilex-vision-api-requests.md`) as you did for the E1 response. If you can't write into the cilex-watchtower repo, put the reply + fixtures in your own repo and state the paths.

## Done means
Watchtower parses fixture #1 with zero field mismatches, serves #2/#3 through its proxy and decodes them, positions per-cell overlays correctly, and keys its warming spinner off your defined signal — all verified **offline, now**, ahead of live integration.
