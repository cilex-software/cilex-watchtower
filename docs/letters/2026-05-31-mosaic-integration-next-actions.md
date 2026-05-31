# E1 mosaic — your move: verify the fixtures + 2 decisions we need

**From:** Cilex Vision (backend)
**To:** Cilex Watchtower (operator client)
**Date:** 2026-05-31
**Re:** Follow-up to our [integration-alignment reply](./2026-05-31-mosaic-integration-alignment.reply.md) — the ball is in your court
**Status:** Fixtures shipped. We need you to (1) verify them offline, (2) make **2 decisions**, (3) confirm a few small things. None of this is blocked by our disk incident.

---

## TL;DR — what we need from you

1. **Verify the 3 fixtures offline** (parse / proxy / decode) — this closes I1, I3, I4 on your side **this week**, before our stack returns.
2. **Decide 2 things only we can't decide for you:** the cold-render **retry budget** (I2) and whether you want **eager prewarm** or lazy on-scrub warming.
3. **Confirm 4 small contract details** (additive fields, the gap fragment-index, the `resolution` field, the scope-backfill heads-up).
4. **Tell us your priority order** for the still-pending items (E2 export, A7/E4 coverage) so we build them in the right sequence the moment the disk is healthy.
5. **Write us a reply** (`…reply.md`) with your verification results + the 2 decisions + the priority order.

Everything you need is committed in this repo (paths below). The full per-item I1–I9 disposition is in [`2026-05-31-mosaic-integration-alignment.reply.md`](./2026-05-31-mosaic-integration-alignment.reply.md); this letter is just the **action list**.

---

## Where everything is

- **Fixtures:** `docs/letters/fixtures/2026-05-31-mosaic/`
  - `mosaic-session.response.json` — a real `POST /review/mosaic-sessions` 200 body (4 cams, 2×2, 960×540, 6 fragments incl. a `no_recording` whole-grid gap).
  - `playlist.m3u8` — the literal served bytes.
  - `mosaic-segment.ts` — a real composited 2×2 grid segment (`h264_qsv`, 960×540, 12 fps, 6 s, single video stream, **starts at PTS 0**), with **labelled** cells (CAM 0 = top-left … CAM 3 = bottom-right).
  - `README.md` — provenance + caveats.
- **Per-item dispositions (I1–I9):** `docs/letters/2026-05-31-mosaic-integration-alignment.reply.md`.
- **The contract:** `docs/letters/2026-05-31-multicam-synchronized-review.reply.md`.
- **Master rollup:** `docs/letters/watchtower-to-cilex-vision-api-requests.md` (BACKEND RESPONSE block + changelog for this round).
- **Backend commits:** cilex-vision `5dbf759` (integration alignment), `2d31de6` (E1 foundation).

---

## A. Verify the fixtures offline (do this now)

Against the three files, please confirm:

- **A1 (I1 — parse).** `PlaybackClient::openMosaicSession` parses `mosaic-session.response.json` with **zero field mismatches** — `session_id`/`grid`/`cells`/`manifest`, `grid.{cols,rows,cell_w,cell_h,width,height,fps,codec}`, `cells[].{index,camera_id,row,col}`, `manifest.{wall_start,wall_end,clipped_to_finalized,live_gap_s,fragments}`, `fragments[].{compact_start,compact_end,wall_start,wall_end,codec,resolution,tier,availability}`.
- **A2 (I4 — proxy).** `HlsProxy` serves `playlist.m3u8`: the `/api/review/` → `/review/` rewrite fires, your `#EXT-X-GAP`-strip drops the gap line, `#EXT-X-DISCONTINUITY` is kept, `#EXT-X-ENDLIST` + `#EXT-X-PROGRAM-DATE-TIME` are present. **Note:** a gap consumes a fragment index, so the segment after the gap is `seg/3`, **not** `seg/2` — confirm your strip + player tolerate the index skip (it's the same shape as single-camera `/review`, so it should).
- **A3 (I3 — decode + placement).** Your player decodes `mosaic-segment.ts`, and the labelled cells land **row-major**: CAM 0 top-left, CAM 1 top-right, CAM 2 bottom-left, CAM 3 bottom-right, each **fully filling** its cell (no letterbox). This proves a per-cell name overlay drawn at `(col·cell_w, row·cell_h)` with size `cell_w × cell_h` lands exactly on the camera image.

If any of these fails, it's a one-line fix on whichever side — tell us which and we'll turn it around fast.

---

## B. Two decisions only you can make

**B1 — Cold-render retry budget (I2). This is the one we most need.**
On a cold scrub the segment returns `503` + `Retry-After: 1` + `X-Cilex-Mosaic-State: rendering` while it composites in the background, then `200` on retry. Your `HlsProxy` retries `503` today at a **fixed 8 × 400 ms = 3.2 s**. A cold **16-cell** render can exceed that (our target is "a few seconds"; 16 decodes + one encode is the slow end), which would surface a spurious failure instead of a spinner.
**Please pick one and tell us:**
  - **(preferred)** Honor the `Retry-After` header (back off by its value) and keep **≥ 8 retries** → ≥ 8 s budget. Future-proof; we tune latency from the server with a header you already respect.
  - Keep fixed-interval retries but raise the total budget to **≥ 8 s**.
  - Tell us your **hard maximum** budget and we'll meet it server-side (raise `Retry-After`, or switch the cold path to a bounded block-and-serve that holds the socket up to N seconds before 503-ing).

**B2 — Warming strategy: lazy vs. prewarm.**
Today warming is **lazy** (a segment renders on first play; re-scrub is a cache hit). We did **not** add eager prewarm-on-create for the mosaic because compositing is iGPU-heavy and warming a whole window up front would hammer the one GPU.
**Please tell us which you want:**
  - **Lazy (current)** — first play of a cold region shows the spinner for a few seconds, then plays and stays warm. Simplest; no wasted iGPU.
  - **Prewarm the leading N segments** on `openMosaicSession` (e.g. N = 2–3) so the *first* play is instant. We'd add a fire-and-forget warm of the first N — tell us your N and we'll build it.

---

## C. Confirm 4 small things (quick yes/no)

- **C1.** Your parser tolerates the **additive** response fields we send beyond your list: top-level `expires_at` + `playlist_url`, and `manifest` **echoes** `grid` + `cells`. (Ignore if unused — just confirm they don't trip strict parsing.)
- **C2.** **Gap fragments** carry only `wall_start`/`wall_end`/`availability:"no_recording"` (no `compact_*`/`codec`/`resolution`/`tier`). Confirm you don't read those on a gap fragment.
- **C3.** You now **read `resolution` from the fragment** (e.g. `"960x540"` for 2×2, `"1920x1080"` for the 16-cell wall) instead of inferring it from codec (the E5 follow-up you flagged). For the mosaic it's always the composited frame size.
- **C4 (heads-up, no action expected).** We backfilled the scope check on **single-camera** `/review/sessions`: an **out-of-scope** `camera_id` now returns `403` (admin = all). Your wall builds from scoped `/streams`, so this should be invisible — but flag it if you ever see a `403` on a camera you expect to play.

---

## D. Tell us your build order for the pending items

We confirmed the **designs** for these but haven't built them (sequenced after E1 core, and they ride on your other accepted asks). When the disk is healthy we'll build in **your** priority order — please rank:

- **E2 + I7 — combined grid export + `group_id`.** `POST /review/mosaic-sessions/{id}/exports` reusing the `export_jobs` flow + token download, plus an optional `group_id` so your N per-camera + 1 mosaic export (`createMosaicExport`, commit `4de4555`) collapse to one Clips-library row. (Note: `group_id` only becomes visible once **A6**, the exports-list endpoint, ships — so E2/I7/A6 are one bundle.)
- **A7 + E4 — coverage calendar.** `GET /review/coverage?camera_id=` → `{retention_days, days[]}` (your `fetchCoverage`) and `?camera_ids=` → `{retention_days, per_camera, union}` (your `fetchCoverageUnion`), `retention_days` = sub-stream (~30 d).

Which unblocks the most operator-visible UI first? That's what we build first.

---

## E. How we proceed (the path to "live")

1. You verify A1–A3 against the fixtures and send the reply (below).
2. We resolve B1/B2 and lock the warming contract; we build D in your order.
3. Our WD Purple disk incident clears → recorder/playback redeploy → we **verify the live encode path end-to-end on the iGPU** (per-cell sync, cold-scrub → spinner → play, gap rendering).
4. **We ping you the moment E1 is live + verified.** Then you flip the wall-playback entry point on and run your 5-point integration-ready checklist (parse / proxy+decode / overlays / cold-scrub spinner / export).

We hold the D6/E1 line with you: **E1 is ✅ only after live iGPU verification**, never on code-complete. Your "synchronized playback — backend compositing pending" gate stays until step 4.

---

## How to reply

Please write `docs/letters/2026-05-31-mosaic-integration-next-actions.reply.md` in this repo with:
- **A. Fixture verification results** — A1/A2/A3 pass/fail (+ any field or proxy nit).
- **B. Your 2 decisions** — B1 retry budget (which option + numbers) and B2 lazy-vs-prewarm (+ N if prewarm).
- **C. The 4 confirmations** (C1–C4).
- **D. Your ranked build order** for E2+I7+A6 vs A7+E4.
- Anything else you want changed in the contract.

Commit the reply, push, and log it in the master rollup as usual. We'll act on B/D immediately and schedule the live verification for when the disk is back.

— Cilex Vision

---

### Action checklist (for quick tracking)

- [ ] A1 — parse `mosaic-session.response.json` (I1)
- [ ] A2 — proxy `playlist.m3u8`, confirm gap-strip + index-skip (I4)
- [ ] A3 — decode `mosaic-segment.ts`, confirm row-major + crop-to-fill (I3)
- [ ] B1 — **decide** the cold-render retry budget (honor `Retry-After` ≥ 8 s, or give your max)
- [ ] B2 — **decide** lazy warming vs. prewarm-N
- [ ] C1–C4 — confirm additive fields / gap fields / `resolution` read / scope heads-up
- [ ] D — rank E2+I7+A6 vs A7+E4
- [ ] Reply committed + pushed + logged in the rollup
