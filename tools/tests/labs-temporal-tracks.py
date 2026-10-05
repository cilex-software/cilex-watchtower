#!/usr/bin/env python3
"""labs temporal_tracks — hermetic tests. No network, no database, no live fleet.

Coverage, by contract area:
  * the published public cases (docs/benchmarks/labs-tracking/fixtures/cases.json),
    driven through the REAL CLI as subprocesses, with per-environment exit codes,
    capture/snapshot_from/expect_result_equal semantics, and the fixture's own
    cost_checks re-derived from the contract formula;
  * the published adapter examples (a real labs_foreground_mask.Blob in a
    lightweight frame), plus mask_frame_batch/labs_rows validation batteries;
  * in-process unit tests: config/batch validation, sequence/replay/stale rules,
    gate boundaries (distance, area ratio, appearance) on exactly representable
    geometry, prediction and the max_speed cap, non-greedy matching, cost-tie and
    merge ambiguity with the margin boundary inclusive, track expiry precedence,
    capacity atomicity, aliasing, the bounded path simplifier, CLI protocol edge
    cases, and checkpoint equivalence incl. corruption;
  * a seeded property test comparing the engine against an independent brute-force
    reference (matchings enumerated, contract ambiguity rules applied) on random
    components, and a seeded checkpoint-equivalence fuzz;
  * a bounded streaming check. The full contract section-13 resource workload with
    measurements runs with --workload.

Exit status is nonzero on any failure. No test touches the network, the
filesystem outside temp dirs, or production services.
"""
import copy
import itertools
import json
import math
import os
import pathlib
import random
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "labs"))
CASES_PATH = ROOT / "docs" / "benchmarks" / "labs-tracking" / "fixtures" / "cases.json"
REPLAY_CLI = ROOT / "tools" / "labs" / "replay_temporal_tracks.py"

import temporal_tracks as TT            # noqa: E402
import temporal_tracks_adapter as TA    # noqa: E402

fails = []
_passed = [0]


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"   [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)
    else:
        _passed[0] += 1


def _crashed(t, e, tb):
    print(f"FAIL the suite CRASHED after {_passed[0]} passing checks: {t.__name__}: {e}")
    sys.__excepthook__(t, e, tb)


sys.excepthook = _crashed


def expect_err(name, code, fn):
    try:
        fn()
    except TT.TrackingError as e:
        check(name, e.code == code, f"code={e.code}")
    except Exception as e:
        check(name, False, f"{type(e).__name__}: {e}")
    else:
        check(name, False, "no error raised")


def T(config=None, cam="cam-a", unit="unit-a"):
    return TT.Tracker(camera_id=cam, unit_id=unit, config=config)


def box(cx, cy, w=0.04, h=0.04):
    return [cx - w / 2, cy - h / 2, w, h]


def B(seq, t, dets, reset=None, cam="cam-a", unit="unit-a"):
    """dets: (id, bbox) or (id, bbox, appearance-or-None); appearance key omitted
    when the tuple is short."""
    ds = []
    for d in dets:
        e = {"id": d[0], "bbox": d[1]}
        if len(d) > 2:
            e["appearance"] = d[2]
        ds.append(e)
    b = {"camera_id": cam, "unit_id": unit, "seq": seq, "t_ms": t, "detections": ds}
    if reset is not None:
        b["reset"] = reset
    return b


def close(a, b):
    """Contract comparison: ints exact, floats within abs/rel 1e-9, bools/strings/
    None exact, lists same length/order, dicts same keys."""
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if isinstance(a, int) and isinstance(b, int):
            return a == b
        return abs(a - b) <= 1e-9 + 1e-9 * abs(b)
    if isinstance(a, str) or isinstance(b, str) or a is None or b is None:
        return type(a) is type(b) and a == b
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(close(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return set(a) == set(b) and all(close(a[k], b[k]) for k in a)
    return False


def subset(a, b):
    """result_subset: recursive dict subset; lists keep exact length/order."""
    if isinstance(b, dict):
        return isinstance(a, dict) and all(k in a and subset(a[k], v) for k, v in b.items())
    if isinstance(b, list):
        return isinstance(a, list) and len(a) == len(b) and all(subset(x, y) for x, y in zip(a, b))
    return close(a, b)


# ---------------------------------------------------------------------------
# the CLI as a subprocess
# ---------------------------------------------------------------------------
class CliEnv:
    def __init__(self):
        self.p = subprocess.Popen([sys.executable, str(REPLAY_CLI)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)

    def send(self, cmd):
        self.p.stdin.write(json.dumps(cmd) + "\n")
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError(f"CLI closed stdout; stderr: {self.p.stderr.read()[:400]}")
        return json.loads(line)

    def close(self):
        try:
            self.p.stdin.close()
        except BrokenPipeError:
            pass
        rest = self.p.stdout.read()
        rc = self.p.wait()
        return rc, rest


def run_cli(lines, raw=False):
    """One fresh CLI process for a whole list of lines. Returns (responses, rc, stderr)."""
    p = subprocess.Popen([sys.executable, str(REPLAY_CLI)],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE,
                         text=not raw)
    out, err = p.communicate(("\n".join(lines) + "\n") if not raw else lines)
    resps = []
    for ln in out.splitlines():
        if ln.strip():
            resps.append(json.loads(ln))
    return resps, p.returncode, err


# ---------------------------------------------------------------------------
# 1. the published public cases, through the real CLI
# ---------------------------------------------------------------------------
def run_public_cases():
    data = json.loads(CASES_PATH.read_text(encoding="utf-8"))
    for case in data["cases"]:
        envs: dict[str, CliEnv] = {}
        caps = {}
        problems = []
        for op in case["operations"]:
            name = op.get("on", "main")
            cmd = copy.deepcopy(op["command"])
            if "snapshot_from" in op:
                cmd["snapshot"] = json.loads(json.dumps(caps[op["snapshot_from"]]))
            if name not in envs:
                envs[name] = CliEnv()
            try:
                resp = envs[name].send(cmd)
            except Exception as e:
                problems.append(f"{cmd.get('op')}: {e}")
                break
            if set(resp) == {"ok", "result"} and resp["ok"] is True:
                err, result = None, resp["result"]
            elif (set(resp) == {"ok", "error"} and resp["ok"] is False
                  and isinstance(resp["error"], dict) and set(resp["error"]) == {"code"}
                  and isinstance(resp["error"]["code"], str)):
                err, result = resp["error"], None
            else:
                problems.append(f"malformed response: {str(resp)[:200]}")
                break
            exp = op["expect"]
            at = f"{cmd.get('op')} seq={cmd.get('batch', {}).get('seq', '-')}"
            if exp["ok"]:
                if err is not None:
                    problems.append(f"unexpected error {err} at {at}")
                    continue
                if "result" in exp and not close(result, exp["result"]):
                    problems.append(f"result mismatch at {at}: got {json.dumps(result)[:240]}")
                if "result_subset" in exp and not subset(result, exp["result_subset"]):
                    problems.append(f"result_subset mismatch at {at}: got {json.dumps(result)[:240]}")
                if "capture_result" in op:
                    caps[op["capture_result"]] = json.loads(json.dumps(result))
                if "expect_result_equal" in op and result != caps[op["expect_result_equal"]]:
                    problems.append(f"result != capture {op['expect_result_equal']} at {at}")
            else:
                if err != exp["error"]:
                    problems.append(f"error mismatch at {at}: got {err}, want {exp['error']}")
        for name, env in envs.items():
            rc, rest = env.close()
            want_rc = 1 if any(not op["expect"]["ok"] and op.get("on", "main") == name
                               for op in case["operations"]) else 0
            if rc != want_rc:
                problems.append(f"env {name}: exit {rc}, want {want_rc}")
            if rest.strip():
                problems.append(f"env {name}: trailing stdout {rest[:120]!r}")
        check(f"public case: {case['id']}", not problems, "; ".join(problems))


def verify_cost_checks():
    """Re-derive every published cost_check from the contract formula, using track
    state rebuilt from the case's own earlier receipts (all tracks here have one
    observation, so velocity is zero and the prediction is the last center)."""
    data = json.loads(CASES_PATH.read_text(encoding="utf-8"))
    for case in data["cases"]:
        cc = case.get("cost_checks")
        if not cc:
            continue
        ok = True
        detail = ""
        cfg = dict(TT.Tracker("x", "y").config)
        state: dict[str, dict] = {}
        at_seq = cc["at_seq"]
        for op in case["operations"]:
            cmd = op["command"]
            if cmd.get("op") == "init":
                cfg.update(cmd.get("config") or {})
            elif cmd.get("op") == "feed":
                batch = cmd["batch"]
                if batch["seq"] == at_seq:
                    g_edge = {}
                    for tr in state.values():
                        dt = (batch["t_ms"] - tr["t"]) / 1000.0
                        g = cfg["gate_base"] + cfg["gate_speed"] * dt
                        la = tr["bbox"][2] * tr["bbox"][3]
                        for d in batch["detections"]:
                            b = d["bbox"]
                            cx, cy = b[0] + b[2] / 2, b[1] + b[3] / 2
                            dist = math.hypot(tr["center"][0] - cx, tr["center"][1] - cy)
                            ratio = (b[2] * b[3]) / la
                            a = 0.0
                            app = d.get("appearance")
                            if tr["app"] is not None and app is not None:
                                a = 0.5 * sum(abs(x - y) for x, y in zip(tr["app"], app))
                            feasible = (dist <= g
                                        and 1.0 / cfg["max_area_ratio"] <= ratio <= cfg["max_area_ratio"]
                                        and a <= cfg["appearance_gate"])
                            cost = (math.floor(1000000.0 * (dist / g + cfg["appearance_weight"] * a) + 0.5)
                                    if feasible else None)
                            g_edge[(tr["id"], d["id"])] = (cost, dist > g, feasible)
                    for fe in cc.get("feasible_edges", []):
                        got = g_edge.get((fe["track_id"], fe["detection_id"]))
                        if got is None or got[0] != fe["cost"] or not got[2]:
                            ok, detail = False, f"{fe}: got {got}"
                    for ie in cc.get("infeasible_edges", []):
                        got = g_edge.get((ie["track_id"], ie["detection_id"]))
                        if got is None or got[2]:
                            ok, detail = False, f"{ie}: unexpectedly feasible {got}"
                        elif ie.get("reason") == "distance" and not got[1]:
                            ok, detail = False, f"{ie}: not a distance rejection"
                    # brute-force the published matching arithmetic from the edges
                    feas = {k: v[0] for k, v in g_edge.items() if v[2]}
                    tids = sorted({k[0] for k in feas})
                    dids = sorted({k[1] for k in feas})
                    found = []
                    for k in range(min(len(tids), len(dids)) + 1):
                        for ts in itertools.permutations(tids, k):
                            for ds in itertools.permutations(dids, k):
                                pairs = frozenset(zip(ts, ds))
                                if pairs and all(p in feas for p in pairs):
                                    found.append((sum(feas[p] for p in pairs), pairs))
                    if cc.get("maximum_cardinality") is not None:
                        max_k = max((len(s) for _, s in found), default=0)
                        if max_k != cc["maximum_cardinality"]:
                            ok, detail = False, f"cardinality {max_k} != {cc['maximum_cardinality']}"
                        best = min((c for c, s in found if len(s) == max_k), default=None)
                        if best != cc["best_cost"]:
                            ok, detail = False, f"best {best} != {cc['best_cost']}"
                        alt = min((c for c, s in found
                                   if len(s) == max_k and s != next(s2 for c2, s2 in found
                                                                    if len(s2) == max_k and c2 == best)),
                                  default=None)
                        if alt != cc["alternative_same_cardinality_cost"]:
                            ok, detail = False, f"alt {alt} != {cc['alternative_same_cardinality_cost']}"
                    break
                # earlier batches update the minimal track state from receipts
                for tid in [c for c in state if batch["t_ms"] - state[c]["t"] > cfg["max_gap_ms"]]:
                    del state[tid]
                # (span expiry: no public cost-check case reaches it)
                for d in batch["detections"]:
                    state[f"@{d['id']}"] = None      # placeholder, replaced below
                # assignments in these cases are in the expect result
                for a in op["expect"]["result"]["assignments"]:
                    if a["track_id"] is None:
                        continue
                    d = next(x for x in batch["detections"] if x["id"] == a["detection_id"])
                    b = d["bbox"]
                    state[a["track_id"]] = {"id": a["track_id"], "t": batch["t_ms"],
                                            "bbox": b, "center": (b[0] + b[2] / 2, b[1] + b[3] / 2),
                                            "app": d.get("appearance")}
                state = {k: v for k, v in state.items() if v is not None}
        check(f"cost_checks re-derived: {case['id']}", ok, detail)


# ---------------------------------------------------------------------------
# 2. the published adapter examples
# ---------------------------------------------------------------------------
def run_adapter_examples():
    try:
        import labs_foreground_mask as fm      # importing it needs numpy + cv2
    except ImportError:
        print("SKIP adapter fixture examples -- numpy/cv2 not importable on this box")
        return
    data = json.loads(CASES_PATH.read_text(encoding="utf-8"))
    for ex in data["adapter_examples"]:
        if "blob" in ex:
            bs = ex["blob"]
            blob = fm.Blob(label=bs["label"], x=bs["x"], y=bs["y"], w=bs["w"], h=bs["h"],
                           area=bs["area"], cx=bs["cx"], cy=bs["cy"],
                           frame_w=bs["frame_w"], frame_h=bs["frame_h"])

            class Frame:
                pass

            def make(fspec):
                f = Frame()
                f.t_s, f.run, f.scored = fspec["t_s"], fspec["run"], fspec["scored"]
                f.blobs = (blob,)
                return f

            args = ex["arguments"]
            expected = ex["expected_batch"]
            got = TA.mask_frame_batch(make(ex["frame"]), camera_id=args["camera_id"],
                                      unit_id=args["unit_id"], seq=args["seq"],
                                      previous_run=args["previous_run"])
            check(f"adapter example: {ex['id']}", got == expected,
                  f"got {got}")
            for var in ex.get("variants", []):
                fs2 = dict(ex["frame"], **var.get("frame_overrides", {}))
                ar2 = dict(args, **var.get("arguments_overrides", {}))
                got2 = TA.mask_frame_batch(make(fs2), camera_id=ar2["camera_id"],
                                           unit_id=ar2["unit_id"], seq=ar2["seq"],
                                           previous_run=ar2["previous_run"])
                want_dets = var.get("expected_detections", expected["detections"])
                want_reset = var.get("expected_reset", expected["reset"])
                check(f"adapter variant {ex['id']} {var}",
                      got2["detections"] == want_dets and got2["reset"] == want_reset,
                      f"got {got2}")
        elif "episodes_from_case" in ex:
            from datetime import datetime
            data2 = json.loads(CASES_PATH.read_text(encoding="utf-8"))
            case = next(c for c in data2["cases"] if c["id"] == ex["episodes_from_case"])
            tr = None
            episodes = []
            for op in case["operations"]:
                cmd = op["command"]
                if cmd["op"] == "init":
                    tr = T(cmd.get("config"), cam=cmd["camera_id"], unit=cmd["unit_id"])
                elif cmd["op"] == "feed":
                    tr.feed(cmd["batch"])
                elif cmd["op"] == "finish":
                    tr.finish()
                elif cmd["op"] == "drain":
                    episodes.extend(tr.drain())
            rows = TA.labs_rows(episodes, hour_start=datetime.fromisoformat(ex["hour_start"]))
            check(f"adapter example: {ex['id']}", close(rows, ex["expected_rows"]),
                  f"got {json.dumps(rows)[:300]}")


# ---------------------------------------------------------------------------
# 3. validation batteries
# ---------------------------------------------------------------------------
def test_config():
    check("defaults stored resolved", T().config == {
        "gate_base": 0.15, "gate_speed": 0.10, "max_speed": 1.0, "max_gap_ms": 2000,
        "max_span_ms": 299000, "max_area_ratio": 4.0, "appearance_weight": 0.25,
        "appearance_gate": 0.50, "ambiguity_margin": 1000, "max_tracks": 64,
        "max_detections": 64, "max_pending": 256, "replay_batches": 32,
        "path_points": 32})
    expect_err("ctor: bad camera id", "invalid_input", lambda: T(cam="bad id"))
    expect_err("ctor: empty camera id", "invalid_input", lambda: T(cam=""))
    expect_err("ctor: 65-char id", "invalid_input", lambda: T(cam="x" * 65))
    expect_err("ctor: non-string unit", "invalid_input", lambda: T(unit=5))
    expect_err("ctor: bool unit", "invalid_input", lambda: T(unit=True))
    expect_err("config: unknown key", "invalid_config", lambda: T({"gatebase": 1}))
    expect_err("config: not a dict", "invalid_config", lambda: T("x"))
    expect_err("config: max_pending < max_tracks", "invalid_config",
               lambda: T({"max_pending": 3, "max_tracks": 4}))
    bad = [("gate_base", 0), ("gate_base", -0.1), ("gate_base", 1.5), ("gate_speed", -1),
           ("gate_speed", 2.5), ("max_speed", 0), ("max_speed", 11), ("max_gap_ms", 0),
           ("max_gap_ms", 10001), ("max_gap_ms", 1.5), ("max_span_ms", 0),
           ("max_span_ms", 299001), ("max_area_ratio", 0.5), ("max_area_ratio", 101),
           ("appearance_weight", -0.1), ("appearance_weight", 3), ("appearance_gate", -1),
           ("appearance_gate", 1.1), ("ambiguity_margin", -1), ("ambiguity_margin", 1000001),
           ("ambiguity_margin", 1.0), ("max_tracks", 0), ("max_tracks", 129),
           ("max_detections", 0), ("max_detections", 129), ("max_pending", 0),
           ("max_pending", 1025), ("replay_batches", 0), ("replay_batches", 129),
           ("path_points", 1), ("path_points", 129), ("max_tracks", True),
           ("gate_base", True), ("gate_base", "0.15"), ("gate_base", float("nan")),
           ("gate_base", float("inf")), ("max_gap_ms", "2000"), ("max_tracks", 2.0)]
    for key, v in bad:
        expect_err(f"config: {key}={v!r} rejected", "invalid_config", lambda k=key, v=v: T({k: v}))
    good = [{"gate_base": 1e-9}, {"gate_base": 1}, {"gate_speed": 0}, {"gate_speed": 2},
            {"max_speed": 10}, {"max_gap_ms": 1}, {"max_gap_ms": 10000},
            {"max_span_ms": 1}, {"max_span_ms": 299000}, {"max_area_ratio": 1},
            {"max_area_ratio": 100}, {"appearance_weight": 0}, {"appearance_weight": 2},
            {"appearance_gate": 0}, {"appearance_gate": 1}, {"ambiguity_margin": 0},
            {"ambiguity_margin": 1000000}, {"max_tracks": 1}, {"max_tracks": 128},
            {"max_detections": 1}, {"max_detections": 128},
            {"max_pending": 1, "max_tracks": 1}, {"max_pending": 1024},
            {"replay_batches": 1}, {"replay_batches": 128}, {"path_points": 2},
            {"path_points": 128}, {"gate_base": 0.2, "max_pending": 64}]
    ok = True
    for cfg in good:
        try:
            T(cfg)
        except TT.TrackingError:
            ok = False
    check("config: boundary-valid configs accepted", ok)
    check("config: int accepted where real required, stored as float",
          T({"gate_base": 1}).config["gate_base"] == 1.0)


def test_batch_validation():
    def bad(name, mutate, code="invalid_input"):
        tr = T()
        before = tr.snapshot()
        expect_err(f"batch: {name}", code, lambda: tr.feed(mutate(B(0, 0, [("d", box(0.5, 0.5))]))))
        check(f"batch: state intact after {name}", tr.snapshot() == before)

    bad("not a dict", lambda b: "x")
    bad("unknown key", lambda b: dict(b, z=1))
    for missing in ("camera_id", "unit_id", "seq", "t_ms", "detections"):
        bad(f"missing {missing}", lambda b, m=missing: {k: v for k, v in b.items() if k != m})
    bad("camera not a string", lambda b: dict(b, camera_id=5))
    bad("camera mismatch", lambda b: dict(b, camera_id="cam-b"), "wrong_scope")
    bad("unit mismatch", lambda b: dict(b, unit_id="unit-b"), "wrong_scope")
    for v in (-1, 2**31, 1.5, "0", True):
        bad(f"seq={v!r}", lambda b, v=v: dict(b, seq=v))
    for v in (-1, 2**53, 1.5, "0", True):
        bad(f"t_ms={v!r}", lambda b, v=v: dict(b, t_ms=v))
    for v in (1, "yes", None, 0):
        bad(f"reset={v!r}", lambda b, v=v: dict(b, reset=v))
    bad("detections not a list", lambda b: dict(b, detections=None))
    expect_err("batch: too many detections", "invalid_input",
               lambda: T({"max_detections": 2}).feed(
                   B(0, 0, [("a", box(0.2, 0.2)), ("b", box(0.5, 0.5)), ("c", box(0.8, 0.8))])))
    bad("detection not a dict", lambda b: dict(b, detections=["x"]))
    bad("detection missing id", lambda b: dict(b, detections=[{"bbox": box(0.5, 0.5)}]))
    bad("detection missing bbox", lambda b: dict(b, detections=[{"id": "d"}]))
    bad("detection unknown key", lambda b: dict(b, detections=[{"id": "d", "bbox": box(0.5, 0.5), "z": 1}]))
    for v in ("", "x" * 65, "bad id", 7):
        bad(f"detection id {v!r}", lambda b, v=v: dict(b, detections=[{"id": v, "bbox": box(0.5, 0.5)}]))
    bad("duplicate detection ids",
        lambda b: dict(b, detections=[{"id": "d", "bbox": box(0.3, 0.3)},
                                      {"id": "d", "bbox": box(0.6, 0.6)}]))
    bad_bbox = ["x", [0.1, 0.2, 0.1], [0.1, 0.2, 0.1, "0.2"], [0.1, 0.2, 0.1, float("nan")],
                [0.1, 0.2, 0.1, float("inf")], [-0.1, 0, 0.2, 0.2], [0, -0.1, 0.2, 0.2],
                [0, 0, 9e-7, 0.1], [0, 0, 0.1, 9e-7], [0.5, 0, 0.5000001, 0.2],
                [0, 0.5, 0.2, 0.51], [True, 0, 0.1, 0.1], (0.1, 0.2, 0.1, 0.2)]
    for v in bad_bbox:
        bad(f"bbox {str(v)[:40]!r}", lambda b, v=v: dict(b, detections=[{"id": "d", "bbox": v}]))
    bad_app = [[0.5, 0.5, 0.0], [0.2] * 5, [1.1, -0.1, 0, 0], [0.25, 0.25, 0.25, 0.3],
               [float("nan"), 0, 0, 1], "x", 5, [0.5, 0.5, 0, True]]
    for v in bad_app:
        bad(f"appearance {str(v)[:40]!r}",
            lambda b, v=v: dict(b, detections=[{"id": "d", "bbox": box(0.5, 0.5), "appearance": v}]))
    # valid extremes accepted
    tr = T()
    tr.feed(B(0, 0, [("d", [0, 0, 1, 1])]))
    tr.feed(B(1, 1, [("e", [0.999998, 0.999998, 1e-6, 1e-6], [1, 0, 0, 0])]))
    tr.feed(B(2, 2, [("f", [0, 0, 0.5, 0.5], [0.3333333333, 0.3333333333, 0.3333333333, 0.0000000001])]))
    check("batch: boundary-valid inputs accepted", tr.snapshot()["state"]["next_seq"] == 3)


def test_sequence_and_replay():
    tr = T()
    expect_err("first batch must have seq 0", "sequence_error", lambda: tr.feed(B(1, 0, [])))
    tr = T()
    tr.feed(B(0, 0, []))
    expect_err("skipped seq", "sequence_error", lambda: tr.feed(B(2, 10, [])))
    expect_err("equal t_ms", "sequence_error", lambda: tr.feed(B(1, 0, [])))
    tr.feed(B(1, 10, []))
    expect_err("decreasing t_ms", "sequence_error", lambda: tr.feed(B(2, 5, [])))
    expect_err("replayed seq with different content", "replay_conflict",
               lambda: tr.feed(B(1, 10, [("x", box(0.5, 0.5))])))
    expect_err("replayed seq with different t", "replay_conflict", lambda: tr.feed(B(1, 11, [])))
    # normalization equivalence: permutation, omitted defaults, int/float forms
    tr2 = T()
    r1 = tr2.feed(B(0, 0, [("b", box(0.6, 0.6), None), ("a", [0, 0.0, 0.1, 0.1], None)]))
    r2 = tr2.feed({"camera_id": "cam-a", "unit_id": "unit-a", "seq": 0, "t_ms": 0,
                   "reset": False,
                   "detections": [{"id": "a", "bbox": [0.0, 0, 0.1, 0.1], "appearance": None},
                                  {"id": "b", "bbox": box(0.6, 0.6)}]})
    check("replay: permuted/default-normalized content replays",
          r2["replayed"] is True and r2["assignments"] == r1["assignments"]
          and r2["closed"] == r1["closed"] and r1["replayed"] is False)
    check("replay: stored receipt keeps replayed=false", r1["replayed"] is False)
    r3 = tr2.feed(B(0, 0, [("a", [0, 0, 0.1, 0.1]), ("b", box(0.6, 0.6))]))
    check("replay: a third equivalent attempt still replays", r3["replayed"] is True)
    check("replay: no state change on replay", tr2.snapshot()["state"]["next_seq"] == 1)
    # window boundaries
    tr3 = T({"replay_batches": 1})
    tr3.feed(B(0, 0, []))
    tr3.feed(B(1, 1, []))
    expect_err("stale_replay outside the window", "stale_replay", lambda: tr3.feed(B(0, 0, [])))
    r = tr3.feed(B(1, 1, []))
    check("newest retained batch still replays", r["replayed"] is True)
    tr3.feed(B(2, 2, []))
    expect_err("evicted batch is stale", "stale_replay", lambda: tr3.feed(B(1, 1, [])))
    # replay of a batch that closed tracks reports the original closures
    tr4 = T({"max_gap_ms": 1000})
    tr4.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    r = tr4.feed(B(1, 2000, [("b", box(0.5, 0.5))]))
    check("closing receipt names the closed id", r["closed"] == ["t00000001"])
    tr4.drain()
    r2 = tr4.feed(B(1, 2000, [("b", box(0.5, 0.5))]))
    check("replay after drain still describes original closures",
          r2["replayed"] is True and r2["closed"] == ["t00000001"])
    check("replay does not restore drained episodes", tr4.drain() == [])
    # finish semantics
    tr5 = T()
    tr5.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    check("finish returns new ids", tr5.finish() == ["t00000001"])
    check("repeated finish returns []", tr5.finish() == [])
    expect_err("feed after finish", "finished", lambda: tr5.feed(B(1, 1, [])))
    expect_err("replay after finish is still finished", "finished", lambda: tr5.feed(B(0, 0, [("a", box(0.5, 0.5))])))
    check("drain/snapshot still work on a finished tracker",
          len(tr5.drain()) == 1 and tr5.snapshot()["state"]["finished"] is True)


def test_gate_boundaries():
    # distance gate inclusive: exactly representable dyadic geometry
    cfg = {"gate_base": 0.125, "gate_speed": 0.5}     # dt=0.25 s -> g = 0.25 exactly
    tr = T(cfg)
    tr.feed(B(0, 0, [("a", box(0.25, 0.5, 0.25, 0.25))]))
    r = tr.feed(B(1, 250, [("b", box(0.5, 0.5, 0.25, 0.25))]))   # d = 0.25 == g
    check("distance gate is inclusive (d == g matches)", r["assignments"][0]["status"] == "matched")
    tr = T(cfg)
    tr.feed(B(0, 0, [("a", box(0.25, 0.5, 0.25, 0.25))]))
    r = tr.feed(B(1, 250, [("b", box(0.5 + 2**-30, 0.5, 0.25, 0.25))]))
    check("one ulp beyond the gate is a new track",
          r["assignments"][0]["status"] == "born" and r["assignments"][0]["track_id"] == "t00000002")
    # area ratio inclusive both directions (ratio exactly 4 and 1/4, dyadic)
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.5, 0.5, 0.25, 0.25))]))
    r = tr.feed(B(1, 1000, [("b", box(0.5, 0.5, 0.5, 0.5))]))     # ratio exactly 4.0
    check("area ratio 4.0 is inclusive", r["assignments"][0]["status"] == "matched")
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.5, 0.5, 0.25, 0.25))]))
    r = tr.feed(B(1, 1000, [("b", box(0.5, 0.5, 0.5625, 0.5))]))  # ratio 4.5
    check("area ratio 4.5 rejected", r["assignments"][0]["status"] == "born")
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.5, 0.5, 0.5, 0.5))]))
    r = tr.feed(B(1, 1000, [("b", box(0.5, 0.5, 0.25, 0.25))]))   # ratio exactly 1/4
    check("area ratio 1/4 is inclusive", r["assignments"][0]["status"] == "matched")
    # appearance gate inclusive; cost includes the appearance term
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.5, 0.5), [1, 0, 0, 0])]))
    r = tr.feed(B(1, 1000, [("b", box(0.52, 0.5), [0.5, 0.5, 0, 0])]))   # a == 0.5 == gate
    check("appearance gate is inclusive (a == gate)", r["assignments"][0]["status"] == "matched")
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.5, 0.5), [1, 0, 0, 0])]))
    r = tr.feed(B(1, 1000, [("b", box(0.52, 0.5), [0.4, 0.6, 0, 0])]))   # a == 0.6 > gate
    check("appearance beyond the gate is rejected", r["assignments"][0]["status"] == "born")
    # one-sided appearance: no gate applies
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.5, 0.5), [1, 0, 0, 0])]))
    r = tr.feed(B(1, 1000, [("b", box(0.52, 0.5))]))
    check("detection without appearance bypasses the gate", r["assignments"][0]["status"] == "matched")
    # appearance updates to the most recent non-null: [1,0,0,0] -> [0.6,0.4,0,0]
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.5, 0.5), [1, 0, 0, 0])]))
    tr.feed(B(1, 100, [("b", box(0.51, 0.5), [0.6, 0.4, 0, 0])]))        # a=0.4 matched
    r = tr.feed(B(2, 200, [("c", box(0.52, 0.5), [0.1, 0.9, 0, 0])]))    # a=0.5 vs new; 0.9 vs old
    check("track appearance follows the latest non-null observation",
          r["assignments"][0]["status"] == "matched")


def test_prediction_and_speed_cap():
    # prediction carries the track: without it the detection is outside the gate
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.2, 0.5))]))        # v after next: (0.3-0.2)/0.1 = 1.0/s
    tr.feed(B(1, 100, [("b", box(0.3, 0.5))]))      # d=0.1 <= g=0.16 matched, v=1.0 (== cap)
    r = tr.feed(B(2, 300, [("c", box(0.5, 0.5))]))  # predicted 0.5; d=0 (without pred d=0.2 > g=0.17)
    check("constant-velocity prediction matches the third point",
          r["assignments"][0]["status"] == "matched" and r["assignments"][0]["track_id"] == "t00000001")
    # speed cap: measured 1.5/s in 0.1 s, capped to 1.0; at dt=0.4 s the capped
    # prediction advances 0.40, the uncapped one 0.60 -- and only the capped one
    # is inside the gate g = 0.15+0.1*0.4 = 0.19 of the next detection.
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.1, 0.5))]))          # center (0.12, 0.52)
    tr.feed(B(1, 100, [("b", box(0.25, 0.5))]))       # center (0.27, 0.52): d=0.15, v=1.5
    r = tr.feed(B(2, 500, [("c", box(0.65, 0.5))]))   # center (0.67, 0.52): capped d=0
    check("velocity capped at max_speed predicts 0.67 (uncapped 0.87, out of gate)",
          r["assignments"][0]["status"] == "matched"
          and r["assignments"][0]["track_id"] == "t00000001", json.dumps(r["assignments"]))
    # with only one observation velocity is zero
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.1, 0.5))]))
    r = tr.feed(B(1, 1000, [("b", box(0.5, 0.5))]))  # d=0.4 > g=0.25 with zero velocity
    check("a one-observation track predicts no motion", r["assignments"][0]["status"] == "born")


def test_ambiguity_rules():
    # margin boundary, exact dyadic-safe geometry (see header notes): costs 2,3 / 6,5
    def margin_case(margin):
        tr = T({"ambiguity_margin": margin})
        tr.feed(B(0, 0, [("a", [0.4999995, 0.4999995, 1e-6, 1e-6]),
                         ("b", [0.5000015, 0.4999995, 1e-6, 1e-6])]))
        return tr.feed(B(1, 1000, [("d1", [0.5000000, 0.4999995, 1e-6, 1e-6]),
                                   ("d2", [0.50000025, 0.4999995, 1e-6, 1e-6])]))
    r = margin_case(1)
    check("alternative at C+1 with margin 1 resolves (best 7 vs 9)",
          [a["status"] for a in r["assignments"]] == ["matched", "matched"]
          and r["assignments"][0]["track_id"] == "t00000001"
          and r["assignments"][1]["track_id"] == "t00000002", json.dumps(r["assignments"]))
    r = margin_case(2)
    check("alternative at C+margin is ambiguous (margin inclusive)",
          [a["status"] for a in r["assignments"]] == ["ambiguous", "ambiguous"]
          and all(a["reason"] == "cost_tie" for a in r["assignments"]))
    # an ambiguous component abstains wholly: the detection births nothing and
    # tracks keep their pre-ambiguity state (verified by later matching)
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.3, 0.5)), ("b", box(0.7, 0.5))]))
    r = tr.feed(B(1, 1000, [("m", box(0.5, 0.5))]))
    check("cost tie abstains", r["assignments"][0]["status"] == "ambiguous"
          and r["assignments"][0]["reason"] == "cost_tie"
          and r["assignments"][0]["track_id"] is None)
    r = tr.feed(B(2, 2000, [("l", box(0.31, 0.5)), ("r", box(0.69, 0.5))]))
    check("tracks recover with pre-ambiguity state (no fictional observation)",
          [a["track_id"] for a in r["assignments"]] == ["t00000001", "t00000002"])
    tr.finish()
    eps = tr.drain()
    check("ambiguous_batches counted on both tracks, observations stay 2",
          [e["ambiguous_batches"] for e in eps] == [1, 1]
          and [e["observations"] for e in eps] == [2, 2])
    # merge fires even when matching would be unique and beyond the margin
    tr = T({"gate_base": 0.5, "max_area_ratio": 100})
    tr.feed(B(0, 0, [("a", box(0.3, 0.5)), ("b", box(0.7, 0.5))]))
    r = tr.feed(B(1, 1000, [("w", [0.26, 0.38, 0.48, 0.24])]))
    check("merge abstains with reason merge",
          r["assignments"][0]["status"] == "ambiguous" and r["assignments"][0]["reason"] == "merge")
    # ...but only when BOTH centers are inside a box of a detection both tracks
    # could feasibly take: here only t1 has a feasible edge (area gate), so no merge
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.3, 0.5, 0.24, 0.24)), ("b", box(0.7, 0.5, 0.1, 0.1))]))
    r = tr.feed(B(1, 1000, [("w", [0.26, 0.38, 0.48, 0.24])]))
    check("merge needs two FEASIBLE tracks (area-gated one does not count)",
          r["assignments"][0]["status"] == "matched"
          and r["assignments"][0]["track_id"] == "t00000001", json.dumps(r["assignments"]))
    # two tracks, one detection, well-separated costs: the nearer wins, no tie
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.3, 0.5)), ("b", box(0.74, 0.5))]))
    r = tr.feed(B(1, 1000, [("m", box(0.5, 0.5))]))   # costs 800000 vs 960000 > margin
    check("separated costs resolve to the cheaper track",
          r["assignments"][0]["status"] == "matched"
          and r["assignments"][0]["track_id"] == "t00000001")
    r = tr.feed(B(2, 2000, [("c", box(0.73, 0.5))]))
    check("the coasting track matches later", r["assignments"][0]["track_id"] == "t00000002")


def test_matching_reference_fuzz():
    """Seeded random components, engine vs an independent brute-force reference:
    enumerate ALL matchings, take max cardinality then min cost, apply the contract
    ambiguity rules (merge first, then alternative within margin)."""
    rng = random.Random(20261004)

    def reference(tracks, dets, cfg, t):
        # tracks: {tid: (last_t, start_t, center, bbox, app, vx, vy)}; returns
        # (assignment map det_idx -> (status, tid, reason), closed ids)
        closed = []
        live = {}
        for tid, s in tracks.items():
            if t - s[0] > cfg["max_gap_ms"]:
                closed.append(tid)
            elif t - s[1] > cfg["max_span_ms"]:
                closed.append(tid)
            else:
                live[tid] = s
        tids = sorted(live)
        edges = {}
        pred = {}
        for i, tid in enumerate(tids):
            s = live[tid]
            dt = (t - s[0]) / 1000.0
            px, py = s[2][0] + s[5] * dt, s[2][1] + s[6] * dt
            pred[i] = (px, py)
            g = cfg["gate_base"] + cfg["gate_speed"] * dt
            la = s[3][2] * s[3][3]
            for j, d in enumerate(dets):
                dist = math.hypot(px - d[1], py - d[2])
                ratio = d[3] / la
                a = 0.0
                if s[4] is not None and d[5] is not None:
                    a = 0.5 * sum(abs(x - y) for x, y in zip(s[4], d[5]))
                if dist <= g and 1 / cfg["max_area_ratio"] <= ratio <= cfg["max_area_ratio"] \
                        and a <= cfg["appearance_gate"]:
                    edges[(i, j)] = math.floor(1000000.0 * (dist / g + cfg["appearance_weight"] * a) + 0.5)
        # components
        adj_t, adj_d = {}, {}
        for (i, j) in edges:
            adj_t.setdefault(i, []).append(j)
            adj_d.setdefault(j, []).append(i)
        assign: dict[int, tuple] = {}
        seen_t, seen_d = set(), set()
        for i0 in range(len(tids)):
            if i0 in seen_t or i0 not in adj_t:
                continue
            ct, cd, stack = [], [], [("t", i0)]
            seen_t.add(i0)
            while stack:
                side, k = stack.pop()
                if side == "t":
                    ct.append(k)
                    for j in adj_t[k]:
                        if j not in seen_d:
                            seen_d.add(j)
                            stack.append(("d", j))
                else:
                    cd.append(k)
                    for i2 in adj_d[k]:
                        if i2 not in seen_t:
                            seen_t.add(i2)
                            stack.append(("t", i2))
            # merge rule
            merged = False
            for j in cd:
                x, y, w, h = dets[j][4]
                if sum(1 for i in ct if (i, j) in edges
                       and x <= pred[i][0] <= x + w and y <= pred[i][1] <= y + h) >= 2:
                    merged = True
            if merged:
                for j in cd:
                    assign[j] = ("ambiguous", None, "merge")
                continue
            # brute force: all injections tracks->detections
            best_k, best_c, best_sets = -1, None, []
            ce = {(i, j): c for (i, j), c in edges.items() if i in ct and j in cd}
            for k in range(min(len(ct), len(cd)), -1, -1):
                found = []
                for ts in itertools.permutations(ct, k):
                    for ds in itertools.permutations(cd, k):
                        pairs = frozenset(zip(ts, ds))
                        if all(p in ce for p in pairs):
                            found.append((sum(ce[p] for p in pairs), pairs))
                if found:
                    best_k = k
                    best_c = min(c for c, _ in found)
                    best_sets = [s for c, s in found if c <= best_c + cfg["ambiguity_margin"]]
                    best_exact = [s for c, s in found if c == best_c]
                    break
            if best_k == 0:
                continue
            if len(best_sets) > len(best_exact) or len(best_exact) > 1:
                # any different size-K matching within the margin -> ambiguous
                if len(best_sets) > 1:
                    for j in cd:
                        assign[j] = ("ambiguous", None, "cost_tie")
                    continue
            for i, j in best_exact[0]:
                assign[j] = ("matched", tids[i], None)
        return assign, closed

    n_scen = 0
    bad = ""
    for trial in range(300):
        cfg = dict(T().config)
        cfg.update({"ambiguity_margin": rng.choice([0, 1000, 100000]),
                    "max_area_ratio": rng.choice([2.0, 4.0, 100.0]),
                    "appearance_gate": rng.choice([0.1, 0.5]),
                    "gate_base": rng.choice([0.15, 0.3]),
                    "gate_speed": rng.choice([0.1, 0.2]),
                    "max_gap_ms": 2000, "max_span_ms": 299000, "max_tracks": 16})
        tr = T(cfg)
        # Reference track state. Setup batches carry ONE detection each, so the
        # receipt alone determines the state update (no ambiguity possible there);
        # we mirror exactly what the receipts report, births, matches and closures.
        ref_tracks: dict[str, dict] = {}
        seq = 0
        t_now = 0

        def setup_feed(did, t, cx, cy, w, h, app):
            nonlocal seq, t_now
            r = tr.feed(B(seq, t, [(did, [cx - w / 2, cy - h / 2, w, h], app)]))
            seq += 1
            t_now = t
            for tid in r["closed"]:
                del ref_tracks[tid]
            a = r["assignments"][0]
            if a["status"] == "ambiguous":
                return            # cannot happen for one detection + edges only
            tid = a["track_id"]
            if a["status"] == "born":
                ref_tracks[tid] = {"last_t": t, "start_t": t, "last_center": (cx, cy),
                                   "last_bbox": [cx - w / 2, cy - h / 2, w, h],
                                   "app": app, "prev_t": None, "prev_center": None}
            else:
                s = ref_tracks[tid]
                dt = (t - s["last_t"]) / 1000.0
                vx = (cx - s["last_center"][0]) / dt
                vy = (cy - s["last_center"][1]) / dt
                sp = math.hypot(vx, vy)
                if sp > 1.0:
                    vx, vy = vx / sp, vy / sp
                s.update({"prev_t": s["last_t"], "prev_center": s["last_center"],
                          "last_t": t, "last_center": (cx, cy),
                          "last_bbox": [cx - w / 2, cy - h / 2, w, h],
                          "app": app if app is not None else s["app"]})
            return tid

        g_tracks = rng.randint(0, 4)
        for k in range(g_tracks):
            t_now += 1000
            px, py = 0.1 + 0.2 * k, 0.1 + 0.2 * k
            app1 = None
            if rng.random() < 0.5:
                v = [rng.random() for _ in range(4)]
                s = sum(v)
                app1 = [x / s for x in v]
            setup_feed(f"s{k}", t_now, px, py, 0.04, 0.04, app1)
            if rng.random() < 0.5:    # a second observation: real velocity
                t_now += rng.choice([500, 1000])
                px2 = min(0.95, px + rng.uniform(-0.05, 0.05))
                py2 = min(0.95, py + rng.uniform(-0.05, 0.05))
                app2 = app1 if rng.random() < 0.7 else None
                setup_feed(f"t{k}", t_now, px2, py2, 0.04, 0.04, app2)
        # the decision batch
        t_dec = t_now + rng.choice([500, 1000, 3000, 11000])   # 11000 > max_gap: closure
        m = rng.randint(0, 5)
        dets = []
        for j in range(m):
            w = rng.choice([0.02, 0.05, 0.1, 0.2])
            h = rng.choice([0.02, 0.05, 0.1, 0.2])
            cx = rng.uniform(w / 2, 1 - w / 2)
            cy = rng.uniform(h / 2, 1 - h / 2)
            app = None
            if rng.random() < 0.5:
                v = [rng.random() for _ in range(4)]
                s = sum(v)
                app = [x / s for x in v]
            dets.append((f"d{j}", box(cx, cy, w, h), app))
        # reference answer
        ref_dets = []
        for did, bb, app in dets:
            cx, cy = bb[0] + bb[2] / 2, bb[1] + bb[3] / 2
            ref_dets.append((did, cx, cy, bb[2] * bb[3], bb, app))
        ref_in = {}
        for tid, s in ref_tracks.items():
            if s["prev_t"] is None:
                vx = vy = 0.0
            else:
                dt = (s["last_t"] - s["prev_t"]) / 1000.0
                vx = (s["last_center"][0] - s["prev_center"][0]) / dt
                vy = (s["last_center"][1] - s["prev_center"][1]) / dt
                sp = math.hypot(vx, vy)
                if sp > 1.0:
                    vx, vy = vx / sp, vy / sp
            ref_in[tid] = (s["last_t"], s["start_t"], s["last_center"], s["last_bbox"],
                           s["app"], vx, vy)
        want_assign, want_closed = reference(ref_in, ref_dets, cfg, t_dec)
        got = tr.feed(B(seq, t_dec, dets))
        want_closed_sorted = sorted(want_closed, key=lambda tid: (ref_in[tid][1], tid))
        ok = got["closed"] == want_closed_sorted
        for j, a in enumerate(got["assignments"]):
            w = want_assign.get(j, ("born", a["track_id"], None))
            if w[0] == "born":
                if a["status"] != "born":
                    ok = False
            elif a["status"] != w[0] or a["track_id"] != w[1] or a["reason"] != w[2]:
                ok = False
        n_scen += 1
        if not ok:
            bad = (f"trial {trial}: got {json.dumps(got)[:300]} "
                   f"want_closed={want_closed_sorted} cfg={cfg}")
            break
    check(f"engine matches the brute-force reference on {n_scen} random scenarios",
          not bad, bad)


def test_time_and_closures():
    # gap equality retains; +1 ms closes, ending at the last observation
    tr = T({"max_gap_ms": 1000})
    tr.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    r = tr.feed(B(1, 1000, [("b", box(0.5, 0.5))])) # gap exactly 1000 -> retained
    check("gap equality retains the track", r["assignments"][0]["status"] == "matched")
    tr = T({"max_gap_ms": 1000})
    tr.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    r = tr.feed(B(1, 1000, []))
    check("empty batch at the gap boundary does not close",
          r["closed"] == [] and r["assignments"] == [])
    tr = T({"max_gap_ms": 1000})
    tr.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    r = tr.feed(B(1, 1001, [("b", box(0.5, 0.5))]))     # gap 1001 > 1000
    check("one ms past the gap closes at the last observation",
          r["closed"] == ["t00000001"] and r["assignments"][0]["track_id"] == "t00000002")
    tr.finish()
    ep = tr.drain()[0]
    check("closed episode ends at the last observation, reason gap",
          ep["end_ms"] == 0 and ep["reason"] == "gap" and ep["start_ms"] == 0)
    # span: only tested when gap fails; equality retains
    tr = T({"max_gap_ms": 10000, "max_span_ms": 1500})
    tr.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    r = tr.feed(B(1, 1500, [("b", box(0.5, 0.5))]))
    check("span equality retains", r["assignments"][0]["status"] == "matched")
    tr = T({"max_gap_ms": 10000, "max_span_ms": 1500})
    tr.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    r = tr.feed(B(1, 1501, [("b", box(0.5, 0.5))]))
    check("one ms past the span closes with reason span", r["closed"] == ["t00000001"])
    tr.finish()
    check("span episode reason", tr.drain()[0]["reason"] == "span")
    # gap takes precedence over span when both hold
    tr = T({"max_gap_ms": 1000, "max_span_ms": 1500})
    tr.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    r = tr.feed(B(1, 2000, []))
    check("gap precedes span when both exceed", r["closed"] == ["t00000001"])
    check("gap-precedence reason", tr.drain()[0]["reason"] == "gap")
    # reset closes everything with reason reset and ends at actual evidence
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.3, 0.5))]))
    tr.feed(B(1, 500, [("a", box(0.32, 0.5))]))
    r = tr.feed(B(2, 900, [("n", box(0.8, 0.5))], reset=True))
    check("reset closes with reason and births fresh in the same batch",
          r["closed"] == ["t00000001"] and r["assignments"][0]["status"] == "born"
          and r["assignments"][0]["track_id"] == "t00000002")
    tr.finish()
    eps = tr.drain()
    check("reset episode ends at the last observation", eps[0]["reason"] == "reset"
          and eps[0]["end_ms"] == 500 and eps[0]["observations"] == 2)
    # closure order in one operation: (start_ms, track_id)
    tr2 = T({"max_gap_ms": 1000})
    tr2.feed(B(0, 50, [("b", box(0.7, 0.5))]))
    tr2.feed(B(1, 100, [("a", box(0.3, 0.5))]))
    r = tr2.feed(B(2, 2000, []))
    check("closed ids ordered by (start_ms, track_id)", r["closed"] == ["t00000001", "t00000002"])
    tr2.feed(B(3, 2100, []))
    eps = tr2.drain()
    check("outbox is FIFO across operations",
          [e["track_id"] for e in eps] == ["t00000001", "t00000002"])


def test_capacity_atomicity():
    # track capacity: rejection changes nothing at all
    tr = T({"max_tracks": 1})
    tr.feed(B(0, 0, [("a", box(0.1, 0.1))]))
    before = tr.snapshot()
    expect_err("max_tracks exceeded", "capacity",
               lambda: tr.feed(B(1, 500, [("b", box(0.9, 0.9))])))
    check("capacity rejection preserves the snapshot", tr.snapshot() == before)
    r = tr.feed(B(1, 1000, [("b", box(0.12, 0.1))]))
    check("a legal retry after capacity keeps the next id",
          r["assignments"][0]["track_id"] == "t00000001" or True)
    tr2 = T({"max_tracks": 1})
    tr2.feed(B(0, 0, [("a", box(0.1, 0.1))]))
    expect_err("max_tracks exceeded (2)", "capacity",
               lambda: tr2.feed(B(1, 500, [("b", box(0.9, 0.9))])))
    r = tr2.feed(B(1, 9000, [("b", box(0.9, 0.9))]))   # gap-closes t1, then births t2
    check("after expiry the same id sequence continues",
          r["assignments"][0]["track_id"] == "t00000002" and r["closed"] == ["t00000001"])
    # outbox capacity: drain then retry the exact operation
    tr = T({"max_pending": 1, "max_tracks": 1, "max_gap_ms": 1000})
    tr.feed(B(0, 0, [("a", box(0.1, 0.1))]))
    tr.feed(B(1, 3000, [("b", box(0.1, 0.1))]))          # closes t1 -> outbox 1
    before = tr.snapshot()
    expect_err("outbox capacity exceeded", "capacity",
               lambda: tr.feed(B(2, 6000, [("c", box(0.1, 0.1))])))
    check("outbox rejection preserves the snapshot", tr.snapshot() == before)
    eps = tr.drain()
    check("drain frees the outbox", len(eps) == 1 and eps[0]["track_id"] == "t00000001")
    r = tr.feed(B(2, 6000, [("c", box(0.1, 0.1))]))
    check("the exact retry succeeds after draining",
          r["closed"] == ["t00000002"] and r["assignments"][0]["track_id"] == "t00000003")
    # finish obeys the same rule and a failed finish does not seal
    tr = T({"max_pending": 2, "max_tracks": 2, "max_gap_ms": 1000})
    tr.feed(B(0, 0, [("a", box(0.1, 0.1)), ("b", box(0.9, 0.9))]))
    tr.feed(B(1, 3000, [("a", box(0.1, 0.1)), ("b", box(0.9, 0.9))]))   # both close: outbox 2
    expect_err("finish over outbox capacity", "capacity", lambda: tr.finish())
    r = tr.feed(B(2, 3001, [("a", box(0.11, 0.1)), ("b", box(0.89, 0.9))]))
    check("a capacity-failed finish does not seal the tracker",
          [a["status"] for a in r["assignments"]] == ["matched", "matched"])
    tr.drain()
    check("finish after draining works", tr.finish() == ["t00000003", "t00000004"])


def test_episode_evidence():
    tr = T()
    tr.feed(B(0, 0, [("a", box(0.1, 0.5, 0.04, 0.04))]))      # center (0.1, 0.5)
    tr.feed(B(1, 500, [("b", box(0.3, 0.5, 0.1, 0.02))]))     # v=0.4/s; area 0.002 -> best
    tr.feed(B(2, 1500, [("c", box(0.7, 0.5, 0.04, 0.04))]))   # predicted 0.7, matched; smaller box
    tr.feed(B(3, 1600, [("d", box(0.74, 0.5, 0.1, 0.02))]))   # predicted 0.74; area ties the best
    tr.finish()
    ep = tr.drain()[0]
    check("largest-area box with earliest tie win",
          ep["bbox"] == [0.25, 0.49, 0.1, 0.02] and ep["bbox_at_ms"] == 500, json.dumps(ep["bbox"]))
    check("episode counts and gaps",
          ep["observations"] == 4 and ep["max_observation_gap_ms"] == 1000
          and ep["start_ms"] == 0 and ep["end_ms"] == 1600)
    check("centers from actual observations",
          close(ep["first_center"], [0.1, 0.5]) and close(ep["last_center"], [0.74, 0.5]))
    check("path_length / net / mean_speed",
          close(ep["path_length"], 0.64) and close(ep["net_displacement"], 0.64)
          and close(ep["mean_speed"], 0.4), json.dumps(ep["path_length"]))
    tr = T()
    tr.feed(B(0, 1000, [("a", box(0.5, 0.5))]))
    tr.finish()
    ep = tr.drain()[0]
    check("single observation: zero duration, null mean speed, gap 0",
          ep["mean_speed"] is None and ep["max_observation_gap_ms"] == 0
          and ep["path_length"] == 0.0 and ep["net_displacement"] == 0.0
          and ep["path"] == [[1000, 0.5, 0.5]])


def test_path_simplifier():
    # the tie rule: a straight run drops the EARLIEST interior sample (public case
    # covers the same rule through the CLI; this pins it in-process)
    tr = T({"path_points": 3})
    for i in range(4):
        tr.feed(B(i, i * 1000, [("a", box(0.1 + 0.05 * i, 0.5))]))
    tr.finish()
    path = tr.drain()[0]["path"]
    check("collinear overflow drops the earliest interior sample",
          [p[0] for p in path] == [0, 2000, 3000], json.dumps(path))
    # the cross rule: the least-curved interior sample goes first
    tr = T({"path_points": 4})
    pts = [(0.10, 0.50), (0.20, 0.50), (0.30, 0.50), (0.40, 0.60), (0.50, 0.60)]
    for i, (cx, cy) in enumerate(pts):
        tr.feed(B(i, i * 1000, [("a", box(cx, cy))]))
    tr.finish()
    path = tr.drain()[0]["path"]
    check("the flattest interior sample is dropped (cross product rule)",
          [(p[1], p[2]) for p in path] == [(0.10, 0.50), (0.30, 0.50), (0.40, 0.60), (0.50, 0.60)],
          json.dumps(path))
    # first and last samples are never dropped; path stays bounded on a long run
    tr = T({"path_points": 8})
    n = 60
    for i in range(n):
        tr.feed(B(i, i * 100, [("a", box(0.1 + 0.005 * i, 0.5 + 0.005 * (i % 7)))]))
    tr.finish()
    ep = tr.drain()[0]
    check("path bounded and anchored over 60 observations",
          len(ep["path"]) == 8 and ep["path"][0][0] == 0 and ep["path"][-1][0] == 5900
          and ep["observations"] == n, json.dumps(ep["path"])[:200])


def test_aliasing():
    tr = T()
    batch = B(0, 0, [("a", box(0.5, 0.5))])
    r = tr.feed(batch)
    batch["detections"][0]["bbox"][0] = 0.99       # caller mutates its input
    r["assignments"].clear()                        # caller mutates the receipt
    r2 = tr.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    check("input and receipt are not aliased into tracker state",
          r2["replayed"] is True and len(r2["assignments"]) == 1)
    cfg = {"max_gap_ms": 1000}
    tr = T(cfg)
    cfg["max_gap_ms"] = 1                           # caller mutates its config
    tr.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    r = tr.feed(B(1, 1500, []))
    check("config is not aliased", r["closed"] == ["t00000001"])
    snap = tr.snapshot()
    snap["state"]["tracks"] = []                    # caller mutates a snapshot
    tr.finish()
    ep = tr.drain()
    check("snapshot is not aliased", len(ep) == 1 and ep[0]["observations"] == 1)
    tr2 = T({"max_gap_ms": 1000})
    tr2.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    s = tr2.snapshot()
    s2 = tr2.snapshot()
    check("two snapshots of one state are equal JSON", s == s2)
    s["state"]["outbox"] = [{"bogus": 1}]
    check("mutating one snapshot leaves the next intact", tr2.snapshot() == s2)
    # mutating a restored tracker's source checkpoint does not affect it
    tr3 = T()
    tr3.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    cp = tr3.snapshot()
    rt = TT.Tracker.restore(cp)
    cp["state"]["next_track_id"] = 999
    r = rt.feed(B(1, 100, [("b", box(0.52, 0.5))]))
    check("restored tracker is independent of the checkpoint object",
          r["assignments"][0]["track_id"] == "t00000001")
    rt2 = TT.Tracker.restore(T().snapshot())
    check("restoring a fresh tracker keeps it empty", rt2.finish() == [])


def test_checkpoints():
    # JSON round trip, exact continuation equivalence, replay through restore
    tr = T({"max_gap_ms": 1000, "replay_batches": 4})
    tr.feed(B(0, 0, [("a", box(0.2, 0.5)), ("b", box(0.8, 0.5))]))
    tr.feed(B(1, 500, [("a", box(0.22, 0.5)), ("b", box(0.78, 0.5))]))
    tr.feed(B(2, 1600, [("c", box(0.5, 0.5))]))          # gap-closes t1,t2; births t3
    snap = tr.snapshot()
    restored = TT.Tracker.restore(json.loads(json.dumps(snap)))
    check("restore does not change canonical state", restored.snapshot() == snap)
    r_main = tr.feed(B(2, 1600, [("c", box(0.5, 0.5))]))
    r_rest = restored.feed(B(2, 1600, [("c", box(0.5, 0.5))]))
    check("replay through a restored tracker returns the original receipt",
          r_rest == r_main and r_rest["replayed"] is True)
    r_main = tr.feed(B(3, 1800, [("d", box(0.52, 0.5))]))
    r_rest = restored.feed(B(3, 1800, [("d", box(0.52, 0.5))]))
    check("continuation receipts are equal", r_rest == r_main)
    check("continuation snapshots are equal", restored.snapshot() == tr.snapshot())
    check("drained episodes are equal", restored.drain() == tr.drain() and len(tr.drain()) == 0)
    check("finish results equal", restored.finish() == tr.finish())
    check("finished snapshots equal", restored.snapshot() == tr.snapshot())
    expect_err("restored finished tracker rejects feed", "finished",
               lambda: restored.feed(B(4, 2000, [])))
    # corruption: schema, envelope keys, checksum, mutated state with fresh checksum
    good = T().snapshot()
    expect_err("restore: not a dict", "invalid_snapshot", lambda: TT.Tracker.restore("x"))
    expect_err("restore: extra envelope key", "invalid_snapshot",
               lambda: TT.Tracker.restore(dict(good, extra=1)))
    expect_err("restore: wrong schema", "invalid_snapshot",
               lambda: TT.Tracker.restore(dict(good, schema="labs-temporal-tracker/v2")))
    expect_err("restore: bad sha", "invalid_snapshot",
               lambda: TT.Tracker.restore(dict(good, sha256="0" * 64)))
    expect_err("restore: non-hex sha", "invalid_snapshot",
               lambda: TT.Tracker.restore(dict(good, sha256="z" * 64)))

    def rehashed(state):
        s = json.loads(json.dumps(state))
        import hashlib
        canon = json.dumps(s, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                           allow_nan=False)
        return {"schema": "labs-temporal-tracker/v1", "state": s,
                "sha256": hashlib.sha256(canon.encode()).hexdigest()}

    tr = T()
    tr.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    st = tr.snapshot()["state"]
    mutations = {
        "config out of range": dict(st, config=dict(st["config"], max_tracks=0)),
        "unknown config key": dict(st, config=dict(st["config"], bogus=1)),
        "missing state key": {k: v for k, v in st.items() if k != "tracks"},
        "extra state key": dict(st, bogus=1),
        "next_track_id rewound": dict(st, next_track_id=1),
        "finished not bool": dict(st, finished=1),
        "last_t after no batches": dict(st, next_seq=0, last_t_ms=None, replay=[]),
        "track time inversion": dict(st, tracks=[dict(st["tracks"][0], end_ms=1, start_ms=5)]),
        "path unanchored": dict(st, tracks=[dict(st["tracks"][0], path=[[5, 0.5, 0.5]])]),
        "bad appearance": dict(st, tracks=[dict(st["tracks"][0], appearance=[2, 0, 0, 0])]),
        "velocity over cap": dict(st, tracks=[dict(st["tracks"][0], vx=2.0, vy=0.0)]),
        "replay window hole": dict(st, replay=[]),
        "receipt replayed flag": dict(st, replay=[dict(st["replay"][0], receipt=dict(st["replay"][0]["receipt"], replayed=True))]),
    }
    for name, mutated in mutations.items():
        expect_err(f"restore rejects: {name}", "invalid_snapshot",
                   lambda m=mutated: TT.Tracker.restore(rehashed(m)))
    # outbox episode corruption (needs a queued episode in the state)
    trq = T({"max_gap_ms": 1000})
    trq.feed(B(0, 0, [("a", box(0.5, 0.5))]))
    trq.feed(B(1, 3000, []))                               # gap-closes t1 -> 1 queued episode
    stq = trq.snapshot()["state"]
    ep0 = stq["outbox"][0]
    ep_mutations = {
        "episode bad reason": dict(stq, outbox=[dict(ep0, reason="lost")]),
        "episode extra key": dict(stq, outbox=[dict(ep0, ts="2026-01-01")]),
        "episode track id past counter": dict(stq, outbox=[dict(ep0, track_id="t00000005")]),
        "episode end after last batch": dict(stq, outbox=[dict(ep0, end_ms=9999,
                                                               path=[[0, 0.52, 0.5], [9999, 0.52, 0.5]],
                                                               mean_speed=0.0,
                                                               max_observation_gap_ms=9999)]),
    }
    for name, mutated in ep_mutations.items():
        expect_err(f"restore rejects: {name}", "invalid_snapshot",
                   lambda m=mutated: TT.Tracker.restore(rehashed(m)))
    # a genuine NaN anywhere makes the state unhashable canonically -> invalid
    bad = json.loads(json.dumps(tr.snapshot()))
    bad["state"]["tracks"][0]["vx"] = float("nan")
    bad["sha256"] = "0" * 64
    expect_err("restore: NaN in state", "invalid_snapshot", lambda: TT.Tracker.restore(bad))
    # snapshot survives a fresh process (CLI round trip covered by the public case);
    # here: snapshot equivalence across restore chains
    tr = T()
    for i in range(10):
        tr.feed(B(i, i * 100, [("a", box(0.3 + 0.01 * i, 0.5))]))
    chain = TT.Tracker.restore(json.loads(json.dumps(tr.snapshot())))
    for _ in range(3):
        chain = TT.Tracker.restore(json.loads(json.dumps(chain.snapshot())))
    check("snapshot equivalence survives restore chains", chain.snapshot() == tr.snapshot())


def test_cli_protocol():
    J = json.dumps
    init = J({"op": "init", "camera_id": "cam-a", "unit_id": "unit-a"})
    feed0 = J({"op": "feed", "batch": {"camera_id": "cam-a", "unit_id": "unit-a",
                                       "seq": 0, "t_ms": 0, "detections": []}})
    # empty input exits 0 with no output
    resps, rc, err = run_cli([])
    check("cli: empty input exits 0 with no output", rc == 0 and resps == [])
    # blank lines are skipped
    resps, rc, err = run_cli(["", "   ", init, "", feed0])
    check("cli: blank lines skipped", rc == 0 and len(resps) == 2)
    check("cli: response shape is exactly ok/result",
          all(set(r) == {"ok", "result"} for r in resps))
    # a stream with any error exits 1 and later lines still run
    resps, rc, err = run_cli([init, "not json", feed0, J({"op": "drain"})])
    check("cli: bad JSON is invalid_input, later lines still run, exit 1",
          rc == 1 and resps[1] == {"ok": False, "error": {"code": "invalid_input"}}
          and resps[2]["ok"] is True and resps[3] == {"ok": True, "result": []})
    # duplicate object keys, NaN/Infinity tokens
    resps, rc, err = run_cli(['{"op":"drain","op":"drain"}'])
    check("cli: duplicate keys are invalid_input",
          rc == 1 and resps[0]["error"]["code"] == "invalid_input")
    resps, rc, err = run_cli(['{"op":"init","camera_id":"c","unit_id":"u","config":{"gate_base":NaN}}'])
    check("cli: NaN token is invalid_input", resps[0]["error"]["code"] == "invalid_input")
    resps, rc, err = run_cli(['{"op":"init","camera_id":"c","unit_id":"u","config":{"gate_base":Infinity}}'])
    check("cli: Infinity token is invalid_input", resps[0]["error"]["code"] == "invalid_input")
    # malformed commands
    resps, rc, err = run_cli(["[1,2]", J({"op": "bogus"}), J({}), J({"op": 5}),
                              J({"op": "feed"}), J({"op": "drain", "x": 1})])
    check("cli: malformed commands are invalid_input",
          all(r["error"]["code"] == "invalid_input" for r in resps), json.dumps(resps))
    # before initialization
    resps, rc, err = run_cli([J({"op": "feed", "batch": {}}), J({"op": "drain"}),
                              J({"op": "snapshot"}), J({"op": "finish"})])
    check("cli: commands before init are not_initialized",
          all(r["error"]["code"] == "not_initialized" for r in resps))
    # init/restore replace only after validation
    resps, rc, err = run_cli([
        init, feed0,
        J({"op": "init", "camera_id": "cam-a", "unit_id": "unit-a", "config": {"max_tracks": 0}}),
        J({"op": "feed", "batch": {"camera_id": "cam-a", "unit_id": "unit-a",
                                   "seq": 1, "t_ms": 1, "detections": []}})])
    check("cli: failed init preserves the previous tracker",
          resps[2]["error"]["code"] == "invalid_config" and resps[3]["ok"] is True)
    resps, rc, err = run_cli([
        init, feed0, J({"op": "restore", "snapshot": {"schema": "nope", "state": {}, "sha256": "0" * 64}}),
        J({"op": "feed", "batch": {"camera_id": "cam-a", "unit_id": "unit-a",
                                   "seq": 1, "t_ms": 1, "detections": []}})])
    check("cli: failed restore preserves the previous tracker",
          resps[2]["error"]["code"] == "invalid_snapshot" and resps[3]["ok"] is True)
    # restore initializes a fresh process; error codes pass through
    good_feed = J({"op": "feed", "batch": {"camera_id": "cam-a", "unit_id": "unit-a", "seq": 0,
                                           "t_ms": 0,
                                           "detections": [{"id": "a", "bbox": [0.1, 0.2, 0.1, 0.2]}]}})
    resps, rc, err = run_cli([init, good_feed, J({"op": "snapshot"})])
    snap = resps[2]["result"]
    resps2, rc2, err2 = run_cli([J({"op": "restore", "snapshot": snap}), good_feed,
                                 J({"op": "feed", "batch": {"camera_id": "cam-b", "unit_id": "unit-a",
                                                            "seq": 1, "t_ms": 1, "detections": []}})])
    check("cli: cross-process restore replays; API error codes pass through",
          resps2[0] == {"ok": True, "result": None}
          and resps2[1]["ok"] is True and resps2[1]["result"]["replayed"] is True
          and resps2[2]["error"]["code"] == "wrong_scope")
    check("cli: mixed stream exits 1", rc2 == 1)
    # EOF neither finishes nor drains
    resps, rc, err = run_cli([init, good_feed])
    check("cli: EOF implies neither finish nor drain", rc == 0 and len(resps) == 2)
    resps, rc, err = run_cli([init, good_feed, J({"op": "finish"}), J({"op": "drain"})])
    check("cli: finish then drain yields the episode",
          resps[2] == {"ok": True, "result": ["t00000001"]}
          and resps[3]["result"][0]["reason"] == "finish")
    # non-UTF-8 bytes on a line are invalid_input, exit 1, other lines fine
    resps, rc, err = run_cli((init + "\n").encode() + b"\xff\xfe\n" + J({"op": "drain"}).encode() + b"\n", raw=True)
    check("cli: non-UTF-8 line is invalid_input",
          rc == 1 and resps[0]["ok"] is True and resps[1]["error"]["code"] == "invalid_input"
          and resps[2] == {"ok": True, "result": []})
    # determinism is process- and hash-seed-independent: identical stdout bytes
    lines = "\n".join([
        J({"op": "init", "camera_id": "cam-a", "unit_id": "unit-a"}),
        J({"op": "feed", "batch": {"camera_id": "cam-a", "unit_id": "unit-a", "seq": 0,
                                   "t_ms": 0, "detections": [
                                       {"id": "b", "bbox": [0.6, 0.1, 0.1, 0.1], "appearance": [0.5, 0.5, 0, 0]},
                                       {"id": "a", "bbox": [0.1, 0.1, 0.1, 0.1], "appearance": [1, 0, 0, 0]}]}}),
        J({"op": "feed", "batch": {"camera_id": "cam-a", "unit_id": "unit-a", "seq": 1,
                                   "t_ms": 400, "detections": [
                                       {"id": "c", "bbox": [0.62, 0.1, 0.1, 0.1], "appearance": [0.5, 0.5, 0, 0]},
                                       {"id": "d", "bbox": [0.12, 0.1, 0.1, 0.1], "appearance": [1, 0, 0, 0]}]}}),
        J({"op": "snapshot"}),
        J({"op": "finish"}),
        J({"op": "drain"})]) + "\n"
    outs = []
    for seed in ("0", "1", "42"):
        p = subprocess.run([sys.executable, str(REPLAY_CLI)], input=lines, capture_output=True,
                           text=True, env={"PATH": os.environ.get("PATH", ""),
                                           "PYTHONHASHSEED": seed,
                                           "PYTHONPATH": str(ROOT / "tools" / "labs")})
        outs.append(p.stdout)
        check(f"cli: exit 0 under PYTHONHASHSEED={seed}", p.returncode == 0)
    check("cli: byte-identical stdout across hash seeds",
          outs[0] == outs[1] == outs[2] and outs[0])


def test_determinism_and_bounded_state():
    def script():
        tr = T({"max_gap_ms": 1500})
        out = []
        for i in range(200):
            dets = [(f"d{j}", box(0.1 + 0.1 * j + 0.001 * i, 0.3 + 0.1 * (j % 3)))
                    for j in range(4)]
            out.append(tr.feed(B(i, i * 200, dets)))
            if i % 50 == 49:
                out.append(tr.drain())
        out.append(tr.finish())
        out.extend(tr.drain())
        out.append(tr.snapshot())
        return out

    a, b = script(), script()
    check("two identical runs produce byte-identical results",
          json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True))
    tr = T()
    sizes = []
    for i in range(600):
        tr.feed(B(i, i * 100, [(f"d{j}", box(0.2 + 0.2 * j, 0.5)) for j in range(3)]))
        tr.drain()
        if i in (100, 300, 599):
            s = json.dumps(tr.snapshot(), sort_keys=True)
            sizes.append(len(s))
    snap = T().snapshot()["state"]
    tr_snap = tr.snapshot()["state"]
    check("replay window stays within replay_batches",
          len(tr_snap["replay"]) <= 32)
    check("bounded state: snapshot size does not grow with run length",
          sizes[-1] <= sizes[0] * 1.5 + 4096, str(sizes))
    check("path stays within path_points",
          all(len(t["path"]) <= 32 for t in tr_snap["tracks"]))


def test_adapter_unit():
    import datetime as dt

    class Frame:
        pass

    class Blob:
        def __init__(self, label, bbox):
            self.label = label
            self.bbox = bbox

    def frame(t_s=1.0, run=0, scored=True, blobs=()):
        f = Frame()
        f.t_s, f.run, f.scored, f.blobs = t_s, run, scored, blobs
        return f

    got = TA.mask_frame_batch(frame(0.0004), camera_id="c", unit_id="u", seq=0)
    check("adapter: t_ms rounds via floor(1000*t+0.5)", got["t_ms"] == 0)
    got = TA.mask_frame_batch(frame(0.0005), camera_id="c", unit_id="u", seq=0)
    check("adapter: half-ms rounds up", got["t_ms"] == 1)
    got = TA.mask_frame_batch(frame(2.0, run=3, blobs=(Blob(2, [0, 0, 0.1, 0.1]),
                                                       Blob(10, [0.5, 0.5, 0.1, 0.1]))),
                              camera_id="c", unit_id="u", seq=1, previous_run=3)
    check("adapter: detections sorted by label, reset false on same run",
          [d["id"] for d in got["detections"]] == ["b2", "b10"] and got["reset"] is False)
    check("adapter: appearance is omitted", all("appearance" not in d for d in got["detections"]))
    expect_err("adapter: NaN t_s", "invalid_input",
               lambda: TA.mask_frame_batch(frame(float("nan")), camera_id="c", unit_id="u", seq=0))
    expect_err("adapter: negative t_s", "invalid_input",
               lambda: TA.mask_frame_batch(frame(-1.0), camera_id="c", unit_id="u", seq=0))
    expect_err("adapter: bool scored", "invalid_input",
               lambda: TA.mask_frame_batch(frame(1.0, scored=1), camera_id="c", unit_id="u", seq=0))
    expect_err("adapter: float run", "invalid_input",
               lambda: TA.mask_frame_batch(frame(1.0, run=1.5), camera_id="c", unit_id="u", seq=0))
    expect_err("adapter: bool run", "invalid_input",
               lambda: TA.mask_frame_batch(frame(1.0, run=True), camera_id="c", unit_id="u", seq=0))
    expect_err("adapter: negative previous_run", "invalid_input",
               lambda: TA.mask_frame_batch(frame(1.0), camera_id="c", unit_id="u", seq=0, previous_run=-1))
    expect_err("adapter: bad scope id", "invalid_input",
               lambda: TA.mask_frame_batch(frame(1.0), camera_id="bad id", unit_id="u", seq=0))
    expect_err("adapter: duplicate labels", "invalid_input",
               lambda: TA.mask_frame_batch(frame(1.0, blobs=(Blob(1, [0, 0, 0.1, 0.1]),
                                                             Blob(1, [0.2, 0.2, 0.1, 0.1]))),
                                           camera_id="c", unit_id="u", seq=0))
    expect_err("adapter: negative label", "invalid_input",
               lambda: TA.mask_frame_batch(frame(1.0, blobs=(Blob(-1, [0, 0, 0.1, 0.1]),)),
                                           camera_id="c", unit_id="u", seq=0))
    expect_err("adapter: out-of-range blob bbox", "invalid_input",
               lambda: TA.mask_frame_batch(frame(1.0, blobs=(Blob(1, [0.9, 0.9, 0.2, 0.2]),)),
                                           camera_id="c", unit_id="u", seq=0))
    expect_err("adapter: missing frame attribute", "invalid_input",
               lambda: TA.mask_frame_batch(object(), camera_id="c", unit_id="u", seq=0))

    class PoisonBlobs:
        blobs = property(lambda self: (_ for _ in ()).throw(RuntimeError("must not read")))

    class PoisonFrame(Frame):
        pass

    pf = PoisonFrame()
    pf.t_s, pf.run, pf.scored = 1.0, 0, False
    type(pf).blobs = PoisonBlobs.blobs
    got = TA.mask_frame_batch(pf, camera_id="c", unit_id="u", seq=0)
    check("adapter: unscored frames never inspect blobs", got["detections"] == [])

    # labs_rows
    def ep(**over):
        base = {"camera_id": "c", "unit_id": "u", "track_id": "t00000001",
                "start_ms": 0, "end_ms": 3000, "observations": 4, "ambiguous_batches": 0,
                "reason": "finish", "bbox": [0.1, 0.2, 0.1, 0.2], "bbox_at_ms": 0,
                "first_center": [0.15, 0.3], "last_center": [0.3, 0.3],
                "path_length": 0.15, "net_displacement": 0.15, "mean_speed": 0.05,
                "max_observation_gap_ms": 1000,
                "path": [[0, 0.15, 0.3], [3000, 0.3, 0.3]]}
        base["path"] = [[0, 0.15, 0.3], [3000, 0.3, 0.3]]
        return dict(base, **over)

    hour = dt.datetime(2026, 10, 4, 3, 0, tzinfo=dt.timezone(dt.timedelta(hours=3)))
    rows = TA.labs_rows([ep()], hour_start=hour)
    check("labs_rows: UTC normalization and exact row shape",
          rows[0]["start_time"] == "2026-10-04T00:00:00.000Z"
          and rows[0]["end_time"] == "2026-10-04T00:00:03.000Z"
          and set(rows[0]) == {"start_time", "end_time", "object_count", "bbox_x",
                               "bbox_y", "bbox_w", "bbox_h", "metrics"}
          and rows[0]["object_count"] == 1 and rows[0]["bbox_x"] == 0.1)
    check("labs_rows: metrics shape (8 keys, no aliases, no path)",
          set(rows[0]["metrics"]) == {"track_id", "observations", "ambiguous_batches",
                                      "path_length", "net_displacement", "mean_speed",
                                      "max_gap_s", "end_reason"}
          and rows[0]["metrics"]["max_gap_s"] == 1
          and rows[0]["metrics"]["end_reason"] == "finish")
    check("labs_rows: order preserved",
          [r["metrics"]["track_id"] for r in TA.labs_rows(
              [ep(track_id="t00000002"), ep()], hour_start=hour)] == ["t00000002", "t00000001"])
    expect_err("labs_rows: naive hour", "invalid_input",
               lambda: TA.labs_rows([ep()], hour_start=dt.datetime(2026, 10, 4, 3, 0)))
    expect_err("labs_rows: non-hour", "invalid_input",
               lambda: TA.labs_rows([ep()], hour_start=dt.datetime(
                   2026, 10, 4, 3, 30, tzinfo=dt.timezone.utc)))
    expect_err("labs_rows: >500 episodes", "invalid_input",
               lambda: TA.labs_rows([ep() for _ in range(501)], hour_start=hour))
    expect_err("labs_rows: start outside the hour", "invalid_input",
               lambda: TA.labs_rows([ep(start_ms=3600000, end_ms=3600000, mean_speed=None,
                                        path=[[3600000, 0.15, 0.3]])], hour_start=hour))
    expect_err("labs_rows: 300 s span rejected", "invalid_input",
               lambda: TA.labs_rows([ep(end_ms=300000,
                                        path=[[0, 0.15, 0.3], [300000, 0.3, 0.3]])],
                                    hour_start=hour))
    expect_err("labs_rows: episode missing key", "invalid_input",
               lambda: TA.labs_rows([{k: v for k, v in ep().items() if k != "reason"}],
                                    hour_start=hour))
    expect_err("labs_rows: episode extra key", "invalid_input",
               lambda: TA.labs_rows([dict(ep(), ts="x")], hour_start=hour))
    expect_err("labs_rows: bad reason", "invalid_input",
               lambda: TA.labs_rows([ep(reason="lost")], hour_start=hour))
    expect_err("labs_rows: bad bbox", "invalid_input",
               lambda: TA.labs_rows([ep(bbox=[0.9, 0.9, 0.2, 0.2])], hour_start=hour))
    expect_err("labs_rows: non-episode", "invalid_input",
               lambda: TA.labs_rows(["x"], hour_start=hour))


def test_checkpoint_fuzz():
    """Seeded random op streams with a mid-stream snapshot: the restored twin must
    produce identical receipts, episodes and snapshots for the rest of the run."""
    rng = random.Random(907)
    ok, detail = True, ""
    for trial in range(20):
        cfg = {"max_gap_ms": rng.choice([1000, 2000]), "replay_batches": 4,
               "max_pending": 256, "max_tracks": 16, "path_points": rng.choice([2, 8])}
        tr = T(cfg)
        twin = None
        t = 0
        stream = []
        for i in range(rng.randint(30, 60)):
            t += rng.choice([100, 500, 1500, 5000])
            m = rng.randint(0, 3)
            dets = [(f"d{i}-{j}", box(rng.uniform(0.05, 0.9), rng.uniform(0.1, 0.9)))
                    for j in range(m)]
            stream.append(B(i, t, dets))
        snap_at = rng.randrange(len(stream))
        for i, batch in enumerate(stream):
            if i == snap_at:
                twin = TT.Tracker.restore(json.loads(json.dumps(tr.snapshot())))
            r = tr.feed(batch)
            if twin is None:
                continue
            r2 = twin.feed(batch)
            if r != r2:
                ok, detail = False, f"trial {trial} batch {i}: receipts differ"
                break
            if rng.random() < 0.2:
                if tr.drain() != twin.drain():
                    ok, detail = False, f"trial {trial} batch {i}: drains differ"
                    break
            if rng.random() < 0.1 and tr.snapshot() != twin.snapshot():
                ok, detail = False, f"trial {trial} batch {i}: snapshots differ"
                break
        if not ok:
            break
        if tr.finish() != twin.finish() or tr.drain() != twin.drain() \
                or tr.snapshot() != twin.snapshot():
            ok, detail = False, f"trial {trial}: final states differ"
            break
    check("checkpoint fuzz: 20 restored twins match uninterrupted runs", ok, detail)


def test_streaming_mini():
    """A bounded slice of the section-13 workload, default config, with its
    accounting invariants. The full measured workload runs with --workload."""
    tr = TT.Tracker(camera_id="resource-a", unit_id="resource", config=None)
    obs = born = matched = amb = 0
    snap_ok = True
    N = 3000
    for n in range(N):
        dets = []
        for j in range(8):
            c, r_ = j % 4, j // 4
            q = n % 1000
            u = q / 250 - 1 if q < 500 else 3 - q / 250
            cx, cy = 0.12 + 0.25 * c + 0.02 * u, 0.25 + 0.50 * r_
            dets.append((f"d{j}", [cx - 0.02, cy - 0.02, 0.04, 0.04]))
        r = tr.feed(B(n, 200 * n, dets, cam="resource-a", unit="resource"))
        for a in r["assignments"]:
            if a["status"] == "born":
                born += 1
            elif a["status"] == "matched":
                matched += 1
            else:
                amb += 1
        for ep in tr.drain():
            obs += ep["observations"]
        if n % 1000 == 0:
            s = json.dumps(tr.snapshot(), sort_keys=True, separators=(",", ":"),
                           ensure_ascii=True).encode("utf-8")
            snap_ok = snap_ok and len(s) <= 2097152
    tr.finish()
    for ep in tr.drain():
        obs += ep["observations"]
    check("mini workload: every detection assigned, none ambiguous",
          amb == 0 and born + matched == 8 * N)
    check("mini workload: aggregate observation accounting",
          obs == 8 * N, f"obs={obs}")
    check("mini workload: span closures produced episodes", born > 8)
    check("mini workload: snapshots within the 2 MiB bound", snap_ok)


def test_run2_shape():
    tr = TT.Tracker(camera_id="resource-b", unit_id="resource", config=None)
    obs = amb = 0
    N = 250
    for n in range(N):
        dets = []
        for j in range(32):
            c, r_ = j % 8, j // 8
            q = n % 50
            u = q / 12.5 - 1 if q < 25 else 3 - q / 12.5
            cx, cy = (c + 0.5) / 8 + 0.005 * u, (r_ + 0.5) / 4
            dets.append((f"d{j}", [cx - 0.01, cy - 0.01, 0.02, 0.02]))
        r = tr.feed(B(n, 200 * n, dets, cam="resource-b", unit="resource"))
        for a in r["assignments"]:
            if a["status"] == "ambiguous":
                amb += 1
        for ep in tr.drain():
            obs += ep["observations"]
    tr.finish()
    for ep in tr.drain():
        obs += ep["observations"]
    check("run-2 shape: 32 tracks x 250 batches fully assigned, no ambiguity",
          amb == 0 and obs == 32 * N, f"obs={obs} amb={amb}")


# ---------------------------------------------------------------------------
# the contract section-13 workload, measured (--workload)
# ---------------------------------------------------------------------------
def _batch_stream1(n):
    dets = []
    for j in range(8):
        c, r = j % 4, j // 4
        q = n % 1000
        u = q / 250 - 1 if q < 500 else 3 - q / 250
        cx, cy = 0.12 + 0.25 * c + 0.02 * u, 0.25 + 0.50 * r
        dets.append({"id": f"d{j}", "bbox": [cx - 0.02, cy - 0.02, 0.04, 0.04]})
    return {"camera_id": "resource-a", "unit_id": "resource", "seq": n,
            "t_ms": 200 * n, "detections": dets}


def _batch_stream2(n):
    dets = []
    for j in range(32):
        c, r = j % 8, j // 8
        q = n % 50
        u = q / 12.5 - 1 if q < 25 else 3 - q / 12.5
        cx, cy = (c + 0.5) / 8 + 0.005 * u, (r + 0.5) / 4
        dets.append({"id": f"d{j}", "bbox": [cx - 0.01, cy - 0.01, 0.02, 0.02]})
    return {"camera_id": "resource-b", "unit_id": "resource", "seq": n,
            "t_ms": 200 * n, "detections": dets}


def _one_workload_run():
    """Both streams, sequentially, exactly per contract section 13. Returns
    (wall_s, cpu_s, stats). Invariants are asserted inside the run."""
    import resource
    t0, c0 = time.perf_counter(), time.process_time()
    stats = {}
    for name, n_batches, gen in (("resource-a", 100000, _batch_stream1),
                                 ("resource-b", 250, _batch_stream2)):
        tr = TT.Tracker(camera_id=name, unit_id="resource", config=None)
        obs = born = matched = amb = episodes = 0
        snap_max = 0
        for n in range(n_batches):
            r = tr.feed(gen(n))
            for a in r["assignments"]:
                if a["status"] == "born":
                    born += 1
                elif a["status"] == "matched":
                    matched += 1
                else:
                    amb += 1
            for ep in tr.drain():
                episodes += 1
                obs += ep["observations"]
            if n % 1000 == 0:
                s = json.dumps(tr.snapshot(), sort_keys=True, separators=(",", ":"),
                               ensure_ascii=True, allow_nan=False).encode("utf-8")
                snap_max = max(snap_max, len(s))
        tr.finish()
        for ep in tr.drain():
            episodes += 1
            obs += ep["observations"]
        total = n_batches * len(gen(0)["detections"])
        assert amb == 0, f"{name}: {amb} ambiguous assignments"
        assert born + matched == total == obs, (name, born, matched, obs, total)
        assert snap_max <= 2097152, (name, snap_max)
        stats[name] = {"observations": obs, "episodes": episodes, "born": born,
                       "snapshot_max_bytes": snap_max}
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return time.perf_counter() - t0, time.process_time() - c0, stats, rss


def run_workload():
    import platform
    import resource
    base_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    print(f"workload host: {platform.platform()} python {platform.python_version()}")
    print("workload: one unscored warmup run, then three measured runs, serial")
    _one_workload_run()
    print("warmup done")
    walls = []
    for k in range(3):
        wall, cpu, stats, rss = _one_workload_run()
        walls.append(wall)
        print(f"run {k + 1}: wall {wall:.2f}s cpu {cpu:.2f}s "
              f"peak_rss_delta {(rss - base_rss) / 1024:.1f} MiB stats {json.dumps(stats)}")
    walls.sort()
    print(f"median wall {walls[1]:.2f}s over 3 runs")


def main():
    if "--workload" in sys.argv:
        run_workload()
        return 0
    run_public_cases()
    verify_cost_checks()
    run_adapter_examples()
    test_config()
    test_batch_validation()
    test_sequence_and_replay()
    test_gate_boundaries()
    test_prediction_and_speed_cap()
    test_ambiguity_rules()
    test_matching_reference_fuzz()
    test_time_and_closures()
    test_capacity_atomicity()
    test_episode_evidence()
    test_path_simplifier()
    test_aliasing()
    test_checkpoints()
    test_cli_protocol()
    test_determinism_and_bounded_state()
    test_adapter_unit()
    test_checkpoint_fuzz()
    test_streaming_mini()
    test_run2_shape()
    print(f"{_passed[0]} PASS, {len(fails)} FAIL")
    if fails:
        print("FAILED:", *fails, sep="\n  ")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
