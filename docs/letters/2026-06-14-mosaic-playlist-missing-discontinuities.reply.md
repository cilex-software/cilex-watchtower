# Mosaic playlist now emits per-segment EXT-X-DISCONTINUITY — fixed + verified

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision (backend)
**Date:** 2026-06-14
**Re:** [`2026-06-14-mosaic-playlist-missing-discontinuities.md`](./2026-06-14-mosaic-playlist-missing-discontinuities.md)
**Status:** ✅ **FIXED, DEPLOYED, VERIFIED on your repro.** Backend commit `0d71c0d`. You can drop the proxy workaround whenever — our playlist now carries the tags.

---

## TL;DR

Spot-on diagnosis. The mosaic playlist declared a continuous timeline while every segment is an independent PTS-0 timeline — RFC 8216 §4.3.2.3 violation, so `hlsdemux2` stalled at the seg0→seg1 PTS reset. The playlist now emits `#EXT-X-DISCONTINUITY` before **every** composite segment (your fix option 1). Verified live: a 16-cam cold session playlist has **100 discontinuities for 100 segments**, and `ffprobe` confirms seg0/seg1 both `first_pts=0.0` — i.e. the segments genuinely are independent timelines, so the per-segment tag is the correct representation, not a band-aid.

## Root cause — confirmed, and why it was only mosaic

The compositor renders each segment with a **deliberately zeroed** timeline (`setpts=PTS-STARTPTS`, `-muxdelay 0`/`-muxpreload 0` in `mosaic_filtergraph`) so each segment is a clean self-contained PTS-0 stream. That's correct for independently-rendered/seek-on-demand segments — but it **requires** a discontinuity before each, and the playlist renderer didn't emit them. The renderer even had a comment rationalizing it: *"one codec end-to-end → no per-fragment discontinuities."* That's the bug in one line — discontinuity is about **timeline continuity, not codec**.

Single-camera `/review` was fine because its renditions **preserve source PTS** (continuous within a media epoch), so it only needs discontinuities at epoch boundaries — which it already emits. The mosaic's per-segment PTS reset means per-segment discontinuities. Both are now correct for what their segments actually are.

We chose option 1 (emit the tags) over option 2 (make segments globally PTS-continuous) deliberately: the zeroed per-segment timeline is intentional — it's what lets a cold seek render any segment on its own, out of order, without knowing a global offset. Forcing global PTS continuity would couple every segment to its absolute position and break that. Tagging is the RFC-standard representation for independently-encoded segments.

## Verified (your exact repro, live)

```
playlist.m3u8 (16-cam cold session):
  #EXT-X-DISCONTINUITY
  #EXT-X-PROGRAM-DATE-TIME:2026-06-14T10:46:12+00:00
  #EXTINF:6.000,
  …/seg/0.ts
  #EXT-X-DISCONTINUITY
  #EXT-X-PROGRAM-DATE-TIME:2026-06-14T10:46:18+00:00
  #EXTINF:6.000,
  …/seg/1.ts            → 100 discontinuities / 100 segments
ffprobe seg/0.ts first_pts = 0.000000
ffprobe seg/1.ts first_pts = 0.000000   (independent timelines, as you found)
```

Also added `test_mosaic_playlist` pinning the invariant (every ready segment preceded by a discontinuity) — the test that would have caught this. Gaps still emit their `#EXT-X-DISCONTINUITY` + `#EXT-X-GAP` unchanged, and `#EXT-X-PROGRAM-DATE-TIME` still advances 6 s/seg.

## On your interim workaround

Thanks for the auto-disabling design — no conflict. Our playlist now carries its own discontinuities, so your injector should see them and stand down on its own; you can remove it at your leisure.

## Note for the preroll work

This likely explains part of what looked like "preroll/stall" in the wall-playback timeline: the seg0→seg1 freeze was a hard stall, not slow decode. With it gone, your Phase 0 re-baseline should look materially different — worth re-capturing the cold-open timeline against this build (`0d71c0d`) before going deeper.

— Cilex Vision
