#!/usr/bin/env python3
"""Run temporal tracking on a real recording or export.

Reads frames, extracts foreground blobs, feeds batches into Tracker, and emits tracks as JSON.
Conforms to product integration requirements.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
import time
from typing import Any, Dict, List, Optional

# Add repository root and tools/labs to sys.path
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, REPO_ROOT)
sys.path.insert(0, os.path.join(REPO_ROOT, "tools", "labs"))

from tools.labs.temporal_tracks import Tracker, TrackingError


def emit_event(ev: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(ev, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def compute_file_sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest().lower()


def analyze_recording(video_path: str, camera_id: str, unit_id: str) -> None:
    if not os.path.isfile(video_path):
        emit_event({
            "event": "status",
            "status": "not_verified",
            "error": f"Recording file not found or inaccessible: {video_path}. Real-footage acceptance is NOT VERIFIED.",
        })
        return

    try:
        file_hash = compute_file_sha256(video_path)
    except Exception as ex:
        emit_event({
            "event": "status",
            "status": "failed",
            "error": f"Could not hash video file: {ex}",
        })
        return

    emit_event({
        "event": "start",
        "file": video_path,
        "file_hash": file_hash,
        "camera_id": camera_id,
        "unit_id": unit_id,
    })

    try:
        import cv2
    except ImportError:
        emit_event({
            "event": "status",
            "status": "failed",
            "error": "OpenCV (cv2) is not installed in the python environment.",
        })
        return

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        emit_event({
            "event": "status",
            "status": "failed",
            "error": f"Could not decode video file: {video_path}",
        })
        return

    fps = cap.get(cv2.CAP_PROP_FPS)
    if fps <= 0 or math.isnan(fps):
        fps = 15.0  # fallback to fleet 15 fps

    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

    # MOG2 background subtractor (consistent with labs_foreground_mask.py parameters)
    fgbg = cv2.createBackgroundSubtractorMOG2(history=100, varThreshold=16, detectShadows=True)

    tracker = Tracker(camera_id=camera_id, unit_id=unit_id)
    frame_idx = 0
    t_start = time.perf_counter()

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        # Compute foreground mask at 320px scale
        scaled_w = 320
        scaled_h = int(height * (320.0 / width)) if width > 0 else 180
        small_frame = cv2.resize(frame, (scaled_w, scaled_h), interpolation=cv2.INTER_AREA)
        fgmask = fgbg.apply(small_frame)

        # Remove shadows (value 127 in MOG2)
        _, thresh = cv2.threshold(fgmask, 200, 255, cv2.THRESH_BINARY)
        kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3))
        thresh = cv2.morphologyEx(thresh, cv2.MORPH_OPEN, kernel)

        # Connected components
        num_labels, labels, stats, centroids = cv2.connectedComponentsWithStats(thresh, connectivity=8)

        detections = []
        det_id_num = 0
        for i in range(1, num_labels):
            area = stats[i, cv2.CC_STAT_AREA]
            if area < 20:  # noise filter
                continue
            x = stats[i, cv2.CC_STAT_LEFT] / float(scaled_w)
            y = stats[i, cv2.CC_STAT_TOP] / float(scaled_h)
            w = stats[i, cv2.CC_STAT_WIDTH] / float(scaled_w)
            h = stats[i, cv2.CC_STAT_HEIGHT] / float(scaled_h)

            x = max(0.0, min(1.0 - 1e-6, x))
            y = max(0.0, min(1.0 - 1e-6, y))
            w = max(1e-6, min(1.0 - x, w))
            h = max(1e-6, min(1.0 - y, h))

            detections.append({
                "id": f"d{det_id_num}",
                "bbox": [x, y, w, h],
            })
            det_id_num += 1

        t_ms = int(math.floor(1000.0 * (frame_idx / fps) + 0.5))
        try:
            tracker.feed({
                "camera_id": camera_id,
                "unit_id": unit_id,
                "seq": frame_idx,
                "t_ms": t_ms,
                "detections": detections,
            })
        except Exception as ex:
            emit_event({
                "event": "error",
                "frame": frame_idx,
                "error": str(ex),
            })
            break

        frame_idx += 1
        if frame_idx % 30 == 0:
            emit_event({
                "event": "progress",
                "frame": frame_idx,
                "total_frames": total_frames,
                "active_tracks": len(tracker.active_tracks),
            })

    cap.release()
    tracker.finish()
    episodes = tracker.drain()
    elapsed = time.perf_counter() - t_start

    emit_event({
        "event": "complete",
        "status": "completed",
        "file_hash": file_hash,
        "processed_frames": frame_idx,
        "elapsed_seconds": round(elapsed, 2),
        "tracks_count": len(episodes),
        "tracks": episodes,
    })


def main() -> None:
    parser = argparse.ArgumentParser(description="Recording tracking analysis")
    parser.add_argument("--input", required=True, help="Path to video or recording file")
    parser.add_argument("--camera-id", default="cam-analysis", help="Camera ID")
    parser.add_argument("--unit-id", default="unit-analysis", help="Unit ID")
    args = parser.parse_args()

    analyze_recording(args.input, args.camera_id, args.unit_id)


if __name__ == "__main__":
    main()
