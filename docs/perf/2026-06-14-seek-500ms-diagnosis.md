# Backward-seek latency → ≤500ms: real diagnosis + fix (2026-06-14)

Goal (user): from a scrubber click / fast-forward / rewind to **video playing
again ≤ 500 ms**. Forward seeks (data already buffered ahead) were already ~70 ms;
the problem is **backward** seeks.

## This overturns Round 4

Round 4 concluded backward seeks were a fixed ~370 ms GStreamer "flush" + ~1 ms
fetch. **That was contaminated** — the bench used `GST_DEBUG` at level 5–6, whose
own logging (11.8 k lines in 2.5 s) inflated the pipeline by ~700 ms, and it
watched the wrong window for I/O. Re-measured **clean** (no GST_DEBUG, low-overhead
proxy timestamps, real compositor, `.108` HEVC), the cost is **two separate
things**, neither a fixed flush:

### 1. Cold segment I/O — *the dominant, fixable half*
A backward seek makes `hlsdemux2` fetch the target segment **and the next 1–2,
serially**, from backend storage. Each cold HEVC-1440p/30 s segment is
**~110–160 ms**, so 2–3 serial cold fetches = the bulk of a cold seek.

| seek | resume (before) | cold segments fetched serially |
|---|---|---|
| −1 m | 300 ms | 1233/1234 @ 27/28 ms (warm — adjacent to played) |
| −10 m | 468 ms | 1215/1216 @ 117/112 ms |
| −1 h | 461 ms | 1110/1111 @ 158/114 ms |
| −5 h | 667 ms | 619/620/621 @ 108/89/119 ms |
| −10 h | 268 ms | seg 0/1 @ 31/32 ms (cached from open) |

### 2. Decode-to-target — *the residual half (GOP-bound)*
An *accurate* seek decodes every frame from the segment's keyframe up to the exact
target. Measured GOP on this footage = **~4 s** (8 keyframes / 32 s segment at
15 fps ≈ 60 frames/GOP). VA-API decodes HEVC-1440p at **~218 fps** (measured:
480-frame segment in 2.30 s). So a landing just before the next keyframe costs
**~60 frames / 218 fps ≈ 275 ms** of pure decode, on top of a ~230 ms pipeline
base. A landing near a keyframe costs ~0. This is **deterministic per landing
spot**, not per distance — `−5 h` happened to land mid-GOP (instrumented: position
lands at +3 ms, status Buffered, then *frozen ~466 ms* while it decodes, then
real-time).

Cost model: **resume ≈ ~230 ms base + cold-fetch(s) + (0–275 ms decode-to-target)**.

Ruled out: live-wall contention (the 16 `vah264dec` are a boot transient — gone by
the seek; normal nav stops live), and codec/tier change (−5 h seg 619 and −1 h seg
1110 are both HEVC 2560×1440 @ 15 fps — no decoder re-init).

## Fix shipped — client: HlsProxy read-ahead prefetch + segment cache
The moment a `.ts` is requested, the proxy serves it and **prefetches the next 2
in parallel** into a 160 MB LRU cache, so the demuxer's serial follow-up requests
become cache hits — collapsing the serial chain. Cached segments also make
**re-seeks to a visited region instant** (scrubbing back and forth).

| seek | before | after (prefetch+cache) |
|---|---|---|
| −1 m | 300 ms | ~330–375 ms (already warm; neutral) |
| −10 m | 468 ms | **~370 ms** ✓ |
| −1 h | 461 ms | **~365 ms** ✓ |
| −5 h | 667 ms | ~660 ms (decode-bound — unchanged by I/O fix) |
| −10 h | 268 ms | ~260 ms (already cached) |

4 / 5 distances now ~260–375 ms, well under 500 ms. Cache hits confirmed (8–9 per
sweep). `src/models/HlsProxy.{h,cpp}`.

## Remaining half — backend: shorten the playback keyframe interval
The only >500 ms case is a far seek that lands deep in a 4 s GOP (~275 ms decode +
~230 ms base ≈ 505 ms). The client can't reduce decode-to-target with QMediaPlayer
(no KEY_UNIT seek control). **Halving the keyframe interval (~4 s → ~2 s) on the
playback HEVC tier bounds the worst-case decode to ~138 ms → worst seek ~370 ms.**
Letter: `docs/letters/2026-06-14-playback-seek-keyframe-interval.md`. Same root as
the export-trim long-GOP finding.

Client-only alternative (heavier, no backend dep): a custom GStreamer playback
pipeline using `GST_SEEK_FLAG_KEY_UNIT` (land on the keyframe ≤2–4 s before target,
play forward — like the −15 s event lead-in), which removes decode-to-target *and*
~part of the base. Large change (replaces QMediaPlayer for playback on both single
+ wall); only worth it if the backend GOP change isn't available.

## Method note
Bench = WT_BENCH=seekgst sweep (anchor on stable playback, issue −1m/−10m/−1h/−5h/
−10h backward, measure interaction→position-advancing) + WT_HLS_LOG with epoch
timestamps to place each fetch on the timeline. All instrumentation was
TEMP-VERIFY, reverted; only the proxy prefetch+cache is permanent.
