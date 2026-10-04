#!/usr/bin/env python3
"""In-product Labs tracking run: one recording -> detections -> tracks.

WHAT THIS IS. The bridge between a recording an operator picked in Watchtower
and the temporal tracking engine (`temporal_tracks.py`). It decodes the
recording with the SAME decoder the Labs worker uses (`frame_source`, one
software ffmpeg, PTS-driven), detects with the SAME analyser the worker uses
(`labs_foreground_mask` — MOG2 over a primed window, cleaned blobs), maps each
`MaskFrame` to a contract batch with `temporal_tracks_adapter.mask_frame_batch`
and feeds the engine. Nothing here invents a detection: every box in the result
came out of the mask pipeline on real frames, and every track is the engine's
own output. There is no model, no classifier and no footage of its own.

BOUNDED AND STREAMING. The run is bounded by `max_frames` and `duration_s`; the
per-frame evidence ledger is written to disk as it is produced and the engine's
outbox is drained into `tracks.jsonl` as episodes close, so nothing accumulates
in memory except the tracker's own bounded state (config `max_tracks`,
`path_points`, `replay_batches`, `max_pending`).

stdout is JSONL progress for the app; the run directory is the evidence:

    run.json          identity, hash, time mapping, config, status, measurements
    frames.jsonl      one line per processed frame: t_ms, run, scored, detections
                      with each detection's own receipt (track_id/status/reason)
    tracks.jsonl      one line per closed episode, as the engine emitted it
    tracks.json       the same episodes as a JSON array (convenience for the UI)
    engine_snapshot.json  the final contract checkpoint (reproducible state)

Usage:
    temporal_tracks_run.py --job job.json --out DIR [--reuse frames.jsonl]
    temporal_tracks_run.py --out DIR --recording FILE --camera CAM [options]

Exit codes: 0 completed, 1 failed, 3 cancelled (partial evidence kept).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import frame_source as fs                    # noqa: E402  (existing decoder)
import labs_foreground_mask as fm            # noqa: E402  (existing detector)
import temporal_tracks as TT                 # noqa: E402
import temporal_tracks_adapter as TA         # noqa: E402

VERSION = "labs-tracking-run/1"
EXIT_OK, EXIT_FAILED, EXIT_CANCELLED = 0, 1, 3

_STOP = {"asked": False, "signal": None}


def _on_signal(signum, _frame):
    _STOP["asked"] = True
    _STOP["signal"] = signum


def emit(event: dict) -> None:
    """One JSONL progress record on stdout, flushed for a line-reading parent."""
    sys.stdout.write(json.dumps(event, ensure_ascii=True) + "\n")
    sys.stdout.flush()


def sha256_file(path: str, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            block = fh.read(chunk)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def _iso(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(float(value), timezone.utc).isoformat()
    text = str(value).strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        stamp = datetime.fromisoformat(text)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(timezone.utc).isoformat()


def guess_start_from_name(path: str):
    """A wall-clock start PARSEABLE from the file name, or None.

    Never a guess dressed as metadata: the caller records that this value came
    from the name, and the operator can correct it before the run.
    """
    stem = Path(path).stem
    for token in reversed(stem.replace("-", "_").split("_")):
        for fmt in ("%Y%m%d_%H%M%S", "%Y%m%d%H%M%S", "%Y%m%d_%H%M", "%Y%m%d%H%M"):
            try:
                stamp = datetime.strptime(token, fmt)
            except ValueError:
                continue
            return stamp.replace(tzinfo=timezone.utc).isoformat()
    # The stamp usually spans two underscore-separated tokens (date_time).
    parts = stem.replace("-", "_").split("_")
    for i in range(len(parts) - 1):
        joined = parts[i] + "_" + parts[i + 1]
        try:
            stamp = datetime.strptime(joined, "%Y%m%d_%H%M%S")
        except ValueError:
            continue
        return stamp.replace(tzinfo=timezone.utc).isoformat()
    return None


def _ffprobe_start(path: str):
    """The container's own creation_time, if it carries one. Metadata, recorded
    as such -- never inferred from the picture or from the file's mtime."""
    try:
        pr = fs.probe(path)
    except Exception:
        return None
    for attr in ("creation_time", "start_time_utc"):
        value = getattr(pr, attr, None)
        if value:
            stamp = _iso(value)
            if stamp:
                return stamp
    return None


def _probe_summary(path: str) -> dict:
    try:
        pr = fs.probe(path, measure_gop=False)
    except Exception as exc:                     # noqa: BLE001
        return {"ok": False, "error": str(exc)[:300]}
    info = {"ok": True}
    for name in ("width", "height", "fps", "pix_fmt", "duration_s", "frames",
                 "codec", "creation_time"):
        if hasattr(pr, name):
            info[name] = getattr(pr, name)
    return info


class Ledger:
    """Per-frame evidence, streamed to disk; the app indexes it by time."""

    def __init__(self, path: Path):
        self.path = path
        self.fh = open(path, "w", encoding="utf-8")
        self.frames = 0
        self.detections = 0
        self.empty_frames = 0
        self.first_t_ms = None
        self.last_t_ms = None
        self.runs = 0
        self._run_seen = None

    def frame(self, t_ms, run, scored, records):
        self.frames += 1
        self.detections += len(records)
        if not records:
            self.empty_frames += 1
        if self.first_t_ms is None:
            self.first_t_ms = t_ms
        self.last_t_ms = t_ms
        if run != self._run_seen:
            self._run_seen = run
            self.runs += 1
        self.fh.write(json.dumps({"t_ms": t_ms, "run": run, "scored": scored,
                                  "detections": records}, ensure_ascii=True) + "\n")

    def close(self):
        try:
            self.fh.flush()
            os.fsync(self.fh.fileno())
        except OSError:
            pass
        self.fh.close()


def run_job(job: dict, out_dir: Path) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    started = time.time()
    recording = job.get("recording") or ""
    camera_id = str(job.get("camera_id") or "recording")
    unit_id = str(job.get("unit_id") or "labs-tracking")
    config = job.get("config") or {}
    max_frames = int(job.get("max_frames") or 900)
    duration_s = float(job.get("duration_s") or 0.0)
    start_offset_s = float(job.get("start_offset_s") or 0.0)
    every_nth = max(1, int(job.get("every_nth") or 1))
    start_utc = _iso(job.get("recording_start_utc"))
    mapping_source = job.get("time_mapping_source") or "operator"

    meta = {
        "version": VERSION,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "recording": recording,
        "recording_name": Path(recording).name if recording else None,
        "camera_id": camera_id,
        "unit_id": unit_id,
        "config": config,
        "bounds": {"max_frames": max_frames, "duration_s": duration_s,
                   "start_offset_s": start_offset_s, "every_nth": every_nth},
        "time_mapping": {"recording_start_utc": start_utc,
                         "source": mapping_source},
        "host": {"python": sys.version.split()[0], "platform": sys.platform},
    }

    ledger = Ledger(out_dir / "frames.jsonl")
    tracks_fh = open(out_dir / "tracks.jsonl", "w", encoding="utf-8")
    episodes = []
    tracker = None
    engine_error = None
    try:
        tracker = TT.Tracker(camera_id, unit_id, config)
    except TT.TrackingError as exc:
        meta["status"] = "failed"
        meta["error"] = {"code": exc.code, "message": str(exc)}
        _write_run(out_dir, meta, ledger, tracks_fh, started)
        emit({"event": "failed", "code": exc.code, "message": str(exc)})
        return EXIT_FAILED

    # ---- identity ------------------------------------------------------------
    if not recording or not os.path.isfile(recording):
        meta["status"] = "failed"
        meta["error"] = {"code": "missing_recording",
                         "message": "no readable recording at %r" % recording}
        _write_run(out_dir, meta, ledger, tracks_fh, started)
        emit({"event": "failed", "code": "missing_recording",
              "message": meta["error"]["message"]})
        return EXIT_FAILED
    try:
        meta["recording_sha256"] = sha256_file(recording)
        st = os.stat(recording)
        meta["recording_bytes"] = st.st_size
    except OSError as exc:
        meta["status"] = "failed"
        meta["error"] = {"code": "unreadable_recording", "message": str(exc)}
        _write_run(out_dir, meta, ledger, tracks_fh, started)
        emit({"event": "failed", "code": "unreadable_recording",
              "message": str(exc)})
        return EXIT_FAILED
    meta["probe"] = _probe_summary(recording)
    emit({"event": "started", "recording": recording,
          "sha256": meta["recording_sha256"],
          "bytes": meta["recording_bytes"], "probe": meta["probe"]})

    # ---- frames --------------------------------------------------------------
    frames = _frames(job, every_nth, start_offset_s)

    # ---- detections -> batches -> tracks ------------------------------------
    seq = 0
    previous_run = None
    last_report = 0.0
    status = "completed"
    counts = {"born": 0, "matched": 0, "ambiguous": 0}
    try:
        for mf in fm.iter_masks(frames, prime=True):
            if _STOP["asked"]:
                status = "cancelled"
                break
            if seq >= max_frames:
                break
            t_ms = fs_frame_ms(mf)
            if t_ms is None:
                continue
            batch = TA.mask_frame_batch(mf, camera_id=camera_id, unit_id=unit_id,
                                        seq=seq, previous_run=previous_run)
            previous_run = mf.run
            receipt = tracker.feed(batch)
            by_id = {a["detection_id"]: a for a in receipt["assignments"]}
            records = []
            for det in batch["detections"]:
                a = by_id.get(det["id"])
                if a is None:
                    continue
                records.append({"id": det["id"], "bbox": det["bbox"],
                                "track_id": a["track_id"], "status": a["status"],
                                "reason": a["reason"]})
                counts[a["status"]] = counts.get(a["status"], 0) + 1
            ledger.frame(t_ms, mf.run, bool(mf.scored), records)
            for ep in tracker.drain():
                episodes.append(ep)
                tracks_fh.write(json.dumps(ep, ensure_ascii=True) + "\n")
                emit({"event": "track", "episode": ep})
            seq += 1
            now = time.time()
            if now - last_report > 0.4:
                last_report = now
                emit({"event": "progress", "batches": seq,
                      "t_ms": t_ms, "frames": ledger.frames,
                      "detections": ledger.detections,
                      "tracks_closed": len(episodes),
                      "elapsed_s": round(now - started, 3)})
    except TT.TrackingError as exc:
        status = "failed"
        engine_error = {"code": exc.code, "message": str(exc)}
    except Exception as exc:                     # noqa: BLE001
        status = "failed"
        engine_error = {"code": "decode_or_engine_error",
                        "message": "%s: %s" % (type(exc).__name__, str(exc)[:300])}

    # finish the engine (still counts as a completed run unless it was cancelled
    # or already failed): closing the remaining tracks is part of the analysis.
    if status == "completed" and tracker is not None:
        try:
            tracker.finish()
            for ep in tracker.drain():
                episodes.append(ep)
                tracks_fh.write(json.dumps(ep, ensure_ascii=True) + "\n")
                emit({"event": "track", "episode": ep})
        except TT.TrackingError as exc:
            status = "failed"
            engine_error = {"code": exc.code, "message": str(exc)}

    if engine_error:
        meta["error"] = engine_error
    meta["status"] = status
    meta["counts"] = counts
    meta["frames"] = ledger.frames
    meta["detections"] = ledger.detections
    meta["empty_frames"] = ledger.empty_frames
    meta["model_runs"] = ledger.runs
    meta["tracks"] = len(episodes)
    meta["timeline"] = {"first_t_ms": ledger.first_t_ms,
                        "last_t_ms": ledger.last_t_ms}
    if tracker is not None:
        try:
            (out_dir / "engine_snapshot.json").write_text(
                json.dumps(tracker.snapshot(), sort_keys=True), encoding="utf-8")
        except Exception:                        # noqa: BLE001
            pass

    _write_run(out_dir, meta, ledger, tracks_fh, started)
    (out_dir / "tracks.json").write_text(
        json.dumps(episodes, sort_keys=True), encoding="utf-8")

    summary = {"event": "finished" if status == "completed" else status,
               "status": status, "frames": ledger.frames,
               "detections": ledger.detections, "tracks": len(episodes),
               "empty_frames": ledger.empty_frames, "counts": counts,
               "elapsed_s": round(time.time() - started, 3),
               "run_dir": str(out_dir)}
    if engine_error:
        summary["error"] = engine_error
    emit(summary)
    if status == "cancelled":
        return EXIT_CANCELLED
    return EXIT_FAILED if status == "failed" else EXIT_OK


def fs_frame_ms(mf) -> int:
    """The frame's own millisecond clock; the adapter's rounding, reused."""
    t_s = getattr(mf, "t_s", None)
    if t_s is None:
        return None
    return int(float(t_s) * 1000.0 + 0.5)


def _frames(job, every_nth, start_offset_s):
    """The real decoder: frame_source's own ffmpeg pass over the recording."""
    kwargs = {"keyframes_only": False}
    if start_offset_s > 0:
        kwargs["t0"] = start_offset_s
    it = fs.iter_frames(job.get("recording"), **kwargs)
    if every_nth > 1:
        it = (f for i, f in enumerate(it) if i % every_nth == 0)
    return it


def _write_run(out_dir, meta, ledger, tracks_fh, started):
    ledger.close()
    try:
        tracks_fh.flush()
        os.fsync(tracks_fh.fileno())
    except OSError:
        pass
    tracks_fh.close()
    meta["elapsed_s"] = round(time.time() - started, 3)
    meta["finished_utc"] = datetime.now(timezone.utc).isoformat()
    meta["frames"] = ledger.frames
    meta["detections"] = ledger.detections
    (out_dir / "run.json").write_text(json.dumps(meta, indent=2, sort_keys=True),
                                      encoding="utf-8")


# ----------------------------------------------------------------------------------
# engine-only replay: rebuild batches from a previous run's frame ledger
# ----------------------------------------------------------------------------------
def run_engine_only(job: dict, out_dir: Path, ledger_path: str) -> int:
    """Feed the engine from a stored frame ledger (no ffmpeg, no mask model)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    started = time.time()
    meta = json.loads((Path(ledger_path).parent / "run.json").read_text()) \
        if (Path(ledger_path).parent / "run.json").is_file() else {}
    identity = {"version": VERSION, "mode": "engine-only",
                "started_utc": datetime.now(timezone.utc).isoformat(),
                "reused_ledger": str(ledger_path),
                "source_run": meta.get("recording"),
                "source_sha256": meta.get("recording_sha256"),
                "time_mapping": meta.get("time_mapping"),
                "camera_id": job.get("camera_id") or meta.get("camera_id"),
                "unit_id": job.get("unit_id") or meta.get("unit_id"),
                "config": job.get("config") or {}}
    camera_id = str(identity["camera_id"] or "recording")
    unit_id = str(identity["unit_id"] or "labs-tracking")
    ledger = Ledger(out_dir / "frames.jsonl")
    tracks_fh = open(out_dir / "tracks.jsonl", "w", encoding="utf-8")
    episodes = []
    try:
        tracker = TT.Tracker(camera_id, unit_id, identity["config"])
    except TT.TrackingError as exc:
        identity["status"] = "failed"
        identity["error"] = {"code": exc.code, "message": str(exc)}
        _write_run(out_dir, identity, ledger, tracks_fh, started)
        emit({"event": "failed", "code": exc.code, "message": str(exc)})
        return EXIT_FAILED

    counts = {"born": 0, "matched": 0, "ambiguous": 0}
    status = "completed"
    seq = 0
    previous_run = None
    try:
        with open(ledger_path, encoding="utf-8") as fh:
            for line in fh:
                if _STOP["asked"]:
                    status = "cancelled"
                    break
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                detections = [{"id": d["id"], "bbox": d["bbox"]}
                              for d in row.get("detections", [])]
                run = int(row.get("run") or 0)
                # Stored boxes, not pixels: the engine-only path, so the batch is
                # built directly -- there is no MaskFrame here to adapt.
                batch = {"camera_id": camera_id, "unit_id": unit_id, "seq": seq,
                         "t_ms": int(row["t_ms"]), "detections": detections,
                         "reset": previous_run is not None and run != previous_run}
                previous_run = run
                receipt = tracker.feed(batch)
                by_id = {a["detection_id"]: a for a in receipt["assignments"]}
                records = []
                for det in detections:
                    a = by_id.get(det["id"])
                    if a is None:
                        continue
                    records.append({"id": det["id"], "bbox": det["bbox"],
                                    "track_id": a["track_id"],
                                    "status": a["status"], "reason": a["reason"]})
                    counts[a["status"]] = counts.get(a["status"], 0) + 1
                ledger.frame(int(row["t_ms"]), run, bool(row.get("scored", True)),
                             records)
                for ep in tracker.drain():
                    episodes.append(ep)
                    tracks_fh.write(json.dumps(ep, ensure_ascii=True) + "\n")
                    emit({"event": "track", "episode": ep})
                seq += 1
    except TT.TrackingError as exc:
        status, identity["error"] = "failed", {"code": exc.code,
                                               "message": str(exc)}
    except Exception as exc:                      # noqa: BLE001
        status = "failed"
        identity["error"] = {"code": "ledger_error",
                             "message": "%s: %s" % (type(exc).__name__,
                                                    str(exc)[:300])}
    if status == "completed":
        try:
            tracker.finish()
            for ep in tracker.drain():
                episodes.append(ep)
                tracks_fh.write(json.dumps(ep, ensure_ascii=True) + "\n")
                emit({"event": "track", "episode": ep})
        except TT.TrackingError as exc:
            status, identity["error"] = "failed", {"code": exc.code,
                                                   "message": str(exc)}
    identity.update({"status": status, "counts": counts,
                     "frames": ledger.frames, "detections": ledger.detections,
                     "empty_frames": ledger.empty_frames,
                     "model_runs": ledger.runs, "tracks": len(episodes),
                     "timeline": {"first_t_ms": ledger.first_t_ms,
                                  "last_t_ms": ledger.last_t_ms}})
    _write_run(out_dir, identity, ledger, tracks_fh, started)
    (out_dir / "tracks.json").write_text(json.dumps(episodes, sort_keys=True),
                                         encoding="utf-8")
    emit({"event": "finished" if status == "completed" else status,
          "status": status, "frames": ledger.frames, "tracks": len(episodes),
          "detections": ledger.detections, "counts": counts,
          "elapsed_s": round(time.time() - started, 3), "run_dir": str(out_dir)})
    if status == "cancelled":
        return EXIT_CANCELLED
    return EXIT_FAILED if status == "failed" else EXIT_OK


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--job", help="JSON job file")
    ap.add_argument("--out", required=True, help="run directory")
    ap.add_argument("--reuse", help="frames.jsonl of a previous run (engine only)")
    ap.add_argument("--recording")
    ap.add_argument("--camera")
    ap.add_argument("--unit", default="labs-tracking")
    ap.add_argument("--max-frames", type=int, default=900)
    ap.add_argument("--duration-s", type=float, default=0.0)
    ap.add_argument("--start-offset-s", type=float, default=0.0)
    ap.add_argument("--every-nth", type=int, default=1)
    ap.add_argument("--start-utc")
    ap.add_argument("--mapping-source", default="operator")
    ap.add_argument("--config", help="JSON engine config")
    ap.add_argument("--probe", action="store_true",
                    help="report the recording's probe and exit")
    args = ap.parse_args(argv)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    job = {}
    if args.job:
        job = json.loads(Path(args.job).read_text(encoding="utf-8"))
    for key, value in (("recording", args.recording), ("camera_id", args.camera),
                       ("unit_id", args.unit), ("max_frames", args.max_frames),
                       ("duration_s", args.duration_s),
                       ("start_offset_s", args.start_offset_s),
                       ("every_nth", args.every_nth),
                       ("recording_start_utc", args.start_utc),
                       ("time_mapping_source", args.mapping_source)):
        if value not in (None, "") and not job.get(key):
            job[key] = value
    if args.config:
        job["config"] = json.loads(args.config)
    out = Path(args.out)

    if args.probe:
        info = {"probe": _probe_summary(job.get("recording") or ""),
                "suggested_start_utc": _ffprobe_start(job.get("recording") or "")
                or guess_start_from_name(job.get("recording") or ""),
                "suggested_start_source": ("file-metadata"
                                           if _ffprobe_start(job.get("recording") or "")
                                           else "filename")}
        print(json.dumps(info, indent=2, sort_keys=True))
        return EXIT_OK

    try:
        if args.reuse:
            return run_engine_only(job, out, args.reuse)
        return run_job(job, out)
    except Exception as exc:                      # noqa: BLE001
        emit({"event": "failed", "code": "runner_error",
              "message": "%s: %s" % (type(exc).__name__, str(exc)[:400])})
        return EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main())
