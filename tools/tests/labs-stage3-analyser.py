#!/usr/bin/env python3
"""Stage-3 semantic analyser tests — hermetic, and on the SAME code Labs runs.

These checks drive `tools/labs/semantic_objects.py` and
`tools/labs/stage3_checklist.py` exactly as `LabsSemanticJob` does (same CLI,
same JSON protocol, same helper), so a pass here means the product path passes.
They test workflow and contract properties, NOT recognition accuracy: accuracy
on these public clips is what the in-app human review records, and full metrics
await CASES.md's annotation phase.

Synthetic clips are generated locally with ffmpeg and are labelled SYNTHETIC
wherever they appear; they exercise plumbing (PTS, boxes, cancellation, missing
prerequisites) and never stand in for one of the eight recording cases. Where a
supplied clip is used, it is read from the neutral directory and its bytes are
identified by hash, never by name.

Run:  python3 tools/tests/labs-stage3-analyser.py        (exit 1 on failure)
Needs ffmpeg and the local detector weights; without weights the prerequisite
checks still run and the accuracy-adjacent checks report SKIP-with-reason.
"""
import hashlib
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
LABS = ROOT / "tools" / "labs"
sys.path.insert(0, str(LABS))
import stage3_evidence as E                                  # noqa: E402

NEUTRAL = pathlib.Path("/home/cilex-vision/Videos/Watchtower-Stage3")
DATASET = ROOT / "docs" / "benchmarks" / "labs-detection-stage3" / "dataset.json"
MODEL_DIR = os.environ.get("WT_LABS_MODEL_DIR",
                           os.path.join(os.path.expanduser("~"), ".cache",
                                        "watchtower-labs-models"))
HAVE_WEIGHTS = os.path.isfile(os.path.join(MODEL_DIR, "yolo11n.pt"))

fails = []
_passed = [0]
TMP = pathlib.Path(tempfile.mkdtemp(prefix="tt-s3-"))


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


def synth(name, seconds=6, fps=20, filt="overlay=x='mod(t*48,272)':y=90"):
    out = TMP / name
    subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", f"color=c=black:s=320x240:d={seconds}:r={fps}",
                    "-f", "lavfi", "-i", f"color=c=white:s=48x72:d={seconds}:r={fps}",
                    "-filter_complex", f"[0:v][1:v]{filt}",
                    "-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "veryfast", str(out)],
                   check=True, capture_output=True, timeout=120, stdin=subprocess.DEVNULL)
    return str(out)


def run_job(path, clip_id, extra=None, term_after=None, env=None, timeout=420):
    args = [sys.executable, "-u", str(LABS / "semantic_objects.py"), "analyze",
            "--input", path, "--clip-id", clip_id, "--run-id", "t-" + hashlib.sha256(
                (path + clip_id + str(time.time())).encode()).hexdigest()[:8],
            "--out-run", str(TMP / "run.json"), "--evidence-dir", str(TMP / "crops"),
            "--source-revision", "test", "--max-frames", "200"]
    args += extra or []
    e = dict(os.environ, WT_LABS_MODEL_DIR=MODEL_DIR)
    e.update(env or {})
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            stdin=subprocess.DEVNULL, text=True, env=e)
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
    r = [l for l in lines if l["kind"] == "result"]
    return r[0] if r else None


def run_doc(lines):
    r = result_of(lines)
    if not r:
        return None
    return json.load(open(r["run_path"], encoding="utf-8"))


# ---- manifest and prerequisites ---------------------------------------------------
proc = subprocess.run([sys.executable, str(LABS / "semantic_objects.py"), "manifest"],
                      capture_output=True, text=True, timeout=180, stdin=subprocess.DEVNULL,
                      env=dict(os.environ, WT_LABS_MODEL_DIR=MODEL_DIR))
man = json.loads(proc.stdout.strip().splitlines()[-1]) if proc.stdout.strip() else {}
check("the analyser publishes its two versioned capabilities and the pipeline id",
      proc.returncode == 0
      and [a["id"] for a in man.get("analysers", [])] == ["semantic_object", "object_colour"]
      and man.get("pipeline", {}).get("id") == "semantic_object+object_colour",
      str(man.get("analysers")))
check("the manifest discloses model source, licence and on-disk hash",
      all(m.get("url") and m.get("licence") and (m.get("sha256_on_disk") or not m.get("present"))
          for m in man.get("models", {}).values()), str(list(man.get("models", {}))))
lines, rc, err = run_job(str(TMP / "absent.mp4"), "WT3-999")
check("a missing recording is refused before any analysis",
      rc == 3 and lines and lines[0]["code"] == "input_missing", str(lines[:1]))
lines, rc, err = run_job(synth("tiny.mp4", seconds=1), "local-tiny",
                         env={"WT_LABS_MODEL_DIR": str(TMP / "no-models")})
check("missing weights are a PREREQUISITE failure, never a no-detection success",
      rc == 3 and lines and lines[0]["code"] == "model_weights_missing", str(lines[:1]))
bad = TMP / "corrupt.mp4"
bad.write_bytes(b"this is not a video stream at all, just text bytes" * 4)
lines, rc, err = run_job(str(bad), "local-corrupt")
check("an undecodable input fails visibly",
      rc == 3 and lines and lines[0]["code"] in ("probe_failed", "no_video_stream"), str(lines[:1]))

# ---- a synthetic run: PTS, boxes, regions, envelope ---------------------------------
SYN = synth("moving.mp4")
lines, rc, err = run_job(SYN, "local-synthetic", ["--crops"])
doc = run_doc(lines)
check("a synthetic clip completes through the same CLI the product drives",
      rc == 0 and doc is not None and doc["status"] == "completed", str(rc))
if doc:
    check("the run envelope carries schema, analyser, model, config, measurements and errors",
          doc["schema_version"] == 1 and doc["analyser"]["id"] == "semantic_object+object_colour"
          and doc["model"]["weights_sha256"] and doc["config"] and doc["measurements"]
          and doc["errors"] == [], str(list(doc)))
    check("peak RSS is reported as a process peak with its method, not a net delta",
          doc["measurements"]["peak_rss_bytes"] > 0
          and "ru_maxrss" in doc["measurements"]["peak_rss_method"],
          str(doc["measurements"]["peak_rss_method"]))
    check("frame PTS come from decoding: strictly increasing and inside the clip",
          doc["measurements"]["pts_strictly_increasing"] is True
          and all(0 <= o["frame_pts_ms"] <= doc["measurements"]["last_pts_ms"]
                  for o in doc["observations"]), str(doc["measurements"].get("last_pts_ms")))
    ft = doc["details"]["frame_times_ms"]
    check("the run keeps every decoded frame's PTS for overlay alignment",
          len(ft) == doc["measurements"]["decoded_frame_count"]
          and all(a < b for a, b in zip(ft, ft[1:])), str(len(ft)))
    check("boxes are normalized, positive and inside the frame",
          all(len(o["bbox_xywh"]) == 4 and o["bbox_xywh"][2] > 0 and o["bbox_xywh"][3] > 0
              and o["bbox_xywh"][0] + o["bbox_xywh"][2] <= 1.000001
              and o["bbox_xywh"][1] + o["bbox_xywh"][3] <= 1.000001
              for o in doc["observations"]))
    check("each observation carries at most one colour per region",
          all(len({c["region"] for c in o["colors"]}) == len(o["colors"]) for o in doc["observations"]))
    check("colour evidence records the sampled region box and pixel count",
          all("region_box_norm" in c and c["pixels"] > 0
              for o in doc["observations"] for c in o["color_evidence"]))
    check("crops were written for the observations that claim colour evidence",
          all(os.path.isfile(os.path.join(str(TMP / "crops"), o["crop"]["file"]))
              for o in doc["observations"] if o.get("crop")), str(len(doc["observations"])))
    check("track references come from the Stage-1 engine, not from interpolation",
          all(o.get("track_id") is None or o["track_id"].startswith("t")
              for o in doc["observations"])
          and doc["config"]["tracking"]["engine"].endswith("temporal_tracks.py (Stage 1)"))

# ---- renamed-input equivalence (CASES.md S3-C02) ------------------------------------
if doc:
    COPY = TMP / "renamed-copy-of-moving.mp4"
    shutil.copyfile(SYN, COPY)
    lines2, rc2, _ = run_job(str(COPY), "local-synthetic")
    doc2 = run_doc(lines2)
    def norm(d):
        return [{k: o[k] for k in ("frame_index", "frame_pts_ms", "class", "bbox_xywh", "colors")}
                for o in d["observations"]]
    check("the same bytes under a different name give the same detections",
          rc2 == 0 and doc2 is not None and norm(doc) == norm(doc2)
          and doc["input_sha256"] == doc2["input_sha256"],
          f"{len(norm(doc))} vs {len(norm(doc2)) if doc2 else -1} observations")
    check("run identity differs between the two runs (no stale reuse)",
          doc2 is not None and doc["run_id"] != doc2["run_id"])

# ---- cancellation ---------------------------------------------------------------------
LONG = synth("long.mp4", seconds=20)
lines3, rc3, _ = run_job(LONG, "local-long", term_after=2)
res3 = result_of(lines3)
check("SIGTERM mid-run ends as cancelled with exit 130 and an honest status",
      rc3 == 130 and res3 is not None and res3["status"] == "cancelled", str((rc3, res3 and res3["status"])))
doc3 = run_doc(lines3) if res3 else None
check("a cancelled run keeps its partial observations and says so in status",
      doc3 is not None and doc3["status"] == "cancelled"
      and isinstance(doc3["observations"], list), str(doc3 and doc3["status"]))

# ---- whole-second evaluation schedule --------------------------------------------------
lines4, rc4, _ = run_job(SYN, "local-synthetic", ["--schedule", "whole-second"])
doc4 = run_doc(lines4)
if doc4:
    ft4 = doc4["details"]["frame_times_ms"]
    idx = sorted({o["frame_index"] for o in doc4["observations"]})
    want = []
    seen = set()
    k = 0
    for s in range(0, ft4[-1] // 1000 + 1):
        while k < len(ft4) and ft4[k] < s * 1000:
            k += 1
        if k < len(ft4) and ft4[k] not in seen:
            seen.add(ft4[k]); want.append(k)
    check("the evaluation schedule emits exactly the first decoded frame at or after each whole second",
          doc4["details"]["requested_frames"] == len(want)
          and all(i in want for i in idx), f"{idx[:8]} vs {want[:8]}")
    check("missing requested frames are reported, not silently dropped",
          isinstance(doc4["measurements"]["missing_requested_frames"], list))

# ---- checklist and review ---------------------------------------------------------------
if HAVE_WEIGHTS and NEUTRAL.is_dir():
    clip5 = NEUTRAL / "clip-005.mp4"
    lines5, rc5, _ = run_job(str(clip5), "WT3-005", ["--sample-fps", "1", "--max-frames", "60"])
    doc5 = run_doc(lines5)
    clip = json.load(open(DATASET, encoding="utf-8"))["clips"][4]
    check("a supplied clip validates against the common helper",
          doc5 is not None and E.validate_run(doc5, clip) == [], str(doc5 and E.validate_run(doc5, clip)))
    proc = subprocess.run([sys.executable, str(LABS / "stage3_checklist.py"), "evaluate",
                           "--run", doc5 and str(TMP / "run.json"), "--clip-id", "WT3-005"],
                          capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
    ev = json.loads(proc.stdout) if proc.returncode == 0 else {}
    t = (ev.get("targets") or [{}])[0]
    check("the checklist finds candidates for the red-clothing target and stays review_required",
          proc.returncode == 0 and ev.get("status") == "review_required"
          and t.get("qualifying_observation_ids"), str(ev.get("status")))
    if t.get("qualifying_observation_ids"):
        oid = t["qualifying_observation_ids"][0]
        proc = subprocess.run([sys.executable, str(LABS / "stage3_checklist.py"), "review",
                               "--run", str(TMP / "run.json"), "--clip-id", "WT3-005",
                               "--reviewer", "labs-stage3-test",
                               "--decisions", json.dumps([{"target_id": t["target_id"],
                                                          "decision": "accepted",
                                                          "observation_ids": [oid],
                                                          "note": "automated plumbing review"}]),
                               "--out", str(TMP / "review.json")],
                              capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
        check("a named reviewer's acceptance binds to the run digest and is recorded",
              proc.returncode == 0 and json.loads(proc.stdout)["status"] == "reviewed"
              and json.load(open(TMP / "review.json"))["run_sha256"] == E.evidence_digest(doc5))
        rev = json.load(open(TMP / "review.json"))
        rev["targets"][0]["observation_ids"] = ["o999999"]
        (TMP / "review-bad.json").write_text(json.dumps(rev))
        proc = subprocess.run([sys.executable, str(LABS / "stage3_checklist.py"), "status",
                               "--run", str(TMP / "run.json"), "--review", str(TMP / "review-bad.json"),
                               "--clip-id", "WT3-005"],
                              capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
        st = json.loads(proc.stdout)
        check("a review naming an observation that does not exist is invalid",
              st.get("status") == "invalid" and st.get("errors"), str(st.get("errors")))
    proc = subprocess.run([sys.executable, str(LABS / "stage3_checklist.py"), "control-invalid",
                           "--run", str(TMP / "run.json"), "--clip-id", "WT3-005"],
                          capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
    ci = json.loads(proc.stdout) if proc.returncode == 0 else {}
    check("the deliberate-invalid control is caught by the common validation",
          ci.get("assessment_status") == "invalid" and len(ci.get("validation_errors", [])) >= 3,
          str(ci.get("validation_errors")))
    check("the corrupt control document is stored apart and labelled",
          ci.get("invalid_run_path", "").endswith(".verification-invalid.json")
          and json.load(open(ci["invalid_run_path"]))["verification_control"].startswith("deliberately"))
else:
    print(f"SKIP  supplied-clip checklist checks (weights={HAVE_WEIGHTS}, neutral dir={NEUTRAL.is_dir()})")

# ---- the common helper's own suite still passes ----------------------------------------
proc = subprocess.run([sys.executable, str(ROOT / "tools" / "tests" / "labs-stage3-evidence.py")],
                      capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
check("the supplied common evidence helper suite passes unchanged",
      proc.returncode == 0 and "OK" in proc.stderr, proc.stderr.strip().splitlines()[-1:])

shutil.rmtree(TMP, ignore_errors=True)
print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}", file=sys.stderr)
    sys.exit(1)
print(f"all passed ({_passed[0]} checks)")
