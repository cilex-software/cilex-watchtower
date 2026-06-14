# Mosaic playlist declares a continuous timeline but segments have reset PTS — wall freezes after the first 6 s

**To:** Cilex Vision
**From:** Cilex Watchtower (operator client)
**Date:** 2026-06-14
**Severity:** HIGH — cold wall playback plays exactly one segment (~6 s) then freezes. Client has a working interim workaround; this is the proper fix.

---

## Symptom (found during the mosaic-preroll investigation)

Open the wall on any cold day → it plays the first ~6 s smoothly, then the
**playhead freezes** at 5999 ms and never advances, while the player keeps
downloading segments ahead. `mediaStatus` sits in Buffering, `playbackState`
stays Playing, position dead. (This is why earlier "sustained playback holds"
checks passed — they watched segment *fetches*, which keep happening, not the
playhead, which doesn't.)

## Root cause (measured)

The mosaic segments are each rendered **independently with reset timestamps** —
every segment starts at **PTS 0** — but the mosaic playlist declares a
**continuous timeline with no `#EXT-X-DISCONTINUITY`**:

```
# ffprobe first PTS of consecutive mosaic segments:
seg0: first_pts=0.000000   seg1: first_pts=0.000000   seg2: first_pts=0.000000
# playlist (600 segments): 0 discontinuities, PROGRAM-DATE-TIME advances 6 s/seg
#EXT-X-PROGRAM-DATE-TIME:2026-06-07T02:00:00+03:00
#EXTINF:6.000,
seg/0.ts
#EXT-X-PROGRAM-DATE-TIME:2026-06-07T02:00:06+03:00   ← claims +6 s
#EXTINF:6.000,
seg/1.ts                                              ← but its PTS is 0 again
```

So the player plays seg0 (PTS 0→6 s), then seg1's PTS jumps **back to 0** with no
discontinuity to explain it. A continuous-timeline HLS demuxer (GStreamer
hlsdemux2 in Qt 6.4) treats that as invalid and stalls at the boundary — even
though seg1 is already downloaded (we confirmed seg1 returns 200 at ms≈59, long
before the freeze). Per RFC 8216 §4.3.2.3, segments whose timestamps don't
continue from the previous one **must** be preceded by `#EXT-X-DISCONTINUITY`.

**Single-camera playback is unaffected because its playlist already emits
discontinuities** (we see them at ~75 % of single-cam boundaries) — so the player
re-bases per segment and plays through. The mosaic playlist simply doesn't.

## Proper fix (your side) — either is fine

1. **Emit `#EXT-X-DISCONTINUITY` before each mosaic segment** (each has reset PTS)
   — exactly what the single-camera playlist already does. Simplest.
2. **Make the mosaic segments PTS-continuous** (seg1 starts at 6 s, seg2 at 12 s…)
   so the playlist's continuity claim is true. Then no tags needed.

## Client-side interim workaround (shipped, auto-disabling)

To unblock operators now, our HLS proxy injects `#EXT-X-DISCONTINUITY` before
each segment **for mosaic playlists that contain none** — and **automatically
stops** the moment your playlist carries its own discontinuities (so it won't
double up or fight your fix). Verified: with injection, the cold wall now plays
continuously past 6 s (playhead 5907→7346→8866→…→26305 ms, smooth, BufferedMedia
throughout). Single-camera and the existing seek/event behavior are untouched.

## Asks

1. Pick fix (1) or (2) and ship it; the client workaround retires itself.
2. Confirm which you chose so we can drop the proxy injection in a later cleanup.

(Unrelated good news from the same investigation: the mosaic is H.264 1080p @ 12 fps
and the client decode→first-frame is ~10 ms — your codec/resolution choices are
spot-on; cold-open preroll to first frame is ~1.7 s in real use. Decode is not a
concern. This boundary freeze was the only real defect.)

— Watchtower
