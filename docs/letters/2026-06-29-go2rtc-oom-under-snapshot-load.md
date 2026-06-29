# go2rtc OOM-kills under camera-producer load — 2026-06-29

**To:** Cilex Vision backend
**From:** Watchtower client
**Severity:** critical (paged via ntfy-critical), recurring

## What happened

`ContainerOOMKilled` alerts fired for the **go2rtc** cgroup twice:

| when (UTC) | when (MSK) | processes OOM-killed in go2rtc cgroup |
|---|---|---|
| 2026-06-28 20:29 | 23:29 | 8 |
| 2026-06-29 07:46 | 10:46 | 3 → 1 |

`docker inspect go2rtc`: **`Memory=536870912` (512 MiB), `RestartCount=19`, `OOMKilled=true`** — chronic, not a
one-off. `GET /api/streams` shows go2rtc serves the **whole fleet: 68 streams (~34 cameras × main+sub)**, several
of them VA-API transcodes (`ffmpeg:cam-1#video=h264#width=1280#hardware=vaapi`, …).

## Cause (two-sided — we own one side, the cap is the other)

go2rtc starts a producer (RTSP connect / ffmpeg transcode) **per stream on demand**. Around both kills its log
shows a burst of `mjpeg/mjpeg.go:126 … write: broken pipe` to the host — frame/stream requests that woke cold
producers and were then abandoned. Wake enough producers at once and a **512 MiB cgroup sized for ~zero
concurrent producers** OOMs; ~9 concurrent cold requests was enough.

**1. Our side (mitigated this commit).** Watchtower's event-snapshot widget fetched the go2rtc live frame
(`/api/frame.jpeg?src=<camera>`) **eagerly for every event shown**, as a fallback for the stored event-still.
The Triage feed spans many cameras, so showing/scrolling/cycling events woke a producer **per distinct camera**
— and our leak-test harness (opening ~26 events/min for long stretches) amplified that into sustained
producer-churn, plausibly contributing to the memory pressure (the 2026-06-29 07:46 kill overlaps a client
run). **Fix:** the live frame is now fetched **only when the stored still actually 404s** (lazy fallback),
which confines go2rtc traffic to genuinely still-less events. We can't prove our client was the *sole* trigger
(a browser/live-view consuming the transcoded streams would look the same in the logs), but we've cut our
footprint regardless.

**2. Your side (the ask).** A 512 MiB cap for a 34-camera go2rtc, where any consumer can wake a producer, is the
root fragility — a single client requesting stills should not be able to OOM it. Please consider:

- **Raise the go2rtc memory cap** to match the producer count it may hold, and/or **bound concurrent
  producers** with prompt teardown of producers whose only consumer broke the pipe.
- **Serve `/api/frame.jpeg` from a cached recent keyframe** instead of waking a full RTSP/transcode producer
  per request. Snapshots/thumbnails don't need a live pipeline; a cached still would make them cheap **and**
  remove the transient `404`s we see when a producer is cold (which is also why our fallback sometimes can't
  render). This is the highest-leverage fix for both the OOM and snapshot reliability.

## How to reproduce

Request `/api/frame.jpeg?src=<camera>` for ~10 distinct cold cameras within a few seconds and watch go2rtc RSS
climb toward 512 MiB → cgroup OOM. Our old eager-fallback did this incidentally across the event feed; the
lazy fix stops it from our side, but the cap + per-request producer-wake remain independently reproducible.
