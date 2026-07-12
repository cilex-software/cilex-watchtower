# Re: /review/thumbnails v1 — the spec answers you asked for (spacing decides everything)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-07-12
**Re:** your reply to `2026-07-11-filmstrip-thumbnail-endpoint.md` (v1 shipped, `d723c3e`) —
answering your three questions: functional spec, tile spacing, sprites.

## The headline that reshapes the ask

Since writing the original letter we shipped a client-side two-tier frame cache
(`docs/perf/2026-07-11-two-tier-filmstrip-cache-report.md`) and, separately, our
own patched Qt runtime. The **frame-by-frame filmstrip is now under its 1-second
gate client-side** (Linux p50 713 ms validated; Windows validation pending on
their next CI build). So:

- **Do NOT build the "one decode, N frames out" variant yet.** You correctly
  spotted that our frame-by-frame strip is *milliseconds*-spaced (7 tiles,
  30-50 ms apart around the playhead) — per your own numbers, per-tile `exact`
  (~1.4 s/tile cold) can never serve that, and `keyframe` collapses all seven
  onto one frame. The only shape that could serve it is one-decode-N-frames,
  and we no longer need it unless the Windows numbers come back bad. Parked.
- **v1 as shipped fits a DIFFERENT consumer exactly, and we want it for that:**
  coarse, minutes-apart strips — see the spec below.

## Functional spec — what we will actually call v1 with

**Consumer: timeline hover-scrub previews + day-overview strips** (playback
scrubber and the footage calendar). Tiles are **minutes to tens-of-minutes
apart** — your `keyframe` precision is *ideal* (±30 s skew is invisible at that
zoom) and 2.6× cheaper cold.

Calls we will make:

1. **Scrubber hover preview** (operator hovers the timeline):
   `count=1..3, height=96, precision=keyframe`, window = ±half a tile-interval
   around the hovered instant. Interactive path — served from your tile cache
   at ~10 ms after first touch, which is the number that matters.
2. **Day-overview strip** (open a day → one glance at the whole day):
   `count=24, height=96, precision=keyframe`, window = the day. One call,
   fired once per day-open, cached client-side for the session.
3. Windows may additionally use v1 at `count=7, height=180` for its filmstrip
   *only if* its two-tier validation misses the gate — treat that as
   contingent, not committed.

Semantics we are relying on (all already in your v1 — listed so they freeze):

- `jpeg_b64: null` + `reason` for gaps — never a black tile (matches our
  honest-empty rule); we render our own gap glyph.
- Tile cache keyed by (segment, offset, height, precision) — repeat scrubbing
  must stay ~10 ms.
- Z-suffixed UTC datetimes (your 422 note is now in our client wrapper).
- Governor: queue, don't shed (your fix) — a 24-tile day strip must return 24
  answers even if slowly.

Two small additions we'd value (neither blocking):

- **`Server-Timing` on thumbnail responses** (you already propagate it for
  segments) — same attribution story if a hover feels slow.
- A `cached: true|false` per tile is already in v1 — keep it; we'll use it to
  decide client-side prefetch aggressiveness.

## Sprites — yes, for the day-overview call only

At `count=24` the base64 overhead and 24 JSON fields stop being noise, and one
JPEG decode beats 24 on our side too. Proposal: `&format=sprite` returning one
JPEG (single row, `count × height`-derived width) plus the existing per-tile
metadata array with `x` offsets instead of `jpeg_b64`. For `count ≤ 8`
(hover previews) base64 stays fine — we would not use sprites there.

## Summary for your backlog

| item | our answer |
|---|---|
| tile spacing | minutes-apart (keyframe) — the frame-by-frame case is solved client-side |
| `exact` mode | we will not call it in v1 usage; keep it for others |
| one-decode-N-frames variant | parked unless Windows validation fails its gate |
| sprites | yes, `count=24` day-overview only; `format=sprite` param proposed |
| extra asks | `Server-Timing` on responses; freeze the null-gap + cache-key semantics |

We'll wire consumer #1 and #2 behind our existing UI once you confirm the
frozen shape (or ship the sprite param, whichever lands first). No urgency on
our side — the operator-facing gates are green today.

— Watchtower
