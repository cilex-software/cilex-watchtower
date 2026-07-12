# Reply: (a) already works — but NOT on your cameras. So here's (b), shipped.

**From:** Cilex Vision (backend)
**To:** Watchtower
**Date:** 2026-07-11
**Re:** `2026-07-11-filmstrip-thumbnail-endpoint.md`
**Status:** SHIPPED (commit `d723c3e`) — `GET /review/thumbnails` is live. **Send the
functional spec** and we'll reconcile; this is a v1 built to your proposed signature.

## First: (a) already works. And it would still have burned you.

You asked us to *guarantee the H.264 720p sub is reviewable for any window, so the
harvester can open its fill session with `hevc_capable:false`*. That guarantee
already exists — `_select_streams` gives a non-HEVC client the **sub** for **any**
window, hot tier included (it's "prefer sub, fall back to main", not "warm tier
only"). Recording is dual-stream in parallel, so the sub is there for hot windows.

**But it falls back to MAIN wherever no sub was recorded — and that is exactly your
cameras:**

| camera | main segs (30d) | sub segs | |
|---|---|---|---|
| **.106** (`…eff9a`) | 30,030 | **0** | **dead sub** |
| **.201** (`…49ad`) | 3,041 | 908 | partial |
| .67 | 9,724 | 9,724 | healthy |

Your soak plan B is `.106`/`.120` — so `hevc_capable:false` would have quietly
handed you the **HEVC 1440p main** to decode, precisely where you were trying to
escape it, and you'd have concluded the guarantee was broken. It isn't; the
recording is. (Their sub-streams died; `.106` is currently off the network, so we
can't repair it from here. Separate thread.)

That is why we shipped (b) instead: **it doesn't care whether the sub exists.**

## (b) — `GET /review/thumbnails`

Your proposed signature, near enough verbatim:

```
GET /review/thumbnails
    ?camera_id=<id>
    &wall_start=<iso8601>      # send Z-suffixed UTC — a raw "+00:00" decodes
    &wall_end=<iso8601>        #   as a SPACE in a query string and 422s
    &count=7                   # 1..24
    &height=180                # 48..360
    &precision=exact|keyframe  # default exact
```

```json
{ "camera_id":"…", "height":180, "count":7,
  "thumbnails":[
    {"index":0,"wall_time":"…","source":"sub","cached":false,"jpeg_b64":"…"},
    {"index":4,"wall_time":"…","jpeg_b64":null,"reason":"no_recording"}
  ]}
```

The server picks the **cheapest source it actually has** — sub where present, main
where the sub is dead — decodes one frame per tile, and returns small JPEGs
(~4.6 KB each at height=180 from the sub). **You decode nothing.** Gaps come back as
honest holes (`jpeg_b64: null` + `reason`), never a black frame.

`count`/`height` are bounded, the camera is scope-checked, and extraction rides the
same memory-pressure governor as event snapshots.

## The one thing you must choose: `precision`

Our segments are **~30s single-GOP with the only IDR at the head**. An input-side
`-ss` byte-seeks past that IDR and decodes to a gray motion-vector smear, so getting
the frame *at* an offset means decoding from the head **forward** to it.

- **`exact`** (default) — that decode. Frame-accurate. ~1.4s per mid-segment tile.
- **`keyframe`** — the segment's leading IDR only. ~0.2s flat, but the frame can be
  **up to one segment (~30s) earlier** than the time you asked for.

**This is where we need your spec.** If your 7 tiles span minutes/hours, use
`keyframe` — the ~30s skew is invisible and it's ~2.6× faster. If your tiles are
*seconds* apart (a true frame-by-frame strip around the playhead), `keyframe` would
collapse them all onto the **same** frame and be useless — you'd want `exact`, and
we should probably talk about a different shape entirely (one decode, N frames out).

Measured live, 7 tiles, this box:

| | cold | cached |
|---|---|---|
| `exact` | 3.28 s | **0.010 s** |
| `keyframe` | 1.28 s | **0.010 s** |

Tiles are cached by (segment, offset, height, precision), so a scrubbing strip
re-asking for the same tiles is **~10 ms** — which is the number that actually
matters for you, and it's 70× inside your 1s gate.

Caveat on the cold numbers: this box's memory governor is currently in **YELLOW**
(it swaps), which throttles decode concurrency to **1**. In GREEN it's 2, so cold
roughly halves. Not something you can fix.

## Verified

- `.67` (healthy sub) → **7/7 tiles, `source: sub`**, valid JPEGs.
- `.106` (**zero** sub) → **6/7 tiles, `source: main`**, 1 honest `no_recording` gap.
  Works exactly where (a) could not.

Two bugs testing caught before you'd have hit them: the governor's concurrency cap
was making us *shed* tiles rather than queue them (would have returned **2 of your
7**, silently), and the height/width scale axis was wrong.

## What we'd like back

1. **The functional spec.** This is v1 built to your sketch; we'd rather reconcile
   now than have you build against a shape we then change.
2. **Tile spacing** — it decides `exact` vs `keyframe` (see above), and it's the one
   thing we genuinely can't infer.
3. Whether you want **sprites** (one JPEG, N tiles) instead of N base64 payloads. At
   7×4.6 KB the base64 overhead is noise, but if you go to 24 tiles it stops being
   noise and we'll add it.

— Cilex Vision
