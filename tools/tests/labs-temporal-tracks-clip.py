#!/usr/bin/env python3
"""Product job runner tests: tools/labs/temporal_tracks_clip.py. Hermetic.

The stage-2 integration drives the tracking engine through a child process that
decodes a real recording with the repository's own ffmpeg pass and foreground
analyser. These tests pin that process's CONTRACT with the application, using
only SYNTHETIC clips generated locally with ffmpeg (labelled as such, never
footage, never committed): the JSON line protocol, the input identity and hash,
the time basis, the bounded analysis window, dropped same-millisecond frames,
cancellation, and the refusal paths.

What is deliberately NOT here: the engine's semantics (association, ambiguity,
time, replay, validation) live in tools/tests/labs-temporal-tracks.py, and the
in-product integration self-checks run inside Watchtower's Labs Verification
view. This file only checks that the helper process says what it did.

Run:  python3 tools/tests/labs-temporal-tracks-clip.py     (exit 1 on failure)
Needs ffmpeg on PATH; without it every check reports SKIP-style failure with the
reason, because a job that cannot decode cannot be trusted silently.
"""
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
JOB = ROOT / "tools" / "labs" / "temporal_tracks_clip.py"
sys.path.insert(0, str(ROOT / "tools" / "labs"))

fails = []
_passed = [0]
SKIPS = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"   [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)
    else:
        _passed[0] += 1


def _crashed(t, e, tb):
    print(f"FAIL the suite CRASHED after {_passed[0]} passing checks: {t.__name__}: {e}")
    sys.__excepthook__(t, e, tb)


sys.excepthook = _crashed

FFMPEG = subprocess.run(["ffmpeg", "-hide_banner", "-version"], capture_output=True).returncode == 0
TMP = pathlib.Path(tempfile.mkdtemp(prefix="tt-clip-"))


def synth(name: str, filt: str, seconds: float = 6, fps: int = 20, size: str = "320x240") -> str:
    out = TMP / name
    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
           "-f", "lavfi", "-i", f"color=c=black:s={size}:d={seconds}:r={fps}",
           "-f", "lavfi", "-i", f"color=c=white:s=48x72:d={seconds}:r={fps}",
           "-filter_complex", f"[0:v][1:v]{filt}",
           "-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "veryfast", str(out)]
    # stdin must be closed: ffmpeg reads it for interactive keys and blocks
    # forever on a pipe that never reaches EOF (measured on this box).
    subprocess.run(cmd, capture_output=True, check=True, timeout=120,
                   stdin=subprocess.DEVNULL)
    return str(out)


def run_job(args, timeout=240, term_after=None):
    """(lines, returncode). With term_after, SIGTERM the child once that many
    stdout lines have arrived -- a cancellation, not a kill."""
    proc = subprocess.Popen([sys.executable, "-u", str(JOB)] + args,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            stdin=subprocess.DEVNULL, text=True)
    lines = []
    if term_after is None:
        out, err = proc.communicate(timeout=timeout)
        lines = [json.loads(l) for l in out.splitlines() if l.strip()]
        return lines, proc.returncode, err
    for line in proc.stdout:
        if line.strip():
            lines.append(json.loads(line))
        if len(lines) >= term_after:
            proc.send_signal(signal.SIGTERM)
            break
    rest, err = proc.communicate(timeout=timeout)
    lines += [json.loads(l) for l in rest.splitlines() if l.strip()]
    return lines, proc.returncode, err


def result_of(lines):
    return [l for l in lines if l["kind"] == "result"]


if not FFMPEG:
    check("ffmpeg is available to build synthetic verification clips", False, "not on PATH")
    print(f"\n{len(fails)} FAILED: {', '.join(fails)}", file=sys.stderr)
    sys.exit(1)

MOVING = synth("moving.mp4", "overlay=x='mod(t*48,272)':y=90")
STATIC = synth("static.mp4", "overlay=x=40:y=90")
# 1500 fps: probe keeps the real 0.667 ms step, so consecutive frames round
# onto the same millisecond. (At 1000/2000 fps ffmpeg's header loses the rate
# and frame_source falls back to whole-second index times -- measured.)
FAST = synth("fast.mp4", "overlay=x='mod(t*48,272)':y=90", seconds=0.4, fps=1500)

# ---- protocol shape -------------------------------------------------------------
lines, rc, err = run_job(["probe", "--input", MOVING])
check("probe exits 0 and emits exactly one meta line", rc == 0 and len(lines) == 1
      and lines[0]["kind"] == "meta", f"rc={rc} lines={len(lines)} err={err[:200]}")
meta = lines[0]
with open(MOVING, "rb") as f:
    want_sha = hashlib.sha256(f.read()).hexdigest()
check("probe reports the input's real size, mtime and sha256",
      meta["input"]["sha256"] == want_sha
      and meta["input"]["size"] == os.path.getsize(MOVING)
      and abs(meta["input"]["mtime_ms"] - os.path.getmtime(MOVING) * 1000) < 5000,
      str(meta["input"]))
check("probe reports the container's real geometry, not a guess",
      meta["probe"]["width"] == 320 and meta["probe"]["height"] == 240
      and meta["probe"]["codec"] == "h264" and (meta["probe"]["fps"] or 0) > 0, str(meta["probe"]))

lines, rc, err = run_job(["analyze", "--input", MOVING, "--run-id", "t-proto",
                          "--revision", "test-rev", "--max-seconds", "10"])
kinds = [l["kind"] for l in lines]
check("analyze exits 0 with one meta, one result and only protocol kinds",
      rc == 0 and kinds.count("meta") == 1 and kinds.count("result") == 1
      and set(kinds) <= {"meta", "progress", "obs", "closed", "result"}, str(sorted(set(kinds))))
check("every stdout line is finite JSON (no NaN, no Infinity)",
      all(l == json.loads(json.dumps(l, allow_nan=False)) for l in lines))
res = result_of(lines)[0]
check("the result names its schema, run id and the revision it was given",
      res["schema"] == "watchtower-temporal-tracks-run/v1" and res["run_id"] == "t-proto"
      and res["engine"]["revision"] == "test-rev", str(res.get("schema")))
check("the result carries the container probe, so a saved run is self-describing",
      res.get("probe", {}).get("width") == meta["probe"]["width"]
      and res.get("probe", {}).get("height") == meta["probe"]["height"]
      and res.get("probe", {}).get("fps") == meta["probe"]["fps"], str(res.get("probe")))
check("the result carries the same input identity the probe reported",
      res["input"]["sha256"] == want_sha and res["input"]["path"] == os.path.abspath(MOVING),
      str(res["input"]))
check("the result digests the engine modules it actually ran",
      all(v and len(v) == 64 for v in res["engine"]["modules"].values()), str(res["engine"]["modules"]))

# ---- a moving synthetic object is tracked; a static one is not ------------------
check("a moving synthetic object produces detections and at least one track",
      res["status"] == "completed" and res["counts"]["detections"] > 0
      and res["counts"]["tracks"] >= 1, str(res["counts"]))
check("every accepted detection is accounted for exactly once",
      res["counts"]["assigned"] == res["counts"]["detections"]
      and res["counts"]["assigned"] == res["counts"]["born"] + res["counts"]["matched"]
      + res["counts"]["ambiguous"], str(res["counts"]))
check("episode observations equal accepted detections (no invented evidence)",
      sum(t["observations"] for t in res["tracks"]) == res["counts"]["assigned"],
      str((sum(t["observations"] for t in res["tracks"]), res["counts"]["assigned"])))
lines_s, rc_s, _ = run_job(["analyze", "--input", STATIC, "--run-id", "t-static", "--max-seconds", "6"])
res_s = result_of(lines_s)[0]
check("a static synthetic scene completes with NO detections and says so",
      rc_s == 0 and res_s["status"] == "completed" and res_s["counts"]["detections"] == 0
      and res_s["tracks"] == [], str(res_s["counts"]))

# ---- time basis and alignment ---------------------------------------------------
check("without an origin every time is clip-relative and no wall fields exist",
      res["scope"]["time_basis"] == "clip-relative" and res["scope"]["origin_epoch_ms"] is None
      and all("start_wall_ms" not in t for t in res["tracks"]), str(res["scope"]))
ORIGIN = 1700000000000
lines_o, rc_o, _ = run_job(["analyze", "--input", MOVING, "--run-id", "t-origin",
                            "--origin-epoch-ms", str(ORIGIN), "--max-seconds", "10"])
res_o = result_of(lines_o)[0]
check("with an origin the document says wall-clock and derives it, never re-measures",
      res_o["scope"]["time_basis"] == "wall-clock"
      and all(t["start_wall_ms"] == ORIGIN + t["start_ms"] for t in res_o["tracks"])
      and all(t["end_wall_ms"] == ORIGIN + t["end_ms"] for t in res_o["tracks"]),
      str(res_o["scope"]))
obs = [o for o in res["observations"] if not o.get("truncated")]
by_track = {}
for o in obs:
    by_track.setdefault(o["track"], []).append(o["t_ms"])
check("observation times strictly increase per track and stay inside the clip",
      all(v == sorted(v) and len(v) == len(set(v)) for v in by_track.values())
      and all(0 <= t <= res["decode"]["duration_s"] * 1000 + 1000 for v in by_track.values() for t in v),
      str({k: v[:4] for k, v in list(by_track.items())[:2]}))
check("path samples keep their ACTUAL timestamps (not an equal spacing)",
      all(len(t["path"]) >= 2 for t in res["tracks"])
      and any(len({s[0] for s in t["path"]}) == len(t["path"]) for t in res["tracks"])
      and any((t["path"][1][0] - t["path"][0][0]) != (t["path"][2][0] - t["path"][1][0])
              for t in res["tracks"] if len(t["path"]) >= 3),
      str([t["path"][:3] for t in res["tracks"][:1]]))
check("every observation box is a normalised box inside the frame",
      all(len(o["bbox"]) == 4 and o["bbox"][0] >= 0 and o["bbox"][1] >= 0
          and o["bbox"][0] + o["bbox"][2] <= 1.0000001 and o["bbox"][1] + o["bbox"][3] <= 1.0000001
          for o in obs), str(obs[:2]))

# ---- bounded window, dropped milliseconds, cancellation -------------------------
lines_w, rc_w, _ = run_job(["analyze", "--input", MOVING, "--run-id", "t-window", "--max-seconds", "2"])
res_w = result_of(lines_w)[0]
check("a bounded window reports its coverage and says the rest was not analysed",
      rc_w == 0 and abs(res_w["decode"]["window_s"] - 2.0) < 0.2
      and res_w["decode"]["coverage"] < 0.5
      and any("not analysed" in p for p in res_w["problems"]), str(res_w["decode"]))
lines_f, rc_f, _ = run_job(["analyze", "--input", FAST, "--run-id", "t-fast", "--max-seconds", "5"])
res_f = result_of(lines_f)[0]
check("frames that round onto the previous millisecond are dropped and COUNTED",
      rc_f == 0 and res_f["status"] == "completed"
      and res_f["decode"]["dropped_same_ms"] > 0
      and res_f["decode"]["frames_decoded"] == res_f["decode"]["frames_scored"],
      str(res_f["decode"]))
check("dropped frames feed no detection: assigned <= fed frames",
      res_f["counts"]["assigned"] <= res_f["decode"]["frames_decoded"]
      - res_f["decode"]["dropped_same_ms"], str(res_f["counts"]))
lines_c, rc_c, _ = run_job(["analyze", "--input", MOVING, "--run-id", "t-cancel", "--max-seconds", "60"],
                           term_after=1)
res_c = result_of(lines_c)
check("SIGTERM after the first line ends the run as cancelled, exit 130",
      rc_c == 130 and res_c and res_c[0]["status"] == "cancelled", f"rc={rc_c}")
check("a cancelled run still reports what it decoded and keeps no fake completion",
      res_c and res_c[0]["counts"]["detections"] >= 0 and res_c[0]["status"] != "completed",
      str(res_c[0]["status"]) if res_c else "no result")

# ---- refusal paths ---------------------------------------------------------------
lines_m, rc_m, _ = run_job(["analyze", "--input", str(TMP / "nope.mp4"), "--run-id", "t-miss"])
check("a missing input is refused with input_missing and exit 3",
      rc_m == 3 and lines_m and lines_m[0]["kind"] == "error"
      and lines_m[0]["code"] == "input_missing", str(lines_m[:1]))
lines_b, rc_b, _ = run_job(["analyze", "--input", MOVING, "--run-id", "t-badcfg",
                            "--config", '{"max_gap_ms": 0}'])
check("an out-of-range engine configuration is refused with invalid_config",
      rc_b == 3 and lines_b and lines_b[0]["code"] == "invalid_config", str(lines_b[:1]))
lines_j, rc_j, _ = run_job(["analyze", "--input", MOVING, "--run-id", "t-badjson",
                            "--config", "{not json"])
check("a non-JSON configuration is refused with invalid_input",
      rc_j == 3 and lines_j and lines_j[0]["code"] == "invalid_input", str(lines_j[:1]))
lines_u, rc_u, _ = run_job(["frobnicate", "--input", MOVING])
check("an unknown subcommand is refused, exit 2", rc_u == 2, str(rc_u))

# ---- the job never writes outside its own stdout ---------------------------------
before = sorted(p.name for p in TMP.iterdir())
run_job(["analyze", "--input", MOVING, "--run-id", "t-clean", "--max-seconds", "3"])
after = sorted(p.name for p in TMP.iterdir())
check("the job leaves no stray files beside its input", before == after, str((before, after)))

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}", file=sys.stderr)
    sys.exit(1)
print(f"all passed ({_passed[0]} checks)")
