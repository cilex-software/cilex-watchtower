"""Offline adaptation between the existing Labs MaskFrame stream and the temporal
tracking engine (docs/benchmarks/labs-tracking/CONTRACT.md section 10).

TWO PURE FUNCTIONS, used only through an explicit import/call. Nothing here is
registered with run_worker.py or the plugin registry, nothing touches the network,
and importing this module needs no images and no OpenCV.

  * mask_frame_batch(frame, *, camera_id, unit_id, seq, previous_run=None) turns ONE
    existing MaskFrame (duck-typed: t_s, run, scored, blobs; each blob has an integer
    label and a normalized bbox) into one contract batch dict. No pixels are read.
    t_ms = floor(1000 * t_s + 0.5). reset is true exactly when previous_run is not
    null and the frame's run differs from it: a changed background model is a
    discontinuity (labs_foreground_mask's rule), and this adapter answers it with a
    fresh start rather than B6's cross-run episode stitching, which this contract
    deliberately does not imitate. Unscored frames carry NO detections and their
    blobs are never inspected. Scope, structure and measurements are validated here;
    Tracker.feed then enforces capacities and time order -- a millisecond timestamp
    collision after rounding is feed's sequence_error, never silently merged here.

  * labs_rows(episodes, *, hour_start) is an offline wire PREVIEW: closed episodes
    (contract section 8) as ObservationIn-shaped rows for one claimed hour, validated
    before anything is returned. It never truncates, merges or submits, and it is
    not a claim of a live run: start_ms must lie inside the hour and every span must
    stay under the server's 300 s group limit, so a row here can always join an
    event group. metrics carries exactly the eight tracking measurements and no
    object_class, confidence or kind -- a track measures where changed pixels went,
    not what they are.
"""
from __future__ import annotations

import math
from datetime import datetime, timedelta, timezone
from typing import Any

import temporal_tracks as tt

__all__ = ["mask_frame_batch", "labs_rows"]

_MISSING = object()


def _invalid(msg: str) -> tt.TrackingError:
    return tt.TrackingError("invalid_input", msg)


def _attr(obj: Any, name: str) -> Any:
    try:
        v = getattr(obj, name, _MISSING)
    except AttributeError:
        v = _MISSING
    if v is _MISSING:
        raise _invalid(f"frame/blob has no {name!r} attribute")
    return v


def mask_frame_batch(frame: Any, *, camera_id: str, unit_id: str, seq: int,
                     previous_run: int | None = None) -> dict:
    """One MaskFrame -> one contract batch dict. Pure; no I/O, no pixels read."""
    tt._check_id(camera_id, "camera_id", "invalid_input")
    tt._check_id(unit_id, "unit_id", "invalid_input")
    if not tt._is_int(seq) or not 0 <= seq <= 2147483647:
        raise _invalid("seq must be an integer in 0..2147483647")
    if previous_run is not None and (not tt._is_int(previous_run) or previous_run < 0):
        raise _invalid("previous_run must be null or a nonnegative integer")
    t_s = _attr(frame, "t_s")
    run = _attr(frame, "run")
    scored = _attr(frame, "scored")
    if not tt._is_real(t_s) or t_s < 0:
        raise _invalid("t_s must be a finite real >= 0")
    t_ms = math.floor(1000.0 * float(t_s) + 0.5)
    if t_ms > 9007199254740991:
        raise _invalid("t_s is too large to place on the millisecond timeline")
    if not tt._is_int(run) or run < 0:
        raise _invalid("run must be a nonnegative integer")
    if not isinstance(scored, bool):
        raise _invalid("scored must be a boolean")
    detections = []
    if scored:
        blobs = _attr(frame, "blobs")
        try:
            blob_list = list(blobs)
        except TypeError:
            raise _invalid("blobs is not iterable") from None
        labels: set[int] = set()
        for blob in blob_list:
            label = _attr(blob, "label")
            if not tt._is_int(label) or label < 0:
                raise _invalid("a blob's label must be a nonnegative integer")
            if label in labels:
                raise _invalid(f"duplicate blob label {label}")
            labels.add(label)
            raw_bbox = _attr(blob, "bbox")
            try:
                raw_bbox = list(raw_bbox)
            except TypeError:
                raise _invalid("a blob's bbox is not a sequence") from None
            bbox = tt._check_bbox(raw_bbox, "invalid_input")
            detections.append((label, {"id": f"b{label}", "bbox": bbox}))
        detections.sort(key=lambda kv: kv[0])
    return {"camera_id": camera_id, "unit_id": unit_id, "seq": seq, "t_ms": t_ms,
            "detections": [d for _, d in detections],
            "reset": previous_run is not None and run != previous_run}


def _stamp(hour_utc: datetime, ms: int) -> str:
    t = hour_utc + timedelta(milliseconds=ms)
    return t.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def labs_rows(episodes: Any, *, hour_start: datetime) -> list:
    """Closed episodes -> ObservationIn-shaped rows for the hour. Offline preview.

    Every episode is materialized and validated against contract section 8 BEFORE
    anything is returned: at most 500 rows, each start_ms in 0..3599999,
    end_ms >= start_ms and end_ms - start_ms < 300000. Violations raise
    TrackingError("invalid_input"); nothing is truncated, merged or invented.
    """
    if not isinstance(hour_start, datetime):
        raise _invalid("hour_start must be a datetime")
    if hour_start.tzinfo is None or hour_start.utcoffset() is None:
        raise _invalid("hour_start must be an aware datetime")
    hour_utc = hour_start.astimezone(timezone.utc)
    if hour_utc.minute != 0 or hour_utc.second != 0 or hour_utc.microsecond != 0:
        raise _invalid("hour_start must be an exact hour")
    try:
        eps = list(episodes)
    except TypeError:
        raise _invalid("episodes must be iterable") from None
    if len(eps) > 500:
        raise _invalid(f"{len(eps)} episodes exceeds the 500-observation unit cap")
    rows = []
    for ep in eps:
        v = tt._check_episode(ep, camera_id=None, unit_id=None, path_points=None,
                              code="invalid_input")
        if v["start_ms"] > 3599999:
            raise _invalid("episode start_ms lies outside the claimed hour")
        if v["end_ms"] - v["start_ms"] >= 300000:
            raise _invalid("episode spans 300 s or more; it could never join a group")
        gap_ms = v["max_observation_gap_ms"]
        rows.append({
            "start_time": _stamp(hour_utc, v["start_ms"]),
            "end_time": _stamp(hour_utc, v["end_ms"]),
            "object_count": 1,
            "bbox_x": v["bbox"][0], "bbox_y": v["bbox"][1],
            "bbox_w": v["bbox"][2], "bbox_h": v["bbox"][3],
            "metrics": {"track_id": v["track_id"],
                        "observations": v["observations"],
                        "ambiguous_batches": v["ambiguous_batches"],
                        "path_length": v["path_length"],
                        "net_displacement": v["net_displacement"],
                        "mean_speed": v["mean_speed"],
                        "max_gap_s": (gap_ms // 1000 if gap_ms % 1000 == 0
                                      else gap_ms / 1000),
                        "end_reason": v["reason"]}})
    return rows
