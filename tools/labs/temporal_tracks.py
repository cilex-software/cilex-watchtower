"""Deterministic, resumable, streaming temporal tracking for Cilex Watchtower Labs.

This is the engine `docs/benchmarks/labs-tracking/CONTRACT.md` specifies: it
consumes timestamped BATCHES of already-supplied foreground detections for one
camera/unit and produces stable tracks, bounded evidence episodes, receipts, a
bounded replay window and a checkpoint that a fresh process can continue from.

WHAT IT IS NOT. It is not a detector and not a classifier. It never looks at a
pixel, a mask, an image or a model, and it infers no person, vehicle, child,
clothing, dog or cyclist class from a box: a detection is `[x, y, w, h]` in
normalised frame coordinates plus an optional four-number appearance histogram
that the CALLER measured. Association is temporal geometry and that supplied
descriptor, nothing else. `object_profile` and `labs_track_linking` stay on
their own paths; nothing here is registered with `run_worker.py`.

THE FOUR GUARANTEES the contract asks for, and where they live:

  * DETERMINISM. No clock, no random state, no file path, no hash seed and no
    object address reaches a decision or an output. Detections are normalised
    into ascending detection-ID order before anything reads them, so input
    order cannot change a receipt, an ID or an episode. Every float that leaves
    this module is finite and never negative zero.
  * ATOMICITY. `feed()` computes an entire operation -- expiry, association,
    births, closures, capacity -- on scratch values and only then touches live
    state. A rejected operation therefore leaves counters, replay history,
    pending output and the next track ID exactly as they were, which is what
    makes "drain, then retry the identical batch" a correct recovery.
  * BOUNDED STATE. Live memory is a function of the configured limits, not of
    how long the tracker has run: at most `max_tracks` live tracks, each with
    at most `path_points` path samples, at most `max_pending` undrained
    episodes, and at most `replay_batches` retained input identities with their
    receipts. There is no seen-ID set, no stream archive and no completed-track
    archive. Section 13's 100000-batch stream runs in that envelope.
  * EVIDENCE WITHOUT INVENTION. Episode measurements come only from ACCEPTED
    observations. Nothing is interpolated: a coasting track predicts where a
    thing would be in order to associate it, and that prediction never becomes
    a timestamp, a centre, a box, a count or a speed. Where the evidence cannot
    separate two objects -- an indistinguishable crossing, or one box that
    swallows two predicted centres -- the whole component abstains, the tracks
    coast, and the episode says so through `ambiguous_batches`.

Public API: `TrackingError` (a ValueError carrying a stable `code`) and
`Tracker` with `feed`, `drain`, `finish`, `snapshot` and `Tracker.restore`.
All returned data is ordinary JSON-compatible dicts, lists and scalars that
never alias tracker state, so a caller may mutate what it gets back.

Optimal association itself lives in the private helper
`temporal_tracks_matching.py`; this module owns validation, state, evidence and
checkpoints. Offline adaptation from existing `MaskFrame` batches, and the Labs
wire preview, live in `temporal_tracks_adapter.py`; the JSONL command line lives
in `replay_temporal_tracks.py`.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
from typing import Any, Mapping, NamedTuple, Sequence

from temporal_tracks_matching import components, forced_pairs, solve_component

__all__ = [
    "TrackingError", "Tracker", "SCHEMA", "STATE_VERSION", "CONFIG_SPEC",
    "DEFAULT_CONFIG", "EPISODE_KEYS", "CLOSE_REASONS", "STATUSES",
    "AMBIGUITY_REASONS", "ID_PATTERN", "SEQ_MAX", "T_MS_MAX",
    "resolve_config", "parse_batch", "validate_episode", "canonical_state_json",
    # The validation primitives the offline adapter shares, so one set of rules
    # decides a measurement whether it arrives as a batch or as a MaskFrame.
    "check_int", "check_real", "check_id", "check_bool", "check_mapping",
    "check_sequence", "check_keys", "check_bbox", "check_appearance",
]

#: Envelope schema of `snapshot()` (CONTRACT.md section 9).
SCHEMA = "labs-temporal-tracker/v1"
#: Version of the implementation-defined `state` object inside that envelope.
STATE_VERSION = 1

#: IDs (camera, unit, detection, track) are 1-64 of these characters.
ID_PATTERN = r"[A-Za-z0-9_.:-]{1,64}"
_ID_RE = re.compile(ID_PATTERN)
#: A track ID is `t` plus a counter padded to at least eight decimal digits.
_TRACK_ID_RE = re.compile(r"t[0-9]{8,}")

SEQ_MAX = 2147483647
T_MS_MAX = 9007199254740991
BOX_MIN_SIDE = 1e-6
APPEARANCE_SUM_TOL = 1e-9

#: CONTRACT.md section 3: key -> (default, kind, low, high, low_exclusive,
#: high_exclusive). Every bound is inclusive except one written with `>`.
CONFIG_SPEC: dict[str, tuple[Any, str, float, float, bool, bool]] = {
    "gate_base":         (0.15,   "real", 0.0, 1.0,      True,  False),
    "gate_speed":        (0.10,   "real", 0.0, 2.0,      False, False),
    "max_speed":         (1.0,    "real", 0.0, 10.0,     True,  False),
    "max_gap_ms":        (2000,   "int",  1,   10000,    False, False),
    "max_span_ms":       (299000, "int",  1,   299000,   False, False),
    "max_area_ratio":    (4.0,    "real", 1.0, 100.0,    False, False),
    "appearance_weight": (0.25,   "real", 0.0, 2.0,      False, False),
    "appearance_gate":   (0.50,   "real", 0.0, 1.0,      False, False),
    "ambiguity_margin":  (1000,   "int",  0,   1000000,  False, False),
    "max_tracks":        (64,     "int",  1,   128,      False, False),
    "max_detections":    (64,     "int",  1,   128,      False, False),
    "max_pending":       (256,    "int",  1,   1024,     False, False),
    "replay_batches":    (32,     "int",  1,   128,      False, False),
    "path_points":       (32,     "int",  2,   128,      False, False),
}
DEFAULT_CONFIG: dict[str, Any] = {k: v[0] for k, v in CONFIG_SPEC.items()}

#: The exact key set of a closed episode (CONTRACT.md section 8).
EPISODE_KEYS = (
    "camera_id", "unit_id", "track_id", "start_ms", "end_ms", "observations",
    "ambiguous_batches", "reason", "bbox", "bbox_at_ms", "first_center",
    "last_center", "path_length", "net_displacement", "mean_speed",
    "max_observation_gap_ms", "path",
)
CLOSE_REASONS = ("gap", "span", "reset", "finish")
STATUSES = ("born", "matched", "ambiguous")
AMBIGUITY_REASONS = ("merge", "cost_tie")


class TrackingError(ValueError):
    """An expected validation or state failure, carrying a stable `code`.

    The codes are the contract's: `invalid_input`, `invalid_config`,
    `wrong_scope`, `sequence_error`, `replay_conflict`, `stale_replay`,
    `capacity`, `finished`, `invalid_snapshot`. Human wording is free; the code
    is what a caller may branch on. It subclasses ValueError so existing Labs
    callers that catch ValueError around an analyser keep working.
    """

    def __init__(self, code: str, message: str | None = None):
        super().__init__(message or code)
        self.code = code


# ---------------------------------------------------------------------------
# scalar validation: strict, because a silently repaired measurement is a
# measurement nobody can trust
# ---------------------------------------------------------------------------
def _nz(v: float) -> float:
    """A float that is never negative zero, so equal values serialise equally."""
    return 0.0 if v == 0.0 else v


def _numeric(v: Any) -> bool:
    """True for a finite int/float. Booleans are not numbers here (section 2)."""
    return (not isinstance(v, bool) and isinstance(v, (int, float))
            and math.isfinite(float(v)))


def check_real(v: Any, what: str, code: str = "invalid_input") -> float:
    """A finite real number as a float, never negative zero."""
    if not _numeric(v):
        raise TrackingError(code, f"{what} must be a finite real number, got {v!r}")
    return _nz(float(v))


def check_int(v: Any, what: str, low: int, high: int, code: str = "invalid_input") -> int:
    """An integer inside `[low, high]`. A bool is not an integer; a float, a
    numeric string or a NumPy scalar is not either."""
    if isinstance(v, bool) or not isinstance(v, int):
        raise TrackingError(code, f"{what} must be an integer, got {v!r}")
    if not low <= v <= high:
        raise TrackingError(code, f"{what}={v} is outside {low}..{high}")
    return int(v)


def check_id(v: Any, what: str, code: str = "invalid_input") -> str:
    """A camera, unit, detection or track identifier."""
    if not isinstance(v, str) or _ID_RE.fullmatch(v) is None:
        raise TrackingError(code, f"{what} must match {ID_PATTERN}, got {v!r}")
    return v


def check_bool(v: Any, what: str, code: str = "invalid_input") -> bool:
    """A real boolean: 0 and 1 are numbers, not flags."""
    if not isinstance(v, bool):
        raise TrackingError(code, f"{what} must be a boolean, got {v!r}")
    return v


def check_mapping(v: Any, what: str, code: str = "invalid_input") -> Mapping:
    if not isinstance(v, Mapping):
        raise TrackingError(code, f"{what} must be an object, got {type(v).__name__}")
    return v


def check_sequence(v: Any, what: str, code: str = "invalid_input") -> Sequence:
    """A JSON list (a tuple is accepted from a Python caller; a string is not a
    sequence of measurements)."""
    if not isinstance(v, (list, tuple)):
        raise TrackingError(code, f"{what} must be a list, got {type(v).__name__}")
    return v


def check_keys(obj: Mapping, required: tuple[str, ...], optional: tuple[str, ...],
               what: str, code: str = "invalid_input") -> None:
    """Reject unknown keys as well as missing ones: a typo must not be ignored."""
    for key in obj:
        if not isinstance(key, str) or (key not in required and key not in optional):
            raise TrackingError(code, f"{what} has an unknown key {key!r}")
    for key in required:
        if key not in obj:
            raise TrackingError(code, f"{what} is missing {key!r}")


def resolve_config(raw: Any = None, code: str = "invalid_config") -> dict[str, Any]:
    """The resolved configuration: defaults filled in, every value type-checked.

    `code` is what a violation raises, so restoring a snapshot can report
    `invalid_snapshot` for the same rules that make a bad constructor argument
    `invalid_config`.
    """
    if raw is None:
        raw = {}
    raw = check_mapping(raw, "config", code)
    for key in raw:
        if key not in CONFIG_SPEC:
            raise TrackingError(code,
                                f"unknown configuration key {key!r}; the contract's keys are "
                                f"{', '.join(sorted(CONFIG_SPEC))}")
    out: dict[str, Any] = {}
    for key, (default, kind, low, high, low_open, high_open) in CONFIG_SPEC.items():
        if key not in raw:
            out[key] = float(default) if kind == "real" else int(default)
            continue
        v = raw[key]
        if kind == "int":
            val: Any = check_int(v, key, -(2 ** 63), 2 ** 63, code)
        else:
            val = check_real(v, key, code)
        if (val <= low) if low_open else (val < low):
            raise TrackingError(code, f"{key}={val!r} is below its minimum {'>' if low_open else ''}{low}")
        if (val >= high) if high_open else (val > high):
            raise TrackingError(code, f"{key}={val!r} is above its maximum {'<' if high_open else ''}{high}")
        out[key] = val
    if out["max_pending"] < out["max_tracks"]:
        raise TrackingError(code,
                            f"max_pending={out['max_pending']} must be >= max_tracks={out['max_tracks']}")
    return out


def check_bbox(v: Any, what: str, code: str = "invalid_input") -> tuple[float, float, float, float]:
    """`[x, y, w, h]` normalised: x,y>=0, w,h>=1e-6, x+w<=1, y+h<=1, all finite."""
    seq = check_sequence(v, what, code)
    if len(seq) != 4:
        raise TrackingError(code, f"{what} needs exactly 4 numbers, got {len(seq)}")
    x, y, w, h = (check_real(c, f"{what}[{i}]", code) for i, c in enumerate(seq))
    if x < 0.0 or y < 0.0:
        raise TrackingError(code, f"{what} origin must be >= 0, got ({x}, {y})")
    if w < BOX_MIN_SIDE or h < BOX_MIN_SIDE:
        raise TrackingError(code, f"{what} sides must be >= {BOX_MIN_SIDE}, got ({w}, {h})")
    if x + w > 1.0 or y + h > 1.0:
        raise TrackingError(code, f"{what} must fit inside the frame, got ({x}, {y}, {w}, {h})")
    return x, y, w, h


def check_appearance(v: Any, what: str, code: str = "invalid_input") -> tuple[float, ...] | None:
    """null, or four reals in 0..1 whose sum differs from 1 by at most 1e-9.

    Never normalised, clipped or repaired: a malformed descriptor is the
    caller's measurement error, and quietly fixing it would let a wrong
    descriptor gate association as though it were a right one.
    """
    if v is None:
        return None
    seq = check_sequence(v, what, code)
    if len(seq) != 4:
        raise TrackingError(code, f"{what} needs exactly 4 numbers, got {len(seq)}")
    vals = tuple(check_real(c, f"{what}[{i}]", code) for i, c in enumerate(seq))
    for c in vals:
        if c < 0.0 or c > 1.0:
            raise TrackingError(code, f"{what} values must lie in 0..1, got {vals}")
    if abs(sum(vals) - 1.0) > APPEARANCE_SUM_TOL:
        raise TrackingError(code, f"{what} must sum to 1 within {APPEARANCE_SUM_TOL}, got {sum(vals)!r}")
    return vals


class _Det(NamedTuple):
    """One validated, normalised detection of one batch."""

    id: str
    x: float
    y: float
    w: float
    h: float
    cx: float
    cy: float
    area: float
    app: tuple[float, float, float, float] | None


class _Batch(NamedTuple):
    """One validated, normalised input batch."""

    camera_id: str
    unit_id: str
    seq: int
    t_ms: int
    reset: bool
    dets: tuple[_Det, ...]
    identity: tuple


def _identity_json(identity: tuple) -> list:
    """The JSON form of a retained input identity (for `snapshot()`)."""
    t_ms, reset, dets = identity
    return [t_ms, reset,
            [[d[0], d[1], d[2], d[3], d[4], (None if d[5] is None else list(d[5]))] for d in dets]]


def _identity_parse(obj: Any, code: str) -> tuple:
    """Validate and rebuild a retained input identity from its JSON form."""
    seq = check_sequence(obj, "replay input", code)
    if len(seq) != 3:
        raise TrackingError(code, "replay input must be [t_ms, reset, detections]")
    t_ms = check_int(seq[0], "replay t_ms", 0, T_MS_MAX, code)
    reset = check_bool(seq[1], "replay reset", code)
    raw = check_sequence(seq[2], "replay detections", code)
    dets = []
    for item in raw:
        row = check_sequence(item, "replay detection", code)
        if len(row) != 6:
            raise TrackingError(code, "replay detection must be [id, x, y, w, h, appearance]")
        did = check_id(row[0], "replay detection id", code)
        nums = tuple(check_real(c, "replay bbox value", code) for c in row[1:5])
        app = None if row[5] is None else check_appearance(row[5], "replay appearance", code)
        dets.append((did, nums[0], nums[1], nums[2], nums[3], app))
    return (t_ms, reset, tuple(dets))


def parse_batch(batch: Any, cfg: Mapping[str, Any]) -> _Batch:
    """Validate and normalise one input batch (CONTRACT.md section 4).

    Detection order is immaterial, so the detections are sorted into ascending
    detection-ID order here and nothing downstream ever looks at input order
    again. Raises `invalid_input`; scope, sequence and replay rules belong to
    `Tracker.feed`, which knows the tracker's history.
    """
    obj = check_mapping(batch, "batch")
    check_keys(obj, ("camera_id", "unit_id", "seq", "t_ms", "detections"), ("reset",), "batch")
    camera_id = check_id(obj["camera_id"], "camera_id")
    unit_id = check_id(obj["unit_id"], "unit_id")
    seq = check_int(obj["seq"], "seq", 0, SEQ_MAX)
    t_ms = check_int(obj["t_ms"], "t_ms", 0, T_MS_MAX)
    reset = check_bool(obj.get("reset", False), "reset")
    raw = check_sequence(obj["detections"], "detections")
    limit = cfg["max_detections"]
    if len(raw) > limit:
        raise TrackingError("invalid_input",
                            f"{len(raw)} detections in one batch; max_detections is {limit}")
    seen: set[str] = set()
    dets: list[_Det] = []
    for i, item in enumerate(raw):
        d = check_mapping(item, f"detections[{i}]")
        check_keys(d, ("id", "bbox"), ("appearance",), f"detections[{i}]")
        did = check_id(d["id"], f"detections[{i}].id")
        if did in seen:
            raise TrackingError("invalid_input", f"duplicate detection id {did!r} in one batch")
        seen.add(did)
        x, y, w, h = check_bbox(d["bbox"], f"detections[{i}].bbox")
        app = check_appearance(d.get("appearance", None), f"detections[{i}].appearance")
        dets.append(_Det(did, x, y, w, h, _nz(x + w / 2.0), _nz(y + h / 2.0), _nz(w * h), app))
    dets.sort(key=lambda d: d.id)
    identity = (t_ms, reset,
                tuple((d.id, d.x, d.y, d.w, d.h, d.app) for d in dets))
    return _Batch(camera_id, unit_id, seq, t_ms, reset, tuple(dets), identity)


# ---------------------------------------------------------------------------
# receipts and episodes
# ---------------------------------------------------------------------------
def _copy_receipt(receipt: Mapping, replayed: bool | None = None) -> dict:
    """An independent copy of a receipt, optionally with a different `replayed`."""
    return {
        "seq": receipt["seq"],
        "replayed": receipt["replayed"] if replayed is None else replayed,
        "assignments": [dict(a) for a in receipt["assignments"]],
        "closed": list(receipt["closed"]),
    }


def _validate_receipt(obj: Any, code: str) -> dict:
    r = check_mapping(obj, "receipt", code)
    check_keys(r, ("seq", "replayed", "assignments", "closed"), (), "receipt", code)
    out = {"seq": check_int(r["seq"], "receipt seq", 0, SEQ_MAX, code),
           "replayed": check_bool(r["replayed"], "receipt replayed", code),
           "assignments": [], "closed": []}
    for i, a in enumerate(check_sequence(r["assignments"], "receipt assignments", code)):
        am = check_mapping(a, f"receipt assignments[{i}]", code)
        check_keys(am, ("detection_id", "track_id", "status", "reason"), (),
                       f"receipt assignments[{i}]", code)
        did = check_id(am["detection_id"], "assignment detection_id", code)
        tid = am["track_id"]
        if tid is not None:
            if not isinstance(tid, str) or _TRACK_ID_RE.fullmatch(tid) is None:
                raise TrackingError(code, f"assignment track_id {tid!r} is not a track ID")
        status = am["status"]
        if status not in STATUSES:
            raise TrackingError(code, f"assignment status {status!r} is not one of {STATUSES}")
        reason = am["reason"]
        if reason is not None and reason not in AMBIGUITY_REASONS:
            raise TrackingError(code, f"assignment reason {reason!r} is not one of {AMBIGUITY_REASONS}")
        if (status == "ambiguous") != (reason is not None):
            raise TrackingError(code, "reason is set exactly for ambiguous assignments")
        if (tid is None) != (status == "ambiguous"):
            raise TrackingError(code, "only an ambiguous assignment has a null track_id")
        out["assignments"].append({"detection_id": did, "track_id": tid,
                                   "status": status, "reason": reason})
    for c in check_sequence(r["closed"], "receipt closed", code):
        if not isinstance(c, str) or _TRACK_ID_RE.fullmatch(c) is None:
            raise TrackingError(code, f"closed track ID {c!r} is not a track ID")
        out["closed"].append(c)
    ids = [a["detection_id"] for a in out["assignments"]]
    if ids != sorted(ids) or len(set(ids)) != len(ids):
        raise TrackingError(code, "receipt assignments must be sorted and unique by detection ID")
    return out


def _copy_episode(ep: Mapping) -> dict:
    out = dict(ep)
    out["bbox"] = list(ep["bbox"])
    out["first_center"] = list(ep["first_center"])
    out["last_center"] = list(ep["last_center"])
    out["path"] = [list(p) for p in ep["path"]]
    return out


def validate_episode(ep: Any, *, path_points: int | None = None, camera_id: str | None = None,
                     unit_id: str | None = None, code: str = "invalid_input") -> dict:
    """Check one closed episode against CONTRACT.md section 8 and return a copy.

    Used when restoring a snapshot (a corrupted episode must not be trusted just
    because the checksum over it was recomputed) and by the adapter's offline
    wire preview, which materialises and validates every episode before it
    returns any row.
    """
    e = check_mapping(ep, "episode", code)
    missing = [k for k in EPISODE_KEYS if k not in e]
    if missing:
        raise TrackingError(code, f"episode is missing {missing}")
    extra = [k for k in e if k not in EPISODE_KEYS]
    if extra:
        raise TrackingError(code, f"episode has unknown keys {extra}")
    out: dict[str, Any] = {}
    for key, want in (("camera_id", camera_id), ("unit_id", unit_id)):
        out[key] = check_id(e[key], f"episode {key}", code)
        if want is not None and out[key] != want:
            raise TrackingError(code, f"episode {key} {out[key]!r} is not this tracker's {want!r}")
    tid = e["track_id"]
    if not isinstance(tid, str) or _TRACK_ID_RE.fullmatch(tid) is None:
        raise TrackingError(code, f"episode track_id {tid!r} is not a track ID")
    out["track_id"] = tid
    start = check_int(e["start_ms"], "episode start_ms", 0, T_MS_MAX, code)
    end = check_int(e["end_ms"], "episode end_ms", 0, T_MS_MAX, code)
    if end < start:
        raise TrackingError(code, f"episode end_ms {end} is before start_ms {start}")
    out["start_ms"], out["end_ms"] = start, end
    obs = check_int(e["observations"], "episode observations", 1, 2 ** 62, code)
    out["observations"] = obs
    out["ambiguous_batches"] = check_int(e["ambiguous_batches"], "episode ambiguous_batches",
                                        0, 2 ** 62, code)
    if e["reason"] not in CLOSE_REASONS:
        raise TrackingError(code, f"episode reason {e['reason']!r} is not one of {CLOSE_REASONS}")
    out["reason"] = e["reason"]
    out["bbox"] = list(check_bbox(e["bbox"], "episode bbox", code))
    at = check_int(e["bbox_at_ms"], "episode bbox_at_ms", 0, T_MS_MAX, code)
    if not start <= at <= end:
        raise TrackingError(code, f"episode bbox_at_ms {at} is outside {start}..{end}")
    out["bbox_at_ms"] = at
    for key in ("first_center", "last_center"):
        c = check_sequence(e[key], f"episode {key}", code)
        if len(c) != 2:
            raise TrackingError(code, f"episode {key} needs 2 numbers")
        out[key] = [check_real(c[0], f"episode {key}[0]", code), check_real(c[1], f"episode {key}[1]", code)]
    pl = check_real(e["path_length"], "episode path_length", code)
    nd = check_real(e["net_displacement"], "episode net_displacement", code)
    if pl < 0.0 or nd < 0.0:
        raise TrackingError(code, "episode distances must be >= 0")
    if nd > pl + 1e-9:
        raise TrackingError(code,
                            f"episode net_displacement {nd!r} exceeds path_length {pl!r}")
    out["path_length"], out["net_displacement"] = pl, nd
    ms = e["mean_speed"]
    if end == start:
        if ms is not None:
            raise TrackingError(code, "a zero-duration episode has no mean_speed")
        out["mean_speed"] = None
    else:
        speed = check_real(ms, "episode mean_speed", code)
        want = pl / ((end - start) / 1000.0)
        if not math.isclose(speed, want, rel_tol=1e-9, abs_tol=1e-9):
            raise TrackingError(code,
                                f"episode mean_speed {speed!r} is not path_length/elapsed ({want!r})")
        out["mean_speed"] = speed
    gap = check_int(e["max_observation_gap_ms"], "episode max_observation_gap_ms", 0, T_MS_MAX, code)
    if gap > end - start:
        raise TrackingError(code, f"episode max_observation_gap_ms {gap} exceeds its span")
    out["max_observation_gap_ms"] = gap
    samples = check_sequence(e["path"], "episode path", code)
    if not 1 <= len(samples) <= obs:
        raise TrackingError(code, f"episode path holds {len(samples)} samples for {obs} observations")
    if path_points is not None and len(samples) > path_points:
        raise TrackingError(code,
                            f"episode path holds {len(samples)} samples; path_points is {path_points}")
    path: list[list] = []
    prev_t = None
    for i, s in enumerate(samples):
        row = check_sequence(s, f"episode path[{i}]", code)
        if len(row) != 3:
            raise TrackingError(code, f"episode path[{i}] must be [t_ms, cx, cy]")
        t = check_int(row[0], f"episode path[{i}] t_ms", 0, T_MS_MAX, code)
        if prev_t is not None and t <= prev_t:
            raise TrackingError(code, f"episode path[{i}] time does not advance")
        prev_t = t
        path.append([t, check_real(row[1], f"episode path[{i}] cx", code),
                     check_real(row[2], f"episode path[{i}] cy", code)])
    if path[0][0] != start or path[-1][0] != end:
        raise TrackingError(code, "an episode path starts and ends at its own observations")
    out["path"] = path
    return out


# ---------------------------------------------------------------------------
# one live track
# ---------------------------------------------------------------------------
class _Track:
    """A live track: the last TWO accepted observations, section 8's evidence
    accumulators, and the bounded path.

    Only accepted observations are recorded here. A batch whose component
    abstained (ambiguous or possible merge) touches nothing but
    `ambiguous_batches`, so a coasting track keeps predicting from real evidence
    and never from a guess it declined to make.
    """

    __slots__ = ("tid", "num", "first_t", "last_t", "observations", "ambiguous_batches",
                 "cx", "cy", "bbox", "area", "prev", "appearance", "first_center",
                 "path", "cross", "path_length", "best_bbox", "best_area", "best_t",
                 "max_gap_ms")

    def __init__(self, tid: str, num: int, det: _Det, t_ms: int):
        self.tid = tid
        self.num = num
        self.first_t = t_ms
        self.last_t = t_ms
        self.observations = 1
        self.ambiguous_batches = 0
        self.cx = det.cx
        self.cy = det.cy
        self.bbox = (det.x, det.y, det.w, det.h)
        self.area = det.area
        #: (cx, cy, t_ms) of the observation before the last one, or None.
        self.prev: tuple[float, float, int] | None = None
        self.appearance = det.app
        self.first_center = (det.cx, det.cy)
        #: Bounded actual-observation samples `[t_ms, cx, cy]`.
        self.path: list[list] = [[t_ms, det.cx, det.cy]]
        #: `cross[k]` is the simplifier weight of `path[k + 1]`, the absolute 2D
        #: cross product of its two adjacent spatial segments. Derived state:
        #: rebuilt on restore, never serialised.
        self.cross: list[float] = []
        self.path_length = 0.0
        self.best_bbox = (det.x, det.y, det.w, det.h)
        self.best_area = det.area
        self.best_t = t_ms
        self.max_gap_ms = 0

    # -- prediction ---------------------------------------------------------
    def predict(self, t_ms: int, max_speed: float) -> tuple[float, float, float]:
        """`(predicted cx, predicted cy, dt seconds)`, constant-velocity.

        Velocity comes from the last TWO accepted observations, is capped at
        `max_speed` without changing direction, and is zero with only one. The
        prediction is NOT clipped to the frame: a thing that left the picture is
        predicted outside it, and the gate decides whether that is associable.
        """
        dt = (t_ms - self.last_t) / 1000.0
        prev = self.prev
        if prev is None:
            vx = vy = 0.0
        else:
            px, py, pt = prev
            step = (self.last_t - pt) / 1000.0
            vx = (self.cx - px) / step
            vy = (self.cy - py) / step
            speed = math.hypot(vx, vy)
            if speed > max_speed:
                k = max_speed / speed
                vx *= k
                vy *= k
        return _nz(self.cx + vx * dt), _nz(self.cy + vy * dt), dt

    # -- evidence -----------------------------------------------------------
    def observe(self, det: _Det, t_ms: int, path_points: int) -> None:
        """Fold one accepted observation into the accumulators and the path."""
        self.prev = (self.cx, self.cy, self.last_t)
        gap = t_ms - self.last_t
        if gap > self.max_gap_ms:
            self.max_gap_ms = gap
        self.path_length = _nz(self.path_length + math.hypot(det.cx - self.cx, det.cy - self.cy))
        self.cx = det.cx
        self.cy = det.cy
        self.bbox = (det.x, det.y, det.w, det.h)
        self.area = det.area
        self.last_t = t_ms
        self.observations += 1
        if det.app is not None:
            self.appearance = det.app
        if det.area > self.best_area:          # strictly greater: the earliest wins a tie
            self.best_area = det.area
            self.best_bbox = (det.x, det.y, det.w, det.h)
            self.best_t = t_ms
        self._append_path(t_ms, det.cx, det.cy, path_points)

    def _weight(self, i: int) -> float:
        a = self.path[i - 1]
        b = self.path[i]
        c = self.path[i + 1]
        return abs((b[1] - a[1]) * (c[2] - b[2]) - (b[2] - a[2]) * (c[1] - b[1]))

    def _append_path(self, t_ms: int, cx: float, cy: float, path_points: int) -> None:
        """Append a sample and re-bound the path, online.

        The contract prescribes this simplifier: drop the interior sample whose
        adjacent spatial segments have the smallest absolute 2D cross product,
        earliest timestamp on an exact tie, never the first or the latest, and
        repeat until the bound holds. It cannot equal a simplification that saw
        the whole future trajectory, and does not claim to.

        `cross` is kept beside `path` so the minimum is two C-level list scans
        (`min` then `index`, which returns the earliest tie) instead of a Python
        loop over every interior sample per observation. Only three weights can
        change per append: the sample that just became interior, and the two
        neighbours of the one removed.
        """
        path = self.path
        path.append([t_ms, cx, cy])
        if len(path) >= 3:
            self.cross.append(self._weight(len(path) - 2))
        if len(path) <= path_points:
            return
        cross = self.cross
        low = min(cross)
        k = cross.index(low)               # earliest interior sample on an exact tie
        del path[k + 1]
        del cross[k]
        if k - 1 >= 0:
            cross[k - 1] = self._weight(k)
        if k < len(cross):
            cross[k] = self._weight(k + 1)

    def rebuild_cross(self) -> None:
        """Recompute the derived simplifier weights (after a restore)."""
        self.cross = [self._weight(i) for i in range(1, len(self.path) - 1)]

    def episode(self, camera_id: str, unit_id: str, reason: str) -> dict:
        """The closed episode. Every number here came from an accepted observation."""
        elapsed_ms = self.last_t - self.first_t
        path_length = self.path_length
        fx, fy = self.first_center
        mean_speed = None if elapsed_ms == 0 else _nz(path_length / (elapsed_ms / 1000.0))
        return {
            "camera_id": camera_id,
            "unit_id": unit_id,
            "track_id": self.tid,
            "start_ms": self.first_t,
            "end_ms": self.last_t,
            "observations": self.observations,
            "ambiguous_batches": self.ambiguous_batches,
            "reason": reason,
            "bbox": list(self.best_bbox),
            "bbox_at_ms": self.best_t,
            "first_center": [fx, fy],
            "last_center": [self.cx, self.cy],
            "path_length": path_length,
            "net_displacement": _nz(math.hypot(self.cx - fx, self.cy - fy)),
            "mean_speed": mean_speed,
            "max_observation_gap_ms": self.max_gap_ms,
            "path": [list(s) for s in self.path],
        }

    # -- checkpoint ---------------------------------------------------------
    def state(self) -> dict:
        prev = self.prev
        return {
            "tid": self.tid,
            "num": self.num,
            "first_t": self.first_t,
            "last_t": self.last_t,
            "observations": self.observations,
            "ambiguous_batches": self.ambiguous_batches,
            "cx": self.cx,
            "cy": self.cy,
            "bbox": list(self.bbox),
            "prev": None if prev is None else [prev[0], prev[1], prev[2]],
            "appearance": None if self.appearance is None else list(self.appearance),
            "first_center": [self.first_center[0], self.first_center[1]],
            "path": [list(s) for s in self.path],
            "path_length": self.path_length,
            "best_bbox": list(self.best_bbox),
            "best_area": self.best_area,
            "best_t": self.best_t,
            "max_gap_ms": self.max_gap_ms,
        }

    @classmethod
    def from_state(cls, st: Any, code: str = "invalid_snapshot") -> "_Track":
        s = check_mapping(st, "track state", code)
        check_keys(s, tuple(k for k in (
            "tid", "num", "first_t", "last_t", "observations", "ambiguous_batches", "cx", "cy",
            "bbox", "prev", "appearance", "first_center", "path", "path_length", "best_bbox",
            "best_area", "best_t", "max_gap_ms")), (), "track state", code)
        tid = s["tid"]
        if not isinstance(tid, str) or _TRACK_ID_RE.fullmatch(tid) is None:
            raise TrackingError(code, f"track ID {tid!r} is not 't' plus >= 8 digits")
        num = check_int(s["num"], "track counter", 1, 2 ** 62, code)
        if tid != f"t{num:08d}":
            raise TrackingError(code, f"track ID {tid!r} does not match its counter {num}")
        tr = cls.__new__(cls)
        tr.tid = tid
        tr.num = num
        tr.first_t = check_int(s["first_t"], "track first_t", 0, T_MS_MAX, code)
        tr.last_t = check_int(s["last_t"], "track last_t", 0, T_MS_MAX, code)
        tr.observations = check_int(s["observations"], "track observations", 1, 2 ** 62, code)
        tr.ambiguous_batches = check_int(s["ambiguous_batches"], "track ambiguous_batches",
                                        0, 2 ** 62, code)
        tr.cx = check_real(s["cx"], "track cx", code)
        tr.cy = check_real(s["cy"], "track cy", code)
        tr.bbox = check_bbox(s["bbox"], "track bbox", code)
        tr.area = _nz(tr.bbox[2] * tr.bbox[3])
        prev = s["prev"]
        if prev is None:
            tr.prev = None
        else:
            row = check_sequence(prev, "track prev", code)
            if len(row) != 3:
                raise TrackingError(code, "track prev must be [cx, cy, t_ms]")
            tr.prev = (check_real(row[0], "track prev cx", code), check_real(row[1], "track prev cy", code),
                       check_int(row[2], "track prev t_ms", 0, T_MS_MAX, code))
        tr.appearance = check_appearance(s["appearance"], "track appearance", code)
        fc = check_sequence(s["first_center"], "track first_center", code)
        if len(fc) != 2:
            raise TrackingError(code, "track first_center needs 2 numbers")
        tr.first_center = (check_real(fc[0], "track first_center[0]", code),
                           check_real(fc[1], "track first_center[1]", code))
        tr.path = []
        for i, sample in enumerate(check_sequence(s["path"], "track path", code)):
            row = check_sequence(sample, f"track path[{i}]", code)
            if len(row) != 3:
                raise TrackingError(code, f"track path[{i}] must be [t_ms, cx, cy]")
            tr.path.append([check_int(row[0], f"track path[{i}] t_ms", 0, T_MS_MAX, code),
                            check_real(row[1], f"track path[{i}] cx", code),
                            check_real(row[2], f"track path[{i}] cy", code)])
        tr.path_length = check_real(s["path_length"], "track path_length", code)
        tr.best_bbox = check_bbox(s["best_bbox"], "track best_bbox", code)
        tr.best_area = check_real(s["best_area"], "track best_area", code)
        tr.best_t = check_int(s["best_t"], "track best_t", 0, T_MS_MAX, code)
        tr.max_gap_ms = check_int(s["max_gap_ms"], "track max_gap_ms", 0, T_MS_MAX, code)
        tr.cross = []
        tr.rebuild_cross()
        return tr

    def check_invariants(self, code: str = "invalid_snapshot") -> None:
        """The relations a real track always satisfies, so a corrupted state that
        happens to carry a recomputed checksum is still refused."""
        if self.first_t > self.last_t:
            raise TrackingError(code, f"{self.tid}: first_t is after last_t")
        if not self.path:
            raise TrackingError(code, f"{self.tid}: an active track has at least one observation")
        if self.path[0][0] != self.first_t or self.path[-1][0] != self.last_t:
            raise TrackingError(code, f"{self.tid}: path ends are not its first/last observation")
        if len(self.path) > self.observations:
            raise TrackingError(code, f"{self.tid}: more path samples than observations")
        for a, b in zip(self.path, self.path[1:]):
            if b[0] <= a[0]:
                raise TrackingError(code, f"{self.tid}: path timestamps do not advance")
        if not math.isclose(self.cx, self.path[-1][1], rel_tol=1e-9, abs_tol=1e-9) or \
                not math.isclose(self.cy, self.path[-1][2], rel_tol=1e-9, abs_tol=1e-9):
            raise TrackingError(code, f"{self.tid}: last centre is not its last path sample")
        if not math.isclose(self.first_center[0], self.path[0][1], rel_tol=1e-9, abs_tol=1e-9) or \
                not math.isclose(self.first_center[1], self.path[0][2], rel_tol=1e-9, abs_tol=1e-9):
            raise TrackingError(code, f"{self.tid}: first centre is not its first path sample")
        if not math.isclose(self.cx, self.bbox[0] + self.bbox[2] / 2.0, rel_tol=1e-9, abs_tol=1e-9) or \
                not math.isclose(self.cy, self.bbox[1] + self.bbox[3] / 2.0, rel_tol=1e-9, abs_tol=1e-9):
            raise TrackingError(code, f"{self.tid}: centre is not the centre of its last box")
        if (self.prev is None) != (self.observations == 1):
            raise TrackingError(code, f"{self.tid}: prev is set exactly from the second observation")
        if self.prev is not None and not self.first_t <= self.prev[2] < self.last_t:
            raise TrackingError(code, f"{self.tid}: prev time is outside its own lifetime")
        if self.path_length < 0.0:
            raise TrackingError(code, f"{self.tid}: negative path_length")
        if not self.first_t <= self.best_t <= self.last_t:
            raise TrackingError(code, f"{self.tid}: best box time is outside its own lifetime")
        if self.best_area <= 0.0 or self.best_area < self.area - 1e-18:
            raise TrackingError(code, f"{self.tid}: best box area is not the largest accepted")
        if not 0 <= self.max_gap_ms <= self.last_t - self.first_t:
            raise TrackingError(code, f"{self.tid}: max_observation_gap_ms outside its lifetime")
        if len(self.cross) != max(0, len(self.path) - 2):
            raise TrackingError(code, f"{self.tid}: derived path weights are stale")


class _Replay(NamedTuple):
    """One retained accepted NEW batch: its normalised identity and receipt."""

    ident: tuple
    receipt: dict


def canonical_state_json(state: Any) -> str:
    """The exact bytes `sha256` is taken over (CONTRACT.md section 9)."""
    return json.dumps(state, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                      allow_nan=False)


# ---------------------------------------------------------------------------
# the tracker
# ---------------------------------------------------------------------------
class Tracker:
    """One camera/unit's temporal tracker: `feed` batches, `drain` episodes.

    The lifecycle is `feed`... `drain`... `finish`, with `snapshot`/
    `Tracker.restore` at any operation boundary. A tracker is single-threaded by
    contract: one caller, one stream, in the caller's time order.
    """

    def __init__(self, camera_id: str, unit_id: str, config: Mapping | None = None):
        self._camera_id = check_id(camera_id, "camera_id")
        self._unit_id = check_id(unit_id, "unit_id")
        self._cfg = resolve_config(config)
        self._tracks: list[_Track] = []
        self._outbox: list[dict] = []
        self._window: dict[int, _Replay] = {}
        self._next_id = 1
        self._last_seq: int | None = None
        self._last_t: int | None = None
        self._finished = False

    # -- read-only views ----------------------------------------------------
    @property
    def camera_id(self) -> str:
        return self._camera_id

    @property
    def unit_id(self) -> str:
        return self._unit_id

    @property
    def config(self) -> dict:
        """A copy of the resolved configuration."""
        return dict(self._cfg)

    @property
    def finished(self) -> bool:
        return self._finished

    # -- output -------------------------------------------------------------
    def drain(self) -> list[dict]:
        """Every pending closed episode, in FIFO order, and empty the outbox.

        The caller owns what comes back: the tracker keeps no reference to it,
        and there is no completed-track archive behind it. Repeated calls return
        `[]`, and a drained episode is never returned again -- which is why a
        replayed receipt describes the ORIGINAL operation's closures instead of
        requeueing them.
        """
        out = self._outbox
        self._outbox = []
        return out

    def finish(self) -> list[str]:
        """Close every active track with reason `finish` and seal the tracker.

        Returns the newly closed IDs, ordered by `(start_ms, track_id)`. Subject
        to the same atomic `max_pending` rule as a feed: if the closures would
        not fit, nothing is closed and the tracker stays open, so the caller can
        drain and retry. A successful repeated finish returns `[]`.
        """
        if self._finished:
            return []
        if self._tracks and len(self._outbox) + len(self._tracks) > self._cfg["max_pending"]:
            raise TrackingError(
                "capacity",
                f"finish would queue {len(self._outbox) + len(self._tracks)} episodes; "
                f"max_pending is {self._cfg['max_pending']} -- drain first")
        episodes = [tr.episode(self._camera_id, self._unit_id, "finish") for tr in self._tracks]
        episodes.sort(key=lambda e: (e["start_ms"], e["track_id"]))
        self._outbox.extend(episodes)
        self._tracks = []
        self._finished = True
        return [e["track_id"] for e in episodes]

    # -- input --------------------------------------------------------------
    def feed(self, batch: Any) -> dict:
        """Accept one batch and return its receipt.

        Raises `finished`, `invalid_input`, `wrong_scope`, `sequence_error`,
        `stale_replay`, `replay_conflict` or `capacity`. Every one of them leaves
        the whole observable state untouched, so the caller can fix its input,
        drain, or restore a checkpoint and continue.
        """
        if self._finished:
            raise TrackingError("finished", "this tracker is sealed: finish() already ran")
        cfg = self._cfg
        nb = parse_batch(batch, cfg)
        if nb.camera_id != self._camera_id or nb.unit_id != self._unit_id:
            raise TrackingError(
                "wrong_scope",
                f"batch is for {nb.camera_id}/{nb.unit_id}, this tracker is "
                f"{self._camera_id}/{self._unit_id}: it never attaches a detection "
                "from another scope")
        # -- replay window, then sequence (section 5) ------------------------
        if self._last_seq is not None and nb.seq <= self._last_seq:
            entry = self._window.get(nb.seq)
            if entry is None:
                raise TrackingError(
                    "stale_replay",
                    f"seq {nb.seq} is at or below the high-water mark {self._last_seq} but "
                    f"outside the {cfg['replay_batches']}-batch replay window")
            if entry.ident != nb.identity:
                raise TrackingError(
                    "replay_conflict",
                    f"seq {nb.seq} was already accepted with different normalised content")
            # The stored receipt describes the ORIGINAL operation, including the
            # IDs it closed then -- not today's queue. Nothing else moves.
            return _copy_receipt(entry.receipt, replayed=True)
        expected = 0 if self._last_seq is None else self._last_seq + 1
        if nb.seq != expected:
            raise TrackingError("sequence_error",
                                f"new batch seq must be {expected}, got {nb.seq}")
        if self._last_t is not None and nb.t_ms <= self._last_t:
            raise TrackingError("sequence_error",
                                f"new batch t_ms must exceed {self._last_t}, got {nb.t_ms}")
        receipt, episodes, keep, next_id = self._operate(nb)
        # -- commit: nothing above this line touched live state --------------
        if episodes:
            self._outbox.extend(episodes)
        self._tracks = keep
        self._next_id = next_id
        self._last_seq = nb.seq
        self._last_t = nb.t_ms
        self._window[nb.seq] = _Replay(nb.identity, _copy_receipt(receipt))
        while len(self._window) > cfg["replay_batches"]:
            del self._window[next(iter(self._window))]
        return receipt

    def _operate(self, nb: _Batch) -> tuple[dict, list[dict], list[_Track], int]:
        """One NEW batch's whole effect: expiry, association, births, closures.

        Returns `(receipt, newly closed episodes, tracks in creation order,
        next track counter)`. Every check -- input, capacity, both of them --
        runs before the first mutation, so raising anywhere above the "apply"
        marker leaves the tracker exactly as it was, counters included.
        """
        cfg = self._cfg
        t_ms = nb.t_ms
        dets = nb.dets
        closures: list[tuple[_Track, str]] = []
        live: list[_Track] = []
        if nb.reset:
            # A declared discontinuity: nothing is linked across it, and the
            # closure ends at each track's last actual observation, not here.
            closures = [(tr, "reset") for tr in self._tracks]
        else:
            gap = cfg["max_gap_ms"]
            span = cfg["max_span_ms"]
            for tr in self._tracks:
                if t_ms - tr.last_t > gap:
                    closures.append((tr, "gap"))
                elif t_ms - tr.first_t > span:
                    closures.append((tr, "span"))
                else:
                    live.append(tr)

        outcomes, abstained = self._associate(live, dets, t_ms)

        # -- both capacities are checked BEFORE anything is mutated ----------
        # A rejected operation must not have expired a track, moved a
        # measurement or advanced seq, so that "drain, then retry the identical
        # batch" is a real recovery and not a second, different operation.
        born = 0
        for kind, _i, _reason in outcomes:
            if kind == "born":
                born += 1
        if len(live) + born > cfg["max_tracks"]:
            raise TrackingError(
                "capacity",
                f"this batch would leave {len(live) + born} active tracks; max_tracks is "
                f"{cfg['max_tracks']} -- nothing was dropped, evicted or half-applied")
        if len(self._outbox) + len(closures) > cfg["max_pending"]:
            raise TrackingError(
                "capacity",
                f"this batch would queue {len(self._outbox) + len(closures)} undrained "
                f"episodes; max_pending is {cfg['max_pending']} -- drain, then retry it")

        # -- apply: nothing below can raise, so the operation is atomic ------
        limit = cfg["path_points"]
        for i in abstained:
            live[i].ambiguous_batches += 1
        assignments: list[dict] = []
        fresh: list[_Track] = []
        next_id = self._next_id
        # `dets` is already in ascending detection-ID order, so this single loop
        # both sorts the receipt and allocates new IDs in that order.
        for j, det in enumerate(dets):
            kind, i, reason = outcomes[j]
            if kind == "matched":
                tr = live[i]
                tr.observe(det, t_ms, limit)
                assignments.append({"detection_id": det.id, "track_id": tr.tid,
                                    "status": "matched", "reason": None})
            elif kind == "ambiguous":
                assignments.append({"detection_id": det.id, "track_id": None,
                                    "status": "ambiguous", "reason": reason})
            else:
                tid = f"t{next_id:08d}"
                fresh.append(_Track(tid, next_id, det, t_ms))
                next_id += 1
                assignments.append({"detection_id": det.id, "track_id": tid,
                                    "status": "born", "reason": None})
        episodes = [tr.episode(self._camera_id, self._unit_id, reason)
                    for tr, reason in closures]
        episodes.sort(key=lambda e: (e["start_ms"], e["track_id"]))
        receipt = {"seq": nb.seq, "replayed": False, "assignments": assignments,
                   "closed": [e["track_id"] for e in episodes]}
        return receipt, episodes, live + fresh, next_id

    def _associate(self, live: list[_Track], dets: tuple[_Det, ...], t_ms: int
                   ) -> tuple[list[tuple[str, int | None, str | None]], list[int]]:
        """Decide every detection's fate in this batch.

        Returns `(outcomes, abstained_tracks)`: per detection, in the batch's
        normalised order, `("matched", track_index, None)`,
        `("ambiguous", None, reason)` or `("born", None, None)`; plus the
        indices of the tracks whose component abstained and so coast.

        Gates are inclusive and are read straight out of the contract: distance
        to the PREDICTED centre against `gate_base + gate_speed*dt`, box-area
        ratio inside `[1/max_area_ratio, max_area_ratio]`, and -- only when both
        sides supplied a descriptor -- half the L1 appearance distance against
        `appearance_gate`. Distance is Euclidean in normalised x/y with no
        aspect correction; the cost is the contract's quantised integer.
        """
        outcomes: list[tuple[str, int | None, str | None]] = [("born", None, None)] * len(dets)
        if not live or not dets:
            return outcomes, []
        cfg = self._cfg
        gate_base = cfg["gate_base"]
        gate_speed = cfg["gate_speed"]
        max_speed = cfg["max_speed"]
        ratio_max = cfg["max_area_ratio"]
        ratio_min = 1.0 / ratio_max
        appearance_weight = cfg["appearance_weight"]
        appearance_gate = cfg["appearance_gate"]

        n_t = len(live)
        n_d = len(dets)
        preds: list[tuple[float, float]] = []
        gates: list[float] = []
        for tr in live:
            px, py, dt = tr.predict(t_ms, max_speed)
            preds.append((px, py))
            gates.append(gate_base + gate_speed * dt)
        det_cx = [d.cx for d in dets]
        det_cy = [d.cy for d in dets]
        det_area = [d.area for d in dets]
        det_app = [d.app for d in dets]

        adj: list[list[tuple[int, int]]] = [[] for _ in range(n_t)]
        radj: list[list[int]] = [[] for _ in range(n_d)]
        n_edges = 0
        for i in range(n_t):
            tr = live[i]
            px, py = preds[i]
            g = gates[i]
            area = tr.area
            t_app = tr.appearance
            row = adj[i]
            for j in range(n_d):
                ratio = det_area[j] / area
                if ratio < ratio_min or ratio > ratio_max:
                    continue
                # Cheap axis reject before the square root: |dx| and |dy| are
                # each a lower bound on the Euclidean distance.
                dx = det_cx[j] - px
                if dx < 0.0:
                    dx = -dx
                if dx > g:
                    continue
                dy = det_cy[j] - py
                if dy < 0.0:
                    dy = -dy
                if dy > g:
                    continue
                d = math.hypot(det_cx[j] - px, det_cy[j] - py)
                if d > g:
                    continue
                a = 0.0
                d_app = det_app[j]
                if t_app is not None and d_app is not None:
                    a = 0.5 * (abs(t_app[0] - d_app[0]) + abs(t_app[1] - d_app[1])
                               + abs(t_app[2] - d_app[2]) + abs(t_app[3] - d_app[3]))
                    if a > appearance_gate:
                        continue
                cost = int(math.floor(1000000.0 * (d / g + appearance_weight * a) + 0.5))
                row.append((j, cost))
                radj[j].append(i)
                n_edges += 1
        if n_edges == 0:
            return outcomes, []

        forced = forced_pairs(adj, radj, n_edges)
        if forced is not None:
            # Every component is a single edge: maximum cardinality 1, the only
            # edge, so no different matching of that size exists to tie with.
            for i, j in forced:
                outcomes[j] = ("matched", i, None)
            return outcomes, []

        margin = cfg["ambiguity_margin"]
        abstained: list[int] = []
        for tracks, ds in components(adj, radj):
            if _component_merge(ds, radj, preds, dets):
                reason: str | None = "merge"
                match = None
            else:
                local = {j: k for k, j in enumerate(ds)}
                sub = [[(local[j], c) for j, c in adj[t]] for t in tracks]
                match, reason = solve_component(sub, len(tracks), len(ds), margin)
            if reason is not None:
                for j in ds:
                    outcomes[j] = ("ambiguous", None, reason)
                abstained.extend(tracks)
            else:
                for k, t in enumerate(tracks):
                    j = match[k]
                    if j >= 0:
                        outcomes[ds[j]] = ("matched", t, None)
        return outcomes, abstained

    # -- checkpoint ---------------------------------------------------------
    def _state(self) -> dict:
        """The implementation-defined state object: everything needed to continue.

        Built fresh, so it never aliases live state, and made only of JSON
        scalars, lists and dicts, so it survives a round trip through a file and
        a new process unchanged. Everything here is bounded by the configured
        limits: `max_tracks` tracks with `path_points` samples each,
        `max_pending` episodes, `replay_batches` retained identities.
        """
        return {
            "v": STATE_VERSION,
            "camera_id": self._camera_id,
            "unit_id": self._unit_id,
            "config": dict(self._cfg),
            "next_id": self._next_id,
            "last_seq": self._last_seq,
            "last_t": self._last_t,
            "finished": self._finished,
            "tracks": [tr.state() for tr in self._tracks],
            "outbox": [_copy_episode(e) for e in self._outbox],
            "replay": [{"seq": seq, "input": _identity_json(entry.ident),
                        "receipt": _copy_receipt(entry.receipt)}
                       for seq, entry in sorted(self._window.items())],
        }

    def snapshot(self) -> dict:
        """An independent, JSON-compatible checkpoint of this exact boundary.

        Mutates nothing: no closure, no drain, no counter move. `sha256` is the
        digest of the canonical JSON of `state`, which catches accidental
        corruption -- it is not authentication and not a security boundary.
        """
        state = self._state()
        blob = canonical_state_json(state)
        return {"schema": SCHEMA, "state": state,
                "sha256": hashlib.sha256(blob.encode("utf-8")).hexdigest()}

    @classmethod
    def restore(cls, checkpoint: Any) -> "Tracker":
        """A new independent Tracker from a snapshot, at the same boundary.

        Validates the envelope, the checksum, and then the state on its own
        terms -- types, finiteness, configuration, bounds, scope, IDs,
        time/counter consistency and the invariants a real track always
        satisfies -- because a checksum recomputed over an invalid state does
        not make it valid. Nothing is unpickled and nothing is executed.
        """
        code = "invalid_snapshot"
        env = check_mapping(checkpoint, "snapshot", code)
        check_keys(env, ("schema", "state", "sha256"), (), "snapshot envelope", code)
        if env["schema"] != SCHEMA:
            raise TrackingError(code, f"snapshot schema {env['schema']!r} is not {SCHEMA!r}")
        want = env["sha256"]
        if not isinstance(want, str) or len(want) != 64 or \
                any(c not in "0123456789abcdef" for c in want):
            raise TrackingError(code, "sha256 must be 64 lowercase hex characters")
        state = env["state"]
        try:
            blob = canonical_state_json(state)
        except (TypeError, ValueError) as e:
            raise TrackingError(code, f"snapshot state is not canonical JSON: {e}") from e
        if hashlib.sha256(blob.encode("utf-8")).hexdigest() != want:
            raise TrackingError(code, "sha256 does not match the canonical JSON of state")

        s = check_mapping(state, "snapshot state", code)
        check_keys(s, ("v", "camera_id", "unit_id", "config", "next_id", "last_seq",
                           "last_t", "finished", "tracks", "outbox", "replay"),
                       (), "snapshot state", code)
        if s["v"] != STATE_VERSION:
            raise TrackingError(code, f"state version {s['v']!r} is not {STATE_VERSION}")
        camera_id = check_id(s["camera_id"], "snapshot camera_id", code)
        unit_id = check_id(s["unit_id"], "snapshot unit_id", code)
        cfg = resolve_config(s["config"], code)
        finished = check_bool(s["finished"], "snapshot finished", code)
        next_id = check_int(s["next_id"], "snapshot next_id", 1, 2 ** 62, code)
        last_seq = s["last_seq"]
        last_t = s["last_t"]
        if (last_seq is None) != (last_t is None):
            raise TrackingError(code, "last_seq and last_t are recorded together")
        if last_seq is not None:
            last_seq = check_int(last_seq, "snapshot last_seq", 0, SEQ_MAX, code)
            last_t = check_int(last_t, "snapshot last_t", 0, T_MS_MAX, code)

        tracks = [_Track.from_state(item, code)
                  for item in check_sequence(s["tracks"], "snapshot tracks", code)]
        if len(tracks) > cfg["max_tracks"]:
            raise TrackingError(code,
                                f"snapshot holds {len(tracks)} tracks; max_tracks is {cfg['max_tracks']}")
        seen: set[str] = set()
        previous_num = 0
        for tr in tracks:
            if tr.tid in seen:
                raise TrackingError(code, f"duplicate track ID {tr.tid} in snapshot")
            seen.add(tr.tid)
            if tr.num <= previous_num:
                raise TrackingError(code, "snapshot tracks are not in ascending creation order")
            previous_num = tr.num
            if tr.num >= next_id:
                raise TrackingError(code, f"snapshot next_id {next_id} precedes track {tr.tid}")
            if len(tr.path) > cfg["path_points"]:
                raise TrackingError(code,
                                    f"{tr.tid} holds {len(tr.path)} path samples; "
                                    f"path_points is {cfg['path_points']}")
            if last_t is not None and tr.last_t > last_t:
                raise TrackingError(code, f"{tr.tid} was observed after the high-water time")
            tr.check_invariants(code)

        outbox = [validate_episode(e, path_points=cfg["path_points"], camera_id=camera_id,
                                   unit_id=unit_id, code=code)
                  for e in check_sequence(s["outbox"], "snapshot outbox", code)]
        if len(outbox) > cfg["max_pending"]:
            raise TrackingError(code,
                                f"snapshot queues {len(outbox)} episodes; max_pending is "
                                f"{cfg['max_pending']}")

        window: dict[int, _Replay] = {}
        for item in check_sequence(s["replay"], "snapshot replay", code):
            entry = check_mapping(item, "replay entry", code)
            check_keys(entry, ("seq", "input", "receipt"), (), "replay entry", code)
            seq = check_int(entry["seq"], "replay seq", 0, SEQ_MAX, code)
            if seq in window:
                raise TrackingError(code, f"duplicate replay seq {seq} in snapshot")
            receipt = _validate_receipt(entry["receipt"], code)
            if receipt["seq"] != seq:
                raise TrackingError(code, f"replay entry {seq} carries a receipt for "
                                          f"seq {receipt['seq']}")
            if receipt["replayed"]:
                raise TrackingError(code, "a retained receipt is never itself a replay")
            window[seq] = _Replay(_identity_parse(entry["input"], code), receipt)
        if len(window) > cfg["replay_batches"]:
            raise TrackingError(code,
                                f"snapshot retains {len(window)} batches; replay_batches is "
                                f"{cfg['replay_batches']}")
        for seq in window:
            if last_seq is None:
                raise TrackingError(code, "a replay window needs an accepted batch")
            if seq > last_seq or seq <= last_seq - cfg["replay_batches"]:
                raise TrackingError(code, f"retained seq {seq} is outside the window that "
                                          f"ends at {last_seq}")
        if finished and tracks:
            raise TrackingError(code, "a finished tracker has no active tracks")

        tracker = cls(camera_id, unit_id, cfg)
        tracker._tracks = tracks
        tracker._outbox = outbox
        tracker._window = dict(sorted(window.items()))
        tracker._next_id = next_id
        tracker._last_seq = last_seq
        tracker._last_t = last_t
        tracker._finished = finished
        return tracker


def _component_merge(ds: Sequence[int], radj: Sequence[Sequence[int]],
                     preds: Sequence[tuple[float, float]],
                     dets: Sequence[_Det]) -> bool:
    """The contract's conservative "possible merge" rule.

    True when one detection box contains the predicted centres of at least two
    tracks that are feasible for it, boundaries included. It claims only that
    the geometry cannot tell one wide box from the two things inside it -- not
    that the detector actually merged them -- and it takes precedence over a
    cost tie when reporting the reason.
    """
    for j in ds:
        det = dets[j]
        right = det.x + det.w
        bottom = det.y + det.h
        hits = 0
        for i in radj[j]:
            px, py = preds[i]
            if det.x <= px <= right and det.y <= py <= bottom:
                hits += 1
                if hits >= 2:
                    return True
    return False
