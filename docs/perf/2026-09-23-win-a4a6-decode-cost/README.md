# A4-A6 decode cost and fleet keyframe distribution — method

Measured 2026-09-23 on **wt-sm-vnutri-01** (guard booth, Win 11, i5-12400 6C/12T @ 2.5 GHz
base), ffmpeg **N-126168** from the v1.1.44 install tree
(`%LOCALAPPDATA%\Programs\Cilex Watchtower.v1144\ffmpeg.exe` — the current dist does not
ship an ffmpeg CLI).

Answers CV's question in
`docs/letters/2026-09-23-a4-a6-the-shape-layer-and-the-decode-cost-nobody-has-priced.md`.
Results are in the `.reply-cilex-watchtower-windows.md` beside it.

## Conditions

- **Software decode only.** No `-hwaccel` anywhere: the shared Intel iGPU wedges ~20 s at
  ~16 concurrent VA-API contexts, and it is a creation-rate failure.
- **`-threads 1`** for every cost figure. `-threads auto` spends 52% more CPU for 1.4× less
  wall time (4.36 vs 2.88 CPU-s for the same work) — wrong trade on a station sharing a CPU
  with a guard wall.
- **CPU time, not wall time**: `Process.TotalProcessorTime` (user+kernel) of the child.
  `Process.StartTime`/`ExitTime` proved unreliable here — use a `Stopwatch` for wall.
- **The guard wall was LIVE throughout** (pid 3580, 16 tiles). The flight recorder shows no
  `SLOW`, no error and no reconnect across every run below.
- Segments are real `-sub` captured by **stream copy** from go2rtc — no transcode, no
  re-encode, no writes to CV, no lease. `-fflags +discardcorrupt` kept.
- Medians of n=5 to n=9, spread reported.

## Scripts, in order

| script | what it establishes |
|---|---|
| `capture-segments.ps1` | captures 30 s `-sub` segments by stream copy |
| `bench-decode.ps1` | per-spawn cost, frame and keyframe census |
| `bench2.ps1` | amortised cost through ONE long-lived decoder over 20 segments |
| `bench3.ps1` | decomposition: parse floor, per-I-frame, per-P/B-frame |
| `gop-profile.ps1` | are I-frame intervals fixed or scene-dependent? (fixed) |
| `gop-dist.ps1` | keyframe interval × resolution across 24 of 130 cameras |
| `bench-convert.ps1`, `bench-gray.ps1` | conversion/delivery cost vs raw decode |

## CORRECTION 2026-09-23, later the same evening — these are 640x360, not 1280x720

**Every CPU figure below was measured on 640x360 footage and first published labelled
1280x720.** The numbers are correct; the resolution attached to them was not, and
640x360 is a quarter of the pixels.

How it happened: the first thing probed this session was a Watchtower mp4 **export**,
which genuinely is 1280x720. The benchmark segments were then captured separately from
go2rtc and never re-probed — the 720p reading was carried across from a different file.
It surfaced only when the analyser's own probe printed the resolution per segment and
disagreed with this document.

**What survives unchanged**, because they are ratios measured within one file:

* `format=gray` costing 1.72x `format=bgr24`, and plane-0 slicing beating both.
* full-vs-keyframe ratios (3.09x at GOP 50, 1.72x at GOP 15).
* an I-frame costing 17.9x a P/B-frame.
* the GOP and resolution distribution in §3 — an independent measurement that reads
  dimensions per camera, and the thing that eventually caught this.

**What does not**: every absolute CPU-s figure is a 640x360 figure. Scaled by pixel
count, 1280x720 is roughly 4x each of them.

**And one inference is withdrawn.** The reply letter reasoned from a 9.5x gap between
"my 17.5 CPU-s/cam-h" and the Linux box's 167 for the same stream, and attributed the
remainder to their Python layer. Matched for resolution the gap is ~2.4x, which is
ordinary CPU difference between two machines. There was no large unexplained gap and
I should not have drawn a conclusion about somebody else's measurement from one I had
mislabelled.

## Headline results — all on 640x360 h264 `-sub` unless stated

    demux + parse floor     0.0078 CPU-s per 30 s segment
    per I-frame             2.64 ms
    per P/B-frame           0.15 ms      (an I-frame costs 17.9x a P-frame)

    640x360, per 30 s segment:    GOP 50 -> keyonly 0.032  full 0.098  (3.09x)
                                  GOP 15 -> keyonly 0.087  full 0.150  (1.72x)

    decode only                        17.5 CPU-s/cam-h
    + bgr24 (OpenCV input)             27.3
    + gray via swscale                 47.0   <- a PESSIMISATION vs bgr24
    native yuv420p, delivered          31.3   <- correct route to luma: slice plane 0
    bgr24, delivered                   54.6

    fleet keyframe interval: GOP 50 (3.31 s) x12 · GOP 15 (0.99 s) x9 · GOP 50+adj x3
    -sub resolutions:        640x360 x11 · 1280x720 x9 · 640x480 x4  (4:3, third value)
    frame rate:              15.1 fps on all 24 sampled

## Three traps worth keeping

1. **Sampling.** The first two cameras measured were both GOP 15 and gave a clean
   zero-variance answer that was unrepresentative of the fleet. Keyframe interval is a
   per-camera setting; n=2 is not a fleet measurement.
2. **`-vf format=gray` is slower than `format=bgr24`** on this build. swscale has SIMD for
   yuv420p→bgr24 and appears to fall back to generic C for yuv420p→gray. Take the Y plane
   off the native yuv420p frame instead — it needs no conversion at all.
3. **Probe the file you are measuring, every time.** A resolution inherited from an
   adjacent file is an assumption wearing a measurement's clothes, and it survived four
   scripts and two letters here because nothing in the benchmark path ever printed
   `width x height`. Anything reporting a cost should print the dimensions it measured
   beside it — `measure_cost.py` does.

## Windows gotchas that cost time here

- ffmpeg's **concat demuxer cannot read a list file containing this box's Cyrillic profile
  path** under any PS 5.1 encoding. Work from an ASCII-only directory (`C:\wt\labs-bench`).
- PowerShell 5.1 reads a **BOM-less `.ps1` as ANSI**, so a literal non-ASCII path inside a
  script written as UTF-8 becomes mojibake. Use `$env:LOCALAPPDATA` etc., never a literal
  user path.
- `C:\wt\pb-app\ffmpeg.exe` and `C:\wt\pb2\ffmpeg.exe` exit `0xC0000135` (DLL not found) —
  they lack `avcodec-63`/`avfilter-12`. Only the v1.1.44 tree has a complete set.
- PowerShell format strings use `{0,10}`, not `{0,>10}`; the latter throws at runtime.

## Not measured

**MOG2 itself**, which is the term that decides the budget — likely 2-7 CPU-s per segment,
an order of magnitude above the entire decode line. OpenCV is not installed here, and
installing unsigned `cv2` binaries on a Smart-App-Control-enforced station running the live
wall is an operator decision, not a detail.
