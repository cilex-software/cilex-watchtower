#!/usr/bin/env python3
"""Peak summed-RSS sampler for a whole process tree (Stage 4 memory control C14).

The V1 deployment budget is stated for the WHOLE analyser helper and its
descendants, decoder included, so measuring only the Python process would be the
wrong number. This samples every descendant's RSS on a fixed interval, keeps the
per-process maximum, and reports the peak of their SUM (which is what a
process-tree budget means).

    mem_probe.py --interval 0.05 --out /tmp/mem.json -- python3 tools/labs/stage4_analyse.py ...

Sampling cannot see a spike between two samples; the interval is recorded and the
limitation is reported rather than hidden. On Linux the cgroup memory high-water
(`memory.peak`) is also read before and after when the container exposes it.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
import time


def _proc_rss_pages(pid: int):
    try:
        with open("/proc/%d/statm" % pid) as fh:
            fields = fh.read().split()
        return int(fields[1])
    except (OSError, IndexError, ValueError):
        return None


def _children(pid: int):
    out = []
    try:
        with open("/proc/%d/task/%d/children" % (pid, pid)) as fh:
            out = [int(p) for p in fh.read().split()]
    except OSError:
        for task in pathlib.Path("/proc/%d/task" % pid).glob("*"):
            try:
                out.extend(int(p) for p in
                           (task / "children").read_text().split())
            except OSError:
                continue
    return out


def tree_rss(pid: int, page: int = 4096) -> dict:
    """RSS of pid and every descendant, in bytes."""
    seen, stack, per = set(), [pid], {}
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        pages = _proc_rss_pages(p)
        if pages is not None:
            per[p] = pages * page
        stack.extend(_children(p))
    return per


def cgroup_peak() -> int:
    for path in ("/sys/fs/cgroup/memory.peak", "/sys/fs/cgroup/memory/memory.max_usage_in_bytes"):
        try:
            return int(pathlib.Path(path).read_text().strip())
        except (OSError, ValueError):
            continue
    return None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=0.05)
    ap.add_argument("--out")
    ap.add_argument("--label", default="")
    ap.add_argument("command", nargs=argparse.REMAINDER)
    args = ap.parse_args(argv)
    command = args.command[1:] if args.command and args.command[0] == "--" else args.command
    if not command:
        print("no command given", file=sys.stderr)
        return 2

    before = cgroup_peak()
    started = time.time()
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True)
    peak_sum, peak_detail, samples = 0, {}, 0
    per_process_max = {}
    while proc.poll() is None:
        snapshot = tree_rss(proc.pid)
        if snapshot:
            total = sum(snapshot.values())
            for p, rss in snapshot.items():
                per_process_max[p] = max(per_process_max.get(p, 0), rss)
            if total > peak_sum:
                peak_sum = total
                peak_detail = dict(snapshot)
            samples += 1
        time.sleep(args.interval)
    stdout, stderr = proc.communicate()
    after = cgroup_peak()
    wall = time.time() - started
    result = {
        "label": args.label, "command": command, "exit_code": proc.returncode,
        "interval_s": args.interval, "samples": samples,
        "peak_tree_rss_bytes": peak_sum, "peak_tree_rss_mib": round(peak_sum / 1048576, 2),
        "peak_processes": peak_detail,
        "per_process_peak_rss_bytes": {str(k): v for k, v in per_process_max.items()},
        "cgroup_memory_peak_before": before, "cgroup_memory_peak_after": after,
        "cgroup_memory_peak_delta": (None if (before is None or after is None)
                                     else after - before),
        "wall_seconds": round(wall, 2),
        "sampling_limit": ("RSS is sampled, not instrumented: a spike shorter than "
                           "the interval can be missed"),
        "stdout_tail": stdout[-4000:], "stderr_tail": stderr[-4000:],
    }
    if args.out:
        pathlib.Path(args.out).write_text(json.dumps(result, indent=1, sort_keys=True))
    print(json.dumps({k: result[k] for k in
                      ("label", "exit_code", "samples", "peak_tree_rss_mib",
                       "wall_seconds", "cgroup_memory_peak_delta")}))
    return proc.returncode or 0


if __name__ == "__main__":
    sys.exit(main())
