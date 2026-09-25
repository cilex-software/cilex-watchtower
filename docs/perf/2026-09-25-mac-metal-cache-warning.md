# "cannot create texture, Metal texture cache was released?" — reproduced, explained, instrumented

**2026-09-25, macOS agent.** Qt 6.11.1 (Homebrew), macOS 26.6, M1 Pro.

## Scale — larger than reported

The flight recorder collapses floods into "(previous message repeated xN)" lines, so a
naive grep counts ~628. Folding those back in: **46,801 occurrences in 8 episodes**
(21 Aug → 24 Sep), five of them AFTER the 2026-08-22 hide-path guard in
`PlaybackScreen.qml`. The worst, 22 Sep 16:30–16:53 (v1.1.494), was ~44,000 in 24 min —
a sustained 60/s. Every episode's surrounding log was startup lines only: nothing
recorded what the app was doing.

## Mechanism — reproduced in isolation

`tools/tests/metal-cache-repro/` plays a clip through `QMediaPlayer` into a `QVideoSink`
that no `VideoOutput` ever shows — exactly `FrameCache::harvestSink()` — and calls
`QVideoFrame::toImage()` per frame:

| mode | frames | warnings | images |
|---|---|---|---|
| bare sink + `toImage()` | 180 | **360 — exactly 2 per frame** (NV12, 2 planes) | 180/180 valid |
| bare sink + `map()` | 180 | 0 | 180/180 mapped |

Call chain at the first warning (backtrace):
`toImage()` → `qImageFromVideoFrame()` → `QVideoTextureHelper::createTextures()` →
`AVFVideoBuffer::textureHandle(QRhi&, int)` → the warning. Qt tries a zero-copy Metal
texture first; a render-less sink (`rhi() == nullptr`) has no Metal texture cache; the
attempt fails once per plane. **Qt then uploads the planes and converts on the GPU**
(result format `RGBA8888_Premultiplied`), and the image is correct. 30 fps × 2 planes
= 60/s: the 22 Sep flood rate.

## The image is correct — measured against ground truth

SMPTE HD bars, encoded BT.709 limited range, centre of each 75% bar:

| bar | source (truth) | `toImage()` (today) | Qt CPU converter (`forceCpu`) |
|---|---|---|---|
| gray | 191,191,191 | 189,192,191 | 189,191,191 |
| yellow | 189,202,7 | 189,202,6 | 188,**216**,14 |
| cyan | 15,223,5 | 14,223,5 | **30,255**,12 |
| magenta | 176,0,186 | 174,0,183 | **160**,0,177 |
| red | 175,0,2 | 174,0,1 | **159**,0,3 |
| blue | 1,0,183 | 0,0,182 | 2,0,**174** |
| gray | 102,102,102 | 100,102,101 | 100,101,101 |

`toImage()` is within ±3 levels everywhere. Over 41.5 M sampled pixels of a moving test
pattern the two paths differ by p50 24 / p99 57 / max 197 levels.

**Rejected fix — do not reintroduce:** the private `qImageFromVideoFrame(frame, forceCpu=true)`
silences the warning but Qt 6.11.1's CPU path gets BT.709 wrong (grays right, saturated
colours off by up to 32 levels, cyan's green clipping at 255 — BT.601 coefficients on
BT.709 content). It would have shifted the colour of every harvested still. Timing
was no argument either: 4.44 ms/frame (`toImage`) vs 5.01 ms (`forceCpu`).

## What shipped

`src/models/MetalCacheProbe.{h,cpp}` — a message handler in FRONT of the flight recorder's:

- **Proven-benign producer → counted, not printed.** `FrameCache::onHarvestFrame` wraps
  `captureFrame()` in `MetalCacheProbe::ExpectedScope`. Warnings raised inside it (same
  thread, synchronously inside `toImage()`) become one `[MTLCACHE] expected episode #N
  STARTED` line and one `ENDED: n=… over … s (…/s)` line.
- **Anything else → self-diagnosing.** The first warning of each episode logs
  `[MTLCACHE] UNEXPECTED …` with the emitting thread, a C++ backtrace (whose frames
  above `QVideoFrame::toImage` / `QSGVideoNode` name the producer: `FrameCache::onFrame`,
  `MotionScan::onFrame`, the scene graph, a `grabToImage`…) and every registered sink —
  FrameCache playback, FrameCache harvest, MotionScan, FrameClock — with its `rhi()`:
  `NULL (no Metal texture cache)` is the precondition. The original line still reaches
  the recorder; `ENDED` gives the episode's count and rate.
- `[MTLCACHE] probe armed` at every launch proves the build carries it.

Verified in the harness against the repo's own `MetalCacheProbe.cpp`: scoped → 0 of 360
lines reach the recorder, 3 `[MTLCACHE]` lines; unscoped → all 360 pass, 41 lines
(armed + header + backtrace + sink state + ENDED). Deployed 2026-09-25 12:38 (pid 48835).

## Next occurrence — how to read it

`grep MTLCACHE ~/Library/Application\ Support/Cilex\ Vision/Watchtower/flightrec/watchtower.log*`

- only `expected` episodes → the harvester ran; benign; nothing to do.
- an `UNEXPECTED` block → read the backtrace frames below `QVideoFrame::toImage` (or the
  scene-graph frames if there is no `toImage`): that is the producer. The sink list says
  which sink had no Metal cache. If it is `FrameCache playback` with `rhi=NULL`, the
  2026-08-22 hide guard missed a path; if it is `MotionScan`, its `map()` failed and it
  fell back to `toImage()` (it logs `[MSCAN] frame map failed`).
