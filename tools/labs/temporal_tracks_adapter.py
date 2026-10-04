"""Offline adapter from MaskFrame batches to temporal tracking and wire previews.

Conforms to Section 10 of labs-temporal-tracking-v1 contract.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import math
import re
from typing import Any, Dict, Iterable, List, Optional, Sequence

from .temporal_tracks import TrackingError, _is_bool, _is_int, _is_real, _ID_REGEX


def mask_frame_batch(
    frame: Any,
    *,
    camera_id: str,
    unit_id: str,
    seq: int,
    previous_run: Optional[int] = None,
) -> Dict[str, Any]:
    """Convert a duck-typed MaskFrame into a contract-compliant input batch."""
    if not isinstance(camera_id, str) or not _ID_REGEX.match(camera_id):
        raise TrackingError(f"invalid camera_id: {camera_id!r}", code="invalid_input")
    if not isinstance(unit_id, str) or not _ID_REGEX.match(unit_id):
        raise TrackingError(f"invalid unit_id: {unit_id!r}", code="invalid_input")

    if not _is_int(seq) or seq < 0 or seq > 2147483647:
        raise TrackingError(f"invalid seq: {seq}", code="invalid_input")

    if previous_run is not None:
        if not _is_int(previous_run) or previous_run < 0:
            raise TrackingError("previous_run must be null or nonnegative integer", code="invalid_input")

    # Duck-typed access to frame
    try:
        t_s = frame.t_s
        run = frame.run
        scored = frame.scored
        blobs = frame.blobs
    except AttributeError as ex:
        raise TrackingError(f"frame missing required attribute: {ex}", code="invalid_input")

    if not _is_real(t_s) or t_s < 0.0:
        raise TrackingError("frame t_s must be finite real >= 0", code="invalid_input")

    if not _is_int(run) or run < 0:
        raise TrackingError("frame run must be nonnegative integer", code="invalid_input")

    if not isinstance(scored, bool):
        raise TrackingError("frame scored must be boolean", code="invalid_input")

    t_ms = math.floor(1000.0 * float(t_s) + 0.5)

    reset = (previous_run is not None) and (run != previous_run)

    detections: List[Dict[str, Any]] = []

    if scored:
        if not isinstance(blobs, (list, tuple)):
            raise TrackingError("scored frame blobs must be a sequence", code="invalid_input")

        seen_labels = set()
        for b in blobs:
            try:
                label = b.label
                bbox = b.bbox
            except AttributeError as ex:
                raise TrackingError(f"blob missing attribute: {ex}", code="invalid_input")

            if not _is_int(label) or label < 0:
                raise TrackingError("blob label must be nonnegative integer", code="invalid_input")

            if label in seen_labels:
                raise TrackingError(f"duplicate blob label: {label}", code="invalid_input")
            seen_labels.add(label)

            if not isinstance(bbox, (list, tuple)) or _is_bool(bbox) or len(bbox) != 4:
                raise TrackingError("blob bbox must be 4 numbers", code="invalid_input")

            for coord in bbox:
                if not _is_real(coord):
                    raise TrackingError("blob bbox coordinates must be finite numbers", code="invalid_input")

            x, y, w, h = float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3])
            if x < 0.0 or y < 0.0 or w < 1e-6 or h < 1e-6 or (x + w) > 1.0 or (y + h) > 1.0:
                raise TrackingError(f"blob bbox bounds violation: {[x, y, w, h]}", code="invalid_input")

            detections.append({
                "id": f"b{label}",
                "bbox": [x, y, w, h],
            })

    return {
        "camera_id": camera_id,
        "unit_id": unit_id,
        "seq": seq,
        "t_ms": int(t_ms),
        "detections": detections,
        "reset": reset,
    }


def _validate_episode(ep: Any) -> Dict[str, Any]:
    """Validate episode against Section 8 schema."""
    if not isinstance(ep, dict) or _is_bool(ep):
        raise TrackingError("episode must be a dict", code="invalid_input")

    required = {
        "camera_id",
        "unit_id",
        "track_id",
        "start_ms",
        "end_ms",
        "observations",
        "ambiguous_batches",
        "reason",
        "bbox",
        "bbox_at_ms",
        "first_center",
        "last_center",
        "path_length",
        "net_displacement",
        "mean_speed",
        "max_observation_gap_ms",
        "path",
    }
    for k in required:
        if k not in ep:
            raise TrackingError(f"episode missing required key: {k}", code="invalid_input")

    if not isinstance(ep["camera_id"], str) or not _ID_REGEX.match(ep["camera_id"]):
        raise TrackingError("malformed camera_id in episode", code="invalid_input")
    if not isinstance(ep["unit_id"], str) or not _ID_REGEX.match(ep["unit_id"]):
        raise TrackingError("malformed unit_id in episode", code="invalid_input")
    if not isinstance(ep["track_id"], str) or not _ID_REGEX.match(ep["track_id"]):
        raise TrackingError("malformed track_id in episode", code="invalid_input")

    start_ms = ep["start_ms"]
    end_ms = ep["end_ms"]
    if not _is_int(start_ms) or start_ms < 0 or start_ms > 3599999:
        raise TrackingError("start_ms must be integer in 0..3599999", code="invalid_input")
    if not _is_int(end_ms) or end_ms < start_ms:
        raise TrackingError("end_ms must be integer >= start_ms", code="invalid_input")
    if (end_ms - start_ms) >= 300000:
        raise TrackingError("episode duration must be < 300000 ms", code="invalid_input")

    if ep["reason"] not in ("gap", "span", "reset", "finish"):
        raise TrackingError(f"invalid reason: {ep['reason']}", code="invalid_input")

    bbox = ep["bbox"]
    if not isinstance(bbox, (list, tuple)) or _is_bool(bbox) or len(bbox) != 4:
        raise TrackingError("bbox must be 4 numbers", code="invalid_input")
    for c in bbox:
        if not _is_real(c):
            raise TrackingError("bbox values must be finite", code="invalid_input")
    x, y, w, h = float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3])
    if x < 0.0 or y < 0.0 or w < 1e-6 or h < 1e-6 or (x + w) > 1.0 or (y + h) > 1.0:
        raise TrackingError("bbox bounds violation", code="invalid_input")

    if not _is_int(ep["observations"]) or ep["observations"] < 1:
        raise TrackingError("observations must be integer >= 1", code="invalid_input")
    if not _is_int(ep["ambiguous_batches"]) or ep["ambiguous_batches"] < 0:
        raise TrackingError("ambiguous_batches must be integer >= 0", code="invalid_input")

    if not _is_real(ep["path_length"]) or ep["path_length"] < 0.0:
        raise TrackingError("path_length must be finite real >= 0", code="invalid_input")
    if not _is_real(ep["net_displacement"]) or ep["net_displacement"] < 0.0:
        raise TrackingError("net_displacement must be finite real >= 0", code="invalid_input")

    if ep["mean_speed"] is not None:
        if not _is_real(ep["mean_speed"]) or ep["mean_speed"] < 0.0:
            raise TrackingError("mean_speed must be finite real or None", code="invalid_input")

    if not _is_int(ep["max_observation_gap_ms"]) or ep["max_observation_gap_ms"] < 0:
        raise TrackingError("max_observation_gap_ms must be integer >= 0", code="invalid_input")

    return ep


def labs_rows(
    episodes: Iterable[Dict[str, Any]],
    *,
    hour_start: datetime,
) -> List[Dict[str, Any]]:
    """Convert closed episodes to ObservationIn wire preview format."""
    if not isinstance(hour_start, datetime) or hour_start.tzinfo is None or hour_start.utcoffset() is None:
        raise TrackingError("hour_start must be an aware datetime", code="invalid_input")

    hour_utc = hour_start.astimezone(timezone.utc)
    if hour_utc.minute != 0 or hour_utc.second != 0 or hour_utc.microsecond != 0:
        raise TrackingError("hour_start must be aligned to top of hour (00:00:00.000)", code="invalid_input")

    ep_list = list(episodes)
    if len(ep_list) > 500:
        raise TrackingError("exceeded 500 episodes limit", code="invalid_input")

    validated_eps = [_validate_episode(ep) for ep in ep_list]

    rows: List[Dict[str, Any]] = []
    for ep in validated_eps:
        st = hour_utc + timedelta(milliseconds=ep["start_ms"])
        en = hour_utc + timedelta(milliseconds=ep["end_ms"])

        st_str = st.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        en_str = en.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

        gap_ms = ep["max_observation_gap_ms"]
        max_gap_s = (gap_ms // 1000) if (gap_ms % 1000 == 0) else (gap_ms / 1000.0)

        metrics = {
            "track_id": str(ep["track_id"]),
            "observations": int(ep["observations"]),
            "ambiguous_batches": int(ep["ambiguous_batches"]),
            "path_length": float(ep["path_length"]),
            "net_displacement": float(ep["net_displacement"]),
            "mean_speed": float(ep["mean_speed"]) if ep["mean_speed"] is not None else None,
            "max_gap_s": max_gap_s,
            "end_reason": str(ep["reason"]),
        }

        bbox = ep["bbox"]
        rows.append({
            "start_time": st_str,
            "end_time": en_str,
            "object_count": 1,
            "bbox_x": float(bbox[0]),
            "bbox_y": float(bbox[1]),
            "bbox_w": float(bbox[2]),
            "bbox_h": float(bbox[3]),
            "metrics": metrics,
        })

    return rows
