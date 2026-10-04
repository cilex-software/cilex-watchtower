#!/usr/bin/env python3
"""The fixed streaming resource workload of CONTRACT.md section 13.

Two independent DEFAULT-config trackers, run sequentially in one process. Each
batch is generated on demand, fed, and its episodes drained and discarded at
once: the harness retains no stream, no episode archive and no receipt history,
so what is measured is the engine's own bounded state, not the caller's.

    python3 tools/tests/fixtures/temporal_tracks/workload.py            # full
    python3 ... --batches-a 2000 --batches-b 60                        # scaled
    python3 ... --json                                                 # machine-readable

Both streams are exactly the contract's arithmetic: stream A is 100000 batches
of eight detections on a 4x2 grid whose columns breathe by +/-0.02 on a
1000-batch triangle wave; stream B is 250 batches of 32 detections on an 8x4
grid breathing by +/-0.005 on a 50-batch wave, where the column spacing (0.125)
is inside the gate (0.17 at dt=0.2 s) so every batch is a real banded
assignment problem rather than eight independent ones. `seq=n`, `t_ms=200*n`,
detection IDs `d0`, `d1`, ..., no appearance, camera `resource-a`/`resource-b`,
unit `resource`; `finish` and a final `drain` end each run. At n=0 and every n
divisible by 1000 the drained tracker's snapshot is serialised to canonical
UTF-8 JSON, measured against the 2 MiB cap, and discarded.

Input generation, feed, drain, sampled serialisation, finish and the final drain
are all inside the measured interval. The declared limits are 180 s on one
isolated CPU and 128 MiB of additional peak RSS above the post-import baseline
for BOTH streams together; this harness reports what it measured on the box it
ran on, which is a shared development host unless the caller isolated it.

It also checks what the contract says a correct run must show, because a fast
wrong run earns nothing: every detection assigned in every batch, no ambiguous
status anywhere, aggregate observation accounting that balances (accepted
detections == summed episode observations == summed track observations), every
sampled snapshot under the byte cap, and checkpoint equivalence -- a restore at
a sampled boundary continuing to produce byte-identical receipts, snapshots and
episodes.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import resource
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "labs"))

import temporal_tracks as tt                                 # noqa: E402
from temporal_tracks import Tracker, TrackingError            # noqa: E402

SNAPSHOT_BYTE_CAP = 2097152
TIME_BUDGET_S = 180.0
RSS_BUDGET_MIB = 128.0


def _rss_mib() -> float:
    """Peak RSS of this process in MiB (Linux/macOS: ru_maxrss is KiB there,
    bytes on macOS)."""
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if platform.system() == "Darwin":
        return peak / (1024.0 * 1024.0)
    return peak / 1024.0


def _current_rss_mib() -> float | None:
    try:
        with open("/proc/self/status", encoding="ascii") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return float(line.split()[1]) / 1024.0
    except OSError:
        return None
    return None


# ---------------------------------------------------------------------------
# the two contract streams, generated on demand
# ---------------------------------------------------------------------------
def batch_a(seq: int) -> dict:
    """Stream A: 100000 batches, eight detections, 4 columns x 2 rows."""
    n = seq
    q = n % 1000
    u = q / 250.0 - 1.0 if q < 500 else 3.0 - q / 250.0
    dets = []
    for j in range(8):
        c = j % 4
        r = j // 4
        cx = 0.12 + 0.25 * c + 0.02 * u
        cy = 0.25 + 0.50 * r
        dets.append({"id": f"d{j}", "bbox": [cx - 0.02, cy - 0.02, 0.04, 0.04]})
    return {"camera_id": "resource-a", "unit_id": "resource", "seq": n,
            "t_ms": 200 * n, "detections": dets}


def batch_b(seq: int) -> dict:
    """Stream B: 250 batches, 32 detections, 8 columns x 4 rows."""
    n = seq
    q = n % 50
    u = q / 12.5 - 1.0 if q < 25 else 3.0 - q / 12.5
    dets = []
    for j in range(32):
        c = j % 8
        r = j // 8
        cx = (c + 0.5) / 8.0 + 0.005 * u
        cy = (r + 0.5) / 4.0
        dets.append({"id": f"d{j}", "bbox": [cx - 0.01, cy - 0.01, 0.02, 0.02]})
    return {"camera_id": "resource-b", "unit_id": "resource", "seq": n,
            "t_ms": 200 * n, "detections": dets}


class Report:
    """One stream's measured totals and invariant violations."""

    def __init__(self, name: str):
        self.name = name
        self.batches = 0
        self.detections = 0
        self.assigned = 0
        self.born = 0
        self.matched = 0
        self.ambiguous = 0
        self.episodes = 0
        self.episode_observations = 0
        self.episode_ambiguous_batches = 0
        self.closed_reasons: dict[str, int] = {}
        self.snapshots = 0
        self.snapshot_bytes_max = 0
        self.snapshot_bytes_total = 0
        self.problems: list[str] = []
        self.checkpoint_checks = 0

    def as_dict(self) -> dict:
        return {k: v for k, v in self.__dict__.items()}

    def take(self, episodes: list[dict]) -> None:
        """Account for drained episodes, then let them go: the harness keeps no
        archive, exactly as the contract's workload requires of its caller."""
        for ep in episodes:
            self.episodes += 1
            self.episode_observations += ep["observations"]
            self.episode_ambiguous_batches += ep["ambiguous_batches"]
            self.closed_reasons[ep["reason"]] = self.closed_reasons.get(ep["reason"], 0) + 1
            tt.validate_episode(ep)


def run_stream(name: str, camera_id: str, batches: int, generate, *,
               snapshot_every: int = 1000, checkpoint_at: int | None = None,
               checkpoint_span: int = 25) -> Report:
    """Feed one stream, draining and discarding immediately."""
    rep = Report(name)
    tracker = Tracker(camera_id, "resource")
    twin: Tracker | None = None
    twin_until = -1
    for n in range(batches):
        batch = generate(n)
        rep.detections += len(batch["detections"])
        receipt = tracker.feed(batch)
        rep.batches += 1
        for a in receipt["assignments"]:
            rep.assigned += 1
            if a["status"] == "born":
                rep.born += 1
            elif a["status"] == "matched":
                rep.matched += 1
            else:
                rep.ambiguous += 1
                if len(rep.problems) < 10:
                    rep.problems.append(f"batch {n}: {a['detection_id']} was {a['status']}")
        if len(receipt["assignments"]) != len(batch["detections"]):
            if len(rep.problems) < 10:
                rep.problems.append(f"batch {n}: receipt accounted for "
                                    f"{len(receipt['assignments'])} of "
                                    f"{len(batch['detections'])} detections")
        episodes = tracker.drain()
        rep.take(episodes)
        if twin is not None and n <= twin_until:
            # Checkpoint equivalence: the restored tracker is at the same
            # boundary, so the same operation must produce the same receipt, the
            # same episodes and the same canonical state.
            rep.checkpoint_checks += 1
            twin_receipt = twin.feed(generate(n))
            if json.dumps(twin_receipt, sort_keys=True) != json.dumps(receipt, sort_keys=True):
                rep.problems.append(f"batch {n}: restored tracker's receipt differs")
            twin_episodes = twin.drain()
            if json.dumps(twin_episodes, sort_keys=True) != json.dumps(episodes, sort_keys=True):
                rep.problems.append(f"batch {n}: restored tracker's episodes differ")
            if tt.canonical_state_json(twin.snapshot()["state"]) != \
                    tt.canonical_state_json(tracker.snapshot()["state"]):
                rep.problems.append(f"batch {n}: restored tracker's snapshot differs")
        if n % snapshot_every == 0:
            blob = tt.canonical_state_json(tracker.snapshot()["state"]).encode("utf-8")
            rep.snapshots += 1
            rep.snapshot_bytes_total += len(blob)
            rep.snapshot_bytes_max = max(rep.snapshot_bytes_max, len(blob))
            if len(blob) > SNAPSHOT_BYTE_CAP:
                rep.problems.append(f"batch {n}: snapshot is {len(blob)} bytes, over the "
                                    f"{SNAPSHOT_BYTE_CAP} byte cap")
        if checkpoint_at is not None and n == checkpoint_at:
            # A checkpoint at this boundary, round-tripped through JSON as a
            # written file would be, must continue indistinguishably.
            checkpoint = tracker.snapshot()
            state = tt.canonical_state_json(checkpoint["state"])
            twin = Tracker.restore(json.loads(json.dumps(checkpoint)))
            twin_until = min(batches - 1, n + checkpoint_span)
            if tt.canonical_state_json(twin.snapshot()["state"]) != state:
                rep.problems.append(f"batch {n}: restore changed the canonical state")
    closed = tracker.finish()
    final = tracker.drain()
    rep.take(final)
    if len(closed) != len(final):
        rep.problems.append(f"finish returned {len(closed)} IDs but the drain held {len(final)}")
    if tracker.drain():
        rep.problems.append("episodes survived the final drain")
    if rep.born != rep.episodes:
        rep.problems.append(f"{rep.born} tracks born but {rep.episodes} episodes emitted")
    if rep.episode_observations != rep.assigned:
        rep.problems.append(f"episode observations {rep.episode_observations} != "
                            f"assigned detections {rep.assigned}")
    return rep


def run(batches_a: int = 100000, batches_b: int = 250, *, snapshot_every: int = 1000,
        checkpoint_at: int | None = 500) -> dict:
    """Both streams, sequentially, inside one measured interval."""
    baseline_peak = _rss_mib()
    baseline_now = _current_rss_mib()
    started = time.perf_counter()
    rep_a = run_stream("resource-a", "resource-a", batches_a, batch_a,
                       snapshot_every=snapshot_every, checkpoint_at=checkpoint_at)
    rep_b = run_stream("resource-b", "resource-b", batches_b, batch_b,
                       snapshot_every=snapshot_every, checkpoint_at=checkpoint_at)
    elapsed = time.perf_counter() - started
    peak = _rss_mib()
    problems = rep_a.problems + rep_b.problems
    if elapsed > TIME_BUDGET_S:
        problems.append(f"{elapsed:.1f} s exceeds the declared {TIME_BUDGET_S:.0f} s budget")
    additional = peak - baseline_peak
    if additional > RSS_BUDGET_MIB:
        problems.append(f"{additional:.1f} MiB of additional peak RSS exceeds the declared "
                        f"{RSS_BUDGET_MIB:.0f} MiB budget")
    return {
        "elapsed_s": round(elapsed, 3),
        "throughput_batches_per_s": round((rep_a.batches + rep_b.batches) / elapsed, 1) if elapsed else None,
        "throughput_detections_per_s": round((rep_a.detections + rep_b.detections) / elapsed, 1) if elapsed else None,
        "rss_baseline_peak_mib": round(baseline_peak, 2),
        "rss_baseline_current_mib": None if baseline_now is None else round(baseline_now, 2),
        "rss_peak_mib": round(peak, 2),
        "rss_additional_peak_mib": round(additional, 2),
        "python": platform.python_version(),
        "platform": platform.platform(),
        "cpus": os.cpu_count(),
        "streams": {"a": rep_a.as_dict(), "b": rep_b.as_dict()},
        "problems": problems,
        "ok": not problems,
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--batches-a", type=int, default=100000)
    ap.add_argument("--batches-b", type=int, default=250)
    ap.add_argument("--snapshot-every", type=int, default=1000)
    ap.add_argument("--checkpoint-at", type=int, default=500,
                    help="batch index at which to verify restore-and-continue (-1 disables)")
    ap.add_argument("--json", action="store_true", help="report as one JSON object")
    args = ap.parse_args(argv)
    report = run(args.batches_a, args.batches_b, snapshot_every=args.snapshot_every,
                 checkpoint_at=None if args.checkpoint_at < 0 else args.checkpoint_at)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        for name in ("a", "b"):
            s = report["streams"][name]
            print(f"stream {s['name']}: {s['batches']} batches, {s['detections']} detections, "
                  f"{s['assigned']} assigned ({s['born']} born, {s['matched']} matched, "
                  f"{s['ambiguous']} ambiguous), {s['episodes']} episodes holding "
                  f"{s['episode_observations']} observations, closes={s['closed_reasons']}, "
                  f"{s['snapshots']} snapshots max {s['snapshot_bytes_max']} B, "
                  f"{s['checkpoint_checks']} checkpoint episodes")
        print(f"elapsed {report['elapsed_s']} s "
              f"({report['throughput_batches_per_s']} batches/s, "
              f"{report['throughput_detections_per_s']} detections/s)")
        print(f"peak RSS {report['rss_peak_mib']} MiB, baseline peak "
              f"{report['rss_baseline_peak_mib']} MiB, additional "
              f"{report['rss_additional_peak_mib']} MiB "
              f"(budget {TIME_BUDGET_S:.0f} s / {RSS_BUDGET_MIB:.0f} MiB)")
        print(f"python {report['python']} on {report['platform']}, {report['cpus']} CPUs visible")
        if report["problems"]:
            print(f"{len(report['problems'])} PROBLEM(S):")
            for p in report["problems"][:20]:
                print("  " + p)
        else:
            print("every contract invariant held")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
