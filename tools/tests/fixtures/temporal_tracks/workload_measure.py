#!/usr/bin/env python3
"""Declared streaming resource workload (contract section 13), measured.

Runs BOTH independent default-config trackers in ONE process, sequentially,
generating every batch on demand, feeding it, and draining-discarding output
immediately. At n=0 and each n divisible by 1000 it serialises a snapshot to
canonical UTF-8 JSON, checks the 2 MiB bound, and discards it. Input
generation, feed, drain, sampled serialisation, finish and the final drain are
all inside the measured interval.

    python3 tools/tests/fixtures/temporal_tracks/workload_measure.py

Prints one JSON object: wall seconds per stream, peak RSS and its growth over
the post-import baseline, detections assigned, births, aggregate observations,
the largest snapshot, and the validator's own pass/fail. This harness keeps no
stream and no episode archive -- only counters.

Contract limits: both streams together within 180 s on one isolated CPU and
within 128 MiB of added peak RSS. Local numbers on a shared host are
diagnostic, not a controlled score.
"""
from __future__ import annotations

import json
import os
import pathlib
import resource
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "tools" / "labs"))

import temporal_tracks as TT          # noqa: E402

SNAP_LIMIT = 2097152
STREAMS = (("resource-a", 100000, 8), ("resource-b", 250, 32))


def batch(camera_id, n, width):
    dets = []
    for j in range(width):
        if width == 8:
            c, r = j % 4, j // 4
            q = n % 1000
            u = (q / 250.0 - 1.0) if q < 500 else (3.0 - q / 250.0)
            cx, cy = 0.12 + 0.25 * c + 0.02 * u, 0.25 + 0.50 * r
            w = h = 0.04
        else:
            c, r = j % 8, j // 8
            q = n % 50
            u = (q / 12.5 - 1.0) if q < 25 else (3.0 - q / 12.5)
            cx, cy = (c + 0.5) / 8 + 0.005 * u, (r + 0.5) / 4
            w = h = 0.02
        dets.append({"id": "d%d" % j, "bbox": [cx - w / 2, cy - h / 2, w, h]})
    return {"camera_id": camera_id, "unit_id": "resource", "seq": n,
            "t_ms": 200 * n, "detections": dets}


def peak_bytes():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024


def main():
    baseline = peak_bytes()
    report = {"baseline_rss": baseline, "streams": [], "ok": True,
              "problems": [], "python": sys.version.split()[0]}
    for camera_id, count, width in STREAMS:
        tr = TT.Tracker(camera_id, "resource")
        assigned = 0
        births = 0
        observed = 0
        biggest = 0
        t0 = time.perf_counter()
        for n in range(count):
            receipt = tr.feed(batch(camera_id, n, width))
            if len(receipt["assignments"]) != width:
                report["ok"] = False
                report["problems"].append("%s n=%d assigned %d/%d"
                                          % (camera_id, n,
                                             len(receipt["assignments"]), width))
            for a in receipt["assignments"]:
                if a["status"] == "ambiguous":
                    report["ok"] = False
                    report["problems"].append("%s n=%d ambiguous" % (camera_id, n))
                elif a["status"] == "born":
                    births += 1
            assigned += len(receipt["assignments"])
            for ep in tr.drain():
                observed += ep["observations"]
            if n == 0 or n % 1000 == 0:
                blob = json.dumps(tr.snapshot(), sort_keys=True,
                                  separators=(",", ":"), ensure_ascii=True,
                                  allow_nan=False).encode("utf-8")
                biggest = max(biggest, len(blob))
                if len(blob) > SNAP_LIMIT:
                    report["ok"] = False
                    report["problems"].append("%s n=%d snapshot %d bytes"
                                              % (camera_id, n, len(blob)))
        ids = tr.finish()
        episodes = tr.drain()
        observed += sum(e["observations"] for e in episodes)
        elapsed = time.perf_counter() - t0
        if sorted(ids) != sorted(e["track_id"] for e in episodes):
            report["ok"] = False
            report["problems"].append("%s finish ids disagree" % camera_id)
        if observed != assigned or assigned != count * width:
            report["ok"] = False
            report["problems"].append("%s observed %d, assigned %d, expected %d"
                                      % (camera_id, observed, assigned,
                                         count * width))
        report["streams"].append({"camera_id": camera_id, "batches": count,
                                  "detections": assigned, "seconds": elapsed,
                                  "births": births, "observations": observed,
                                  "episodes": len(episodes),
                                  "max_snapshot_bytes": biggest})
    report["total_seconds"] = sum(s["seconds"] for s in report["streams"])
    report["peak_rss"] = peak_bytes()
    report["added_peak_rss"] = report["peak_rss"] - baseline
    report["limits"] = {"seconds": 180, "added_bytes": 128 * 1024 * 1024,
                        "snapshot_bytes": SNAP_LIMIT}
    report["within_limits"] = (report["ok"]
                               and report["total_seconds"] <= 180
                               and report["added_peak_rss"] <= 128 * 1024 * 1024)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["within_limits"] else 1


if __name__ == "__main__":
    sys.exit(main())
