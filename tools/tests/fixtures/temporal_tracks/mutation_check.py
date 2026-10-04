#!/usr/bin/env python3
"""Mutation check: does `tools/tests/labs-temporal-tracks.py` actually fail when
the implementation is wrong?

A suite that passes proves nothing on its own. The benchmark's rubric scores
whether the suite DETECTS an independently planted defect in each of five
families -- association, ambiguity, time boundaries, replay/checkpoints,
validation/adapter -- so this helper plants its own defects, one at a time, and
requires the suite to fail for every one. A defect that survives is a hole in the
suite and this script exits 1 for it. One entry (C0) is a deliberate NO-OP edit:
if the harness reports that as a defect, it is over-reporting and says nothing.

It never touches the working tree. `tools/` and the published cases are copied
into a temporary directory, each defect is written into the COPY, the suite runs
there, and the copy is discarded.

    python3 tools/tests/fixtures/temporal_tracks/mutation_check.py           # all
    python3 tools/tests/fixtures/temporal_tracks/mutation_check.py --list    # names
    python3 tools/tests/fixtures/temporal_tracks/mutation_check.py --only A2,B3
    python3 tools/tests/fixtures/temporal_tracks/mutation_check.py --keep /tmp/x

Each defect is a single semantic edit of the kind a plausible implementation
gets wrong -- a greedy assignment instead of a global optimum, a prediction that
forgets the velocity, a `>` that should be `>=`, a replay that reports today's
queue, a snapshot that forgets the outbox, an adapter that truncates instead of
rounding -- not a syntax error or a crash. Every one still produces a working
tracker that answers most questions correctly, which is exactly what a weak suite
waves through.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[3]
SUITE = "tools/tests/labs-temporal-tracks.py"

CORE = "tools/labs/temporal_tracks.py"
MATCH = "tools/labs/temporal_tracks_matching.py"
ADAPTER = "tools/labs/temporal_tracks_adapter.py"
CLIMOD = "tools/labs/replay_temporal_tracks.py"

CONTROL = "C0"

#: (id, family, file, old, new, what the defect is)
MUTATIONS: list[tuple[str, str, str, str, str, str]] = [
    # ---- control: a no-op edit that must NOT be reported -------------------
    (CONTROL, "control", CORE,
     "        self.max_gap_ms = 0\n",
     "        self.max_gap_ms = 0          # no accepted observation yet\n",
     "a comment: no behaviour change at all"),

    # ---- association -------------------------------------------------------
    ("A1", "association", MATCH,
     "    size, cost, match_t = optimal(adj, n_tracks, n_dets)\n",
     "    _edges = sorted((c, t, j) for t, row in enumerate(adj) for j, c in row)\n"
     "    match_t = [-1] * n_tracks\n"
     "    _used = [False] * n_dets\n"
     "    size = 0\n"
     "    cost = 0\n"
     "    for _c, _t, _j in _edges:\n"
     "        if match_t[_t] < 0 and not _used[_j]:\n"
     "            match_t[_t] = _j\n"
     "            _used[_j] = True\n"
     "            size += 1\n"
     "            cost += _c\n",
     "greedy cheapest-edge-first instead of maximum cardinality first"),
    ("A2", "association", CORE,
     "        return _nz(self.cx + vx * dt), _nz(self.cy + vy * dt), dt",
     "        return _nz(self.cx), _nz(self.cy), dt",
     "association gates on the last position instead of the prediction"),
    ("A3", "association", CORE,
     "            if speed > max_speed:",
     "            if False:",
     "max_speed is never applied"),
    ("A4", "association", CORE,
     "                d = math.hypot(det_cx[j] - px, det_cy[j] - py)\n"
     "                if d > g:",
     "                d = math.hypot(det_cx[j] - px, det_cy[j] - py)\n"
     "                if d >= g:",
     "the distance gate is exclusive where the contract makes it inclusive"),
    ("A5", "association", CORE,
     "                if ratio < ratio_min or ratio > ratio_max:",
     "                if False:",
     "the box-area ratio gate is not applied"),
    ("A6", "association", CORE,
     "    dets.sort(key=lambda d: d.id)",
     "    dets = list(dets)",
     "detections keep their input order, so IDs and receipts depend on it"),
    ("A7", "association", CORE,
     "                    a = 0.5 * (abs(t_app[0] - d_app[0]) + abs(t_app[1] - d_app[1])\n"
     "                               + abs(t_app[2] - d_app[2]) + abs(t_app[3] - d_app[3]))",
     "                    a = 0.5 * abs(t_app[0] - d_app[0])",
     "the appearance distance uses one band instead of half the L1 sum"),
    ("A8", "association", CORE,
     "            gates.append(gate_base + gate_speed * dt)",
     "            gates.append(gate_base)",
     "gate_speed never widens the gate, so occlusions cannot be bridged"),
    ("A9", "association", CORE,
     "        if det.app is not None:\n"
     "            self.appearance = det.app",
     "        self.appearance = det.app",
     "a null descriptor clears the track's descriptor instead of keeping it"),

    # ---- ambiguity ---------------------------------------------------------
    ("B1", "ambiguity", MATCH,
     "    limit = cost + margin\n    for t in range(n_tracks):",
     "    limit = cost + margin\n    for t in ():",
     "the ambiguity test never runs: every best matching is accepted"),
    ("B2", "ambiguity", CORE,
     "                abstained.extend(tracks)",
     "                abstained.extend(tracks[:1])",
     "only one track of an abstaining component counts the ambiguous batch"),
    ("B3", "ambiguity", CORE,
     "            if _component_merge(ds, radj, preds, dets):",
     "            if False:",
     "the possible-merge rule is never applied"),
    ("B4", "ambiguity", MATCH,
     "        if size2 == size and cost2 <= limit:",
     "        if size2 == size and cost2 < limit:",
     "ambiguity_margin is treated as exclusive instead of inclusive"),
    ("B5", "ambiguity", MATCH,
     "        if size2 == size and cost2 <= limit:",
     "        if cost2 <= limit:",
     "a smaller-cardinality alternative wrongly voids the matching"),
    ("B6", "ambiguity", CORE,
     "                if hits >= 2:",
     "                if hits >= 3:",
     "a merge needs three swallowed centres instead of two"),
    ("B7", "ambiguity", CORE,
     "                for j in ds:\n"
     '                    outcomes[j] = ("ambiguous", None, reason)',
     "                for j in ds:\n"
     "                    if len(radj[j]) > 1:\n"
     '                        outcomes[j] = ("ambiguous", None, reason)',
     "only the multiply-linked detections abstain, not the whole component"),
    ("B8", "ambiguity", CORE,
     "            if reason is not None:\n",
     "            if reason is not None and reason != \"merge\":\n",
     "a merge is reported but the matching is applied anyway"),
    ("B9", "ambiguity", CORE,
     "            if det.x <= px <= right and det.y <= py <= bottom:",
     "            if det.x < px < right and det.y < py < bottom:",
     "box boundaries are excluded from the merge test"),

    # ---- time boundaries ---------------------------------------------------
    ("C1", "time", CORE,
     "                if t_ms - tr.last_t > gap:",
     "                if t_ms - tr.last_t >= gap:",
     "the gap boundary is inclusive where the contract says strict >"),
    ("C2", "time", CORE,
     "                elif t_ms - tr.first_t > span:",
     "                elif False:",
     "max_span_ms never closes a track"),
    ("C3", "time", CORE,
     "                if t_ms - tr.last_t > gap:\n"
     "                    closures.append((tr, \"gap\"))\n"
     "                elif t_ms - tr.first_t > span:\n"
     "                    closures.append((tr, \"span\"))",
     "                if t_ms - tr.first_t > span:\n"
     "                    closures.append((tr, \"span\"))\n"
     "                elif t_ms - tr.last_t > gap:\n"
     "                    closures.append((tr, \"gap\"))",
     "span is tested before gap, so a batch that trips both reports span"),
    ("C4", "time", CORE,
     "        if self._last_t is not None and nb.t_ms <= self._last_t:",
     "        if self._last_t is not None and nb.t_ms < self._last_t:",
     "an equal timestamp is accepted instead of being sequence_error"),
    ("C5", "time", CORE,
     "            closures = [(tr, \"reset\") for tr in self._tracks]",
     "            closures = [(tr, \"gap\") for tr in self._tracks]",
     "a declared discontinuity reports gap instead of reset"),
    ("C7", "time", CORE,
     "        gap = t_ms - self.last_t\n"
     "        if gap > self.max_gap_ms:",
     "        gap = 0\n"
     "        if gap > self.max_gap_ms:",
     "max_observation_gap_ms never records a coast"),
    ("C8", "time", CORE,
     "        elapsed_ms = self.last_t - self.first_t",
     "        elapsed_ms = self.best_t - self.first_t",
     "mean_speed divides by the wrong elapsed time"),
    ("C9", "time", CORE,
     "        if det.area > self.best_area:",
     "        if det.area >= self.best_area:",
     "the latest box wins an equal-area tie instead of the earliest"),

    # ---- replay and checkpoints -------------------------------------------
    ("D1", "replay", CORE,
     "            return _copy_receipt(entry.receipt, replayed=True)",
     "            self._outbox = self._outbox + [_copy_episode(e) for e in self._outbox]\n"
     "            return _copy_receipt(entry.receipt, replayed=True)",
     "a replay requeues the episodes the original operation closed"),
    ("D2", "replay", CORE,
     "            return _copy_receipt(entry.receipt, replayed=True)",
     "            return {\"seq\": nb.seq, \"replayed\": True,\n"
     "                    \"assignments\": _copy_receipt(entry.receipt)[\"assignments\"],\n"
     "                    \"closed\": [e[\"track_id\"] for e in self._outbox]}",
     "a replay reports today's queue instead of the original operation's closures"),
    ("D3", "replay", CORE,
     "        while len(self._window) > cfg[\"replay_batches\"]:",
     "        while False:",
     "the replay window is never evicted, so stale seqs stay replayable"),
    ("D4", "replay", CORE,
     "                tuple((d.id, d.x, d.y, d.w, d.h, d.app) for d in dets))",
     "                tuple((d.id, d.x, d.y, d.w, d.h, None) for d in dets))",
     "the retained input identity ignores the appearance descriptor"),
    ("D5", "replay", CORE,
     "            \"outbox\": [_copy_episode(e) for e in self._outbox],",
     "            \"outbox\": [],",
     "the snapshot forgets undrained episodes, so a restore loses them"),
    ("D6", "replay", CORE,
     "        if hashlib.sha256(blob.encode(\"utf-8\")).hexdigest() != want:",
     "        if False:",
     "restore does not verify the checksum"),
    ("D7", "replay", CORE,
     "            tr.check_invariants(code)",
     "            _ = code",
     "restore trusts a corrupted track instead of checking its invariants"),
    ("D8", "replay", CORE,
     "        self._window[nb.seq] = _Replay(nb.identity, _copy_receipt(receipt))",
     "        self._window[nb.seq] = _Replay(nb.identity, _copy_receipt(receipt, replayed=True))",
     "the retained receipt is stored as a replay"),
    ("D9", "replay", CORE,
     "            if entry.ident != nb.identity:",
     "            if False:",
     "different content at a retained seq is replayed instead of refused"),
    ("D10", "replay", CORE,
     "        expected = 0 if self._last_seq is None else self._last_seq + 1",
     "        expected = 0 if self._last_seq is None else self._last_seq",
     "a repeated seq is treated as the next new batch"),
    ("D11", "replay", CORE,
     "            \"tracks\": [tr.state() for tr in self._tracks],",
     "            \"tracks\": [tr.state() for tr in reversed(self._tracks)],",
     "the snapshot records tracks out of creation order"),
    ("D12", "replay", CORE,
     "        tracker._next_id = next_id",
     "        tracker._next_id = 1",
     "a restored tracker restarts its ID counter, so new tracks collide"),

    # ---- validation and the adapter ---------------------------------------
    ("E1", "validation", CORE,
     "    for key in raw:\n        if key not in CONFIG_SPEC:",
     "    for key in ():\n        if key not in CONFIG_SPEC:",
     "an unknown configuration key is silently ignored"),
    ("E2", "validation", CORE,
     "    if isinstance(v, bool) or not isinstance(v, int):\n"
     "        raise TrackingError(code, f\"{what} must be an integer, got {v!r}\")",
     "    if not isinstance(v, int):\n"
     "        raise TrackingError(code, f\"{what} must be an integer, got {v!r}\")",
     "a boolean is accepted as an integer"),
    ("E3", "validation", CORE,
     "    if abs(sum(vals) - 1.0) > APPEARANCE_SUM_TOL:",
     "    if False:",
     "an appearance descriptor that does not sum to 1 is accepted"),
    ("E4", "validation", CORE,
     "        if did in seen:",
     "        if False:",
     "duplicate detection IDs in one batch are accepted"),
    ("E5", "validation", CORE,
     "    if len(raw) > limit:",
     "    if False:",
     "max_detections is not enforced"),
    ("E6", "validation", CORE,
     "        if len(live) + born > cfg[\"max_tracks\"]:",
     "        if len(live) + born >= cfg[\"max_tracks\"]:",
     "a batch that exactly fills max_tracks is refused"),
    ("E7", "validation", CORE,
     "    if x + w > 1.0 or y + h > 1.0:",
     "    if x + w > 1.0 + 1e-6 or y + h > 1.0 + 1e-6:",
     "a box that leaves the frame is accepted"),
    ("E8", "validation", CORE,
     "        if (val >= high) if high_open else (val > high):",
     "        if False:",
     "configuration upper bounds are not enforced"),
    ("E9", "validation", ADAPTER,
     "    t_ms = int(math.floor(scaled))",
     "    t_ms = int(scaled - 0.5)",
     "the adapter truncates instead of rounding to the nearest millisecond"),
    ("E20", "validation", ADAPTER,
     "    if not math.isfinite(scaled):",
     "    if False:",
     "a finite t_s whose millisecond product overflows is not refused"),
    ("E10", "validation", ADAPTER,
     "            \"reset\": bool(previous_run is not None and run != previous_run)}",
     "            \"reset\": bool(previous_run is not None)}",
     "the adapter declares a discontinuity on every frame naming a previous run"),
    ("E11", "validation", ADAPTER,
     "    if len(items) > MAX_OBSERVATIONS:",
     "    items = items[:MAX_OBSERVATIONS]\n    if False:",
     "the preview silently truncates instead of refusing more than 500 episodes"),
    ("E12", "validation", ADAPTER,
     "            \"max_gap_s\": ep[\"max_observation_gap_ms\"] / 1000.0,",
     "            \"max_gap_s\": ep[\"max_observation_gap_ms\"],",
     "max_gap_s is emitted in milliseconds, not seconds"),
    ("E13", "validation", ADAPTER,
     "    if utc.minute or utc.second or utc.microsecond:",
     "    if False:",
     "an hour_start that is not a whole UTC hour is accepted"),
    ("E14", "validation", ADAPTER,
     "    detections: list[dict] = []\n    if scored:",
     "    detections: list[dict] = []\n    if True:",
     "an unscored frame's blobs are inspected and reported as detections"),
    ("E15", "validation", ADAPTER,
     "        if end - start >= 300000:",
     "        if end - start > 300000:",
     "a 300000 ms episode is rendered although it can never join an event group"),
    ("E16", "validation", CLIMOD,
     "    if not isinstance(op, str) or op not in COMMANDS:",
     "    if not isinstance(op, str):",
     "an unknown op is not refused by the CLI"),
    ("E17", "validation", CLIMOD,
     "        if key in out:\n            raise _DuplicateKey(f\"duplicate object key {key!r}\")",
     "        if False:\n            raise _DuplicateKey(f\"duplicate object key {key!r}\")",
     "duplicate JSON object keys are accepted by the CLI"),
    ("E18", "validation", CLIMOD,
     "            self.tracker = Tracker(cmd[\"camera_id\"], cmd[\"unit_id\"], cmd.get(\"config\"))\n"
     "            return None",
     "            self.tracker = None\n"
     "            Tracker(cmd[\"camera_id\"], cmd[\"unit_id\"], cmd.get(\"config\"))\n"
     "            return None",
     "a failed init destroys the previous tracker instead of preserving it"),
    ("E19", "validation", CLIMOD,
     "    return 1 if failed else 0",
     "    return 0",
     "the CLI exits 0 even when a line produced an error response"),
]


def build_copy(dest: pathlib.Path) -> None:
    shutil.copytree(ROOT / "tools", dest / "tools", symlinks=True)
    (dest / "docs" / "benchmarks" / "labs-tracking").mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / "docs" / "benchmarks" / "labs-tracking" / "fixtures",
                    dest / "docs" / "benchmarks" / "labs-tracking" / "fixtures")


def run_suite(dest: pathlib.Path, timeout: float) -> tuple[int, list[str], int]:
    """(exit code, names of failing checks, number of passing checks)."""
    env = dict(os.environ, WT_SHORT="1", PYTHONHASHSEED="0")
    try:
        proc = subprocess.run([sys.executable, str(dest / SUITE)], cwd=str(dest),
                              capture_output=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return -1, ["<the suite timed out>"], 0
    text = proc.stdout.decode("utf-8", "replace") + proc.stderr.decode("utf-8", "replace")
    lines = text.split("\n")
    killed = [ln[5:].split("   [")[0].strip() for ln in lines if ln.startswith("FAIL")]
    passed = sum(1 for ln in lines if ln.startswith("PASS"))
    return proc.returncode, killed, passed


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--list", action="store_true", help="list defects and exit")
    ap.add_argument("--only", default="", help="comma-separated defect ids to run")
    ap.add_argument("--timeout", type=float, default=120.0,
                    help="per-suite timeout; a defect that hangs counts as killed")
    ap.add_argument("--keep", default="", help="keep the temporary copy in this directory")
    args = ap.parse_args(argv)
    if args.list:
        for mid, family, path, _old, _new, what in MUTATIONS:
            print(f"{mid:4s} {family:12s} {path.split('/')[-1]:28s} {what}")
        return 0
    only = {x.strip() for x in args.only.split(",") if x.strip()}
    selected = [m for m in MUTATIONS if not only or m[0] in only]

    tmp = pathlib.Path(args.keep) if args.keep else pathlib.Path(
        tempfile.mkdtemp(prefix="tt-mutation-"))
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True, exist_ok=True)
    try:
        build_copy(tmp)
        rc, killed, passed = run_suite(tmp, args.timeout)
        if rc != 0:
            print(f"the UNMUTATED copy already fails ({len(killed)} checks); fix that first:")
            for name in killed[:10]:
                print("   " + name)
            return 1
        print(f"unmutated copy: {passed} checks pass. planting {len(selected)} edits\n")
        survivors: list[tuple[str, str, str]] = []
        unapplied: list[str] = []
        control_bad = False
        kills = 0
        families: dict[str, list[str]] = {}
        started = time.perf_counter()
        for mid, family, path, old, new, what in selected:
            original = (ROOT / path).read_text(encoding="utf-8")
            if original.count(old) != 1:
                unapplied.append(mid)
                print(f"SKIP {mid:4s} {family:12s} the pattern occurs "
                      f"{original.count(old)} times -- rewrite this defect")
                continue
            target = tmp / path
            target.write_text(original.replace(old, new, 1), encoding="utf-8")
            rc, killed, _passed = run_suite(tmp, args.timeout)
            target.write_text(original, encoding="utf-8")
            detected = rc != 0
            if mid == CONTROL:
                control_bad = detected
                print(f"{'BAD ' if detected else 'ok  '} {mid:4s} {family:12s} CONTROL: "
                      f"{'reported as a defect -- this harness over-reports' if detected else 'not reported, as it must be'}")
                continue
            if detected:
                kills += 1
                families.setdefault(family, []).append(mid)
                print(f"KILL {mid:4s} {family:12s} {what}\n"
                      f"            {len(killed)} checks fail, first: {killed[0][:88]!r}")
            else:
                survivors.append((mid, family, what))
                print(f"LIVE {mid:4s} {family:12s} {what}   <-- the suite does not catch this")
        elapsed = time.perf_counter() - started
        planted = len(selected) - len(unapplied) - (1 if any(m[0] == CONTROL for m in selected) else 0)
        print(f"\n{kills}/{planted} planted defects killed in {elapsed:.0f} s")
        for family in sorted(families):
            print(f"   {family:12s} {len(families[family])} killed: {' '.join(families[family])}")
        if unapplied:
            print(f"   not applied (stale pattern): {' '.join(unapplied)}")
        if survivors:
            print("SURVIVORS -- the suite has a hole for these:")
            for mid, family, what in survivors:
                print(f"   {mid} [{family}] {what}")
        if control_bad:
            print("the control no-op edit was reported as a defect: this harness over-reports")
        return 1 if survivors or control_bad or unapplied else 0
    finally:
        if not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
