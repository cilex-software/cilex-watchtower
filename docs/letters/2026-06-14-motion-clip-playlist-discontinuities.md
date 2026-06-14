# Motion-clip playback freezes — playlist omits per-segment #EXT-X-DISCONTINUITY

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-14
**One problem:** review playlists for motion-triggered cameras don't emit a
`#EXT-X-DISCONTINUITY` before each segment, even though every segment resets its
PTS — so the player freezes after the first segment of each clip.

## Symptom (operator-reported, reproduced)

Clicking a `.106` motion event opens playback; the timer ticks but the video is
frozen on one frame. It plays ~5 s then freezes again. The clock free-runs while
the frame is stuck.

## Root cause (confirmed with ffprobe)

Every review segment is encoded independently and **resets its PTS**:

```
.106 seg/1.ts: PTS 1.400 → 5.296
.106 seg/2.ts: PTS 1.400 → 5.347   ← jumps backward, no discontinuity announced
.106 seg/3.ts: PTS 1.400 → 5.347
```

`hlsdemux2` only stays in sync across a PTS reset if a `#EXT-X-DISCONTINUITY`
precedes the segment. **Continuous 24/7 cameras (`.108`) get one before every
segment and play fine. Motion-triggered clips do NOT** — the playlist only emits
discontinuities around the `#EXT-X-GAP` blocks, not between the in-clip segments:

```
#EXT-X-PROGRAM-DATE-TIME:...:29:16
#EXTINF:3.946,
seg/1.ts
#EXT-X-PROGRAM-DATE-TIME:...:29:20      ← no #EXT-X-DISCONTINUITY here
#EXTINF:3.997,
seg/2.ts                                ← PTS resets to 1.4 → hlsdemux2 stalls
```

So the player decodes seg/1 (~5 s) then stalls on seg/2's backward PTS jump.

## The ask

**Emit `#EXT-X-DISCONTINUITY` before every segment whose PTS restarts — for
motion-clip / single-camera review playlists, exactly as you already do for
continuous cameras and (since `0d71c0d`) for mosaic.** Equivalently: make the
single-cam review playlist generator use the same per-segment discontinuity rule
as the continuous-camera path. This is the direct sibling of the mosaic
discontinuity fix (`2026-06-14-mosaic-playlist-missing-discontinuities`).

(Alternatively, don't reset PTS per segment — but per-segment discontinuities are
what the rest of your renditions already do, so consistency is the cheap fix.)

## Client status

We ship a safety net: our local HLS proxy now **normalizes** the playlist — ensures
every segment is preceded by exactly one discontinuity (deduped) and strips
`#EXT-X-GAP` dead-air. Verified: `.106` motion playback went from a 23 s freeze
per clip to smooth (0 stalls, ~15 fps continuous), `.108` unchanged. So playback
is fixed for our client regardless — but the playlist is wrong at the source and
any other/standard HLS player will hit the same freeze, so please fix it upstream.

## How we'll verify

`scripts/playback-smoothness-test.sh` (asserts 0 frame-vs-playhead stalls over a
35 s window). We'll confirm the corrected playlist carries a discontinuity before
every segment via the raw `playlist.m3u8`.
