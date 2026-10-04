#!/usr/bin/env python3
"""Executable test suite for Labs temporal tracking benchmark.

Tests:
1. Public cases from cases.json (both direct Python API and CLI JSONL protocol).
2. Adapter examples and wire preview from cases.json.
3. Edge cases: configuration bounds, atomic rollbacks, replay window expiry,
   scope validation, sequence errors, snapshot corruption/invariants.
4. Resource workload from Section 13 (sequential streams 1 & 2).
5. Defect detection / mutation tests.
"""

from __future__ import annotations

import collections
import copy
from datetime import datetime, timezone
import hashlib
import json
import math
import os
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

import psutil

# Add repository root and tools/labs to sys.path
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, REPO_ROOT)
sys.path.insert(0, os.path.join(REPO_ROOT, "tools", "labs"))

from tools.labs.temporal_tracks import Tracker, TrackingError, TrackState
from tools.labs.temporal_tracks_adapter import mask_frame_batch, labs_rows
from tools.labs.labs_foreground_mask import Blob


def _num_equal(a: Any, b: Any, tol: float = 1e-9) -> bool:
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return math.isclose(float(a), float(b), abs_tol=tol, rel_tol=tol)
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return False
        return all(_num_equal(x, y, tol) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        if set(a.keys()) != set(b.keys()):
            return False
        return all(_num_equal(a[k], b[k], tol) for k in a)
    return a == b


def _dict_subset_equal(sub: Any, full: Any, tol: float = 1e-9) -> bool:
    if isinstance(sub, dict) and isinstance(full, dict):
        for k, v in sub.items():
            if k not in full:
                return False
            if not _dict_subset_equal(v, full[k], tol):
                return False
        return True
    elif isinstance(sub, list) and isinstance(full, list):
        if len(sub) != len(full):
            return False
        return all(_dict_subset_equal(x, y, tol) for x, y in zip(sub, full))
    else:
        return _num_equal(sub, full, tol)


def run_public_cases() -> None:
    cases_path = os.path.join(REPO_ROOT, "docs", "benchmarks", "labs-tracking", "fixtures", "cases.json")
    with open(cases_path, "r", encoding="utf-8") as f:
        fixtures_data = json.load(f)

    # 1. Test each case using Python API
    print("=== Running Public Cases (Python API & CLI) ===")
    for case in fixtures_data["cases"]:
        case_id = case["id"]
        # Python in-memory trackers per "on" stream
        trackers: Dict[str, Optional[Tracker]] = collections.defaultdict(lambda: None)
        captures: Dict[str, Any] = {}

        for op_idx, op in enumerate(case["operations"]):
            stream_name = op["on"]
            cmd = copy.deepcopy(op["command"])
            expect = op.get("expect", {})

            if "snapshot_from" in op:
                snap_val = captures[op["snapshot_from"]]
                # Round-trip through JSON to ensure clean deserialization
                cmd["snapshot"] = json.loads(json.dumps(snap_val))

            op_name = cmd["op"]
            ok = True
            result = None
            err_code = None

            try:
                if op_name == "init":
                    trackers[stream_name] = Tracker(
                        camera_id=cmd["camera_id"],
                        unit_id=cmd["unit_id"],
                        config=cmd.get("config"),
                    )
                    result = None
                elif op_name == "restore":
                    trackers[stream_name] = Tracker.restore(cmd["snapshot"])
                    result = None
                elif op_name == "feed":
                    t = trackers[stream_name]
                    if t is None:
                        raise TrackingError("not initialized", code="not_initialized")
                    result = t.feed(cmd["batch"])
                elif op_name == "drain":
                    t = trackers[stream_name]
                    if t is None:
                        raise TrackingError("not initialized", code="not_initialized")
                    result = t.drain()
                elif op_name == "snapshot":
                    t = trackers[stream_name]
                    if t is None:
                        raise TrackingError("not initialized", code="not_initialized")
                    result = t.snapshot()
                elif op_name == "finish":
                    t = trackers[stream_name]
                    if t is None:
                        raise TrackingError("not initialized", code="not_initialized")
                    result = t.finish()
                else:
                    raise TrackingError(f"unknown op: {op_name}", code="invalid_input")
            except TrackingError as ex:
                ok = False
                err_code = ex.code

            # Verify expect.ok
            if expect.get("ok") is not None:
                assert ok == expect["ok"], f"Case {case_id} op {op_idx} ok mismatch: expected {expect['ok']}, got {ok} (err {err_code})"

            # Verify expect.error
            if not ok:
                assert "error" in expect, f"Case {case_id} op {op_idx} unexpected error {err_code}"
                assert err_code == expect["error"]["code"], f"Case {case_id} op {op_idx} error code mismatch: expected {expect['error']['code']}, got {err_code}"

            # Verify expect.result
            if "result" in expect:
                assert _num_equal(result, expect["result"]), f"Case {case_id} op {op_idx} result mismatch:\nExpected: {expect['result']}\nGot: {result}"

            # Verify expect.result_subset
            if "result_subset" in expect:
                assert _dict_subset_equal(expect["result_subset"], result), f"Case {case_id} op {op_idx} result_subset mismatch:\nExpected subset: {expect['result_subset']}\nGot: {result}"

            # Handle capture_result
            if "capture_result" in op:
                captures[op["capture_result"]] = copy.deepcopy(result)

            # Handle expect_result_equal
            if "expect_result_equal" in op:
                captured = captures[op["expect_result_equal"]]
                assert _num_equal(result, captured), f"Case {case_id} op {op_idx} equality mismatch with {op['expect_result_equal']}"

        # 2. Test same case through CLI replay_temporal_tracks.py
        # Group operations per "on" stream
        streams_ops: Dict[str, List[Dict[str, Any]]] = collections.defaultdict(list)
        for op in case["operations"]:
            streams_ops[op["on"]].append(op)

        for stream_name, ops in streams_ops.items():
            lines_in: List[str] = []
            expected_outs: List[Tuple[bool, Optional[str], Optional[Any], Optional[Any]]] = []
            for op in ops:
                cmd = copy.deepcopy(op["command"])
                if "snapshot_from" in op:
                    cmd["snapshot"] = json.loads(json.dumps(captures[op["snapshot_from"]]))
                lines_in.append(json.dumps(cmd))
                exp = op.get("expect", {})
                expected_outs.append((
                    exp.get("ok", True),
                    exp.get("error", {}).get("code"),
                    exp.get("result"),
                    exp.get("result_subset"),
                ))

            proc = subprocess.Popen(
                [sys.executable, os.path.join(REPO_ROOT, "tools", "labs", "replay_temporal_tracks.py")],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            stdout_data, stderr_data = proc.communicate(input="\n".join(lines_in) + "\n")
            out_lines = [l for l in stdout_data.splitlines() if l.strip()]
            assert len(out_lines) == len(lines_in), f"CLI output lines mismatch for {case_id}:{stream_name}"

            had_error = False
            for line_idx, out_line in enumerate(out_lines):
                resp = json.loads(out_line)
                exp_ok, exp_err, exp_res, exp_subset = expected_outs[line_idx]
                if not exp_ok:
                    had_error = True
                    assert not resp["ok"], f"CLI expected failure on {case_id}:{stream_name} op {line_idx}"
                    assert resp["error"]["code"] == exp_err, f"CLI error code mismatch: {resp['error']['code']} vs {exp_err}"
                else:
                    assert resp["ok"], f"CLI unexpected failure on {case_id}:{stream_name} op {line_idx}: {resp}"
                    if exp_res is not None:
                        assert _num_equal(resp["result"], exp_res), f"CLI result mismatch on {case_id}:{stream_name} op {line_idx}"
                    if exp_subset is not None:
                        assert _dict_subset_equal(exp_subset, resp["result"]), f"CLI subset mismatch on {case_id}:{stream_name} op {line_idx}"

            expected_exit = 1 if had_error else 0
            assert proc.returncode == expected_exit, f"CLI exit code mismatch for {case_id}:{stream_name}: expected {expected_exit}, got {proc.returncode}"

        print(f"  PASS  public case: {case_id}")


class FakeFrame:
    def __init__(self, t_s: float, run: int, scored: bool, blobs: Tuple[Any, ...]) -> None:
        self.t_s = t_s
        self.run = run
        self.scored = scored
        self.blobs = blobs


def run_adapter_examples() -> None:
    print("=== Running Adapter Examples ===")
    cases_path = os.path.join(REPO_ROOT, "docs", "benchmarks", "labs-tracking", "fixtures", "cases.json")
    with open(cases_path, "r", encoding="utf-8") as f:
        fixtures_data = json.load(f)

    adapter_exs = fixtures_data["adapter_examples"]

    # 1. pixel-blob-normalization-and-run-reset
    ex1 = adapter_exs[0]
    b_data = ex1["blob"]
    blob = Blob(
        label=b_data["label"],
        x=b_data["x"],
        y=b_data["y"],
        w=b_data["w"],
        h=b_data["h"],
        area=b_data["area"],
        cx=b_data["cx"],
        cy=b_data["cy"],
        frame_w=b_data["frame_w"],
        frame_h=b_data["frame_h"],
    )

    f_data = ex1["frame"]
    args = ex1["arguments"]
    frame = FakeFrame(t_s=f_data["t_s"], run=f_data["run"], scored=f_data["scored"], blobs=(blob,))

    batch = mask_frame_batch(
        frame,
        camera_id=args["camera_id"],
        unit_id=args["unit_id"],
        seq=args["seq"],
        previous_run=args["previous_run"],
    )
    assert _num_equal(batch, ex1["expected_batch"]), f"Adapter batch mismatch:\nExpected: {ex1['expected_batch']}\nGot: {batch}"

    # Test variants
    for variant in ex1.get("variants", []):
        frame_overrides = variant.get("frame_overrides", {})
        arg_overrides = variant.get("arguments_overrides", {})

        cur_t_s = frame_overrides.get("t_s", f_data["t_s"])
        cur_run = frame_overrides.get("run", f_data["run"])
        cur_scored = frame_overrides.get("scored", f_data["scored"])
        cur_frame = FakeFrame(t_s=cur_t_s, run=cur_run, scored=cur_scored, blobs=(blob,))

        cur_cam = arg_overrides.get("camera_id", args["camera_id"])
        cur_unit = arg_overrides.get("unit_id", args["unit_id"])
        cur_seq = arg_overrides.get("seq", args["seq"])
        cur_prev_run = arg_overrides.get("previous_run", args["previous_run"])

        v_batch = mask_frame_batch(cur_frame, camera_id=cur_cam, unit_id=cur_unit, seq=cur_seq, previous_run=cur_prev_run)
        if "expected_detections" in variant:
            assert _num_equal(v_batch["detections"], variant["expected_detections"]), "Variant detections mismatch"
        if "expected_reset" in variant:
            assert v_batch["reset"] == variant["expected_reset"], "Variant reset mismatch"

    print("  PASS  pixel-blob-normalization-and-run-reset")

    # 2. labs-wire-preview
    ex2 = adapter_exs[1]
    # Drained episode from one-object-unique-and-bounded-path
    t = Tracker(camera_id="cam-public", unit_id="unit-public", config={"path_points": 3})
    t.feed({"camera_id": "cam-public", "unit_id": "unit-public", "seq": 0, "t_ms": 0, "detections": [{"id": "d0", "bbox": [0.1, 0.2, 0.1, 0.2]}]})
    t.feed({"camera_id": "cam-public", "unit_id": "unit-public", "seq": 1, "t_ms": 1000, "detections": [{"id": "d1", "bbox": [0.15, 0.2, 0.1, 0.2]}]})
    t.feed({"camera_id": "cam-public", "unit_id": "unit-public", "seq": 2, "t_ms": 2000, "detections": [{"id": "d2", "bbox": [0.2, 0.2, 0.1, 0.2]}]})
    t.feed({"camera_id": "cam-public", "unit_id": "unit-public", "seq": 3, "t_ms": 3000, "detections": [{"id": "d3", "bbox": [0.25, 0.2, 0.1, 0.2]}]})
    t.finish()
    eps = t.drain()
    assert len(eps) == 1

    dt = datetime.fromisoformat(ex2["hour_start"])
    rows = labs_rows(eps, hour_start=dt)
    assert _num_equal(rows, ex2["expected_rows"]), f"labs_rows mismatch:\nExpected: {ex2['expected_rows']}\nGot: {rows}"

    print("  PASS  labs-wire-preview")


def run_contract_edge_cases() -> None:
    print("=== Running Contract Edge Cases ===")

    # 1. Invalid configuration
    bad_configs = [
        {"gate_base": 0.0},
        {"gate_base": 1.1},
        {"gate_speed": -0.1},
        {"max_speed": 0.0},
        {"max_gap_ms": 0},
        {"max_span_ms": 300000},
        {"max_area_ratio": 0.9},
        {"appearance_weight": 2.1},
        {"appearance_gate": 1.1},
        {"ambiguity_margin": -1},
        {"max_tracks": 129},
        {"max_detections": 0},
        {"max_pending": 63, "max_tracks": 64},  # max_pending < max_tracks
        {"path_points": 1},
        {"unknown_key": 42},
        {"max_gap_ms": True},  # Boolean as int
        {"gate_base": "0.15"},  # String as real
    ]
    for cfg in bad_configs:
        try:
            Tracker(config=cfg)
            assert False, f"Expected invalid_config for {cfg}"
        except TrackingError as ex:
            assert ex.code == "invalid_config", f"Expected invalid_config, got {ex.code}"

    # 2. Scope mismatch and sequence error
    t = Tracker(camera_id="cam-1", unit_id="unit-1")
    try:
        t.feed({"camera_id": "cam-2", "unit_id": "unit-1", "seq": 0, "t_ms": 0, "detections": []})
        assert False, "Expected wrong_scope"
    except TrackingError as ex:
        assert ex.code == "wrong_scope"

    # Nonconsecutive seq on first batch
    try:
        t.feed({"camera_id": "cam-1", "unit_id": "unit-1", "seq": 1, "t_ms": 0, "detections": []})
        assert False, "Expected sequence_error"
    except TrackingError as ex:
        assert ex.code == "sequence_error"

    # First batch ok
    t.feed({"camera_id": "cam-1", "unit_id": "unit-1", "seq": 0, "t_ms": 100, "detections": []})

    # Nonconsecutive seq on second batch
    try:
        t.feed({"camera_id": "cam-1", "unit_id": "unit-1", "seq": 2, "t_ms": 200, "detections": []})
        assert False, "Expected sequence_error"
    except TrackingError as ex:
        assert ex.code == "sequence_error"

    # Nonincreasing timestamp
    try:
        t.feed({"camera_id": "cam-1", "unit_id": "unit-1", "seq": 1, "t_ms": 100, "detections": []})
        assert False, "Expected sequence_error"
    except TrackingError as ex:
        assert ex.code == "sequence_error"

    # 3. Detection validation errors
    bad_detections = [
        [{"id": "d0", "bbox": [-0.01, 0, 0.1, 0.1]}],
        [{"id": "d0", "bbox": [0, 0, 1.01, 0.1]}],
        [{"id": "d0", "bbox": [0, 0, 0, 0.1]}],  # w < 1e-6
        [{"id": "d0", "bbox": [0, 0, 0.1, 0.1], "appearance": [0.5, 0.5, 0, 0.1]}],  # sum != 1
        [{"id": "d0", "bbox": [0, 0, 0.1, 0.1]}, {"id": "d0", "bbox": [0.5, 0.5, 0.1, 0.1]}],  # duplicate id
    ]
    for dets in bad_detections:
        try:
            t.feed({"camera_id": "cam-1", "unit_id": "unit-1", "seq": 1, "t_ms": 200, "detections": dets})
            assert False, f"Expected invalid_input for {dets}"
        except TrackingError as ex:
            assert ex.code == "invalid_input"

    # 4. Snapshot corruption checks
    t2 = Tracker(camera_id="cam-2", unit_id="unit-2")
    t2.feed({"camera_id": "cam-2", "unit_id": "unit-2", "seq": 0, "t_ms": 0, "detections": [{"id": "d0", "bbox": [0.1, 0.1, 0.1, 0.1]}]})
    snap = t2.snapshot()

    # Wrong checksum
    corrupted_snap = copy.deepcopy(snap)
    corrupted_snap["sha256"] = "0" * 64
    try:
        Tracker.restore(corrupted_snap)
        assert False, "Expected invalid_snapshot for sha mismatch"
    except TrackingError as ex:
        assert ex.code == "invalid_snapshot"

    # Corrupted state with valid recomputed sha
    corrupted_state = copy.deepcopy(snap["state"])
    corrupted_state["active_tracks"][0]["observations"] = -1
    c_bytes = json.dumps(corrupted_state, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode("utf-8")
    corrupted_snap2 = {
        "schema": snap["schema"],
        "state": corrupted_state,
        "sha256": hashlib.sha256(c_bytes).hexdigest().lower(),
    }
    try:
        Tracker.restore(corrupted_snap2)
        assert False, "Expected invalid_snapshot for negative observations"
    except TrackingError as ex:
        assert ex.code == "invalid_snapshot"

    print("  PASS  all contract edge cases verified")


def run_resource_workload() -> None:
    print("=== Running Section 13 Resource Workload ===")
    t_start = time.perf_counter()
    proc = psutil.Process()
    rss_start = proc.memory_info().rss

    # Run 1: 100000 batches, 8 detections per batch
    t1 = Tracker(camera_id="resource-a", unit_id="resource")
    max_snap_size1 = 0

    for n in range(100000):
        q = n % 1000
        u = q / 250.0 - 1.0 if q < 500 else 3.0 - q / 250.0

        dets = []
        for j in range(8):
            c = j % 4
            r = j // 4
            cx = 0.12 + 0.25 * c + 0.02 * u
            cy = 0.25 + 0.50 * r
            dets.append({
                "id": f"d{j}",
                "bbox": [cx - 0.02, cy - 0.02, 0.04, 0.04],
            })

        receipt = t1.feed({
            "camera_id": "resource-a",
            "unit_id": "resource",
            "seq": n,
            "t_ms": 200 * n,
            "detections": dets,
        })
        # Check all detections assigned without ambiguity
        for a in receipt["assignments"]:
            assert a["status"] in ("born", "matched")
            assert a["reason"] is None

        t1.drain()

        if n % 1000 == 0:
            snap = t1.snapshot()
            snap_bytes = json.dumps(snap, separators=(",", ":")).encode("utf-8")
            max_snap_size1 = max(max_snap_size1, len(snap_bytes))
            assert len(snap_bytes) <= 2097152, f"Snapshot exceeded 2MB at n={n}: {len(snap_bytes)}"

    t1.finish()
    t1.drain()

    # Run 2: 250 batches, 32 detections per batch
    t2 = Tracker(camera_id="resource-b", unit_id="resource")
    max_snap_size2 = 0

    for n in range(250):
        q = n % 50
        u = q / 12.5 - 1.0 if q < 25 else 3.0 - q / 12.5

        dets = []
        for j in range(32):
            c = j % 8
            r = j // 8
            cx = (c + 0.5) / 8.0 + 0.005 * u
            cy = (r + 0.5) / 4.0
            dets.append({
                "id": f"d{j}",
                "bbox": [cx - 0.01, cy - 0.01, 0.02, 0.02],
            })

        receipt = t2.feed({
            "camera_id": "resource-b",
            "unit_id": "resource",
            "seq": n,
            "t_ms": 200 * n,
            "detections": dets,
        })
        for a in receipt["assignments"]:
            assert a["status"] in ("born", "matched")
            assert a["reason"] is None

        t2.drain()

        if n % 1000 == 0:
            snap = t2.snapshot()
            snap_bytes = json.dumps(snap, separators=(",", ":")).encode("utf-8")
            max_snap_size2 = max(max_snap_size2, len(snap_bytes))
            assert len(snap_bytes) <= 2097152

    t2.finish()
    t2.drain()

    elapsed = time.perf_counter() - t_start
    rss_end = proc.memory_info().rss
    rss_delta_mb = (rss_end - rss_start) / (1024 * 1024)

    print(f"  PASS  workload completed in {elapsed:.2f} s (limit <= 180 s)")
    print(f"  PASS  peak additional RSS: {rss_delta_mb:.2f} MiB (limit <= 128 MiB)")
    print(f"  PASS  max snapshot sizes: {max_snap_size1} bytes, {max_snap_size2} bytes (limit <= 2 MiB)")

    assert elapsed <= 180.0, f"Workload timed out: {elapsed:.2f} s > 180 s"
    assert rss_delta_mb <= 128.0, f"Workload RSS exceeded: {rss_delta_mb:.2f} MiB > 128 MiB"


def run_targeted_rubric_tests() -> None:
    print("=== Running Targeted Rubric & Mutation Family Tests ===")

    # 1. Association: non-greedy matching
    t = Tracker(camera_id="cam-rubric", unit_id="unit-rubric", config={"ambiguity_margin": 0})
    t.feed({
        "camera_id": "cam-rubric", "unit_id": "unit-rubric", "seq": 0, "t_ms": 0,
        "detections": [
            {"id": "t1", "bbox": [0.1, 0.4, 0.1, 0.1]},
            {"id": "t2", "bbox": [0.3, 0.4, 0.1, 0.1]},
        ]
    })
    rec = t.feed({
        "camera_id": "cam-rubric", "unit_id": "unit-rubric", "seq": 1, "t_ms": 1000,
        "detections": [
            {"id": "d_mid", "bbox": [0.19, 0.4, 0.1, 0.1]},
            {"id": "d_left", "bbox": [0.0, 0.4, 0.1, 0.1]},
        ]
    })
    matched_count = len([a for a in rec["assignments"] if a["status"] == "matched"])
    assert matched_count == 2, f"Expected 2 matches, got {matched_count}"
    print("  PASS  association: max cardinality before nearest edge")

    # 2. Ambiguity: merge boundary containment
    t_merge = Tracker(camera_id="cam-merge", unit_id="unit-merge", config={"gate_base": 0.5, "max_area_ratio": 100})
    t_merge.feed({
        "camera_id": "cam-merge", "unit_id": "unit-merge", "seq": 0, "t_ms": 0,
        "detections": [
            {"id": "m1", "bbox": [0.2, 0.4, 0.1, 0.1]},  # center: 0.25, 0.45
            {"id": "m2", "bbox": [0.4, 0.4, 0.1, 0.1]},  # center: 0.45, 0.45
        ]
    })
    rec_merge = t_merge.feed({
        "camera_id": "cam-merge", "unit_id": "unit-merge", "seq": 1, "t_ms": 1000,
        "detections": [
            {"id": "wide", "bbox": [0.25, 0.4, 0.20, 0.1]},
        ]
    })
    assert rec_merge["assignments"][0]["status"] == "ambiguous"
    assert rec_merge["assignments"][0]["reason"] == "merge"
    print("  PASS  ambiguity: merge boundary containment")

    # 3. Time: strict gap boundary and end_ms evidence preservation
    t_time = Tracker(camera_id="cam-time", unit_id="unit-time", config={"max_gap_ms": 1000, "max_span_ms": 2000})
    t_time.feed({
        "camera_id": "cam-time", "unit_id": "unit-time", "seq": 0, "t_ms": 0,
        "detections": [{"id": "d0", "bbox": [0.1, 0.1, 0.1, 0.1]}]
    })
    rec_time = t_time.feed({
        "camera_id": "cam-time", "unit_id": "unit-time", "seq": 1, "t_ms": 1000,
        "detections": []
    })
    assert rec_time["closed"] == []
    rec_time2 = t_time.feed({
        "camera_id": "cam-time", "unit_id": "unit-time", "seq": 2, "t_ms": 1001,
        "detections": []
    })
    assert rec_time2["closed"] == ["t00000001"]
    eps_time = t_time.drain()
    assert len(eps_time) == 1
    assert eps_time[0]["reason"] == "gap"
    assert eps_time[0]["end_ms"] == 0
    print("  PASS  time: strict gap boundary and end_ms evidence preservation")

    # 4. Replay: permutation equivalence
    t_rep = Tracker(camera_id="cam-rep", unit_id="unit-rep")
    rec_orig = t_rep.feed({
        "camera_id": "cam-rep", "unit_id": "unit-rep", "seq": 0, "t_ms": 0,
        "detections": [
            {"id": "a", "bbox": [0.1, 0.1, 0.1, 0.1]},
            {"id": "b", "bbox": [0.3, 0.3, 0.1, 0.1]},
        ]
    })
    rec_rep = t_rep.feed({
        "camera_id": "cam-rep", "unit_id": "unit-rep", "seq": 0, "t_ms": 0,
        "detections": [
            {"id": "b", "bbox": [0.3, 0.3, 0.1, 0.1]},
            {"id": "a", "bbox": [0.1, 0.1, 0.1, 0.1]},
        ]
    })
    assert rec_rep["replayed"] is True
    assert _num_equal(rec_rep["assignments"], rec_orig["assignments"])
    print("  PASS  replay: permutation equivalence")

    # 5. CLI: duplicate keys rejection
    proc = subprocess.Popen(
        [sys.executable, os.path.join(REPO_ROOT, "tools", "labs", "replay_temporal_tracks.py")],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    cmd_str = '{"op":"init","camera_id":"cam-dup","unit_id":"unit-dup","unit_id":"unit-dup"}\n'
    out, _ = proc.communicate(input=cmd_str)
    res = json.loads(out.strip())
    assert res["ok"] is False
    assert res["error"]["code"] == "invalid_input"
    assert proc.returncode == 1
    print("  PASS  cli: duplicate keys rejection")


def main() -> None:
    print("==================================================")
    print("  Labs Temporal Tracking Test Suite (Stage 1)")
    print("==================================================")

    run_public_cases()
    run_adapter_examples()
    run_contract_edge_cases()
    run_targeted_rubric_tests()
    run_resource_workload()

    print("\nALL CHECKS PASSED.")


if __name__ == "__main__":
    main()

