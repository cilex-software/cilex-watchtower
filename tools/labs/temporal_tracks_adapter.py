"""Offline adaptation between the existing Labs analysers and the new tracker.

Two pure functions, and nothing else. This module is never registered with
`run_worker.py`, never imported by `plugins.py`, and never activated against a
station: the contract's adapter is selected by an explicit import or the offline
CLI, so B6 (`labs_track_linking`) and its normal plugin path stay exactly as
they are. Existing behaviour stays on its existing path.

  * `mask_frame_batch()` turns ONE existing `labs_foreground_mask.MaskFrame`
    into a `temporal_tracks` input batch. The MaskFrame/Blob interface is taken
    by duck typing (`t_s`, `run`, `scored`, `blobs`; a blob with an integer
    `label` and a normalised `bbox`), so this module imports neither the
    vendored analyser, nor NumPy, nor OpenCV, nor an image: importing it needs
    nothing but the standard library and the tracker core. No pixel is read.
  * `labs_rows()` renders closed episodes as an offline PREVIEW of the Labs
    observation wire format, using the existing `ObservationIn` field names and
    the metric caps `worker.check_metrics` enforces. It is a preview for a
    caller to inspect: it never truncates, merges, submits or claims to be
    live.

Both raise `TrackingError("invalid_input")` rather than repair anything. A
frame whose clock is not a finite non-negative number, a blob whose label is
not a distinct non-negative integer, a box that does not fit the frame, an
episode that is not a section-8 episode, an hour start that is not an aware
datetime on a whole UTC hour: each is the caller's error, and silently fixing it
would put a wrong number into evidence that a guard later reads.

Millisecond rounding is where this adapter and the tracker meet: `t_ms` is
`floor(1000*t_s + 0.5)`, and two frames that land on the same millisecond are
rejected by `feed` as a non-increasing timestamp. They are not silently
combined and not silently dropped -- a recording that produced them is a
recording the caller has to place differently.

Run boundaries are the caller's to declare. `reset` is true exactly when a
`previous_run` was supplied and this frame's `run` differs, which is the
contract's discontinuity rule, not B6's cross-run episode stitching: the
background model was rebuilt there, so nothing is linked across it. Pre-roll
placement and the choice of time origin stay with the explicit caller.
"""
from __future__ import annotations

import math
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable, Mapping

import temporal_tracks as tt
from temporal_tracks import TrackingError

__all__ = ["mask_frame_batch", "labs_rows", "MAX_OBSERVATIONS", "MAX_METRIC_KEYS",
           "MAX_METRIC_KEY_LEN", "MAX_METRIC_STR_LEN"]

#: Mirrors of the caps the running worker enforces before it submits
#: (worker.py MAX_OBSERVATIONS_PER_UNIT / MAX_METRIC_KEYS / MAX_METRIC_KEY_LEN /
#: MAX_METRIC_STR_LEN, which mirror cilex-vision's `_clean_metrics`). They are
#: repeated here, not imported, so this adapter keeps importing without
#: numpy/cv2; tools/tests/labs-temporal-tracks.py checks every row it renders
#: against the worker's own `check_metrics`, so a drift fails there.
MAX_OBSERVATIONS = 500
MAX_METRIC_KEYS = 24
MAX_METRIC_KEY_LEN = 40
MAX_METRIC_STR_LEN = 120
_METRIC_KEY_OK = frozenset("abcdefghijklmnopqrstuvwxyz0123456789_")

#: The wire preview's row keys, matching the existing ObservationIn names. No
#: `ts` and no `span_s` alias, no `object_class`, no confidence, no kind.
ROW_KEYS = ("start_time", "end_time", "object_count", "bbox_x", "bbox_y", "bbox_w",
            "bbox_h", "metrics")
METRIC_KEYS = ("track_id", "observations", "ambiguous_batches", "path_length",
               "net_displacement", "mean_speed", "max_gap_s", "end_reason")


def mask_frame_batch(frame: Any, *, camera_id: str, unit_id: str, seq: int,
                     previous_run: int | None = None) -> dict:
    """One MaskFrame as a tracker input batch. Pure: it reads, it does not feed.

    A scored frame contributes one detection per blob, `{"id": "b"+label,
    "bbox": [x, y, w, h]}`, with no appearance (this adapter invents no
    descriptor). An unscored frame contributes none, and its blobs are not
    inspected or validated at all: a warm-up or global-change frame's blobs are
    not measurements, and pretending otherwise would be the same error as
    reporting them.
    """
    code = "invalid_input"
    if frame is None or not hasattr(frame, "t_s") or not hasattr(frame, "run") \
            or not hasattr(frame, "scored") or not hasattr(frame, "blobs"):
        raise TrackingError(code, "a frame needs t_s, run, scored and blobs "
                                  "(labs_foreground_mask.MaskFrame's interface)")
    t_s = frame.t_s
    if isinstance(t_s, bool) or not isinstance(t_s, (int, float)) or not math.isfinite(float(t_s)):
        raise TrackingError(code, f"frame t_s must be a finite number of seconds, got {t_s!r}")
    t_s = float(t_s)
    if t_s < 0.0:
        raise TrackingError(code, f"frame t_s must be >= 0, got {t_s!r}")
    scaled = 1000.0 * t_s + 0.5
    if not math.isfinite(scaled):
        # A finite t_s can still overflow the millisecond product (1e308 s);
        # math.floor of an infinity is an OverflowError, not a refusal.
        raise TrackingError(code, f"frame t_s {t_s!r} is too large to express in milliseconds")
    t_ms = int(math.floor(scaled))
    if t_ms > tt.T_MS_MAX:
        raise TrackingError(code, f"frame t_s {t_s!r} rounds past t_ms's maximum {tt.T_MS_MAX}")
    run = _nonneg_int(frame.run, "frame run", code)
    scored = tt.check_bool(frame.scored, "frame scored", code)
    if previous_run is not None:
        previous_run = _nonneg_int(previous_run, "previous_run", code)
    cam = tt.check_id(camera_id, "camera_id", code)
    unit = tt.check_id(unit_id, "unit_id", code)
    n = tt.check_int(seq, "seq", 0, tt.SEQ_MAX, code)

    detections: list[dict] = []
    if scored:
        blobs = frame.blobs
        if not isinstance(blobs, (list, tuple)):
            raise TrackingError(code, f"frame.blobs must be a sequence, got {type(blobs).__name__}")
        seen: set[int] = set()
        for i, blob in enumerate(blobs):
            if blob is None or not hasattr(blob, "label") or not hasattr(blob, "bbox"):
                raise TrackingError(code, f"blobs[{i}] needs label and bbox (fm.Blob's interface)")
            label = blob.label
            if isinstance(label, bool) or not isinstance(label, int):
                raise TrackingError(code, f"blobs[{i}].label must be an integer, got {label!r}")
            if label < 0:
                raise TrackingError(code, f"blobs[{i}].label must be >= 0, got {label}")
            if label in seen:
                raise TrackingError(code, f"blobs[{i}].label {label} repeats in one frame")
            seen.add(label)
            box = blob.bbox
            x, y, w, h = tt.check_bbox(box, f"blobs[{i}].bbox", code)
            detections.append({"id": f"b{label}", "bbox": [x, y, w, h]})
    return {"camera_id": cam, "unit_id": unit, "seq": n, "t_ms": t_ms,
            "detections": detections,
            "reset": bool(previous_run is not None and run != previous_run)}


def _nonneg_int(v: Any, what: str, code: str) -> int:
    if isinstance(v, bool) or not isinstance(v, int):
        raise TrackingError(code, f"{what} must be an integer, got {v!r}")
    if v < 0:
        raise TrackingError(code, f"{what} must be >= 0, got {v}")
    return int(v)


def _hour_start(value: Any) -> datetime:
    """An aware datetime, normalised to UTC, on a whole hour -- or a refusal."""
    code = "invalid_input"
    if not isinstance(value, datetime):
        raise TrackingError(code, f"hour_start must be a datetime, got {type(value).__name__}")
    if value.tzinfo is None or value.tzinfo.utcoffset(value) is None:
        raise TrackingError(code, "hour_start is naive: refusing to guess its zone")
    utc = value.astimezone(timezone.utc)
    if utc.minute or utc.second or utc.microsecond:
        raise TrackingError(code,
                            f"hour_start {utc.isoformat()} is not a whole UTC hour; a Labs "
                            "unit claims one hour and its rows are placed inside it")
    return utc


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _check_metrics(metrics: Mapping) -> None:
    """The same caps `worker.check_metrics` applies, checked before anything is
    returned: a row the server would 422 on is a local error here, not a lost
    unit later."""
    code = "invalid_input"
    if len(metrics) > MAX_METRIC_KEYS:
        raise TrackingError(code, f"{len(metrics)} metric keys; the wire allows {MAX_METRIC_KEYS}")
    for k, v in metrics.items():
        if not isinstance(k, str) or not k or len(k) > MAX_METRIC_KEY_LEN:
            raise TrackingError(code, f"metric key {k!r} is not 1-{MAX_METRIC_KEY_LEN} chars")
        if any(ch not in _METRIC_KEY_OK for ch in k):
            raise TrackingError(code, f"metric key {k!r} is not a lowercase slug")
        if isinstance(v, bool):
            raise TrackingError(code, f"metric {k!r} is a boolean, not a number")
        if v is None:
            continue
        if isinstance(v, (int, float)):
            if not math.isfinite(float(v)):
                raise TrackingError(code, f"metric {k!r} is not finite")
            continue
        if isinstance(v, str):
            if len(v) > MAX_METRIC_STR_LEN:
                raise TrackingError(code, f"metric {k!r} is {len(v)} chars; the wire allows "
                                          f"{MAX_METRIC_STR_LEN}")
            continue
        raise TrackingError(code, f"metric {k!r} is {type(v).__name__}, not a scalar")


def labs_rows(episodes: Iterable[Any], *, hour_start: datetime) -> list[dict]:
    """Closed episodes as offline PREVIEW rows in the existing wire shape.

    Every episode is materialised and validated against CONTRACT.md section 8,
    and every limit checked, BEFORE the first row is built: a caller either gets
    the whole preview or a refusal, never a half-rendered list it might mistake
    for a complete one. Episode order is preserved; nothing is truncated,
    coarsely merged or submitted, and this is not a live submission path.
    """
    code = "invalid_input"
    origin = _hour_start(hour_start)
    items = list(episodes)
    if len(items) > MAX_OBSERVATIONS:
        raise TrackingError(code,
                            f"{len(items)} episodes; a unit carries at most {MAX_OBSERVATIONS} "
                            "rows and this preview does not truncate")
    checked = [tt.validate_episode(e, code=code) for e in items]
    rows: list[dict] = []
    for ep in checked:
        start = ep["start_ms"]
        end = ep["end_ms"]
        if not 0 <= start <= 3599999:
            raise TrackingError(code,
                                f"{ep['track_id']}: start_ms {start} is not inside one hour")
        if end < start:
            raise TrackingError(code, f"{ep['track_id']}: end_ms {end} precedes start_ms {start}")
        if end - start >= 300000:
            raise TrackingError(code,
                                f"{ep['track_id']}: a {end - start} ms episode can never join an "
                                "event group (the server's group span cap is 300 s)")
        x, y, w, h = ep["bbox"]
        metrics = {
            "track_id": ep["track_id"],
            "observations": ep["observations"],
            "ambiguous_batches": ep["ambiguous_batches"],
            "path_length": ep["path_length"],
            "net_displacement": ep["net_displacement"],
            "mean_speed": ep["mean_speed"],
            "max_gap_s": ep["max_observation_gap_ms"] / 1000.0,
            "end_reason": ep["reason"],
        }
        if tuple(metrics) != METRIC_KEYS:
            raise TrackingError(code, "internal error: metric keys drifted from the preview shape")
        _check_metrics(metrics)
        rows.append({
            "start_time": _iso(origin + timedelta(milliseconds=start)),
            "end_time": _iso(origin + timedelta(milliseconds=end)),
            "object_count": 1,
            "bbox_x": x, "bbox_y": y, "bbox_w": w, "bbox_h": h,
            "metrics": metrics,
        })
    return rows
