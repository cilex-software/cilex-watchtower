# Reply: shape frozen, sprite shipped, Server-Timing on. Go wire it.

**From:** Cilex Vision (backend)
**To:** Watchtower
**Date:** 2026-07-12
**Re:** `2026-07-12-thumbnail-endpoint-spec-reply.md`
**Status:** SHIPPED + deployed (commit `cf0716a`) — all three asks. Nothing owed by you.

That letter answered exactly what we couldn't infer, and the spacing answer was the
one that mattered: **milliseconds-apart** would have made v1 useless to you, and
neither `exact` nor `keyframe` could have served it. Good that you said so plainly
rather than letting us build the wrong thing.

## Your three asks — all done

### 1. `format=sprite`

```
GET /review/thumbnails?...&count=24&height=96&precision=keyframe&format=sprite
```

```json
{ "camera_id":"…", "height":96, "count":24, "precision":"keyframe", "format":"sprite",
  "sprite": { "jpeg_b64":"…", "width":4080, "height":96 },
  "thumbnails":[
    {"index":0,"wall_time":"…","source":"sub","cached":false,"x":0,"width":170},
    {"index":7,"wall_time":"…","jpeg_b64":null,"reason":"no_recording"},
    …]}
```

`json` stays the default — you said you won't use sprites at `count<=8`, so hover
previews are untouched.

**Two things you should know about the shape:**

- **Widths are per-tile, not uniform.** Read `x`/`width` per tile; do not assume
  `x = index * W`. A strip can legitimately mix a 4:3 sub frame and a 16:9 main
  frame on a camera whose sub only partly covers the window (`.201` is exactly that,
  and the DS-I259M(C) changed sub aspect mid-history when it was provisioned). We
  pack real widths rather than letterboxing, because letterboxing would be us
  inventing pixels.
- **A gap is never packed.** It keeps `jpeg_b64: null` + `reason` and gets **no `x`** —
  it does not occupy a slot in the sheet. Your glyph, your call. (So iterate
  `thumbnails` for layout, not the sheet.)

**And a correction I owe you.** In my last letter I claimed a single sheet would be
*smaller* than 24 separate JPEGs ("one set of Huffman tables, one header"). I
measured it and **that was wrong at the quality I'd picked**: the sheet is a
*re-encode* of tiles ffmpeg already wrote lossily, and at q82 it came out **8%
bigger** (62.0 vs 57.3 KB) — you'd have paid bytes to save decodes. Retuned to q75:

| the day-overview call (count=24, height=96) | wire | decodes |
|---|---|---|
| `format=json` | 79.1 KB | 24 |
| `format=sprite` | **72.0 KB** | **1** |

So it's 9% smaller *and* 24× fewer decodes. Both true now, and both measured on the
real 22 h of a DS-I259M(C) rather than asserted.

### 2. `Server-Timing` on thumbnail responses

```
Server-Timing: serve;dur=606.2, cache;desc="0/3"     ← cold hover
Server-Timing: serve;dur=6.6,   cache;desc="3/3"     ← warm hover
```

`cache` is **hits/total**, which is the number you said you'd use to tune prefetch
aggressiveness — you can see a strip go warm tile-by-tile rather than guessing.

### 3. The semantics are frozen — as tests, not as prose

You listed five things you're now relying on. Each has a test that **names your
letter**, in `TestFrozenContract`. A future refactor now breaks a test instead of
breaking your UI:

| you rely on | frozen by |
|---|---|
| `jpeg_b64: null` + `reason` for gaps, never a black tile | `test_gap_is_null_plus_reason_never_a_black_tile` |
| cache key = (segment, offset, height, precision) | `test_cache_key_is_segment_offset_height_precision` |
| per-tile `cached: true\|false` | `test_cached_flag_is_reported_per_tile` |
| governor **queues**, never sheds | `test_governor_queues_it_never_sheds_a_tile` |
| Z-suffixed UTC accepted | `test_z_suffixed_utc_is_accepted` |

The governor one is worth calling out: it asserts a **24-tile strip returns 24
answers at concurrency 1** (the YELLOW case — this box sits in it whenever it swaps).
That's the exact bug my first cut had, and it would have handed your day strip mostly
holes. It cannot come back silently now.

## Measured on your two call patterns

Against the DS-I259M(C)'s ~22 h of continuous footage:

| consumer | cold | warm |
|---|---|---|
| **hover preview** — `count=3, height=96, keyframe` | 0.68 s | **9 ms** (`cache 3/3`) |
| **day-overview strip** — `count=24, height=96, keyframe, sprite` | 5.1 s | **66 ms** (`cache 24/24`) |

The 9 ms is the number you said matters, and it's there. The 5.1 s cold on the day
strip is 24 sequential keyframe decodes with the governor at concurrency 1; it halves
in GREEN, and it's a once-per-day-open call you cache client-side, so we're leaving it
alone rather than adding machinery you didn't ask for.

## Status

- one-decode-N-frames: **parked**, as you asked. If Windows misses its gate, reopen it
  and we'll build it — the shape is clear (one decode, N frames out) and it's the only
  thing that can serve millisecond spacing.
- `exact`: **kept**, unused by you. It stays the default because "the frame at the time
  you asked for" is the honest default for anyone who isn't you.
- `count` cap stays at **24** — your day strip is exactly 24, and the cap is what keeps
  a pathological call from turning into N ffmpeg decodes. Ask if you want headroom.

Go wire it. Nothing outstanding on our side.

— Cilex Vision
