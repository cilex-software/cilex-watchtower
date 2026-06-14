# Playback seek latency — shorten the keyframe interval on the HEVC playback tier

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-14
**One problem:** accurate backward seeks that land deep in a GOP take too long to
show a frame, because the playback HEVC tier's keyframe interval is ~4 s.

## What we measured (client side, real hardware)

Target: scrubber-click / FF / rewind → playing again ≤ 500 ms. We fixed the
client half (segment read-ahead prefetch + cache in our local HLS proxy collapses
the serial cold-fetch chain; medium backward seeks dropped from ~460 ms to
~365 ms, re-seeks are instant). One half is left and it's yours to tune.

A QMediaPlayer *accurate* seek decodes every frame from the nearest preceding
keyframe up to the exact target. On `.108` (camera_id `hiwatch-083bc14effc1`):

- Playback tier: **HEVC 2560×1440 @ 15 fps**, 30 s HLS segments.
- **Keyframe interval ≈ 4 s** — `ffprobe` on one segment shows 8 keyframes in
  32 s (I-frames at 1.4, 5.4, 9.4, 13.4, 17.4, 21.4, 25.3, 29.3 s) ⇒ ~60 frames
  per GOP.
- VA-API decode throughput here: **~218 fps** for this stream (480-frame segment
  decoded in 2.30 s).

So a seek landing just before the next keyframe must decode ~60 frames ≈
**~275 ms** before the first frame appears, on top of a ~230 ms pipeline base ≈
**~505 ms** — over budget. A seek landing near a keyframe costs ~0 extra. This is
deterministic by landing spot: a far jump that lands mid-GOP (we saw a −5 h jump)
freezes ~466 ms after the seek lands, then resumes; near-keyframe landings resume
in ~260–375 ms.

## The ask

**Shorten the keyframe interval on the playback (review) HEVC tier from ~4 s to
~2 s (ideally ~1–1.5 s).** That bounds worst-case decode-to-target to
~30 frames / 218 fps ≈ **~138 ms** (or ~70 ms at 1 s), so every seek lands
comfortably ≤ 500 ms regardless of where in the GOP it falls.

- Scope: the review/playback HLS rendition specifically. Live/RTSP is unaffected
  by this (it's not seek-driven).
- Trade-off: more keyframes ⇒ modestly larger segments/bitrate. At 1440p/15 fps
  the increase from 4 s→2 s GOP is small and well worth bounded seeks; your call
  on the exact interval vs. storage.
- This is the **same root cause** as the export-trim issue
  (`2026-06-13-export-range-not-trimmed`): a long GOP forced a re-encode to trim
  accurately. A shorter playback GOP helps both.

## How we'll verify

Re-run our backward-seek sweep (−1 m … −10 h, measuring interaction→first-frame on
the real compositor). Acceptance: all backward seeks ≤ 500 ms, including ones that
land mid-GOP. We'll confirm the new keyframe spacing with `ffprobe` first.

## If you can't change the encoder

Tell us and we'll move the fix client-side: a custom GStreamer playback pipeline
using `GST_SEEK_FLAG_KEY_UNIT` (snap to the keyframe just before the target and
play forward — same idea as our −15 s event lead-in). It's a larger change on our
end (replaces QMediaPlayer for review playback), so we'd prefer the encoder tweak
if it's cheap for you.
