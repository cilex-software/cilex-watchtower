"""Labs temporal tracking engine -- contract v1 (`labs-temporal-tracking-v1`).

WHAT THIS IS. A deterministic, resumable, streaming tracker over SUPPLIED
observations. It consumes timestamped batches of foreground detections (box
centre, box size, optional coarse appearance histogram) and produces stable
tracks and closed passage episodes. It infers no class: a box is a box. There
is no model, no image decoding, no network and no subprocess here; the caller
supplies detections, and `temporal_tracks_adapter` is the one place that reads
the existing `MaskFrame`/`Blob` interface.

WHY IT IS SHAPED LIKE THIS.
  * Every accepted operation is planned in full before a single field is
    written, so a rejected batch (capacity, sequence, replay conflict) leaves
    counters, queued output and the next deterministic track ID untouched.
  * Association is a MINIMUM-COST MAXIMUM-CARDINALITY bipartite matching per
    connected component, not greedy nearest-neighbour: the public
    "maximum-cardinality-before-nearest-edge" case loses a whole track under
    greedy. A component whose best matching is not unique within
    `ambiguity_margin`, or in which one detection box encloses the predicted
    centres of two feasible tracks, is reported AMBIGUOUS -- every detection in
    it abstains, every track in it merely coasts, and none of it becomes
    evidence. A crossing the observations cannot resolve stays unresolved.
  * A track owns one bounded path sample (default 32 points) while every
    measurement accumulator (counts, largest box, path length, worst gap) is
    updated from EVERY accepted observation, so bounding the path never changes
    the evidence counts. The sampler is the contract's online rule: drop the
    interior sample whose two adjacent segments have the smallest absolute
    cross product, earliest timestamp wins a tie.
  * State is bounded by configuration (active tracks, path samples, pending
    episodes, replay entries) and independent of stream length.

COST MODEL, kept in one place. For track i and detection j:
    dt = seconds since the track's last accepted observation
    g  = gate_base + gate_speed*dt
    d  = distance from the track's PREDICTED centre to j's box centre
    a  = 0.5*sum(|track.appearance[k] - detection.appearance[k]|), or 0 when
         either side is null (and then no appearance gate applies)
    cost = floor(1000000*(d/g + appearance_weight*a) + 0.5)
Edges need d<=g, an area ratio inside [1/max_area_ratio, max_area_ratio] and,
when both appearances exist, a<=appearance_gate. Booleans are not numbers here
and no malformed measurement is repaired or invented.

RECOVERY. `snapshot()` is a JSON envelope (`schema`, `state`, `sha256`) whose
checksum is the canonical SHA-256 of `state`; `restore()` re-validates the
whole state against the type, bound, scope, ID, clock and counter rules before
adopting it -- a checksum recomputed over an invalid state does not make it
valid. Snapshots survive JSON and a fresh process.

Deliberate reading of two under-specified orderings (see SUBMISSION.md):
structural batch errors are reported before "this tracker is sealed", the seal
before a scope mismatch, and a scope mismatch before replay/window handling.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
from typing import Any, Optional

__all__ = ["TrackingError", "Tracker", "SCHEMA", "DEFAULT_CONFIG",
           "resolve_config", "validate_snapshot"]

SCHEMA = "labs-temporal-tracker/v1"

MAX_SEQ = 2147483647
MAX_T_MS = 9007199254740991
_ID_RE = re.compile(r"[A-Za-z0-9_.:-]{1,64}\Z")
_HEX_RE = re.compile(r"[0-9a-f]{64}\Z")
_BBOX_SLACK = 1e-12

#: default, kind, low, high, low-is-exclusive
_CONFIG_SPEC: dict = {
    "gate_base":         (0.15,   "real", 0.0,  1.0,       True),
    "gate_speed":        (0.10,   "real", 0.0,  2.0,       False),
    "max_speed":         (1.0,    "real", 0.0,  10.0,      True),
    "max_gap_ms":        (2000,   "int",  1,    10000,     False),
    "max_span_ms":       (299000, "int",  1,    299000,    False),
    "max_area_ratio":    (4.0,    "real", 1.0,  100.0,     False),
    "appearance_weight": (0.25,   "real", 0.0,  2.0,       False),
    "appearance_gate":   (0.50,   "real", 0.0,  1.0,       False),
    "ambiguity_margin":  (1000,   "int",  0,    1000000,   False),
    "max_tracks":        (64,     "int",  1,    128,       False),
    "max_detections":    (64,     "int",  1,    128,       False),
    "max_pending":       (256,    "int",  1,    1024,      False),
    "replay_batches":    (32,     "int",  1,    128,       False),
    "path_points":       (32,     "int",  2,    128,       False),
}
_CONFIG_KEYS = frozenset(_CONFIG_SPEC)

DEFAULT_CONFIG: dict = {k: spec[0] for k, spec in _CONFIG_SPEC.items()}

_BATCH_KEYS = frozenset({"camera_id", "unit_id", "seq", "t_ms", "detections",
                         "reset"})
_BATCH_REQUIRED = frozenset({"camera_id", "unit_id", "seq", "t_ms",
                             "detections"})
_DETECTION_KEYS = frozenset({"id", "bbox", "appearance"})
_DETECTION_REQUIRED = frozenset({"id", "bbox"})
_EPISODE_KEYS = frozenset({
    "camera_id", "unit_id", "track_id", "start_ms", "end_ms", "observations",
    "ambiguous_batches", "reason", "bbox", "bbox_at_ms", "first_center",
    "last_center", "path_length", "net_displacement", "mean_speed",
    "max_observation_gap_ms", "path"})
_TRACK_KEYS = frozenset({
    "id", "first_ms", "last_ms", "obs", "ambiguous_batches", "first_center",
    "last_center", "prev_center", "prev_ms", "last_box", "appearance",
    "best_box", "best_ms", "path_length", "max_gap_ms", "path"})
_STATE_KEYS = frozenset({
    "camera_id", "unit_id", "config", "next_index", "last_seq", "last_t_ms",
    "finished", "tracks", "outbox", "replay"})
_REASONS = frozenset({"gap", "span", "reset", "finish"})


class TrackingError(ValueError):
    """An expected validation or state failure. `code` is the contract's slug."""

    __slots__ = ("code",)

    def __init__(self, code: str, message: str = "") -> None:
        super().__init__(("%s: %s" % (code, message)) if message else code)
        self.code = code


def _bad(code: str, message: str = "") -> TrackingError:
    return TrackingError(code, message)


# ----------------------------------------------------------------------------------
# Scalar checks. Booleans are not integers and not reals; strings never coerce.
# ----------------------------------------------------------------------------------
def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _integral(v: Any) -> bool:
    """A real that is exactly an integer (0.0), and safe to treat as one."""
    return (isinstance(v, float) and not isinstance(v, bool)
            and math.isfinite(v) and v.is_integer() and abs(v) <= MAX_T_MS)


def as_int(v: Any, what: str, lo: int, hi: int, code: str = "invalid_input") -> int:
    """An integer in [lo, hi]; an integral float is the same measurement."""
    if _is_int(v):
        n = v
    elif _integral(v):
        n = int(v)
    else:
        raise _bad(code, "%s must be an integer, not %r" % (what, v))
    if n < lo or n > hi:
        raise _bad(code, "%s=%d is outside %d..%d" % (what, n, lo, hi))
    return n


def as_real(v: Any, what: str) -> float:
    if not (isinstance(v, (int, float)) and not isinstance(v, bool)
            and math.isfinite(v)):
        raise _bad("invalid_input", "%s must be a finite real, not %r" % (what, v))
    f = float(v)
    return 0.0 if f == 0.0 else f          # fold -0.0 into 0.0


def as_id(v: Any, what: str) -> str:
    if not isinstance(v, str) or not _ID_RE.match(v):
        raise _bad("invalid_input",
                   "%s is not a 1..64 character ID: %r" % (what, v))
    return v


def _bbox_of(v: Any, what: str) -> list:
    if not isinstance(v, (list, tuple)) or len(v) != 4:
        raise _bad("invalid_input", "%s must be [x,y,w,h]" % what)
    x = as_real(v[0], what + "[0]")
    y = as_real(v[1], what + "[1]")
    w = as_real(v[2], what + "[2]")
    h = as_real(v[3], what + "[3]")
    if x < 0.0 or y < 0.0 or w < 1e-6 or h < 1e-6 \
            or x + w > 1.0 + _BBOX_SLACK or y + h > 1.0 + _BBOX_SLACK:
        raise _bad("invalid_input", "%s is not a normalised box: %r" % (what, v))
    return [x, y, w, h]


def _appearance_of(v: Any, what: str) -> Optional[list]:
    if v is None:
        return None
    if not isinstance(v, (list, tuple)) or len(v) != 4:
        raise _bad("invalid_input", "%s must be null or four reals" % what)
    out = [as_real(v[k], "%s[%d]" % (what, k)) for k in range(4)]
    for f in out:
        if f < 0.0 or f > 1.0:
            raise _bad("invalid_input", "%s entries must lie in 0..1" % what)
    if abs(sum(out) - 1.0) > 1e-9:
        raise _bad("invalid_input", "%s must sum to 1" % what)
    return out


def resolve_config(config: Any = None) -> dict:
    """The resolved configuration; unknown keys and out-of-range values fail."""
    if config is None:
        config = {}
    if not isinstance(config, dict):
        raise _bad("invalid_config", "config must be an object")
    out = dict(DEFAULT_CONFIG)
    for key, value in config.items():
        spec = _CONFIG_SPEC.get(key)
        if spec is None:
            raise _bad("invalid_config", "unknown config key %r" % (key,))
        _default, kind, lo, hi, lo_excl = spec
        if kind == "int":
            if not _is_int(value) and not _integral(value):
                raise _bad("invalid_config", "%s must be an integer" % key)
            value = int(value)
        else:
            if not (isinstance(value, (int, float)) and not isinstance(value, bool)
                    and math.isfinite(value)):
                raise _bad("invalid_config", "%s must be a finite real" % key)
            value = float(value)
        if value < lo or value > hi or (lo_excl and value == lo):
            raise _bad("invalid_config", "%s=%r is outside %s%r..%r"
                       % (key, value, "(" if lo_excl else "[", lo, hi))
        out[key] = value
    if out["max_pending"] < out["max_tracks"]:
        raise _bad("invalid_config", "max_pending must be >= max_tracks")
    return out


# ----------------------------------------------------------------------------------
# Min-cost maximum-cardinality bipartite matching, by successive shortest paths.
# ----------------------------------------------------------------------------------
def _min_cost_matching(nt: int, nd: int, edges: list,
                       ban: Optional[tuple] = None) -> tuple:
    """(flow, cost, matched) for the cheapest MAXIMUM-cardinality matching.

    `edges` is [(track_index, detection_index, integer_cost)]. `ban` drops one
    edge, which is how the ambiguity test asks "is there a DIFFERENT matching of
    the same cardinality within the margin?". Successive shortest augmenting
    paths give maximum cardinality first and minimum cost among those, which is
    exactly the contract's rule -- greedy nearest-neighbour is not equivalent.
    """
    n = nt + nd + 2
    src = nt + nd
    snk = src + 1
    head = [-1] * n
    to: list = []
    cap: list = []
    cst: list = []
    nxt: list = []
    slot_of: dict = {}

    def add(u: int, v: int, c: int, w: int) -> int:
        to.append(v); cap.append(c); cst.append(w); nxt.append(head[u])
        head[u] = len(to) - 1
        to.append(u); cap.append(0); cst.append(-w); nxt.append(head[v])
        head[v] = len(to) - 1
        return len(to) - 2

    for i in range(nt):
        add(src, i, 1, 0)
    for j in range(nd):
        add(nt + j, snk, 1, 0)
    for (ti, di, cost) in edges:
        if ban is not None and ti == ban[0] and di == ban[1]:
            continue
        slot_of[(ti, di)] = add(ti, nt + di, 1, cost)

    flow = 0
    total = 0
    while True:
        dist: list = [None] * n
        prev = [-1] * n
        inq = [False] * n
        dist[src] = 0
        dq = [src]
        inq[src] = True
        while dq:
            u = dq.pop()
            inq[u] = False
            du = dist[u]
            e = head[u]
            while e != -1:
                if cap[e]:
                    v = to[e]
                    nd_ = du + cst[e]
                    dv = dist[v]
                    if dv is None or nd_ < dv:
                        dist[v] = nd_
                        prev[v] = e
                        if not inq[v]:
                            inq[v] = True
                            dq.append(v)
                e = nxt[e]
        if dist[snk] is None:
            break
        v = snk
        while v != src:
            e = prev[v]
            cap[e] -= 1
            cap[e ^ 1] += 1
            v = to[e ^ 1]
        flow += 1
        total += dist[snk]

    matched = [pair for pair, e in slot_of.items() if cap[e] == 0]
    return flow, total, matched


# ----------------------------------------------------------------------------------
# One active track. Slots and no per-batch allocation: this is the stream's hot path.
# ----------------------------------------------------------------------------------
class _Track:
    __slots__ = ("track_id", "first_ms", "last_ms", "obs", "ambiguous_batches",
                 "first_center", "last_center", "prev_center", "prev_ms",
                 "last_box", "last_area", "appearance", "best_box", "best_area",
                 "best_ms", "path_length", "max_gap_ms", "path", "cross")

    def __init__(self, track_id: str, t_ms: int, bbox: list, center: tuple) -> None:
        self.track_id = track_id
        self.first_ms = t_ms
        self.last_ms = t_ms
        self.obs = 1
        self.ambiguous_batches = 0
        self.first_center = center
        self.last_center = center
        self.prev_center = None
        self.prev_ms = None
        self.last_box = bbox
        self.last_area = bbox[2] * bbox[3]
        self.appearance = None
        self.best_box = bbox
        self.best_area = self.last_area
        self.best_ms = t_ms
        self.path_length = 0.0
        self.max_gap_ms = 0
        self.path = [[t_ms, center[0], center[1]]]
        self.cross = []

    def predicted_center(self, t_ms: int, max_speed: float) -> tuple:
        """The last centre advanced by the velocity of the last two observations.

        One observation, or a non-advancing clock, means zero velocity; the
        direction is preserved when the speed cap scales the vector.
        """
        lx, ly = self.last_center
        if self.prev_center is None:
            return (lx, ly)
        dt = (self.last_ms - self.prev_ms) / 1000.0
        if dt <= 0.0:
            return (lx, ly)
        vx = (lx - self.prev_center[0]) / dt
        vy = (ly - self.prev_center[1]) / dt
        speed = math.sqrt(vx * vx + vy * vy)
        if speed > max_speed:
            scale = max_speed / speed
            vx *= scale
            vy *= scale
        step = (t_ms - self.last_ms) / 1000.0
        return (lx + vx * step, ly + vy * step)

    def accept(self, t_ms: int, bbox: list, center: tuple,
               appearance: Optional[list], path_points: int) -> None:
        gap = t_ms - self.last_ms
        if gap > self.max_gap_ms:
            self.max_gap_ms = gap
        self.path_length += math.sqrt((center[0] - self.last_center[0]) ** 2
                                      + (center[1] - self.last_center[1]) ** 2)
        self.prev_center = self.last_center
        self.prev_ms = self.last_ms
        self.last_center = center
        self.last_ms = t_ms
        self.obs += 1
        self.last_box = bbox
        self.last_area = bbox[2] * bbox[3]
        if appearance is not None:
            self.appearance = appearance
        if self.last_area > self.best_area:       # strict: earliest wins a tie
            self.best_area = self.last_area
            self.best_box = bbox
            self.best_ms = t_ms
        self._append_path(t_ms, center, path_points)

    def _cross_at(self, path: list, k: int) -> float:
        a, b, c = path[k - 1], path[k], path[k + 1]
        return abs((b[1] - a[1]) * (c[2] - b[2]) - (b[2] - a[2]) * (c[1] - b[1]))

    def _append_path(self, t_ms: int, center: tuple, path_points: int) -> None:
        """Bound the path with the contract's online cross-product simplifier.

        The cross products are kept incrementally: appending adds exactly one
        interior sample, and dropping one touches only its two neighbours.
        """
        path = self.path
        cross = self.cross
        path.append([t_ms, center[0], center[1]])
        if len(path) >= 3:
            cross.append(self._cross_at(path, len(path) - 2))
        while len(path) > path_points:
            k = 0
            best = cross[0]
            for i in range(1, len(cross)):
                if cross[i] < best:
                    best = cross[i]
                    k = i
            del path[k + 1]
            del cross[k]
            n = len(path)
            if 0 <= k - 1 and k + 1 < n:
                cross[k - 1] = self._cross_at(path, k)
            if k + 2 < n:
                cross[k] = self._cross_at(path, k + 1)


# ----------------------------------------------------------------------------------
# The tracker.
# ----------------------------------------------------------------------------------
class Tracker:
    """One camera/unit temporal tracker. See the module docstring for the model."""

    def __init__(self, camera_id: str, unit_id: str, config: Any = None) -> None:
        self._camera_id = as_id(camera_id, "camera_id")
        self._unit_id = as_id(unit_id, "unit_id")
        self._config = resolve_config(config)
        self._next_index = 1
        self._last_seq: Optional[int] = None
        self._last_t_ms: Optional[int] = None
        self._finished = False
        self._tracks: dict = {}                # id -> _Track, in creation order
        self._outbox: list = []
        self._replay: list = []                # oldest first

    # --- read-only views ------------------------------------------------------
    @property
    def camera_id(self) -> str:
        return self._camera_id

    @property
    def unit_id(self) -> str:
        return self._unit_id

    @property
    def config(self) -> dict:
        return dict(self._config)

    @property
    def finished(self) -> bool:
        return self._finished

    # --- input ----------------------------------------------------------------
    def _parse_batch(self, batch: Any) -> dict:
        """Structural validation and normalisation; no state is read or written."""
        if not isinstance(batch, dict):
            raise _bad("invalid_input", "batch must be an object")
        unknown = [k for k in batch if k not in _BATCH_KEYS]
        if unknown:
            raise _bad("invalid_input", "unknown batch key %r" % (unknown[0],))
        for key in ("camera_id", "unit_id", "seq", "t_ms", "detections"):
            if key not in batch:
                raise _bad("invalid_input", "batch is missing %r" % (key,))
        camera_id = as_id(batch["camera_id"], "batch camera_id")
        unit_id = as_id(batch["unit_id"], "batch unit_id")
        seq = as_int(batch["seq"], "seq", 0, MAX_SEQ)
        t_ms = as_int(batch["t_ms"], "t_ms", 0, MAX_T_MS)
        raw = batch["detections"]
        if not isinstance(raw, (list, tuple)):
            raise _bad("invalid_input", "detections must be a list")
        limit = self._config["max_detections"]
        if len(raw) > limit:
            raise _bad("invalid_input", "%d detections exceeds max_detections=%d"
                       % (len(raw), limit))
        detections = []
        seen = set()
        for item in raw:
            if not isinstance(item, dict):
                raise _bad("invalid_input", "each detection must be an object")
            unknown = [k for k in item if k not in _DETECTION_KEYS]
            if unknown:
                raise _bad("invalid_input",
                           "unknown detection key %r" % (unknown[0],))
            for key in ("id", "bbox"):
                if key not in item:
                    raise _bad("invalid_input", "detection is missing %r" % (key,))
            det_id = as_id(item["id"], "detection id")
            if det_id in seen:
                raise _bad("invalid_input", "duplicate detection id %r" % (det_id,))
            seen.add(det_id)
            detections.append({"id": det_id,
                               "bbox": _bbox_of(item["bbox"], "bbox"),
                               "appearance": _appearance_of(
                                   item.get("appearance"), "appearance")})
        detections.sort(key=lambda d: d["id"])
        reset = batch["reset"] if "reset" in batch else False
        if not isinstance(reset, bool):
            raise _bad("invalid_input", "reset must be a boolean")
        return {"camera_id": camera_id, "unit_id": unit_id, "seq": seq,
                "t_ms": t_ms, "reset": reset, "detections": detections}

    def feed(self, batch: Any) -> dict:
        """Validate, then apply one batch; returns the contract's receipt."""
        norm = self._parse_batch(batch)
        if self._finished:
            raise _bad("finished", "this tracker is sealed by finish()")
        if norm["camera_id"] != self._camera_id or norm["unit_id"] != self._unit_id:
            raise _bad("wrong_scope", "batch scope does not match this tracker")
        seq = norm["seq"]
        if self._last_seq is not None and seq <= self._last_seq:
            for entry in self._replay:
                if entry["seq"] == seq:
                    if entry["batch"] != _batch_identity(norm):
                        raise _bad("replay_conflict",
                                   "seq %d was accepted with different content"
                                   % seq)
                    stored = entry["receipt"]
                    return {"seq": stored["seq"], "replayed": True,
                            "assignments": [dict(a) for a in stored["assignments"]],
                            "closed": list(stored["closed"])}
            raise _bad("stale_replay", "seq %d is outside the replay window" % seq)
        expected = 0 if self._last_seq is None else self._last_seq + 1
        if seq != expected:
            raise _bad("sequence_error",
                       "seq %d is not the expected %d" % (seq, expected))
        if self._last_t_ms is not None and norm["t_ms"] <= self._last_t_ms:
            raise _bad("sequence_error", "t_ms %d does not advance past %d"
                       % (norm["t_ms"], self._last_t_ms))
        return self._apply(norm)

    # --- the operation --------------------------------------------------------
    def _apply(self, norm: dict) -> dict:
        t_ms = norm["t_ms"]
        cfg = self._config
        detections = norm["detections"]

        # 1. Plan closures. Nothing is written yet: a capacity failure below must
        #    leave counters, queued output and the next track ID untouched.
        if norm["reset"]:
            closing = [(tid, "reset") for tid in self._tracks]
        else:
            closing = []
            max_gap = cfg["max_gap_ms"]
            max_span = cfg["max_span_ms"]
            for tid, tr in self._tracks.items():
                if t_ms - tr.last_ms > max_gap:
                    closing.append((tid, "gap"))
                elif t_ms - tr.first_ms > max_span:
                    closing.append((tid, "span"))
        closing_ids = {tid for tid, _ in closing}
        remaining = [tr for tid, tr in self._tracks.items()
                     if tid not in closing_ids]

        # 2. Plan association over the tracks that survive this batch.
        plan = self._associate(remaining, detections, t_ms)
        born = [i for i, (status, _tr, _r) in enumerate(plan) if status == "born"]

        # 3. Capacity: the resulting active count and the outbox must both fit.
        if len(remaining) + len(born) > cfg["max_tracks"]:
            raise _bad("capacity", "%d active tracks exceeds max_tracks=%d"
                       % (len(remaining) + len(born), cfg["max_tracks"]))
        if len(self._outbox) + len(closing) > cfg["max_pending"]:
            raise _bad("capacity", "closing %d episode(s) would exceed max_pending=%d"
                       % (len(closing), cfg["max_pending"]))

        # 4. Commit. Track IDs are allocated in ascending detection-ID order.
        episodes = []
        for tid, reason in closing:
            tr = self._tracks.pop(tid)
            episodes.append((tr.first_ms, tr.track_id, self._episode(tr, reason)))
        episodes.sort(key=lambda e: (e[0], e[1]))
        self._outbox.extend(e[2] for e in episodes)
        closed = [e[1] for e in episodes]

        assignments = []
        for i, (status, tr, reason) in enumerate(plan):
            det = detections[i]
            if status == "matched":
                tr.accept(t_ms, det["bbox"], _center(det["bbox"]),
                          det["appearance"], cfg["path_points"])
                assignments.append({"detection_id": det["id"],
                                    "track_id": tr.track_id,
                                    "status": "matched", "reason": None})
            elif status == "ambiguous":
                assignments.append({"detection_id": det["id"], "track_id": None,
                                    "status": "ambiguous", "reason": reason})
            else:
                track_id = "t%08d" % self._next_index
                self._next_index += 1
                tr = _Track(track_id, t_ms, det["bbox"], _center(det["bbox"]))
                # A birth is a successful unambiguous assignment, so the
                # detection's appearance is the new track's appearance.
                if det["appearance"] is not None:
                    tr.appearance = det["appearance"]
                self._tracks[track_id] = tr
                assignments.append({"detection_id": det["id"],
                                    "track_id": track_id,
                                    "status": "born", "reason": None})

        self._last_seq = norm["seq"]
        self._last_t_ms = t_ms
        receipt = {"seq": norm["seq"], "replayed": False,
                   "assignments": assignments, "closed": closed}
        self._remember(norm, receipt)
        return {"seq": receipt["seq"], "replayed": False,
                "assignments": [dict(a) for a in assignments],
                "closed": list(closed)}

    def _remember(self, norm: dict, receipt: dict) -> None:
        self._replay.append({
            "seq": norm["seq"],
            "batch": _batch_identity(norm),
            "receipt": {"seq": receipt["seq"], "replayed": False,
                        "assignments": [dict(a) for a in receipt["assignments"]],
                        "closed": list(receipt["closed"])}})
        limit = self._config["replay_batches"]
        if len(self._replay) > limit:
            del self._replay[0:len(self._replay) - limit]

    def _associate(self, tracks: list, detections: list, t_ms: int) -> list:
        """One (status, track_or_None, reason) per detection, in detection order."""
        nd = len(detections)
        plan: list = [None] * nd
        if not nd:
            return plan
        centers = [_center(d["bbox"]) for d in detections]
        areas = [d["bbox"][2] * d["bbox"][3] for d in detections]
        cfg = self._config
        nt = len(tracks)

        if nt:
            gate_base = cfg["gate_base"]
            gate_speed = cfg["gate_speed"]
            max_speed = cfg["max_speed"]
            ratio = cfg["max_area_ratio"]
            inv_ratio = 1.0 / ratio
            weight = cfg["appearance_weight"]
            app_gate = cfg["appearance_gate"]
            preds = [tr.predicted_center(t_ms, max_speed) for tr in tracks]
            gates = [gate_base + gate_speed * ((t_ms - tr.last_ms) / 1000.0)
                     for tr in tracks]

            feasible = []                     # [(ti, di, integer cost)]
            for ti in range(nt):
                tr = tracks[ti]
                px, py = preds[ti]
                g = gates[ti]
                lo_area = tr.last_area * inv_ratio
                hi_area = tr.last_area * ratio
                tr_app = tr.appearance
                for di in range(nd):
                    area = areas[di]
                    if area < lo_area or area > hi_area:
                        continue
                    cx, cy = centers[di]
                    dx = px - cx
                    dy = py - cy
                    dist = math.sqrt(dx * dx + dy * dy)
                    if dist > g:
                        continue
                    app_cost = 0.0
                    d_app = detections[di]["appearance"]
                    if tr_app is not None and d_app is not None:
                        app_cost = 0.5 * (abs(tr_app[0] - d_app[0])
                                          + abs(tr_app[1] - d_app[1])
                                          + abs(tr_app[2] - d_app[2])
                                          + abs(tr_app[3] - d_app[3]))
                        if app_cost > app_gate:
                            continue
                    feasible.append((ti, di, math.floor(
                        1000000.0 * (dist / g + weight * app_cost) + 0.5)))

            # Connected components of the feasible bipartite graph.
            parent = list(range(nt + nd))

            def find(a: int) -> int:
                while parent[a] != a:
                    parent[a] = parent[parent[a]]
                    a = parent[a]
                return a

            for (ti, di, _c) in feasible:
                ra, rb = find(ti), find(nt + di)
                if ra != rb:
                    parent[rb] = ra
            components: dict = {}
            for edge in feasible:
                components.setdefault(find(edge[0]), []).append(edge)

            margin = cfg["ambiguity_margin"]
            for edges in components.values():
                local_tracks = sorted({ti for (ti, _di, _c) in edges})
                local_dets = sorted({di for (_ti, di, _c) in edges})
                tmap = {ti: k for k, ti in enumerate(local_tracks)}
                dmap = {di: k for k, di in enumerate(local_dets)}
                local_edges = [(tmap[ti], dmap[di], c) for (ti, di, c) in edges]
                flow, best, matched = _min_cost_matching(
                    len(local_tracks), len(local_dets), local_edges)

                reason = None
                if flow:
                    if self._possible_merge(local_dets, edges, preds,
                                            [d["bbox"] for d in detections]):
                        reason = "merge"
                    elif len(local_edges) > flow and self._alternative(
                            len(local_tracks), len(local_dets), local_edges,
                            matched, best, margin):
                        reason = "cost_tie"
                if reason is not None:
                    for di in local_dets:
                        plan[di] = ("ambiguous", None, reason)
                    for ti in local_tracks:
                        tracks[ti].ambiguous_batches += 1
                    continue

                by_det = {ldi: lti for (lti, ldi) in matched}
                for k, di in enumerate(local_dets):
                    lti = by_det.get(k)
                    if lti is not None:
                        plan[di] = ("matched", tracks[local_tracks[lti]], None)
        for i in range(nd):
            if plan[i] is None:
                plan[i] = ("born", None, None)
        return plan

    @staticmethod
    def _possible_merge(local_dets: list, edges: list, preds: list,
                        boxes: list) -> bool:
        """One detection box encloses the predicted centres of two feasible tracks."""
        for di in local_dets:
            near = [ti for (ti, dj, _c) in edges if dj == di]
            if len(near) < 2:
                continue
            x, y, w, h = boxes[di]
            x2, y2 = x + w, y + h
            inside = 0
            for ti in near:
                px, py = preds[ti]
                if x <= px <= x2 and y <= py <= y2:
                    inside += 1
            if inside >= 2:
                return True
        return False

    @staticmethod
    def _alternative(nt: int, nd: int, edges: list, matched: list,
                     best: int, margin: int) -> bool:
        """Is another size-K matching within `margin` of the best cost?

        Forbidding each selected edge in turn and re-solving finds every
        candidate: a different matching of the same cardinality must omit at
        least one edge the chosen one uses.
        """
        limit = best + margin
        size = len(matched)
        for ban in matched:
            flow, cost, _m = _min_cost_matching(nt, nd, edges, ban)
            if flow == size and cost <= limit:
                return True
        return False

    # --- episodes -------------------------------------------------------------
    def _episode(self, tr: _Track, reason: str) -> dict:
        first = tr.first_center
        last = tr.last_center
        elapsed = (tr.last_ms - tr.first_ms) / 1000.0
        return {
            "camera_id": self._camera_id,
            "unit_id": self._unit_id,
            "track_id": tr.track_id,
            "start_ms": tr.first_ms,
            "end_ms": tr.last_ms,
            "observations": tr.obs,
            "ambiguous_batches": tr.ambiguous_batches,
            "reason": reason,
            "bbox": list(tr.best_box),
            "bbox_at_ms": tr.best_ms,
            "first_center": [first[0], first[1]],
            "last_center": [last[0], last[1]],
            "path_length": tr.path_length,
            "net_displacement": math.sqrt((last[0] - first[0]) ** 2
                                          + (last[1] - first[1]) ** 2),
            "mean_speed": (tr.path_length / elapsed) if elapsed > 0 else None,
            "max_observation_gap_ms": tr.max_gap_ms,
            "path": [list(p) for p in tr.path],
        }

    # --- output ---------------------------------------------------------------
    def drain(self) -> list:
        out = [_copy_episode(e) for e in self._outbox]
        self._outbox = []
        return out

    def finish(self) -> list:
        if self._finished:
            return []
        closing = [(tid, "finish") for tid in self._tracks]
        if len(self._outbox) + len(closing) > self._config["max_pending"]:
            raise _bad("capacity", "closing %d episode(s) would exceed max_pending=%d"
                       % (len(closing), self._config["max_pending"]))
        episodes = []
        for tid, reason in closing:
            tr = self._tracks.pop(tid)
            episodes.append((tr.first_ms, tr.track_id, self._episode(tr, reason)))
        episodes.sort(key=lambda e: (e[0], e[1]))
        self._outbox.extend(e[2] for e in episodes)
        self._finished = True
        return [e[1] for e in episodes]

    # --- checkpoints ----------------------------------------------------------
    def _state(self) -> dict:
        tracks = []
        for tr in self._tracks.values():
            tracks.append({
                "id": tr.track_id,
                "first_ms": tr.first_ms,
                "last_ms": tr.last_ms,
                "obs": tr.obs,
                "ambiguous_batches": tr.ambiguous_batches,
                "first_center": [tr.first_center[0], tr.first_center[1]],
                "last_center": [tr.last_center[0], tr.last_center[1]],
                "prev_center": (None if tr.prev_center is None
                                else [tr.prev_center[0], tr.prev_center[1]]),
                "prev_ms": tr.prev_ms,
                "last_box": list(tr.last_box),
                "appearance": (None if tr.appearance is None
                               else list(tr.appearance)),
                "best_box": list(tr.best_box),
                "best_ms": tr.best_ms,
                "path_length": tr.path_length,
                "max_gap_ms": tr.max_gap_ms,
                "path": [list(p) for p in tr.path]})
        return {
            "camera_id": self._camera_id,
            "unit_id": self._unit_id,
            "config": dict(self._config),
            "next_index": self._next_index,
            "last_seq": self._last_seq,
            "last_t_ms": self._last_t_ms,
            "finished": self._finished,
            "tracks": tracks,
            "outbox": [_copy_episode(e) for e in self._outbox],
            "replay": [{"seq": e["seq"],
                        "batch": _copy_identity(e["batch"]),
                        "receipt": {"seq": e["receipt"]["seq"],
                                    "replayed": False,
                                    "assignments": [dict(a) for a
                                                    in e["receipt"]["assignments"]],
                                    "closed": list(e["receipt"]["closed"])}}
                       for e in self._replay]}

    def snapshot(self) -> dict:
        state = self._state()
        return {"schema": SCHEMA, "state": state, "sha256": _digest(state)}

    @classmethod
    def restore(cls, checkpoint: Any) -> "Tracker":
        state = validate_snapshot(checkpoint)
        obj = cls.__new__(cls)
        obj._camera_id = state["camera_id"]
        obj._unit_id = state["unit_id"]
        obj._config = state["config"]
        obj._next_index = state["next_index"]
        obj._last_seq = state["last_seq"]
        obj._last_t_ms = state["last_t_ms"]
        obj._finished = state["finished"]
        obj._tracks = {}
        for t in state["tracks"]:
            tr = _Track(t["id"], t["first_ms"], t["last_box"], t["first_center"])
            tr.last_ms = t["last_ms"]
            tr.obs = t["obs"]
            tr.ambiguous_batches = t["ambiguous_batches"]
            tr.last_center = t["last_center"]
            tr.prev_center = t["prev_center"]
            tr.prev_ms = t["prev_ms"]
            tr.last_area = t["last_box"][2] * t["last_box"][3]
            tr.appearance = t["appearance"]
            tr.best_box = t["best_box"]
            tr.best_area = t["best_box"][2] * t["best_box"][3]
            tr.best_ms = t["best_ms"]
            tr.path_length = t["path_length"]
            tr.max_gap_ms = t["max_gap_ms"]
            tr.path = t["path"]
            tr.cross = _crosses(tr.path)
            obj._tracks[tr.track_id] = tr
        obj._outbox = state["outbox"]
        obj._replay = state["replay"]
        return obj


def _center(bbox: list) -> tuple:
    return (bbox[0] + bbox[2] * 0.5, bbox[1] + bbox[3] * 0.5)


def _copy_episode(ep: dict) -> dict:
    """A deep copy: a caller mutating returned evidence must not reach the state."""
    return {"camera_id": ep["camera_id"], "unit_id": ep["unit_id"],
            "track_id": ep["track_id"], "start_ms": ep["start_ms"],
            "end_ms": ep["end_ms"], "observations": ep["observations"],
            "ambiguous_batches": ep["ambiguous_batches"], "reason": ep["reason"],
            "bbox": list(ep["bbox"]), "bbox_at_ms": ep["bbox_at_ms"],
            "first_center": list(ep["first_center"]),
            "last_center": list(ep["last_center"]),
            "path_length": ep["path_length"],
            "net_displacement": ep["net_displacement"],
            "mean_speed": ep["mean_speed"],
            "max_observation_gap_ms": ep["max_observation_gap_ms"],
            "path": [list(p) for p in ep["path"]]}


def _crosses(path: list) -> list:
    out = []
    for k in range(1, len(path) - 1):
        a, b, c = path[k - 1], path[k], path[k + 1]
        out.append(abs((b[1] - a[1]) * (c[2] - b[2])
                       - (b[2] - a[2]) * (c[1] - b[1])))
    return out


def _batch_identity(norm: dict) -> dict:
    """The normalized content a replay compares: copies, never shared lists."""
    dets = []
    for d in norm["detections"]:
        app = d["appearance"]
        dets.append({"id": d["id"], "bbox": list(d["bbox"]),
                     "appearance": None if app is None else list(app)})
    return {"camera_id": norm["camera_id"], "unit_id": norm["unit_id"],
            "seq": norm["seq"], "t_ms": norm["t_ms"], "reset": norm["reset"],
            "detections": dets}


def _copy_identity(batch: dict) -> dict:
    return {"camera_id": batch["camera_id"], "unit_id": batch["unit_id"],
            "seq": batch["seq"], "t_ms": batch["t_ms"], "reset": batch["reset"],
            "detections": [{"id": d["id"], "bbox": list(d["bbox"]),
                            "appearance": (None if d["appearance"] is None
                                           else list(d["appearance"]))}
                           for d in batch["detections"]]}


def _digest(state: dict) -> str:
    blob = json.dumps(state, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True, allow_nan=False)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


# ----------------------------------------------------------------------------------
# Snapshot validation. `state` is implementation-defined; the rules below are not
# optional, because a checksum recomputed over an invalid state is still invalid.
# ----------------------------------------------------------------------------------
def _snap_bad(why: str) -> TrackingError:
    return _bad("invalid_snapshot", why)


def _snap_clock(v: Any, what: str) -> int:
    if not _is_int(v) or v < 0 or v > MAX_T_MS:
        raise _snap_bad("%s is not a millisecond clock value" % what)
    return v


def _snap_count(v: Any, what: str) -> int:
    if not _is_int(v) or v < 0 or v > (1 << 62):
        raise _snap_bad("%s is not a non-negative count" % what)
    return v


def _snap_real(v: Any, what: str, lo: Optional[float] = None) -> float:
    if not (isinstance(v, (int, float)) and not isinstance(v, bool)
            and math.isfinite(v)):
        raise _snap_bad("%s is not a finite real" % what)
    f = float(v)
    if lo is not None and f < lo:
        raise _snap_bad("%s is below %r" % (what, lo))
    return f


def _snap_id(v: Any, what: str) -> str:
    if not isinstance(v, str) or not _ID_RE.match(v):
        raise _snap_bad("%s is not a contract ID" % what)
    return v


def _snap_bbox(v: Any, what: str) -> list:
    if not isinstance(v, list) or len(v) != 4:
        raise _snap_bad("%s is not a four-element box" % what)
    x = _snap_real(v[0], what + "[0]")
    y = _snap_real(v[1], what + "[1]")
    w = _snap_real(v[2], what + "[2]")
    h = _snap_real(v[3], what + "[3]")
    if x < 0.0 or y < 0.0 or w < 1e-6 or h < 1e-6 \
            or x + w > 1.0 + _BBOX_SLACK or y + h > 1.0 + _BBOX_SLACK:
        raise _snap_bad("%s is not a normalised box" % what)
    return [x, y, w, h]


def _snap_center(v: Any, what: str) -> list:
    if not isinstance(v, list) or len(v) != 2:
        raise _snap_bad("%s is not a two-element centre" % what)
    return [_snap_real(v[0], what + "[0]"), _snap_real(v[1], what + "[1]")]


def _snap_appearance(v: Any, what: str) -> Optional[list]:
    if v is None:
        return None
    if not isinstance(v, list) or len(v) != 4:
        raise _snap_bad("%s is not null or four reals" % what)
    out = [_snap_real(v[k], "%s[%d]" % (what, k)) for k in range(4)]
    for f in out:
        if f < 0.0 or f > 1.0:
            raise _snap_bad("%s entries leave 0..1" % what)
    if abs(sum(out) - 1.0) > 1e-9:
        raise _snap_bad("%s does not sum to 1" % what)
    return out


def _snap_path(v: Any, what: str, limit: int) -> list:
    if not isinstance(v, list) or not v or len(v) > limit:
        raise _snap_bad("%s must be 1..%d samples" % (what, limit))
    out = []
    last_t = None
    for k, item in enumerate(v):
        if not isinstance(item, list) or len(item) != 3:
            raise _snap_bad("%s[%d] is not [t_ms,cx,cy]" % (what, k))
        t = _snap_clock(item[0], "%s[%d][0]" % (what, k))
        if last_t is not None and t <= last_t:
            raise _snap_bad("%s timestamps must increase" % what)
        last_t = t
        out.append([t, _snap_real(item[1], "%s[%d][1]" % (what, k)),
                    _snap_real(item[2], "%s[%d][2]" % (what, k))])
    return out


def _snap_episode(v: Any, what: str) -> dict:
    if not isinstance(v, dict) or set(v) != _EPISODE_KEYS:
        raise _snap_bad("%s does not carry exactly the episode keys" % what)
    start = _snap_clock(v["start_ms"], what + ".start_ms")
    end = _snap_clock(v["end_ms"], what + ".end_ms")
    if end < start:
        raise _snap_bad("%s ends before it starts" % what)
    obs = _snap_count(v["observations"], what + ".observations")
    if obs < 1:
        raise _snap_bad("%s has no observations" % what)
    _snap_count(v["ambiguous_batches"], what + ".ambiguous_batches")
    if v["reason"] not in _REASONS:
        raise _snap_bad("%s has an unknown reason" % what)
    bbox = _snap_bbox(v["bbox"], what + ".bbox")
    bbox_at = _snap_clock(v["bbox_at_ms"], what + ".bbox_at_ms")
    if not start <= bbox_at <= end:
        raise _snap_bad("%s bbox_at_ms is outside the episode" % what)
    first = _snap_center(v["first_center"], what + ".first_center")
    last = _snap_center(v["last_center"], what + ".last_center")
    path_length = _snap_real(v["path_length"], what + ".path_length", 0.0)
    net = _snap_real(v["net_displacement"], what + ".net_displacement", 0.0)
    speed = v["mean_speed"]
    if speed is None:
        if end != start:
            raise _snap_bad("%s has a duration but no mean speed" % what)
    else:
        speed = _snap_real(speed, what + ".mean_speed", 0.0)
        if end == start:
            raise _snap_bad("%s has a mean speed over zero duration" % what)
    gap = _snap_count(v["max_observation_gap_ms"], what + ".max_observation_gap_ms")
    if gap > MAX_T_MS:
        raise _snap_bad("%s has an impossible gap" % what)
    if obs == 1 and gap != 0:
        raise _snap_bad("%s has a gap over a single observation" % what)
    path = _snap_path(v["path"], what + ".path", 128)
    if path[0][0] != start or path[-1][0] != end:
        raise _snap_bad("%s path does not span the episode" % what)
    if obs < len(path):
        raise _snap_bad("%s path is longer than its observations" % what)
    if (path[0][1], path[0][2]) != (first[0], first[1]):
        raise _snap_bad("%s first centre disagrees with its path" % what)
    if (path[-1][1], path[-1][2]) != (last[0], last[1]):
        raise _snap_bad("%s last centre disagrees with its path" % what)
    if path_length + 1e-9 < net:
        raise _snap_bad("%s path length is shorter than its displacement" % what)
    return {"camera_id": v["camera_id"], "unit_id": v["unit_id"],
            "track_id": v["track_id"], "start_ms": start, "end_ms": end,
            "observations": obs, "ambiguous_batches": v["ambiguous_batches"],
            "reason": v["reason"], "bbox": bbox, "bbox_at_ms": bbox_at,
            "first_center": first, "last_center": last,
            "path_length": path_length, "net_displacement": net,
            "mean_speed": speed, "max_observation_gap_ms": gap, "path": path}


def _snap_track(v: Any, what: str, path_points: int, clock: int) -> dict:
    if not isinstance(v, dict) or set(v) != _TRACK_KEYS:
        raise _snap_bad("%s does not carry this tracker's track fields" % what)
    track_id = _snap_id(v["id"], what + ".id")
    first = _snap_clock(v["first_ms"], what + ".first_ms")
    last = _snap_clock(v["last_ms"], what + ".last_ms")
    if last < first or last > clock:
        raise _snap_bad("%s has impossible observation times" % what)
    obs = _snap_count(v["obs"], what + ".obs")
    if obs < 1:
        raise _snap_bad("%s counts no observations" % what)
    _snap_count(v["ambiguous_batches"], what + ".ambiguous_batches")
    first_center = _snap_center(v["first_center"], what + ".first_center")
    last_center = _snap_center(v["last_center"], what + ".last_center")
    prev_center = v["prev_center"]
    prev_ms = v["prev_ms"]
    if prev_center is None:
        if prev_ms is not None or obs != 1:
            raise _snap_bad("%s has no previous observation but counts %d"
                            % (what, obs))
    else:
        prev_center = _snap_center(prev_center, what + ".prev_center")
        prev_ms = _snap_clock(prev_ms, what + ".prev_ms")
        if not first <= prev_ms < last:
            raise _snap_bad("%s has a previous time outside its span" % what)
    last_box = _snap_bbox(v["last_box"], what + ".last_box")
    appearance = _snap_appearance(v["appearance"], what + ".appearance")
    best_box = _snap_bbox(v["best_box"], what + ".best_box")
    best_ms = _snap_clock(v["best_ms"], what + ".best_ms")
    if not first <= best_ms <= last:
        raise _snap_bad("%s largest box is outside its span" % what)
    if best_box[2] * best_box[3] + 1e-12 < last_box[2] * last_box[3]:
        raise _snap_bad("%s largest box is smaller than its last box" % what)
    path_length = _snap_real(v["path_length"], what + ".path_length", 0.0)
    max_gap = _snap_count(v["max_gap_ms"], what + ".max_gap_ms")
    if max_gap > MAX_T_MS:
        raise _snap_bad("%s has an impossible gap" % what)
    if obs == 1 and max_gap != 0:
        raise _snap_bad("%s has a gap over a single observation" % what)
    path = _snap_path(v["path"], what + ".path", path_points)
    if path[0][0] != first or path[-1][0] != last:
        raise _snap_bad("%s path does not span its observations" % what)
    if obs < len(path):
        raise _snap_bad("%s path is longer than its observations" % what)
    if (path[0][1], path[0][2]) != (first_center[0], first_center[1]):
        raise _snap_bad("%s first centre disagrees with its path" % what)
    if (path[-1][1], path[-1][2]) != (last_center[0], last_center[1]):
        raise _snap_bad("%s last centre disagrees with its path" % what)
    if path_length + 1e-9 < math.dist(first_center, last_center):
        raise _snap_bad("%s path length is shorter than its displacement" % what)
    return {"id": track_id, "first_ms": first, "last_ms": last, "obs": obs,
            "ambiguous_batches": v["ambiguous_batches"],
            "first_center": first_center, "last_center": last_center,
            "prev_center": prev_center, "prev_ms": prev_ms,
            "last_box": last_box, "appearance": appearance, "best_box": best_box,
            "best_ms": best_ms, "path_length": path_length, "max_gap_ms": max_gap,
            "path": path}


def _snap_receipt(v: Any, what: str, seq: int) -> dict:
    if not isinstance(v, dict) or set(v) != {"seq", "replayed", "assignments",
                                             "closed"}:
        raise _snap_bad("%s is not a receipt" % what)
    if v["seq"] != seq or v["replayed"] is not False:
        raise _snap_bad("%s does not describe its own seq" % what)
    if not isinstance(v["assignments"], list):
        raise _snap_bad("%s assignments is not a list" % what)
    out = []
    for k, a in enumerate(v["assignments"]):
        if not isinstance(a, dict) or set(a) != {"detection_id", "track_id",
                                                 "status", "reason"}:
            raise _snap_bad("%s assignment %d is malformed" % (what, k))
        det_id = _snap_id(a["detection_id"], "%s assignment id" % what)
        status = a["status"]
        if status not in ("born", "matched", "ambiguous"):
            raise _snap_bad("%s assignment status is unknown" % what)
        track_id, reason = a["track_id"], a["reason"]
        if status == "ambiguous":
            if track_id is not None or reason not in ("merge", "cost_tie"):
                raise _snap_bad("%s ambiguous assignment is malformed" % what)
        else:
            if track_id is None or reason is not None:
                raise _snap_bad("%s assignment is malformed" % what)
            _snap_id(track_id, "%s assignment track id" % what)
        out.append({"detection_id": det_id, "track_id": track_id,
                    "status": status, "reason": reason})
    ids = [a["detection_id"] for a in out]
    if ids != sorted(ids):
        raise _snap_bad("%s assignments are not sorted" % what)
    if not isinstance(v["closed"], list):
        raise _snap_bad("%s closed is not a list" % what)
    for tid in v["closed"]:
        _snap_id(tid, "%s closed id" % what)
    return {"seq": seq, "replayed": False, "assignments": out,
            "closed": list(v["closed"])}


def _snap_entry(v: Any, what: str, cfg: dict) -> dict:
    if not isinstance(v, dict) or set(v) != {"seq", "batch", "receipt"}:
        raise _snap_bad("%s is not a replay entry" % what)
    seq = _snap_clock(v["seq"], what + ".seq")
    if seq > MAX_SEQ:
        raise _snap_bad("%s seq is out of range" % what)
    batch = v["batch"]
    if not isinstance(batch, dict) or set(batch) != _BATCH_KEYS:
        raise _snap_bad("%s batch is malformed" % what)
    if batch["seq"] != seq:
        raise _snap_bad("%s batch seq disagrees with its key" % what)
    camera_id = _snap_id(batch["camera_id"], what + ".camera_id")
    unit_id = _snap_id(batch["unit_id"], what + ".unit_id")
    t_ms = _snap_clock(batch["t_ms"], what + ".t_ms")
    if not isinstance(batch["reset"], bool):
        raise _snap_bad("%s reset is not a boolean" % what)
    dets = batch["detections"]
    if not isinstance(dets, list) or len(dets) > cfg["max_detections"]:
        raise _snap_bad("%s detections are malformed" % what)
    out_dets = []
    seen = set()
    for k, d in enumerate(dets):
        if not isinstance(d, dict) or set(d) != _DETECTION_KEYS:
            raise _snap_bad("%s detection %d is malformed" % (what, k))
        det_id = _snap_id(d["id"], "%s detection id" % what)
        if det_id in seen:
            raise _snap_bad("%s repeats a detection id" % what)
        seen.add(det_id)
        out_dets.append({"id": det_id,
                         "bbox": _snap_bbox(d["bbox"], what + " bbox"),
                         "appearance": _snap_appearance(d["appearance"],
                                                        what + " appearance")})
    if [d["id"] for d in out_dets] != sorted(d["id"] for d in out_dets):
        raise _snap_bad("%s detections are not normalised in ID order" % what)
    return {"seq": seq,
            "batch": {"camera_id": camera_id, "unit_id": unit_id, "seq": seq,
                      "t_ms": t_ms, "reset": batch["reset"],
                      "detections": out_dets},
            "receipt": _snap_receipt(v["receipt"], what + " receipt", seq)}


def validate_snapshot(checkpoint: Any) -> dict:
    """Validate an envelope and return a clean, independent copy of its state."""
    if not isinstance(checkpoint, dict):
        raise _snap_bad("snapshot must be an object")
    if set(checkpoint) != {"schema", "state", "sha256"}:
        raise _snap_bad("snapshot must carry exactly schema, state and sha256")
    if checkpoint["schema"] != SCHEMA:
        raise _snap_bad("unknown snapshot schema %r" % (checkpoint["schema"],))
    state = checkpoint["state"]
    if not isinstance(state, dict):
        raise _snap_bad("snapshot state must be an object")
    digest = checkpoint["sha256"]
    if not isinstance(digest, str) or not _HEX_RE.match(digest):
        raise _snap_bad("sha256 must be 64 lowercase hex characters")
    try:
        recomputed = _digest(state)
    except (TypeError, ValueError):
        raise _snap_bad("state is not canonically serialisable")
    if recomputed != digest:
        raise _snap_bad("state checksum does not match")

    if set(state) != _STATE_KEYS:
        raise _snap_bad("state does not carry this tracker's fields")
    camera_id = _snap_id(state["camera_id"], "camera_id")
    unit_id = _snap_id(state["unit_id"], "unit_id")
    try:
        cfg = resolve_config(state["config"])
    except TrackingError as e:
        raise _snap_bad("configuration is invalid: %s" % e)
    if state["config"] != cfg:
        raise _snap_bad("configuration is not a resolved configuration")
    next_index = _snap_count(state["next_index"], "next_index")
    if next_index < 1:
        raise _snap_bad("next_index must be at least 1")
    last_seq = state["last_seq"]
    if last_seq is not None:
        last_seq = _snap_clock(last_seq, "last_seq")
        if last_seq > MAX_SEQ:
            raise _snap_bad("last_seq is out of range")
    last_t_ms = state["last_t_ms"]
    if last_t_ms is not None:
        last_t_ms = _snap_clock(last_t_ms, "last_t_ms")
    if (last_seq is None) != (last_t_ms is None):
        raise _snap_bad("the sequence and time high-water marks disagree")
    if not isinstance(state["finished"], bool):
        raise _snap_bad("finished is not a boolean")
    finished = state["finished"]

    tracks = state["tracks"]
    if not isinstance(tracks, list) or len(tracks) > cfg["max_tracks"]:
        raise _snap_bad("tracks is not a bounded list")
    if finished and tracks:
        raise _snap_bad("a finished tracker still holds active tracks")
    clock = MAX_T_MS if last_t_ms is None else last_t_ms
    out_tracks = []
    seen_ids = set()
    for k, t in enumerate(tracks):
        tr = _snap_track(t, "track %d" % k, cfg["path_points"], clock)
        if tr["id"] in seen_ids:
            raise _snap_bad("duplicate track id")
        seen_ids.add(tr["id"])
        if int(tr["id"][1:]) >= next_index:
            raise _snap_bad("a track id is not below the next counter")
        out_tracks.append(tr)

    outbox = state["outbox"]
    if not isinstance(outbox, list) or len(outbox) > cfg["max_pending"]:
        raise _snap_bad("outbox is not a bounded list")
    out_eps = []
    for k, e in enumerate(outbox):
        ep = _snap_episode(e, "outbox episode %d" % k)
        if ep["camera_id"] != camera_id or ep["unit_id"] != unit_id:
            raise _snap_bad("a queued episode is from another scope")
        _snap_id(ep["track_id"], "queued episode track id")
        out_eps.append(ep)

    replay = state["replay"]
    if not isinstance(replay, list) or len(replay) > cfg["replay_batches"]:
        raise _snap_bad("the replay window is not a bounded list")
    out_replay = []
    prev_seq = None
    for k, entry in enumerate(replay):
        clean = _snap_entry(entry, "replay %d" % k, cfg)
        if clean["batch"]["camera_id"] != camera_id \
                or clean["batch"]["unit_id"] != unit_id:
            raise _snap_bad("a replay entry is from another scope")
        if last_seq is None or clean["seq"] > last_seq:
            raise _snap_bad("a replay entry is beyond the high-water mark")
        if prev_seq is not None and clean["seq"] <= prev_seq:
            raise _snap_bad("replay entries are not in ascending order")
        prev_seq = clean["seq"]
        out_replay.append(clean)
    if out_replay:
        if out_replay[-1]["seq"] != last_seq:
            raise _snap_bad("the newest replay entry is not the high-water mark")
        if out_replay[-1]["batch"]["t_ms"] != last_t_ms:
            raise _snap_bad("the newest replay entry disagrees with the clock")

    return {"camera_id": camera_id, "unit_id": unit_id, "config": cfg,
            "next_index": next_index, "last_seq": last_seq,
            "last_t_ms": last_t_ms, "finished": finished, "tracks": out_tracks,
            "outbox": out_eps, "replay": out_replay}
