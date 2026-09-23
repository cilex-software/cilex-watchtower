#!/usr/bin/env python3
"""Measure the A4-A6 analyser's cost per camera-hour, on real footage.

THIS IS THE NUMBER cilex-vision's BUDGET PAGE SHOWS `null` FOR, deliberately,
because "a guess stored beside a measurement is indistinguishable from one".
`foreground_mask` and `blob_geometry` both read cost_cpu_s_per_camera_hour: null
on GET /labs/analyzers today.

WHY IT MATTERS MORE THAN THE DECODE FIGURE. Decode was priced on this booth at
~0.098 CPU-s per 30 s segment and delivery at ~0.26, which turned out to be a
minority of the real cost. cilex-vision's own shipped analyser corroborates it
from the other direction: `frame_difference` measures 96.8 CPU-s per camera-hour
while keyframe decode for those 117 segments is only ~3.7, so ~96% of a live
analyser's cost is not decode. The background model is the term that decides
affordability, and nobody had measured it.

METHOD, and the split that makes the answer useful:
  * `time.process_time()` brackets the analyser loop, so it counts MOG2, the
    morphology, connected components and numpy IN THIS PROCESS ONLY.
  * ffmpeg decodes in a SUBPROCESS, so its CPU is deliberately NOT in that number.
    Decode is already measured separately (docs/perf/2026-09-23-win-a4a6-decode-cost)
    and reporting them mixed is how the 15x guess happened in the first place.
  * cv2.setNumThreads(1) -- the guard wall shares this CPU. Also makes CPU-seconds
    and wall-seconds comparable rather than a threading artefact.
  * Segments per camera-hour: 117, cilex-vision's measured figure over 1,680
    camera-hours. Not 120: coverage is 3,505 s of 3,600.

Run:  C:\\wt\\labs-venv\\Scripts\\python.exe tools/labs/measure_cost.py <dir-of-ts> [...]
"""

from __future__ import annotations

import os
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cv2

import frame_source as fs
from shape_observations import AnalyserState, Config, SegmentMeta, analyse_segment

SEGMENTS_PER_CAMERA_HOUR = 117  # cilex-vision, measured over 1,680 camera-hours
REPEATS = 3


def measure(path: str, ff: str, keyframes_only: bool):
    """Two passes, so MOG2 is isolated from the cost of merely handing frames over.

    Frames are STREAMED, never collected: a 5-minute 1280x720 window is ~4,500
    frames of luma and materialising it costs gigabytes on a guard station.
    ffmpeg decodes in a subprocess, so `process_time()` excludes it by construction.
    """
    pr = fs.probe(path, ff, measure_gop=True)
    drain_s, total_s, wall_s = [], [], []
    nframes = nobs = 0
    notes: list[str] = []
    duration_s = None

    for _ in range(REPEATS):
        # pass 1 -- drain only: pipe reads + frombuffer, i.e. in-process delivery
        c0 = time.process_time()
        n = 0
        for _f in fs.iter_frames(path, ffmpeg=ff, keyframes_only=keyframes_only, pr=pr):
            n += 1
        drain_s.append(time.process_time() - c0)

        # pass 2 -- delivery + the analyser
        state = AnalyserState(Config())
        meta = SegmentMeta(
            segment_id=os.path.basename(path),
            camera_id=os.path.basename(path).split(".")[0],
        )
        c0, w0 = time.process_time(), time.perf_counter()
        obs, st = analyse_segment(
            fs.iter_frames(path, ffmpeg=ff, keyframes_only=keyframes_only, pr=pr),
            meta, state,
        )
        total_s.append(time.process_time() - c0)
        wall_s.append(time.perf_counter() - w0)
        nframes, nobs, notes = st.frames_seen, len(obs), st.notes
        if pr.fps and n:
            duration_s = (n * (pr.keyframe_gop or 1) if keyframes_only else n) / pr.fps

    med_total = statistics.median(total_s)
    med_drain = statistics.median(drain_s)
    med_mog2 = max(0.0, med_total - med_drain)
    # Normalise to a 30 s segment: captures are not all 30 s, and 4-second
    # motion-triggered segments exist in the corpus too.
    per30 = (med_mog2 / duration_s * 30.0) if duration_s else med_mog2
    return {
        "res": f"{pr.width}x{pr.height}",
        "codec": pr.codec or "unknown",
        "gop": pr.keyframe_gop,
        "frames": nframes,
        "obs": nobs,
        "dur": duration_s,
        "drain": med_drain,
        "mog2": med_mog2,
        "per_frame_ms": (med_mog2 / nframes * 1000.0) if nframes else 0.0,
        "per30": per30,
        "cam_h": per30 * SEGMENTS_PER_CAMERA_HOUR,
        "notes": notes,
    }


def main(argv: list[str]) -> int:
    cv2.setNumThreads(1)
    ff = fs.find_ffmpeg()
    print(f"ffmpeg: {ff}")
    print(f"cv2 {cv2.__version__}, threads pinned to {cv2.getNumThreads()}")
    print(f"repeats={REPEATS}, segments/camera-hour={SEGMENTS_PER_CAMERA_HOUR} (CV measured)")
    print()

    paths = []
    for a in argv:
        if os.path.isdir(a):
            paths += [
                os.path.join(a, f)
                for f in sorted(os.listdir(a))
                if f.endswith(".ts") and os.path.getsize(os.path.join(a, f)) > 100_000
            ]
        elif a.endswith(".ts"):
            paths.append(a)
    if not paths:
        print("no .ts segments given")
        return 2

    # Resolution is printed beside every cost ON PURPOSE. This document's numbers
    # were once published labelled 1280x720 when the footage was 640x360, because
    # nothing in the benchmark path ever printed the dimensions it measured.
    hdr = (f"{'segment':<22} {'res':>10} {'GOP':>4} {'frames':>7} {'obs':>6} "
           f"{'ms/frame':>9} {'CPU-s/30s':>10} {'CPU-s/cam-h':>12}")
    for mode, keyonly in (("FULL RATE", False), ("KEYFRAME ONLY", True)):
        print(f"=== {mode} — MOG2 + blobs only, decode and delivery excluded ===")
        print(hdr)
        rows = []
        for p in paths:
            try:
                r = measure(p, ff, keyonly)
            except Exception as e:                      # noqa: BLE001
                print(f"{os.path.basename(p):<22} ERROR {type(e).__name__}: {e}")
                continue
            rows.append(r)
            print(f"{os.path.basename(p):<22} {r['res']:>10} {str(r['gop']):>4} "
                  f"{r['frames']:>7} {r['obs']:>6} {r['per_frame_ms']:>9.2f} "
                  f"{r['per30']:>10.3f} {r['cam_h']:>12.1f}")
        if rows:
            by_res: dict[str, list[dict]] = {}
            for r in rows:
                by_res.setdefault(r["res"], []).append(r)
            print("  -- per resolution --")
            for res, rs in sorted(by_res.items()):
                med = statistics.median([r["per30"] for r in rs])
                mf = statistics.median([r["per_frame_ms"] for r in rs])
                dr = statistics.median([r["drain"] for r in rs])
                print(f"     {res:>10}  n={len(rs):<3} {mf:6.2f} ms/frame  "
                      f"{med:6.3f} CPU-s per 30 s segment  -> {med * SEGMENTS_PER_CAMERA_HOUR:7.1f} "
                      f"CPU-s/camera-hour   (in-process delivery, excluded: {dr:.3f} s)")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
