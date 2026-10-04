#!/usr/bin/env python3
"""In-product verification checks for the Labs tracking workflow.

The operator starts these from the Labs Tracking panel; they execute the REAL
code and report what this run produced -- never a stored success list. One
JSONL record per check on stdout:

    {"event":"check","group":G,"name":N,"status":"pass|fail|skip",
     "detail":D,"ms":M,"control":bool}
    {"event":"group","group":G,"status":...,"passed":n,"failed":n,"skipped":n}
    {"event":"done","passed":n,"failed":n,"skipped":n,"control_ok":bool}

Groups:
  contract    the published contract suite (all eight public cases plus the
              contract's own checks) and the adapter examples, run as the real
              subprocess and reported per group of checks.
  regression  the existing Labs worker tests and the two analyser self-tests
              the original assignment requires.
  workload    the declared section-13 streaming workload in its own process:
              measured wall time, peak RSS and snapshot sizes against the
              contract's limits.
  integration the product path itself: real engine invocation, recording
              identity/hash, timestamp alignment, replay, cancellation, repeat
              runs without stale results -- plus a DELIBERATE failure control.

A check that cannot run for want of an input is reported SKIP with the reason,
never as a pass. The deliberate failure control is reported as a real failure
and the harness then asserts that it saw one; if the harness ever came back
green, the control itself fails.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

_HERE = Path(__file__).resolve().parent
ROOT = _HERE.parent.parent
sys.path.insert(0, str(_HERE))

import temporal_tracks as TT            # noqa: E402
import temporal_tracks_adapter as TA    # noqa: E402

RUNNER = _HERE / "temporal_tracks_run.py"
CONTRACT_SUITE = ROOT / "tools" / "tests" / "labs-temporal-tracks.py"
WORKER_SUITE = ROOT / "tools" / "tests" / "labs-worker.py"
SHAPE_SELFTEST = _HERE / "selftest_shape_observations.py"
PROFILE_SELFTEST = _HERE / "selftest_object_profile.py"
WORKLOAD = ROOT / "tools" / "tests" / "fixtures" / "temporal_tracks" / "workload_measure.py"

_PASS_FAIL = re.compile(r"^(PASS|FAIL)\s+(\S+)")
_RESULT = {"passed": 0, "failed": 0, "skipped": 0, "control_failed": 0}
_CONTROL = {"deliberate_seen_failed": False}


def emit(record: dict) -> None:
    sys.stdout.write(json.dumps(record, ensure_ascii=True) + "\n")
    sys.stdout.flush()


def check(group: str, name: str, ok, detail: str = "", ms: float = 0.0,
          control: bool = False) -> None:
    if ok is None:
        status = "skip"
        _RESULT["skipped"] += 1
    else:
        status = "pass" if ok else "fail"
        _RESULT["passed" if ok else "failed"] += 1
    if control and status == "fail":
        _CONTROL["deliberate_seen_failed"] = True
        _RESULT["control_failed"] += 1
    emit({"event": "check", "group": group, "name": name, "status": status,
          "detail": detail, "ms": round(ms, 1), "control": control})


def group(name: str, counts: dict) -> None:
    real = counts["failed"] - counts.get("control_failed", 0)
    emit({"event": "group", "group": name,
          "status": "fail" if real else "pass", **counts})


def _run(cmd, timeout=900, cwd=None):
    t0 = time.time()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout, cwd=str(cwd or ROOT))
        return proc.returncode, proc.stdout, proc.stderr, time.time() - t0
    except subprocess.TimeoutExpired:
        return None, "", "timed out after %ss" % timeout, time.time() - t0
    except OSError as exc:
        return None, "", str(exc), time.time() - t0


# ----------------------------------------------------------------------------------
# contract: the published suite, reported per check family
# ----------------------------------------------------------------------------------
def group_contract(quick: bool) -> dict:
    before = dict(_RESULT)
    cmd = [sys.executable, str(CONTRACT_SUITE)]
    if not quick:
        cmd.append("--full-workload")
    code, out, err, secs = _run(cmd, timeout=1800 if not quick else 600)
    if code is None:
        check("contract", "contract-suite", False, err[:300], secs * 1000)
        return _delta(before)
    families: dict = {}
    for line in out.splitlines():
        m = _PASS_FAIL.match(line.strip())
        if not m:
            continue
        status, token = m.group(1), m.group(2)
        fam = token.split("/")[0].split(":")[0]
        slot = families.setdefault(fam, {"pass": 0, "fail": 0})
        slot["pass" if status == "PASS" else "fail"] += 1
    summary = ""
    for line in out.splitlines():
        if re.match(r"^\d+ PASS, \d+ FAIL", line.strip()):
            summary = line.strip()
    for fam in sorted(families):
        slot = families[fam]
        check("contract", fam, slot["fail"] == 0,
              "%d passed, %d failed" % (slot["pass"], slot["fail"]))
    check("contract", "contract-suite-exit", code == 0,
          "%s (exit %s)%s" % (summary or "no summary line", code,
                              "" if code == 0 else " :: " + err.strip()[:200]),
          secs * 1000)
    return _delta(before)


# ----------------------------------------------------------------------------------
# regression: the existing Labs suites
# ----------------------------------------------------------------------------------
def group_regression() -> dict:
    before = dict(_RESULT)
    code, out, err, secs = _run([sys.executable, str(WORKER_SUITE)], timeout=1800)
    passes = sum(1 for line in out.splitlines() if line.startswith("PASS "))
    fails = [line for line in out.splitlines() if line.startswith("FAIL ")]
    ok = code == 0 and not fails and passes > 0
    check("regression", "labs-worker (existing suite)", ok,
          "%d assertions passed, %d failed, exit %s" % (passes, len(fails), code),
          secs * 1000)
    for line in fails[:8]:
        check("regression", "labs-worker: " + line[5:80], False, "reported by the suite")

    for label, path, expect in (("shape_observations self-test", SHAPE_SELFTEST, 79),
                                ("object_profile self-test", PROFILE_SELFTEST, 40)):
        code, out, err, secs = _run([sys.executable, str(path)], timeout=900)
        m = re.search(r"(\d+)/(\d+) checks passed", out)
        got = int(m.group(1)) if m else 0
        ok = code == 0 and m is not None and got == expect
        check("regression", label, ok,
              "%s, exit %s" % (m.group(0) if m else "no summary line", code),
              secs * 1000)
    return _delta(before)


# ----------------------------------------------------------------------------------
# workload: the declared section-13 stream, measured in its own process
# ----------------------------------------------------------------------------------
def group_workload() -> dict:
    before = dict(_RESULT)
    code, out, err, secs = _run([sys.executable, str(WORKLOAD)], timeout=1800)
    try:
        report = json.loads(out[out.index("{"):])
    except (ValueError, json.JSONDecodeError):
        check("workload", "declared streaming workload", False,
              "no report: %s" % (err.strip()[:200] or out.strip()[:200]), secs * 1000)
        return _delta(before)
    s1, s2 = report["streams"][0], report["streams"][1]
    check("workload", "stream 1 (100000 x 8 detections)", s1["detections"] == 800000,
          "%.2f s, %d detections, %d tracks" % (s1["seconds"], s1["detections"],
                                                s1["episodes"]), s1["seconds"] * 1000)
    check("workload", "stream 2 (250 x 32 detections)", s2["detections"] == 8000,
          "%.2f s, %d detections" % (s2["seconds"], s2["detections"]),
          s2["seconds"] * 1000)
    check("workload", "both streams within 180 s", report["total_seconds"] <= 180,
          "%.2f s measured" % report["total_seconds"], report["total_seconds"] * 1000)
    check("workload", "added peak RSS within 128 MiB",
          report["added_peak_rss"] <= 128 * 1024 * 1024,
          "%.1f MiB measured" % (report["added_peak_rss"] / 1048576.0))
    check("workload", "snapshots within 2 MiB", report["ok"],
          "largest %d bytes" % max(s["max_snapshot_bytes"] for s in report["streams"]))
    check("workload", "aggregate observation accounting", report["ok"],
          "every detection accounted for once" if report["ok"]
          else "; ".join(report["problems"][:3]))
    return _delta(before)


def _delta(before: dict) -> dict:
    return {"passed": _RESULT["passed"] - before["passed"],
            "failed": _RESULT["failed"] - before["failed"],
            "skipped": _RESULT["skipped"] - before["skipped"],
            "control_failed": (_RESULT["control_failed"]
                               - before.get("control_failed", 0))}


# ----------------------------------------------------------------------------------
# integration: the product path, and a deliberate failure control
# ----------------------------------------------------------------------------------
def group_integration(recording: str, workdir: Path) -> dict:
    before = dict(_RESULT)
    workdir.mkdir(parents=True, exist_ok=True)

    # 1. the engine really runs, on a scenario with a known answer
    t0 = time.time()
    tr = TT.Tracker("verify-cam", "verify-unit", {"path_points": 3})
    receipts = []
    for seq, t, x in ((0, 0, 0.30), (1, 500, 0.35), (2, 1000, 0.40)):
        receipts.append(tr.feed({"camera_id": "verify-cam", "unit_id": "verify-unit",
                                 "seq": seq, "t_ms": t,
                                 "detections": [{"id": "d0",
                                                 "bbox": [x - 0.02, 0.48, 0.04, 0.04]}]}))
    closed = tr.finish()
    episodes = tr.drain()
    ok = (receipts[0]["assignments"][0]["status"] == "born"
          and all(r["assignments"][0]["track_id"] == "t00000001" for r in receipts)
          and closed == ["t00000001"] and episodes[0]["observations"] == 3)
    check("integration", "engine invocation (deterministic scenario)", ok,
          "3 receipts, 1 track, %d observations"
          % (episodes[0]["observations"] if episodes else -1),
          (time.time() - t0) * 1000)

    # 2. checkpoint round trip through JSON
    snap = json.loads(json.dumps(tr.snapshot()))
    restored = TT.Tracker.restore(snap)
    check("integration", "checkpoint restore equals uninterrupted state",
          restored.snapshot() == tr.snapshot(),
          "digest %s" % snap["sha256"][:12])

    # 3. replay is explicit and changes nothing
    tr2 = TT.Tracker("verify-cam", "verify-unit")
    first = tr2.feed({"camera_id": "verify-cam", "unit_id": "verify-unit",
                      "seq": 0, "t_ms": 0,
                      "detections": [{"id": "d0", "bbox": [0.28, 0.48, 0.04, 0.04]}]})
    again = tr2.feed({"camera_id": "verify-cam", "unit_id": "verify-unit",
                      "seq": 0, "t_ms": 0,
                      "detections": [{"id": "d0", "bbox": [0.28, 0.48, 0.04, 0.04]}]})
    check("integration", "duplicate input is a replay, not new evidence",
          again["replayed"] is True and first["assignments"] == again["assignments"]
          and tr2.drain() == [])

    # 4. a malformed batch is refused by code, and the state survives
    before_snap = tr2.snapshot()
    code = None
    try:
        tr2.feed({"camera_id": "verify-cam", "unit_id": "verify-unit", "seq": 1,
                  "t_ms": 100, "detections": [{"id": "d0",
                                               "bbox": [float("nan"), 0, 0.1, 0.1]}]})
    except TT.TrackingError as exc:
        code = exc.code
    check("integration", "malformed measurement refused atomically",
          code == "invalid_input" and tr2.snapshot() == before_snap,
          "code=%r" % code)

    # 5. the adapter maps the existing MaskFrame/Blob shape
    t0 = time.time()
    class _Blob:
        label = 3
        bbox = (0.1, 0.2, 0.05, 0.05)

    class _Frame:
        t_s = 2.5
        run = 1
        scored = True
        blobs = (_Blob(),)

    batch = TA.mask_frame_batch(_Frame(), camera_id="verify-cam",
                                unit_id="verify-unit", seq=0, previous_run=1)
    check("integration", "MaskFrame/Blob adapter maps real analyser output",
          batch["t_ms"] == 2500 and batch["detections"][0]["id"] == "b3"
          and batch["reset"] is False, json.dumps(batch["detections"]),
          (time.time() - t0) * 1000)

    # ---- recording-dependent checks -----------------------------------------
    if not recording or not os.path.isfile(recording):
        why = ("no recording selected" if not recording
               else "recording not readable: %s" % recording)
        check("integration", "real recording: identity/hash", None, why)
        check("integration", "real recording: bounded run", None, why)
        check("integration", "real recording: timestamp alignment", None, why)
        check("integration", "real recording: cancellation", None, why)
        check("integration", "repeat runs replace, never append", None, why)
    else:
        want = hashlib.sha256(Path(recording).read_bytes()).hexdigest()
        out1 = workdir / "verify-run-1"
        code, out, err, secs = _run(
            [sys.executable, str(RUNNER), "--recording", recording,
             "--camera", "verify-recording", "--unit", "verify",
             "--max-frames", "60", "--out", str(out1)], timeout=600)
        meta = {}
        if (out1 / "run.json").is_file():
            meta = json.loads((out1 / "run.json").read_text())
        check("integration", "real recording: identity/hash",
              meta.get("recording_sha256") == want,
              "sha256 %s" % str(meta.get("recording_sha256"))[:16], secs * 1000)
        check("integration", "real recording: bounded run",
              code == 0 and meta.get("status") == "completed"
              and meta.get("frames") == 60,
              "status=%s frames=%s exit=%s" % (meta.get("status"),
                                               meta.get("frames"), code))

        # alignment: real frame timestamps, monotone, at the probed rate, and
        # every track sample a real frame instant (never an interpolated time)
        frames = []
        if (out1 / "frames.jsonl").is_file():
            for line in (out1 / "frames.jsonl").read_text().splitlines():
                if line.strip():
                    frames.append(json.loads(line))
        stamps = [f["t_ms"] for f in frames]
        steps = sorted(b - a for a, b in zip(stamps, stamps[1:]))
        median = steps[len(steps) // 2] if steps else 0
        episodes = json.loads((out1 / "tracks.json").read_text()) \
            if (out1 / "tracks.json").is_file() else []
        samples_real = all(p[0] in set(stamps) for e in episodes for p in e["path"])
        check("integration", "real recording: timestamp alignment",
              bool(stamps) and stamps == sorted(set(stamps)) and 20 <= median <= 200
              and samples_real,
              "%d frames, median step %d ms, all %d track samples on real frame "
              "instants" % (len(stamps), median,
                            sum(len(e["path"]) for e in episodes)))

        # cancellation: the same runner, stopped mid-decode
        out2 = workdir / "verify-run-cancel"
        proc = subprocess.Popen(
            [sys.executable, str(RUNNER), "--recording", recording,
             "--camera", "verify-recording", "--unit", "verify",
             "--max-frames", "100000", "--out", str(out2)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(1.5)
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        meta2 = {}
        if (out2 / "run.json").is_file():
            meta2 = json.loads((out2 / "run.json").read_text())
        check("integration", "real recording: cancellation",
              proc.returncode == 3 and meta2.get("status") == "cancelled",
              "exit=%s status=%s" % (proc.returncode, meta2.get("status")))

        # repeat runs: same recording, different bound -> its own evidence
        out3 = workdir / "verify-run-2"
        code3, _out3, _err3, _s3 = _run(
            [sys.executable, str(RUNNER), "--recording", recording,
             "--camera", "verify-recording", "--unit", "verify",
             "--max-frames", "30", "--out", str(out3)], timeout=600)
        meta3 = {}
        if (out3 / "run.json").is_file():
            meta3 = json.loads((out3 / "run.json").read_text())
        frames3 = sum(1 for line in (out3 / "frames.jsonl").read_text().splitlines()
                      if line.strip()) if (out3 / "frames.jsonl").is_file() else 0
        check("integration", "repeat runs replace, never append",
              code3 == 0 and meta3.get("frames") == 30 and frames3 == 30
              and meta3.get("recording_sha256") == want,
              "second run: %d frames (first: 60)" % frames3)

    # 6. engine-only re-run reuses stored detections (the input cache)
    if recording and os.path.isfile(recording):
        out4 = workdir / "verify-run-engineonly"
        ledger = workdir / "verify-run-1" / "frames.jsonl"
        code4, _o4, err4, _s4 = _run(
            [sys.executable, str(RUNNER), "--reuse", str(ledger),
             "--camera", "verify-recording", "--unit", "verify",
             "--out", str(out4)], timeout=600)
        meta4 = {}
        if (out4 / "run.json").is_file():
            meta4 = json.loads((out4 / "run.json").read_text())
        check("integration", "cached detections re-run without decoding",
              code4 == 0 and meta4.get("mode") == "engine-only"
              and meta4.get("frames") == 60
              and meta4.get("source_sha256") == hashlib.sha256(
                  Path(recording).read_bytes()).hexdigest(),
              "status=%s frames=%s exit=%s %s" % (meta4.get("status"),
                                                  meta4.get("frames"), code4,
                                                  err4.strip()[:120]))

    # 7. DELIBERATE FAILURE CONTROL -- must be reported as a failure
    check("integration", "control: this check is designed to fail", False,
          "deliberate: proves the panel shows a real failure instead of "
          "reporting success unconditionally", 0.0, control=True)
    check("integration", "control: the harness reported that failure",
          _CONTROL["deliberate_seen_failed"],
          "the deliberate failure was recorded as FAIL" if
          _CONTROL["deliberate_seen_failed"] else
          "THE HARNESS SWALLOWED A FAILURE -- results here cannot be trusted")
    return _delta(before)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--group", default="all",
                    choices=["all", "contract", "regression", "workload",
                             "integration"])
    ap.add_argument("--recording", default="")
    ap.add_argument("--workdir", default="")
    ap.add_argument("--quick", action="store_true",
                    help="bounded contract suite (no declared workload inside it)")
    args = ap.parse_args(argv)

    workdir = Path(args.workdir) if args.workdir else Path(
        os.environ.get("TMPDIR", "/tmp")) / "labs-tracking-checks"
    started = time.time()
    groups = (["contract", "regression", "workload", "integration"]
              if args.group == "all" else [args.group])

    for name in groups:
        before = dict(_RESULT)
        if name == "contract":
            group_contract(args.quick)
        elif name == "regression":
            group_regression()
        elif name == "workload":
            group_workload()
        else:
            group_integration(args.recording, workdir)
        group(name, _delta(before))

    real_failed = _RESULT["failed"] - _RESULT["control_failed"]
    emit({"event": "done", "passed": _RESULT["passed"],
          "failed": _RESULT["failed"], "skipped": _RESULT["skipped"],
          "control_failed": _RESULT["control_failed"], "real_failed": real_failed,
          "control_ok": _CONTROL["deliberate_seen_failed"],
          "elapsed_s": round(time.time() - started, 3)})
    # The deliberate control IS a real failure and stays in the counts. The exit
    # status separates it explicitly: 0 only when every non-control check passed
    # AND the control was reported as a failure; 1 otherwise.
    return 0 if (real_failed == 0 and _CONTROL["deliberate_seen_failed"]) else 1


if __name__ == "__main__":
    sys.exit(main())
