# Mosaic preroll investigation — Phase 0 findings (2026-06-14)

Ran the backend-reviewed Phase 0 (instrument-first, decompose, measure-the-shape,
Wayland-not-offscreen, confirm HW decode). It short-circuited the deep harness:
the real defect wasn't preroll at all.

## What "client-side preroll" actually was

| stage | finding |
|---|---|
| codec/decode | mosaic = **H.264 1080p @ 12 fps**; client decode→first-frame ≈ **10 ms** (NOT the bottleneck; the HEVC-software-decode hypothesis was wrong — client sends no `codec`, backend default is H.264) |
| cold-open click→first frame | **≈ 1.7 s** real use; the ~1.6 s "open→sessionReady" is a cold-boot-only artifact (`openMosaicSession` queues behind `/streams` resolution when not yet logged in) |
| server render (seg0) | ≈ 1–2 s (e8079ca/3043dbe), correct |

## The real defect — cold wall freezes after the first segment

Playhead-continuity sampling (not just segment-fetch watching) revealed the cold
wall plays seg0 (~6 s) then **freezes at 5999 ms** while segments keep
downloading. Root cause: every mosaic segment resets to **PTS 0**, but the
playlist declared a continuous timeline with **zero `#EXT-X-DISCONTINUITY`** →
`hlsdemux2` stalls at the seg0→seg1 PTS reset. Single-camera was fine (its
playlist already carries discontinuities).

This also corrected an earlier wrong "sustained playback holds" call — that check
had watched segment *fetches* (which keep happening) instead of the *playhead*.

## Fixes

- **Client (`4ae882d`):** HlsProxy injects the missing discontinuity tags for
  mosaic playlists, auto-disabling once the backend emits its own. Verified: cold
  wall plays through (playhead 5907→26305 ms, smooth).
- **Backend (`0d71c0d`):** mosaic playlist now emits per-segment
  `#EXT-X-DISCONTINUITY` (+ regression test). Verified: 600/600 tags, segs PTS-0,
  wall plays through. Letter thread: `2026-06-14-mosaic-playlist-missing-discontinuities.*`.

## Follow-up

Remove the proxy workaround after a soak cycle (it's a no-op now — auto-disabled).
No deep client preroll harness needed: decode is cheap, preroll ≈ 1.7 s, stable
playback == first frame.
