"""Offline adapter between the existing Labs foreground masks and the temporal
tracking contract, plus the offline Labs wire PREVIEW.

This module is the ONLY place in the tracking deliverable that knows about
`labs_foreground_mask`. It reads no pixels and decodes nothing: a `MaskFrame`
already carries, per frame, the run of the model that produced it, whether the
frame may be scored, and its cleaned blobs with normalised boxes. The adapter
turns one such frame into one contract batch; the caller owns the sequence
number, the pre-roll and the origin placement, exactly as the contract asks.

`run` changes are model rebuilds (frame size change, a time jump, a primed run
reaching its frame cap), so the adapter's reset policy is the contract's: a
change of run resets the tracker rather than stitching a track across a model
the caller never measured. That deliberately does NOT imitate B6's cross-run
episode stitching, and B6 itself (labs_track_linking) is untouched and
unregistered: this adapter runs only when a caller imports it explicitly.

Importing this module never requires OpenCV or images.
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:                 # allow `python3 <path>/this_file.py`
    sys.path.insert(0, _HERE)

from temporal_tracks import (              # noqa: E402
    MAX_SEQ, MAX_T_MS, TrackingError, _bbox_of, _snap_episode, as_id,
    as_int, as_real)

__all__ = ["mask_frame_batch", "labs_rows", "MAX_ROWS", "MAX_ROW_SPAN_MS",
           "HOUR_MS"]

#: cilex-vision refuses a whole submission above this many rows per unit
#: (routers/labs.py:1441, MAX_OBSERVATIONS_PER_UNIT -- mirrored in
#: tools/labs/worker.py:433, checked 2026-10-04).
MAX_ROWS = 500
#: The server's observation-group span cap, in milliseconds (worker.py:440
#: GROUP_MAX_SPAN_S; cilex-vision routers/labs.py:194, checked 2026-10-04).
MAX_ROW_SPAN_MS = 300000
HOUR_MS = 3600000


def _nonneg_int(v: Any, what: str) -> int:
    if isinstance(v, bool) or not isinstance(v, int) or v < 0:
        raise TrackingError("invalid_input", "%s must be a non-negative integer"
                            % what)
    return v


def mask_frame_batch(frame: Any, *, camera_id: Any, unit_id: Any, seq: Any,
                     previous_run: Optional[int] = None) -> dict:
    """One contract batch built from one `MaskFrame` (duck typed, no pixels).

    Inputs: `frame.t_s`, `frame.run`, `frame.scored`, `frame.blobs`; each blob
    has an integer `label` and a normalised `bbox`. `t_ms` is `floor(1000*t_s
    + 0.5)`. `reset` is true exactly when `previous_run` is not null and
    `frame.run != previous_run`. Unscored frames map to no detections and their
    blobs are not inspected at all.
    """
    cam = as_id(camera_id, "camera_id")
    unit = as_id(unit_id, "unit_id")
    seq_n = as_int(seq, "seq", 0, MAX_SEQ)
    if previous_run is not None:
        previous_run = _nonneg_int(previous_run, "previous_run")

    t_s = getattr(frame, "t_s", None)
    if not (isinstance(t_s, (int, float)) and not isinstance(t_s, bool)):
        raise TrackingError("invalid_input", "frame.t_s must be a real")
    t_s = float(t_s)
    if t_s != t_s or t_s in (float("inf"), float("-inf")) or t_s < 0:
        raise TrackingError("invalid_input", "frame.t_s must be finite and >= 0")
    t_ms = int(t_s * 1000.0 + 0.5)
    if t_ms > MAX_T_MS:
        raise TrackingError("invalid_input", "frame.t_s is beyond the contract's"
                            " millisecond range")
    run = _nonneg_int(getattr(frame, "run", None), "frame.run")
    scored = getattr(frame, "scored", None)
    if not isinstance(scored, bool):
        raise TrackingError("invalid_input", "frame.scored must be a boolean")

    detections = []
    if scored:
        blobs = getattr(frame, "blobs", None)
        if blobs is None or isinstance(blobs, (str, bytes, dict)):
            raise TrackingError("invalid_input", "frame.blobs must be a sequence")
        seen = set()
        for k, blob in enumerate(blobs):
            label = getattr(blob, "label", None)
            if isinstance(label, bool) or not isinstance(label, int) or label < 0:
                raise TrackingError("invalid_input",
                                    "blob %d label must be a non-negative integer"
                                    % k)
            if label in seen:
                raise TrackingError("invalid_input",
                                    "blob label %d appears twice" % label)
            seen.add(label)
            detections.append({"id": "b" + str(label),
                               "bbox": _bbox_of(getattr(blob, "bbox", None),
                                                "blob %d bbox" % k)})
        detections.sort(key=lambda d: d["id"])

    return {"camera_id": cam, "unit_id": unit, "seq": seq_n, "t_ms": t_ms,
            "detections": detections,
            "reset": previous_run is not None and run != previous_run}


def _stamp(hour_start: datetime, ms: int) -> str:
    when = hour_start + timedelta(milliseconds=ms)
    return (when.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (when.microsecond // 1000))


def labs_rows(episodes: Any, *, hour_start: Any) -> list:
    """Offline WIRE PREVIEW: contract episodes as existing `ObservationIn` rows.

    This never submits, never truncates and never claims to be live. `hour_start`
    must be an aware datetime on a whole minute in UTC; every episode is
    materialised and validated before anything is returned, and any violation
    (more than 500 episodes, an episode starting outside the hour, an episode
    reaching 300 s or longer) raises `invalid_input` rather than being dropped.
    """
    if not isinstance(hour_start, datetime):
        raise TrackingError("invalid_input", "hour_start must be a datetime")
    if hour_start.tzinfo is None or hour_start.utcoffset() is None:
        raise TrackingError("invalid_input", "hour_start must be timezone aware")
    start = hour_start.astimezone(timezone.utc)
    if start.minute or start.second or start.microsecond:
        raise TrackingError("invalid_input",
                            "hour_start must be on a whole minute")
    if isinstance(episodes, (str, bytes, dict)) or episodes is None:
        raise TrackingError("invalid_input", "episodes must be a sequence")
    items = list(episodes)
    if len(items) > MAX_ROWS:
        raise TrackingError("invalid_input",
                            "%d episodes exceeds the %d-row submission cap"
                            % (len(items), MAX_ROWS))

    rows = []
    for k, raw in enumerate(items):
        try:
            ep = _snap_episode(raw, "episode %d" % k)
        except TrackingError as e:
            raise TrackingError("invalid_input", str(e))
        as_id(ep["camera_id"], "episode %d camera_id" % k)
        as_id(ep["unit_id"], "episode %d unit_id" % k)
        as_id(ep["track_id"], "episode %d track_id" % k)
        if not 0 <= ep["start_ms"] < HOUR_MS:
            raise TrackingError("invalid_input",
                                "episode %d starts outside the claimed hour" % k)
        if ep["end_ms"] - ep["start_ms"] >= MAX_ROW_SPAN_MS:
            raise TrackingError("invalid_input",
                                "episode %d spans %d ms; the server groups at most"
                                " %d" % (k, ep["end_ms"] - ep["start_ms"],
                                         MAX_ROW_SPAN_MS))
        x, y, w, h = ep["bbox"]
        rows.append({
            "start_time": _stamp(start, ep["start_ms"]),
            "end_time": _stamp(start, ep["end_ms"]),
            "object_count": 1,
            "bbox_x": x, "bbox_y": y, "bbox_w": w, "bbox_h": h,
            "metrics": {
                "track_id": ep["track_id"],
                "observations": ep["observations"],
                "ambiguous_batches": ep["ambiguous_batches"],
                "path_length": ep["path_length"],
                "net_displacement": ep["net_displacement"],
                "mean_speed": ep["mean_speed"],
                "max_gap_s": ep["max_observation_gap_ms"] / 1000.0,
                "end_reason": ep["reason"],
            }})
    return rows
