Watchtower (the operator client) needs your help to make recorded-playback seeks
fast. Goal: scrubber-click / fast-forward / rewind → video playing again ≤ 500 ms.

We already fixed our client half (our local HLS proxy now prefetches the next
segments and caches them, so the serial cold-fetch chain after a seek is gone —
medium backward seeks went ~460 ms → ~365 ms). One half is left and it's on the
encoder side.

THE PROBLEM
A QMediaPlayer accurate seek decodes from the nearest preceding keyframe up to the
exact target frame. On the review/playback HEVC tier we measured (camera
hiwatch-083bc14effc1, 2560×1440 @ 15 fps, 30 s segments):

- keyframe interval ≈ 4 s (ffprobe: 8 I-frames in a 32 s segment) ⇒ ~60 frames/GOP
- VA-API decode ≈ 218 fps for this stream

So a seek landing just before the next keyframe must decode ~60 frames ≈ 275 ms
before the first frame shows, on top of a ~230 ms pipeline base ≈ ~505 ms — just
over budget. Near-keyframe landings are fine (~260–375 ms). We confirmed it's not
codec/tier (both ends HEVC 1440p) and not I/O (segments were cache hits) — it's
decode-to-target, bounded by the GOP length.

THE ASK
Shorten the keyframe interval on the review/playback HEVC rendition from ~4 s to
~2 s (ideally ~1–1.5 s). That caps worst-case decode-to-target at
~30 frames / 218 fps ≈ 138 ms (≈70 ms at 1 s) → every seek ≤ 500 ms regardless of
where in the GOP it lands.

NOTES
- Scope is the review/playback HLS rendition only; live/RTSP is not seek-driven.
- Trade-off is modestly larger segments; pick the interval vs. storage you're
  comfortable with (2 s is plenty for our target).
- Same root cause as the export-trim issue (long GOP forced a re-encode to trim) —
  a shorter playback GOP helps both seeking and trimmed export.

Please confirm the new keyframe spacing with ffprobe when done; we'll re-run our
backward-seek sweep (−1 m … −10 h, measuring interaction→first-frame on the real
compositor) and accept when all are ≤ 500 ms including mid-GOP landings.

If changing the encoder isn't feasible, say so and we'll do a client-side
KEY_UNIT-seek pipeline instead (bigger change on our side; we'd prefer your tweak).
