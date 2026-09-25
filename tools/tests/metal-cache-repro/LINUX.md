# Running this harness on Linux — UNTESTED, recorded so the controls are not lost

**Status 2026-09-25: never run on Linux.** Recipe from the macOS agent, who wrote the
harness and measured Qt 6.11.1 on macOS/Metal. Queued behind the Labs worker on the
pilot host. Nothing below is a result.

## The question it answers

Does `QVideoFrame::toImage()` on this box fall back to Qt's **private CPU converter**,
and if so, is that converter right for BT.709? On macOS 6.11.1 the forced-CPU path
(`qImageFromVideoFrame(frame, /*forceCpu*/ true)`) was **up to 32 levels off** on
saturated colours (red 175→159, cyan 15,223→30,255) while `toImage()` took a GPU path
within ±3 of truth. This codebase calls `toImage()` (FrameCache.cpp:182,
MotionScan.cpp:209), never the forced path — so the open question is only whether
`toImage()` itself falls back to it here.

## Measured on the pilot host (not a result, a precondition)

- Qt **6.12.0** at `~/Qt/6.12.0/gcc_64`
- the header the harness includes (`repro.cpp:15`, `<private/qvideoframeconverter_p.h>`)
  is **present**, and it declares `qImageFromVideoFrame` twice:
  ```
  :24  QImage qImageFromVideoFrame(const QVideoFrame &frame,
                                   const VideoTransformation &transformation, ...
  :28  QImage qImageFromVideoFrame(const QVideoFrame &frame, bool forceCpu = false);
  ```
  **So the 2-argument `forceCpu` overload survived into 6.12**, and the harness's
  `qImageFromVideoFrame(f, true)` matches it. No signature adaptation expected.

> **CORRECTED 2026-09-25, same day.** The first version of this section named
> `qvideoframeconversionhelper_p.h` as the precondition and I told the macOS agent
> "the build won't be the blocker". That was the wrong file: it is the conversion
> HELPER, and it declares `qImageFromVideoFrame` **zero** times. The macOS agent
> caught it by reading `repro.cpp:15` rather than trusting my summary. The conclusion
> happened to be right — the correct header is also present — but it was right for a
> reason I had not checked, which is the thing this repo keeps having to relearn.
> I verified *a* header and reported it as *the* header.

## CONTROLS — read before interpreting any number

**This box and the Mac differ in Qt version, pixel format, OS, multimedia backend AND
GPU at once, so a straight comparison between them attributes NOTHING.** Vary one thing
at a time:

| to isolate | hold constant | vary |
|---|---|---|
| pixel format | the Qt version | NV12 vs yuv420p |
| Qt version | the pixel format | 6.11.1 vs 6.12 |

**Record the Qt version and the frame's `pixelFormat` next to every number.** The
harness prints `pixelFormat` on its first-frame line.

It cuts both ways, and neither direction is free to read:
- a **correct** forceCpu column here may mean 6.12 fixed the converter — a *version*
  result that says nothing about whether 6.11.1 was wrong. The Mac's 6.11.1 numbers
  stand as measured.
- the pilot's wall uses **software decode by default** (since the 2026-09-08 soak), so
  frames may arrive as **yuv420p**, which the Mac never measured (NV12 only). A
  different result is format-suspect before it is Qt-suspect.

**`frames=0` means there is NO result** — the platform delivered nothing. On macOS
`-platform offscreen` delivered zero frames with the darwin backend. Try the FFmpeg
backend offscreen first, then `xvfb-run`, and record which one delivered frames.

**It is private API.** `_p.h` signatures may change between minor versions. If the
2-argument `qImageFromVideoFrame(frame, forceCpu)` overload is gone in 6.12, the
3-argument one takes a `VideoTransformation` — that is the harness needing adaptation,
**not a result**. Report it; do not work around it silently.

The harness exits **3 on an unknown MODE**, so a stale binary cannot pass itself off as
a result.

## Recipe (macOS agent's, adapted: h264_videotoolbox is macOS-only, so libx264)

```sh
cmake -S tools/tests/metal-cache-repro -B /tmp/mcr -G Ninja && cmake --build /tmp/mcr

ffmpeg -f lavfi -i smptehdbars=size=1280x720 -frames:v 1 src.png
ffmpeg -f lavfi -i smptehdbars=size=1280x720:rate=30 -t 3 -c:v libx264 -b:v 8M \
       -pix_fmt yuv420p -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
       -color_range tv bars.mp4
ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30 -t 6 -c:v libx264 -b:v 2M \
       -pix_fmt yuv420p clip.mp4

# in the directory holding src.png
BARS=1 MODE=compare /tmp/mcr/repro bars.mp4   # bar centres: SOURCE vs toImage() vs forceCpu
MODE=compare /tmp/mcr/repro clip.mp4          # diff histogram toImage vs forceCpu, ms/frame
```

## Reading it

- **compare histogram near 0** → this box's `toImage()` IS the CPU path. Then the bars
  say whether that path is right for BT.709 — and that would be a live correctness
  question for FrameCache and MotionScan.
- **histogram large** (Mac: p50 24, max 197) → `toImage()` takes a GPU path, only the
  forceCpu column differs, and nothing here calls forceCpu.
