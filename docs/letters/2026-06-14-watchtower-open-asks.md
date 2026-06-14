# What Watchtower needs from Cilex Vision — open asks (2026-06-14)

Two open issues, both in the **recorded-playback (review) HLS path**, in priority
order. Each has a standalone detail letter; this is the actionable summary.
Watchtower has shipped client-side mitigations for both, but the source data is
wrong, so any standard HLS player hits the same problems — please fix upstream.

---

## 1. [BLOCKER] Motion-clip playback freezes — playlist omits per-segment `#EXT-X-DISCONTINUITY`

**Symptom:** clicking a motion event on a motion-triggered camera (e.g. `.106`)
opens playback; the video plays ~5 s then freezes on one frame while the playhead
timer keeps ticking. Reproduced reliably.

**Root cause (ffprobe-confirmed):** every review segment is encoded independently
and **resets its PTS to ~1.4 s**, but the motion-clip playlist only emits
`#EXT-X-DISCONTINUITY` around `#EXT-X-GAP` blocks — **not between in-clip
segments**. So `hlsdemux2` plays seg 1, then seg 2's PTS jumps backward with no
discontinuity to announce it → the decoder stalls while the pipeline clock
free-runs.

```
.106 seg/1.ts: PTS 1.400 → 5.296
.106 seg/2.ts: PTS 1.400 → 5.347   ← backward jump, NO #EXT-X-DISCONTINUITY before it
```

Continuous 24/7 cameras (`.108`) reset PTS identically **but emit a discontinuity
before every segment**, so they play fine. Mosaic was the same and you fixed it in
`0d71c0d`.

**Specific ask:** in the single-camera / motion-clip review playlist generator,
**emit `#EXT-X-DISCONTINUITY` before every segment whose PTS restarts** — the same
rule the continuous-camera and mosaic paths already use. (Equivalent alternative:
don't reset PTS per segment. Discontinuities are the cheaper, consistent fix.)

**Verify:** raw `playlist.m3u8` carries a discontinuity before each segment; our
`scripts/playback-smoothness-test.sh` reports 0 freezes.

**Detail:** `docs/letters/2026-06-14-motion-clip-playlist-discontinuities.md`

---

## 2. Seeks exceed 500 ms on far jumps — review keyframe interval too long

**Symptom:** a backward seek / jump that lands deep in a GOP takes ~500–670 ms to
show a frame (target ≤ 500 ms). Near-keyframe landings are fine (~260–375 ms).

**Root cause:** an *accurate* seek decodes every frame from the preceding keyframe
to the target. The review HEVC tier's **keyframe interval is ~4 s** (ffprobe: 8
I-frames in a 32 s segment, 15 fps → ~60 frames/GOP), and VA-API decodes this
stream at ~218 fps, so a mid-GOP landing costs ~60/218 ≈ **275 ms of decode** on
top of a ~230 ms pipeline base ≈ ~505 ms.

**Specific ask:** **shorten the keyframe interval on the review/playback HEVC
rendition from ~4 s to ~2 s** (ideally ~1–1.5 s). That caps worst-case decode at
~30 frames / 218 fps ≈ ~138 ms → every seek ≤ 500 ms regardless of landing.
Scope: review rendition only (live/RTSP isn't seek-driven). Trade-off is modestly
larger segments — your call on the exact interval. Same root cause as the
export-trim long-GOP issue, so it helps trimmed export too.

**Verify:** ffprobe shows ~2 s keyframe spacing; our backward-seek sweep
(−1 m … −10 h) is ≤ 500 ms including mid-GOP landings.

**Detail:** `docs/letters/2026-06-14-playback-seek-keyframe-interval.md`

---

## (Optional, low priority) Large cold segments

Review segments are 30 s HEVC-1440p (~10–15 MB); a cold read from storage is
~110–160 ms each, and a backward seek pulls 2–3 serially. We mitigate this
client-side (our proxy prefetches the next segments + caches them, so cold medium
seeks dropped ~460 → ~365 ms and re-seeks are instant). A backend warm-segment
cache or shorter segments would further help first-time cold seeks, but this is
**not blocking** — only raise it if cheap.

---

## Already resolved — thank you

`hevc_capable` 500 (`131d1b6`), mosaic cold-render latency, export range trimming
(`e78d0dc`), mosaic playlist discontinuities (`0d71c0d`). All verified fixed.
