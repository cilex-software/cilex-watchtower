"""Stage 4 inference: video pixels -> object, size, colour and colour location.

CONTRACT (RESULT_FORMAT.md, schema 4): one run directory containing `run.json`
plus referenced evidence files; every scheduled frame gets a coverage record even
when nothing is detected; boxes are normalized to the full source frame; colour
records carry the pixels that supported them.

WHAT IT READS AT INFERENCE: the input video, its own configuration and its own
checkpoint. It does not read annotations, target lists, dataset files, filenames
that encode labels, or any network resource -- and it cannot: nothing here opens
those paths, and the checkpoint carries the full state dict so the pretrained
trunk is never downloaded.

Timestamps come from each decoded frame's own `pts_time` reported by ffmpeg, not
from a frame counter divided by a nominal frame rate. `frame_index` is the index
of the decoded presentation frame, which is what a schedule addresses.
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
import tempfile
import threading
import time

import cv2
import numpy as np

# Cap OpenCV's thread pools and the math-library threads BEFORE the heavy imports
# do their allocating. OpenCV defaults to one worker pool per core (this box has
# 20), and each pool's scratch buffers are real RSS: the analyser tree measured
# 700-790 MiB with the defaults and the two-core inference budget asks for two
# threads anyway. Set here rather than per-call so nothing can miss it.
os.environ.setdefault("OMP_NUM_THREADS", "2")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "2")
os.environ.setdefault("MKL_NUM_THREADS", "2")
try:
    cv2.setNumThreads(2)
except Exception:                                            # noqa: BLE001
    pass

_HERE = pathlib.Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import stage4_colour as COLOUR      # noqa: E402
import stage4_data as DATA          # noqa: E402

# stage4_model (and therefore torch) is imported LAZILY: the ONNX runtime path
# must not pay torch's several-hundred-MiB import cost, which is exactly what the
# memory budget is about.
CLASSES = ("human", "car", "animal")
INPUT_SIZE = 256
STRIDES = (4,)

ANALYSER_VERSION = "stage4-object-size-colour/1.0.0"
SCHEMA_VERSION = 4
DEFAULT_DECODE_WIDTH = 1280
REGIONS_FOR_CLASS = {"human": ("upper_clothing", "lower_clothing"),
                     "car": ("vehicle_body",),
                     "animal": ("coat",)}
_SHOWINFO_PTS = re.compile(r"\bn:\s*\d+\b.*?\bpts_time:\s*([-+0-9.eE]+)")


# ----------------------------------------------------------------------------------
# process helpers
# ----------------------------------------------------------------------------------
def tool(name: str) -> str:
    """ffmpeg/ffprobe: explicit env first, then PATH (the app passes its own)."""
    override = os.environ.get("WT_%s" % name.upper())
    if override:
        if not os.path.isfile(override):
            raise RuntimeError("WT_%s points at %r, which is not a file"
                               % (name.upper(), override))
        return override
    found = shutil.which(name)
    if not found:
        raise RuntimeError("%s not found; install it or point WT_%s at the binary "
                           "that ships with Watchtower" % (name, name.upper()))
    return found


def peak_rss_bytes() -> int:
    """Peak RSS in BYTES on every platform (ru_maxrss is KiB on Linux, bytes on macOS)."""
    import resource
    raw = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    return raw if sys.platform == "darwin" else raw * 1024


def sha256_file(path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def sha256_obj(obj) -> str:
    blob = json.dumps(obj, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def probe(path: str) -> dict:
    out = subprocess.run(
        [tool("ffprobe"), "-v", "error", "-of", "json", "-show_format",
         "-show_streams", path], capture_output=True, text=True, timeout=120).stdout
    info = json.loads(out or "{}")
    stream = next((s for s in info.get("streams", []) if s.get("codec_type") == "video"),
                  {})
    rotation = None
    for sd in stream.get("side_data_list", []) or []:
        if "rotation" in sd:
            rotation = sd["rotation"]
    return {"width": stream.get("width"), "height": stream.get("height"),
            "codec": stream.get("codec_name"),
            "avg_frame_rate": stream.get("avg_frame_rate"),
            "time_base": stream.get("time_base"),
            "duration_s": float(info.get("format", {}).get("duration") or 0.0),
            "rotation": rotation, "nb_frames_header": stream.get("nb_frames")}


def scaled_size(path: str, width: int, source=None):
    """Output size of `scale=width:-2`, computed ARITHMETICALLY.

    The obvious implementation asks ffprobe to evaluate the filter graph
    (`-f lavfi -i movie=...,scale=...`), but that DECODES THE WHOLE FILE to answer
    a question about two integers: on a 45-second 1080p clip it blocked for
    minutes inside the first ffprobe call, which is how this was found (a run sat
    at 0.5% CPU with its temp directory empty). Arithmetic is instant and exact:
    the height is the aspect-preserving value rounded to an even number.
    """
    info = source or probe(path)
    w, h = info.get("width"), info.get("height")
    if not w or not h:
        return width, max(2, int(round(width * 9 / 16)))
    nh = int(round(h * (width / float(w)) / 2.0)) * 2
    return width, max(2, nh)


# ----------------------------------------------------------------------------------
# decoding (real PTS per decoded presentation frame)
# ----------------------------------------------------------------------------------
class _PtsReader:
    """Reads ffmpeg's log from a FILE and pulls `pts_time` out of it as it grows.

    ffmpeg's log goes to a file rather than a pipe on purpose. With a pipe, a
    reader thread that stops draining (or drains slower than ffmpeg logs) fills the
    64 KiB pipe buffer, ffmpeg blocks in its log write, stops producing video, and
    the frame reader waits forever -- measured on a 45 s 1080p clip: both processes
    alive and idle, ~30 frames decoded, no timeout reached. A file cannot block
    anyone, so the failure mode is gone rather than made rarer.
    """

    def __init__(self, handle):
        self.handle = handle
        self.pos = 0
        self.buffer = ""
        self.pending = []

    def poll(self):
        self.handle.seek(self.pos)
        chunk = self.handle.read()
        self.pos = self.handle.tell()
        if not chunk:
            return
        self.buffer += chunk.decode("utf-8", "replace")
        while "\n" in self.buffer:
            line, self.buffer = self.buffer.split("\n", 1)
            m = _SHOWINFO_PTS.search(line)
            if m:
                try:
                    self.pending.append(float(m.group(1)))
                except ValueError:
                    continue

    def take(self):
        return self.pending.pop(0) if self.pending else None


def frame_pts(path: str, ffmpeg: str = None) -> list:
    """Every decoded presentation frame's own PTS in order, as milliseconds.

    This is a separate, pixel-free pass (`-f null`). Harvesting timestamps from the
    same pass that transfers frames looked cheaper, but ffmpeg block-buffers its
    log when stderr is not a terminal, so the timestamps arrive in ~4 KiB bursts
    well behind the pixels: measured, only 659 of 1124 frames could be paired that
    way, and the rest would have been unusable for scheduling. A null decode
    transfers no pixels, drains its pipes with `communicate()` (which cannot
    deadlock), and yields the complete, ordered list.
    """
    # `-fps_mode passthrough`: without it ffmpeg converts the variable-rate source
    # to a constant rate by DUPLICATING frames, so the pixel pass produced 1124
    # frames from a 680-frame clip and every timestamp after the first duplicate
    # described a frame that is not a distinct decoded presentation frame.
    cmd = [ffmpeg or tool("ffmpeg"), "-hide_banner", "-nostats", "-loglevel", "info",
           "-i", path, "-vf", "showinfo", "-fps_mode", "passthrough",
           "-f", "null", "-"]
    out = subprocess.run(cmd, capture_output=True, timeout=3600)
    values = []
    for line in out.stderr.decode("utf-8", "replace").splitlines():
        m = _SHOWINFO_PTS.search(line)
        if not m:
            continue
        try:
            values.append(round(float(m.group(1)) * 1000.0, 3))
        except ValueError:
            continue
    return values


def decode(path: str, width: int, ffmpeg: str = None, source=None, pts_list=None):
    """Yield (frame_index, pts_ms, bgr) for every decoded frame, with real PTS.

    `pts_list` (from `frame_pts`) is paired with the frames by index, so a frame is
    timed by the timestamp the decoder produced for THAT frame or not at all.
    """
    timestamps = list(pts_list or [])
    w, h = scaled_size(path, width, source)
    cmd = [ffmpeg or tool("ffmpeg"), "-hide_banner", "-nostats", "-loglevel", "info",
           "-i", path, "-vf", "scale=%d:-2,showinfo" % width,
           "-fps_mode", "passthrough",
           "-pix_fmt", "bgr24", "-f", "rawvideo", "-"]
    frame_bytes = w * h * 3
    log = tempfile.TemporaryFile()
    # Default buffering: an unbuffered pipe hands back PARTIAL reads, so the
    # length check below would treat a short chunk as end-of-stream (measured: zero
    # frames decoded). A BufferedReader gives whole frames or a real EOF.
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=log)
    pts = _PtsReader(log)
    frames: queue.Queue = queue.Queue(maxsize=4)
    sentinel = object()

    def _reader():
        try:
            while True:
                buf = proc.stdout.read(frame_bytes)
                if not buf:
                    break
                frames.put(buf)
        except Exception:                                    # noqa: BLE001
            pass
        finally:
            frames.put(sentinel)

    t = threading.Thread(target=_reader, daemon=True)
    t.start()
    index = 0
    try:
        while True:
            item = frames.get()
            if item is sentinel:
                break
            if len(item) < frame_bytes:
                break
            frame = np.frombuffer(item, np.uint8).reshape(h, w, 3)
            value = timestamps[index] if index < len(timestamps) else None
            yield index, value, frame
            index += 1
    finally:
        try:
            proc.stdout.close()
        except Exception:                                    # noqa: BLE001
            pass
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        t.join(timeout=2)
        pts.poll()
        log.close()


# ----------------------------------------------------------------------------------
# the analyser
# ----------------------------------------------------------------------------------
class Analyser:
    """Loads one checkpoint and turns decoded frames into contract observations."""

    def __init__(self, approach: str, checkpoint, config: dict, run_dir: pathlib.Path,
                 progress=None, runtime: str = "auto"):
        self.approach = approach
        self.config = config
        self.run_dir = run_dir
        self.progress = progress or (lambda rec: None)
        t0 = time.perf_counter()
        candidates = [pathlib.Path(str(checkpoint) + ".onnx"),
                      pathlib.Path(str(checkpoint)).with_suffix(".onnx")]
        onnx_path = next((c for c in candidates if c.is_file()), candidates[0])
        use_onnx = runtime == "onnx" or (runtime == "auto" and onnx_path.is_file())
        self.runtime = "onnx" if use_onnx else "torch"
        if use_onnx:
            import stage4_onnx as ONNX
            self.onnx = ONNX.OnnxRuntime(onnx_path, threads=int(config.get("threads", 2)))
            self.checkpoint_meta = {"runtime": "onnx", "onnx_sha256":
                                    ONNX.identity(onnx_path)["onnx_sha256"],
                                    "onnx_version": self.onnx.version}
            self.model = None
        else:
            import torch
            import stage4_model as MODEL
            torch.manual_seed(int(config.get("seed", 20261006)))
            torch.set_num_threads(int(config.get("threads", 2)))
            self.model, self.checkpoint_meta = MODEL.load_checkpoint(approach, checkpoint)
        self.model_load_ms = round((time.perf_counter() - t0) * 1000.0, 2)
        # Hand the allocator's free pages back after loading. On this build the
        # cold run sat 64 MiB above the 512 MiB target purely because the loader
        # had grown the heap, while warm runs measured 510-511 MiB; trimming is a
        # one-line way to make the first run behave like the rest.
        try:
            import ctypes
            ctypes.CDLL("libc.so.6").malloc_trim(0)
        except Exception:                                    # noqa: BLE001
            pass
        self.checkpoint_path = str(checkpoint)
        self.checkpoint_sha256 = sha256_file(checkpoint)
        self.inference_ms = []
        self.colour_ms = []
        self.decode_ms = []
        self._counter = 0
        # Every directory the evidence writers use must exist BEFORE they run:
        # `colour_crops/` was missing, cv2.imwrite failed silently, and the run then
        # referenced colour crops that were never on disk (found by S4-C06/C10/C15,
        # which is what those controls are for).
        for sub in ("crops", "masks", "colour_crops"):
            (run_dir / sub).mkdir(parents=True, exist_ok=True)

    # -- one frame ------------------------------------------------------------------
    def analyse_frame(self, frame_bgr: np.ndarray, frame_index: int, pts_ms):
        cfg = self.config
        size = int(cfg["input_size"])
        h, w = frame_bgr.shape[:2]
        small, scale, pad_x, pad_y = DATA.letterbox(frame_bgr, size)
        t0 = time.perf_counter()
        if self.runtime == "onnx":
            import stage4_onnx as ONNX
            x = image_to_nchw(small)
            outputs = self.onnx.run(x)
            boxes, scores, classes = ONNX.decode(outputs, size,
                                                 float(cfg["score_threshold"]),
                                                 int(cfg["topk"]), float(cfg["nms_iou"]))
        else:
            import torch
            import stage4_model as MODEL
            tensor = torch_from_image(small)
            with torch.inference_mode():
                outputs = self.model(tensor)
            boxes, scores, classes = MODEL.decode(outputs, size,
                                                  float(cfg["score_threshold"]),
                                                  int(cfg["topk"]),
                                                  float(cfg["nms_iou"]))
        self.inference_ms.append((time.perf_counter() - t0) * 1000.0)
        src_boxes = DATA.letterbox_to_boxes(boxes, w, h, scale, pad_x, pad_y, size)
        observations = []
        t1 = time.perf_counter()
        for i in range(src_boxes.shape[0]):
            self._counter += 1
            obs = self._observation(frame_bgr, frame_index, pts_ms, src_boxes[i],
                                    float(scores[i]), int(classes[i]))
            observations.append(obs)
        self.colour_ms.append((time.perf_counter() - t1) * 1000.0)
        self.progress({"event": "frame", "frame_index": frame_index, "pts_ms": pts_ms,
                       "objects": len(observations)})
        return observations

    def _observation(self, frame_bgr, frame_index, pts_ms, box, score, class_id) -> dict:
        cls = CLASSES[class_id]
        x, y, bw, bh = (float(v) for v in box)
        area_fraction = bw * bh
        oid = "o%05d" % self._counter
        h, w = frame_bgr.shape[:2]
        x0, y0 = max(0, int(x * w)), max(0, int(y * h))
        x1, y1 = min(w, int((x + bw) * w)), min(h, int((y + bh) * h))
        crop = frame_bgr[y0:y1, x0:x1]
        crop_rel = None
        if crop.size:
            crop_rel = "crops/%s.jpg" % oid
            cv2.imwrite(str(self.run_dir / crop_rel), crop,
                        [int(cv2.IMWRITE_JPEG_QUALITY), 88])
        colors = []
        for region in REGIONS_FOR_CLASS[cls]:
            rec = COLOUR.dominant_color(frame_bgr, [x, y, bw, bh], region,
                                        config=self.config.get("colour", {}),
                                        mask_dir=str(self.run_dir / "masks"),
                                        crop_dir=str(self.run_dir / "colour_crops"),
                                        name="%s-%s" % (oid, region))
            if rec.get("crop"):
                rec["crop"] = "colour_crops/%s" % os.path.basename(rec["crop"])
            colors.append(rec)
        # truncated: the box touches a frame edge, so part of the object is outside
        edge = 0.002
        truncated = bool(x <= edge or y <= edge or x + bw >= 1 - edge or y + bh >= 1 - edge)
        return {"observation_id": oid, "frame_index": int(frame_index),
                "frame_pts_ms": (None if pts_ms is None else float(pts_ms)),
                "class": cls, "confidence": round(float(score), 6),
                "bbox_xywh": [round(x, 6), round(y, 6), round(bw, 6), round(bh, 6)],
                "apparent_size": {"area_fraction": round(area_fraction, 8),
                                  "label": size_label(area_fraction),
                                  "policy": "bbox-area-v1"},
                "truncated": truncated, "occluded": None, "track_id": None,
                "crop": crop_rel, "colors": colors}

    def identity(self) -> dict:
        return {"analyser_version": ANALYSER_VERSION,
                "runtime": self.runtime,
                "approach": self.approach,
                "checkpoint": self.checkpoint_path,
                "checkpoint_sha256": self.checkpoint_sha256,
                "checkpoint_meta": self.checkpoint_meta,
                "model_load_ms": self.model_load_ms,
                "parameters": (self.model.parameter_counts()
                               if self.model is not None else None)}


def image_to_nchw(bgr: np.ndarray) -> np.ndarray:
    """BGR uint8 -> float32 NCHW RGB in [0,1], without torch."""
    rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
    return np.ascontiguousarray(rgb.transpose(2, 0, 1)[None])


def torch_from_image(bgr: np.ndarray):
    import torch
    rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
    return torch.from_numpy(rgb.transpose(2, 0, 1).copy()).unsqueeze(0)


def size_label(area_fraction: float) -> str:
    if area_fraction <= 0:
        return "unknown"
    if area_fraction < 0.01:
        return "small"
    if area_fraction < 0.10:
        return "medium"
    return "big"


def _installed_version(name: str):
    """Package version WITHOUT importing the package.

    `implementation_identity` used to `import torch` merely to read its version
    string, and that import alone costs hundreds of MiB -- on the ONNX path it
    defeated the entire point of the lighter runtime (measured: 700 MiB tree with
    the import, and the version is available from metadata for free).
    """
    try:
        from importlib.metadata import version
        return version(name)
    except Exception:                                        # noqa: BLE001
        return None


def loaded_runtime_modules() -> dict:
    """Which inference runtimes are actually imported in THIS process."""
    return {"torch_loaded": any(m == "torch" or m.startswith("torch.")
                                for m in sys.modules),
            "torchvision_loaded": any(m == "torchvision" or m.startswith("torchvision.")
                                      for m in sys.modules),
            "onnxruntime_loaded": "onnxruntime" in sys.modules,
            "opencv_loaded": any(m == "cv2" or m.startswith("cv2.") for m in sys.modules),
            "numpy_loaded": "numpy" in sys.modules}


def implementation_identity() -> dict:
    torch = torchvision = None
    root = _HERE.parent.parent
    try:
        revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(root),
                                  capture_output=True, text=True).stdout.strip()
        dirty = bool(subprocess.run(["git", "status", "--porcelain"], cwd=str(root),
                                    capture_output=True, text=True).stdout.strip())
    except Exception:                                        # noqa: BLE001
        revision, dirty = None, None
    files = {}
    for name in ("stage4_detect.py", "stage4_model.py", "stage4_colour.py",
                 "stage4_data.py", "stage4_evaluate.py"):
        p = _HERE / name
        if p.is_file():
            files[name] = sha256_file(p)
    identity = {"source_revision": revision, "source_dirty": dirty,
                "source_files_sha256": files,
                "implementation_sha256": sha256_obj(files),
                "python": sys.version.split()[0], "platform": platform.platform(),
                "opencv": cv2.__version__, "numpy": np.__version__,
                "torch": _installed_version("torch"),
                "torchvision": _installed_version("torchvision")}
    identity["onnxruntime"] = _installed_version("onnxruntime")
    return identity


# ----------------------------------------------------------------------------------
# schedule handling
# ----------------------------------------------------------------------------------
def native_schedule(decoded: list) -> list:
    """The submitted fixed native policy: first decoded frame at/after each second.

    Seconds are measured from the FIRST decoded frame's own PTS, so this matches
    the common evaluation schedule without assuming any frame rate.
    """
    if not decoded:
        return []
    base = decoded[0][1] or 0.0
    out, second = [], 1
    for index, pts in decoded:
        if pts is None:
            continue
        while pts >= base + second * 1000.0:
            out.append({"frame_index": index, "frame_pts_ms": pts})
            second += 1
    return out


def load_schedule(path, input_sha256: str, decoded: dict):
    """Validate a supplied schedule against the input it claims to describe."""
    spec = json.loads(pathlib.Path(path).read_text())
    errors = []
    if spec.get("schema_version") != 1:
        errors.append("schedule schema_version must be 1, got %r"
                      % (spec.get("schema_version"),))
    if spec.get("input_sha256") and spec["input_sha256"] != input_sha256:
        errors.append("schedule input_sha256 %s does not match the input %s"
                      % (spec["input_sha256"], input_sha256))
    frames = spec.get("frames") or []
    if not isinstance(frames, list) or not frames:
        errors.append("schedule carries no frames")
    checked = []
    for fr in frames:
        idx, pts = fr.get("frame_index"), fr.get("frame_pts_ms")
        if not isinstance(idx, int):
            errors.append("schedule frame_index %r is not an integer" % (idx,))
            continue
        if idx not in decoded:
            errors.append("schedule frame_index %d is not a decoded presentation "
                          "frame of this input" % idx)
            continue
        actual = decoded[idx]
        if actual is None:
            errors.append("decoded frame %d has no usable timestamp" % idx)
            continue
        if pts is None or abs(float(pts) - actual) > 1.0:
            errors.append("schedule frame %d pts %r does not match the decoded "
                          "%.3f ms (tolerance 1 ms)" % (idx, pts, actual))
            continue
        checked.append({"frame_index": idx, "frame_pts_ms": actual})
    checked.sort(key=lambda f: f["frame_index"])
    return checked, errors


def run(args) -> int:
    started = time.time()
    out_dir = pathlib.Path(args.output)
    problems = []
    if out_dir.exists():
        print("output directory %s already exists; refusing to overwrite it"
              % out_dir, file=sys.stderr)
        return 2
    out_dir.mkdir(parents=True)
    run_id = "%s-%s-%s" % (args.approach, time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()),
                           os.urandom(3).hex())
    config = {
        "approach": args.approach,
        "score_threshold": args.score_threshold,
        "topk": 64, "nms_iou": 0.5,
        "input_size": INPUT_SIZE,
        "decode_width": args.decode_width,
        "sampling": ("supplied-schedule" if args.schedule else "native-1hz-pts"),
        "device": "cpu", "threads": args.threads, "runtime": args.runtime,
        "size_policy": "bbox-area-v1",
        "colour": dict(COLOUR.DEFAULT_CONFIG),
        "colour_regions": {k: list(v) for k, v in COLOUR.REGION_GEOMETRY.items()},
        "seed": args.seed,
    }

    def emit(rec):
        rec = dict(rec)
        rec.setdefault("run_id", run_id)
        print(json.dumps(rec, sort_keys=True), flush=True)

    def finish(status, errors, payload):
        envelope = {
            "schema_version": SCHEMA_VERSION, "run_id": run_id,
            "approach": args.approach, "status": status, "errors": errors,
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
            **payload,
        }
        envelope["artifact_manifest"] = artifact_manifest(out_dir, envelope)
        (out_dir / "run.json").write_text(json.dumps(envelope, indent=1, sort_keys=True))
        emit({"event": "finished", "status": status, "errors": errors[:4],
              "observations": len(envelope.get("observations") or []),
              "run_dir": str(out_dir)})
        return 0 if status == "completed" else 1

    # ---- input -------------------------------------------------------------------
    if not os.path.isfile(args.input):
        return finish("failed", ["input file %s does not exist" % args.input], {})
    input_sha = sha256_file(args.input)
    input_bytes = os.path.getsize(args.input)
    try:
        info = probe(args.input)
    except Exception as exc:                                 # noqa: BLE001
        return finish("failed", ["probe failed: %s" % exc], {})
    emit({"event": "start", "approach": args.approach, "input": args.input,
          "input_sha256": input_sha, "bytes": input_bytes})

    # ---- checkpoint --------------------------------------------------------------
    checkpoint = args.checkpoint or default_checkpoint(args.approach, args.revision)
    if not checkpoint or not os.path.isfile(checkpoint):
        return finish("failed", ["checkpoint %r is absent: a missing model is a "
                                 "prerequisite failure, not an empty result"
                                 % (checkpoint,)], {})
    # Which revision this run used, verified from the file it is about to load.
    revision_info = {"revision": args.revision or "explicit-checkpoint",
                     "checkpoint": checkpoint}
    try:
        import stage4_revisions as REV
        resolved = REV.resolve(args.approach, args.revision, verify=False)
        revision_info = {k: resolved[k] for k in
                         ("revision", "label", "status", "architecture", "cache_size")}
        revision_info["registered_checkpoint"] = (resolved["checkpoint"] or {}).get("rel")
        revision_info["registered_sha256"] = (resolved["checkpoint"] or {}).get("sha256")
        revision_info["matches_registry"] = (
            revision_info["registered_sha256"] == sha256_file(checkpoint))
    except Exception as exc:                                 # noqa: BLE001
        revision_info["registry_note"] = "registry unavailable: %s" % exc
    if args.checkpoint_sha256:
        actual = sha256_file(checkpoint)
        if actual != args.checkpoint_sha256:
            return finish("failed", ["checkpoint sha256 %s does not match the "
                                     "expected %s" % (actual, args.checkpoint_sha256)], {})
    try:
        analyser = Analyser(args.approach, args.onnx or checkpoint, config, out_dir,
                            progress=emit, runtime=args.runtime)
    except Exception as exc:                                 # noqa: BLE001
        return finish("failed", ["checkpoint could not be loaded: %s" % exc], {})

    # ---- decode + schedule -------------------------------------------------------
    decoded = {}
    frames_meta = []
    t_decode = time.perf_counter()
    cancelled = {"flag": False}

    def _term(_sig, _frm):
        cancelled["flag"] = True
    signal.signal(signal.SIGTERM, _term)

    pts_list = frame_pts(args.input)
    emit({"event": "timestamps", "frames": len(pts_list)})
    for index, pts_ms, _frame in decode(args.input, args.decode_width, source=info,
                                        pts_list=pts_list):
        decoded[index] = pts_ms
        frames_meta.append({"frame_index": index, "frame_pts_ms": pts_ms})
        if cancelled["flag"]:
            break
    decode_ms = (time.perf_counter() - t_decode) * 1000.0
    timed = [f for f in frames_meta if f["frame_pts_ms"] is not None]
    emit({"event": "decoded", "frames": len(frames_meta), "timed": len(timed),
          "decode_ms": round(decode_ms, 2)})
    if not frames_meta:
        return finish("failed", ["no frame could be decoded from the input"], {})
    if len(timed) != len(frames_meta):
        problems.append("%d decoded frames carry no usable timestamp; they cannot "
                        "be scheduled or cited as evidence"
                        % (len(frames_meta) - len(timed)))
    if cancelled["flag"]:
        return finish("cancelled", ["terminated during decoding"], {
            "input": {"sha256": input_sha, "bytes": input_bytes, **info}})

    if args.schedule:
        schedule, errors = load_schedule(args.schedule, input_sha,
                                         {f["frame_index"]: f["frame_pts_ms"] for f in timed})
        if errors:
            return finish("failed", errors, {
                "input": {"sha256": input_sha, "bytes": input_bytes,
                          "decoded_frame_count": len(frames_meta), **info}})
    else:
        schedule = native_schedule([(f["frame_index"], f["frame_pts_ms"]) for f in timed])

    # ---- inference over the scheduled frames -------------------------------------
    wanted = {f["frame_index"]: f["frame_pts_ms"] for f in schedule}
    coverage = []
    observations = []
    t_infer = time.perf_counter()
    for index, pts_ms, frame in decode(args.input, args.decode_width, source=info,
                                       pts_list=pts_list):
        if cancelled["flag"]:
            break
        if index not in wanted:
            continue
        if pts_ms is None:
            coverage.append({"frame_index": index, "frame_pts_ms": None,
                             "state": "failed", "reason": "frame has no usable PTS",
                             "observation_ids": []})
            continue
        try:
            found = analyser.analyse_frame(frame, index, pts_ms)
        except Exception as exc:                             # noqa: BLE001
            coverage.append({"frame_index": index, "frame_pts_ms": pts_ms,
                             "state": "failed", "reason": str(exc)[:200],
                             "observation_ids": []})
            continue
        observations.extend(found)
        coverage.append({"frame_index": index, "frame_pts_ms": pts_ms,
                         "state": "analysed", "reason": None,
                         "observation_ids": [o["observation_id"] for o in found]})
    infer_ms = (time.perf_counter() - t_infer) * 1000.0

    missing = [f["frame_index"] for f in schedule
               if f["frame_index"] not in {c["frame_index"] for c in coverage}]
    for index in missing:
        coverage.append({"frame_index": index, "frame_pts_ms": wanted[index],
                         "state": "failed",
                         "reason": "scheduled frame was not reached in the decode pass",
                         "observation_ids": []})
    coverage.sort(key=lambda c: c["frame_index"])

    status = "cancelled" if cancelled["flag"] else "completed"
    if cancelled["flag"]:
        problems.append("run was terminated before every scheduled frame was analysed")
    payload = {
        "input": {"path": args.input, "sha256": input_sha, "bytes": input_bytes,
                  "decoded_width": args.decode_width, **info,
                  "decoded_frame_count": len(frames_meta),
                  "first_absolute_pts_ms": (timed[0]["frame_pts_ms"] if timed else None),
                  "camera_metadata": None,
                  "camera_metadata_note": ("capture time and camera are recording "
                                           "metadata; this analyser neither infers "
                                           "nor fabricates them")},
        "implementation": implementation_identity(),
        "revision": revision_info,
        "runtime_modules": loaded_runtime_modules(),
        "models": [{"role": "detector", "approach": args.approach,
                    "architecture": ("scratch-cnn-anchorfree" if args.approach == "A"
                                     else "resnet18-frozen-trunk-anchorfree-head"),
                    "runtime": analyser.runtime,
                    "runtime_version": analyser.checkpoint_meta.get("onnx_version"),
                    "origin": analyser.identity()["checkpoint_meta"].get("tag"),
                    "checkpoint": analyser.checkpoint_path,
                    "checkpoint_sha256": analyser.checkpoint_sha256,
                    "checkpoint_bytes": os.path.getsize(checkpoint),
                    "pretrained_trunk": analyser.checkpoint_meta.get("pretrained_trunk"),
                    "training_artifact": analyser.checkpoint_meta.get("tag")}],
        "config": config,
        "schedule": {"policy": config["sampling"], "frames": schedule,
                     "count": len(schedule)},
        "coverage": coverage,
        "observations": observations,
        "metrics": {
            "decode_ms": round(decode_ms, 2),
            "inference_pass_ms": round(infer_ms, 2),
            "model_load_ms": analyser.model_load_ms,
            "inference_ms_per_frame_mean": (round(float(np.mean(analyser.inference_ms)), 2)
                                            if analyser.inference_ms else None),
            "inference_ms_per_frame_max": (round(float(np.max(analyser.inference_ms)), 2)
                                           if analyser.inference_ms else None),
            "colour_ms_per_frame_mean": (round(float(np.mean(analyser.colour_ms)), 2)
                                         if analyser.colour_ms else None),
            "frames_decoded": len(frames_meta),
            "frames_scheduled": len(schedule),
            "frames_analysed": sum(1 for c in coverage if c["state"] == "analysed"),
            "observations": len(observations),
            "peak_rss_bytes": peak_rss_bytes(),
            "measurement_method": ("time.perf_counter around each phase; peak RSS "
                                   "from resource.getrusage(RUSAGE_SELF) reported in "
                                   "bytes for this platform; this is PEAK RSS of the "
                                   "analyser process only, the OS-level process tree "
                                   "is sampled by the product control"),
            "wall_seconds": round(time.time() - started, 2),
        },
        "unavailable": problems,
    }
    return finish(status, problems, payload)


def artifact_manifest(out_dir: pathlib.Path, envelope: dict) -> dict:
    """Every file the run produced, with its hash and size."""
    items = []
    for path in sorted(out_dir.rglob("*")):
        if path.is_file():
            items.append({"path": str(path.relative_to(out_dir)),
                          "sha256": sha256_file(path), "bytes": path.stat().st_size})
    return {"schema_version": 1, "files": items, "count": len(items)}


def default_checkpoint(approach: str, revision: str = None):
    """The selected revision's checkpoint, through the one registry.

    R1's version of this function resolved build/stage4/training/<tag>/final.pt,
    which is the ORIGINAL (R0) artifact, while the checks and reports talked about
    R1 — three resolvers, three revisions (R2 finding 1).
    """
    import stage4_revisions as REV
    try:
        return REV.resolve(approach, revision, verify=True)["checkpoint"]["path"]
    except REV.RevisionError:
        return None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--approach", required=True, choices=["A", "B"])
    ap.add_argument("--config")
    ap.add_argument("--schedule")
    ap.add_argument("--output", help="a NEW run directory (required unless --probe)")
    ap.add_argument("--checkpoint")
    ap.add_argument("--checkpoint-sha256", dest="checkpoint_sha256")
    ap.add_argument("--score-threshold", type=float, default=0.30)
    ap.add_argument("--decode-width", type=int, default=DEFAULT_DECODE_WIDTH)
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--seed", type=int, default=20261006)
    ap.add_argument("--onnx", help="explicit ONNX file (default: beside the checkpoint)")
    ap.add_argument("--revision", default=None,
                    help="artifact revision from the registry (default: its selection)")
    ap.add_argument("--runtime", default="auto", choices=["auto", "torch", "onnx"],
                    help="inference runtime; auto prefers a verified ONNX export")
    ap.add_argument("--probe", action="store_true",
                    help="print input facts as JSON and exit (no inference)")
    args = ap.parse_args(argv)
    if args.probe:
        if not os.path.isfile(args.input):
            print(json.dumps({"error": "input does not exist", "path": args.input}))
            return 1
        try:
            info = probe(args.input)
        except Exception as exc:                             # noqa: BLE001
            print(json.dumps({"error": str(exc)}))
            return 1
        print(json.dumps({"sha256": sha256_file(args.input),
                          "bytes": os.path.getsize(args.input), **info}, sort_keys=True))
        return 0
    # The seed/thread setup used to import torch whenever the runtime was not
    # EXPLICITLY "onnx" -- so the default `auto` path loaded torch even when it then
    # ran through ONNX Runtime, which defeats the point of the lighter runtime. The
    # torch-specific setup now lives in the torch branch of Analyser, and the run
    # records which modules actually got loaded.

    if args.config:
        spec = json.loads(pathlib.Path(args.config).read_text())
        for key in ("score_threshold", "decode_width", "topk", "nms_iou"):
            if key in spec:
                setattr(args, key.replace("-", "_"), spec[key])
    if not args.probe and not args.output:
        ap.error("--output is required unless --probe is used")
    try:
        return run(args)
    except KeyboardInterrupt:                                # pragma: no cover
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
