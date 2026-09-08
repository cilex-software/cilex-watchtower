# Live open → first decoded frame — measured 2026-09-08, target 500 ms

**Result: the target is met for `recording` cameras (~50 ms) and missed ~2× for every
`armed` camera (450–900 ms). Cause proven: go2rtc drops the camera producer when its last
consumer leaves, so an armed camera — nothing consuming it between motion events — is
dialled cold on every open. Server-side fix; letter sent to CV.**

## Method
`tools/live-ttff-probe.py`: one cold GStreamer pipeline per sample
(`rtspsrc protocols=tcp latency=0 ! rtph264depay ! h264parse ! avdec_h264`), timed from
`PLAYING` to the first **decoded** frame. Same decoder family as the app's live tile; the
app's own Qt tile construction is not included, so real tiles are this number plus a
small client-side constant. Stream URLs from `/streams` via the station display session.

## Numbers
- 40 cold opens, 8 cameras, 0 failures: **p50 108 ms, p95 561 ms, max 574 ms, 29/40 ≤ 500 ms**.
- Widened cohort (12 more cameras): every `recording` camera 40–92 ms; every `armed`
  camera 424–1003 ms — **regardless of model** (I456Z armed = 487–886, I456Z recording = 40–48).

## The proof (armed I202(E), same camera, same minute)
```
cold open (no consumer)            547 ms
open while a consumer holds         72 ms
again, still held                   86 ms
cold again after release (3 s)     424 ms
```
Population: 126 online, **72 armed** (miss target), 54 recording (meet it).

## Dead ends, so nobody re-runs them
- Model/firmware (I202(E)/V5.8.0) — coincidental; armed I456Z cameras are equally slow.
- Keyframe interval — all cameras measured GOP ≈ 3.3 s; cannot produce a 50 vs 500 split.
- Back-to-back opens — NOT warm: go2rtc drops the producer instantly on last-consumer
  exit, so open #2 was as cold as #1 (measured 884 ms). Only an overlapping consumer warms it.
- An `h264parse`-level probe mis-flagged first packets as P-frames on fast cameras; the
  decoder-level probe is the truthful one and is what `samples.jsonl` holds.
