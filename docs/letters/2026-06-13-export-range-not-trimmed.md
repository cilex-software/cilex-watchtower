# Single-camera exports ignore the requested range — whole segments, no trim

**To:** Cilex Vision
**From:** Cilex Watchtower (operator client)
**Date:** 2026-06-13
**Severity:** HIGH for evidentiary use — every exported clip is longer than requested and starts before the requested instant. Performance is fine; this is correctness.

---

## Evidence (camera `hiwatch-083bc14effc1`, measured 2026-06-13 ~00:40 +03)

| requested window | file duration | = source segments |
|---|---|---|
| **5 s** (hot) | **27.94 s** | 1 whole segment |
| **35 s** (hot, ~1 h ago) | **61.25 s** | 2 whole segments |
| **60 s** (warm, 06-06 sub era) | **89.80 s** | 3 whole segments (3 × 29.93) |

The pattern is exact: the output is the **concatenation of every ~30 s source
segment overlapping the window** — `wall_start`/`wall_end` are never applied as
in/out points. The smoking gun is the 5 s request returning 27.9 s.

Everything else about these jobs looked right: `resolution` honest
(2560×1440 hot / 1280×720 warm — prefer-main works), h264 output, sub-second
create, fast processing (below), instant token download. The earlier wall-time
doubling is gone — these are clean single-stream outputs, just untrimmed.

## Repro

```bash
# any 5s window inside recorded footage:
POST /review/exports {"camera_id":"hiwatch-083bc14effc1",
  "wall_start":"2026-06-12T19:38:20Z","wall_end":"2026-06-12T19:38:25Z",
  "mode":"wallclock"}
# → ready in ~3s → download → ffprobe duration = 27.94s (expected ≈5s)
```

## Why it matters

The operator picks an exact In→Out on the timeline (our drawer shows
HH:MM:SS.mmm); the job echoes those timestamps back in its status; the file then
contains up to ~30 s of *extra* footage before the In point and after the Out.
For incident clips that's wrong footage in the file — and for chain-of-custody
use, the file doesn't match its declared range.

## Proposed fix (small, in your existing pipeline)

You already run every export through the cross-epoch **re-encode** — trimming is
nearly free there:

1. Compute `in_off = wall_start − first_segment.start` and
   `out_off = wall_end − first_segment.start` on the concat timeline (you have
   exact per-segment wall times in the DB).
2. Apply them to the existing ffmpeg invocation: either input seek on the concat
   (`-ss in_off` before `-i`, `-t (wall_end−wall_start)`) or output trim
   (`-ss/-t` after inputs; you're re-encoding, so it's frame-accurate either
   way — no keyframe snapping caveats).
3. `compact` mode: same, applied after gap-dropping on the compact timeline.

Expected after fix: duration == requested ±1 frame; first frame at
`wall_start`. Our acceptance check (we'll re-run on your ping): the three rows
above return ≈5.0 s / ≈35.0 s / ≈60.0 s.

## For completeness — the perf numbers (all PASS, no action needed)

| case | create | ready | download |
|---|---|---|---|
| hot 35 s (1440p) | 0.02 s | **14.4 s** | 22.1 MB in 0.10 s |
| warm 60 s (720p) | 0.01 s | **6.1 s** | 19.2 MB in 0.12 s |
| hot 5 s | — | **~3 s** | 2.1 MB instant |

— Watchtower
