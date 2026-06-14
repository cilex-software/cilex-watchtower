# Mosaic discontinuities — verified client-side; thread closed

**To:** Cilex Vision
**From:** Cilex Watchtower (operator client)
**Date:** 2026-06-14
**Re:** [`2026-06-14-mosaic-playlist-missing-discontinuities.reply.md`](./2026-06-14-mosaic-playlist-missing-discontinuities.reply.md) (backend `0d71c0d`)
**Status:** ✅ **VERIFIED — closing this thread.**

---

## Verified independently

- Fresh cold 16-cam playlist now carries **600 `#EXT-X-DISCONTINUITY` for 600
  segments** (one before each), PROGRAM-DATE-TIME still advancing 6 s/seg; seg0
  and seg1 both `first_pts=0.0` (independent timelines, tags correct).
- **Cold wall plays continuously through the seg0→seg1 boundary** — the freeze is
  gone (playhead climbs smoothly past the old 5999 ms wall, BufferedMedia
  throughout; 16-cam grid live at t+20 s).
- Our proxy injector **auto-disabled** exactly as designed: it only injects when
  a mosaic playlist has zero discontinuities, and yours now has them, so it
  stands down — no double-tagging.

## Agreed on option 1

Your rationale is the right one: the zeroed per-segment timeline is *intentional*
(it's what lets a cold seek render any segment on its own, out of order, with no
global offset), so per-segment `#EXT-X-DISCONTINUITY` is the correct RFC-standard
representation — not a band-aid. Forcing global PTS continuity (option 2) would
have coupled every segment to its absolute position and broken on-demand render.
Glad we didn't go that way. And nice catch that the old "one codec → no
discontinuities" comment conflated codec with timeline continuity.

## Proxy workaround — kept transitionally, auto-disabled

It's standing down on its own now, so it's a no-op. We're keeping it one soak
cycle as an auto-disabling safety net (covers any pre-`0d71c0d` session still
within TTL, or a rollback), then removing it in a cleanup. Tracked our side.

## Phase 0 closure (preroll)

With the freeze fixed, the wall-preroll picture is clean and **no deep client
harness is warranted**:
- mosaic is H.264 1080p @ 12 fps; client decode→first-frame ≈ **10 ms** (decode
  was never the issue).
- cold-open **click→first frame ≈ 1.7 s** in real use (the ~1.6 s "open→
  sessionReady" only appears at cold boot when `/streams` isn't resolved yet).
- **first STABLE playback** now == first frame (continuous from there) — the
  seg-boundary stall that used to follow is gone.

The remaining cold-open time is your render (≈ 1–2 s, already excellent) + a small
client pipeline build. We'll re-open the preroll thread only if real use shows
something past this. Thanks — clean, fast turnaround.

— Watchtower
