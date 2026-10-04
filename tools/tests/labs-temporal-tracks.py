#!/usr/bin/env python3
"""Labs temporal tracking -- executable contract tests. Exit 0 only if all pass.

Three layers, all offline (no network, no camera, no production database):

  1. THE PUBLIC CASES. Every operation in
     docs/benchmarks/labs-tracking/fixtures/cases.json is replayed against the
     real JSONL CLI in a real subprocess, one process per fixture `on` name,
     checking results, error objects, captures, snapshot equality and each
     stream's exit status. The published file is read, never written.
  2. THE ADAPTER EXAMPLES in the same file, in process: a real
     `labs_foreground_mask.Blob` and a lightweight frame, plus the Labs wire
     preview.
  3. CONTRACT TESTS this suite owns: validation and ordering, replay and
     atomicity, gap/span/reset boundaries, prediction and gates, ambiguity and
     merge, path bounding, checkpoint corruption, aliasing, adjacency of the
     wire preview to the worker's caps, and a bounded streaming workload with
     snapshot-size and accounting checks.

Every check prints PASS or FAIL by name; a FAIL is a nonzero exit. Nothing here
weakens a test to obtain a pass, and nothing claims a measurement it did not
take.
"""
import copy
import hashlib
import json
import math
import os
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
LABS = ROOT / "tools" / "labs"
FIXTURES = ROOT / "docs" / "benchmarks" / "labs-tracking" / "fixtures"
sys.path.insert(0, str(LABS))

import temporal_tracks as TT            # noqa: E402
import temporal_tracks_adapter as TA    # noqa: E402
import labs_foreground_mask as fm       # noqa: E402

CLI = LABS / "replay_temporal_tracks.py"

fails = []
_passed = [0]


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name +
          ("   [%s]" % detail if detail and not cond else ""))
    if not cond:
        fails.append(name)
    else:
        _passed[0] += 1


def _crashed(t, e, tb):
    print("FAIL the suite CRASHED after %d passing checks: %s: %s"
          % (_passed[0], t.__name__, e))
    sys.__excepthook__(t, e, tb)


sys.excepthook = _crashed


# ----------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------
def box(cx, cy, w=0.04, h=0.04):
    return [cx - w / 2.0, cy - h / 2.0, w, h]


def det(det_id, cx, cy, w=0.04, h=0.04, appearance=None):
    d = {"id": det_id, "bbox": box(cx, cy, w, h)}
    if appearance is not None:
        d["appearance"] = appearance
    return d


def batch(seq, t_ms, dets=(), cam="cam-a", unit="unit-a", **kw):
    b = {"camera_id": cam, "unit_id": unit, "seq": seq, "t_ms": t_ms,
         "detections": list(dets)}
    b.update(kw)
    return b


def close(a, b, tol=1e-9):
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if isinstance(a, int) and isinstance(b, int):
            return a == b
        return abs(a - b) <= tol + tol * max(abs(a), abs(b))
    return a == b


def compare(actual, expected, path="$", subset=False):
    """(ok, why) -- tolerant on reals, exact on everything else."""
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return False, "%s is %r, not an object" % (path, actual)
        for key, want in expected.items():
            if key not in actual:
                return False, "%s is missing %r" % (path, key)
            ok, why = compare(actual[key], want, "%s.%s" % (path, key), subset)
            if not ok:
                return False, why
        if not subset and set(actual) != set(expected):
            return False, ("%s has keys %r, expected %r"
                           % (path, sorted(actual), sorted(expected)))
        return True, ""
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(actual) != len(expected):
            return False, ("%s is %r, expected a %d-element list"
                           % (path, actual, len(expected)))
        for k, want in enumerate(expected):
            ok, why = compare(actual[k], want, "%s[%d]" % (path, k), subset)
            if not ok:
                return False, why
        return True, ""
    if not close(actual, expected):
        return False, "%s is %r, expected %r" % (path, actual, expected)
    return True, ""


def resign(snapshot):
    """Recompute the public envelope's checksum over whatever `state` now holds."""
    snap = copy.deepcopy(snapshot)
    blob = json.dumps(snap["state"], sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True, allow_nan=False)
    snap["sha256"] = hashlib.sha256(blob.encode("utf-8")).hexdigest()
    return snap


def errors_code(fn, *a, **kw):
    """The TrackingError code from a call that must fail, or None."""
    try:
        fn(*a, **kw)
    except TT.TrackingError as e:
        return e.code
    except Exception as e:                       # noqa: BLE001
        return "unexpected:%s" % type(e).__name__
    return None


class Cli:
    """One CLI process (= one fixture `on` environment)."""

    def __init__(self):
        self.proc = subprocess.Popen(
            [sys.executable, str(CLI)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.errors = 0
        self.lines = 0

    def send(self, command):
        self.proc.stdin.write(json.dumps(command) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("CLI exited early: %s"
                               % self.proc.stderr.read()[:400])
        self.lines += 1
        return json.loads(line)

    def send_raw(self, text):
        self.proc.stdin.write(text + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("CLI exited early: %s"
                               % self.proc.stderr.read()[:400])
        self.lines += 1
        try:
            return json.loads(line)
        except ValueError:
            return {"raw": line}

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            return self.proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            return None


# ----------------------------------------------------------------------------------
# 1. The public cases, through the real CLI
# ----------------------------------------------------------------------------------
def run_public_cases():
    data = json.loads((FIXTURES / "cases.json").read_text())
    for case in data["cases"]:
        cid = case["id"]
        envs = {}
        captures = {}
        stream_errors = {}

        def env(name):
            if name not in envs:
                envs[name] = Cli()
            return envs[name]

        for n, op in enumerate(case["operations"]):
            name = op.get("on", "main")
            command = copy.deepcopy(op["command"])
            label = "%s op%d(%s)/%s" % (cid, n, name, command.get("op"))
            if "snapshot_from" in op:
                command["snapshot"] = copy.deepcopy(captures[op["snapshot_from"]])
            try:
                response = env(name).send(command)
            except Exception as e:                       # noqa: BLE001
                check(label, False, "CLI failure: %s" % e)
                continue
            expect = op.get("expect", {})
            want_ok = expect.get("ok", True)
            got_ok = response.get("ok") is True
            if got_ok != want_ok:
                check(label, False, "ok=%r, expected %r: %r"
                      % (response.get("ok"), want_ok, response))
            else:
                detail = ""
                good = True
                if not want_ok:
                    if response.get("error") != expect.get("error"):
                        good, detail = False, ("error %r, expected %r"
                                               % (response.get("error"),
                                                  expect.get("error")))
                    stream_errors[name] = True
                else:
                    if stream_errors.get(name):
                        pass
                    if set(response) != {"ok", "result"}:
                        good, detail = False, "response carried %r" % sorted(response)
                    elif "result" in expect:
                        good, detail = compare(response["result"], expect["result"])
                    elif "result_subset" in expect:
                        good, detail = compare(response["result"],
                                               expect["result_subset"], subset=True)
                    if good and "expect_result_equal" in op:
                        good, detail = compare(response["result"],
                                               captures[op["expect_result_equal"]])
                        if good:
                            detail = "restored result differs"
                    if good and not expect.get("result") and \
                            not expect.get("result_subset") and \
                            "expect_result_equal" not in op:
                        # shape-only expectations still get the normative shape
                        res = response["result"]
                        op_name = command.get("op")
                        if op_name in ("drain", "finish"):
                            good = isinstance(res, list)
                        elif op_name == "snapshot":
                            good = (isinstance(res, dict)
                                    and set(res) == {"schema", "state", "sha256"})
                        elif op_name in ("init", "restore"):
                            good = res is None
                        if not good:
                            detail = "unexpected result shape %r" % (res,)
                if good and "capture_result" in op:
                    captures[op["capture_result"]] = copy.deepcopy(
                        json.loads(json.dumps(response["result"])))
                check(label, good, detail)

        for name, proc in sorted(envs.items()):
            code = proc.close()
            want = 1 if stream_errors.get(name) else 0
            check("%s exit(%s)" % (cid, name), code == want,
                  "exit %r, expected %d" % (code, want))


# ----------------------------------------------------------------------------------
# 2. Adapter examples from the same public file
# ----------------------------------------------------------------------------------
class Frame:
    """A lightweight stand-in for a MaskFrame: the fields the adapter reads."""

    def __init__(self, t_s, run, scored, blobs=()):
        self.t_s = t_s
        self.run = run
        self.scored = scored
        self.blobs = tuple(blobs)


def run_adapter_examples():
    data = json.loads((FIXTURES / "cases.json").read_text())
    examples = {e["id"]: e for e in data["adapter_examples"]}
    case = examples["pixel-blob-normalization-and-run-reset"]
    blob = fm.Blob(label=case["blob"]["label"], x=case["blob"]["x"],
                   y=case["blob"]["y"], w=case["blob"]["w"], h=case["blob"]["h"],
                   area=case["blob"]["area"], cx=case["blob"]["cx"],
                   cy=case["blob"]["cy"], frame_w=case["blob"]["frame_w"],
                   frame_h=case["blob"]["frame_h"])
    frame = Frame(case["frame"]["t_s"], case["frame"]["run"],
                  case["frame"]["scored"], [blob])
    args = dict(case["arguments"])
    got = TA.mask_frame_batch(frame, **args)
    ok, why = compare(got, case["expected_batch"])
    check("adapter/pixel-blob-normalization", ok, why)

    for k, variant in enumerate(case["variants"]):
        over = dict(case["frame"]["scored"] and {"scored": frame.scored} or {})
        over.update(variant.get("frame_overrides", {}))
        f = Frame(case["frame"]["t_s"], case["frame"]["run"],
                  over.get("scored", case["frame"]["scored"]), [blob])
        a = dict(args)
        a.update(variant.get("arguments_overrides", {}))
        out = TA.mask_frame_batch(f, **a)
        good = True
        why = ""
        if "expected_detections" in variant:
            good = out["detections"] == variant["expected_detections"]
            why = "detections %r" % (out["detections"],)
        if good and "expected_reset" in variant:
            good = out["reset"] is variant["expected_reset"]
            why = "reset %r" % (out["reset"],)
        check("adapter/variant%d" % k, good, why)

    # labs_rows over the one-object case's own drained episode.
    tracker = TT.Tracker("cam-public", "unit-public", {"path_points": 3})
    for seq, t, x in ((0, 0, 0.15), (1, 1000, 0.2), (2, 2000, 0.25), (3, 3000, 0.3)):
        tracker.feed(batch(seq, t, [det("d%d" % seq, x, 0.3, 0.1, 0.2)],
                           cam="cam-public", unit="unit-public"))
    tracker.finish()
    episodes = tracker.drain()
    wire = examples["labs-wire-preview"]
    from datetime import datetime
    hour_start = datetime.fromisoformat(wire["hour_start"])
    rows = TA.labs_rows(episodes, hour_start=hour_start)
    ok, why = compare(rows, wire["expected_rows"])
    check("adapter/labs-wire-preview", ok, why)

    # The preview's own limits, and that a rejected preview returns nothing.
    big = [dict(episodes[0]) for _ in range(501)]
    check("adapter/labs_rows-500-cap",
          errors_code(TA.labs_rows, big, hour_start=hour_start) == "invalid_input")
    late = copy.deepcopy(episodes)
    late[0]["start_ms"] = 3600000
    check("adapter/labs_rows-outside-hour",
          errors_code(TA.labs_rows, late, hour_start=hour_start) == "invalid_input")
    long_ep = copy.deepcopy(episodes)
    long_ep[0]["end_ms"] = long_ep[0]["start_ms"] + 300000
    long_ep[0]["path"] = [[long_ep[0]["start_ms"], 0.15, 0.3],
                          [long_ep[0]["end_ms"], 0.3, 0.3]]
    long_ep[0]["last_center"] = [0.3, 0.3]
    long_ep[0]["mean_speed"] = 0.001
    long_ep[0]["max_observation_gap_ms"] = 300000
    check("adapter/labs_rows-300s-cap",
          errors_code(TA.labs_rows, long_ep, hour_start=hour_start)
          == "invalid_input")
    check("adapter/labs_rows-naive-hour",
          errors_code(TA.labs_rows, episodes,
                      hour_start=datetime(2026, 10, 4, 3, 0, 0))
          == "invalid_input")
    check("adapter/labs_rows-half-hour",
          errors_code(TA.labs_rows, episodes,
                      hour_start=datetime.fromisoformat("2026-10-04T03:30:00+03:00"))
          == "invalid_input")
    broken = copy.deepcopy(episodes)
    broken[0]["object_class"] = "person"
    check("adapter/labs_rows-rejects-extra-keys",
          errors_code(TA.labs_rows, broken, hour_start=hour_start)
          == "invalid_input")


# ----------------------------------------------------------------------------------
# 3. Contract tests this suite owns
# ----------------------------------------------------------------------------------
def test_validation():
    check("config/defaults",
          TT.Tracker("cam", "unit").config == TT.DEFAULT_CONFIG)
    check("config/unknown-key",
          errors_code(TT.Tracker, "cam", "unit", {"nope": 1}) == "invalid_config")
    check("config/bounds",
          errors_code(TT.Tracker, "cam", "unit", {"gate_base": 0}) == "invalid_config"
          and errors_code(TT.Tracker, "cam", "unit", {"gate_base": 1.5})
          == "invalid_config"
          and errors_code(TT.Tracker, "cam", "unit", {"max_gap_ms": 0})
          == "invalid_config"
          and errors_code(TT.Tracker, "cam", "unit", {"max_gap_ms": 10001})
          == "invalid_config"
          and errors_code(TT.Tracker, "cam", "unit", {"path_points": 1})
          == "invalid_config"
          and errors_code(TT.Tracker, "cam", "unit", {"ambiguity_margin": -1})
          == "invalid_config")
    check("config/pending-vs-tracks",
          errors_code(TT.Tracker, "cam", "unit",
                      {"max_tracks": 4, "max_pending": 2}) == "invalid_config")
    check("config/bool-is-not-a-number",
          errors_code(TT.Tracker, "cam", "unit", {"max_gap_ms": True})
          == "invalid_config")
    check("config/numeric-string",
          errors_code(TT.Tracker, "cam", "unit", {"gate_base": "0.2"})
          == "invalid_config")
    check("config/nan",
          errors_code(TT.Tracker, "cam", "unit", {"gate_base": float("nan")})
          == "invalid_config")
    check("ctor/bad-ids",
          errors_code(TT.Tracker, "", "unit") == "invalid_input"
          and errors_code(TT.Tracker, "cam", "has space") == "invalid_input"
          and errors_code(TT.Tracker, None, "unit") == "invalid_input")

    tr = TT.Tracker("cam-a", "unit-a")
    good = batch(0, 0, [det("d0", 0.3, 0.5)])
    tr.feed(good)
    base = tr.snapshot()
    cases = {
        "not-an-object": "nope",
        "missing-key": {"camera_id": "cam-a", "unit_id": "unit-a", "seq": 1,
                        "t_ms": 100},
        "unknown-key": dict(batch(1, 100, []), extra=1),
        "wrong-scope": batch(1, 100, [], cam="cam-b"),
        "wrong-unit": batch(1, 100, [], unit="unit-b"),
        "bad-detect-key": batch(1, 100, [{"id": "x", "bbox": box(0.3, 0.5),
                                          "label": "person"}]),
        "dup-detect": batch(1, 100, [det("x", 0.3, 0.5), det("x", 0.3, 0.6)]),
        "bad-bbox-wide": batch(1, 100, [{"id": "x", "bbox": [0.5, 0.5, 0.6, 0.1]}]),
        "bad-bbox-zero": batch(1, 100, [{"id": "x", "bbox": [0.5, 0.5, 0, 0.1]}]),
        "bad-bbox-string": batch(1, 100, [{"id": "x", "bbox": ["0.1", 0.1, 0.1,
                                                               0.1]}]),
        "bad-bbox-bool": batch(1, 100, [{"id": "x", "bbox": [True, 0.1, 0.1, 0.1]}]),
        "bbox-nan": batch(1, 100, [{"id": "x", "bbox": [float("nan"), 0, 0.1, 0.1]}]),
        "bbox-inf": batch(1, 100, [{"id": "x", "bbox": [0, 0, float("inf"), 0.1]}]),
        "appearance-short": batch(1, 100, [det("x", 0.3, 0.5, appearance=[1, 0, 0])]),
        "appearance-sum": batch(1, 100, [det("x", 0.3, 0.5,
                                             appearance=[0.5, 0.5, 0.5, 0.5])]),
        "appearance-range": batch(1, 100, [det("x", 0.3, 0.5,
                                               appearance=[2, -1, 0, 0])]),
        "reset-not-bool": batch(1, 100, [], reset=1),
        "seq-float": batch(1.5, 100, []),
        "seq-negative": batch(-1, 100, []),
        "t-negative": batch(1, -1, []),
        "t-string": batch(1, "100", []),
        "seq-gap": batch(2, 100, []),
        "t-not-advancing": batch(1, 0, []),
        "too-many-detections": batch(1, 100,
                                     [det("d%02d" % i, 0.02 + 0.01 * i, 0.5)
                                      for i in range(65)]),
    }
    for name, bad in cases.items():
        code = errors_code(tr.feed, bad)
        want = {"wrong-scope": "wrong_scope", "wrong-unit": "wrong_scope",
                "seq-gap": "sequence_error", "t-not-advancing": "sequence_error",
                "too-many-detections": "invalid_input"}.get(name, "invalid_input")
        check("validate/%s" % name, code == want, "code=%r want %r" % (code, want))
    check("validate/state-intact", tr.snapshot() == base)
    check("validate/finished-after-bad-input",
          TT.Tracker.restore(base).finished is False)


def test_ordering_and_determinism():
    tr = TT.Tracker("cam-a", "unit-a")
    r1 = tr.feed(batch(0, 0, [det("b", 0.7, 0.5), det("a", 0.3, 0.5)]))
    check("order/assignments-sorted",
          [a["detection_id"] for a in r1["assignments"]] == ["a", "b"])
    check("order/ids-by-detection-id",
          r1["assignments"][0]["track_id"] == "t00000001"
          and r1["assignments"][1]["track_id"] == "t00000002")
    # The same geometry with the detection list and the detection names
    # permuted must produce the same tracks, not the same labels.
    other = TT.Tracker("cam-a", "unit-a")
    other.feed(batch(0, 0, [det("a", 0.3, 0.5), det("b", 0.7, 0.5)]))
    r2 = other.feed(batch(1, 1000, [det("y", 0.7, 0.5), det("x", 0.3, 0.5)]))
    check("order/permutation-same-tracks",
          [(a["detection_id"], a["track_id"]) for a in r2["assignments"]]
          == [("x", "t00000001"), ("y", "t00000002")], repr(r2["assignments"]))
    check("order/assignment-keys-exact",
          all(set(a) == {"detection_id", "track_id", "status", "reason"}
              for a in r1["assignments"])
          and set(r1) == {"seq", "replayed", "assignments", "closed"})


def test_association_quality():
    # Greedy takes the individually cheapest edge and loses a track here; the
    # contract's maximum-cardinality matching keeps both.
    tr = TT.Tracker("cam-a", "unit-a")
    tr.feed(batch(0, 0, [det("a", 0.15, 0.45, 0.1, 0.1),
                         det("b", 0.35, 0.45, 0.1, 0.1)]))
    r = tr.feed(batch(1, 1000, [det("middle", 0.24, 0.45, 0.1, 0.1),
                                det("left", 0.05, 0.45, 0.1, 0.1)]))
    got = {a["detection_id"]: a["track_id"] for a in r["assignments"]}
    check("assoc/max-cardinality", got == {"left": "t00000001",
                                           "middle": "t00000002"}, repr(got))

    # Prediction: a track moving +0.05/s for 1 s is predicted at +0.05, so the
    # nearest detection to the PREDICTION wins, not the one nearest the last box.
    tr = TT.Tracker("cam-a", "unit-a")
    tr.feed(batch(0, 0, [det("a", 0.30, 0.5)]))
    tr.feed(batch(1, 1000, [det("b", 0.35, 0.5)]))
    r = tr.feed(batch(2, 2000, [det("c", 0.40, 0.5), det("stale", 0.30, 0.5)]))
    got = {a["detection_id"]: a["track_id"] for a in r["assignments"]}
    check("assoc/velocity-prediction",
          got.get("c") == "t00000001" and got.get("stale") != "t00000001", repr(got))

    # A track that coasts one batch keeps its velocity through the gap.
    tr = TT.Tracker("cam-a", "unit-a")
    tr.feed(batch(0, 0, [det("a", 0.20, 0.5)]))
    tr.feed(batch(1, 1000, [det("b", 0.25, 0.5)]))
    tr.feed(batch(2, 2000, []))
    r = tr.feed(batch(3, 3000, [det("c", 0.35, 0.5)]))
    check("assoc/coasting-keeps-velocity",
          r["assignments"][0]["track_id"] == "t00000001", repr(r))

    # The speed cap: 0.9/s of real motion cannot be predicted past max_speed.
    tr = TT.Tracker("cam-a", "unit-a", {"max_speed": 0.05})
    tr.feed(batch(0, 0, [det("a", 0.10, 0.5, 0.02, 0.02)]))
    tr.feed(batch(1, 1000, [det("b", 0.20, 0.5, 0.02, 0.02)]))
    # Uncapped the prediction would be 0.30; capped it is 0.25 (0.05/s * 1 s).
    r = tr.feed(batch(2, 2000, [det("at-cap", 0.25, 0.5, 0.02, 0.02),
                                det("uncapped", 0.30, 0.5, 0.02, 0.02)]))
    got = {a["detection_id"]: a["track_id"] for a in r["assignments"]}
    check("assoc/max-speed-cap", got.get("at-cap") == "t00000001", repr(got))

    # The area gate is inclusive at both ends and rejects one step beyond.
    tr = TT.Tracker("cam-a", "unit-a", {"max_area_ratio": 4.0})
    tr.feed(batch(0, 0, [det("a", 0.5, 0.5, 0.02, 0.02)]))
    r = tr.feed(batch(1, 1000, [det("grow", 0.5, 0.5, 0.04, 0.02)]))
    check("gate/area-inclusive", r["assignments"][0]["status"] == "matched")
    r = tr.feed(batch(2, 2000, [det("grow", 0.5, 0.5, 0.2, 0.02)]))
    check("gate/area-beyond", r["assignments"][0]["status"] == "born",
          repr(r["assignments"][0]))

    # Appearance: a distinguishable histogram preserves identity through a
    # crossing; an over-gate mismatch makes the pair infeasible.
    tr = TT.Tracker("cam-a", "unit-a")
    tr.feed(batch(0, 0, [det("a", 0.4, 0.5, appearance=[1, 0, 0, 0])]))
    r = tr.feed(batch(1, 1000, [det("b", 0.45, 0.5, appearance=[0, 1, 0, 0])]))
    check("gate/appearance", r["assignments"][0]["status"] == "born",
          repr(r["assignments"][0]))

    # A tie within ambiguity_margin abstains; beyond it, the cheaper match wins.
    tr = TT.Tracker("cam-a", "unit-a", {"ambiguity_margin": 1000000})
    tr.feed(batch(0, 0, [det("a", 0.3, 0.5), det("b", 0.7, 0.5)]))
    r = tr.feed(batch(1, 1000, [det("m", 0.5, 0.5)]))
    check("ambiguity/wide-margin-abstains",
          r["assignments"][0]["status"] == "ambiguous"
          and r["assignments"][0]["reason"] == "cost_tie", repr(r["assignments"][0]))
    tr2 = TT.Tracker("cam-a", "unit-a", {"ambiguity_margin": 0})
    tr2.feed(batch(0, 0, [det("a", 0.3, 0.5), det("b", 0.7, 0.5)]))
    r2 = tr2.feed(batch(1, 1000, [det("m", 0.5, 0.5)]))
    check("ambiguity/zero-margin-still-ties",
          r2["assignments"][0]["status"] == "ambiguous", repr(r2["assignments"][0]))
    # Margin 0 with an actually cheaper alternative: resolve it, do not abstain.
    tr3 = TT.Tracker("cam-a", "unit-a", {"ambiguity_margin": 0})
    tr3.feed(batch(0, 0, [det("a", 0.30, 0.5), det("b", 0.70, 0.5)]))
    r3 = tr3.feed(batch(1, 1000, [det("m", 0.45, 0.5)]))
    check("ambiguity/clear-winner",
          r3["assignments"][0]["status"] == "matched"
          and r3["assignments"][0]["track_id"] == "t00000001",
          repr(r3["assignments"][0]))

    # A merge abstains and takes precedence over the tie.
    tr = TT.Tracker("cam-a", "unit-a", {"gate_base": 0.5, "max_area_ratio": 100})
    tr.feed(batch(0, 0, [det("a", 0.30, 0.5), det("b", 0.70, 0.5)]))
    r = tr.feed(batch(1, 1000, [det("wide", 0.5, 0.5, 0.48, 0.24)]))
    check("ambiguity/merge-precedence",
          r["assignments"][0]["status"] == "ambiguous"
          and r["assignments"][0]["reason"] == "merge", repr(r["assignments"][0]))
    tr.finish()
    eps = tr.drain()
    check("ambiguity/merge-adds-no-evidence",
          all(e["observations"] == 1 and e["ambiguous_batches"] == 1
              for e in eps), repr(eps))
    check("ambiguity/merge-end-at-last-observation",
          all(e["start_ms"] == 0 and e["end_ms"] == 0 for e in eps))

    # An isolated detection with no feasible edge still starts a track.
    tr = TT.Tracker("cam-a", "unit-a")
    tr.feed(batch(0, 0, [det("a", 0.1, 0.5)]))
    r = tr.feed(batch(1, 1000, [det("far", 0.9, 0.9)]))
    check("assoc/isolated-detection-born",
          r["assignments"][0]["status"] == "born", repr(r["assignments"][0]))


def test_time_and_lifecycle():
    tr = TT.Tracker("cam-a", "unit-a", {"max_gap_ms": 1000, "max_span_ms": 1500})
    tr.feed(batch(0, 0, [det("a", 0.3, 0.5)]))
    r = tr.feed(batch(1, 1000, [det("b", 0.3, 0.5)]))
    check("time/gap-equality-retained",
          r["assignments"][0]["track_id"] == "t00000001" and r["closed"] == [])
    r = tr.feed(batch(2, 1500, [det("c", 0.3, 0.5)]))
    check("time/span-equality-retained", r["closed"] == [])
    r = tr.feed(batch(3, 1501, [det("d", 0.3, 0.5)]))
    check("time/span-beyond-closes",
          r["closed"] == ["t00000001"] and r["assignments"][0]["track_id"]
          == "t00000002", repr(r))
    tr.finish()
    eps = {e["track_id"]: e for e in tr.drain()}
    check("time/span-reason-and-end",
          eps["t00000001"]["reason"] == "span" and eps["t00000001"]["end_ms"] == 1500,
          repr(eps["t00000001"]))

    # A gap beats a span when both are exceeded, and closes at the last evidence.
    tr = TT.Tracker("cam-a", "unit-a", {"max_gap_ms": 100, "max_span_ms": 50})
    tr.feed(batch(0, 0, [det("a", 0.3, 0.5)]))
    r = tr.feed(batch(1, 200, [det("b", 0.3, 0.5)]))
    check("time/gap-precedence",
          r["closed"] == ["t00000001"] and r["assignments"][0]["track_id"]
          == "t00000002", repr(r))
    tr.finish()
    ep = tr.drain()[0]
    check("time/gap-reason", ep["reason"] == "gap" and ep["end_ms"] == 0)

    # Reset closes every active track at its own last observation and births.
    tr = TT.Tracker("cam-a", "unit-a")
    tr.feed(batch(0, 0, [det("a", 0.3, 0.5), det("b", 0.7, 0.5)]))
    tr.feed(batch(1, 500, [det("a2", 0.3, 0.5), det("b2", 0.7, 0.5)]))
    r = tr.feed(batch(2, 1000, [det("c", 0.3, 0.5)], reset=True))
    check("time/reset-closes-all",
          sorted(r["closed"]) == ["t00000001", "t00000002"]
          and r["assignments"][0]["track_id"] == "t00000003", repr(r))
    tr.finish()
    eps = {e["track_id"]: e for e in tr.drain()}
    check("time/reset-ends-at-evidence",
          eps["t00000001"]["reason"] == "reset" and eps["t00000001"]["end_ms"] == 500
          and eps["t00000002"]["end_ms"] == 500)

    # An empty batch advances time and can expire a track.
    tr = TT.Tracker("cam-a", "unit-a", {"max_gap_ms": 100})
    tr.feed(batch(0, 0, [det("a", 0.3, 0.5)]))
    r = tr.feed(batch(1, 100, []))
    check("time/empty-equal-gap", r["assignments"] == [] and r["closed"] == [])
    r = tr.feed(batch(2, 101, []))
    check("time/empty-advances-time", r["closed"] == ["t00000001"], repr(r))

    # finish is idempotent and seals; drain and snapshot still work.
    tr = TT.Tracker("cam-a", "unit-a")
    tr.feed(batch(0, 0, [det("a", 0.3, 0.5)]))
    check("life/finish-ids", tr.finish() == ["t00000001"])
    check("life/finish-twice", tr.finish() == [])
    check("life/feed-after-finish",
          errors_code(tr.feed, batch(1, 1000, [det("b", 0.3, 0.5)])) == "finished")
    check("life/replay-after-finish",
          errors_code(tr.feed, batch(0, 0, [det("a", 0.3, 0.5)])) == "finished")
    check("life/drain-after-finish", len(tr.drain()) == 1 and tr.drain() == [])
    check("life/snapshot-after-finish",
          tr.snapshot()["state"]["finished"] is True)

    # A capacity failure at finish leaves the tracker open and intact.
    tr = TT.Tracker("cam-a", "unit-a", {"max_tracks": 2, "max_pending": 2,
                                        "max_gap_ms": 100})
    tr.feed(batch(0, 0, [det("a", 0.2, 0.5), det("b", 0.8, 0.5)]))
    tr.feed(batch(1, 200, [det("c", 0.2, 0.5), det("d", 0.8, 0.5)]))
    before = tr.snapshot()
    check("life/finish-capacity", errors_code(tr.finish) == "capacity")
    check("life/finish-capacity-atomic", tr.snapshot() == before)
    tr.drain()
    check("life/finish-after-drain", tr.finish() == ["t00000003", "t00000004"])
    check("life/finish-after-drain-results",
          [e["track_id"] for e in tr.drain()] == ["t00000003", "t00000004"])


def test_episode_evidence():
    tr = TT.Tracker("cam-a", "unit-a", {"path_points": 3})
    # Four collinear observations: the interior sample with the smallest cross
    # product goes first, earliest wins the tie -> t=1000 leaves.
    for seq, t, x in ((0, 0, 0.1), (1, 1000, 0.2), (2, 2000, 0.3), (3, 3000, 0.4)):
        tr.feed(batch(seq, t, [det("d", x, 0.5, 0.1, 0.1)]))
    tr.finish()
    ep = tr.drain()[0]
    check("evidence/path-tie-removes-earliest",
          [p[0] for p in ep["path"]] == [0, 2000, 3000], repr(ep["path"]))
    check("evidence/counts-ignore-bounding",
          ep["observations"] == 4 and ep["max_observation_gap_ms"] == 1000)
    check("evidence/path-length-full",
          abs(ep["path_length"] - 0.3) < 1e-9 and abs(ep["mean_speed"] - 0.1) < 1e-9,
          repr((ep["path_length"], ep["mean_speed"])))
    check("evidence/bbox-largest-earliest-tie",
          ep["bbox"] == box(0.1, 0.5, 0.1, 0.1) and ep["bbox_at_ms"] == 0)

    # A zig-zag: the corner that carries the shape must survive the bounding.
    tr = TT.Tracker("cam-a", "unit-a", {"path_points": 5})
    pts = [(0.10, 0.10), (0.15, 0.20), (0.20, 0.10), (0.25, 0.10), (0.30, 0.10),
           (0.35, 0.10)]
    for seq, (x, y) in enumerate(pts):
        tr.feed(batch(seq, seq * 1000, [det("d", x, y, 0.04, 0.04)]))
    tr.finish()
    ep = tr.drain()[0]
    times = [p[0] for p in ep["path"]]
    check("evidence/path-bounded-to-config", len(ep["path"]) == 5, repr(times))
    check("evidence/path-keeps-endpoints",
          times[0] == 0 and times[-1] == 5000, repr(times))
    check("evidence/path-keeps-corner", 2000 in times, repr(times))
    check("evidence/path-samples-are-observations",
          all(any(abs(p[1] - x) < 1e-12 and abs(p[2] - y) < 1e-12
                  for (x, y) in pts) for p in ep["path"]), repr(ep["path"]))

    # Duplicate and empty batches never invent observations.
    tr = TT.Tracker("cam-a", "unit-a", {"max_gap_ms": 1000})
    tr.feed(batch(0, 0, [det("a", 0.3, 0.5)]))
    tr.feed(batch(1, 500, []))
    tr.feed(batch(2, 1000, []))
    tr.finish()
    ep = tr.drain()[0]
    check("evidence/empty-batches-no-observations",
          ep["observations"] == 1 and ep["path"] == [[0, 0.3, 0.5]]
          and ep["max_observation_gap_ms"] == 0, repr(ep))
    check("evidence/single-observation-speed-null", ep["mean_speed"] is None)


def test_replay_and_atomicity():
    tr = TT.Tracker("cam-a", "unit-a", {"replay_batches": 2, "max_pending": 4,
                                        "max_tracks": 2, "max_gap_ms": 1000})
    tr.feed(batch(0, 0, [det("a", 0.2, 0.5), det("b", 0.8, 0.5)]))
    before = tr.snapshot()
    check("capacity/tracks", errors_code(tr.feed, batch(1, 100, [det("c", 0.5, 0.9)]))
          == "capacity")
    check("capacity/tracks-atomic", tr.snapshot() == before)
    check("capacity/tracks-still-full",
          errors_code(tr.feed, batch(1, 100, [det("c", 0.5, 0.9)])) == "capacity")
    # Expiring a track frees the slot, and the rejected batch left no trace.
    r = tr.feed(batch(1, 1200, [det("c", 0.5, 0.9)]))
    check("capacity/slot-reused-after-expiry",
          sorted(r["closed"]) == ["t00000001", "t00000002"]
          and r["assignments"][0]["track_id"] == "t00000003", repr(r))

    tr = TT.Tracker("cam-a", "unit-a", {"replay_batches": 1, "max_gap_ms": 100})
    tr.feed(batch(0, 0, [det("a", 0.3, 0.5)]))
    tr.feed(batch(1, 200, [det("b", 0.3, 0.5)]))
    tr.drain()
    r = tr.feed(batch(1, 200, [det("b", 0.3, 0.5)]))
    check("replay/returns-original-receipt",
          r["replayed"] is True and r["closed"] == ["t00000001"]
          and r["assignments"][0]["track_id"] == "t00000002", repr(r))
    check("replay/does-not-requeue", tr.drain() == [])
    # Equivalent lexical forms, explicit optional defaults and a permuted
    # detection list are the same normalised input.
    lex = TT.Tracker("cam-a", "unit-a")
    lex.feed({"camera_id": "cam-a", "unit_id": "unit-a", "seq": 0, "t_ms": 0,
              "detections": [{"id": "b", "bbox": [0.68, 0, 0.04, 0.04]},
                             {"id": "a", "bbox": [0.28, 0, 0.04, 0.04]}]})
    r = lex.feed({"camera_id": "cam-a", "unit_id": "unit-a", "seq": 0.0,
                  "t_ms": 0.0, "reset": False,
                  "detections": [{"id": "a", "bbox": [0.28, 0.0, 0.04, 0.04],
                                  "appearance": None},
                                 {"id": "b", "bbox": [0.68, 0.0, 0.04, 0.04],
                                  "appearance": None}]})
    check("replay/normalised-equivalence", r["replayed"] is True, repr(r))
    check("replay/reset-is-content",
          errors_code(lex.feed,
                      {"camera_id": "cam-a", "unit_id": "unit-a", "seq": 0,
                       "t_ms": 0, "reset": True,
                       "detections": [{"id": "a", "bbox": [0.28, 0, 0.04, 0.04]},
                                      {"id": "b",
                                       "bbox": [0.68, 0, 0.04, 0.04]}]})
          == "replay_conflict")
    check("replay/conflict",
          errors_code(tr.feed, batch(1, 200, [det("b", 0.31, 0.5)]))
          == "replay_conflict")
    check("replay/stale",
          errors_code(tr.feed, batch(0, 0, [det("a", 0.3, 0.5)])) == "stale_replay")
    check("replay/no-rewind-after-stale",
          errors_code(tr.feed, batch(0, 0, [det("a", 0.3, 0.5)])) == "stale_replay")
    check("replay/no-rewind-does-not-requeue", tr.drain() == [])

    # A rejected operation must not move the replay window or the clock.
    tr = TT.Tracker("cam-a", "unit-a", {"replay_batches": 1, "max_gap_ms": 100,
                                        "max_tracks": 2, "max_pending": 4})
    tr.feed(batch(0, 0, [det("a", 0.3, 0.5)]))
    snap = tr.snapshot()
    check("atomic/reject-keeps-clock",
          errors_code(tr.feed, batch(1, 100, [det("f1", 0.9, 0.1),
                                              det("f2", 0.1, 0.9)])) == "capacity")
    check("atomic/reject-keeps-window", tr.snapshot() == snap)
    check("atomic/reject-keeps-next-id",
          tr.feed(batch(1, 100, [det("far", 0.9, 0.1)]))
          ["assignments"][0]["track_id"] == "t00000002",
          repr(tr.snapshot()["state"]["next_index"]))


def test_aliasing():
    tr = TT.Tracker("cam-a", "unit-a", {"max_gap_ms": 100})
    r = tr.feed(batch(0, 0, [det("a", 0.3, 0.5)]))
    r["assignments"][0]["track_id"] = "mutated"
    r["closed"].append("mutated")
    r["assignments"].append({"detection_id": "ghost"})
    replay = tr.feed(batch(0, 0, [det("a", 0.3, 0.5)]))
    check("alias/receipt-is-a-copy",
          replay["replayed"] is True and replay["closed"] == []
          and replay["assignments"] == [{"detection_id": "a",
                                          "track_id": "t00000001",
                                          "status": "born", "reason": None}],
          repr(replay))
    live = tr.snapshot()
    live["state"]["tracks"][0]["last_box"][0] = 0.99
    check("alias/snapshot-ignores-later-mutation",
          tr.snapshot()["state"]["tracks"][0]["last_box"][0] == box(0.3, 0.5)[0])
    tr.feed(batch(1, 100, []))
    tr.finish()
    queued = tr.snapshot()
    eps = tr.drain()
    eps[0]["track_id"] = "mutated"
    eps[0]["path"].append([1, 2, 3])
    eps[0]["bbox"][0] = 9.0
    rest = TT.Tracker.restore(queued)
    rest_state = rest.snapshot()["state"]
    check("alias/drained-episode-independent",
          rest_state["outbox"][0]["track_id"] == "t00000001"
          and rest_state["outbox"][0]["bbox"][0] == box(0.3, 0.5)[0]
          and rest_state["outbox"][0]["path"] == [[0, 0.3, 0.5]],
          repr(rest_state["outbox"][0]))
    snap = tr.snapshot()
    snap["state"]["camera_id"] = "mutated"
    snap["state"]["tracks"].append({})
    check("alias/snapshot-is-a-copy", tr.snapshot()["state"]["camera_id"] == "cam-a")
    cfg = tr.config
    cfg["max_gap_ms"] = 1
    check("alias/config-is-a-copy", tr.config["max_gap_ms"] == 100)
    # A second drain returns independent objects.
    tr2 = TT.Tracker("cam-a", "unit-a")
    tr2.feed(batch(0, 0, [det("a", 0.3, 0.5)]))
    tr2.finish()
    first = tr2.drain()
    first[0]["observations"] = 99
    check("alias/drain-empties-the-outbox",
          tr2.drain() == [] and tr2.snapshot()["state"]["outbox"] == [])


def test_checkpoints():
    tr = TT.Tracker("cam-a", "unit-a", {"max_gap_ms": 1000, "path_points": 4})
    for seq, t, x in ((0, 0, 0.1), (1, 300, 0.16), (2, 600, 0.22)):
        tr.feed(batch(seq, t, [det("d", x, 0.5)]))
    snap = tr.snapshot()
    check("snapshot/envelope",
          set(snap) == {"schema", "state", "sha256"}
          and snap["schema"] == "labs-temporal-tracker/v1")
    round_tripped = json.loads(json.dumps(snap))
    restored = TT.Tracker.restore(round_tripped)
    check("snapshot/independent-new-tracker",
          restored.snapshot() == snap)
    r1 = tr.feed(batch(3, 900, [det("e", 0.28, 0.5)]))
    r2 = restored.feed(batch(3, 900, [det("e", 0.28, 0.5)]))
    check("snapshot/continuation-receipt", r1 == r2)
    check("snapshot/continuation-snapshot", tr.snapshot() == restored.snapshot())
    tr.finish()
    restored.finish()
    check("snapshot/continuation-episodes", tr.drain() == restored.drain())
    check("snapshot/continuation-snapshot-after",
          tr.snapshot() == restored.snapshot())

    # The same state must serialise to the same bytes (canonical digest).
    check("snapshot/canonical-digest",
          TT.Tracker.restore(json.loads(json.dumps(snap))).snapshot()["sha256"]
          == snap["sha256"])

    # Corruption: bad envelope shapes, and leaf mutations with the checksum
    # recomputed over the mutated state.
    base = TT.Tracker("cam-a", "unit-a", {"max_pending": 4, "max_tracks": 4})
    base.feed(batch(0, 0, [det("a", 0.3, 0.5)]))
    base.feed(batch(1, 200, [det("b", 0.9, 0.9)]))
    base.drain()
    good = base.snapshot()
    bad = [
        ("not-an-object", 5),
        ("missing-sha", {"schema": good["schema"], "state": good["state"]}),
        ("extra-key", dict(good, extra=1)),
        ("bad-schema", dict(good, schema="labs-temporal-tracker/v2")),
        ("bad-digest", dict(good, sha256="0" * 63)),
        ("upper-digest", dict(good, sha256=good["sha256"].upper())),
        ("not-hex", dict(good, sha256="z" * 64)),
        ("corrupt-state", dict(good, state=dict(good["state"], next_index=999))),
    ]
    for name, value in bad:
        check("snapshot/reject/%s" % name,
              errors_code(TT.Tracker.restore, value) == "invalid_snapshot")
    mutated = [
        ("next_index-zero", {"next_index": 0}),
        ("next_index-string", {"next_index": "1"}),
        ("next_index-nan", {"next_index": float("nan")}),
        ("finished-string", {"finished": "yes"}),
        ("last_seq-negative", {"last_seq": -1}),
        ("last_t_ms-null", {"last_t_ms": None}),
        ("drop-key", {"camera_id": None}),
        ("tracks-not-list", {"tracks": {}}),
        ("outbox-not-list", {"outbox": 3}),
        ("replay-not-list", {"replay": "x"}),
        ("config-not-object", {"config": 4}),
        ("config-bad-value", {"config": dict(good["state"]["config"],
                                             max_tracks=0)}),
        ("config-unknown-key", {"config": dict(good["state"]["config"], z=1)}),
    ]
    for name, patch in mutated:
        state = json.loads(json.dumps(good["state"]))
        for key, value in patch.items():
            if value is None and key in ("camera_id", "drop-key"):
                state.pop("camera_id", None)
            else:
                state[key] = value
        try:
            candidate = resign({"schema": good["schema"], "state": state,
                                "sha256": good["sha256"]})
        except ValueError:
            continue                       # NaN is not canonically serialisable
        check("snapshot/reject-resigned/%s" % name,
              errors_code(TT.Tracker.restore, candidate) == "invalid_snapshot")
    track_state = json.loads(json.dumps(good["state"]))
    if track_state["tracks"]:
        track_state["tracks"][0]["obs"] = 0
        check("snapshot/reject-resigned/track-obs-zero",
              errors_code(TT.Tracker.restore,
                          resign({"schema": good["schema"], "state": track_state,
                                  "sha256": good["sha256"]}))
              == "invalid_snapshot")
    # Bounded state: the replay window and the outbox obey their configuration.
    tr = TT.Tracker("cam-a", "unit-a", {"replay_batches": 3, "path_points": 2})
    for seq in range(50):
        tr.feed(batch(seq, seq * 100, [det("d", 0.3, 0.5)]))
    state = tr.snapshot()["state"]
    check("snapshot/bounded-replay", len(state["replay"]) == 3)
    check("snapshot/bounded-paths",
          all(len(t["path"]) <= 2 for t in state["tracks"]))
    check("snapshot/checkpoint-size", len(json.dumps(tr.snapshot())) < 2097152)


def test_matching_exactness():
    """The matching and the ambiguity test, against brute force.

    Association is where a plausible-looking implementation can be quietly
    wrong -- greedy nearest-neighbour, a cost tie treated as a match, or an
    alternative matching missed -- and the public fixtures only cover small
    instances. These are exhaustive comparisons on random small graphs.
    """
    import itertools
    import random

    def all_matchings(nt, nd, edges):
        """Every matching, as a tuple of (track, detection) pairs."""
        by_track = [[] for _ in range(nt)]
        for (ti, di, c) in edges:
            by_track[ti].append((di, c))
        out = []
        used = [False] * nd
        chosen = []

        def walk(ti):
            if ti == nt:
                out.append(tuple(chosen))
                return
            walk(ti + 1)                          # this track unmatched
            for (di, c) in by_track[ti]:
                if not used[di]:
                    used[di] = True
                    chosen.append((ti, di, c))
                    walk(ti + 1)
                    chosen.pop()
                    used[di] = False

        walk(0)
        return out

    rng = random.Random(20261004)
    bad = []
    for trial in range(400):
        nt = rng.randint(0, 4)
        nd = rng.randint(0, 4)
        edges = []
        for ti in range(nt):
            for di in range(nd):
                if rng.random() < 0.55:
                    edges.append((ti, di, rng.randint(0, 5000)))
        flow, cost, matched = TT._min_cost_matching(nt, nd, edges)
        matchings = all_matchings(nt, nd, edges)
        sizes = [len(m) for m in matchings]
        best_size = max(sizes) if sizes else 0
        best_cost = min(sum(c for (_t, _d, c) in m) for m in matchings
                        if len(m) == best_size) if matchings else 0
        if flow != best_size or cost != best_cost:
            bad.append(("solve", trial, edges, flow, cost, best_size, best_cost))
            continue
        mset = set(matched)
        if (len(mset) != flow
                or not mset <= {(t, d) for (t, d, _c) in edges}
                or len({t for (t, _d) in matched}) != flow
                or len({d for (_t, d) in matched}) != flow):
            bad.append(("pairs", trial, edges, matched))
            continue
        for margin in (0, 1000, 100000):
            mine = TT.Tracker._alternative(nt, nd, edges, list(matched), cost,
                                           margin)
            want = any(len(m) == best_size
                       and {(t, d) for (t, d, _c) in m} != mset
                       and sum(c for (_t, _d, c) in m) <= cost + margin
                       for m in matchings)
            if mine != want:
                bad.append(("ambiguity", trial, edges, margin, mine, want))
                break
    check("matching/brute-force-400-graphs", not bad,
          "%d disagreement(s), first %r" % (len(bad), bad[0] if bad else None))

    # A composed graph must not be solved as one blob: two disjoint pairs are
    # two components, each unambiguous on its own.
    tr = TT.Tracker("cam-a", "unit-a")
    tr.feed(batch(0, 0, [det("a", 0.2, 0.5), det("b", 0.8, 0.5)]))
    r = tr.feed(batch(1, 500, [det("a1", 0.2, 0.5), det("b1", 0.8, 0.5)]))
    check("matching/disjoint-components",
          [a["status"] for a in r["assignments"]] == ["matched", "matched"],
          repr(r["assignments"]))


def test_path_simplifier_checkpoint():
    """A saturated path must simplify identically after a restore.

    The simplifier is maintained incrementally; a restore recomputes its cross
    products. If the two ever disagreed, a resumed tracker would drop a
    different sample and its episodes would stop matching uninterrupted
    execution -- so this runs a saturating trajectory through both.
    """
    def zigzag(n):
        # A wandering centre that keeps the simplifier busy without leaving the
        # default gate's reach at 1 s spacing.
        x = 0.30 + 0.05 * math.sin(n * 0.7) + 0.01 * math.cos(n * 2.3)
        y = 0.50 + 0.05 * math.cos(n * 0.9)
        return x, y

    def feed(tr, lo, hi):
        for n in range(lo, hi):
            x, y = zigzag(n)
            tr.feed(batch(n, 1000 * n, [det("d", x, y, 0.04, 0.04)]))

    for points in (3, 4, 8):
        whole = TT.Tracker("cam-a", "unit-a", {"path_points": points})
        feed(whole, 0, 40)
        split = TT.Tracker.restore(json.loads(json.dumps(whole.snapshot())))
        feed(whole, 40, 60)
        feed(split, 40, 60)
        check("path/checkpoint-receipts-match-p%d" % points,
              whole.snapshot() == split.snapshot())
        whole.finish()
        split.finish()
        check("path/checkpoint-episodes-match-p%d" % points,
              whole.drain() == split.drain())
        ep = whole.snapshot()["state"]
        check("path/checkpoint-bounded-p%d" % points, ep == ep)


def test_contract_edges():
    # Reset on a batch that also expires: reset wins the reason.
    tr = TT.Tracker("cam-a", "unit-a", {"max_gap_ms": 10})
    tr.feed(batch(0, 0, [det("a", 0.3, 0.5)]))
    r = tr.feed(batch(1, 100000, [det("b", 0.3, 0.5)], reset=True))
    tr.finish()
    ep = tr.drain()[0]
    check("edges/reset-beats-gap", ep["reason"] == "reset" and ep["end_ms"] == 0,
          repr(ep))

    # max_span counts from the FIRST observation, gap from the LAST.
    tr = TT.Tracker("cam-a", "unit-a", {"max_gap_ms": 1000, "max_span_ms": 2500})
    for seq in range(5):
        tr.feed(batch(seq, seq * 600, [det("d", 0.3, 0.5)]))
    r = tr.feed(batch(5, 3000, [det("e", 0.3, 0.5)]))
    check("edges/span-from-first", r["closed"] == ["t00000001"], repr(r))
    tr.finish()
    check("edges/span-episode", tr.drain()[0]["reason"] == "span")

    # A detection may not silently join a closed track.
    tr = TT.Tracker("cam-a", "unit-a", {"max_gap_ms": 100})
    tr.feed(batch(0, 0, [det("a", 0.3, 0.5)]))
    r = tr.feed(batch(1, 500, [det("b", 0.3, 0.5)]))
    check("edges/closed-tracks-never-reattach",
          r["closed"] == ["t00000001"] and r["assignments"][0]["status"] == "born"
          and r["assignments"][0]["track_id"] == "t00000002", repr(r))

    # The largest box is chosen by AREA, and the earliest wins an exact tie.
    tr = TT.Tracker("cam-a", "unit-a")
    tr.feed(batch(0, 0, [det("a", 0.3, 0.5, 0.04, 0.04)]))
    tr.feed(batch(1, 500, [det("b", 0.3, 0.5, 0.08, 0.04)]))
    tr.feed(batch(2, 1000, [det("c", 0.3, 0.5, 0.04, 0.16)]))
    tr.finish()
    ep = tr.drain()[0]
    check("edges/bbox-largest-area-not-largest-side",
          ep["bbox"] == box(0.3, 0.5, 0.04, 0.16) and ep["bbox_at_ms"] == 1000,
          repr((ep["bbox"], ep["bbox_at_ms"])))
    # Equal areas tie to the EARLIEST box, not the latest.
    tr = TT.Tracker("cam-a", "unit-a")
    tr.feed(batch(0, 0, [det("a", 0.3, 0.5, 0.04, 0.04)]))
    tr.feed(batch(1, 500, [det("b", 0.3, 0.5, 0.08, 0.02)]))
    tr.finish()
    ep = tr.drain()[0]
    check("edges/bbox-tie-earliest",
          ep["bbox"] == box(0.3, 0.5, 0.04, 0.04) and ep["bbox_at_ms"] == 0,
          repr((ep["bbox"], ep["bbox_at_ms"])))

    # Every accepted detection is counted once, whatever the bounding does.
    tr = TT.Tracker("cam-a", "unit-a", {"path_points": 2})
    for seq in range(9):
        tr.feed(batch(seq, seq * 200, [det("d", 0.3 + 0.01 * seq, 0.5)]))
    tr.finish()
    ep = tr.drain()[0]
    check("edges/observation-accounting",
          ep["observations"] == 9 and len(ep["path"]) == 2
          and ep["max_observation_gap_ms"] == 200, repr(ep))

    # Cross-batch duplicate detection IDs are fine; they are not identities.
    tr = TT.Tracker("cam-a", "unit-a")
    both = tr.feed(batch(0, 0, [det("same", 0.3, 0.5), det("other", 0.7, 0.5)]))
    r = tr.feed(batch(1, 500, [det("same", 0.3, 0.5)]))
    check("edges/repeated-detection-ids-ok",
          both["assignments"][0]["status"] == "born"
          and r["assignments"][0]["status"] == "matched")

    # finish() must order by (start_ms, track_id) across mixed start times.
    tr = TT.Tracker("cam-a", "unit-a", {"max_gap_ms": 10000})
    tr.feed(batch(0, 0, [det("a", 0.2, 0.2)]))
    tr.feed(batch(1, 100, [det("b", 0.8, 0.8)]))
    check("edges/finish-order", tr.finish() == ["t00000001", "t00000002"])
    check("edges/drain-order",
          [e["track_id"] for e in tr.drain()] == ["t00000001", "t00000002"])

    # The adapter refuses malformed frames without touching blob payloads.
    class Bad:
        pass
    f = Bad()
    f.t_s, f.run, f.scored, f.blobs = -1.0, 0, True, ()
    check("edges/adapter-negative-time",
          errors_code(TA.mask_frame_batch, f, camera_id="cam-a",
                      unit_id="unit-a", seq=0) == "invalid_input")
    f.t_s, f.run, f.scored, f.blobs = 0.0, 0, "yes", ()
    check("edges/adapter-scored-not-bool",
          errors_code(TA.mask_frame_batch, f, camera_id="cam-a",
                      unit_id="unit-a", seq=0) == "invalid_input")
    f.t_s, f.run, f.scored, f.blobs = 0.0, -1, True, ()
    check("edges/adapter-negative-run",
          errors_code(TA.mask_frame_batch, f, camera_id="cam-a",
                      unit_id="unit-a", seq=0) == "invalid_input")
    f.t_s, f.run, f.scored, f.blobs = 0.0, 0, True, (fm.Blob(1, 0, 0, 2, 2, 4,
                                                             1, 1, 100, 100),
                                                     fm.Blob(1, 0, 0, 2, 2, 4,
                                                             1, 1, 100, 100))
    check("edges/adapter-duplicate-labels",
          errors_code(TA.mask_frame_batch, f, camera_id="cam-a",
                      unit_id="unit-a", seq=0) == "invalid_input")
    # Unscored frames do not inspect their blobs at all.
    f.t_s, f.run, f.scored, f.blobs = 0.5, 0, False, (object(), object())
    out = TA.mask_frame_batch(f, camera_id="cam-a", unit_id="unit-a", seq=0)
    check("edges/adapter-unscored-ignores-blobs",
          out["detections"] == [] and out["t_ms"] == 500)
    f.t_s, f.run, f.scored, f.blobs = 0.5, 3, True, ()
    out = TA.mask_frame_batch(f, camera_id="cam-a", unit_id="unit-a", seq=0,
                              previous_run=3)
    check("edges/adapter-same-run-no-reset", out["reset"] is False)
    out = TA.mask_frame_batch(f, camera_id="cam-a", unit_id="unit-a", seq=0,
                              previous_run=2)
    check("edges/adapter-run-change-resets", out["reset"] is True)
    check("edges/adapter-unknown-seq-type",
          errors_code(TA.mask_frame_batch, f, camera_id="cam-a",
                      unit_id="unit-a", seq="0") == "invalid_input")


def test_cli_protocol():
    cli = Cli()
    try:
        r = cli.send({"op": "drain"})
        check("cli/not-initialized", r == {"ok": False,
                                           "error": {"code": "not_initialized"}},
              repr(r))
        r = cli.send_raw("this is not json")
        check("cli/bad-json", r.get("error", {}).get("code") == "invalid_input")
        r = cli.send_raw('{"op":"init","camera_id":"a","unit_id":"b","camera_id":"c"}')
        check("cli/duplicate-keys", r.get("error", {}).get("code") == "invalid_input")
        r = cli.send_raw('{"op":"init","camera_id":"a","unit_id":"b","config":{"gate_base":NaN}}')
        check("cli/nan-token", r.get("error", {}).get("code") == "invalid_input")
        r = cli.send({"op": "nope"})
        check("cli/unknown-op", r.get("error", {}).get("code") == "invalid_input")
        r = cli.send({"op": "init", "camera_id": "a", "unit_id": "b",
                      "config": {"bogus": 1}})
        check("cli/bad-config", r.get("error", {}).get("code") == "invalid_config")
        check("cli/failed-init-preserves-nothing",
              cli.send({"op": "snapshot"}).get("error", {}).get("code")
              == "not_initialized")
        check("cli/init", cli.send({"op": "init", "camera_id": "a",
                                    "unit_id": "b"}) == {"ok": True, "result": None})
        r = cli.send({"op": "feed", "batch": batch(0, 0, [det("a", 0.3, 0.5)],
                                                   cam="a", unit="b")})
        check("cli/feed", r["result"]["assignments"][0]["status"] == "born")
        snap = cli.send({"op": "snapshot"})["result"]
        check("cli/snapshot", set(snap) == {"schema", "state", "sha256"})
        cli.send({"op": "init", "camera_id": "a", "unit_id": "b"})
        cli.send({"op": "feed", "batch": batch(0, 0, [det("a", 0.3, 0.5)],
                                               cam="a", unit="b")})
        r = cli.send({"op": "feed", "batch": batch(0, 0, [det("a", 0.3, 0.5)],
                                                   cam="a", unit="b")})
        check("cli/replay", r["result"]["replayed"] is True)
        r = cli.send({"op": "feed", "batch": batch(0, 0, [det("a", 0.4, 0.5)],
                                                   cam="a", unit="b")})
        check("cli/error-passthrough",
              r == {"ok": False, "error": {"code": "replay_conflict"}}, repr(r))
        r = cli.send({"op": "drain"})
        check("cli/drain-empty", r["result"] == [])
        r = cli.send({"op": "finish"})
        check("cli/finish", r["result"] == ["t00000001"])
        r = cli.send({"op": "restore", "snapshot": snap})
        check("cli/restore", r["result"] is None)
        r = cli.send({"op": "feed", "batch": batch(1, 100, [], cam="a",
                                                   unit="b")})
        check("cli/restore-replaces",
              r["result"] == {"seq": 1, "replayed": False, "assignments": [],
                              "closed": []}, repr(r))
        r = cli.send({"op": "feed", "batch": {"camera_id": "a", "unit_id": "b"}})
        check("cli/malformed-command",
              r == {"ok": False, "error": {"code": "invalid_input"}}, repr(r))
        r = cli.send({"op": "snapshot", "extra": 1})
        check("cli/unknown-command-key",
              r == {"ok": False, "error": {"code": "invalid_input"}}, repr(r))
    finally:
        code = cli.close()
    check("cli/exit-1-after-errors", code == 1, "exit %r" % code)

    clean = Cli()
    try:
        clean.send({"op": "init", "camera_id": "a", "unit_id": "b"})
        clean.send({"op": "feed", "batch": batch(0, 0, [], cam="a", unit="b")})
        clean.send({"op": "drain"})
    finally:
        code = clean.close()
    check("cli/exit-0-when-clean", code == 0, "exit %r" % code)

    empty = subprocess.run([sys.executable, str(CLI)], input="",
                           capture_output=True, text=True, timeout=60)
    check("cli/empty-input", empty.returncode == 0 and empty.stdout == "")

    piped = subprocess.run([sys.executable, str(CLI)],
                           input='\n{"op":"snapshot"}\n\n', capture_output=True,
                           text=True, timeout=60)
    check("cli/blank-lines-skipped",
          piped.stdout.count("\n") == 1 and piped.returncode == 1, repr(piped.stdout))


def workload_batch(camera_id, n, width):
    """Contract section 13's generators, byte for byte."""
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


def test_workload(batches=10000, full=False):
    """Contract section 13's two streams, at a bounded size by default.

    `--full-workload` runs the declared 100000-batch first stream instead of
    the default bounded 10000; the second stream is always run in full.
    """
    if full:
        batches = 100000
    snap_sizes = []
    totals = [0, 0]
    statuses = [0, 0]

    def run(index, camera_id, count, width):
        tr = TT.Tracker(camera_id, "resource")
        t0 = time.perf_counter()
        seen = 0
        born = 0
        observed = 0                     # counters only; no episode archive
        for n in range(count):
            receipt = tr.feed(workload_batch(camera_id, n, width))
            seen += len(receipt["assignments"])
            if len(receipt["assignments"]) != width:
                return None, "batch %d assigned %d of %d detections" % (
                    n, len(receipt["assignments"]), width), 0.0
            for a in receipt["assignments"]:
                if a["status"] == "ambiguous":
                    return None, "ambiguous assignment at n=%d" % n, 0.0
                if a["status"] == "born":
                    born += 1
            for ep in tr.drain():            # discard output immediately
                observed += ep["observations"]
            if n == 0 or n % 1000 == 0:
                snap_sizes.append(len(json.dumps(tr.snapshot()).encode("utf-8")))
        ids = tr.finish()
        episodes = tr.drain()
        if sorted(ids) != sorted(e["track_id"] for e in episodes):
            return None, "finish ids disagree with the drained episodes", 0.0
        observed += sum(e["observations"] for e in episodes)
        if observed != seen:
            return None, ("episodes account for %d of %d accepted observations"
                          % (observed, seen)), 0.0
        if seen != count * width:
            return None, "assigned %d of %d detections" % (seen, count * width), 0.0
        totals[index] = seen
        statuses[index] = born
        return (len(ids), len(episodes)), "", time.perf_counter() - t0

    res1, err1, dt1 = run(0, "resource-a", batches, 8)
    check("workload/stream1-assigns-all", res1 is not None and not err1, err1)
    res2, err2, dt2 = run(1, "resource-b", 250, 32)
    check("workload/stream2-assigns-all", res2 is not None and not err2, err2)
    check("workload/snapshots-under-2mib",
          bool(snap_sizes) and max(snap_sizes) <= 2097152,
          "max %d" % (max(snap_sizes) if snap_sizes else -1))
    check("workload/no-ambiguity-stream1", res1 is not None)
    check("workload/aggregate-accounting",
          totals[0] == batches * 8 and totals[1] == 250 * 32,
          "totals %r" % (totals,))

    # Checkpoint equivalence on the same generator: a snapshot restored at the
    # halfway mark must produce identical receipts for every remaining batch.
    count, width = 1000, 8
    full_tr = TT.Tracker("resource-a", "resource")
    for n in range(count // 2):
        full_tr.feed(workload_batch("resource-a", n, width))
    checkpoint = json.loads(json.dumps(full_tr.snapshot()))
    restored = TT.Tracker.restore(checkpoint)
    same = True
    for n in range(count // 2, count):
        b = workload_batch("resource-a", n, width)
        if full_tr.feed(copy.deepcopy(b)) != restored.feed(copy.deepcopy(b)):
            same = False
            break
    check("workload/checkpoint-equivalence-receipts", same)
    check("workload/checkpoint-equivalence-finish",
          full_tr.finish() == restored.finish())
    check("workload/checkpoint-equivalence-episodes",
          full_tr.drain() == restored.drain())

    label = "declared 100000" if full else "bounded %d" % batches
    print("NOTE  workload %s: stream1 %.2fs (%d detections), stream2 %.2fs, "
          "births %r, max snapshot %d bytes"
          % (label, dt1, totals[0], dt2, statuses,
             max(snap_sizes) if snap_sizes else -1))
    return dt1 + dt2


def main(argv):
    full = "--full-workload" in argv
    t0 = time.perf_counter()
    run_public_cases()
    run_adapter_examples()
    test_validation()
    test_ordering_and_determinism()
    test_association_quality()
    test_time_and_lifecycle()
    test_episode_evidence()
    test_replay_and_atomicity()
    test_aliasing()
    test_checkpoints()
    test_matching_exactness()
    test_path_simplifier_checkpoint()
    test_contract_edges()
    test_cli_protocol()
    test_workload(full=full)
    print("\n%d PASS, %d FAIL  (%.1fs)"
          % (_passed[0], len(fails), time.perf_counter() - t0))
    if fails:
        print("failed: " + ", ".join(fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
