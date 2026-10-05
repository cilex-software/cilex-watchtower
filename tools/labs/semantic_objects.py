#!/usr/bin/env python3
"""Stage-3 local semantic analysers for Cilex Watchtower Labs.

Two separately identifiable, separately versioned capabilities that share one
decode+inference pass (RESULT_FORMAT.md allows a combined pipeline to say so):

  * ``semantic_object`` (s3-1) — person / car / dog / bag / scooter boxes with
    confidence, on ACTUAL decoded presentation timestamps.
  * ``object_colour``   (s3-1) — one dominant broad colour per explicitly named
    region of the SAME detected object: ``vehicle_body``, ``clothing``,
    ``upper_clothing``, ``lower_clothing``; ``unknown`` when the pixels will not
    support a claim.

Both are LOCAL and experimental. Nothing here talks to a network service, and no
frame, crop or recording leaves this machine.

WHAT THIS MODULE DELIBERATELY DOES NOT KNOW. It never reads dataset.json,
inputs.json, a filename, a clip identifier or a hash to decide what to report.
The only inputs to a prediction are decoded pixels and the effective
configuration recorded in the run. Target assessment lives in a separate module
(`stage3_checklist.py`) which runs AFTER inference, exactly as PROTOCOL.md
requires.

TIMESTAMPS. `frame_pts_ms` is the decoded presentation timestamp minus the first
decoded frame's, taken from ffmpeg's own `showinfo` output — never
`frame_index / average_fps` and never a filename time. These clips have
`r_frame_rate` 20/1 against `avg_frame_rate` 7960/529 (dataset.json), so a rate
assumption would be wrong; gaps and jumps are preserved and reported.
`frame_index` counts decoded frames in presentation order, BEFORE inference
sampling, so a reviewer can tie an observation back to the stream.

MODELS. Detection weights are a local pretrained COCO checkpoint; the colour
sampler is unweighted pixel statistics (hence `reason_no_weights`). Source,
version, licence and SHA-256 are recorded in every run document and in
`model_manifest()`. A missing weights file is a PREREQUISITE FAILURE with its own
error code, never a completed run with no detections.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

RUN_SCHEMA = 1
OBJECT_ANALYSER = {"id": "semantic_object", "version": "s3-1"}
COLOUR_ANALYSER = {"id": "object_colour", "version": "s3-1"}
PIPELINE_ID = "semantic_object+object_colour"
PIPELINE_VERSION = "s3-1"

#: RESULT_FORMAT.md class vocabulary.
CLASSES = ("person", "car", "dog", "bag", "scooter", "other")
REGIONS = ("vehicle_body", "clothing", "upper_clothing", "lower_clothing")
COLOURS = ("black", "dark_gray", "white", "light_gray", "red", "blue", "brown",
           "pink", "green", "yellow", "orange", "unknown")

#: COCO name -> this contract's class. Vehicle and animal look-alikes are NOT
#: folded into `car`: RESULT_FORMAT.md forbids relabelling truck/bus/motorcycle
#: as car to satisfy a target, so they surface as `other` with `native_class`.
COCO_MAP = {
    "person": "person", "car": "car", "dog": "dog", "cat": "other",
    "backpack": "bag", "handbag": "bag", "suitcase": "bag", "skateboard": "scooter",
    "motorcycle": "other", "bicycle": "other", "truck": "other", "bus": "other",
    "train": "other", "bench": "other", "horse": "other", "sheep": "other",
    "cow": "other", "elephant": "other", "bear": "other", "zebra": "other",
    "giraffe": "other", "bird": "other",
}
DEFAULT_KEEP = ("person", "car", "dog", "bag", "scooter")

MODEL_DIR_ENV = "WT_LABS_MODEL_DIR"


def _default_model_dir() -> str:
    """Weights live outside the repository. Prefer an explicit override, then an
    existing XDG cache dir, then ~/.cache -- so an isolated XDG_CACHE_HOME (the
    documented way to launch a development instance) still finds weights that
    were installed under the real one."""
    env = os.environ.get(MODEL_DIR_ENV)
    if env:
        return env
    cands = []
    xdg = os.environ.get("XDG_CACHE_HOME")
    if xdg:
        cands.append(os.path.join(xdg, "watchtower-labs-models"))
    cands.append(os.path.join(os.path.expanduser("~"), ".cache", "watchtower-labs-models"))
    for c in cands:
        if os.path.isdir(c):
            return c
    return cands[0]


DEFAULT_MODEL_DIR = _default_model_dir()

#: Weights this analyser knows how to use, with provenance for the submission
#: report. `licence` is disclosed, not adjudicated: AGPL-3.0 carries obligations
#: if the product is ever distributed, and that decision belongs to the operator.
KNOWN_MODELS = {
    "yolo11n": {
        "name": "ultralytics/yolo11n (COCO pretrained)",
        "file": "yolo11n.pt",
        "url": "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11n.pt",
        "sha256": "0ebbc80d4a7680d14987a577cd21342b65ecfd94632bd9a8da63ae6417644ee1",
        "licence": "AGPL-3.0 (weights and ultralytics runtime)",
        "classes": "COCO 80",
    },
    "yolo11s": {
        "name": "ultralytics/yolo11s (COCO pretrained)",
        "file": "yolo11s.pt",
        "url": "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11s.pt",
        "sha256": "85a76fe86dd8afe384648546b56a7a78580c7cb7b404fc595f97969322d502d5",
        "licence": "AGPL-3.0 (weights and ultralytics runtime)",
        "classes": "COCO 80",
    },
}

_stop = {"flag": False}


def _on_term(_sig, _frm):
    _stop["flag"] = True


def _say(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=True, allow_nan=False,
                                separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _fail(code: str, message: str) -> int:
    _say({"kind": "error", "code": code, "message": message})
    return 3


def _detach_stdin() -> None:
    """ffmpeg reads stdin for interactive keys; an inherited pipe that never
    reaches EOF makes it block until its own timeout (measured on this box)."""
    try:
        fd = os.open(os.devnull, os.O_RDONLY)
        if fd != 0:
            os.dup2(fd, 0)
            os.close(fd)
    except OSError:
        pass


def sha256_file(path: str, limit: int | None = None) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
            if limit is not None and h.digest_size and f.tell() >= limit:
                break
    return h.hexdigest()


def model_manifest() -> dict:
    """Provenance for every weight file this analyser can use, with the hash
    actually on disk now (None when absent, so a missing prerequisite is visible
    rather than assumed)."""
    d = os.environ.get(MODEL_DIR_ENV) or DEFAULT_MODEL_DIR
    out = {"model_dir": d, "models": {}}
    for key, info in KNOWN_MODELS.items():
        p = os.path.join(d, info["file"])
        out["models"][key] = dict(info, path=p, present=os.path.isfile(p),
                                  bytes=os.path.getsize(p) if os.path.isfile(p) else None,
                                  sha256_on_disk=sha256_file(p) if os.path.isfile(p) else None)
    return out


# ---------------------------------------------------------------------------
# decoding: real PTS, real pixels
# ---------------------------------------------------------------------------
_SHOWINFO = re.compile(rb"n:\s*(\d+)\s+pts:\s*(\S+)\s+pts_time:([0-9.+-]+)")
_SIZE = re.compile(rb"s:(\d+)x(\d+)")


def probe_media(path: str, ffmpeg: str = "ffmpeg") -> dict:
    """Container facts, labelled as container facts (not a decode census)."""
    out = subprocess.run(["ffprobe", "-v", "error", "-print_format", "json",
                          "-show_format", "-show_streams", path],
                         capture_output=True, timeout=60, stdin=subprocess.DEVNULL)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.decode("utf-8", "replace")[:300])
    info = json.loads(out.stdout.decode())
    v = next((s for s in info.get("streams", []) if s.get("codec_type") == "video"), {})
    fmt = info.get("format", {})
    return {"container_duration_s": float(fmt.get("duration") or 0.0),
            "width": int(v.get("width") or 0), "height": int(v.get("height") or 0),
            "codec": v.get("codec_name"), "pix_fmt": v.get("pix_fmt"),
            "r_frame_rate": v.get("r_frame_rate"), "avg_frame_rate": v.get("avg_frame_rate"),
            "nb_frames": v.get("nb_frames"), "start_time": v.get("start_time"),
            "measurement": "ffprobe container metadata, not a full-decode census"}


def iter_decoded(path: str, decode_width: int | None, ffmpeg: str = "ffmpeg"):
    """Yield `(frame_index, pts_ms, bgr)` for EVERY decoded frame.

    `pts_ms` is the frame's own presentation time minus the first decoded
    frame's, in milliseconds. `decode_width` rescales inside ffmpeg (declared in
    the run config) so a 1440p stream does not push 11 MB per frame through the
    pipe; normalized boxes are unaffected by that scaling and the scale is
    recorded so a reviewer can reproduce it.
    """
    vf = (f"scale={int(decode_width)}:-2,showinfo" if decode_width else "showinfo")
    cmd = [ffmpeg, "-hide_banner", "-nostats", "-loglevel", "info", "-i", path,
           "-an", "-fps_mode", "passthrough", "-vf", vf, "-f", "rawvideo",
           "-pix_fmt", "bgr24", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            stdin=subprocess.DEVNULL, bufsize=1 << 20)
    import threading
    import queue
    errq: queue.Queue = queue.Queue()

    def _drain():
        for line in proc.stderr:
            errq.put(line)
    threading.Thread(target=_drain, daemon=True).start()

    first_pts = None
    index = 0
    w = h = None
    pending: list[tuple[int, float]] = []
    frame_bytes = None

    def _next_meta():
        while True:
            try:
                line = errq.get(timeout=0.05)
            except queue.Empty:
                if proc.poll() is not None and errq.empty():
                    return None
                continue
            m = _SHOWINFO.search(line)
            if m:
                return line, m
            if proc.poll() is not None and errq.empty():
                return None

    while True:
        got = _next_meta()
        if got is None:
            break
        line, m = got
        if w is None:
            sm = _SIZE.search(line)
            if sm:
                w, h = int(sm.group(1)), int(sm.group(2))
                frame_bytes = w * h * 3
        if frame_bytes is None:
            continue
        pts_time = float(m.group(3))
        buf = proc.stdout.read(frame_bytes)
        if buf is None or len(buf) < frame_bytes:
            break
        if first_pts is None:
            first_pts = pts_time
        import numpy as np
        img = np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 3)
        yield index, int(round((pts_time - first_pts) * 1000.0)), img
        index += 1
        if _stop["flag"]:
            break
    try:
        proc.stdout.close()
        proc.wait(timeout=10)
    except Exception:                                    # noqa: BLE001
        proc.kill()


# ---------------------------------------------------------------------------
# colour: unweighted, region-scoped, and willing to say unknown
# ---------------------------------------------------------------------------
def region_box_norm(cls: str, region: str, x: float, y: float, w: float, h: float):
    """The normalized sub-box the colour sampler actually inspects.

    Documented geometry, not a guess: for a person the head is excluded from
    every clothing region, `upper_clothing` is the torso band, `lower_clothing`
    the leg band and `clothing` both; for a vehicle the body band excludes the
    top (sky/roof highlight) and the bottom (road, shadow, wheels).
    """
    if cls in ("car", "truck", "bus") or region == "vehicle_body":
        return (x + 0.08 * w, y + 0.25 * h, x + 0.92 * w, y + 0.85 * h)
    if region == "upper_clothing":
        return (x + 0.22 * w, y + 0.22 * h, x + 0.78 * w, y + 0.55 * h)
    if region == "lower_clothing":
        return (x + 0.25 * w, y + 0.55 * h, x + 0.75 * w, y + 0.92 * h)
    if region == "clothing":
        return (x + 0.18 * w, y + 0.22 * h, x + 0.82 * w, y + 0.92 * h)
    return (x, y, x + w, y + h)


MIN_COLOUR_PIXELS = 200


def sample_region_colour(bgr, box_norm, min_pixels: int = MIN_COLOUR_PIXELS):
    """`(label, confidence, stats)` for one region of one detection.

    The 5th-95th percentile trim on each channel is what keeps a background
    sliver, a shadow edge or a strap from carrying the vote; the label rules are
    broad by design (CASES.md accepts black OR dark_gray for "dark", white OR
    light_gray for "light"), and anything the pixels do not support returns
    `unknown` rather than a guess. Confidence is a rule margin plus pixel
    agreement -- it is NOT calibrated and the run says so.
    """
    import cv2
    import numpy as np
    H, W = bgr.shape[:2]
    x0 = int(max(0, min(box_norm[0] * W, W - 1)))
    x1 = int(max(x0 + 1, min(box_norm[2] * W, W)))
    y0 = int(max(0, min(box_norm[1] * H, H - 1)))
    y1 = int(max(y0 + 1, min(box_norm[3] * H, H)))
    crop = bgr[y0:y1, x0:x1]
    stats = {"region_box_norm": [round(float(v), 5) for v in box_norm],
             "pixels": int(crop.shape[0] * crop.shape[1])}
    if crop.size == 0 or crop.shape[0] < 4 or crop.shape[1] < 4 or stats["pixels"] < min_pixels:
        stats["why"] = "too few pixels in the stated region"
        return "unknown", 0.0, stats
    hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV).reshape(-1, 3).astype("float32")
    hh, ss, vv = hsv[:, 0], hsv[:, 1] / 255.0, hsv[:, 2] / 255.0

    def trim(a):
        lo, hi = np.percentile(a, [5, 95])
        m = (a >= lo) & (a <= hi)
        return a[m] if int(m.sum()) >= 30 else a

    ht, st, vt = trim(hh), trim(ss), trim(vv)
    S = float(np.median(st))
    V = float(np.median(vt))
    rad = ht * (2.0 * math.pi / 180.0)
    Hm = float((math.degrees(math.atan2(float(np.mean(np.sin(rad))),
                                        float(np.mean(np.cos(rad))))) / 2.0) % 180.0)
    # agreement: the share of region pixels that fall in the same broad bucket
    def bucket(h, s, v):
        if v < 0.16: return "black"
        if v < 0.38 and s < 0.35: return "dark_gray"
        if s >= 0.30 and v >= 0.15 and (h < 10 or h > 168): return "red"
        if v >= 0.78 and s <= 0.18: return "white"
        if v >= 0.55 and s <= 0.20: return "light_gray"
        return "other"
    votes = {}
    for h_i, s_i, v_i in zip(hh[::7], ss[::7], vv[::7]):
        b = bucket(float(h_i), float(s_i), float(v_i))
        votes[b] = votes.get(b, 0) + 1
    tot = max(1, sum(votes.values()))
    stats.update({"H": round(Hm, 1), "S": round(S, 3), "V": round(V, 3),
                  "V_p10": round(float(np.percentile(vv, 10)), 3),
                  "V_p90": round(float(np.percentile(vv, 90)), 3),
                  "bucket_shares": {k: round(v / tot, 3) for k, v in sorted(votes.items())}})

    label, conf = "unknown", 0.2
    if V < 0.16:
        label, conf = "black", min(1.0, 0.55 + (0.16 - V) * 2.0)
    elif V < 0.38 and S < 0.35:
        label, conf = "dark_gray", min(1.0, 0.45 + (0.38 - V) * 1.5 + S * 0.2)
    elif S >= 0.30 and V >= 0.15 and (Hm < 10 or Hm > 168):
        label, conf = "red", min(1.0, 0.45 + S * 0.6)
    elif S >= 0.35 and 10 <= Hm < 22:
        label, conf = "orange", min(1.0, 0.4 + S * 0.5)
    elif S >= 0.30 and 22 <= Hm < 36:
        label, conf = "yellow", min(1.0, 0.4 + S * 0.5)
    elif S >= 0.18 and 36 <= Hm < 85:
        label, conf = "green", min(1.0, 0.4 + S * 0.5)
    elif S >= 0.18 and 85 <= Hm < 135:
        label, conf = "blue", min(1.0, 0.4 + S * 0.5)
    elif S >= 0.15 and Hm >= 135 and V >= 0.55:
        label, conf = "pink", min(1.0, 0.4 + S * 0.5)
    elif S >= 0.15 and 10 <= Hm < 26 and V < 0.55:
        label, conf = "brown", min(1.0, 0.35 + S * 0.5)
    elif V >= 0.78 and S <= 0.18:
        label, conf = "white", min(1.0, 0.5 + (V - 0.78) * 2.0)
    elif V >= 0.55 and S <= 0.20:
        label, conf = "light_gray", min(1.0, 0.4 + (V - 0.55) * 1.5)
    else:
        stats["why"] = "hue/saturation/value between the broad buckets"
    agree = votes.get(label, 0) / tot if label in votes else 0.0
    conf = max(0.0, min(1.0, 0.6 * conf + 0.4 * agree)) if label != "unknown" else round(0.2 * (1 - agree), 3)
    stats["agreement"] = round(agree, 3)
    return label, round(conf, 4), stats


# ---------------------------------------------------------------------------
# detector backend
# ---------------------------------------------------------------------------
class Detector:
    """One local pretrained detector. Backend is pluggable so a permissively
    licensed checkpoint can replace the default without touching the analyser."""

    def __init__(self, backend: str, weights: str, imgsz: int, conf: float, device: str):
        self.backend = backend
        self.weights = weights
        self.imgsz = int(imgsz)
        self.conf = float(conf)
        self.device = device
        self.names: dict = {}
        self._impl = None
        self.load_ms = None

    def open(self) -> None:
        t0 = time.perf_counter()
        if self.backend == "yolo11":
            try:
                from ultralytics import YOLO
            except ImportError as e:
                raise PrerequisiteError(
                    "model_runtime_missing",
                    f"the ultralytics runtime is not importable in this interpreter: {e}. "
                    "This analyser needs it for the yolo11 backend; install it in an isolated "
                    "environment or select another backend.") from e
            if not os.path.isfile(self.weights):
                raise PrerequisiteError(
                    "model_weights_missing",
                    f"weights not found at {self.weights}. Expected SHA-256 "
                    f"{KNOWN_MODELS.get(os.path.basename(self.weights)[:-3], {}).get('sha256', '?')}; "
                    "download them once into the model directory (see model_manifest()). "
                    "A missing model is a prerequisite failure, not a no-detection result.")
            self._impl = YOLO(self.weights)
            self.names = {int(k): v for k, v in (self._impl.names or {}).items()}
        elif self.backend == "none":
            raise PrerequisiteError("model_backend_disabled",
                                    "backend 'none' was selected: no detector is available")
        else:
            raise PrerequisiteError("model_backend_unknown",
                                    f"unknown detector backend {self.backend!r}")
        self.load_ms = round((time.perf_counter() - t0) * 1000.0, 1)

    def detect(self, bgr) -> list[dict]:
        """`[{native_class, class, confidence, bbox_norm}]` in the frame's own
        normalized coordinates, mapped through COCO_MAP; suppressed natives are
        not returned at all (recorded in config instead)."""
        r = self._impl.predict(bgr, imgsz=self.imgsz, conf=self.conf,
                               verbose=False, device=self.device)[0]
        h, w = bgr.shape[:2]
        out = []
        for b in r.boxes:
            native = r.names[int(b.cls[0])]
            mapped = COCO_MAP.get(native, "other")
            x0, y0, x1, y1 = [float(v) for v in b.xyxy[0].tolist()]
            bw = (x1 - x0) / w
            bh = (y1 - y0) / h
            if bw <= 0 or bh <= 0:
                continue
            out.append({"native_class": native, "class": mapped,
                        "confidence": round(min(1.0, max(0.0, float(b.conf[0]))), 5),
                        "bbox_norm": [round(max(0.0, x0 / w), 6), round(max(0.0, y0 / h), 6),
                                      round(min(1.0, bw), 6), round(min(1.0, bh), 6)]})
        return out


class PrerequisiteError(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


# ---------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------
def whole_second_schedule(times_ms: list[int]) -> list[int]:
    """CASES.md's predeclared annotation schedule: the first decoded frame at or
    after each whole second relative to the first decoded frame, deduplicated.
    Returns indices into `times_ms`."""
    picks, seen, k = [], set(), 0
    if not times_ms:
        return picks
    total_s = times_ms[-1] // 1000
    for s in range(0, total_s + 1):
        want = s * 1000
        while k < len(times_ms) and times_ms[k] < want:
            k += 1
        if k >= len(times_ms):
            break
        if times_ms[k] not in seen:
            seen.add(times_ms[k])
            picks.append(k)
    return picks


def analyse(args) -> int:
    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)
    t_start = time.perf_counter()
    if not os.path.isfile(args.input):
        return _fail("input_missing", f"no such recording: {args.input}")
    try:
        media = probe_media(args.input)
    except Exception as e:                                     # noqa: BLE001
        return _fail("probe_failed", f"could not probe {args.input}: {e}")
    if media["width"] <= 0 or media["height"] <= 0:
        return _fail("no_video_stream", f"{args.input} has no video stream")

    import cv2
    import numpy as np

    det = Detector(args.det_backend, args.det_weights, args.imgsz, args.conf, args.device)
    try:
        det.open()
    except PrerequisiteError as e:
        return _fail(e.code, str(e))

    want_classes = tuple(c.strip() for c in args.classes.split(",") if c.strip()) or DEFAULT_KEEP
    suppressed: dict[str, int] = {}
    cfg = {
        "det_backend": args.det_backend, "det_weights": os.path.abspath(args.det_weights),
        "imgsz": det.imgsz, "conf_threshold": det.conf, "device": args.device,
        "decode_width": args.decode_width, "decode_height_actual": None,
        "source_width": media["width"], "source_height": media["height"],
        "sampling": args.schedule, "sample_fps": args.sample_fps, "max_inference_frames": args.max_frames,
        "classes_emitted": list(want_classes),
        "native_classes_suppressed": [k for k, v in COCO_MAP.items() if v not in want_classes],
        "colour_regions": {"person": ["upper_clothing", "clothing", "lower_clothing"],
                           "vehicle": ["vehicle_body"]},
        "colour_method": "HSV trimmed-median rules (5th-95th percentile), unweighted",
        "confidence_note": "detector score and colour rule margin x pixel agreement; not calibrated",
        "bbox_normalization": "full source frame; detector resize/letterbox undone by the backend",
        "tracking": {"engine": "tools/labs/temporal_tracks.py (Stage 1)", "enabled": not args.no_tracks,
                     "config": None},
        "seed": None, "nondeterminism": "CPU inference is deterministic for fixed weights, "
                                        "threads and input; no RNG is used",
    }

    # ---- pass 1: decode every frame, keep the schedule's frames for inference
    times: list[int] = []
    frames: dict[int, object] = {}
    decoded = 0
    gaps: list[dict] = []
    prev_pts = None
    schedule_idx: list[int] = []
    two_pass = args.schedule == "whole-second"
    if two_pass:
        # The schedule is defined on DECODED frame times, so the times must be
        # known before choosing frames: a cheap metadata pass, then the real one.
        for index, pts_ms, _img in iter_decoded(args.input, args.decode_width):
            times.append(pts_ms)
            decoded += 1
            if prev_pts is not None and pts_ms - prev_pts > 1500:
                gaps.append({"after_frame_index": index - 1, "from_ms": prev_pts, "to_ms": pts_ms})
            prev_pts = pts_ms
            if args.max_frames and decoded >= args.max_frames * 40:
                break
        schedule_idx = whole_second_schedule(times)
        keep = set(schedule_idx)
    else:
        keep = None

    observations: list[dict] = []
    crops_written = 0
    infer_frames = 0
    missing_requested: list[int] = []
    step = max(1, int(round(args.sample_fps and (1.0 / args.sample_fps) or 1))) if args.schedule != "whole-second" else 1
    fps_hint = None
    try:
        num, den = (media.get("avg_frame_rate") or "0/1").split("/")
        fps_hint = float(num) / float(den) if float(den) else None
    except Exception:                                          # noqa: BLE001
        fps_hint = None
    if args.schedule != "whole-second" and fps_hint:
        step = max(1, int(round(fps_hint / max(0.1, args.sample_fps))))

    tr = None
    if not args.no_tracks:
        try:
            from temporal_tracks import Tracker
            tr = Tracker(args.camera_id or "stage3-local", args.unit_id or "labs-semantic",
                         json.loads(args.track_config) if args.track_config else None)
            cfg["tracking"]["config"] = tr.config
        except Exception as e:                                 # noqa: BLE001
            cfg["tracking"]["enabled"] = False
            cfg["tracking"]["error"] = f"{type(e).__name__}: {e}"
            tr = None

    os.makedirs(args.evidence_dir, exist_ok=True)
    obs_seq = 0
    track_seq = 0
    second_pass_times = []
    for index, pts_ms, img in iter_decoded(args.input, args.decode_width):
        if _stop["flag"]:
            break
        if not two_pass:
            times.append(pts_ms)
            decoded += 1
            if prev_pts is not None and pts_ms - prev_pts > 1500:
                gaps.append({"after_frame_index": index - 1, "from_ms": prev_pts, "to_ms": pts_ms})
            prev_pts = pts_ms
            do_infer = (index % step == 0)
        else:
            do_infer = index in keep
        if cfg["decode_height_actual"] is None:
            cfg["decode_height_actual"] = int(img.shape[0])
        if not do_infer:
            continue
        if two_pass and pts_ms != times[index]:
            missing_requested.append(index)
            continue
        if infer_frames >= args.max_frames:
            break
        infer_frames += 1
        dets = det.detect(img)
        batch_dets = []
        for d in dets:
            if d["class"] not in want_classes:
                suppressed[d["native_class"]] = suppressed.get(d["native_class"], 0) + 1
                continue
            batch_dets.append(d)
        # one tracker batch per analysed frame, so track ids follow real time
        assign: dict[str, str | None] = {}
        if tr is not None and batch_dets:
            try:
                det_list = [{"id": f"d{i}", "bbox": d["bbox_norm"][:2] + d["bbox_norm"][2:]}
                            for i, d in enumerate(batch_dets)]
                rec = tr.feed({"camera_id": args.camera_id or "stage3-local",
                               "unit_id": args.unit_id or "labs-semantic",
                               "seq": track_seq, "t_ms": pts_ms, "detections": det_list})
                track_seq += 1
                for a in rec["assignments"]:
                    assign[a["detection_id"]] = a["track_id"]
            except Exception as e:                             # noqa: BLE001
                cfg["tracking"]["error"] = f"{type(e).__name__}: {e}"
                cfg["tracking"]["enabled"] = False
                tr = None
        for i, d in enumerate(batch_dets):
            obs_seq += 1
            oid = f"o{obs_seq:06d}"
            x, y, bw, bh = d["bbox_norm"]
            colours = []
            colour_evidence = []
            regions = (["vehicle_body"] if d["class"] == "car"
                       else ["upper_clothing", "clothing", "lower_clothing"]
                       if d["class"] == "person" else [])
            for reg in regions:
                rb = region_box_norm(d["class"], reg, x, y, bw, bh)
                lab, conf, stats = sample_region_colour(img, rb)
                colours.append({"region": reg, "label": lab, "confidence": conf})
                colour_evidence.append({"region": reg, "label": lab, "confidence": conf, **stats})
            ob = {"id": oid, "frame_index": index, "frame_pts_ms": pts_ms,
                  "class": d["class"], "confidence": d["confidence"],
                  "bbox_xywh": [round(x, 6), round(y, 6), round(bw, 6), round(bh, 6)],
                  "colors": colours,
                  "native_class": d["native_class"],
                  "color_evidence": colour_evidence}
            tid = assign.get(f"d{i}")
            if tid:
                ob["track_id"] = tid
            if args.crops and bw * bh >= args.crop_min_area:
                H, W = img.shape[:2]
                x0, y0 = int(x * W), int(y * H)
                x1, y1 = int((x + bw) * W), int((y + bh) * H)
                crop = img[max(0, y0):max(1, y1), max(0, x0):max(1, x1)]
                if crop.size:
                    name = f"{args.clip_id}_{index:06d}_{oid}_{d['class']}.jpg"
                    cv2.imwrite(os.path.join(args.evidence_dir, name), crop)
                    ob["crop"] = {"file": name, "sha256": None}
                    crops_written += 1
            observations.append(ob)
        if infer_frames % 5 == 0 or infer_frames == 1:
            pct = int(100.0 * pts_ms / max(1, times[-1] if times else 1)) if not two_pass else \
                  int(100.0 * (schedule_idx.index(index) + 1) / max(1, len(schedule_idx))) if index in schedule_idx else 0
            _say({"kind": "progress", "decoded": decoded, "inferred": infer_frames,
                  "observations": len(observations), "pts_ms": pts_ms, "percent": min(99, pct)})
    if tr is not None:
        try:
            tr.finish()
            tr.drain()
        except Exception:                                      # noqa: BLE001
            pass

    cancelled = _stop["flag"]
    elapsed_ms = round((time.perf_counter() - t_start) * 1000.0, 1)
    import resource                                  # Unix-only: imported here, not at module top
    peak_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    peak_rss_bytes = peak_rss * 1024 if sys.platform != "darwin" else peak_rss
    pts_increasing = all(a < b for a, b in zip(times, times[1:]))
    run = {
        "schema_version": RUN_SCHEMA,
        "run_id": args.run_id,
        "clip_id": args.clip_id,
        "input_sha256": sha256_file(args.input),
        "source_revision": args.source_revision or "unknown",
        "source_revision_dirty": bool(args.source_revision_dirty),
        "analyser": {"id": PIPELINE_ID, "version": PIPELINE_VERSION,
                     "capabilities": [dict(OBJECT_ANALYSER), dict(COLOUR_ANALYSER)],
                     "note": "object detection and object colour share one decode+inference pass"},
        "model": {"name": KNOWN_MODELS.get(os.path.splitext(os.path.basename(args.det_weights))[0],
                                           {}).get("name", os.path.basename(args.det_weights)),
                  "weights_sha256": _weights_hash(args.det_weights),
                  "backend": args.det_backend,
                  "source": KNOWN_MODELS.get(os.path.splitext(os.path.basename(args.det_weights))[0],
                                             {}).get("url"),
                  "licence": KNOWN_MODELS.get(os.path.splitext(os.path.basename(args.det_weights))[0],
                                              {}).get("licence", "unknown"),
                  "reason_no_weights": None},
        "colour_model": {"name": "HSV trimmed-median region rules (object_colour s3-1)",
                         "weights_sha256": None,
                         "reason_no_weights": "unweighted pixel statistics; no learned parameters"},
        "config": cfg,
        "status": "cancelled" if cancelled else "completed",
        "observations": observations,
        "errors": [],
        "measurements": {
            "elapsed_ms": elapsed_ms,
            "model_load_ms": det.load_ms,
            "peak_rss_bytes": int(peak_rss_bytes),
            "peak_rss_method": "resource.getrusage(RUSAGE_SELF).ru_maxrss (process peak, not end-minus-start)",
            "decoded_frame_count": decoded,
            "inference_frame_count": infer_frames,
            "observations": len(observations),
            "crops_written": crops_written,
            "suppressed_native_classes": suppressed,
            "pts_strictly_increasing": pts_increasing,
            "timing_gaps_over_1500ms": gaps,
            "missing_requested_frames": missing_requested,
            "first_pts_ms": times[0] if times else None,
            "last_pts_ms": times[-1] if times else None,
            "hardware": {"cpu_count": os.cpu_count(),
                         "loadavg": list(os.getloadavg()) if hasattr(os, "getloadavg") else None,
                         "gpu": None},
            "runtime": {"python": sys.version.split()[0], "opencv": cv2.__version__,
                        "numpy": np.__version__},
        },
        "details": {
            "schema_name": "watchtower-stage3-run/v1",
            "input_path": os.path.abspath(args.input),
            "media": media,
            # Every decoded frame's presentation time, so the reviewer (and the
            # overlay) can place an observation on its exact source frame window
            # instead of guessing a frame rate.
            "frame_times_ms": times,
            "evidence_dir": os.path.abspath(args.evidence_dir),
            "schedule": args.schedule,
            "requested_frames": len(schedule_idx) if two_pass else None,
            "started_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        },
    }
    if cancelled:
        run["errors"] = []           # a cancelled run is honest by status, not by errors
    if not pts_increasing:
        run["measurements"]["timing_warning"] = "decoded PTS did not increase monotonically"
    with open(args.out_run, "w", encoding="utf-8") as f:
        json.dump(run, f, ensure_ascii=True, allow_nan=False)
    _say({"kind": "result", "status": run["status"], "run_path": os.path.abspath(args.out_run),
          "run_id": run["run_id"], "clip_id": run["clip_id"],
          "input_sha256": run["input_sha256"],
          "counts": {"decoded": decoded, "inferred": infer_frames, "observations": len(observations),
                     "by_class": _by_class(observations), "crops": crops_written},
          "measurements": {k: run["measurements"][k] for k in
                           ("elapsed_ms", "model_load_ms", "peak_rss_bytes", "decoded_frame_count",
                            "inference_frame_count")},
          "timing_gaps": len(gaps)})
    return 130 if cancelled else 0


def _weights_hash(path: str) -> str | None:
    try:
        return sha256_file(path)
    except OSError:
        return None


def _by_class(obs) -> dict:
    out: dict[str, int] = {}
    for o in obs:
        out[o["class"]] = out.get(o["class"], 0) + 1
    return out


def cmd_manifest(_args) -> int:
    _say({"kind": "manifest", "analysers": [dict(OBJECT_ANALYSER), dict(COLOUR_ANALYSER)],
          "pipeline": {"id": PIPELINE_ID, "version": PIPELINE_VERSION},
          "classes": list(CLASSES), "regions": list(REGIONS), "colours": list(COLOURS),
          "model_dir": model_manifest()["model_dir"],
          "models": model_manifest()["models"]})
    return 0


def main(argv=None) -> int:
    _detach_stdin()
    ap = argparse.ArgumentParser(prog="semantic_objects",
                                 description="Stage-3 local semantic object and colour analysers")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("manifest")
    a = sub.add_parser("analyze")
    a.add_argument("--input", required=True)
    a.add_argument("--clip-id", required=True)
    a.add_argument("--run-id", required=True)
    a.add_argument("--out-run", required=True)
    a.add_argument("--evidence-dir", required=True)
    a.add_argument("--source-revision", default="")
    a.add_argument("--source-revision-dirty", action="store_true")
    a.add_argument("--camera-id", default="")
    a.add_argument("--unit-id", default="")
    a.add_argument("--det-backend", default="yolo11")
    a.add_argument("--det-weights", default="")
    a.add_argument("--imgsz", type=int, default=640)
    a.add_argument("--conf", type=float, default=0.35,
                    help="detector confidence floor; 0.35 chosen from the probe: at 0.25 the model"
                         " reports benches, posts and luggage as person/car")
    a.add_argument("--device", default="cpu")
    a.add_argument("--decode-width", type=int, default=1280)
    a.add_argument("--schedule", choices=("adaptive", "whole-second"), default="adaptive")
    a.add_argument("--sample-fps", type=float, default=2.0)
    a.add_argument("--max-frames", type=int, default=400)
    a.add_argument("--classes", default=",".join(DEFAULT_KEEP))
    a.add_argument("--crops", action="store_true")
    a.add_argument("--crop-min-area", type=float, default=0.0004)
    a.add_argument("--no-tracks", action="store_true")
    a.add_argument("--track-config", default="")
    args = ap.parse_args(argv)
    if args.cmd == "manifest":
        return cmd_manifest(args)
    if not args.det_weights:
        d = os.environ.get(MODEL_DIR_ENV) or DEFAULT_MODEL_DIR
        args.det_weights = os.path.join(d, "yolo11n.pt")
    return analyse(args)


if __name__ == "__main__":
    sys.exit(main())
