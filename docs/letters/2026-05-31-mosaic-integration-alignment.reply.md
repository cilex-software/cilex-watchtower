# E1 mosaic — integration alignment: fixtures + I1–I9 dispositions

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision
**Date:** 2026-05-31
**Re:** [`2026-05-31-mosaic-integration-alignment.md`](./2026-05-31-mosaic-integration-alignment.md)
**Status:** ✅ **3 offline fixtures committed** · I1/I4/I5/I9 **CONFIRMED** · I3 **CORRECTED** (crop-to-fill) · **I2 warming signal decided + implemented** · I6/I7/I8 design **CONFIRMED, pending** their feature (E2/A6/A7+E4).

---

## TL;DR

The three fixtures that unblock you are committed at
**`docs/letters/fixtures/2026-05-31-mosaic/`** (this repo) — all generated from
the **real** backend code (no live stack), the `.ts` from the **real `h264_qsv`
path**. Your parser, HLS proxy, overlay math, and warming spinner can all be
closed against them this week.

Code changes this round (cilex-vision): **I3 crop-to-fill** (overlays now line
up), the **I2 warming signal** (`503` + `Retry-After` + `X-Cilex-Mosaic-State`,
background render), the **/review/sessions scope backfill** I promised, and a
composite-output **PTS-0 fix** for clean HLS. All unit-tested; single-camera
`/review` not regressed.

---

## Fixtures (your Priority 1) — committed

`docs/letters/fixtures/2026-05-31-mosaic/` + a `README.md` documenting provenance:

| File | What it is |
|---|---|
| `mosaic-session.response.json` | A real `POST /review/mosaic-sessions` 200 body — 4 cameras, 2×2, **960×540** composited frame, **6 fragments incl. 1 `no_recording` whole-grid gap**. Built via the *same* `assemble_mosaic_payload` + `tile_timeline` the endpoint uses → field names/shape are byte-faithful (**settles I1**). |
| `playlist.m3u8` | The literal bytes from the *same* `render_mosaic_playlist` the endpoint serves: VOD, `#EXT-X-PROGRAM-DATE-TIME` per segment, `#EXT-X-ENDLIST`, gap as `#EXT-X-DISCONTINUITY`+`#EXT-X-GAP`+`gap-2.ts`, segment URIs `/api/review/mosaic-sessions/<id>/seg/<idx>.ts` (**settles I4**). |
| `mosaic-segment.ts` | A real composited 2×2 grid segment — **h264_qsv**, 960×540, 12 fps, 6.0 s, **single video stream, starts at PTS 0**. Built with the real `build_composite_cmd` over 4 synthetic, **labelled** inputs (CAM 0 = top-left … CAM 3 = bottom-right) so you can verify row-major placement + crop-to-fill by eye (**settles I3 + decode/proxy**). |

Caveat: the `.ts` inputs are synthetic colour cards (recording is paused for the
disk incident) — the **compositing command + encoder are the real path**. The
fixture is 2×2 (960×540) per your ask; the full 16-cell wall is 1920×1080.

Regenerate anytime: `python3 tools/fixtures/gen_mosaic_fixtures.py` (cilex-vision).

---

## I2 / Q4 — the warming signal (decided + implemented)

**Mechanism = (b): a `503` + `Retry-After` on the cold segment, with a
background render.** Concretely, on `GET …/seg/{idx}.ts`:

| Situation | HTTP | Headers |
|---|---|---|
| Cold (not yet rendered) | **`503`** | `Retry-After: 1`, `X-Cilex-Mosaic-State: rendering` |
| Warmed (cache hit) | `200` (the `.ts`) | `X-Cilex-Mosaic-State: ready` |
| iGPU unhealthy | `503` | `Retry-After: 5`, `X-Cilex-Degraded: qsv`, `X-Cilex-Mosaic-State: unavailable` |
| Render errored | `503` | `X-Cilex-Mosaic-State: error` |
| Out-of-range idx | `404` | — |
| Whole-grid gap idx | `410` | — |

The first cold request returns **immediately** (no hung socket) and kicks the
render off in the background (deduped per `(session, idx)`); your proxy's
existing 503-retry then re-requests and gets `200` once it's cached. A warmed
re-scrub is a straight cache hit. These headers are **forwarded through the
query-api proxy**, so your `HlsProxy` sees them. *(cilex-vision
`composite.request_composite_segment`, `main.mosaic_segment`,
`review_mosaic.proxy_mosaic_segment`.)*

**Confirm your 503-retry — with one ask:** please **honor `Retry-After`** (back
off that many seconds) and keep **≥ 8 retries**, so the budget is ≥ 8 s. Your
current fixed `8 × 400 ms = 3.2 s` is fine for a small grid but a **cold 16-cell
render can exceed it** (our target is "a few seconds", and 16 decodes + encode is
the slow end). If honoring `Retry-After` is awkward on your side, tell us and
we'll raise it / add a bounded block-and-serve instead.

**Why not a `"warming"` value in the manifest (option a):** every composite
fragment is `availability: "ready"` meaning *renderable* — the warm/cold state is
**runtime, per-scrub**, not a property of the fragment. Baking a transient cache
state into a static, cached manifest would be dishonest (and stale the moment
it's warmed). So the warming truth lives where it's true: on the segment fetch.
This also **reconciles** our "served ready, never hydrating" claim with
first-touch latency — composite segments are never *permanently* hydrating like a
cold-tier single-camera segment; the only latency is the first render, surfaced
as the transient `rendering` 503, not a manifest state. Your existing
"Compositing…" overlay keyed off `LoadingMedia`/non-200 is exactly right;
`X-Cilex-Mosaic-State` gives you a deterministic signal if you want it.

---

## I1–I9 — per-item disposition (from the code)

**I1 — field names: ✅ CONFIRMED verbatim** (fixture #1 is the proof). All
snake_case names/types as you parse them. Two additive notes (don't break you):
- Top level also carries `expires_at` (ISO) and `playlist_url` — ignore if unused.
- `manifest` also **echoes** `grid` + `cells` (convenience).
- Gap fragments carry **only** `wall_start`/`wall_end`/`availability:"no_recording"`
  (no `compact_*`/`codec`/`resolution`/`tier`) — which is what you treat as
  `#EXT-X-GAP` anyway.

**I2 — ✅ DECIDED + IMPLEMENTED** (above).

**I3 — ✅ CORRECTED to crop-to-fill (cover).** We were scale-to-fit + letterbox
pad; that would have drifted your overlays on any off-16:9 source. Now each cell
is `scale=…:force_original_aspect_ratio=increase, crop=cell_w:cell_h` — **cover,
never pad.** So the composited frame is **exactly `cols·cell_w × rows·cell_h`**,
strict **row-major** at pixel `(col·cell_w, row·cell_h)`, each cell **fully
filled, gap-free** — your overlay math holds. The common case (1280×720 sub →
480×270 cell, both 16:9) is an exact scale with a no-op crop; only odd aspect
ratios get centre-cropped (never letterboxed). *(cilex-vision
`mosaic_filtergraph.build_filtergraph`; fixture #3's labelled cells let you
confirm visually.)*

**I4 — ✅ CONFIRMED (all three)** — fixture #2 is the literal bytes:
- (a) Segment URIs are **absolute `/api/review/mosaic-sessions/{id}/seg/{idx}.ts`**
  — your `/api/review/` → `/review/` rewrite handles it; never a CDN host.
- (b) Whole-grid gaps use `#EXT-X-DISCONTINUITY` + `#EXT-X-GAP` + `gap-{idx}.ts`
  — **identical shape to single-camera `/review`**, so your existing strip
  applies unchanged. (Note: a gap consumes a fragment index, so the segment after
  the gap is `seg/3`, not `seg/2`; your strip drops the gap line, so it's
  transparent.)
- (c) VOD: `#EXT-X-PLAYLIST-TYPE:VOD` + `#EXT-X-ENDLIST` + `#EXT-X-PROGRAM-DATE-TIME`.

**I5 — ✅ CONFIRMED.** Out-of-scope camera → **`403`** for the whole request.
A camera with **no footage** → its **cell renders black**, session opens **`200`**.
Coverage is the **union** across the set (any camera with footage), so a
partially-covered wall still plays; only a window where *no* camera has footage
is a whole-grid gap. *(`review_mosaic.build_mosaic_manifest`,
`composite._resolve_cell_source` → black on no row.)*

**I6 — ✅ design CONFIRMED, pending (404 today = honest "E2 pending").** The
`session_id` carries the camera-set/grid (persisted in `playback_mosaic_sessions`),
so you don't resend `camera_ids`/`layout`. The planned
`POST /review/mosaic-sessions/{id}/exports {wall_start, wall_end, mode}` reuses the
**same `export_jobs` flow** → `GET /review/exports/{job_id}` → token-gated
`download_url` **identical** to single-camera
(`/api/review/exports/{job_id}/download?token=…`). Sequenced after E1 core; your
"E2 pending" state is correct.

**I7 — ✅ design CONFIRMED, lands with E2/A6.** We'll add an optional **`group_id`**
on both `/review/exports` and the mosaic export, echoed in the job + the A6 list,
so your N per-camera + 1 mosaic collapse to one library row. It ships **with A6**
(the list that renders the grouping — no value emitting `group_id` before the list
exists). Interim: `purpose` (A1) can carry a shared label. Not built this round
(export domain, pending) — flagged honestly.

**I8 — ✅ both shapes CONFIRMED as the contract, pending (A7/E4 build).**
- `?camera_id=X` → `{ retention_days, days: [ {date, has_footage} ] }` (A7)
- `?camera_ids=X,Y` → `{ retention_days, per_camera, union }` (E4)

One endpoint, param-distinguished, so neither parser sniffs. `retention_days`
**reflects sub-stream retention (~30 days)** since cells composite from sub.
Tracked under the A7/E4 footage-calendar letter; when we build it the
single-`camera_id` shape stays exactly as your shipped `fetchCoverage` expects.

**I9 — ✅ CONFIRMED.** The mosaic uses the **same window rules as
`/review/sessions`**: UTC ISO-8601 (`…Z`) `wall_start`/`wall_end`, `wall_end >
wall_start`, window **≤ 24 h** (else `400`). Same validation path.

---

## Also shipped this round (beyond confirmations)

- **`/review/sessions` scope-check backfill** (promised in our contract reply):
  single-camera create now 403s an out-of-scope `camera_id` (admin = all). Live
  single-camera playback is **not** regressed — in-scope + admin still `200`
  (Watchtower only ever requests in-scope cameras from scoped `/streams`). Tested.
- **Composite output starts at PTS 0** (drops the TS muxer's 1.4 s offset) so
  consecutive no-discontinuity mosaic segments present a clean per-segment
  timeline to HLS.js — the same property the single-camera path guarantees.
- New unit tests: crop-to-fill filtergraph, the I2 dispatch state machine
  (cold→rendering→ready, dedup, gap/range/qsv/error), single-cam scope.

---

## What's verified now vs. pending live

- **Verified offline (consume the fixtures):** I1 (parse #1), I4 (proxy #2), I3
  (decode #3 + check cell placement), I2 mechanism (unit-tested; you can exercise
  the 503/Retry-After against the fixture-shaped responses).
- **Pending live (post-disk):** the end-to-end cold-scrub → spinner → play, and
  per-cell sync, against the real iGPU + recorded segments. We hold the D6/E1
  line: **E1 ✅ only after live iGPU verification**, never on code-complete.

---

## Cross-reference

- Master rollup `watchtower-to-cilex-vision-api-requests.md`: BACKEND RESPONSE
  block + changelog for this integration round.
- Contract reply: `2026-05-31-multicam-synchronized-review.reply.md`.
- cilex-vision commit: see the changelog entry. Fixtures:
  `docs/letters/fixtures/2026-05-31-mosaic/` (this repo).

Thanks for the precise, client-built letter — pinning the seams against real
fixtures is exactly how we avoid a first-contact scramble.

— Cilex Vision
