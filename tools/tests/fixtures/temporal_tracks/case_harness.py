"""Interpreter for `docs/benchmarks/labs-tracking/fixtures/cases.json`.

The published cases are DATA, not a test runner: each operation carries the
contract JSONL command plus fixture-only annotations (`on`, `expect`,
`capture_result`, `snapshot_from`, `expect_result_equal`) that say what an
independent harness must check. This module implements those annotations, and
nothing else, so the same file drives two independent paths:

  * `mode="api"` -- the operations go straight to `temporal_tracks.Tracker` in
    this process;
  * `mode="cli"` -- the operations are grouped per `on` environment, each group
    replayed as one `replay_temporal_tracks.py` subprocess, which also checks
    the stream's exit status.

Both modes apply the same numeric rule the fixture header states: measurement
floats compare at absolute/relative tolerance 1e-9, while IDs, counts,
statuses, quantised costs, ordering and integer timestamps are exact. Where an
operation's `expect` carries only `ok`, the normative result SHAPE for that op
is checked instead of nothing at all -- a receipt with a missing key, an episode
with an invented field or a snapshot without a checksum is a failure here even
though the fixture did not spell the value out.

`adapter_examples` are pure-Python cases outside the JSONL protocol, so they run
in-process against the real `labs_foreground_mask.Blob` in both modes.
"""
from __future__ import annotations

import json
import pathlib
import subprocess
import sys
from datetime import datetime
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "tools" / "labs"))

import temporal_tracks as tt                                # noqa: E402
from temporal_tracks import Tracker, TrackingError           # noqa: E402

CASES_JSON = ROOT / "docs" / "benchmarks" / "labs-tracking" / "fixtures" / "cases.json"
CLI = ROOT / "tools" / "labs" / "replay_temporal_tracks.py"
TOL = 1e-9


# ---------------------------------------------------------------------------
# comparison: the fixture's numeric rule
# ---------------------------------------------------------------------------
def _num_eq(a: Any, b: Any) -> bool:
    if a == b:
        return True
    try:
        return abs(a - b) <= TOL * max(1.0, abs(a), abs(b))
    except TypeError:
        return False


def equal(expected: Any, actual: Any) -> bool:
    """Complete equality: same keys, same list length and order, floats within
    tolerance, everything else exact."""
    if isinstance(expected, bool) or isinstance(actual, bool):
        return isinstance(expected, bool) and isinstance(actual, bool) and expected is actual
    if isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
        return _num_eq(expected, actual)
    if isinstance(expected, dict):
        return (isinstance(actual, dict) and set(expected) == set(actual)
                and all(equal(expected[k], actual[k]) for k in expected))
    if isinstance(expected, list):
        return (isinstance(actual, list) and len(expected) == len(actual)
                and all(equal(a, b) for a, b in zip(expected, actual)))
    if expected is None or actual is None:
        return expected is None and actual is None
    if isinstance(expected, str):
        return isinstance(actual, str) and expected == actual
    return False


def subset(expected: Any, actual: Any) -> bool:
    """Recursive dict subset; lists still require the stated length and order."""
    if isinstance(expected, dict):
        return (isinstance(actual, dict)
                and all(k in actual and subset(v, actual[k]) for k, v in expected.items()))
    if isinstance(expected, list):
        return (isinstance(actual, list) and len(expected) == len(actual)
                and all(subset(a, b) for a, b in zip(expected, actual)))
    return equal(expected, actual)


def describe(expected: Any, actual: Any, limit: int = 400) -> str:
    try:
        e = json.dumps(expected, sort_keys=True)[:limit]
        a = json.dumps(actual, sort_keys=True, default=repr)[:limit]
    except (TypeError, ValueError):
        e, a = repr(expected)[:limit], repr(actual)[:limit]
    return f"expected {e} got {a}"


# ---------------------------------------------------------------------------
# normative result shapes, for operations whose `expect` carries only `ok`
# ---------------------------------------------------------------------------
def shape_ok(op: str, result: Any) -> bool:
    if op in ("init", "restore"):
        return result is None
    if op == "drain":
        return isinstance(result, list) and all(_episode_shape(e) for e in result)
    if op == "finish":
        return (isinstance(result, list)
                and all(isinstance(x, str) and tt._TRACK_ID_RE.fullmatch(x) for x in result))
    if op == "snapshot":
        return _snapshot_shape(result)
    if op == "feed":
        return _receipt_shape(result)
    return False


def _receipt_shape(r: Any) -> bool:
    if not isinstance(r, dict) or set(r) != {"seq", "replayed", "assignments", "closed"}:
        return False
    if not isinstance(r["seq"], int) or isinstance(r["seq"], bool):
        return False
    if not isinstance(r["replayed"], bool) or not isinstance(r["closed"], list):
        return False
    if not all(isinstance(c, str) and tt._TRACK_ID_RE.fullmatch(c) for c in r["closed"]):
        return False
    ids = []
    for a in r["assignments"]:
        if not isinstance(a, dict) or set(a) != {"detection_id", "track_id", "status", "reason"}:
            return False
        if a["status"] not in tt.STATUSES:
            return False
        if (a["status"] == "ambiguous") != (a["reason"] is not None):
            return False
        if a["reason"] is not None and a["reason"] not in tt.AMBIGUITY_REASONS:
            return False
        if (a["track_id"] is None) != (a["status"] == "ambiguous"):
            return False
        ids.append(a["detection_id"])
    return ids == sorted(ids) and len(set(ids)) == len(ids)


def _episode_shape(e: Any) -> bool:
    try:
        tt.validate_episode(e)
    except TrackingError:
        return False
    return True


def _snapshot_shape(s: Any) -> bool:
    if not isinstance(s, dict) or set(s) != {"schema", "state", "sha256"}:
        return False
    if s["schema"] != tt.SCHEMA or not isinstance(s["state"], dict):
        return False
    want = s["sha256"]
    if not isinstance(want, str) or len(want) != 64:
        return False
    import hashlib
    try:
        blob = tt.canonical_state_json(s["state"])
    except (TypeError, ValueError):
        return False
    return hashlib.sha256(blob.encode("utf-8")).hexdigest() == want


# ---------------------------------------------------------------------------
# one case
# ---------------------------------------------------------------------------
class CaseFailure(Exception):
    pass


def _apply(session: Any, op: str, cmd: dict, mode: str) -> Any:
    """Run one command against an environment and return its result."""
    if op == "init":
        session["tracker"] = Tracker(cmd["camera_id"], cmd["unit_id"], cmd.get("config"))
        return None
    if op == "restore":
        session["tracker"] = Tracker.restore(cmd["snapshot"])
        return None
    tracker = session.get("tracker")
    if tracker is None:
        raise TrackingError("not_initialized", f"{op} before init")
    if op == "feed":
        return tracker.feed(cmd["batch"])
    if op == "drain":
        return tracker.drain()
    if op == "snapshot":
        return tracker.snapshot()
    if op == "finish":
        return tracker.finish()
    raise TrackingError("invalid_input", f"unknown op {op!r}")


def run_case_api(case: dict) -> list[tuple[str, bool, str]]:
    """Every operation of one case, in process. Returns [(name, ok, detail)]."""
    out: list[tuple[str, bool, str]] = []
    envs: dict[str, dict] = {}
    captures: dict[str, Any] = {}
    drained: dict[str, Any] = {}
    for i, op_spec in enumerate(case["operations"]):
        on = op_spec.get("on", "main")
        session = envs.setdefault(on, {})
        cmd = json.loads(json.dumps(op_spec["command"]))     # an independent copy
        if "snapshot_from" in op_spec:
            cmd["snapshot"] = json.loads(json.dumps(captures[op_spec["snapshot_from"]]))
        name = f"{case['id']}[{i}] {on}/{cmd.get('op')}"
        expect = op_spec.get("expect", {})
        try:
            result = _apply(session, cmd["op"], cmd, "api")
            ok, detail = True, ""
            code = None
        except TrackingError as e:
            result, ok, detail, code = None, False, "", e.code
        want_ok = expect.get("ok", True)
        if bool(ok) != bool(want_ok):
            out.append((name, False,
                        f"expected ok={want_ok}, got ok={ok}"
                        + (f" code={code}" if code else "") + (f" {detail}" if detail else "")))
            continue
        if not ok:
            want_err = expect.get("error")
            if want_err is not None and not equal(want_err, {"code": code}):
                out.append((name, False, f"expected error {want_err}, got {{'code': {code!r}}}"))
                continue
            out.append((name, True, ""))
            continue
        if "result" in expect and not equal(expect["result"], result):
            out.append((name, False, describe(expect["result"], result)))
            continue
        if "result_subset" in expect and not subset(expect["result_subset"], result):
            out.append((name, False, "subset " + describe(expect["result_subset"], result)))
            continue
        if not shape_ok(cmd["op"], result):
            out.append((name, False, f"result does not have the normative shape: {result!r}"[:400]))
            continue
        if "expect_result_equal" in op_spec:
            ref = captures[op_spec["expect_result_equal"]]
            if not equal(ref, result):
                out.append((name, False,
                            f"differs from capture {op_spec['expect_result_equal']}: "
                            + describe(ref, result)))
                continue
        if "capture_result" in op_spec:
            captures[op_spec["capture_result"]] = json.loads(json.dumps(result))
            if cmd["op"] == "drain":
                drained[case["id"]] = captures[op_spec["capture_result"]]
        out.append((name, True, ""))
    return out


def run_case_cli(case: dict, timeout: float = 180.0) -> list[tuple[str, bool, str]]:
    """Every operation of one case, as JSONL subprocesses, one per `on` stream."""
    out: list[tuple[str, bool, str]] = []
    streams: dict[str, list[tuple[int, dict, dict]]] = {}
    captures: dict[str, Any] = {}
    # Captures must resolve in operation order, so the API decides their values
    # and the CLI streams are then checked against the same expectations.
    api = {n: (ok, detail) for n, ok, detail in run_case_api(case)}
    envs: dict[str, dict] = {}
    for i, op_spec in enumerate(case["operations"]):
        on = op_spec.get("on", "main")
        session = envs.setdefault(on, {})
        cmd = json.loads(json.dumps(op_spec["command"]))
        if "snapshot_from" in op_spec:
            cmd["snapshot"] = json.loads(json.dumps(captures[op_spec["snapshot_from"]]))
        streams.setdefault(on, []).append((i, cmd, op_spec))
        try:
            result = _apply(session, cmd["op"], cmd, "cli")
        except TrackingError:
            result = None
        if "capture_result" in op_spec and result is not None:
            captures[op_spec["capture_result"]] = json.loads(json.dumps(result))
    for on, items in streams.items():
        payload = "".join(json.dumps(cmd) + "\n" for _i, cmd, _s in items)
        try:
            proc = subprocess.run([sys.executable, str(CLI)], input=payload.encode("utf-8"),
                                  capture_output=True, timeout=timeout)
            crashed = None
        except subprocess.TimeoutExpired:
            out.append((f"{case['id']}/{on} cli", False, f"CLI timed out after {timeout} s"))
            continue
        lines = [ln for ln in proc.stdout.decode("utf-8", "replace").split("\n") if ln.strip()]
        if len(lines) != len(items):
            out.append((f"{case['id']}/{on} cli", False,
                        f"{len(items)} commands produced {len(lines)} responses; "
                        f"stderr={proc.stderr.decode('utf-8', 'replace')[:200]}"))
            continue
        responses = []
        bad = None
        for ln in lines:
            try:
                responses.append(json.loads(ln))
            except ValueError as e:
                bad = f"stdout is not JSONL at {ln[:80]!r}: {e}"
                break
        if bad:
            out.append((f"{case['id']}/{on} cli", False, bad))
            continue
        errors = 0
        for (i, cmd, spec), resp in zip(items, responses):
            name = f"{case['id']}[{i}] {on}/{cmd.get('op')} cli"
            expect = spec.get("expect", {})
            if not isinstance(resp, dict) or set(resp) - {"ok", "result", "error"}:
                out.append((name, False, f"response is not the contract shape: {resp!r}"[:300]))
                errors += 1
                continue
            want_ok = bool(expect.get("ok", True))
            got_ok = bool(resp.get("ok"))
            if got_ok != want_ok:
                out.append((name, False, f"expected ok={want_ok}, got {resp!r}"[:300]))
                errors += 1
                continue
            if not got_ok:
                errors += 1
                code = (resp.get("error") or {}).get("code")
                if "error" in expect and not equal(expect["error"], resp["error"]):
                    out.append((name, False, f"expected error {expect['error']}, got {resp['error']}"))
                    continue
                out.append((name, True, ""))
                continue
            result = resp["result"]
            if "result" in expect and not equal(expect["result"], result):
                out.append((name, False, describe(expect["result"], result)))
                errors += 0
                continue
            if "result_subset" in expect and not subset(expect["result_subset"], result):
                out.append((name, False, "subset " + describe(expect["result_subset"], result)))
                continue
            if not shape_ok(cmd["op"], result):
                out.append((name, False, f"result does not have the normative shape: {result!r}"[:400]))
                continue
            if "expect_result_equal" in spec:
                ref = captures.get(spec["expect_result_equal"])
                if ref is None or not equal(ref, result):
                    out.append((name, False,
                                f"differs from capture {spec['expect_result_equal']}: "
                                + describe(ref, result)))
                    continue
            out.append((name, True, ""))
        want_exit = 1 if errors else 0
        if proc.returncode != want_exit:
            out.append((f"{case['id']}/{on} exit", False,
                        f"{errors} error responses, expected exit {want_exit}, "
                        f"got {proc.returncode}; stderr={proc.stderr.decode('utf-8','replace')[:200]}"))
        else:
            out.append((f"{case['id']}/{on} exit={want_exit}", True, ""))
        if crashed:
            out.append((f"{case['id']}/{on} cli", False, str(crashed)))
    return out


# ---------------------------------------------------------------------------
# adapter_examples
# ---------------------------------------------------------------------------
class _Frame:
    """The lightweight frame the fixture README describes: the four fields the
    adapter reads, and no image data."""

    def __init__(self, t_s, run, scored, blobs):
        self.t_s = t_s
        self.run = run
        self.scored = scored
        self.blobs = blobs


def run_adapter_examples(doc: dict, episodes_by_case: dict[str, Any]) -> list[tuple[str, bool, str]]:
    import labs_foreground_mask as fm
    import temporal_tracks_adapter as ad
    out: list[tuple[str, bool, str]] = []
    for ex in doc.get("adapter_examples", []):
        if "blob" in ex:
            b = ex["blob"]
            blob = fm.Blob(label=b["label"], x=b["x"], y=b["y"], w=b["w"], h=b["h"],
                           area=b["area"], cx=b["cx"], cy=b["cy"],
                           frame_w=b["frame_w"], frame_h=b["frame_h"])
            f = ex["frame"]
            args = ex["arguments"]
            base_frame = _Frame(f["t_s"], f["run"], f["scored"], (blob,))
            try:
                got = ad.mask_frame_batch(base_frame, **args)
                ok, detail = equal(ex["expected_batch"], got), describe(ex["expected_batch"], got)
            except TrackingError as e:
                ok, detail = False, f"raised {e.code}: {e}"
            out.append((f"adapter {ex['id']}", ok, "" if ok else detail))
            for v_i, var in enumerate(ex.get("variants", [])):
                fo = dict(f)
                fo.update(var.get("frame_overrides", {}))
                a = dict(args)
                a.update(var.get("arguments_overrides", {}))
                frame = _Frame(fo["t_s"], fo["run"], fo["scored"],
                               () if not fo["scored"] else (blob,))
                try:
                    got = ad.mask_frame_batch(frame, **a)
                except TrackingError as e:
                    out.append((f"adapter {ex['id']} variant{v_i}", False, f"raised {e.code}: {e}"))
                    continue
                ok, detail = True, ""
                if "expected_detections" in var:
                    ok = equal(var["expected_detections"], got["detections"])
                    detail = describe(var["expected_detections"], got["detections"])
                if ok and "expected_reset" in var:
                    ok = var["expected_reset"] is got["reset"]
                    detail = f"expected reset={var['expected_reset']}, got {got['reset']!r}"
                if ok and "expected_batch" in var:
                    ok = equal(var["expected_batch"], got)
                    detail = describe(var["expected_batch"], got)
                out.append((f"adapter {ex['id']} variant{v_i}", ok, "" if ok else detail))
        if "expected_rows" in ex:
            eps = episodes_by_case.get(ex["episodes_from_case"])
            if eps is None:
                out.append((f"adapter {ex['id']}", False,
                            f"no drained episodes captured from case {ex['episodes_from_case']}"))
                continue
            try:
                rows = ad.labs_rows(json.loads(json.dumps(eps)),
                                    hour_start=datetime.fromisoformat(ex["hour_start"]))
                ok = equal(ex["expected_rows"], rows)
                detail = describe(ex["expected_rows"], rows)
            except TrackingError as e:
                ok, detail = False, f"raised {e.code}: {e}"
            out.append((f"adapter {ex['id']}", ok, "" if ok else detail))
    return out


def drained_episodes(case: dict) -> Any:
    """The episodes the case's own API run drains, for `episodes_from_case`."""
    envs: dict[str, dict] = {}
    captures: dict[str, Any] = {}
    last = None
    for op_spec in case["operations"]:
        on = op_spec.get("on", "main")
        session = envs.setdefault(on, {})
        cmd = json.loads(json.dumps(op_spec["command"]))
        if "snapshot_from" in op_spec:
            cmd["snapshot"] = json.loads(json.dumps(captures[op_spec["snapshot_from"]]))
        try:
            result = _apply(session, cmd["op"], cmd, "api")
        except TrackingError:
            result = None
        if "capture_result" in op_spec and result is not None:
            captures[op_spec["capture_result"]] = json.loads(json.dumps(result))
        if cmd["op"] == "drain" and isinstance(result, list) and result:
            last = json.loads(json.dumps(result))
    return last


def load(path: pathlib.Path = CASES_JSON) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)
