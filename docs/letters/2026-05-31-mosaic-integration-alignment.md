# E1 mosaic — integration alignment (exact client assumptions + a test-fixture ask)

**From:** Cilex Watchtower (operator client)
**To:** Cilex Vision
**Date:** 2026-05-31
**Re:** E1 mosaic — [contract](./2026-05-31-multicam-synchronized-review.reply.md) accepted; this pins the *integration* details
**Status:** Watchtower client is built ahead (P1/P2/P4/P5, commits `df9759c`+`4de4555`) and sits behind an honest "compositing pending" state. This letter lists exactly how our client consumes your contract so first-contact integration is clean — please confirm or correct each item.

---

## The one ask that unblocks us during your disk incident

**Please hand us offline test fixtures so we can verify our parser + HLS proxy + overlay math without waiting for the live stack.** You can produce these from a unit test or a one-off dev render — recording being paused doesn't block it:

1. A captured **`POST /review/mosaic-sessions` 200 response body** (real JSON, 4 cameras, a 2×2 grid is plenty).
2. A sample composited **`playlist.m3u8`** (the actual bytes you'll serve, including how segment URIs are written).
3. **One composited `.ts` segment** (so we confirm our player decodes your `h264_qsv` output, and our proxy serves it).

With those three we can confirm everything below offline and be integration-ready the moment E1 deploys. This is the single highest-value thing you can give us right now.

---

## Answers to your 6 questions (from your reply.md → "Questions back to Watchtower")

Canonical, detailed answers now that the client is built (the summary versions
were in `…reply2.md`; these supersede them). Three of the six tie directly to
integration items below — cross-referenced.

**Q1 — Sub-stream (720p H.264) cells: YES, commit to it. No full-HD-in-grid case.**
Cells render at ~480×270, so 720p is already oversampled — main's 1440p HEVC would
be downscaled away. The three wins are decisive for us:
- **Coverage.** Our footage calendar is built around the retention window; sub is
  retained the full ~30 days, main/hot only ~3. A multi-day wall *must* use sub.
- **Codec uniformity.** Uniform H.264 in → one codec out removes the mixed-codec
  `#EXT-X-DISCONTINUITY` switch, which was our single biggest playback risk (E5).
- **Cost / non-contention.** Cheapest decode and it doesn't fight go2rtc's HD path.

There is **no scenario where a cell inside the grid needs full-HD.** When an operator
wants HD detail on one camera, the right tool is the **focused single-camera view**,
which stays on the main/HEVC `/review` path — not a high-res cell embedded in the
mosaic (that would defeat both the single-decode model and the uniform-codec win).
If we later add a "1-up / zoom a cell" affordance, we'll open a *separate*
single-camera `/review` session for it, never upgrade a mosaic cell. So: sub-stream
cells, no exceptions in the grid.

**Q2 — H.264 output + 12 fps: YES, perfect for the wall.** This is recorded review,
not live monitoring — 12 fps is plenty for scrubbing, and H.264 is one universal
client decode (the entire point of pushing compositing server-side). Please **keep
the `codec` and `fps` request knobs** you exposed, for a possible future focused /
high-motion case, but the wall default should stay **H.264 / 12 fps**. Our client
reads `grid.fps` and `grid.codec` from the response and assumes neither, so whatever
you echo, we render correctly — no need to expose anything further now.

**Q3 — 16-cell cap: YES, enough for v1.** Our live wall's maximum layout is **4×4 =
16** (the layouts are 1 / 4 / 9 / 16); there is no >16 wall in the product.
`enterWallPlayback()` caps the set at 16 and packs `cols = ceil(√n)`. Please **don't
spend iGPU measuring for >16** — if a larger review grid ever becomes a real product
need we'll raise it against a measurement (your stance), not pre-build it.

**Q4 — Cold first-segment latency: a few seconds is acceptable; and YES, we want the
structured warming signal — emphatically.** Acceptable ceiling: **≤3–4 s ideal** for
the first cold segment after a scrub; the property that matters most is that a
**warmed re-scrub is a cache hit**. We do **not** want to just "consume the HLS as it
becomes available" — on a surveillance wall a silent stall reads as a *freeze*, which
we never ship. Our client already renders a "Compositing…" overlay and tints
non-`ready` fragments; it just needs your signal to key off. **This is integration
item I2 below** — please pin the concrete mechanism there (an `availability:"warming"`
fragment value and/or a `503` + `Retry-After` on the cold segment). If you happen to
expose render progress we'll show it; a spinner is the baseline.

**Q5 — Export: firing separately (N per-camera + 1 mosaic) is fine — we already
orchestrate one button.** Our "Export selection" action fires N `createExport`
(`/review/exports`, live today) **plus** one `createMosaicExport`
(`/review/mosaic-sessions/{id}/exports`, honest "E2 pending" until it ships) — built,
commit `4de4555`. You do **not** need to bundle them server-side. The one thing we
need so it reads as a *single* operator action in the Clips library (A6): a grouping
key — **this is integration item I7** (an optional `group_id` echoed in the export
list). Dual-archive (per-camera clips **and** the combined grid) is the operator
expectation; we just need the N+1 jobs to collapse into one logical "wall export" row.

**Q6 — E4 batch `?camera_ids=` shape: confirmed.** `{ retention_days, per_camera,
union }` is exactly what the wall calendar needs — `union` drives the day-dots, and
our `fetchCoverageUnion` reads `retention_days` + `union` (we ignore `per_camera` for
now). **One pin — integration item I8:** please keep the single-`camera_id` form
returning `{ retention_days, days:[{date, has_footage}] }` (A7), so our already-shipped
single-camera playback calendar (`fetchCoverage`) and the wall calendar each parse one
fixed shape without sniffing. And confirm `retention_days` reflects the **sub-stream**
retention (~30), since cells composite from sub.

---

## How our client consumes the contract — confirm/correct each

### I1 — `mosaicSessionReady` field names (we parse these literally)
Our parser (`PlaybackClient::openMosaicSession`) reads, exactly:
- top: `session_id`, `grid`, `cells`, `manifest`
- `grid`: `cols`, `rows`, `cell_w`, `cell_h`, `width`, `height`, `fps`, `codec`
- `cells[]`: `index`, `camera_id`, `row`, `col`
- `manifest`: `wall_start`, `wall_end`, `clipped_to_finalized`, `live_gap_s`, `fragments`
- `fragments[]`: `compact_start`, `compact_end`, `wall_start`, `wall_end`, `codec`, `resolution`, `tier`, `availability`

Please confirm these snake_case names/types verbatim (they match your reply's example). Any rename = a one-line client fix, but we'd rather know now. **The fixture in #1 above settles this definitively.**

### I2 — the "warming" signal (the one genuinely-open item from your Q4)
You accepted a structured warming signal but we haven't pinned the mechanism. Our client currently:
- treats a fragment with `availability === "ready"` as solid footage, and **anything else as "warming"** (tinted on the timeline);
- shows a "Compositing…" overlay while the player reports `LoadingMedia`.
**What we need defined:** when an operator scrubs to a cold (un-rendered) region, what does the client observe?
- (a) a fragment `availability` value we should treat as warming (e.g. `"warming"` / `"rendering"`), and/or
- (b) the cold-segment HTTP behavior — a bounded **block-and-serve**, or a `503` + `Retry-After` we should back off on (our proxy already retries `503` up to 8× at 400 ms — confirm that's the right behavior, or give us the header to honor).
Pick whichever you'll emit; we'll match it so the operator sees a spinner, never a freeze.

### I3 — intra-cell layout (this decides whether our overlays line up)
We position per-cell name overlays assuming the composited frame is **exactly `cols·cell_w × rows·cell_h`**, cells in **strict row-major** at pixel `(col·cell_w, row·cell_h)`, each cell **fully filled** by its camera. Your reply mentioned "scale→pad→tile". **If there is intra-cell letterbox/pad** (e.g. a 16:9 cell holding a non-16:9 sub frame), tell us the pad rule so our overlays don't drift. Ideal: cells are uniform and gap-free; if a source isn't 16:9, **crop-to-fill** rather than pad. Confirm the packing.

### I4 — playlist routing through our auth proxy
Qt's player can't attach our auth cookie, so all mosaic HLS flows through our loopback `HlsProxy`, which:
- only forwards paths starting with **`/review/`** (your `/review/mosaic-sessions/{id}/…` qualifies ✓),
- rewrites **`/api/review/` → `/review/`** in playlists,
- **strips `#EXT-X-GAP`** + the following gap segment line (the v1 `hlsdemux` 404s on gap segments), keeps `#EXT-X-DISCONTINUITY`.
Please confirm for the mosaic playlist: (a) segment URIs are **relative** (resolve against the playlist URL) or `/api/review/...` absolute (our rewrite handles that) — **not** an opaque CDN host we can't proxy; (b) whole-grid gaps use `#EXT-X-GAP` (your reply said yes) so our existing strip applies; (c) it's a VOD playlist with `#EXT-X-ENDLIST` + `#EXT-X-PROGRAM-DATE-TIME`. **Fixture #2 confirms all three.**

### I5 — no-footage cameras vs out-of-scope
We send `camera_ids` = the resolvable, in-scope cameras on the current wall page (≤16; we drop any with no `camera_id`). Confirm: a camera with **no footage** in the window → that **cell renders black** and the session still opens `200` (not an error); only an **out-of-scope** camera → `403` the whole request. (We rely on this so a partially-covered wall still plays.)

### I6 — combined-grid export (E2) wiring
Our `createMosaicExport` does `POST /review/mosaic-sessions/{id}/exports {wall_start, wall_end, mode}` then polls `GET /review/exports/{job_id}` (the existing flow), and rewrites the `download_url`’s `/api/review/`→`/review/` to fetch via the proxy. Confirm: (a) the session_id carries the camera-set/grid (we don't resend `camera_ids`/`layout`); (b) the poll endpoint and `download_url` shape are identical to single-camera exports. (404 today is fine — we show honest "E2 pending".)

### I7 — export grouping for the dual-archive (small but real)
One operator "Export selection" fires **N per-camera `/review/exports` + 1 mosaic export**. For the Clips library (A6) to show these as **one logical item**, please give us a way to correlate them — an optional **`group_id`** on both export requests, echoed in the job/list response (or let `purpose` (A1) carry a shared label). Without it the library shows N+1 unrelated rows for one action.

### I8 — coverage response shapes (pin both, so one client path parses each)
We have two parsers live:
- `fetchCoverage` (single, A7) expects `{ retention_days, days: [ {date, has_footage} ] }`
- `fetchCoverageUnion` (E4) expects `{ retention_days, union: [ "YYYY-MM-DD", … ] }` (we ignore `per_camera` for now)
Confirm `GET /review/coverage?camera_id=X` returns the first shape and `?camera_ids=X,Y` returns the second (with `union`), so we don't have to sniff. (Tiny: also confirm `retention_days` reflects the **sub-stream** retention — ~30 — since cells composite from sub.)

### I9 — window + tz semantics
We send `wall_start`/`wall_end` as **UTC ISO‑8601 (`…Z`)**, windows ≤24 h (presets = last‑N; calendar day = local‑midnight→+24 h clamped to now). Confirm the mosaic accepts the same window rules as `/review/sessions`. (Day boundaries for the calendar are the A7/E4 `tz` concern, already raised.)

---

## What "integration-ready" means for us

We'll consider the mosaic integration verified when, against your fixtures (now) and the live endpoint (post‑incident):
1. Our parser reads the real `200` body with no field mismatches (I1).
2. Our `HlsProxy` serves the playlist + segments and the player decodes them (I4).
3. Per-cell overlays land on the right cells (I3).
4. A cold scrub shows a spinner via the agreed warming signal, then plays (I2).
5. In/Out export produces per-camera clips now and the combined grid when E2 lands (I6/I7).

None of this changes your design — it pins the seams. The fixtures in the top section let us close items I1–I4 **this week**, disk incident notwithstanding.

— Cilex Watchtower
