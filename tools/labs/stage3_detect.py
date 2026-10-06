#!/usr/bin/env python3
"""Stage 3 analyser run: one recording -> semantic object and colour observations.

WHAT THIS IS. The new Labs analysers. It decodes a recording with one ffmpeg
pass (frames AND their own presentation timestamps), runs a local COCO detector
over sampled decoded frames, samples object-linked broad colours from the pixels
of a named region of each detected object, links detections into local track
references, and writes a Stage 3 result contract run.

WHAT IT DELIBERATELY NEVER READS: `dataset.json`, filenames, clip ids or any
expected-target list. Pixels in, observations out. The target evaluator is a
separate program (`stage3_evaluate.py`) and a separate process, which is the only
place annotation data is loaded.

TIMESTAMPS are the decoder's own `pts_time` per decoded frame -- never
`frame_index / average_fps`, never a filename. `frame_index` is the zero-based
index in decoded presentation order, BEFORE inference sampling, so a sampled
observation still names the frame it came from.

EVIDENCE. Every observation carries its object crop, and every colour carries
the region box and the crop of the pixels that supported it, so the reviewer can
see what was actually measured. Crops are written next to the run.

    stage3_detect.py --job job.json --out RUNDIR
    stage3_detect.py --check-model [--backend NAME]

Exit codes: 0 completed, 1 failed, 3 cancelled (partial evidence kept).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import platform
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cv2                                    # noqa: E402
import numpy as np                            # noqa: E402

import stage3_colour as colour                # noqa: E402
import stage3_models as models                # noqa: E402

VERSION = "stage3-detect/1"
ANALYSER_ID = "stage3-objects-colours"
ANALYSER_VERSION = "1.0.0"
EXIT_OK, EXIT_FAILED, EXIT_CANCELLED = 0, 1, 3

_PTS = queue.Queue()
_STOP = {"asked": False}
#: showinfo logs TWO lines per frame (one with n:/pts_time, one with the pixel
#: format) plus a config line per format change. Only the frame line carries both
#: `n:` and `pts_time:`, and only it may enter the PTS queue: feeding the queue with
#: every showinfo line pairs timestamps with the wrong frames (measured 2026-10-05:
#: a 52.85 s clip read back as 26.25 s, exactly half).
_SHOWINFO_PTS = re.compile(r"\bn:\s*\d+\b.*?\bpts_time:\s*([-+0-9.eE]+)")


def tool(name: str) -> str:
    """Locate ffmpeg/ffprobe: explicit env, then PATH, else a clear failure.

    macOS ships no ffmpeg and the app does not put one on PATH -- the packaged
    build carries its own LGPL ffmpeg inside the bundle -- so the panel passes
    WT_FFMPEG/WT_FFPROBE down to this process. On Linux the PATH binary is what
    the Labs worker already uses.
    """
    override = os.environ.get("WT_%s" % name.upper())
    if override:
        if not os.path.isfile(override):
            raise RuntimeError("WT_%s points at %r, which is not a file"
                               % (name.upper(), override))
        return override
    found = shutil.which(name)
    if not found:
        raise RuntimeError(
            "%s not found. Install it, or point WT_%s at the binary that ships "
            "with Watchtower." % (name, name.upper()))
    return found


def peak_rss_bytes():
    """Peak RSS of THIS process, reported in bytes on every platform.

    `ru_maxrss` is KiB on Linux and BYTES on macOS, so the unit is chosen by
    platform rather than assumed -- assuming KiB on a Mac multiplies the number
    by 1024 and would have been reported as a measured value.
    """
    import resource
    raw = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    if sys.platform == "darwin":
        return raw
    return raw * 1024


def emit(event: dict) -> None:
    sys.stdout.write(json.dumps(event, ensure_ascii=True) + "\n")
    sys.stdout.flush()


def _on_signal(signum, _frame):
    _STOP["asked"] = True


def sha256_file(path: str, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def implementation_identity() -> dict:
    """The ACTUAL revision of the code that produced a run.

    HEAD is recorded as-is; a dirty tree is recorded as dirty, and the analyser
    files' own hashes are stored so the exact code is identifiable even when the
    checkout has not been committed.
    """
    root = pathlib.Path(_HERE).resolve().parents[1]
    info = {"head": "", "dirty": None, "files_sha256": {}}
    try:
        info["head"] = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                                      capture_output=True, text=True,
                                      timeout=20).stdout.strip()
        status = subprocess.run(["git", "-C", str(root), "status", "--porcelain"],
                                capture_output=True, text=True, timeout=20).stdout
        info["dirty"] = bool(status.strip())
    except Exception:                            # noqa: BLE001
        pass
    for name in ("stage3_detect.py", "stage3_colour.py", "stage3_models.py",
                 "stage3_evidence.py"):
        path = pathlib.Path(_HERE) / name
        if path.is_file():
            info["files_sha256"][name] = sha256_file(str(path))
    joined = json.dumps(info["files_sha256"], sort_keys=True).encode("utf-8")
    info["implementation_sha256"] = hashlib.sha256(joined).hexdigest()
    info["source_revision"] = "%s%s" % (info["head"][:12] or "unknown",
                                        "-dirty" if info["dirty"] else "")
    return info


# ----------------------------------------------------------------------------------
# decode: frames and their OWN presentation timestamps
# ----------------------------------------------------------------------------------
def probe(path: str) -> dict:
    out = subprocess.run(
        [tool("ffprobe"), "-v", "error", "-of", "json", "-show_format",
         "-show_streams", path],
        capture_output=True, text=True, timeout=120).stdout
    data = json.loads(out or "{}")
    video = next((s for s in data.get("streams", [])
                  if s.get("codec_type") == "video"), {})
    duration = float(data.get("format", {}).get("duration") or 0.0)
    return {"width": int(video.get("width") or 0), "height": int(video.get("height") or 0),
            "codec": video.get("codec_name"), "duration_ms": int(round(duration * 1000)),
            "r_frame_rate": video.get("r_frame_rate"),
            "avg_frame_rate": video.get("avg_frame_rate"),
            "nb_frames": video.get("nb_frames")}


def scaled_size(path: str, width: int) -> tuple:
    """The exact output size of `scale=width:-2` for this file, from ffmpeg itself."""
    out = subprocess.run(
        [tool("ffprobe"), "-v", "error", "-of", "json", "-show_entries",
         "stream=width,height", "-f", "lavfi",
         "-i", "movie=%s,scale=%d:-2" % (path, width)],
        capture_output=True, text=True, timeout=180).stdout
    data = json.loads(out or "{}")
    stream = (data.get("streams") or [{}])[0]
    return int(stream.get("width") or 0), int(stream.get("height") or 0)


def decode(path: str, width: int, ffmpeg: str = None):
    """Yield (frame_index, pts_ms_or_None, BGR frame) for every decoded frame.

    The PTS queue is filled by a stderr drain thread (showinfo prints one line per
    decoded frame) and consumed one entry per frame read, so a frame and its
    timestamp cannot drift apart. A full stderr pipe would block ffmpeg forever,
    which is why the drain runs on its own thread.
    """
    w, h = scaled_size(path, width)
    if not w or not h:
        raise RuntimeError("could not determine the decoder's output size")
    cmd = [ffmpeg or tool("ffmpeg"), "-hide_banner", "-nostats", "-loglevel", "info",
           "-threads", "1", "-filter_threads", "1", "-fflags", "+discardcorrupt",
           "-i", path, "-map", "0:v:0", "-an", "-sn", "-dn",
           "-fps_mode", "passthrough",
           "-vf", "scale=%d:-2,showinfo" % width,
           "-pix_fmt", "bgr24", "-f", "rawvideo", "pipe:1"]
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, bufsize=w * h * 3 * 2)
    errors = []
    while not _PTS.empty():                      # a fresh stream starts clean
        _PTS.get_nowait()

    def drain():
        for raw in iter(proc.stderr.readline, b""):
            line = raw.decode("utf-8", "replace")
            if "showinfo" in line:
                m = _SHOWINFO_PTS.search(line)
                if m:
                    try:
                        _PTS.put(float(m.group(1)))
                    except ValueError:
                        _PTS.put(None)
                # any other showinfo line (the per-frame pixel-format line, or the
                # filter's config line) is NOT a frame timestamp: enqueueing it
                # would put two entries in the queue for one frame.
            elif "rror" in line:
                errors.append(line.strip())
                del errors[:-20]

    thread = threading.Thread(target=drain, daemon=True, name="stage3-ffmpeg")
    thread.start()
    index = 0
    frame_bytes = w * h * 3
    first_pts = None
    try:
        while True:
            if _STOP["asked"]:
                break
            buf = proc.stdout.read(frame_bytes)
            if not buf or len(buf) < frame_bytes:
                break
            try:
                pts = _PTS.get(timeout=30.0)
            except queue.Empty:
                pts = None
            pts_ms = None
            if pts is not None:
                if first_pts is None:
                    first_pts = pts
                pts_ms = int(round((pts - first_pts) * 1000.0))
                if pts_ms < 0:
                    pts_ms = 0
            frame = np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 3)
            yield index, pts_ms, frame
            index += 1
    finally:
        try:
            proc.stdout.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        thread.join(timeout=2.0)
    if index == 0 and proc.returncode not in (0, None) and not _STOP["asked"]:
        raise RuntimeError("decoder exited %s with no frames: %s"
                           % (proc.returncode, " | ".join(errors[-3:])[:300]))


# ----------------------------------------------------------------------------------
# tracking (local object references, no cross-camera identity claim)
# ----------------------------------------------------------------------------------
class Linker:
    """Greedy class-consistent linking of sampled detections into local tracks."""

    def __init__(self, max_gap_ms=3000, max_dist=0.14, size_lo=0.45, size_hi=2.2):
        self.tracks = []
        self.next_id = 1
        self.max_gap_ms = max_gap_ms
        self.max_dist = max_dist
        self.size_lo = size_lo
        self.size_hi = size_hi

    @staticmethod
    def _centre(box):
        return (box[0] + box[2] / 2.0, box[1] + box[3] / 2.0)

    def assign(self, cls: str, box, pts_ms: int) -> str:
        cx, cy = self._centre(box)
        best, best_dist = None, None
        for tr in self.tracks:
            if tr["class"] != cls or pts_ms - tr["pts_ms"] > self.max_gap_ms:
                continue
            tx, ty = tr["centre"]
            dist = ((cx - tx) ** 2 + (cy - ty) ** 2) ** 0.5
            ratio = (box[2] * box[3]) / max(1e-9, tr["area"])
            if dist <= self.max_dist and self.size_lo <= ratio <= self.size_hi:
                if best_dist is None or dist < best_dist:
                    best, best_dist = tr, dist
        if best is None:
            track_id = "s3t%04d" % self.next_id
            self.next_id += 1
            self.tracks.append({"id": track_id, "class": cls, "centre": (cx, cy),
                                "area": box[2] * box[3], "pts_ms": pts_ms})
            return track_id
        best.update(centre=(cx, cy), area=box[2] * box[3], pts_ms=pts_ms)
        return best["id"]


# ----------------------------------------------------------------------------------
# inference
# ----------------------------------------------------------------------------------
def nms(boxes, scores, iou_threshold=0.5):
    if not boxes:
        return []
    arr = np.asarray(boxes, dtype=np.float32)
    sc = np.asarray(scores, dtype=np.float32)
    x0, y0 = arr[:, 0], arr[:, 1]
    x1, y1 = arr[:, 0] + arr[:, 2], arr[:, 1] + arr[:, 3]
    areas = arr[:, 2] * arr[:, 3]
    order = sc.argsort()[::-1]
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(int(i))
        xx0 = np.maximum(x0[i], x0[order[1:]])
        yy0 = np.maximum(y0[i], y0[order[1:]])
        xx1 = np.minimum(x1[i], x1[order[1:]])
        yy1 = np.minimum(y1[i], y1[order[1:]])
        w = np.maximum(0.0, xx1 - xx0)
        h = np.maximum(0.0, yy1 - yy0)
        inter = w * h
        iou = inter / np.maximum(1e-9, areas[i] + areas[order[1:]] - inter)
        order = order[1:][iou <= iou_threshold]
    return keep


def detect_frame(model, frame, torch, backend_info, cfg):
    """[(class, native_class, confidence, box_xywh)] for one decoded BGR frame."""
    h, w = frame.shape[:2]
    rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    tensor = torch.from_numpy(rgb).permute(2, 0, 1).float().div_(255.0)
    with torch.inference_mode():
        out = model([tensor])[0]
    names = models.coco_names()
    per_class = {}
    for label, score, box in zip(out["labels"].tolist(), out["scores"].tolist(),
                                 out["boxes"].tolist()):
        if score < cfg["score_threshold"]:
            continue
        x0, y0, x1, y1 = box
        bw, bh = (x1 - x0) / w, (y1 - y0) / h
        if bw <= 0 or bh <= 0 or bw * w < cfg["min_box_px"] or bh * h < cfg["min_box_px"]:
            continue
        cls = models.CLASS_MAP.get(int(label), "other")
        per_class.setdefault(cls, []).append(
            ((max(0.0, min(1.0, x0 / w))), max(0.0, min(1.0, y0 / h)),
             min(1.0, bw), min(1.0, bh), float(score), names.get(int(label), str(label))))
    results = []
    for cls, items in per_class.items():
        boxes = [[i[0], i[1], i[2], i[3]] for i in items]
        scores = [i[4] for i in items]
        for k in nms(boxes, scores, cfg["nms_iou"]):
            x, y, bw, bh, score, native = items[k]
            x = min(x, 1.0 - bw)                 # keep the box inside the frame
            y = min(y, 1.0 - bh)
            bw, bh = max(1e-6, min(bw, 1.0 - x)), max(1e-6, min(bh, 1.0 - y))
            results.append((cls, native, round(score, 6),
                            [round(x, 6), round(y, 6), round(bw, 6), round(bh, 6)]))
    results.sort(key=lambda r: (-r[2], r[0]))
    return results


#: Which colour regions are sampled for which contract class. A region is only
#: sampled when it means something for that object: a car has no upper clothing,
#: and a dog's "clothing" would be fur, which the contract's palette does not name.
REGIONS_FOR_CLASS = {"person": ("upper_clothing", "clothing", "lower_clothing"),
                     "car": ("vehicle_body",)}


def build_observation(frame, det, pts_ms, frame_index, track_id, run_dir, obs_seq, cfg):
    """One contract observation, with crops written as evidence."""
    cls, native, score, box = det
    obs_id = "s3o%06d" % obs_seq
    obs = {"id": obs_id, "frame_index": int(frame_index), "frame_pts_ms": int(pts_ms),
           "class": cls, "confidence": float(score), "bbox_xywh": list(box),
           "track_id": track_id, "colors": []}
    if native != cls:
        obs["native_class"] = native
    crops = pathlib.Path(run_dir) / "crops"
    crops.mkdir(parents=True, exist_ok=True)
    obj_crop = colour.crop_region(frame, box)
    if obj_crop is not None:
        name = "%s_object.png" % obs_id
        cv2.imwrite(str(crops / name), obj_crop)
        obs["evidence"] = {"object_crop": "crops/" + name,
                           "source_frame_index": int(frame_index),
                           "source_frame_pts_ms": int(pts_ms)}
    for region in REGIONS_FOR_CLASS.get(cls, ()):
        label, conf, rbox, rcrop, dist = colour.dominant_color(frame, box, region, cfg)
        entry = {"region": region, "label": label, "confidence": round(float(conf), 6)}
        rname = "%s_%s.png" % (obs_id, region)
        if rcrop is not None:
            cv2.imwrite(str(crops / rname), rcrop)
        entry["evidence"] = {"region_box_xywh": [round(float(v), 6) for v in rbox],
                             "region_crop": "crops/" + rname if rcrop is not None else None,
                             "distribution": dist,
                             "region_geometry": list(colour.REGION_GEOMETRY[region])}
        obs["colors"].append(entry)
    return obs


# ----------------------------------------------------------------------------------
# run
# ----------------------------------------------------------------------------------
def run_job(job: dict, out_dir: pathlib.Path) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    started = time.time()
    revision = implementation_identity()
    recording = job.get("recording") or ""
    clip_id = str(job.get("clip_id") or pathlib.Path(recording).stem or "clip")
    backend_key = job.get("backend") or models.DEFAULT_BACKEND
    cfg = {"score_threshold": float(job.get("score_threshold", 0.55)),
           "nms_iou": float(job.get("nms_iou", 0.5)),
           "min_box_px": int(job.get("min_box_px", 12)),
           "decode_width": int(job.get("decode_width", 1280)),
           "sample_fps": float(job.get("sample_fps", 2.5)),
           "device": "cpu", "seed": 0,
           "colour": dict(colour.DEFAULT_CONFIG),
           "colour_regions": {k: list(v) for k, v in colour.REGION_GEOMETRY.items()}}
    max_frames = int(job.get("max_frames") or 0)
    cfg["max_frames"] = max_frames
    sampling = {"mode": "adaptive_fps", "sample_fps": cfg["sample_fps"],
                "requested_frame_pts_ms": list(job.get("eval_frames_ms") or [])}
    if sampling["requested_frame_pts_ms"]:
        sampling["mode"] = "requested_frame_pts_ms"

    run = {"schema_version": 1, "run_id": job.get("run_id") or
           "%s-%s" % (ANALYSER_ID, datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")),
           "clip_id": clip_id, "input_sha256": "", "source_revision": revision["source_revision"],
           "analyser": {"id": ANALYSER_ID, "version": ANALYSER_VERSION,
                        "pipeline": "objects+colours",
                        "implementation": revision},
           "model": {}, "config": {"backend": backend_key, "inference": cfg,
                                   "sampling": sampling},
           "status": "failed", "observations": [], "errors": [],
           "measurements": {"decoded_frame_count": None, "inference_frame_count": None,
                            "elapsed_ms": None, "peak_rss_bytes": None,
                            "model_load_ms": None, "setup_ms": None,
                            "measurement_method":
                                "time.perf_counter around the run; "
                                "resource.getrusage(RUSAGE_SELF).ru_maxrss read once at "
                                "the end and converted to bytes for this platform "
                                "(KiB on Linux, bytes on macOS); this is PEAK RSS, not "
                                "net RSS, and it includes the torch runtime"}}

    def finish(status, error=None, exit_code=EXIT_FAILED):
        run["status"] = status
        if error:
            run["errors"] = [str(error)]
        run["measurements"]["elapsed_ms"] = int(round((time.time() - started) * 1000))
        try:
            run["measurements"]["peak_rss_bytes"] = peak_rss_bytes()
        except Exception:                                    # noqa: BLE001
            pass
        (out_dir / "run.json").write_text(
            json.dumps(run, indent=1, sort_keys=True, allow_nan=False), encoding="utf-8")
        return exit_code

    # ---- prerequisites ---------------------------------------------------------
    if not recording or not os.path.isfile(recording):
        emit({"event": "failed", "code": "missing_recording",
              "message": "no readable recording at %r" % recording})
        return finish("failed", "missing_recording: %r" % recording)
    state = models.check_backend(backend_key)
    if not state.get("ok"):
        emit({"event": "failed", "code": state.get("code", "model_unavailable"),
              "message": state.get("detail", "detector backend unavailable")})
        return finish("failed", "%s: %s" % (state.get("code"), state.get("detail")))
    if not state.get("weights_present"):
        msg = ("weights not present at %s; fetch %s"
               % (state.get("weights_path"), state.get("source")))
        emit({"event": "failed", "code": "missing_model", "message": msg})
        return finish("failed", "missing_model: " + msg)
    run["model"] = {"name": state["name"], "backend": backend_key,
                    "licence": state["licence"], "source": state["source"],
                    "weights_sha256": state["weights_sha256"],
                    "weights_sha256_expected": state["weights_sha256_expected"],
                    "weights_integrity_match": state["weights_match"],
                    "device": "cpu", "framework": _framework_version(),
                    "platform": "%s %s (%s)" % (platform.system(), platform.release(),
                                                platform.machine()),
                    "classes": {str(k): v for k, v in sorted(models.CLASS_MAP.items())}}
    run["input_sha256"] = sha256_file(recording)
    run["measurements"]["setup_ms"] = int(round((time.time() - started) * 1000))

    # ---- model -----------------------------------------------------------------
    try:
        import torch
        torch.set_num_threads(int(job.get("threads", 6)))
        t_load = time.perf_counter()
        model = models.load_backend(backend_key)
        run["measurements"]["model_load_ms"] = int(round((time.perf_counter() - t_load) * 1000))
    except Exception as exc:                                 # noqa: BLE001
        emit({"event": "failed", "code": "model_load_failed", "message": str(exc)[:300]})
        return finish("failed", "model_load_failed: %s" % exc)

    frames_path = out_dir / "frames.jsonl"
    obs_path = out_dir / "observations.jsonl"
    linker = Linker()
    decode_meta = {"probe": {}, "decoded_frames": 0, "last_pts_ms": None,
                   "discontinuities": [], "pts_source":
                       "ffmpeg showinfo pts_time of each decoded frame "
                       "(n: ... pts_time:), never frame_index/fps",
                   "requested_missing": [], "frames_without_pts": 0,
                   "backwards_pts": 0, "sampled_without_pts": 0}
    inference_frames = 0
    obs_seq = 0
    last_sample_ms = None
    next_requested = 0
    requested = sorted(float(v) for v in sampling["requested_frame_pts_ms"])
    cancelled = False
    try:
        decode_meta["probe"] = probe(recording)
        width = cfg["decode_width"] or decode_meta["probe"]["width"]
        with open(frames_path, "w", encoding="utf-8") as fh, \
                open(obs_path, "w", encoding="utf-8") as ofh:
            for index, pts_ms, frame in decode(recording, width):
                if _STOP["asked"]:
                    cancelled = True
                    break
                if max_frames and index >= max_frames:
                    break
                if pts_ms is None:
                    # A frame the decoder could not time is REPORTED, never given a
                    # fabricated timestamp and never used as observation evidence.
                    decode_meta["frames_without_pts"] += 1
                    fh.write(json.dumps({"frame_index": index, "pts_ms": None}) + "\n")
                    decode_meta["decoded_frames"] = index + 1
                    continue
                if (decode_meta["last_pts_ms"] is not None
                        and pts_ms < decode_meta["last_pts_ms"]):
                    decode_meta["backwards_pts"] += 1
                    decode_meta["discontinuities"].append(
                        {"frame_index": index, "kind": "backwards",
                         "from_ms": decode_meta["last_pts_ms"], "to_ms": pts_ms})
                elif (decode_meta["last_pts_ms"] is not None
                        and pts_ms - decode_meta["last_pts_ms"] > 2000):
                    decode_meta["discontinuities"].append(
                        {"frame_index": index, "kind": "gap",
                         "from_ms": decode_meta["last_pts_ms"], "to_ms": pts_ms})
                decode_meta["last_pts_ms"] = pts_ms
                decode_meta["decoded_frames"] = index + 1
                fh.write(json.dumps({"frame_index": index, "pts_ms": pts_ms}) + "\n")

                sample = False
                if requested:
                    if next_requested < len(requested) and pts_ms >= requested[next_requested]:
                        sample = True
                        while (next_requested < len(requested)
                               and pts_ms >= requested[next_requested]):
                            next_requested += 1
                else:
                    step = 1000.0 / max(0.01, cfg["sample_fps"])
                    if last_sample_ms is None or pts_ms - last_sample_ms >= step - 1.0:
                        sample = True
                if not sample:
                    continue
                if decode_meta["frames_without_pts"] and pts_ms is None:
                    decode_meta["sampled_without_pts"] += 1
                    continue
                last_sample_ms = pts_ms
                inference_frames += 1
                for det in detect_frame(model, frame, torch, {}, cfg):
                    track_id = linker.assign(det[0], det[3], pts_ms)
                    obs = build_observation(frame, det, pts_ms, index, track_id,
                                            out_dir, obs_seq, cfg)
                    obs_seq += 1
                    run["observations"].append(obs)
                    ofh.write(json.dumps(obs, allow_nan=False) + "\n")
                    emit({"event": "observation", "id": obs["id"], "class": obs["class"],
                          "frame_index": index, "frame_pts_ms": pts_ms,
                          "confidence": obs["confidence"],
                          "colors": [c["label"] for c in obs["colors"]]})
                if index % 25 == 0:
                    emit({"event": "progress", "frames_decoded": index + 1,
                          "inference_frames": inference_frames,
                          "observations": len(run["observations"]),
                          "t_ms": pts_ms,
                          "elapsed_s": round(time.time() - started, 2)})
        if requested:
            decode_meta["requested_missing"] = [
                v for v in requested if v > (decode_meta["last_pts_ms"] or 0)]
        emit({"event": "progress", "frames_decoded": decode_meta["decoded_frames"],
              "inference_frames": inference_frames,
              "observations": len(run["observations"]),
              "t_ms": decode_meta["last_pts_ms"],
              "elapsed_s": round(time.time() - started, 2)})
    except Exception as exc:                                 # noqa: BLE001
        emit({"event": "failed", "code": "run_error",
              "message": "%s: %s" % (type(exc).__name__, str(exc)[:300])})
        run["measurements"]["decoded_frame_count"] = decode_meta["decoded_frames"]
        run["measurements"]["inference_frame_count"] = inference_frames
        return finish("failed", "%s: %s" % (type(exc).__name__, exc))

    run["measurements"]["decoded_frame_count"] = decode_meta["decoded_frames"]
    run["measurements"]["inference_frame_count"] = inference_frames
    run["config"]["decode"] = {"width": cfg["decode_width"],
                               "source": decode_meta["probe"],
                               "pts_source": decode_meta["pts_source"],
                               "discontinuities": decode_meta["discontinuities"],
                               "frames_without_pts": decode_meta["frames_without_pts"],
                               "backwards_pts": decode_meta["backwards_pts"],
                               "requested_frames_missing": decode_meta["requested_missing"]}
    if cancelled:
        emit({"event": "cancelled", "observations": len(run["observations"]),
              "frames_decoded": decode_meta["decoded_frames"]})
        return finish("cancelled", None, EXIT_CANCELLED)
    emit({"event": "finished", "status": "completed", "clip_id": clip_id,
          "observations": len(run["observations"]),
          "inference_frames": inference_frames,
          "decoded_frames": decode_meta["decoded_frames"],
          "classes": _count(run["observations"], lambda o: o["class"]),
          "elapsed_s": round(time.time() - started, 2), "run_dir": str(out_dir)})
    return finish("completed", None, EXIT_OK)


def _count(observations, key) -> dict:
    out = {}
    for ob in observations:
        k = key(ob)
        out[k] = out.get(k, 0) + 1
    return out


def _framework_version() -> str:
    try:
        import torch
        import torchvision
        return "torch %s / torchvision %s" % (torch.__version__, torchvision.__version__)
    except Exception:                                        # noqa: BLE001
        return "unknown"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--job")
    ap.add_argument("--out")
    ap.add_argument("--recording")
    ap.add_argument("--clip-id")
    ap.add_argument("--backend", default=models.DEFAULT_BACKEND)
    ap.add_argument("--sample-fps", type=float, default=2.5)
    ap.add_argument("--score-threshold", type=float, default=0.55)
    ap.add_argument("--max-frames", type=int, default=0)
    ap.add_argument("--check-model", action="store_true")
    ap.add_argument("--probe", action="store_true",
                    help="report container facts for --recording and exit")
    args = ap.parse_args(argv)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    if args.probe:
        if not args.recording:
            print(json.dumps({"ok": False, "error": "--recording is required"}, indent=1))
            return EXIT_FAILED
        try:
            info = probe(args.recording)
            info["ok"] = True
        except Exception as exc:                             # noqa: BLE001
            info = {"ok": False, "error": "%s: %s" % (type(exc).__name__, exc)}
        print(json.dumps(info, indent=1, sort_keys=True))
        return EXIT_OK if info.get("ok") else EXIT_FAILED

    if args.check_model:
        state = models.check_backend(args.backend)
        print(json.dumps(state, indent=1, sort_keys=True))
        return EXIT_OK if state.get("ok") and state.get("weights_present") else EXIT_FAILED

    job = {}
    if args.job:
        job = json.loads(pathlib.Path(args.job).read_text(encoding="utf-8"))
    for key, value in (("recording", args.recording), ("clip_id", args.clip_id),
                       ("backend", args.backend), ("sample_fps", args.sample_fps),
                       ("score_threshold", args.score_threshold)):
        if value not in (None, "") and not job.get(key):
            job[key] = value
    if not args.out:
        print("--out is required", file=sys.stderr)
        return EXIT_FAILED
    try:
        return run_job(job, pathlib.Path(args.out))
    except Exception as exc:                                 # noqa: BLE001
        emit({"event": "failed", "code": "runner_error",
              "message": "%s: %s" % (type(exc).__name__, str(exc)[:300])})
        return EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main())
