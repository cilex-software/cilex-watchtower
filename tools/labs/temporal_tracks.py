"""Deterministic, resumable streaming temporal tracking engine for Cilex Watchtower Labs.

Conforms to labs-temporal-tracking-v1 contract.
"""

from __future__ import annotations

import collections
import copy
import hashlib
import heapq
import json
import math
import re
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple


_ID_REGEX = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")
_SNAPSHOT_SCHEMA = "labs-temporal-tracker/v1"

_CONFIG_DEFAULTS = {
    "gate_base": 0.15,
    "gate_speed": 0.10,
    "max_speed": 1.0,
    "max_gap_ms": 2000,
    "max_span_ms": 299000,
    "max_area_ratio": 4.0,
    "appearance_weight": 0.25,
    "appearance_gate": 0.50,
    "ambiguity_margin": 1000,
    "max_tracks": 64,
    "max_detections": 64,
    "max_pending": 256,
    "replay_batches": 32,
    "path_points": 32,
}


class TrackingError(ValueError):
    """Normative tracking exception carrying a public string error code."""

    def __init__(self, message: str, code: str = "invalid_input") -> None:
        super().__init__(message)
        self.code = str(code)


def _is_bool(val: Any) -> bool:
    return isinstance(val, bool)


def _is_int(val: Any) -> bool:
    return isinstance(val, int) and not isinstance(val, bool)


def _is_real(val: Any) -> bool:
    return isinstance(val, (int, float)) and not isinstance(val, bool) and math.isfinite(val)


def _validate_config(config_dict: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """Validate and resolve Tracker configuration according to Section 3."""
    if config_dict is None:
        return dict(_CONFIG_DEFAULTS)
    if not isinstance(config_dict, dict) or _is_bool(config_dict):
        raise TrackingError("config must be a dictionary", code="invalid_config")

    resolved = dict(_CONFIG_DEFAULTS)
    for key, value in config_dict.items():
        if key not in _CONFIG_DEFAULTS:
            raise TrackingError(f"unknown configuration key: {key}", code="invalid_config")

        if key == "gate_base":
            if not _is_real(value) or value <= 0.0 or value > 1.0:
                raise TrackingError("gate_base must be real, >0 and <=1", code="invalid_config")
            resolved[key] = float(value)
        elif key == "gate_speed":
            if not _is_real(value) or value < 0.0 or value > 2.0:
                raise TrackingError("gate_speed must be real, 0..2", code="invalid_config")
            resolved[key] = float(value)
        elif key == "max_speed":
            if not _is_real(value) or value <= 0.0 or value > 10.0:
                raise TrackingError("max_speed must be real, >0 and <=10", code="invalid_config")
            resolved[key] = float(value)
        elif key == "max_gap_ms":
            if not _is_int(value) or value < 1 or value > 10000:
                raise TrackingError("max_gap_ms must be integer, 1..10000", code="invalid_config")
            resolved[key] = int(value)
        elif key == "max_span_ms":
            if not _is_int(value) or value < 1 or value > 299000:
                raise TrackingError("max_span_ms must be integer, 1..299000", code="invalid_config")
            resolved[key] = int(value)
        elif key == "max_area_ratio":
            if not _is_real(value) or value < 1.0 or value > 100.0:
                raise TrackingError("max_area_ratio must be real, 1..100", code="invalid_config")
            resolved[key] = float(value)
        elif key == "appearance_weight":
            if not _is_real(value) or value < 0.0 or value > 2.0:
                raise TrackingError("appearance_weight must be real, 0..2", code="invalid_config")
            resolved[key] = float(value)
        elif key == "appearance_gate":
            if not _is_real(value) or value < 0.0 or value > 1.0:
                raise TrackingError("appearance_gate must be real, 0..1", code="invalid_config")
            resolved[key] = float(value)
        elif key == "ambiguity_margin":
            if not _is_int(value) or value < 0 or value > 1000000:
                raise TrackingError("ambiguity_margin must be integer, 0..1000000", code="invalid_config")
            resolved[key] = int(value)
        elif key == "max_tracks":
            if not _is_int(value) or value < 1 or value > 128:
                raise TrackingError("max_tracks must be integer, 1..128", code="invalid_config")
            resolved[key] = int(value)
        elif key == "max_detections":
            if not _is_int(value) or value < 1 or value > 128:
                raise TrackingError("max_detections must be integer, 1..128", code="invalid_config")
            resolved[key] = int(value)
        elif key == "max_pending":
            if not _is_int(value) or value < 1 or value > 1024:
                raise TrackingError("max_pending must be integer, 1..1024", code="invalid_config")
            resolved[key] = int(value)
        elif key == "replay_batches":
            if not _is_int(value) or value < 1 or value > 128:
                raise TrackingError("replay_batches must be integer, 1..128", code="invalid_config")
            resolved[key] = int(value)
        elif key == "path_points":
            if not _is_int(value) or value < 2 or value > 128:
                raise TrackingError("path_points must be integer, 2..128", code="invalid_config")
            resolved[key] = int(value)

    if resolved["max_pending"] < resolved["max_tracks"]:
        raise TrackingError("require max_pending >= max_tracks", code="invalid_config")

    return resolved


class TrackState:
    """Internal mutable tracking state for one active object trajectory."""

    __slots__ = (
        "track_id",
        "start_ms",
        "end_ms",
        "observations",
        "ambiguous_batches",
        "first_center",
        "last_center",
        "second_last_center",
        "second_last_t_ms",
        "last_box",
        "max_box",
        "max_box_area",
        "max_box_t_ms",
        "appearance",
        "path_length",
        "max_observation_gap_ms",
        "path",
    )

    def __init__(
        self,
        track_id: str,
        t_ms: int,
        det: Dict[str, Any],
        path_points: int,
    ) -> None:
        self.track_id = track_id
        self.start_ms = t_ms
        self.end_ms = t_ms
        self.observations = 1
        self.ambiguous_batches = 0
        cx = det["bbox"][0] + det["bbox"][2] / 2.0
        cy = det["bbox"][1] + det["bbox"][3] / 2.0
        self.first_center = [cx, cy]
        self.last_center = [cx, cy]
        self.second_last_center = None
        self.second_last_t_ms = None
        self.last_box = [float(x) for x in det["bbox"]]
        self.max_box = [float(x) for x in det["bbox"]]
        self.max_box_area = self.last_box[2] * self.last_box[3]
        self.max_box_t_ms = t_ms
        self.appearance = [float(v) for v in det["appearance"]] if det.get("appearance") is not None else None
        self.path_length = 0.0
        self.max_observation_gap_ms = 0
        self.path = [[t_ms, cx, cy]]

    def predict_center(self, current_t_ms: int, max_speed: float) -> Tuple[float, float]:
        """Predict current box center using last two accepted observations."""
        if self.second_last_center is None:
            return self.last_center[0], self.last_center[1]

        elapsed_dt = (self.end_ms - self.second_last_t_ms) / 1000.0
        vx = (self.last_center[0] - self.second_last_center[0]) / elapsed_dt
        vy = (self.last_center[1] - self.second_last_center[1]) / elapsed_dt
        speed = math.hypot(vx, vy)
        if speed > max_speed:
            scale = max_speed / speed
            vx *= scale
            vy *= scale
        dt_curr = (current_t_ms - self.end_ms) / 1000.0
        return self.last_center[0] + vx * dt_curr, self.last_center[1] + vy * dt_curr

    def accept_observation(self, t_ms: int, det: Dict[str, Any], path_points: int) -> None:
        """Update track state with a newly assigned detection."""
        cx = det["bbox"][0] + det["bbox"][2] / 2.0
        cy = det["bbox"][1] + det["bbox"][3] / 2.0

        dist = math.hypot(cx - self.last_center[0], cy - self.last_center[1])
        self.path_length += dist

        gap = t_ms - self.end_ms
        if gap > self.max_observation_gap_ms:
            self.max_observation_gap_ms = gap

        self.second_last_center = self.last_center
        self.second_last_t_ms = self.end_ms
        self.last_center = [cx, cy]
        self.last_box = [float(x) for x in det["bbox"]]

        area = self.last_box[2] * self.last_box[3]
        if area > self.max_box_area:  # strictly greater so earliest wins tie
            self.max_box = [float(x) for x in det["bbox"]]
            self.max_box_area = area
            self.max_box_t_ms = t_ms

        if det.get("appearance") is not None:
            self.appearance = [float(v) for v in det["appearance"]]

        self.end_ms = t_ms
        self.observations += 1

        self.path.append([t_ms, cx, cy])
        while len(self.path) > path_points:
            best_idx = 1
            best_val = None
            for i in range(1, len(self.path) - 1):
                xp, yp = self.path[i - 1][1], self.path[i - 1][2]
                xi, yi = self.path[i][1], self.path[i][2]
                xn, yn = self.path[i + 1][1], self.path[i + 1][2]
                val = abs((xi - xp) * (yn - yi) - (yi - yp) * (xn - xi))
                if best_val is None or val < best_val:
                    best_val = val
                    best_idx = i
            del self.path[best_idx]

    def to_episode_dict(self, camera_id: str, unit_id: str, reason: str) -> Dict[str, Any]:
        """Format closed episode according to Section 8."""
        disp = math.hypot(self.last_center[0] - self.first_center[0], self.last_center[1] - self.first_center[1])
        mean_speed = None
        if self.end_ms > self.start_ms:
            mean_speed = self.path_length / ((self.end_ms - self.start_ms) / 1000.0)

        return {
            "camera_id": camera_id,
            "unit_id": unit_id,
            "track_id": self.track_id,
            "start_ms": self.start_ms,
            "end_ms": self.end_ms,
            "observations": self.observations,
            "ambiguous_batches": self.ambiguous_batches,
            "reason": reason,
            "bbox": [float(x) for x in self.max_box],
            "bbox_at_ms": self.max_box_t_ms,
            "first_center": [float(c) for c in self.first_center],
            "last_center": [float(c) for c in self.last_center],
            "path_length": float(self.path_length),
            "net_displacement": float(disp),
            "mean_speed": float(mean_speed) if mean_speed is not None else None,
            "max_observation_gap_ms": self.max_observation_gap_ms,
            "path": [[int(pt[0]), float(pt[1]), float(pt[2])] for pt in self.path],
        }

    def serialize(self) -> Dict[str, Any]:
        """Serialize track state for snapshot checkpointing."""
        return {
            "track_id": self.track_id,
            "start_ms": self.start_ms,
            "end_ms": self.end_ms,
            "observations": self.observations,
            "ambiguous_batches": self.ambiguous_batches,
            "first_center": self.first_center,
            "last_center": self.last_center,
            "second_last_center": self.second_last_center,
            "second_last_t_ms": self.second_last_t_ms,
            "last_box": self.last_box,
            "max_box": self.max_box,
            "max_box_area": self.max_box_area,
            "max_box_t_ms": self.max_box_t_ms,
            "appearance": self.appearance,
            "path_length": self.path_length,
            "max_observation_gap_ms": self.max_observation_gap_ms,
            "path": self.path,
        }

    @classmethod
    def deserialize(cls, d: Dict[str, Any]) -> TrackState:
        """Restore track state from snapshot dictionary."""
        if not isinstance(d, dict) or _is_bool(d):
            raise TrackingError("track state must be dict", code="invalid_snapshot")

        tid = d.get("track_id")
        if not isinstance(tid, str) or not _ID_REGEX.match(tid):
            raise TrackingError("invalid track_id in track state", code="invalid_snapshot")

        st_ms = d.get("start_ms")
        en_ms = d.get("end_ms")
        if not _is_int(st_ms) or st_ms < 0 or not _is_int(en_ms) or en_ms < st_ms:
            raise TrackingError("invalid start_ms or end_ms in track state", code="invalid_snapshot")

        obs = d.get("observations")
        if not _is_int(obs) or obs < 1:
            raise TrackingError("invalid observations in track state", code="invalid_snapshot")

        amb = d.get("ambiguous_batches")
        if not _is_int(amb) or amb < 0:
            raise TrackingError("invalid ambiguous_batches in track state", code="invalid_snapshot")

        fc = d.get("first_center")
        lc = d.get("last_center")
        if not isinstance(fc, (list, tuple)) or len(fc) != 2 or not all(_is_real(x) for x in fc):
            raise TrackingError("invalid first_center in track state", code="invalid_snapshot")
        if not isinstance(lc, (list, tuple)) or len(lc) != 2 or not all(_is_real(x) for x in lc):
            raise TrackingError("invalid last_center in track state", code="invalid_snapshot")

        slc = d.get("second_last_center")
        if slc is not None:
            if not isinstance(slc, (list, tuple)) or len(slc) != 2 or not all(_is_real(x) for x in slc):
                raise TrackingError("invalid second_last_center in track state", code="invalid_snapshot")

        lbox = d.get("last_box")
        mbox = d.get("max_box")
        if not isinstance(lbox, (list, tuple)) or len(lbox) != 4 or not all(_is_real(x) for x in lbox):
            raise TrackingError("invalid last_box in track state", code="invalid_snapshot")
        if not isinstance(mbox, (list, tuple)) or len(mbox) != 4 or not all(_is_real(x) for x in mbox):
            raise TrackingError("invalid max_box in track state", code="invalid_snapshot")

        plen = d.get("path_length")
        if not _is_real(plen) or plen < 0:
            raise TrackingError("invalid path_length in track state", code="invalid_snapshot")

        gap = d.get("max_observation_gap_ms")
        if not _is_int(gap) or gap < 0:
            raise TrackingError("invalid max_observation_gap_ms in track state", code="invalid_snapshot")

        path = d.get("path")
        if not isinstance(path, (list, tuple)) or not path:
            raise TrackingError("invalid path in track state", code="invalid_snapshot")

        ts = cls.__new__(cls)
        ts.track_id = tid
        ts.start_ms = int(st_ms)
        ts.end_ms = int(en_ms)
        ts.observations = int(obs)
        ts.ambiguous_batches = int(amb)
        ts.first_center = [float(x) for x in fc]
        ts.last_center = [float(x) for x in lc]
        ts.second_last_center = [float(x) for x in slc] if slc is not None else None
        ts.second_last_t_ms = int(d["second_last_t_ms"]) if d.get("second_last_t_ms") is not None else None
        ts.last_box = [float(x) for x in lbox]
        ts.max_box = [float(x) for x in mbox]
        ts.max_box_area = float(d["max_box_area"])
        ts.max_box_t_ms = int(d["max_box_t_ms"])
        ts.appearance = [float(x) for x in d["appearance"]] if d.get("appearance") is not None else None
        ts.path_length = float(plen)
        ts.max_observation_gap_ms = int(gap)
        ts.path = [[int(pt[0]), float(pt[1]), float(pt[2])] for pt in path]
        return ts


def _solve_matching(
    num_u: int,
    num_v: int,
    edges: Sequence[Tuple[int, int, int]],
    forbidden: Optional[Tuple[int, int]] = None,
) -> Tuple[int, int, List[Tuple[int, int]]]:
    """Find maximum cardinality matching, and minimum integer cost among size-K matchings.

    Uses successive shortest augmenting paths with node potentials.
    Returns: (cardinality K, min_cost C, matching list of (u, v)).
    """
    adj: List[List[Tuple[int, int]]] = [[] for _ in range(num_u)]
    for u, v, c in edges:
        if forbidden is not None and (u, v) == forbidden:
            continue
        adj[u].append((v, c))

    u_match = [-1] * num_u
    v_match = [-1] * num_v
    pot_u = [0] * num_u
    pot_v = [0] * num_v

    cardinality = 0

    while True:
        dist_u = [float("inf")] * num_u
        dist_v = [float("inf")] * num_v
        prev_v = [-1] * num_v

        pq: List[Tuple[float, int, int]] = []
        for u in range(num_u):
            if u_match[u] == -1:
                dist_u[u] = 0
                heapq.heappush(pq, (0, 0, u))

        min_v = -1
        min_dist_v = float("inf")

        while pq:
            d, is_v, node = heapq.heappop(pq)
            if is_v:
                v = node
                if d > dist_v[v]:
                    continue
                if v_match[v] == -1:
                    min_v = v
                    min_dist_v = d
                    break
                nxt_u = v_match[v]
                if dist_u[nxt_u] > d:
                    dist_u[nxt_u] = d
                    heapq.heappush(pq, (d, 0, nxt_u))
            else:
                u = node
                if d > dist_u[u]:
                    continue
                for v, c in adj[u]:
                    if v_match[v] == u:
                        continue
                    red_c = c + pot_u[u] - pot_v[v]
                    if dist_v[v] > d + red_c:
                        dist_v[v] = d + red_c
                        prev_v[v] = u
                        heapq.heappush(pq, (dist_v[v], 1, v))

        if min_v == -1:
            break

        max_d = min_dist_v
        for u in range(num_u):
            if dist_u[u] < max_d:
                pot_u[u] += int(dist_u[u] - max_d)
        for v in range(num_v):
            if dist_v[v] < max_d:
                pot_v[v] += int(dist_v[v] - max_d)

        curr_v = min_v
        while curr_v != -1:
            curr_u = prev_v[curr_v]
            nxt_v = u_match[curr_u]
            u_match[curr_u] = curr_v
            v_match[curr_v] = curr_u
            curr_v = nxt_v

        cardinality += 1

    pairs: List[Tuple[int, int]] = []
    tot_cost = 0
    for u in range(num_u):
        if u_match[u] != -1:
            v = u_match[u]
            for ov, c in adj[u]:
                if ov == v:
                    tot_cost += c
                    pairs.append((u, v))
                    break

    return cardinality, tot_cost, pairs


class Tracker:
    """Normative multi-object temporal tracking engine."""

    def __init__(
        self,
        camera_id: str = "cam-a",
        unit_id: str = "unit-a",
        config: Optional[Dict[str, Any]] = None,
    ) -> None:
        if not isinstance(camera_id, str) or not _ID_REGEX.match(camera_id):
            raise TrackingError(f"invalid camera_id: {camera_id!r}", code="invalid_input")
        if not isinstance(unit_id, str) or not _ID_REGEX.match(unit_id):
            raise TrackingError(f"invalid unit_id: {unit_id!r}", code="invalid_input")

        self.camera_id = camera_id
        self.unit_id = unit_id
        self.config = _validate_config(config)

        self.active_tracks: Dict[str, TrackState] = {}
        self.next_track_num: int = 1
        self.outbox: List[Dict[str, Any]] = []
        self.replay_window: collections.deque[Tuple[int, Dict[str, Any], Dict[str, Any]]] = collections.deque(
            maxlen=self.config["replay_batches"]
        )
        self.max_accepted_seq: Optional[int] = None
        self.last_batch_t_ms: Optional[int] = None
        self.is_finished: bool = False

    def _normalize_batch(self, batch: Dict[str, Any]) -> Dict[str, Any]:
        """Validate input batch format and produce normalized representation for replay comparison."""
        if not isinstance(batch, dict) or _is_bool(batch):
            raise TrackingError("batch must be a dict", code="invalid_input")

        required = {"camera_id", "unit_id", "seq", "t_ms", "detections"}
        for k in required:
            if k not in batch:
                raise TrackingError(f"missing required batch key: {k}", code="invalid_input")

        for k in batch:
            if k not in required and k != "reset":
                raise TrackingError(f"unknown batch key: {k}", code="invalid_input")

        cam = batch["camera_id"]
        unit = batch["unit_id"]
        if not isinstance(cam, str) or not _ID_REGEX.match(cam):
            raise TrackingError("malformed camera_id in batch", code="invalid_input")
        if not isinstance(unit, str) or not _ID_REGEX.match(unit):
            raise TrackingError("malformed unit_id in batch", code="invalid_input")

        if cam != self.camera_id or unit != self.unit_id:
            raise TrackingError(f"scope mismatch: expected {self.camera_id}/{self.unit_id}, got {cam}/{unit}", code="wrong_scope")

        seq = batch["seq"]
        if not _is_int(seq) or seq < 0 or seq > 2147483647:
            raise TrackingError("seq must be integer in 0..2147483647", code="invalid_input")

        t_ms = batch["t_ms"]
        if not _is_int(t_ms) or t_ms < 0 or t_ms > 9007199254740991:
            raise TrackingError("t_ms must be integer in 0..9007199254740991", code="invalid_input")

        reset = batch.get("reset", False)
        if not isinstance(reset, bool):
            raise TrackingError("reset must be boolean", code="invalid_input")

        dets = batch["detections"]
        if not isinstance(dets, list) or _is_bool(dets):
            raise TrackingError("detections must be a list", code="invalid_input")

        if len(dets) > self.config["max_detections"]:
            raise TrackingError("exceeded max_detections", code="invalid_input")

        seen_det_ids: Set[str] = set()
        norm_dets: List[Dict[str, Any]] = []

        for d in dets:
            if not isinstance(d, dict) or _is_bool(d):
                raise TrackingError("detection must be a dict", code="invalid_input")
            if "id" not in d or "bbox" not in d:
                raise TrackingError("detection missing required id or bbox", code="invalid_input")
            for k in d:
                if k not in ("id", "bbox", "appearance"):
                    raise TrackingError(f"unknown detection key: {k}", code="invalid_input")

            did = d["id"]
            if not isinstance(did, str) or not _ID_REGEX.match(did):
                raise TrackingError(f"malformed detection id: {did!r}", code="invalid_input")
            if did in seen_det_ids:
                raise TrackingError(f"duplicate detection id in batch: {did!r}", code="invalid_input")
            seen_det_ids.add(did)

            bbox = d["bbox"]
            if not isinstance(bbox, (list, tuple)) or _is_bool(bbox) or len(bbox) != 4:
                raise TrackingError("bbox must be 4 numbers", code="invalid_input")
            for coord in bbox:
                if not _is_real(coord):
                    raise TrackingError("bbox coordinates must be finite numbers", code="invalid_input")
            x, y, w, h = float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3])
            if x < 0.0 or y < 0.0 or w < 1e-6 or h < 1e-6 or (x + w) > 1.0 or (y + h) > 1.0:
                raise TrackingError(f"bbox bounds violation: {[x, y, w, h]}", code="invalid_input")

            app = d.get("appearance", None)
            norm_app = None
            if app is not None:
                if not isinstance(app, (list, tuple)) or _is_bool(app) or len(app) != 4:
                    raise TrackingError("appearance must be 4 numbers", code="invalid_input")
                norm_app = []
                for v in app:
                    if not _is_real(v) or v < 0.0 or v > 1.0:
                        raise TrackingError("appearance elements must be in 0..1", code="invalid_input")
                    norm_app.append(float(v))
                if abs(sum(norm_app) - 1.0) > 1e-9:
                    raise TrackingError("appearance sum must equal 1 within 1e-9", code="invalid_input")

            norm_dets.append({
                "id": did,
                "bbox": [x, y, w, h],
                "appearance": norm_app,
            })

        norm_dets.sort(key=lambda d: d["id"])

        return {
            "camera_id": cam,
            "unit_id": unit,
            "seq": int(seq),
            "t_ms": int(t_ms),
            "reset": bool(reset),
            "detections": norm_dets,
        }

    def feed(self, batch: Dict[str, Any]) -> Dict[str, Any]:
        """Feed a timestamped batch of detections into the tracker."""
        norm_batch = self._normalize_batch(batch)

        if self.is_finished:
            raise TrackingError("feed called on finished tracker", code="finished")

        seq = norm_batch["seq"]
        t_ms = norm_batch["t_ms"]

        # Check replay vs new batch
        if self.max_accepted_seq is not None and seq <= self.max_accepted_seq:
            # Replay attempt
            for r_seq, r_batch, r_receipt in self.replay_window:
                if r_seq == seq:
                    if norm_batch == r_batch:
                        receipt_copy = copy.deepcopy(r_receipt)
                        receipt_copy["replayed"] = True
                        return receipt_copy
                    else:
                        raise TrackingError(f"replay conflict at seq {seq}", code="replay_conflict")
            raise TrackingError(f"stale replay at seq {seq}", code="stale_replay")

        # New batch sequence checks
        expected_seq = 0 if self.max_accepted_seq is None else self.max_accepted_seq + 1
        if seq != expected_seq:
            raise TrackingError(f"nonconsecutive seq: expected {expected_seq}, got {seq}", code="sequence_error")

        if self.last_batch_t_ms is not None and t_ms <= self.last_batch_t_ms:
            raise TrackingError(f"nonincreasing timestamp: last {self.last_batch_t_ms}, got {t_ms}", code="sequence_error")

        # 1. Determine which tracks to close
        tracks_to_close: List[TrackState] = []
        remaining_tracks: List[TrackState] = []
        close_reasons: Dict[str, str] = {}

        if norm_batch["reset"]:
            for tid, track in self.active_tracks.items():
                tracks_to_close.append(track)
                close_reasons[tid] = "reset"
        else:
            max_gap = self.config["max_gap_ms"]
            max_span = self.config["max_span_ms"]
            for tid, track in self.active_tracks.items():
                if (t_ms - track.end_ms) > max_gap:
                    tracks_to_close.append(track)
                    close_reasons[tid] = "gap"
                elif (t_ms - track.start_ms) > max_span:
                    tracks_to_close.append(track)
                    close_reasons[tid] = "span"
                else:
                    remaining_tracks.append(track)

        # Pre-check outbox capacity
        if len(self.outbox) + len(tracks_to_close) > self.config["max_pending"]:
            raise TrackingError("outbox capacity exceeded", code="capacity")

        # 2. Build feasible bipartite graph
        dets = norm_batch["detections"]
        num_tracks = len(remaining_tracks)
        num_dets = len(dets)

        gate_base = self.config["gate_base"]
        gate_speed = self.config["gate_speed"]
        max_speed = self.config["max_speed"]
        max_area_ratio = self.config["max_area_ratio"]
        app_weight = self.config["appearance_weight"]
        app_gate = self.config["appearance_gate"]
        ambiguity_margin = self.config["ambiguity_margin"]

        # Track predictions and geometry
        track_preds: List[Tuple[float, float]] = []
        track_areas: List[float] = []
        for track in remaining_tracks:
            pred_cx, pred_cy = track.predict_center(t_ms, max_speed)
            track_preds.append((pred_cx, pred_cy))
            track_areas.append(track.last_box[2] * track.last_box[3])

        det_centers: List[Tuple[float, float]] = []
        det_areas: List[float] = []
        for det in dets:
            cx = det["bbox"][0] + det["bbox"][2] / 2.0
            cy = det["bbox"][1] + det["bbox"][3] / 2.0
            det_centers.append((cx, cy))
            det_areas.append(det["bbox"][2] * det["bbox"][3])

        feasible_edges: List[Tuple[int, int, int]] = []
        track_adj: List[List[int]] = [[] for _ in range(num_tracks)]
        det_adj: List[List[int]] = [[] for _ in range(num_dets)]

        for ti, track in enumerate(remaining_tracks):
            dt = (t_ms - track.end_ms) / 1000.0
            g = gate_base + gate_speed * dt
            pred_cx, pred_cy = track_preds[ti]
            t_area = track_areas[ti]

            for dj, det in enumerate(dets):
                det_cx, det_cy = det_centers[dj]
                d = math.hypot(pred_cx - det_cx, pred_cy - det_cy)
                if d > g:
                    continue

                d_area = det_areas[dj]
                ratio = d_area / t_area
                if ratio < (1.0 / max_area_ratio) or ratio > max_area_ratio:
                    continue

                if track.appearance is not None and det["appearance"] is not None:
                    a = 0.5 * sum(abs(track.appearance[k] - det["appearance"][k]) for k in range(4))
                    if a > app_gate:
                        continue
                else:
                    a = 0.0

                cost = math.floor(1000000.0 * (d / g + app_weight * a) + 0.5)
                feasible_edges.append((ti, dj, int(cost)))
                track_adj[ti].append(dj)
                det_adj[dj].append(ti)

        # 3. Find connected components
        visited_t = [False] * num_tracks
        visited_d = [False] * num_dets
        components: List[Tuple[List[int], List[int], List[Tuple[int, int, int]]]] = []

        for ti in range(num_tracks):
            if visited_t[ti] or not track_adj[ti]:
                continue
            comp_t: List[int] = []
            comp_d: List[int] = []
            q: collections.deque[Tuple[int, int]] = collections.deque([(0, ti)])
            visited_t[ti] = True

            while q:
                is_det, idx = q.popleft()
                if is_det:
                    comp_d.append(idx)
                    for nxt_t in det_adj[idx]:
                        if not visited_t[nxt_t]:
                            visited_t[nxt_t] = True
                            q.append((0, nxt_t))
                else:
                    comp_t.append(idx)
                    for nxt_d in track_adj[idx]:
                        if not visited_d[nxt_d]:
                            visited_d[nxt_d] = True
                            q.append((1, nxt_d))

            comp_edges: List[Tuple[int, int, int]] = []
            set_t = set(comp_t)
            set_d = set(comp_d)
            for u, v, c in feasible_edges:
                if u in set_t and v in set_d:
                    comp_edges.append((u, v, c))

            components.append((comp_t, comp_d, comp_edges))

        # Check for any remaining detections with edges
        for dj in range(num_dets):
            if not visited_d[dj] and det_adj[dj]:
                comp_t = []
                comp_d = []
                q = collections.deque([(1, dj)])
                visited_d[dj] = True
                while q:
                    is_det, idx = q.popleft()
                    if is_det:
                        comp_d.append(idx)
                        for nxt_t in det_adj[idx]:
                            if not visited_t[nxt_t]:
                                visited_t[nxt_t] = True
                                q.append((0, nxt_t))
                    else:
                        comp_t.append(idx)
                        for nxt_d in track_adj[idx]:
                            if not visited_d[nxt_d]:
                                visited_d[nxt_d] = True
                                q.append((1, nxt_d))
                set_t = set(comp_t)
                set_d = set(comp_d)
                comp_edges = [e for e in feasible_edges if e[0] in set_t and e[1] in set_d]
                components.append((comp_t, comp_d, comp_edges))

        # 4. Process each component
        matched_pairs: List[Tuple[int, int]] = []
        ambiguous_tracks: Set[int] = set()
        ambiguous_dets: Dict[int, str] = {}  # dj -> reason ('merge' or 'cost_tie')
        unmatched_dets_in_unambig: List[int] = []

        for comp_t, comp_d, comp_edges in components:
            # Check possible merge rule
            is_merge = False
            for dj in comp_d:
                det = dets[dj]
                bx, by, bw, bh = det["bbox"]
                bx2, by2 = bx + bw, by + bh
                enclosed_tracks = 0
                for ti in det_adj[dj]:
                    pred_cx, pred_cy = track_preds[ti]
                    if bx <= pred_cx <= bx2 and by <= pred_cy <= by2:
                        enclosed_tracks += 1
                if enclosed_tracks >= 2:
                    is_merge = True
                    break

            if is_merge:
                for ti in comp_t:
                    ambiguous_tracks.add(ti)
                for dj in comp_d:
                    ambiguous_dets[dj] = "merge"
                continue

            # Solve maximum cardinality, minimum cost matching
            map_u = {orig_u: idx for idx, orig_u in enumerate(comp_t)}
            map_v = {orig_v: idx for idx, orig_v in enumerate(comp_d)}
            sub_edges = [(map_u[u], map_v[v], c) for u, v, c in comp_edges]

            K, C, best_m = _solve_matching(len(comp_t), len(comp_d), sub_edges)

            # Check matching ambiguity
            is_ambiguous = False
            for edge in best_m:
                sub_K, sub_C, _ = _solve_matching(len(comp_t), len(comp_d), sub_edges, forbidden=edge)
                if sub_K == K and sub_C <= C + ambiguity_margin:
                    is_ambiguous = True
                    break

            if is_ambiguous:
                for ti in comp_t:
                    ambiguous_tracks.add(ti)
                for dj in comp_d:
                    ambiguous_dets[dj] = "cost_tie"
            else:
                comp_matched_v: Set[int] = set()
                for u_idx, v_idx in best_m:
                    matched_pairs.append((comp_t[u_idx], comp_d[v_idx]))
                    comp_matched_v.add(comp_d[v_idx])
                for dj in comp_d:
                    if dj not in comp_matched_v:
                        unmatched_dets_in_unambig.append(dj)

        # Isolated detections (no feasible edges)
        born_det_indices: List[int] = list(unmatched_dets_in_unambig)
        for dj in range(num_dets):
            if not det_adj[dj] and dj not in ambiguous_dets:
                born_det_indices.append(dj)

        # 5. Check track capacity before applying any state mutations
        total_active_after = num_tracks + len(born_det_indices)
        if total_active_after > self.config["max_tracks"]:
            raise TrackingError("max_tracks capacity exceeded", code="capacity")

        # --- COMMIT OPERATIONS TO STATE ---

        # 1. Close expired tracks
        newly_closed_episodes: List[Dict[str, Any]] = []
        tracks_to_close.sort(key=lambda t: (t.start_ms, t.track_id))
        for track in tracks_to_close:
            reason = close_reasons[track.track_id]
            ep = track.to_episode_dict(self.camera_id, self.unit_id, reason)
            newly_closed_episodes.append(ep)
            self.outbox.append(ep)
            del self.active_tracks[track.track_id]

        closed_ids = [ep["track_id"] for ep in newly_closed_episodes]

        # 2. Update ambiguous tracks
        for ti in ambiguous_tracks:
            remaining_tracks[ti].ambiguous_batches += 1

        # 3. Update matched tracks
        det_assignments: Dict[str, Dict[str, Any]] = {}
        for ti, dj in matched_pairs:
            track = remaining_tracks[ti]
            det = dets[dj]
            track.accept_observation(t_ms, det, self.config["path_points"])
            det_assignments[det["id"]] = {
                "detection_id": det["id"],
                "track_id": track.track_id,
                "status": "matched",
                "reason": None,
            }

        # 4. Mark ambiguous detections
        for dj, reason in ambiguous_dets.items():
            det = dets[dj]
            det_assignments[det["id"]] = {
                "detection_id": det["id"],
                "track_id": None,
                "status": "ambiguous",
                "reason": reason,
            }

        # 5. Create new tracks for born detections in ascending detection ID order
        born_det_indices.sort(key=lambda dj: dets[dj]["id"])
        for dj in born_det_indices:
            det = dets[dj]
            new_tid = f"t{self.next_track_num:08d}"
            self.next_track_num += 1
            new_track = TrackState(new_tid, t_ms, det, self.config["path_points"])
            self.active_tracks[new_tid] = new_track
            det_assignments[det["id"]] = {
                "detection_id": det["id"],
                "track_id": new_tid,
                "status": "born",
                "reason": None,
            }

        # Format assignments sorted by detection ID
        assignments = [det_assignments[det["id"]] for det in dets]
        assignments.sort(key=lambda a: a["detection_id"])

        receipt = {
            "seq": seq,
            "replayed": False,
            "assignments": assignments,
            "closed": closed_ids,
        }

        # Update high-water mark, timestamp and replay buffer
        self.max_accepted_seq = seq
        self.last_batch_t_ms = t_ms
        self.replay_window.append((seq, norm_batch, copy.deepcopy(receipt)))

        return receipt

    def drain(self) -> List[Dict[str, Any]]:
        """Drain and clear all currently pending episodes from outbox."""
        episodes = self.outbox
        self.outbox = []
        return episodes

    def finish(self) -> List[str]:
        """Seal tracker and close all active tracks with reason 'finish'."""
        if self.is_finished:
            return []

        if len(self.outbox) + len(self.active_tracks) > self.config["max_pending"]:
            raise TrackingError("outbox capacity exceeded on finish", code="capacity")

        active_list = list(self.active_tracks.values())
        active_list.sort(key=lambda t: (t.start_ms, t.track_id))

        closed_ids: List[str] = []
        for track in active_list:
            ep = track.to_episode_dict(self.camera_id, self.unit_id, "finish")
            self.outbox.append(ep)
            closed_ids.append(track.track_id)

        self.active_tracks.clear()
        self.is_finished = True
        return closed_ids

    def snapshot(self) -> Dict[str, Any]:
        """Export independent snapshot envelope of current tracker state."""
        state = {
            "schema_version": 1,
            "camera_id": self.camera_id,
            "unit_id": self.unit_id,
            "config": copy.deepcopy(self.config),
            "next_track_num": self.next_track_num,
            "max_accepted_seq": self.max_accepted_seq,
            "last_batch_t_ms": self.last_batch_t_ms,
            "is_finished": self.is_finished,
            "outbox": copy.deepcopy(self.outbox),
            "active_tracks": [t.serialize() for t in self.active_tracks.values()],
            "replay_window": [
                [r_seq, r_batch, r_receipt] for r_seq, r_batch, r_receipt in self.replay_window
            ],
        }

        canonical_bytes = json.dumps(
            state,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("utf-8")
        sha = hashlib.sha256(canonical_bytes).hexdigest().lower()

        return {
            "schema": _SNAPSHOT_SCHEMA,
            "state": state,
            "sha256": sha,
        }

    @classmethod
    def restore(cls, checkpoint: Dict[str, Any]) -> Tracker:
        """Restore independent Tracker from verified checkpoint envelope."""
        if not isinstance(checkpoint, dict) or _is_bool(checkpoint):
            raise TrackingError("checkpoint must be a dictionary", code="invalid_snapshot")

        for k in checkpoint:
            if k not in ("schema", "state", "sha256"):
                raise TrackingError(f"unknown checkpoint envelope key: {k}", code="invalid_snapshot")

        if checkpoint.get("schema") != _SNAPSHOT_SCHEMA:
            raise TrackingError("unsupported or missing snapshot schema", code="invalid_snapshot")

        state = checkpoint.get("state")
        if not isinstance(state, dict) or _is_bool(state):
            raise TrackingError("state must be a dictionary", code="invalid_snapshot")

        try:
            canonical_bytes = json.dumps(
                state,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=True,
                allow_nan=False,
            ).encode("utf-8")
        except Exception as ex:
            raise TrackingError(f"cannot serialize state: {ex}", code="invalid_snapshot")

        computed_sha = hashlib.sha256(canonical_bytes).hexdigest().lower()
        if checkpoint.get("sha256") != computed_sha:
            raise TrackingError("snapshot sha256 mismatch", code="invalid_snapshot")

        # Validate state contents
        required_state_keys = {
            "schema_version",
            "camera_id",
            "unit_id",
            "config",
            "next_track_num",
            "max_accepted_seq",
            "last_batch_t_ms",
            "is_finished",
            "outbox",
            "active_tracks",
            "replay_window",
        }
        for k in required_state_keys:
            if k not in state:
                raise TrackingError(f"missing state key: {k}", code="invalid_snapshot")

        cam_id = state["camera_id"]
        unit_id = state["unit_id"]
        if not isinstance(cam_id, str) or not _ID_REGEX.match(cam_id):
            raise TrackingError("invalid camera_id in snapshot", code="invalid_snapshot")
        if not isinstance(unit_id, str) or not _ID_REGEX.match(unit_id):
            raise TrackingError("invalid unit_id in snapshot", code="invalid_snapshot")

        try:
            cfg = _validate_config(state["config"])
        except Exception:
            raise TrackingError("invalid config in snapshot", code="invalid_snapshot")

        tracker = cls.__new__(cls)
        tracker.camera_id = cam_id
        tracker.unit_id = unit_id
        tracker.config = cfg

        if not _is_int(state["next_track_num"]) or state["next_track_num"] < 1:
            raise TrackingError("invalid next_track_num in snapshot", code="invalid_snapshot")
        tracker.next_track_num = int(state["next_track_num"])

        max_seq = state["max_accepted_seq"]
        if max_seq is not None and (not _is_int(max_seq) or max_seq < 0):
            raise TrackingError("invalid max_accepted_seq in snapshot", code="invalid_snapshot")
        tracker.max_accepted_seq = int(max_seq) if max_seq is not None else None

        last_t = state["last_batch_t_ms"]
        if last_t is not None and (not _is_int(last_t) or last_t < 0):
            raise TrackingError("invalid last_batch_t_ms in snapshot", code="invalid_snapshot")
        tracker.last_batch_t_ms = int(last_t) if last_t is not None else None

        if not isinstance(state["is_finished"], bool):
            raise TrackingError("invalid is_finished in snapshot", code="invalid_snapshot")
        tracker.is_finished = bool(state["is_finished"])

        # Validate outbox
        outbox = state["outbox"]
        if not isinstance(outbox, list) or _is_bool(outbox) or len(outbox) > cfg["max_pending"]:
            raise TrackingError("invalid outbox in snapshot", code="invalid_snapshot")
        tracker.outbox = copy.deepcopy(outbox)

        # Validate active tracks
        active_list = state["active_tracks"]
        if not isinstance(active_list, list) or _is_bool(active_list) or len(active_list) > cfg["max_tracks"]:
            raise TrackingError("invalid active_tracks in snapshot", code="invalid_snapshot")

        tracker.active_tracks = {}
        for td in active_list:
            if not isinstance(td, dict) or _is_bool(td):
                raise TrackingError("track data in snapshot must be dict", code="invalid_snapshot")
            ts = TrackState.deserialize(td)
            tracker.active_tracks[ts.track_id] = ts

        # Validate replay window
        replay_list = state["replay_window"]
        if not isinstance(replay_list, list) or _is_bool(replay_list) or len(replay_list) > cfg["replay_batches"]:
            raise TrackingError("invalid replay_window in snapshot", code="invalid_snapshot")

        tracker.replay_window = collections.deque(maxlen=cfg["replay_batches"])
        for item in replay_list:
            if not isinstance(item, (list, tuple)) or len(item) != 3:
                raise TrackingError("invalid replay item in snapshot", code="invalid_snapshot")
            tracker.replay_window.append((int(item[0]), copy.deepcopy(item[1]), copy.deepcopy(item[2])))

        return tracker
