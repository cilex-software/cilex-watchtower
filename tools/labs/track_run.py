#!/usr/bin/env python3
"""track_run — the product-owned helper behind Watchtower's Labs Tracking view.

The app (src/models/LabsTrackRunner.cpp) spawns this script as a child process;
nothing here runs on the UI thread and every long job is cancellable by killing
the process (the evidence file is only ever replaced atomically at completion, so
a cancelled run leaves no "completed" record). Three subcommands:

    probe   identity of one local recording file: size, sha256, the real
            codec/geometry/rate out of the bytes (frame_source.probe), container
            start and duration, and a SUGGESTED scope/time mapping parsed from a
            Watchtower export name. Suggestions are labelled by origin; the
            operator confirms them in the UI. Nothing is invented.

    run     decode the file (frame_source, software ffmpeg), extract foreground
            detections with the existing B3 pipeline (labs_foreground_mask,
            primed mode per bounded clip), map them through
            temporal_tracks_adapter.mask_frame_batch and run the temporal_tracks
            engine. Writes one atomic evidence JSON (schema labs-track-run/v1)
            carrying input identity/hash, engine file hashes + source revision,
            resolved config, per-batch assignment evidence, and the closed
            episodes. Progress goes to stderr as `WTTRACK progress <permille> <msg>`.

    verify  stream one check suite as JSONL on stdout:
            {"type":"check","suite","name","status":"pass|fail|skip","detail","seconds"}
            terminated by {"type":"summary",...}. Suites: "contract" (the engine's
            own test module incl. the public cases), "regressions" (the Labs worker
            suite and the two analyser self-tests, run as-is), "workload" (the
            contract's streaming resource workload with its measurements), and
            "integration" (the same helper path the operator's run uses: real
            decode of a generated synthetic clip, evidence identity, timestamp
            alignment, replay, error surfacing, cancellation, repeat-run
            determinism). --failure-control appends one check that FAILS by
            construction, proving a red failure renders in the product.

This is a development/review tool: it never contacts the network, never starts
the worker, and never writes outside the evidence path it is handed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

LABS_DIR = Path(__file__).resolve().parent
REPO_ROOT = LABS_DIR.parents[1]
sys.path.insert(0, str(LABS_DIR))

SCHEMA = "labs-track-run/v1"
DEFAULT_UNIT = "local-review"


def _emit(obj) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=True, allow_nan=False) + "\n")
    sys.stdout.flush()


def _progress(permille: int, msg: str) -> None:
    sys.stderr.write(f"WTTRACK progress {int(permille)} {msg}\n")
    sys.stderr.flush()


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            c = f.read(1 << 20)
            if not c:
                break
            h.update(c)
    return h.hexdigest()


def _engine_identity() -> dict:
    files = {}
    for name in ("track_run.py", "temporal_tracks.py", "temporal_tracks_adapter.py",
                 "frame_source.py", "labs_foreground_mask.py"):
        p = LABS_DIR / name
        files[name] = _sha256_file(str(p)) if p.exists() else None
    head = None
    try:
        r = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT,
                           capture_output=True, timeout=10)
        if r.returncode == 0:
            head = r.stdout.decode().strip()
    except Exception:
        head = None
    return {"files_sha256": files, "source_revision": head}


_DURATION_RE = re.compile(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)")
_START_RE = re.compile(r"start:\s*([-0-9.]+)")
_EXPORT_NAME_RE = re.compile(r"^(.+?)_(\d{8})_(\d{6})\.[a-z0-9]+$")


def _container_info(ff: str, path: str) -> dict:
    """Duration and container start from `ffmpeg -i` stderr; nulls when absent."""
    out = {"duration_s": None, "container_start_s": None}
    try:
        p = subprocess.run([ff, "-hide_banner", "-i", path], capture_output=True,
                           timeout=120)
        err = p.stderr.decode("utf-8", "replace")
        m = _DURATION_RE.search(err)
        if m:
            out["duration_s"] = (int(m.group(1)) * 3600 + int(m.group(2)) * 60
                                 + float(m.group(3)))
        m = _START_RE.search(err)
        if m:
            out["container_start_s"] = float(m.group(1))
    except Exception:
        pass
    return out


def _suggest_from_name(path: str) -> dict:
    """A Watchtower export is <camera>_<yyyyMMdd>_<HHmmss>.<ext> in LOCAL time.
    Returned values are suggestions only — the UI says where they came from, and
    a name that cannot be a scope id (spaces, punctuation) is never suggested."""
    m = _EXPORT_NAME_RE.match(os.path.basename(path))
    if not m:
        return {"camera_id": None, "start_time": None}
    cam = m.group(1)
    if not _valid_scope(cam):
        cam = None
    try:
        naive = datetime.strptime(m.group(2) + m.group(3), "%Y%m%d%H%M%S")
        local = naive.astimezone()          # the machine's own zone, made explicit
        start = local.isoformat()
    except ValueError:
        start = None
    return {"camera_id": cam, "start_time": start if cam else None}


def _parse_iso(s: str) -> datetime:
    t = datetime.fromisoformat(s.replace("Z", "+00:00"))
    if t.tzinfo is None:
        raise ValueError("start time needs a timezone offset")
    return t


def _valid_scope(s: str) -> bool:
    return bool(re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}", s))


# ---------------------------------------------------------------------------
# probe
# ---------------------------------------------------------------------------
def cmd_probe(args) -> int:
    try:
        import frame_source as fs
        path = args.file
        if not os.path.isfile(path):
            raise ValueError(f"not a file: {path}")
        st = os.stat(path)
        info = {"path": os.path.abspath(path), "bytes": st.st_size,
                "sha256": _sha256_file(path)}
        try:
            pr = fs.probe(path)
            info["probe"] = {"width": pr.width, "height": pr.height,
                             "codec": pr.codec, "fps": pr.fps, "pix_fmt": pr.pix_fmt}
        except Exception as e:
            _emit({"ok": False, "error": {"code": "not_a_video",
                                          "message": f"could not read a video stream: {e}"}})
            return 2
        info.update(_container_info(fs.find_ffmpeg(), path))
        info["suggested"] = _suggest_from_name(path)
        _emit({"ok": True, "result": info})
        return 0
    except Exception as e:
        _emit({"ok": False, "error": {"code": "probe_failed", "message": str(e)}})
        return 2


# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
def cmd_run(args) -> int:
    evidence_path = args.out
    tmp_path = evidence_path + ".tmp"
    try:
        os.makedirs(os.path.dirname(os.path.abspath(evidence_path)), exist_ok=True)
        return _run(args, evidence_path, tmp_path)
    finally:
        try:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
        except OSError:
            pass


def _run(args, evidence_path: str, tmp_path: str) -> int:
    try:
        import cv2  # noqa: F401
    except ImportError:
        _progress(0, "OpenCV (cv2) is not installed in this Python; cannot decode")
        return 3
    import frame_source as fs
    import labs_foreground_mask as fm
    import temporal_tracks as tt
    import temporal_tracks_adapter as ta

    path = args.file
    camera_id = args.camera
    unit_id = args.unit
    if not _valid_scope(camera_id) or not _valid_scope(unit_id):
        _progress(0, "camera/unit id must match [A-Za-z0-9_.:-]{1,64}")
        return 2
    try:
        start_dt = _parse_iso(args.start)
    except ValueError as e:
        _progress(0, str(e))
        return 2
    try:
        config = json.loads(args.config) if args.config else None
        if config is not None and not isinstance(config, dict):
            raise ValueError("config must be a JSON object")
    except ValueError as e:
        _progress(0, f"bad config: {e}")
        return 2
    try:
        tr = tt.Tracker(camera_id=camera_id, unit_id=unit_id, config=config)
    except tt.TrackingError as e:
        _progress(0, f"config rejected: {e.code}: {e}")
        return 2
    t_start = time.perf_counter()
    _progress(0, "hashing input")
    input_identity = {"path": os.path.abspath(path), "bytes": os.path.getsize(path),
                      "sha256": _sha256_file(path)}
    _progress(5, "probing container")
    pr = fs.probe(path)
    cinfo = _container_info(fs.find_ffmpeg(), path)
    input_identity.update(cinfo)
    input_identity["probe"] = {"width": pr.width, "height": pr.height,
                               "codec": pr.codec, "fps": pr.fps,
                               "pix_fmt": pr.pix_fmt}
    every_nth = max(1, args.every_nth)
    input_identity["every_nth"] = every_nth
    input_identity["timing_mode"] = "fps-step"     # frame_source's documented step
    input_identity["mask_mode"] = "primed"

    stats = {"frames_decoded": 0, "frames_scored": 0, "warmup_frames": 0,
             "batches": 0, "detections": 0, "born": 0, "matched": 0, "ambiguous": 0,
             "resets": 0}
    assignments = []
    episodes = []
    total_frames = None
    if cinfo["duration_s"] and pr.fps:
        total_frames = max(1, int(cinfo["duration_s"] * pr.fps / every_nth))

    def decimated():
        for i, fr in enumerate(fs.iter_frames(path)):
            if i % every_nth == 0:
                stats["frames_decoded"] += 1
                yield fr

    _progress(8, "decoding and detecting")
    seq = 0
    prev_run = None
    last_t_s = 0.0
    duration_s = cinfo["duration_s"]
    try:
        for mf in fm.iter_masks(decimated(), prime=True):
            stats["frames_scored"] += 1
            last_t_s = mf.t_s if mf.t_s is not None else last_t_s
            if not mf.scored:
                stats["warmup_frames"] += 1
            batch = ta.mask_frame_batch(mf, camera_id=camera_id, unit_id=unit_id,
                                        seq=seq, previous_run=prev_run)
            if batch["reset"]:
                stats["resets"] += 1
            prev_run = mf.run
            receipt = tr.feed(batch)
            stats["batches"] += 1
            by_id = {d["id"]: d["bbox"] for d in batch["detections"]}
            for a in receipt["assignments"]:
                stats[a["status"]] += 1
                stats["detections"] += 1
                assignments.append({"t_ms": batch["t_ms"],
                                    "detection_id": a["detection_id"],
                                    "track_id": a["track_id"], "status": a["status"],
                                    "reason": a["reason"],
                                    "bbox": by_id[a["detection_id"]]})
            episodes.extend(tr.drain())
            seq += 1
            if seq % 25 == 0:
                frac = 10 + int(880 * min(1.0, mf.t_s / duration_s)) if duration_s else 100
                _progress(frac, f"tracking… frame {seq}")
    except tt.TrackingError as e:
        _progress(0, f"engine rejected the stream: {e.code}: {e}")
        return 3
    except Exception as e:
        _progress(0, f"decode/detect failed: {type(e).__name__}: {e}")
        return 3

    _progress(92, "finishing tracks")
    tr.finish()
    episodes.extend(tr.drain())
    wall_end_ms = int(round(last_t_s * 1000.0))
    evidence = {
        "schema": SCHEMA,
        "run_id": None,
        "created_local": datetime.now().astimezone().isoformat(),
        "status": "completed",
        "synthetic": bool(args.synthetic),
        "input": input_identity,
        "scope": {"camera_id": camera_id, "unit_id": unit_id},
        "wall": {"start_time": start_dt.isoformat(),
                 "end_time": datetime.fromtimestamp(
                     start_dt.timestamp() + wall_end_ms / 1000.0,
                     tz=start_dt.tzinfo).isoformat(),
                 "origin": args.origin},
        "engine": _engine_identity(),
        "config": tr.config,
        "stats": dict(stats, wall_seconds=round(time.perf_counter() - t_start, 3)),
        "assignments": assignments,
        "episodes": episodes,
    }
    rid_src = json.dumps({"in": input_identity["sha256"], "eng": evidence["engine"],
                          "cfg": evidence["config"], "scope": evidence["scope"],
                          "wall": evidence["wall"]["start_time"]},
                         sort_keys=True, separators=(",", ":"))
    evidence["run_id"] = hashlib.sha256(rid_src.encode()).hexdigest()[:16]
    _progress(97, "writing evidence")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(evidence, f, ensure_ascii=True, allow_nan=False)
        f.write("\n")
    os.replace(tmp_path, evidence_path)
    _progress(1000, f"done: {len(episodes)} track(s), {stats['detections']} detections")
    _emit({"ok": True, "result": {"run_id": evidence["run_id"], "episodes": len(episodes),
                                  "detections": stats["detections"],
                                  "evidence": os.path.abspath(evidence_path)}})
    return 0


# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
def _check(suite, name, status, detail="", seconds=0.0):
    _emit({"type": "check", "suite": suite, "name": name, "status": status,
           "detail": detail, "seconds": round(seconds, 3)})


def _relay_script(suite, argv, env_extra=None, timeout=1800):
    """Run a check script, relay its PASS/FAIL/SKIP or JSONL lines as checks."""
    t0 = time.perf_counter()
    passed = failed = skipped = 0
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, cwd=REPO_ROOT, env=env)
    timed_out = False
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        out, _ = p.communicate()
        timed_out = True
    saw_lines = False
    for line in out.splitlines():
        obj = None
        if line.startswith("{"):
            try:
                obj = json.loads(line)
            except ValueError:
                obj = None
        if obj and obj.get("type") == "check":
            _check(suite, f"{obj.get('suite', '')}:{obj['name']}" if obj.get("suite")
                   else obj["name"], obj["status"], obj.get("detail", ""),
                   obj.get("seconds", 0.0))
            saw_lines = True
            passed += obj["status"] == "pass"
            failed += obj["status"] == "fail"
            skipped += obj["status"] == "skip"
        elif obj and obj.get("type") == "measurement":
            obj["suite"] = suite
            _emit(obj)
        elif line.startswith("PASS "):
            saw_lines = True
            passed += 1
            _check(suite, line[5:], "pass")
        elif line.startswith("FAIL "):
            saw_lines = True
            failed += 1
            _check(suite, line[5:], "fail")
        elif line.startswith("SKIP "):
            saw_lines = True
            skipped += 1
            _check(suite, line[5:], "skip")
        elif line.startswith("run ") or line.startswith("median "):
            m = re.match(r"run (\d+): wall ([0-9.]+)s cpu ([0-9.]+)s peak_rss_delta "
                         r"([0-9.]+) MiB stats (.*)$", line)
            if m:
                _emit({"type": "measurement", "suite": suite, "run": int(m.group(1)),
                       "wall_s": float(m.group(2)), "cpu_s": float(m.group(3)),
                       "peak_rss_delta_mib": float(m.group(4)),
                       "stats": json.loads(m.group(5))})
                _check(suite, f"workload run {m.group(1)} completed within limits",
                       "pass", f"wall {m.group(2)} s, rss +{m.group(4)} MiB")
            else:
                m2 = re.match(r"median wall ([0-9.]+)s over (\d+) runs", line)
                if m2:
                    _emit({"type": "measurement", "suite": suite,
                           "median_wall_s": float(m2.group(1)),
                           "runs": int(m2.group(2))})
                    _check(suite, f"median wall {m2.group(1)} s over {m2.group(2)} runs",
                           "pass", "shared-host diagnostic, not a controlled score")
                else:
                    _check(suite, line, "pass", "measurement")
        elif line.startswith("workload") or line.startswith("warmup"):
            _emit({"type": "measurement", "suite": suite, "note": line})
    if timed_out:
        failed += 1
        _check(suite, "suite timed out", "fail", f"killed after {timeout} s")
    elif not saw_lines:
        # A suite that prints no per-check lines still reports its exit status.
        if p.returncode == 0:
            passed += 1
            _check(suite, Path(argv[-1]).name + " exited 0", "pass")
        else:
            failed += 1
            _check(suite, Path(argv[-1]).name + f" exited {p.returncode}", "fail",
                   out.strip().splitlines()[-1][:300] if out.strip() else "")
    elif p.returncode != 0 and failed == 0:
        failed += 1
        _check(suite, "suite exited nonzero without a FAIL line", "fail",
               f"exit {p.returncode}")
    return passed, failed, skipped, time.perf_counter() - t0


def _verify_contract(failure_control: bool):
    argv = [sys.executable, str(REPO_ROOT / "tools/tests/labs-temporal-tracks.py"),
            "--jsonl"]
    return _relay_script("contract", argv)


def _verify_regressions(failure_control: bool):
    total = [0, 0, 0, 0.0]
    for script in ("labs-worker.py",):
        r = _relay_script("regressions",
                          [sys.executable, str(REPO_ROOT / "tools/tests" / script)])
        total = [a + b for a, b in zip(total, r)]
    for script in ("selftest_shape_observations.py", "selftest_object_profile.py"):
        r = _relay_script("regressions",
                          [sys.executable, str(REPO_ROOT / "tools/labs" / script)])
        total = [a + b for a, b in zip(total, r)]
    return tuple(total)


def _verify_workload(failure_control: bool):
    argv = [sys.executable, str(REPO_ROOT / "tools/tests/labs-temporal-tracks.py"),
            "--workload"]
    return _relay_script("workload", argv)


def _make_synth_clip(path: str, seconds: float = 6.0, fps: int = 15,
                     hold_s: float = 1.0) -> dict:
    """A small real video file whose content we control exactly: a bright square
    that enters at hold_s, walks left to right, and leaves one second before the
    end. Frames are generated as rawvideo and encoded by the local ffmpeg — the
    pipeline under test then decodes real bytes, never fabricated detections."""
    import numpy as np
    w, h = 320, 180
    n = int(seconds * fps)

    def frames():
        for i in range(n):
            t = i / fps
            img = np.full((h, w, 3), 24, np.uint8)
            img[:, :] = (32, 30, 28)
            if hold_s <= t < seconds - 1.0:
                k = (t - hold_s) / (seconds - 1.0 - hold_s)
                x = int(8 + k * (w - 40))
                img[70:110, x:x + 32] = (210, 220, 235)
            yuv = np.empty((h * 3 // 2, w), np.uint8)
            r, g, b = img[..., 0].astype(np.int32), img[..., 1].astype(np.int32), img[..., 2].astype(np.int32)
            y = (66 * r + 129 * g + 25 * b + 128) // 256 + 16
            yuv[:h] = np.clip(y, 0, 255).astype(np.uint8)
            u = (-38 * r - 74 * g + 112 * b + 128) // 256 + 128
            v = (112 * r - 94 * g - 18 * b + 128) // 256 + 128
            yuv[h:] = 128
            yield yuv.tobytes()

    import frame_source as fs
    ff = fs.find_ffmpeg()
    cmd = [ff, "-hide_banner", "-loglevel", "error", "-y",
           "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", f"{w}x{h}", "-r", str(fps),
           "-i", "pipe:0", "-c:v", "libx264", "-g", str(fps), "-bf", "0",
           "-pix_fmt", "yuv420p", path]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    for blob in frames():
        p.stdin.write(blob)
    p.stdin.close()
    err = p.stderr.read().decode("utf-8", "replace")
    if p.wait() != 0:
        raise RuntimeError(f"could not encode the synthetic clip: {err[:200]}")
    return {"path": path, "seconds": seconds, "fps": fps, "hold_s": hold_s,
            "motion_window": (hold_s, seconds - 1.0)}


def _verify_integration(failure_control: bool):
    passed = failed = skipped = 0
    t_all = time.perf_counter()

    def run_check(name, fn):
        nonlocal passed, failed
        t0 = time.perf_counter()
        try:
            detail = fn()
        except AssertionError as e:
            failed += 1
            _check("integration", name, "fail", str(e), time.perf_counter() - t0)
        except Exception as e:
            failed += 1
            _check("integration", name, "fail", f"{type(e).__name__}: {e}",
                   time.perf_counter() - t0)
        else:
            passed += 1
            _check("integration", name, "pass", detail or "", time.perf_counter() - t0)

    tmp = Path(tempfile.mkdtemp(prefix="wttrack-it-"))
    clip = str(tmp / "synth.mp4")
    ev1 = str(tmp / "run1.json")
    ev2 = str(tmp / "run2.json")
    clip_meta = {}

    def c_make():
        clip_meta.update(_make_synth_clip(clip))
        return f"{clip_meta['seconds']}s at {clip_meta['fps']} fps"
    run_check("synthetic clip generated and encoded locally", c_make)

    def c_probe():
        r = subprocess.run([sys.executable, __file__, "probe", "--file", clip],
                           capture_output=True, text=True, timeout=120)
        d = json.loads(r.stdout.strip().splitlines()[-1])
        assert r.returncode == 0 and d.get("ok"), f"probe failed: {r.stdout[-200:]}"
        clip_meta["sha256"] = d["result"]["sha256"]
        return f"sha256 {clip_meta['sha256'][:16]}…"
    run_check("probe identifies the input (identity + real codec)", c_probe)

    def _run_once(out):
        return subprocess.run([sys.executable, __file__, "run", "--file", clip,
                               "--camera", "synth-cam", "--unit", DEFAULT_UNIT,
                               "--start", "2026-10-05T00:00:00+00:00",
                               "--synthetic", "--out", out],
                              capture_output=True, text=True, timeout=600)

    def c_run():
        r = _run_once(ev1)
        assert r.returncode == 0, f"run failed: {r.stderr[-300:]}"
        d = json.loads(r.stdout.strip().splitlines()[-1])
        assert d["ok"] and d["result"]["episodes"] >= 1, json.dumps(d)[:200]
        return f"{d['result']['episodes']} episode(s)"
    run_check("run completes on the decoded clip (real detections)", c_run)

    ev = {}

    def c_identity():
        ev.update(json.loads(Path(ev1).read_text()))
        assert ev["input"]["sha256"] == clip_meta["sha256"], "input hash mismatch"
        assert ev["engine"]["files_sha256"].get("temporal_tracks.py"), "no engine hash"
        return "input hash matches the file"
    run_check("evidence carries the input identity and engine revision", c_identity)

    def c_alignment():
        ep = max(ev["episodes"], key=lambda e: e["observations"])
        t0, t1 = clip_meta["motion_window"]
        s, e = ep["start_ms"] / 1000.0, ep["end_ms"] / 1000.0
        assert abs(s - t0) <= 2.0 and abs(e - t1) <= 2.0, \
            f"episode {s:.2f}–{e:.2f}s vs true motion {t0:.2f}–{t1:.2f}s"
        times = [a["t_ms"] for a in ev["assignments"]]
        assert times == sorted(times), "assignment times not monotonic"
        return f"episode {s:.2f}–{e:.2f}s, motion was {t0:.2f}–{t1:.2f}s"
    run_check("track timing aligns with the recording", c_alignment)

    def c_joinable():
        have = {a["t_ms"] for a in ev["assignments"] if a["track_id"]}
        for ep in ev["episodes"]:
            for t_ms, _cx, _cy in ep["path"]:
                assert t_ms in have, f"path sample {t_ms} has no observed assignment"
        return "every path sample is an observed detection"
    run_check("overlay evidence joins receipts to detections", c_joinable)

    def c_replay():
        cli = REPO_ROOT / "tools/labs/replay_temporal_tracks.py"
        batch = {"camera_id": "c", "unit_id": "u", "seq": 0, "t_ms": 0,
                 "detections": [{"id": "d0", "bbox": [0.1, 0.2, 0.1, 0.2]}]}
        lines = [json.dumps({"op": "init", "camera_id": "c", "unit_id": "u"}),
                 json.dumps({"op": "feed", "batch": batch}),
                 json.dumps({"op": "feed", "batch": batch})]
        r = subprocess.run([sys.executable, str(cli)], input="\n".join(lines) + "\n",
                           capture_output=True, text=True, timeout=60)
        rs = [json.loads(x) for x in r.stdout.splitlines()]
        assert rs[1]["result"]["replayed"] is False and rs[2]["result"]["replayed"] is True
        return "second identical feed replays the original receipt"
    run_check("replay returns the original receipt without re-processing", c_replay)

    def c_errors():
        cli = REPO_ROOT / "tools/labs/replay_temporal_tracks.py"
        bad = {"camera_id": "c", "unit_id": "u", "seq": 0, "t_ms": 0,
               "detections": [{"id": "d0", "bbox": [0.9, 0.9, 0.5, 0.5]}]}
        lines = [json.dumps({"op": "init", "camera_id": "c", "unit_id": "u"}),
                 json.dumps({"op": "feed", "batch": bad})]
        r = subprocess.run([sys.executable, str(cli)], input="\n".join(lines) + "\n",
                           capture_output=True, text=True, timeout=60)
        rs = [json.loads(x) for x in r.stdout.splitlines()]
        assert rs[1]["ok"] is False and rs[1]["error"]["code"] == "invalid_input"
        badfile = tmp / "not-a-video.bin"
        badfile.write_bytes(b"\x00\x01\x02\x03")
        r2 = subprocess.run([sys.executable, __file__, "run", "--file", str(badfile),
                             "--camera", "c", "--unit", DEFAULT_UNIT,
                             "--start", "2026-10-05T00:00:00+00:00", "--out",
                             str(tmp / "bad.json")], capture_output=True, text=True,
                            timeout=120)
        assert r2.returncode != 0, "an unreadable input exited 0"
        return "invalid input and an unreadable file both surface as errors"
    run_check("failures surface as failures, never as passes", c_errors)

    def c_cancel():
        big = str(tmp / "long.mp4")
        _make_synth_clip(big, seconds=60.0, fps=15)
        p = subprocess.Popen([sys.executable, __file__, "run", "--file", big,
                              "--camera", "synth-cam", "--unit", DEFAULT_UNIT,
                              "--start", "2026-10-05T00:00:00+00:00", "--synthetic",
                              "--out", str(tmp / "long.json")],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        # Kill it once tracking is genuinely under way (the first per-batch progress
        # line), not on a timer: a fast clip must not have already completed.
        deadline = time.monotonic() + 30
        killed = False
        while time.monotonic() < deadline:
            line = p.stderr.readline()
            if line == "" or "tracking…" in line:
                p.terminate()
                killed = True
                break
        if not killed:
            p.terminate()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
        done = tmp / "long.json"
        assert killed, "the run finished before it could be cancelled"
        assert not (done.exists() and json.loads(done.read_text())["status"] == "completed"), \
            "a killed run left a completed record"
        return "a cancelled run leaves no completed evidence"
    run_check("cancellation stops the work and keeps no stale result", c_cancel)

    def c_repeat():
        r = _run_once(ev2)
        assert r.returncode == 0
        a = json.loads(Path(ev1).read_text())
        b = json.loads(Path(ev2).read_text())
        da = json.dumps(a["episodes"], sort_keys=True)
        db = json.dumps(b["episodes"], sort_keys=True)
        assert da == db, "repeat run differs"
        assert a["run_id"] == b["run_id"], "same input+config gave different run ids"
        return "identical episode digest on repeat"
    run_check("repeating a run reproduces it exactly (no stale state)", c_repeat)

    if failure_control:
        # SUPPOSED to fail, every time: the engine is invoked for real and then a
        # deliberately WRONG expectation is asserted. This proves the product can
        # display a genuine failure rather than only ever reporting success.
        t0 = time.perf_counter()
        try:
            import temporal_tracks as tt
            tr = tt.Tracker(camera_id="c", unit_id="u")
            r = tr.feed({"camera_id": "c", "unit_id": "u", "seq": 0, "t_ms": 0,
                         "detections": [{"id": "d", "bbox": [0.1, 0.2, 0.1, 0.2]}]})
            assert r["assignments"] == [], \
                "DELIBERATE CONTROL: expected no assignments, but the engine correctly " \
                f"produced {r['assignments'][0]['status']} on a valid batch"
        except AssertionError as e:
            failed += 1
            _check("integration", "DELIBERATE FAILURE CONTROL (fails by request)",
                   "fail", str(e), time.perf_counter() - t0)
        except Exception as e:
            failed += 1
            _check("integration", "DELIBERATE FAILURE CONTROL (fails by request)",
                   "fail", f"control itself errored: {e}", time.perf_counter() - t0)

    return passed, failed, skipped, time.perf_counter() - t_all


def cmd_verify(args) -> int:
    suite = args.suite
    fn = {"contract": _verify_contract, "regressions": _verify_regressions,
          "workload": _verify_workload, "integration": _verify_integration}.get(suite)
    if fn is None:
        _emit({"ok": False, "error": {"code": "unknown_suite", "message": suite}})
        return 2
    passed, failed, skipped, seconds = fn(bool(args.failure_control))
    _emit({"type": "summary", "suite": suite, "passed": passed, "failed": failed,
           "skipped": skipped, "seconds": round(seconds, 3)})
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="track_run.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("probe")
    p.add_argument("--file", required=True)
    r = sub.add_parser("run")
    r.add_argument("--file", required=True)
    r.add_argument("--camera", required=True)
    r.add_argument("--unit", default=DEFAULT_UNIT)
    r.add_argument("--start", required=True)
    r.add_argument("--origin", default="operator",
                 choices=["operator", "filename", "fixture"])
    r.add_argument("--out", required=True)
    r.add_argument("--config", default=None)
    r.add_argument("--every-nth", type=int, default=3)
    r.add_argument("--synthetic", action="store_true")
    v = sub.add_parser("verify")
    v.add_argument("--suite", required=True,
                   choices=["contract", "regressions", "workload", "integration"])
    v.add_argument("--failure-control", action="store_true")
    args = ap.parse_args()
    return {"probe": cmd_probe, "run": cmd_run, "verify": cmd_verify}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
