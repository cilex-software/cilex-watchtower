"""Deterministic, resumable, streaming temporal tracking for Cilex Watchtower Labs.

This is the labs-tracking benchmark engine (docs/benchmarks/labs-tracking/CONTRACT.md).
It consumes timestamped batches of foreground detections and produces stable tracks
and passage records: multiple objects, crossings, short occlusions, unresolved
associations, recording discontinuities, checkpoint/resume and bounded retained state.

It is a tracking foundation for later recognition, on purpose: nothing here infers a
person/vehicle/clothing class from a geometric shape, and no detector or trained model
is involved. Detections and optional appearance descriptors are SUPPLIED inputs.

DESIGN, in one place:

  * ONE Tracker per (camera_id, unit_id). Track IDs are local to that scope:
    "t" + an increasing counter, padded to at least eight decimals (t00000001 ...).
    A tracker never attaches a detection from another scope (wrong_scope).

  * STATE IS THE SNAPSHOT. Every piece of mutable state lives in JSON-native
    dicts/lists that ARE the checkpoint document: snapshot() deep-copies the live
    structures and hashes their canonical JSON; restore() validates and deep-copies
    them back. Because there is no second representation, an uninterrupted run and a
    restored run cannot drift apart (contract section 9 equivalence), and no clock,
    hash seed, process or object address can leak into output.

  * ATOMIC OPERATIONS. feed() validates a batch completely, then computes every
    consequence (expiry closures, association, ambiguity, births) into locals, then
    checks BOTH capacities (max_tracks, max_pending), and only then mutates. A
    rejected operation therefore leaves the entire observable state -- counters,
    replay history, pending output, future IDs -- exactly as it was (section 5).

  * BOUNDED REPLAY, NOT EXACTLY-ONCE. The last `replay_batches` accepted NEW batches
    are retained as (canonical input identity, original receipt). A same-content retry
    inside the window returns the original receipt with replayed=true and changes
    nothing, even after the episodes it closed were drained; outside the window the
    tracker answers stale_replay rather than guess at history it no longer holds.

  * MATCHING IS GLOBAL, NEVER GREEDY. Feasible track/detection edges (distance gate,
    area-ratio gate, appearance gate; integer quantized cost) are split into connected
    components; each component gets a MAXIMUM-cardinality, then MINIMUM-cost matching
    (successive shortest augmenting paths, exact integer costs). Ambiguity is decided
    by re-solving with each selected edge forbidden: any different size-K matching
    within `ambiguity_margin` abstains the WHOLE component, and a detection box that
    contains the predicted centers of two feasible tracks abstains it as a possible
    merge first. A completely indistinguishable crossing is allowed to stay
    unresolved; no identity is manufactured from evidence that does not provide it.

  * EVIDENCE, NOT INTERPOLATION. Episode counters, path length, largest box and the
    bounded path come from accepted observations only. A track coasting through
    empty or ambiguous batches gains no synthetic observation, and a closure ends at
    the last ACTUAL observation, never at the timeout or reset time. The bounded path
    is the prescribed online simplifier: past `path_points`, the interior sample with
    the smallest absolute cross product of its adjacent segments is dropped (earliest
    timestamp wins a tie); the first and last samples are never dropped.

Python 3.12, standard library only. No I/O, no clock, no randomness, no subprocess.
"""
from __future__ import annotations

import copy
import hashlib
import heapq
import json
import math
import re
from typing import Any

#: Snapshot envelope schema (contract section 9).
SCHEMA = "labs-temporal-tracker/v1"

__all__ = ["TrackingError", "Tracker", "SCHEMA"]

_ID_RE = re.compile(r"[A-Za-z0-9_.:-]{1,64}")
_TRACK_ID_RE = re.compile(r"t[0-9]{8,}")
_SHA_RE = re.compile(r"[0-9a-f]{64}")

_MAX_SEQ = 2147483647            # 2**31 - 1
_MAX_T_MS = 9007199254740991     # 2**53 - 1

_BATCH_KEYS = {"camera_id", "unit_id", "seq", "t_ms", "detections", "reset"}
_DETECTION_KEYS = {"id", "bbox", "appearance"}

#: key -> (default, kind, low, high, low_is_exclusive).  kind "real" accepts any
#: finite non-bool int/float (stored as float); kind "int" accepts only ints.
_CONFIG_SPEC: dict[str, tuple[Any, str, Any, Any, bool]] = {
    "gate_base": (0.15, "real", 0.0, 1.0, True),
    "gate_speed": (0.10, "real", 0.0, 2.0, False),
    "max_speed": (1.0, "real", 0.0, 10.0, True),
    "max_gap_ms": (2000, "int", 1, 10000, False),
    "max_span_ms": (299000, "int", 1, 299000, False),
    "max_area_ratio": (4.0, "real", 1.0, 100.0, False),
    "appearance_weight": (0.25, "real", 0.0, 2.0, False),
    "appearance_gate": (0.50, "real", 0.0, 1.0, False),
    "ambiguity_margin": (1000, "int", 0, 1000000, False),
    "max_tracks": (64, "int", 1, 128, False),
    "max_detections": (64, "int", 1, 128, False),
    "max_pending": (256, "int", 1, 1024, False),
    "replay_batches": (32, "int", 1, 128, False),
    "path_points": (32, "int", 2, 128, False),
}

_EPISODE_KEYS = {"camera_id", "unit_id", "track_id", "start_ms", "end_ms",
                 "observations", "ambiguous_batches", "reason", "bbox", "bbox_at_ms",
                 "first_center", "last_center", "path_length", "net_displacement",
                 "mean_speed", "max_observation_gap_ms", "path"}
_REASONS = {"gap", "span", "reset", "finish"}

_STATE_KEYS = {"camera_id", "unit_id", "config", "next_seq", "last_t_ms",
               "next_track_id", "finished", "tracks", "outbox", "replay"}
_TRACK_KEYS = {"id", "start_ms", "end_ms", "first_center", "last_center", "vx", "vy",
               "last_bbox", "appearance", "observations", "ambiguous_batches",
               "path_length", "max_gap_ms", "best_bbox", "best_bbox_t_ms", "path"}
_RECEIPT_KEYS = {"seq", "replayed", "assignments", "closed"}
_ASSIGN_KEYS = {"detection_id", "track_id", "status", "reason"}
_REPLAY_KEYS = {"seq", "identity", "receipt"}


class TrackingError(ValueError):
    """An expected validation/state failure. `code` is the public error code."""

    def __init__(self, code: str, message: str = ""):
        super().__init__(message or code)
        self.code = code


def _err(code: str, msg: str) -> TrackingError:
    return TrackingError(code, msg)


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _is_real(v: Any) -> bool:
    """A finite non-bool int/float. Numeric strings, NaN and infinity are not real."""
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _check_id(v: Any, what: str, code: str) -> str:
    if not isinstance(v, str) or _ID_RE.fullmatch(v) is None:
        raise _err(code, f"{what} must be a string matching [A-Za-z0-9_.:-]{{1,64}}")
    return v


def _check_track_id(v: Any, code: str) -> str:
    if not isinstance(v, str) or _TRACK_ID_RE.fullmatch(v) is None:
        raise _err(code, f"malformed track id {v!r}")
    return v


def _resolve_config(config: Any, code: str) -> dict:
    """The 14 known keys, defaults filled, ranges enforced; max_pending >= max_tracks."""
    if config is None:
        config = {}
    if not isinstance(config, dict):
        raise _err(code, "config must be an object")
    unknown = set(config) - set(_CONFIG_SPEC)
    if unknown:
        raise _err(code, f"unknown config key(s): {sorted(unknown)}")
    out: dict[str, Any] = {}
    for key, (default, kind, lo, hi, lo_excl) in _CONFIG_SPEC.items():
        v = config.get(key, default)
        if kind == "int":
            if not _is_int(v):
                raise _err(code, f"config {key} must be an integer")
        else:
            if not _is_real(v):
                raise _err(code, f"config {key} must be a finite real number")
            v = float(v)
        if v < lo or (lo_excl and v == lo) or v > hi:
            raise _err(code, f"config {key}={v!r} outside its permitted range")
        out[key] = v
    if out["max_pending"] < out["max_tracks"]:
        raise _err(code, "config max_pending must be >= max_tracks")
    return out


def _canonical(obj: Any) -> str:
    """Deterministic JSON text: the form hashed for snapshots and replay identity."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                      allow_nan=False)


def _check_bbox(v: Any, code: str) -> list[float]:
    """[x, y, w, h]: finite reals, x,y>=0, w,h>=1e-6, x+w<=1, y+h<=1. Returns floats."""
    if not isinstance(v, list) or len(v) != 4 or not all(_is_real(c) for c in v):
        raise _err(code, "bbox must be a list of four finite real numbers")
    x, y, w, h = (float(c) for c in v)
    if x < 0.0 or y < 0.0 or w < 1e-6 or h < 1e-6 or x + w > 1.0 or y + h > 1.0:
        raise _err(code, f"bbox {v!r} outside the unit square rules")
    return [x, y, w, h]


def _check_appearance(v: Any, code: str) -> list[float] | None:
    if v is None:
        return None
    if not isinstance(v, list) or len(v) != 4 or not all(_is_real(c) for c in v):
        raise _err(code, "appearance must be null or a list of four finite reals")
    a = [float(c) for c in v]
    if any(c < 0.0 or c > 1.0 for c in a):
        raise _err(code, "appearance components must lie in 0..1")
    if abs(sum(a) - 1.0) > 1e-9:
        raise _err(code, "appearance components must sum to 1 within 1e-9")
    return a


def _check_center(v: Any, what: str, code: str) -> list[float]:
    if not isinstance(v, list) or len(v) != 2 or not all(_is_real(c) for c in v):
        raise _err(code, f"{what} must be a two-element list of finite reals")
    return [float(v[0]), float(v[1])]


# ---------------------------------------------------------------------------
# matching: maximum cardinality, then minimum summed integer cost, per component
# ---------------------------------------------------------------------------
def _solve_matching(n_t: int, n_d: int, edges: dict[tuple[int, int], int],
                    forbid: tuple[int, int] | None = None
                    ) -> tuple[int, int, list[tuple[int, int]]]:
    """Min-cost max-flow on the component's bipartite graph.

    Successive shortest augmenting paths (Dijkstra with Johnson potentials; all
    original costs are non-negative integers, so zero potentials are a valid start).
    Returns (cardinality K, summed cost C of a cheapest size-K matching, its pairs).
    Deterministic: adjacency is built in sorted edge order and the heap breaks ties
    by node index. Whether that tie-break is ever observable is decided by the
    ambiguity rule: an equal-cost alternative within the margin abstains anyway.
    """
    n = n_t + n_d + 2
    src, sink = 0, n - 1
    g: list[list[list]] = [[] for _ in range(n)]

    def add(u: int, v: int, cap: int, cost: int) -> None:
        g[u].append([v, cap, cost, len(g[v])])
        g[v].append([u, 0, -cost, len(g[u]) - 1])

    for i in range(n_t):
        add(src, 1 + i, 1, 0)
    for (i, j), c in edges.items():
        if (i, j) != forbid:
            add(1 + i, 1 + n_t + j, 1, c)
    for j in range(n_d):
        add(1 + n_t + j, sink, 1, 0)

    flow = 0
    h = [0] * n
    while True:
        dist = [None] * n
        dist[src] = 0
        prev_v = [-1] * n
        prev_e = [-1] * n
        pq = [(0, src)]
        while pq:
            d, u = heapq.heappop(pq)
            if dist[u] is not None and d > dist[u]:
                continue
            for k, e in enumerate(g[u]):
                if e[1] <= 0:
                    continue
                nd = d + e[2] + h[u] - h[e[0]]
                if dist[e[0]] is None or nd < dist[e[0]]:
                    dist[e[0]] = nd
                    prev_v[e[0]] = u
                    prev_e[e[0]] = k
                    heapq.heappush(pq, (nd, e[0]))
        if dist[sink] is None:
            break
        for v in range(n):
            if dist[v] is not None:
                h[v] += dist[v]
        v = sink
        while v != src:
            e = g[prev_v[v]][prev_e[v]]
            e[1] -= 1
            g[v][e[3]][1] += 1
            v = prev_v[v]
        flow += 1
    pairs = []
    cost = 0
    for i in range(n_t):
        for e in g[1 + i]:
            if 1 + n_t <= e[0] < 1 + n_t + n_d and e[1] == 0:
                pairs.append((i, e[0] - (1 + n_t)))
                cost += edges[(i, e[0] - (1 + n_t))]
    return flow, cost, pairs


def _cross(a: list, b: list, c: list) -> float:
    """|cross product| of the two spatial segments meeting at path sample b."""
    ax, ay = b[1] - a[1], b[2] - a[2]
    bx, by = c[1] - b[1], c[2] - b[2]
    return abs(ax * by - ay * bx)


class Tracker:
    """One deterministic tracking scope: a (camera_id, unit_id) pair.

    feed(batch) -> receipt; drain() -> pending closed episodes; finish() seals;
    snapshot()/restore() checkpoint the complete state. All data in and out is
    ordinary JSON-compatible dicts/lists/scalars, and none of it aliases mutable
    internal state. See the module docstring for the design rules.
    """

    def __init__(self, camera_id: str, unit_id: str, config: dict | None = None):
        self._cam = _check_id(camera_id, "camera_id", "invalid_input")
        self._unit = _check_id(unit_id, "unit_id", "invalid_input")
        self._cfg = _resolve_config(config, "invalid_config")
        self._next_seq = 0                 # next accepted NEW batch must carry this seq
        self._last_t: int | None = None    # t_ms of the last accepted NEW batch
        self._next_id = 1                  # next track counter value (t00000001 first)
        self._finished = False
        self._tracks: dict[str, dict] = {}
        self._outbox: list[dict] = []      # closed episodes, FIFO, pending drain()
        self._replay: dict[int, list] = {} # seq -> [canonical identity, stored receipt]

    # -- introspection -------------------------------------------------------
    @property
    def config(self) -> dict:
        """A copy of the resolved configuration (defaults filled, ranges checked)."""
        return copy.deepcopy(self._cfg)

    # -- input validation ------------------------------------------------------
    def _normalize_batch(self, batch: Any) -> tuple[int, int, bool, list, str]:
        """Validate a batch completely and return it in canonical processing form:
        (seq, t_ms, reset, detections, identity). detections is a list of
        (det_id, cx, cy, area, bbox_floats, appearance_floats_or_None) sorted by
        ascending detection id; identity is the canonical JSON used by replay.
        Raises before touching anything: nothing here mutates the tracker.
        """
        if not isinstance(batch, dict):
            raise _err("invalid_input", "batch must be an object")
        unknown = set(batch) - _BATCH_KEYS
        if unknown:
            raise _err("invalid_input", f"unknown batch key(s): {sorted(unknown)}")
        missing = {"camera_id", "unit_id", "seq", "t_ms", "detections"} - set(batch)
        if missing:
            raise _err("invalid_input", f"missing batch key(s): {sorted(missing)}")
        cam, unit = batch["camera_id"], batch["unit_id"]
        if not isinstance(cam, str) or not isinstance(unit, str):
            raise _err("invalid_input", "camera_id and unit_id must be strings")
        if cam != self._cam or unit != self._unit:
            raise _err("wrong_scope",
                       f"batch is for {cam}/{unit}; this tracker is {self._cam}/{self._unit}")
        seq, t_ms = batch["seq"], batch["t_ms"]
        if not _is_int(seq) or not 0 <= seq <= _MAX_SEQ:
            raise _err("invalid_input", "seq must be an integer in 0..2147483647")
        if not _is_int(t_ms) or not 0 <= t_ms <= _MAX_T_MS:
            raise _err("invalid_input", "t_ms must be an integer in 0..9007199254740991")
        reset = batch.get("reset", False)
        if not isinstance(reset, bool):
            raise _err("invalid_input", "reset must be a boolean")
        dets_in = batch["detections"]
        if not isinstance(dets_in, list):
            raise _err("invalid_input", "detections must be a list")
        if len(dets_in) > self._cfg["max_detections"]:
            raise _err("invalid_input",
                       f"{len(dets_in)} detections exceeds max_detections")
        seen: set[str] = set()
        dets = []
        canon_dets = []
        for d in dets_in:
            if not isinstance(d, dict):
                raise _err("invalid_input", "a detection must be an object")
            unknown = set(d) - _DETECTION_KEYS
            if unknown:
                raise _err("invalid_input", f"unknown detection key(s): {sorted(unknown)}")
            if "id" not in d or "bbox" not in d:
                raise _err("invalid_input", "a detection needs id and bbox")
            did = _check_id(d["id"], "detection id", "invalid_input")
            if did in seen:
                raise _err("invalid_input", f"duplicate detection id {did!r}")
            seen.add(did)
            bbox = _check_bbox(d["bbox"], "invalid_input")
            app = _check_appearance(d.get("appearance"), "invalid_input")
            cx, cy = bbox[0] + bbox[2] / 2.0, bbox[1] + bbox[3] / 2.0
            dets.append((did, cx, cy, bbox[2] * bbox[3], bbox, app))
            canon_dets.append({"id": did, "bbox": bbox, "appearance": app})
        order = sorted(range(len(dets)), key=lambda i: dets[i][0])
        dets = [dets[i] for i in order]
        canon = {"camera_id": cam, "unit_id": unit, "seq": seq, "t_ms": t_ms,
                 "reset": reset, "detections": [canon_dets[i] for i in order]}
        return seq, t_ms, reset, dets, _canonical(canon)

    # -- feed ------------------------------------------------------------------
    def feed(self, batch: dict) -> dict:
        """Accept one batch (or answer a replay of it) and return its receipt."""
        if self._finished:
            raise _err("finished", "the tracker is sealed; no feed is accepted, "
                                   "not even a replay")
        seq, t_ms, reset, dets, identity = self._normalize_batch(batch)
        if seq < self._next_seq:
            # A seq at or below the high-water mark: only the retained window may
            # answer it, and only with the original receipt.
            entry = self._replay.get(seq)
            if entry is None:
                raise _err("stale_replay",
                           f"seq {seq} is older than the retained replay window")
            if entry[0] != identity:
                raise _err("replay_conflict",
                           f"seq {seq} was accepted with different content")
            receipt = copy.deepcopy(entry[1])
            receipt["replayed"] = True
            return receipt
        if seq != self._next_seq:
            raise _err("sequence_error",
                       f"expected seq {self._next_seq}, got {seq}")
        if self._last_t is not None and t_ms <= self._last_t:
            raise _err("sequence_error",
                       f"t_ms {t_ms} does not advance past {self._last_t}")
        return self._process_new(seq, t_ms, reset, dets, identity)

    def _process_new(self, seq: int, t: int, reset: bool, dets: list,
                     identity: str) -> dict:
        cfg = self._cfg
        tracks = self._tracks

        # 1. Closures, decided BEFORE association. A reset batch closes everything
        #    with reason reset; otherwise strict >: gap first, span only if gap fails.
        closing: list[tuple[str, str]] = []
        if reset:
            closing = [(tid, "reset") for tid in tracks]
        else:
            for tid, tr in tracks.items():
                if t - tr["end_ms"] > cfg["max_gap_ms"]:
                    closing.append((tid, "gap"))
                elif t - tr["start_ms"] > cfg["max_span_ms"]:
                    closing.append((tid, "span"))
        closing.sort(key=lambda kr: (tracks[kr[0]]["start_ms"], kr[0]))
        closed_ids = [tid for tid, _ in closing]
        closed_set = set(closed_ids)
        remaining = {tid: tr for tid, tr in tracks.items() if tid not in closed_set}
        # Building episode dicts has no side effects; they are committed later.
        new_episodes = [self._episode(tracks[tid], reason) for tid, reason in closing]

        # 2. Feasible edges (distance/area/appearance gates, integer cost).
        tids = sorted(remaining)
        dets_ids = [d[0] for d in dets]      # already ascending
        edges: dict[tuple[int, int], int] = {}
        predicted: dict[int, tuple[float, float]] = {}
        for i, tid in enumerate(tids):
            tr = remaining[tid]
            dt_s = (t - tr["end_ms"]) / 1000.0
            px = tr["last_center"][0] + tr["vx"] * dt_s
            py = tr["last_center"][1] + tr["vy"] * dt_s
            predicted[i] = (px, py)
            g = cfg["gate_base"] + cfg["gate_speed"] * dt_s
            last_area = tr["last_bbox"][2] * tr["last_bbox"][3]
            for j, det in enumerate(dets):
                d = math.hypot(px - det[1], py - det[2])
                if d > g:
                    continue
                ratio = det[3] / last_area
                if ratio > cfg["max_area_ratio"] or ratio * cfg["max_area_ratio"] < 1.0:
                    continue
                a = 0.0
                if tr["appearance"] is not None and det[5] is not None:
                    ta, da = tr["appearance"], det[5]
                    a = 0.5 * (abs(ta[0] - da[0]) + abs(ta[1] - da[1])
                               + abs(ta[2] - da[2]) + abs(ta[3] - da[3]))
                    if a > cfg["appearance_gate"]:
                        continue
                edges[(i, j)] = math.floor(
                    1000000.0 * (d / g + cfg["appearance_weight"] * a) + 0.5)

        # 3. Connected components of the bipartite graph; resolve each.
        adj_t: dict[int, list[int]] = {}
        adj_d: dict[int, list[int]] = {}
        for (i, j) in edges:
            adj_t.setdefault(i, []).append(j)
            adj_d.setdefault(j, []).append(i)
        matched: dict[int, int] = {}          # i -> j
        ambiguous: dict[int, str] = {}        # j -> reason
        ambiguous_tracks: set[int] = set()
        seen_t: set[int] = set()
        seen_d: set[int] = set()
        for i0 in range(len(tids)):
            if i0 in seen_t or i0 not in adj_t:
                continue
            comp_t: list[int] = []
            comp_d: list[int] = []
            stack = [("t", i0)]
            seen_t.add(i0)
            while stack:
                side, k = stack.pop()
                if side == "t":
                    comp_t.append(k)
                    for j in adj_t[k]:
                        if j not in seen_d:
                            seen_d.add(j)
                            stack.append(("d", j))
                else:
                    comp_d.append(k)
                    for i2 in adj_d[k]:
                        if i2 not in seen_t:
                            seen_t.add(i2)
                            stack.append(("t", i2))
            comp_t.sort()
            comp_d.sort()
            self._resolve_component(comp_t, comp_d, tids, dets, edges, predicted,
                                    matched, ambiguous, ambiguous_tracks)

        matched_dets = set(matched.values())
        births = [j for j in range(len(dets))
                  if j not in matched_dets and j not in ambiguous]

        # 4. Capacities, checked BEFORE anything is committed: a rejected operation
        #    must not partially expire tracks, update measurements or advance seq.
        if len(remaining) + len(births) > cfg["max_tracks"]:
            raise _err("capacity",
                       f"{len(remaining) + len(births)} tracks would exceed "
                       f"max_tracks={cfg['max_tracks']}")
        if len(self._outbox) + len(new_episodes) > cfg["max_pending"]:
            raise _err("capacity",
                       f"{len(self._outbox) + len(new_episodes)} pending episodes "
                       f"would exceed max_pending={cfg['max_pending']}")

        # 5. Commit.
        for tid in closed_ids:
            del tracks[tid]
        self._outbox.extend(new_episodes)
        for i, j in matched.items():
            self._accept(remaining[tids[i]], dets[j], t)
        for i in ambiguous_tracks:
            remaining[tids[i]]["ambiguous_batches"] += 1
        assignments: dict[int, tuple] = {}
        for i, j in matched.items():
            assignments[j] = (dets_ids[j], tids[i], "matched", None)
        for j, reason in ambiguous.items():
            assignments[j] = (dets_ids[j], None, "ambiguous", reason)
        for j in births:
            tid = f"t{self._next_id:08d}"
            self._next_id += 1
            tracks[tid] = self._born(tid, dets[j], t)
            assignments[j] = (dets_ids[j], tid, "born", None)
        receipt = {"seq": seq, "replayed": False,
                   "assignments": [dict(zip(("detection_id", "track_id", "status",
                                             "reason"), assignments[j]))
                                   for j in range(len(dets))],
                   "closed": closed_ids}
        self._next_seq = seq + 1
        self._last_t = t
        self._replay[seq] = [identity, copy.deepcopy(receipt)]
        while len(self._replay) > cfg["replay_batches"]:
            del self._replay[min(self._replay)]
        return receipt

    def _resolve_component(self, comp_t: list[int], comp_d: list[int],
                           tids: list[str], dets: list,
                           edges: dict[tuple[int, int], int],
                           predicted: dict[int, tuple[float, float]],
                           matched: dict[int, int], ambiguous: dict[int, str],
                           ambiguous_tracks: set[int]) -> None:
        """One connected component with at least one edge: accept its unique best
        matching, or abstain the WHOLE component (merge first, then cost tie)."""
        cfg = self._cfg
        # Remap to LOCAL indices for the solver: track li = position in comp_t,
        # detection lj = position in comp_d.
        tpos = {i: li for li, i in enumerate(comp_t)}
        dpos = {j: lj for lj, j in enumerate(comp_d)}
        comp_edges = {(tpos[i], dpos[j]): c for (i, j), c in edges.items()
                      if i in tpos and j in dpos}
        # Possible merge: one detection box contains the predicted centers of two
        # tracks it has a feasible edge to (box boundaries included).
        for j in comp_d:
            x, y, w, h = dets[j][4]
            inside = 0
            for i in comp_t:
                if (i, j) not in edges:
                    continue
                px, py = predicted[i]
                if x <= px <= x + w and y <= py <= y + h:
                    inside += 1
            if inside >= 2:
                for jj in comp_d:
                    ambiguous[jj] = "merge"
                ambiguous_tracks.update(comp_t)
                return
        k_best, c_best, pairs = _solve_matching(len(comp_t), len(comp_d), comp_edges)
        # Ambiguity: any DIFFERENT size-K matching within the margin abstains all.
        # Forbidding each selected edge in turn is sound and complete for that:
        # a different matching of the same size omits at least one selected edge.
        tied = False
        if len(comp_edges) > k_best:     # otherwise no different matching can exist
            for li, lj in pairs:
                k2, c2, _ = _solve_matching(len(comp_t), len(comp_d), comp_edges,
                                            forbid=(li, lj))
                if k2 == k_best and c2 <= c_best + cfg["ambiguity_margin"]:
                    tied = True
                    break
            if tied:
                for jj in comp_d:
                    ambiguous[jj] = "cost_tie"
                ambiguous_tracks.update(comp_t)
                return
        for li, lj in pairs:
            matched[comp_t[li]] = comp_d[lj]

    # -- track updates -----------------------------------------------------------
    def _born(self, tid: str, det: tuple, t: int) -> dict:
        _did, cx, cy, _area, bbox, app = det
        return {"id": tid, "start_ms": t, "end_ms": t,
                "first_center": [cx, cy], "last_center": [cx, cy],
                "vx": 0.0, "vy": 0.0, "last_bbox": list(bbox),
                "appearance": list(app) if app is not None else None,
                "observations": 1, "ambiguous_batches": 0,
                "path_length": 0.0, "max_gap_ms": 0,
                "best_bbox": list(bbox), "best_bbox_t_ms": t,
                "path": [[t, cx, cy]]}

    def _accept(self, tr: dict, det: tuple, t: int) -> None:
        """Extend a track with its unambiguously assigned detection."""
        cfg = self._cfg
        _did, cx, cy, area, bbox, app = det
        old_t = tr["end_ms"]
        ox, oy = tr["last_center"]
        dt_s = (t - old_t) / 1000.0
        vx, vy = (cx - ox) / dt_s, (cy - oy) / dt_s
        speed = math.hypot(vx, vy)
        if speed > cfg["max_speed"]:     # cap magnitude, keep direction
            vx *= cfg["max_speed"] / speed
            vy *= cfg["max_speed"] / speed
        tr["vx"], tr["vy"] = vx, vy
        tr["path_length"] += math.hypot(cx - ox, cy - oy)
        if t - old_t > tr["max_gap_ms"]:
            tr["max_gap_ms"] = t - old_t
        tr["end_ms"] = t
        tr["last_center"] = [cx, cy]
        tr["last_bbox"] = list(bbox)
        if app is not None:
            tr["appearance"] = list(app)
        if area > tr["best_bbox"][2] * tr["best_bbox"][3]:
            tr["best_bbox"] = list(bbox)
            tr["best_bbox_t_ms"] = t
        tr["observations"] += 1
        path = tr["path"]
        path.append([t, cx, cy])
        limit = cfg["path_points"]
        while len(path) > limit:
            # Drop the interior sample whose two adjacent segments are most nearly
            # collinear; an exact tie removes the earliest interior timestamp. The
            # first and latest samples are never removed.
            best_i, best_c = 1, _cross(path[0], path[1], path[2])
            for i in range(2, len(path) - 1):
                c = _cross(path[i - 1], path[i], path[i + 1])
                if c < best_c:
                    best_i, best_c = i, c
            del path[best_i]

    def _episode(self, tr: dict, reason: str) -> dict:
        """The closed-track evidence record. Closure ends at the last ACTUAL
        observation; every accumulator came from accepted observations only."""
        first, last = tr["first_center"], tr["last_center"]
        dur_s = (tr["end_ms"] - tr["start_ms"]) / 1000.0
        return {"camera_id": self._cam, "unit_id": self._unit, "track_id": tr["id"],
                "start_ms": tr["start_ms"], "end_ms": tr["end_ms"],
                "observations": tr["observations"],
                "ambiguous_batches": tr["ambiguous_batches"],
                "reason": reason,
                "bbox": list(tr["best_bbox"]), "bbox_at_ms": tr["best_bbox_t_ms"],
                "first_center": list(first), "last_center": list(last),
                "path_length": tr["path_length"],
                "net_displacement": math.hypot(last[0] - first[0], last[1] - first[1]),
                "mean_speed": tr["path_length"] / dur_s if dur_s > 0 else None,
                "max_observation_gap_ms": tr["max_gap_ms"],
                "path": [list(p) for p in tr["path"]]}

    # -- draining / finishing ------------------------------------------------------
    def drain(self) -> list:
        """All pending closed episodes in FIFO order; empties the outbox."""
        out = self._outbox
        self._outbox = []
        return out

    def finish(self) -> list:
        """Close every active track (reason finish) and seal the tracker.

        Subject to the outbox capacity rule like any operation: over capacity the
        call fails atomically and the tracker is NOT sealed. A successful repeat
        returns [] and emits nothing.
        """
        if self._finished:
            return []
        closing = sorted(self._tracks.values(),
                         key=lambda tr: (tr["start_ms"], tr["id"]))
        if len(self._outbox) + len(closing) > self._cfg["max_pending"]:
            raise _err("capacity",
                       f"{len(self._outbox) + len(closing)} pending episodes would "
                       f"exceed max_pending={self._cfg['max_pending']}")
        self._outbox.extend(self._episode(tr, "finish") for tr in closing)
        self._tracks = {}
        self._finished = True
        return [tr["id"] for tr in closing]

    # -- checkpoints ----------------------------------------------------------------
    def snapshot(self) -> dict:
        """A JSON-compatible checkpoint of the complete state. Does not mutate,
        drain or close anything; the returned dict shares nothing with the tracker."""
        state = {"camera_id": self._cam, "unit_id": self._unit,
                 "config": copy.deepcopy(self._cfg),
                 "next_seq": self._next_seq, "last_t_ms": self._last_t,
                 "next_track_id": self._next_id, "finished": self._finished,
                 "tracks": copy.deepcopy([self._tracks[tid]
                                          for tid in sorted(self._tracks)]),
                 "outbox": copy.deepcopy(self._outbox),
                 "replay": [{"seq": s, "identity": e[0], "receipt": copy.deepcopy(e[1])}
                            for s, e in sorted(self._replay.items())]}
        return {"schema": SCHEMA, "state": state,
                "sha256": hashlib.sha256(_canonical(state).encode("utf-8")).hexdigest()}

    @classmethod
    def restore(cls, checkpoint: dict) -> "Tracker":
        """A new Tracker from a snapshot, validated before anything is trusted.

        The checksum is verified over the snapshot's own canonical form, then the
        state is validated structurally and against the tracker's own invariants --
        a recomputed checksum over invalid state does not make it valid.
        """
        tr = cls.__new__(cls)
        tr._load(checkpoint)
        return tr

    def _load(self, checkpoint: Any) -> None:
        if not isinstance(checkpoint, dict) or set(checkpoint) != {"schema", "state",
                                                                   "sha256"}:
            raise _err("invalid_snapshot", "envelope must have exactly schema, state, sha256")
        if checkpoint["schema"] != SCHEMA:
            raise _err("invalid_snapshot", f"schema must be {SCHEMA!r}")
        state, sha = checkpoint["state"], checkpoint["sha256"]
        if not isinstance(sha, str) or _SHA_RE.fullmatch(sha) is None:
            raise _err("invalid_snapshot", "sha256 must be 64 lowercase hex characters")
        try:
            canonical = _canonical(state)
        except (ValueError, TypeError):
            raise _err("invalid_snapshot", "state is not finite JSON") from None
        if hashlib.sha256(canonical.encode("utf-8")).hexdigest() != sha:
            raise _err("invalid_snapshot", "sha256 does not match the state")
        if not isinstance(state, dict) or set(state) != _STATE_KEYS:
            raise _err("invalid_snapshot", "state keys are not exactly the known set")

        cam = _check_id(state["camera_id"], "camera_id", "invalid_snapshot")
        unit = _check_id(state["unit_id"], "unit_id", "invalid_snapshot")
        cfg = _resolve_config(state["config"], "invalid_snapshot")
        next_seq = state["next_seq"]
        if not _is_int(next_seq) or not 0 <= next_seq <= _MAX_SEQ + 1:
            raise _err("invalid_snapshot", "next_seq out of range")
        last_t = state["last_t_ms"]
        if next_seq == 0:
            if last_t is not None:
                raise _err("invalid_snapshot", "no batch accepted but last_t_ms is set")
        elif not _is_int(last_t) or not 0 <= last_t <= _MAX_T_MS:
            raise _err("invalid_snapshot", "last_t_ms out of range")
        next_id = state["next_track_id"]
        if not _is_int(next_id) or next_id < 1:
            raise _err("invalid_snapshot", "next_track_id out of range")
        finished = state["finished"]
        if not isinstance(finished, bool):
            raise _err("invalid_snapshot", "finished must be a boolean")

        tracks_in = state["tracks"]
        if not isinstance(tracks_in, list):
            raise _err("invalid_snapshot", "tracks must be a list")
        outbox_in = state["outbox"]
        if not isinstance(outbox_in, list):
            raise _err("invalid_snapshot", "outbox must be a list")
        if next_seq == 0 and (tracks_in or outbox_in):
            # Every track and every episode came from an accepted batch; with no
            # batch accepted there can be neither.
            raise _err("invalid_snapshot", "no batch accepted but state is nonempty")
        if len(tracks_in) > cfg["max_tracks"]:
            raise _err("invalid_snapshot", "more active tracks than max_tracks")
        tracks: dict[str, dict] = {}
        for raw in tracks_in:
            tr = self._check_track(raw, cfg, cam, unit, next_id)
            if tr["id"] in tracks:
                raise _err("invalid_snapshot", f"duplicate track id {tr['id']}")
            if last_t is not None and tr["end_ms"] > last_t:
                raise _err("invalid_snapshot", "a track ends after the last batch")
            tracks[tr["id"]] = tr

        if len(outbox_in) > cfg["max_pending"]:
            raise _err("invalid_snapshot", "more pending episodes than max_pending")
        outbox = []
        for raw in outbox_in:
            ep = _check_episode(raw, camera_id=cam, unit_id=unit,
                                path_points=cfg["path_points"], code="invalid_snapshot")
            if int(ep["track_id"][1:]) >= next_id:
                raise _err("invalid_snapshot", "episode track id past next_track_id")
            if last_t is not None and ep["end_ms"] > last_t:
                raise _err("invalid_snapshot", "an episode ends after the last batch")
            outbox.append(ep)

        replay_in = state["replay"]
        if not isinstance(replay_in, list):
            raise _err("invalid_snapshot", "replay must be a list")
        # Every accepted NEW batch is retained until evicted past replay_batches, so
        # the window is EXACTLY the seqs in [next_seq-replay_batches, next_seq).
        expect = list(range(max(0, next_seq - cfg["replay_batches"]), next_seq))
        replay: dict[int, list] = {}
        for raw in replay_in:
            if not isinstance(raw, dict) or set(raw) != _REPLAY_KEYS:
                raise _err("invalid_snapshot", "malformed replay entry")
            s = raw["seq"]
            if not _is_int(s) or not 0 <= s <= _MAX_SEQ:
                raise _err("invalid_snapshot", "replay seq out of range")
            if not isinstance(raw["identity"], str):
                raise _err("invalid_snapshot", "replay identity must be a string")
            receipt = self._check_receipt(raw["receipt"], s, next_id)
            if s in replay:
                raise _err("invalid_snapshot", "duplicate replay seq")
            replay[s] = [raw["identity"], receipt]
        if sorted(replay) != expect:
            raise _err("invalid_snapshot",
                       "replay window is not exactly the latest accepted batches")

        self._cam, self._unit, self._cfg = cam, unit, cfg
        self._next_seq, self._last_t = next_seq, last_t
        self._next_id, self._finished = next_id, finished
        self._tracks, self._outbox, self._replay = tracks, outbox, replay

    def _check_track(self, raw: Any, cfg: dict, cam: str, unit: str,
                     next_id: int) -> dict:
        code = "invalid_snapshot"
        if not isinstance(raw, dict) or set(raw) != _TRACK_KEYS:
            raise _err(code, "track keys are not exactly the known set")
        tid = _check_track_id(raw["id"], code)
        if int(tid[1:]) >= next_id:
            raise _err(code, f"track {tid} at or past next_track_id")
        start, end = raw["start_ms"], raw["end_ms"]
        if not _is_int(start) or not _is_int(end) or not (0 <= start <= end <= _MAX_T_MS):
            raise _err(code, f"track {tid}: bad start/end times")
        first = _check_center(raw["first_center"], "first_center", code)
        last = _check_center(raw["last_center"], "last_center", code)
        vx, vy = raw["vx"], raw["vy"]
        if not _is_real(vx) or not _is_real(vy):
            raise _err(code, f"track {tid}: velocity must be finite")
        vx, vy = float(vx), float(vy)
        if math.hypot(vx, vy) > cfg["max_speed"] + 1e-9:
            raise _err(code, f"track {tid}: velocity exceeds max_speed")
        last_bbox = _check_bbox(raw["last_bbox"], code)
        best_bbox = _check_bbox(raw["best_bbox"], code)
        best_t = raw["best_bbox_t_ms"]
        if not _is_int(best_t) or not start <= best_t <= end:
            raise _err(code, f"track {tid}: best_bbox_t_ms outside the track span")
        app = _check_appearance(raw["appearance"], code)
        obs, amb = raw["observations"], raw["ambiguous_batches"]
        if not _is_int(obs) or obs < 1:
            raise _err(code, f"track {tid}: observations must be a positive integer")
        if not _is_int(amb) or amb < 0:
            raise _err(code, f"track {tid}: ambiguous_batches must be >= 0")
        plen = raw["path_length"]
        if not _is_real(plen) or plen < 0:
            raise _err(code, f"track {tid}: path_length must be finite and >= 0")
        max_gap = raw["max_gap_ms"]
        if not _is_int(max_gap) or max_gap < 0 or max_gap > end - start:
            raise _err(code, f"track {tid}: bad max_gap_ms")
        path = _check_path(raw["path"], start, end, code, f"track {tid}")
        if len(path) != min(obs, cfg["path_points"]):
            raise _err(code, f"track {tid}: path length contradicts observations")
        return {"id": tid, "start_ms": start, "end_ms": end,
                "first_center": first, "last_center": last, "vx": vx, "vy": vy,
                "last_bbox": last_bbox, "appearance": app, "observations": obs,
                "ambiguous_batches": amb, "path_length": float(plen),
                "max_gap_ms": max_gap, "best_bbox": best_bbox, "best_bbox_t_ms": best_t,
                "path": path}

    def _check_receipt(self, raw: Any, seq: int, next_id: int) -> dict:
        code = "invalid_snapshot"
        if not isinstance(raw, dict) or set(raw) != _RECEIPT_KEYS:
            raise _err(code, "receipt keys are not exactly seq, replayed, assignments, closed")
        if raw["seq"] != seq:
            raise _err(code, "receipt seq does not match its replay entry")
        if raw["replayed"] is not False:
            raise _err(code, "a stored receipt must have replayed=false")
        assignments = raw["assignments"]
        if not isinstance(assignments, list):
            raise _err(code, "receipt assignments must be a list")
        seen: set[str] = set()
        out_a = []
        for a in assignments:
            if not isinstance(a, dict) or set(a) != _ASSIGN_KEYS:
                raise _err(code, "malformed assignment entry")
            did = _check_id(a["detection_id"], "detection id", code)
            if did in seen:
                raise _err(code, "duplicate detection id in a receipt")
            seen.add(did)
            tid, status, reason = a["track_id"], a["status"], a["reason"]
            if status == "ambiguous":
                if tid is not None or reason not in ("merge", "cost_tie"):
                    raise _err(code, "malformed ambiguous assignment")
            elif status in ("born", "matched"):
                _check_track_id(tid, code)
                if int(tid[1:]) >= next_id:
                    raise _err(code, "assignment names a track past next_track_id")
                if reason is not None:
                    raise _err(code, "reason is only set for ambiguity")
            else:
                raise _err(code, f"unknown assignment status {status!r}")
            out_a.append({"detection_id": did, "track_id": tid,
                          "status": status, "reason": reason})
        if [a["detection_id"] for a in out_a] != sorted(seen):
            raise _err(code, "receipt assignments are not sorted by detection id")
        closed = raw["closed"]
        if not isinstance(closed, list):
            raise _err(code, "receipt closed must be a list")
        out_c = []
        for tid in closed:
            _check_track_id(tid, code)
            if int(tid[1:]) >= next_id:
                raise _err(code, "closed names a track past next_track_id")
            out_c.append(tid)
        return {"seq": seq, "replayed": False, "assignments": out_a, "closed": out_c}


def _check_path(raw: Any, start: int, end: int, code: str, what: str) -> list:
    """The bounded path: [t_ms, cx, cy] samples, strictly increasing in time,
    anchored at the track's first and last observation times."""
    if not isinstance(raw, list) or not raw:
        raise _err(code, f"{what}: path must be a nonempty list")
    out = []
    prev_t = None
    for p in raw:
        if not isinstance(p, list) or len(p) != 3:
            raise _err(code, f"{what}: a path sample must be [t_ms, cx, cy]")
        t, cx, cy = p
        if not _is_int(t) or not _is_real(cx) or not _is_real(cy):
            raise _err(code, f"{what}: bad path sample types")
        if prev_t is not None and t <= prev_t:
            raise _err(code, f"{what}: path times must strictly increase")
        if t < start or t > end:
            raise _err(code, f"{what}: path sample outside the track span")
        prev_t = t
        out.append([t, float(cx), float(cy)])
    if out[0][0] != start or out[-1][0] != end:
        raise _err(code, f"{what}: path must start and end at the observation times")
    return out


def _check_episode(ep: Any, *, camera_id: str | None, unit_id: str | None,
                   path_points: int | None, code: str) -> dict:
    """Validate one closed episode against contract section 8 and return a fresh,
    normalized dict (floats as floats). Shared by restore and by the Labs adapter,
    which applies its hour-specific bounds on top.
    """
    if not isinstance(ep, dict) or set(ep) != _EPISODE_KEYS:
        raise _err(code, "episode keys are not exactly the contract set")
    if camera_id is not None and ep["camera_id"] != camera_id:
        raise _err(code, "episode camera_id does not match the scope")
    _check_id(ep["camera_id"], "camera_id", code)
    if unit_id is not None and ep["unit_id"] != unit_id:
        raise _err(code, "episode unit_id does not match the scope")
    _check_id(ep["unit_id"], "unit_id", code)
    tid = _check_track_id(ep["track_id"], code)
    start, end = ep["start_ms"], ep["end_ms"]
    if not _is_int(start) or not _is_int(end) or not (0 <= start <= end <= _MAX_T_MS):
        raise _err(code, "episode start_ms/end_ms out of range")
    obs, amb = ep["observations"], ep["ambiguous_batches"]
    if not _is_int(obs) or obs < 1:
        raise _err(code, "episode observations must be a positive integer")
    if not _is_int(amb) or amb < 0:
        raise _err(code, "episode ambiguous_batches must be >= 0")
    reason = ep["reason"]
    if reason not in _REASONS:
        raise _err(code, f"episode reason must be one of {sorted(_REASONS)}")
    bbox = _check_bbox(ep["bbox"], code)
    bbox_t = ep["bbox_at_ms"]
    if not _is_int(bbox_t) or not start <= bbox_t <= end:
        raise _err(code, "episode bbox_at_ms outside its span")
    first = _check_center(ep["first_center"], "first_center", code)
    last = _check_center(ep["last_center"], "last_center", code)
    plen, net = ep["path_length"], ep["net_displacement"]
    if not _is_real(plen) or plen < 0 or not _is_real(net) or net < 0:
        raise _err(code, "episode path_length/net_displacement must be finite, >= 0")
    mean = ep["mean_speed"]
    if mean is not None and (not _is_real(mean) or mean < 0):
        raise _err(code, "episode mean_speed must be null or a finite real >= 0")
    if (start == end) != (mean is None):
        raise _err(code, "mean_speed is null exactly when the episode has zero duration")
    max_gap = ep["max_observation_gap_ms"]
    if not _is_int(max_gap) or max_gap < 0 or max_gap > end - start:
        raise _err(code, "episode max_observation_gap_ms out of range")
    if obs == 1 and max_gap != 0:
        raise _err(code, "a single-observation episode has gap 0")
    path = _check_path(ep["path"], start, end, code, "episode")
    if path_points is not None and len(path) > path_points:
        raise _err(code, "episode path exceeds path_points")
    if len(path) > obs:
        raise _err(code, "episode path longer than its observation count")
    return {"camera_id": ep["camera_id"], "unit_id": ep["unit_id"], "track_id": tid,
            "start_ms": start, "end_ms": end, "observations": obs,
            "ambiguous_batches": amb, "reason": reason, "bbox": bbox,
            "bbox_at_ms": bbox_t, "first_center": first, "last_center": last,
            "path_length": float(plen), "net_displacement": float(net),
            "mean_speed": None if mean is None else float(mean),
            "max_observation_gap_ms": max_gap, "path": path}
