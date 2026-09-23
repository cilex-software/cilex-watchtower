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

## MOG2 IS NOW MEASURED — and it is the whole budget

Measured later the same evening, once the operator authorised starting A4-A6 and OpenCV
went on this box. `tools/labs/measure_cost.py`, cv2 5.0.0 pinned to one thread, 5 minutes
of continuous single-camera `-sub` per row, n=3, **decode and frame delivery excluded** by
a drain pass (ffmpeg runs in a subprocess, so `process_time()` omits it by construction).

    MOG2 + morphology + connected components    ms/frame  CPU-s/30s  CPU-s/cam-h
    full rate    1280x720                         19.68      8.856       1036.1
    full rate     640x360                          4.36      1.960        229.3
    keyframe     1280x720  GOP 50                 17.34      0.156         18.3
    keyframe     1280x720  GOP 15                 19.67      0.590         69.1
    keyframe      640x360  GOP 50                  4.29      0.039          4.5

    in-process frame delivery, excluded above: 1.25 ms/frame at 720p

**Across 56 outside cameras for a day:**

    full rate, 1280x720                 386.8 CPU-hours/day
    keyframe only, 1280x720 GOP 50        6.8
    keyframe only, 1280x720 GOP 15       25.8
    keyframe only,  640x360 GOP 50        1.7

Three things follow, and the first reframes the whole exercise.

1. **cilex-vision's fear was right and its cause was wrong.** They worried A4-A6 might be
   unaffordable and priced *decode* to find out. Decode is ~0.1-0.4 CPU-s per segment and
   never mattered; MOG2 at full rate is **1,036 CPU-s/camera-hour, about 6x the Linux box's
   entire full-decode figure of 167**. The unaffordability they sensed is real and lives one
   stage further on.

2. **Keyframe-only saves 50x here, not 3x.** Decode only saves ~3x by skipping frames,
   because the frames it keeps are the expensive I-frames. MOG2 has no such asymmetry — it
   is linear in frames — so the saving is the whole frame-count ratio: 52.9x at GOP 50,
   16.0x at GOP 15. **The keyframe-vs-full decision is an algorithm decision, and it is a
   far bigger lever than the decode analysis suggested.**

3. **The GOP spread becomes a budget spread.** On the keyframe path a 720p GOP 15 camera
   costs 69.1 CPU-s/camera-hour against 18.3 for GOP 50 — **3.8x, at identical resolution**,
   because it emits 3.3x more keyframes. A single `cost_cpu_s_per_camera_hour` per analyser
   cannot represent this fleet.

Observation rate was comparable between the two decode rates on the same camera (8.1% of
frames at full rate against 8.3% keyframe-only on one camera; 4.9% against 5.5% on another),
which is consistent with cilex-vision's own convergence result.

Bandwidth corroborates the keyframe asymmetry independently: 5 minutes of 720p GOP 15 is
**51.5 MB** against **8.3 MB** for 720p GOP 50 — 6.2x, same resolution, same duration.

## Conditions for the MOG2 figures

- OpenCV installed into an isolated venv at `C:\wt\labs-venv`, **not** the station's Python.
- **Smart App Control blocks `numpy.random._philox`** while permitting numpy and cv2
  themselves — its verdict is per file hash, so a dependency is not simply allowed or
  denied. Nothing in the analyser or its tests uses `numpy.random`.
- The guard wall was live throughout (pid 3580, 35 live pipelines); the flight recorder
  shows no `SLOW`, no error and no reconnect across all of it.
- `concat20.ts` is unsuitable for this measurement and was discarded: it alternates two
  cameras, so a full scene change every 30 s makes the whole frame foreground. Correct
  behaviour, worthless as a cost figure — hence 5 minutes of one camera per row.
