#!/usr/bin/env python3
"""Product job runner: one local recording in, one temporal-tracks run out.

This is the helper process Cilex Watchtower's Labs screen drives
(`src/models/LabsTrackJob.cpp` launches it and reads its stdout). It is a thin,
honest driver over the EXISTING pipeline -- nothing here detects, decodes or
tracks on its own:

    frame_source.iter_frames(path)          the repo's ffmpeg decode pass
      -> labs_foreground_mask.iter_masks    the repo's foreground analyser (B3)
      -> temporal_tracks_adapter            MaskFrame -> engine batch, offline
      -> temporal_tracks.Tracker            the stage-1 engine, unchanged

It prints one JSON object per line and exits 0 on a completed run:

    {"kind":"meta", ...}        input identity (path, size, mtime, sha256), the
                                container probe, the scope and time basis, the
                                resolved engine config and module digests
    {"kind":"progress", ...}    frames decoded/scored, detections, live tracks,
                                percent of the bounded analysis window
    {"kind":"obs", ...}         one ACCEPTED observation: track, t_ms, box, status
    {"kind":"closed", ...}      one episode as it closes
    {"kind":"result", ...}      the complete run document (tracks, counts,
                                coverage, problems, status)

A refusal or crash prints {"kind":"error", ...} and exits non-zero. SIGTERM
stops the decode at the next frame and reports status "cancelled" -- a cancelled
run is a cancelled run, never a quiet success.

WHAT THIS FILE WILL NOT DO. It never invents a camera, a wall clock or a
detection: the scope comes from the caller's flags, the footage origin from
`--origin-epoch-ms` (absent means every time in the document is clip-relative
and says so), and every box comes from the analyser's blobs for a decoded frame.
Frames whose rounded millisecond equals the previous one are DROPPED and counted
(`dropped_same_ms`), because the engine's time order is strict; they are reported,
not merged and not silently lost. Frames past `--max-frames` / `--max-seconds`
end the analysis window and the document's `coverage` says exactly how much of
the clip was analysed, so a bounded run never reads as a complete one.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import signal
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import frame_source as fs                                    # noqa: E402
import labs_foreground_mask as fm                            # noqa: E402
import temporal_tracks as tt                                 # noqa: E402
import temporal_tracks_adapter as ad                         # noqa: E402
from temporal_tracks import Tracker, TrackingError            # noqa: E402

RUN_SCHEMA = "watchtower-temporal-tracks-run/v1"
ENGINE_MODULES = ("temporal_tracks.py", "temporal_tracks_matching.py",
                  "temporal_tracks_adapter.py", "temporal_tracks_clip.py")

_stop = {"flag": False}


def _on_term(_signum, _frame):
    _stop["flag"] = True


def _say(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=True, allow_nan=False,
                                separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _sha256(path: str, limit_bytes: int | None = None) -> str:
    h = hashlib.sha256()
    read = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
            read += len(chunk)
            if limit_bytes is not None and read >= limit_bytes:
                break
    return h.hexdigest()


def _module_digests() -> dict:
    out = {}
    for name in ENGINE_MODULES:
        p = os.path.join(HERE, name)
        try:
            out[name] = _sha256(p)
        except OSError:
            out[name] = None
    return out


def _fail(code: str, message: str) -> int:
    _say({"kind": "error", "code": code, "message": message})
    return 3


def cmd_probe(args) -> int:
    """Cheap input identity + container facts, for the picker and cache keys."""
    if not os.path.isfile(args.input):
        return _fail("input_missing", f"no such file: {args.input}")
    st = os.stat(args.input)
    try:
        pr = fs.probe(args.input, measure_gop=False)
    except Exception as e:                                  # noqa: BLE001
        return _fail("probe_failed", f"ffmpeg could not probe {args.input}: {e}")
    _say({"kind": "meta", "input": {"path": args.input, "size": st.st_size,
                                    "mtime_ms": int(st.st_mtime * 1000),
                                    "sha256": _sha256(args.input)},
          "probe": {"width": pr.width, "height": pr.height, "codec": pr.codec,
                    "fps": pr.fps, "pix_fmt": pr.pix_fmt}})
    return 0


def cmd_analyze(args) -> int:
    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)
    started = time.monotonic()
    if not os.path.isfile(args.input):
        return _fail("input_missing", f"no such file: {args.input}")
    st = os.stat(args.input)
    input_id = {"path": os.path.abspath(args.input), "size": st.st_size,
                "mtime_ms": int(st.st_mtime * 1000), "sha256": _sha256(args.input)}
    try:
        pr = fs.probe(args.input, measure_gop=False)
    except Exception as e:                                  # noqa: BLE001
        return _fail("probe_failed", f"ffmpeg could not probe {args.input}: {e}")
    if pr.width <= 0 or pr.height <= 0:
        return _fail("probe_failed", f"{args.input} has no video stream")

    try:
        cfg = tt.resolve_config(json.loads(args.config) if args.config else None)
    except TrackingError as e:
        return _fail(e.code, f"engine configuration refused: {e}")
    except ValueError as e:
        return _fail("invalid_input", f"engine configuration is not JSON: {e}")

    origin = args.origin_epoch_ms
    time_basis = "wall-clock" if origin is not None else "clip-relative"
    _say({"kind": "meta", "run_id": args.run_id, "started_at": _now(),
          "input": input_id,
          "probe": {"width": pr.width, "height": pr.height, "codec": pr.codec,
                    "fps": pr.fps, "pix_fmt": pr.pix_fmt},
          "scope": {"camera_id": args.camera_id, "unit_id": args.unit_id,
                    "origin_epoch_ms": origin, "time_basis": time_basis,
                    "label_from_file_name": args.label or None},
          "config": cfg,
          "engine": {"revision": args.revision or "unknown",
                     "python": sys.version.split()[0],
                     "modules": _module_digests()},
          "limits": {"max_frames": args.max_frames, "max_seconds": args.max_seconds}})

    tracker = Tracker(args.camera_id, args.unit_id, cfg)
    duration_s = _duration_s(args.input, pr)
    window_s = min(args.max_seconds, duration_s) if duration_s else args.max_seconds

    frames_decoded = 0
    frames_scored = 0
    dropped_same_ms = 0
    detections = 0
    assigned = 0
    born = matched = ambiguous = 0
    resets = 0
    observations: list[dict] = []
    episodes: list[dict] = []
    problems: list[str] = []
    status = "completed"
    seq = 0
    last_run = None
    last_t_ms = None
    cancelled = False
    failed: tuple[str, str] | None = None

    try:
        # Every decoded frame of the bounded window, at the decoder's own times:
        # frame_source's step_s only RE-TIMES frames, it never samples them, so
        # passing one here would label real frames with invented timestamps.
        frames = fs.iter_frames(args.input, keyframes_only=False)
        # PRIME mode is the analyser's own answer to "score this bounded window":
        # the model sees the window once in reverse first, so a 10 s clip is not
        # swallowed whole by stream mode's 30 s warm-up. Windows longer than
        # config.prime_max_frames are cut into consecutive runs, each primed on
        # itself, and each cut arrives here as a new `run` -> a declared reset.
        masks = fm.iter_masks(frames, prime=True)
        for mask in masks:
            if _stop["flag"]:
                status = "cancelled"
                cancelled = True
                break
            if mask.t_s is not None and mask.t_s > window_s:
                problems.append(f"analysis window ends at {window_s:.1f} s of a "
                                f"{duration_s:.1f} s clip; the rest was not analysed")
                break
            frames_decoded += 1
            if not mask.scored:
                continue
            frames_scored += 1
            batch = ad.mask_frame_batch(mask, camera_id=args.camera_id,
                                        unit_id=args.unit_id, seq=seq,
                                        previous_run=last_run)
            if batch["reset"]:
                resets += 1
            last_run = mask.run
            if last_t_ms is not None and batch["t_ms"] <= last_t_ms:
                # The engine's time order is strict; a frame that rounds onto the
                # previous millisecond is reported as dropped, never merged.
                dropped_same_ms += 1
                continue
            last_t_ms = batch["t_ms"]
            boxes = {d["id"]: d["bbox"] for d in batch["detections"]}
            receipt = tracker.feed(batch)
            seq += 1
            detections += len(batch["detections"])
            for a in receipt["assignments"]:
                assigned += 1
                if a["status"] == "born":
                    born += 1
                elif a["status"] == "matched":
                    matched += 1
                else:
                    ambiguous += 1
                if a["status"] != "ambiguous":
                    if len(observations) < args.max_observations:
                        ob = {"track": a["track_id"], "t_ms": batch["t_ms"],
                              "bbox": boxes[a["detection_id"]], "status": a["status"]}
                        observations.append(ob)
                        _say({"kind": "obs", **ob})
                    elif len(observations) == args.max_observations:
                        problems.append("observation list truncated at "
                                        f"{args.max_observations}; counts are complete")
                        observations.append({"truncated": True})
            for ep in tracker.drain():
                episodes.append(ep)
                _say({"kind": "closed", "episode": _episode_view(ep, origin)})
            if frames_decoded % 25 == 0 or frames_decoded == 1:
                pct = int(min(100.0, (mask.t_s or 0.0) / window_s * 100.0)) if window_s else 0
                _say({"kind": "progress", "frame": frames_decoded, "scored": frames_scored,
                      "t_s": mask.t_s, "detections": detections,
                      "live_tracks": born - len(episodes), "percent": pct})
            if frames_decoded >= args.max_frames:
                problems.append(f"analysis stopped at --max-frames={args.max_frames} of "
                                f"{duration_s:.1f} s; the rest was not analysed")
                break
    except TrackingError as e:
        failed = (e.code, str(e))
        status = "failed"
    except Exception as e:                                  # noqa: BLE001
        failed = ("analysis_error", f"{type(e).__name__}: {e}")
        status = "failed"

    closed_by_finish: list[str] = []
    if failed is None and not cancelled:
        try:
            closed_by_finish = tracker.finish()
            for ep in tracker.drain():
                episodes.append(ep)
        except TrackingError as e:
            failed = (e.code, str(e))
            status = "failed"
    elif cancelled:
        try:
            tracker.finish()
            episodes.extend(tracker.drain())
        except TrackingError:
            pass

    elapsed = time.monotonic() - started
    doc = {
        "kind": "result",
        "schema": RUN_SCHEMA,
        "run_id": args.run_id,
        "status": status,
        "started_at": _now(),
        "elapsed_s": round(elapsed, 3),
        "input": input_id,
        "probe": {"width": pr.width, "height": pr.height, "codec": pr.codec,
                  "fps": pr.fps, "pix_fmt": pr.pix_fmt},
        "scope": {"camera_id": args.camera_id, "unit_id": args.unit_id,
                  "origin_epoch_ms": origin, "time_basis": time_basis,
                  "label_from_file_name": args.label or None},
        "config": cfg,
        "engine": {"revision": args.revision or "unknown", "python": sys.version.split()[0],
                   "modules": _module_digests()},
        "decode": {"frames_decoded": frames_decoded, "frames_scored": frames_scored,
                   "dropped_same_ms": dropped_same_ms, "resets": resets,
                   "duration_s": duration_s, "window_s": window_s,
                   "coverage": (window_s / duration_s) if duration_s else None},
        "counts": {"detections": detections, "assigned": assigned, "born": born,
                   "matched": matched, "ambiguous": ambiguous,
                   "tracks": born, "episodes": len(episodes),
                   "closed_by_finish": len(closed_by_finish)},
        "observations": observations,
        "tracks": [_episode_view(e, origin) for e in episodes],
        "problems": problems,
    }
    if failed is not None:
        doc["error"] = {"code": failed[0], "message": failed[1]}
    _say(doc)
    if failed is not None:
        return 4
    return 0 if status == "completed" else (130 if cancelled else 4)


def _duration_s(path: str, pr) -> float:
    try:
        import subprocess
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                              "-of", "default=noprint_wrappers=1:nokey=1", path],
                             capture_output=True, timeout=20)
        return float(out.stdout.decode().strip() or 0.0)
    except Exception:                                       # noqa: BLE001
        return 0.0


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _episode_view(ep: dict, origin: int | None) -> dict:
    """The episode as the product shows it: evidence plus an explicit time basis."""
    out = dict(ep)
    out["start_ms_clip"] = ep["start_ms"]
    out["end_ms_clip"] = ep["end_ms"]
    if origin is not None:
        out["start_wall_ms"] = origin + ep["start_ms"]
        out["end_wall_ms"] = origin + ep["end_ms"]
    out["uncertain"] = ep["ambiguous_batches"] > 0
    return out


def _detach_stdin() -> None:
    # ffmpeg reads its stdin for interactive keys. An inherited pipe that never
    # reaches EOF makes a probe block until its own timeout (measured on this
    # box: a 120 s probe timeout under a held-open shell pipe). The product
    # launches this job with a null stdin; make every other invocation safe too.
    try:
        fd = os.open(os.devnull, os.O_RDONLY)
        if fd != 0:
            os.dup2(fd, 0)
            os.close(fd)
    except OSError:
        pass


def main(argv=None) -> int:
    _detach_stdin()
    ap = argparse.ArgumentParser(prog="temporal_tracks_clip", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("probe")
    p.add_argument("--input", required=True)
    a = sub.add_parser("analyze")
    a.add_argument("--input", required=True)
    a.add_argument("--run-id", default="run")
    a.add_argument("--camera-id", default="local-clip")
    a.add_argument("--unit-id", default="watchtower-labs")
    a.add_argument("--label", default="")
    a.add_argument("--origin-epoch-ms", type=int, default=None)
    a.add_argument("--config", default="")
    a.add_argument("--revision", default="")
    a.add_argument("--max-frames", type=int, default=6000)
    a.add_argument("--max-seconds", type=float, default=120.0)
    a.add_argument("--max-observations", type=int, default=20000)
    args = ap.parse_args(argv)
    if args.cmd == "probe":
        return cmd_probe(args)
    return cmd_analyze(args)


if __name__ == "__main__":
    sys.exit(main())
