#!/usr/bin/env python3
"""Stage 3 product controls: the CASES.md checklist, run through the real path.

Every check here executes the SAME programs the Labs panel executes --
`stage3_detect.py` for analysis and `stage3_evaluate.py` (which owns the common
evidence helper) for validation and target candidates. None of them re-implements
detection, and none of them turns a workflow property into an accuracy claim.

Emitted as JSONL so the panel can show individual results:

    {"event":"check","group":G,"name":N,"status":"pass|fail|skip",
     "detail":D,"ms":M,"control":bool}
    {"event":"group","group":G,"status":...,"passed":n,"failed":n,"skipped":n}
    {"event":"done","passed":n,"failed":n,"skipped":n,"control_failed":n,
     "real_failed":n,"control_ok":bool}

Groups:
    supplied     S3-C01/C03/C04/C10 over the runs the product already produced
    controls     S3-C02/C05..C09/C12 -- live runs of the real analyser
    checks       the common helper's own suite and the detector's hermetic units
    regressions  the existing tracking/worker/self-test suites
    all          everything above

A check that cannot run for want of an input is SKIP with the reason, never a
pass. One check is DELIBERATELY built to fail: the panel must be able to show a
real failure, and the harness asserts that it saw one.
"""
from __future__ import annotations

import argparse
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

_HERE = pathlib.Path(__file__).resolve().parent
ROOT = _HERE.parent.parent
sys.path.insert(0, str(_HERE))

import stage3_evidence as E                      # noqa: E402
import stage3_evaluate as EV                     # noqa: E402

DETECT = _HERE / "stage3_detect.py"
EVALUATE = _HERE / "stage3_evaluate.py"
HELPER_TESTS = ROOT / "tools" / "tests" / "labs-stage3-evidence.py"
DETECTOR_TESTS = ROOT / "tools" / "tests" / "labs-stage3-detector.py"
TRACKING_TESTS = ROOT / "tools" / "tests" / "labs-temporal-tracks.py"
WORKER_TESTS = ROOT / "tools" / "tests" / "labs-worker.py"
SHAPE_SELFTEST = _HERE / "selftest_shape_observations.py"
PROFILE_SELFTEST = _HERE / "selftest_object_profile.py"

_RESULT = {"passed": 0, "failed": 0, "skipped": 0, "control_failed": 0}
_CONTROL = {"seen": False}


def emit(record: dict) -> None:
    sys.stdout.write(json.dumps(record, ensure_ascii=True) + "\n")
    sys.stdout.flush()


def check(group, name, ok, detail="", ms=0.0, control=False):
    if ok is None:
        status = "skip"
        _RESULT["skipped"] += 1
    else:
        status = "pass" if ok else "fail"
        _RESULT["passed" if ok else "failed"] += 1
    if control and status == "fail":
        _CONTROL["seen"] = True
        _RESULT["control_failed"] += 1
    emit({"event": "check", "group": group, "name": name, "status": status,
          "detail": detail, "ms": round(ms, 1), "control": control})


def run(cmd, timeout=1800, env=None):
    t0 = time.time()
    full = dict(os.environ)
    if env:
        full.update(env)
    try:
        proc = subprocess.run([str(c) for c in cmd], capture_output=True, text=True,
                              timeout=timeout, env=full, cwd=str(ROOT))
        return proc.returncode, proc.stdout, proc.stderr, (time.time() - t0) * 1000
    except subprocess.TimeoutExpired:
        return None, "", "timed out after %ss" % timeout, (time.time() - t0) * 1000


def _delta(before):
    return {"passed": _RESULT["passed"] - before["passed"],
            "failed": _RESULT["failed"] - before["failed"],
            "skipped": _RESULT["skipped"] - before["skipped"],
            "control_failed": _RESULT["control_failed"] - before["control_failed"]}


def group(name, counts):
    real = counts["failed"] - counts["control_failed"]
    emit({"event": "group", "group": name, "status": "fail" if real else "pass",
          **counts})


# ----------------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------------
def _default_recordings() -> str:
    """Where the supplied clips live on THIS platform (same rule as the panel)."""
    override = os.environ.get("WT_STAGE3_CLIPS")
    if override:
        return override
    if sys.platform == "darwin":
        movies = pathlib.Path.home() / "Movies"
    else:
        movies = pathlib.Path(os.path.expanduser("~")) / "Videos"
    candidate = movies / "Watchtower-Stage3"
    if candidate.is_dir():
        return str(candidate)
    dev = pathlib.Path("/home/cilex-vision/Videos/Watchtower-Stage3")
    return str(dev if dev.is_dir() else candidate)


def newest_run(runs_dir: pathlib.Path, clip_id: str):
    best = None
    for d in sorted(runs_dir.glob(clip_id + "-*"), reverse=True):
        if (d / "run.json").is_file():
            best = d
            break
    return best


def evaluate(run_dir, clip_id, review=None):
    args = [sys.executable, str(EVALUATE), "--run", str(run_dir), "--clip-id", clip_id]
    if review:
        args += ["--review", str(review)]
    code, out, err, ms = run(args, timeout=300)
    try:
        return json.loads(out), code, ms, err
    except ValueError:
        return {"valid": False, "errors": ["evaluator produced no JSON: " + err[:200]]}, code, ms, err


def analyse(recording, out_dir, clip_id, extra=(), timeout=1800, env=None):
    cmd = [sys.executable, str(DETECT), "--recording", str(recording),
           "--clip-id", clip_id, "--out", str(out_dir)] + list(extra)
    code, out, err, ms = run(cmd, timeout=timeout, env=env)
    meta = {}
    if (pathlib.Path(out_dir) / "run.json").is_file():
        meta = json.loads((pathlib.Path(out_dir) / "run.json").read_text())
    return code, meta, out, err, ms


# ----------------------------------------------------------------------------------
# supplied clips: S3-C01, C03, C04, C10 over the product's own runs
# ----------------------------------------------------------------------------------
def group_supplied(runs_dir, recordings, dataset_path):
    before = dict(_RESULT)
    data = EV.load_dataset(dataset_path)
    for clip in data["clips"]:
        cid = clip["clip_id"]
        entry = EV.clip_entry(data, cid)
        d = newest_run(runs_dir, cid)
        if d is None:
            check("supplied", "%s analysis run present" % cid, None,
                  "no run under %s" % runs_dir)
            continue
        result, code, ms, err = evaluate(d, cid)
        cov = result.get("coverage", {})
        ok = (result.get("valid") and result.get("provenance", {}).get("input_matches_clip")
              and (cov.get("object_crops_present") or 0) > 0
              and not cov.get("object_crops_missing"))
        check("supplied", "S3-C01 %s valid envelope, input hash, decoded frames, crops" % cid,
              bool(ok), "valid=%s hash_match=%s frames=%s obs=%s crops=%s missing=%s" % (
                  result.get("valid"),
                  result.get("provenance", {}).get("input_matches_clip"),
                  (result.get("provenance", {}).get("measurements") or {}).get("decoded_frame_count"),
                  cov.get("observations"), cov.get("object_crops_present"),
                  len(cov.get("object_crops_missing") or [])), ms)
    # S3-C03 stationary car: semantic car evidence without motion
    for cid in ("WT3-002", "WT3-004"):
        d = newest_run(runs_dir, cid)
        if d is None:
            check("supplied", "S3-C03 %s car while stationary" % cid, None, "no run")
            continue
        result, _, ms, _ = evaluate(d, cid)
        obs = [o for o in result.get("observation_detail", []) if o["class"] == "car"]
        obs.sort(key=lambda o: o["frame_pts_ms"])
        stable = 0
        best = 0
        for a, b in zip(obs, obs[1:]):
            moved = max(abs(a["bbox_xywh"][0] - b["bbox_xywh"][0]),
                        abs(a["bbox_xywh"][1] - b["bbox_xywh"][1]))
            span = b["frame_pts_ms"] - a["frame_pts_ms"]
            if moved <= 0.01 and 200 <= span <= 1500:
                stable += span
                best = max(best, stable)
            else:
                stable = 0
        check("supplied", "S3-C03 %s semantic car evidence while stationary" % cid,
              best >= 2000,
              "%d car observations; longest near-stationary run %.1f s "
              "(box moves <=0.01 per sample)" % (len(obs), best / 1000.0), ms)
    # S3-C04 two people in WT3-007: separate evidence, colour from own pixels
    d = newest_run(runs_dir, "WT3-007")
    if d is None:
        check("supplied", "S3-C04 WT3-007 separate people evidence", None, "no run")
    else:
        result, _, ms, _ = evaluate(d, "WT3-007")
        people = [o for o in result.get("observation_detail", []) if o["class"] == "person"]
        tracks = {}
        for o in people:
            tracks.setdefault(o.get("track_id") or "none", []).append(o)
        check("supplied", "S3-C04a WT3-007 two distinct person tracks",
              len(tracks) >= 2, "%d person tracks: %s" % (len(tracks), sorted(tracks)[:6]),
              ms)

        # (b) every colour must be RE-DERIVABLE from that observation's own saved
        # object crop, with the shipped sampler: the pixels, the region geometry and
        # the object's own surroundings are all in that crop (it IS the detected
        # box), so a label that cannot be reproduced from it did not come from the
        # stated object. Nothing here looks at another observation or another frame.
        run_doc = json.loads((d / "run.json").read_text())
        import cv2
        import stage3_colour as SC
        mismatched, checked_regions, unknown_regions, geometry_bad = [], 0, 0, []
        for ob in run_doc["observations"]:
            ref = (ob.get("evidence") or {}).get("object_crop")
            if not ref:
                continue
            obj = cv2.imread(str(d / ref))
            if obj is None:
                mismatched.append("missing object crop " + ref)
                continue
            for color in ob.get("colors", []):
                checked_regions += 1
                if color["label"] == "unknown":
                    unknown_regions += 1
                rbox = (color.get("evidence") or {}).get("region_box_xywh")
                bbox = ob["bbox_xywh"]
                if not rbox or not (bbox[0] - 1e-6 <= rbox[0]
                                    and bbox[1] - 1e-6 <= rbox[1]
                                    and rbox[0] + rbox[2] <= bbox[0] + bbox[2] + 1e-6
                                    and rbox[1] + rbox[3] <= bbox[1] + bbox[3] + 1e-6):
                    geometry_bad.append(ob["id"])
                    continue
                label, conf, _rb, _crop, _dist = SC.dominant_color(
                    obj, [0.0, 0.0, 1.0, 1.0], color["region"])
                if label != color["label"]:
                    mismatched.append("%s %s: stored %s, recomputed %s"
                                      % (ob["id"], color["region"], color["label"], label))
        check("supplied", "S3-C04b every colour re-derives from its own object crop",
              not mismatched and not geometry_bad,
              "%d colour regions checked, %d unknown, %d mismatched %s, %d regions "
              "outside their object box" % (checked_regions, unknown_regions,
                                            len(mismatched), mismatched[:2],
                                            len(geometry_bad)))

        # (c) the two foreground subjects must carry DIFFERENT colours, and each
        # subject's own label should hold across its observations. Stability is
        # reported as a measured share: it is a quality signal, not a pass mark.
        def majority(rows, region="upper_clothing"):
            counts = {}
            for r in rows:
                for c in r["colors"]:
                    if c["region"] == region and c["label"] != "unknown":
                        counts[c["label"]] = counts.get(c["label"], 0) + 1
            return max(counts.items(), key=lambda kv: kv[1]) if counts else ("unknown", 0)
        big = sorted(((t, rows) for t, rows in tracks.items() if len(rows) >= 3),
                     key=lambda kv: -len(kv[1]))
        summary = {}
        for tid, rows in big[:4]:
            label, n = majority(rows)
            summary[tid] = "n=%d %s %d/%d" % (len(rows), label, n, len(rows))
        dark = any(majority(rows)[0] in ("black", "dark_gray") for _t, rows in big)
        red = any(majority(rows)[0] == "red" for _t, rows in big)
        check("supplied", "S3-C04c WT3-007 one dark and one red foreground subject",
              dark and red, json.dumps(summary))

    # S3-C10 every observation names a real decoded frame with that PTS
    for cid in [c["clip_id"] for c in data["clips"]]:
        d = newest_run(runs_dir, cid)
        if d is None:
            continue
        frames = {}
        for line in (d / "frames.jsonl").read_text().splitlines():
            if line.strip():
                row = json.loads(line)
                frames[row["frame_index"]] = row["pts_ms"]
        run_doc = json.loads((d / "run.json").read_text())
        bad = [o["id"] for o in run_doc["observations"]
               if frames.get(o["frame_index"]) != o["frame_pts_ms"]]
        check("supplied", "S3-C10 %s observations map to the decoded frame's own PTS" % cid,
              not bad, "%d observations, %d mismatched" % (len(run_doc["observations"]),
                                                           len(bad)))
    return _delta(before)


# ----------------------------------------------------------------------------------
# controls: live runs of the real analyser
# ----------------------------------------------------------------------------------
def group_controls(workdir, recordings, dataset_path, recording=None, clip_id=None):
    before = dict(_RESULT)
    workdir.mkdir(parents=True, exist_ok=True)
    src_one = pathlib.Path(recordings) / "clip-001.mp4"
    src_two = pathlib.Path(recordings) / "clip-002.mp4"

    # S3-C02 same bytes, different neutral filename -------------------------------
    if src_two.is_file():
        ren = workdir / "renamed-sample.mp4"
        shutil.copyfile(src_two, ren)
        a = workdir / "c02-a"
        b = workdir / "c02-b"
        code_a, meta_a, _, err_a, ms_a = analyse(src_two, a, "WT3-002",
                                                 ["--sample-fps", "0.5", "--max-frames", "0"])
        code_b, meta_b, _, err_b, ms_b = analyse(ren, b, "WT3-002",
                                                 ["--sample-fps", "0.5", "--max-frames", "0"])
        def dets(meta):
            return sorted((o["class"], o["frame_index"], round(o["confidence"], 6),
                           tuple(round(v, 6) for v in o["bbox_xywh"]))
                          for o in meta.get("observations", []))
        same = code_a == 0 and code_b == 0 and dets(meta_a) == dets(meta_b)
        check("controls", "S3-C02 renamed input: identical detections, identical hash",
              same, "%d vs %d detections; sha %s vs %s" % (
                  len(meta_a.get("observations", [])), len(meta_b.get("observations", [])),
                  str(meta_a.get("input_sha256"))[:12], str(meta_b.get("input_sha256"))[:12]),
              ms_a + ms_b)
    else:
        check("controls", "S3-C02 renamed input equivalence", None, "clip-002.mp4 missing")

    # S3-C05/S3-C06 identity binding between two saved runs -----------------------
    if src_one.is_file() and src_two.is_file():
        ra = newest_run(workdir.parent, "WT3-001") if False else None
        a = workdir / "c05-a"
        b = workdir / "c05-b"
        analyse(src_one, a, "WT3-001", ["--sample-fps", "0.5"])
        analyse(src_two, b, "WT3-002", ["--sample-fps", "0.5"])
        ev_a, _, ms_a, _ = evaluate(a, "WT3-001")
        ev_b, _, ms_b, _ = evaluate(b, "WT3-002")
        ids = {ev_a.get("input_sha256"), ev_b.get("input_sha256")}
        ok = (ev_a.get("valid") and ev_b.get("valid") and len(ids) == 2
              and ev_a.get("clip_id") == "WT3-001" and ev_b.get("clip_id") == "WT3-002")
        check("controls", "S3-C05/C06 two runs stay bound to their own clip and hash",
              ok, "A=%s/%s B=%s/%s" % (ev_a.get("clip_id"), str(ev_a.get("input_sha256"))[:8],
                                       ev_b.get("clip_id"), str(ev_b.get("input_sha256"))[:8]),
              ms_a + ms_b)
        # reopen A after B: same evidence, same digest
        ev_a2, _, _, _ = evaluate(a, "WT3-001")
        check("controls", "S3-C06 reopening A returns A's evidence",
              ev_a2.get("run_sha256") == ev_a.get("run_sha256")
              and ev_a2.get("coverage", {}).get("observations")
              == ev_a.get("coverage", {}).get("observations"),
              "digest %s" % str(ev_a.get("run_sha256"))[:12])
    else:
        check("controls", "S3-C05/C06 run identity binding", None, "supplied clips missing")

    # S3-C07 cancellation, then a clean rerun -------------------------------------
    if src_one.is_file():
        out = workdir / "c07-cancel"
        env = dict(os.environ)
        proc = subprocess.Popen(
            [sys.executable, str(DETECT), "--recording", str(src_one),
             "--clip-id", "WT3-001", "--out", str(out), "--sample-fps", "0.2"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        time.sleep(6.0)
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        meta = json.loads((out / "run.json").read_text()) if (out / "run.json").is_file() else {}
        alive = subprocess.run(["pgrep", "-f", "stage3_detect.py --recording %s" % src_one],
                               capture_output=True, text=True).stdout.strip()
        check("controls", "S3-C07 cancel: honest cancelled state, no orphan process",
              proc.returncode == 3 and meta.get("status") == "cancelled" and not alive,
              "exit=%s status=%s orphans=%r observations=%d" % (
                  proc.returncode, meta.get("status"), alive or "none",
                  len(meta.get("observations", []))))
        rerun = workdir / "c07-rerun"
        code_r, meta_r, _, _, ms_r = analyse(src_one, rerun, "WT3-001",
                                             ["--sample-fps", "0.5"])
        check("controls", "S3-C07 rerun after cancel completes cleanly",
              code_r == 0 and meta_r.get("status") == "completed"
              and len(meta_r.get("observations", [])) > 0,
              "status=%s observations=%d" % (meta_r.get("status"),
                                             len(meta_r.get("observations", []))), ms_r)
    else:
        check("controls", "S3-C07 cancellation", None, "clip-001.mp4 missing")

    # S3-C08 missing input, corrupt input, missing model ---------------------------
    code_m, meta_m, _, err_m, ms_m = analyse(workdir / "does-not-exist.mp4",
                                             workdir / "c08-missing", "MISSING", [])
    check("controls", "S3-C08 missing input is a specific failure",
          code_m != 0 and meta_m.get("status") == "failed"
          and "missing_recording" in json.dumps(meta_m.get("errors", [])),
          "exit=%s status=%s" % (code_m, meta_m.get("status")), ms_m)
    corrupt = workdir / "corrupt.mp4"
    corrupt.write_bytes(os.urandom(200000))
    code_c, meta_c, _, _, ms_c = analyse(corrupt, workdir / "c08-corrupt", "CORRUPT", [])
    check("controls", "S3-C08 corrupt input fails without findings",
          code_c != 0 and meta_c.get("status") == "failed"
          and not meta_c.get("observations"),
          "exit=%s status=%s observations=%d" % (code_c, meta_c.get("status"),
                                                 len(meta_c.get("observations", []))), ms_c)
    empty_weights = workdir / "empty-weights"
    empty_weights.mkdir(exist_ok=True)
    code_w, meta_w, _, _, ms_w = analyse(src_one, workdir / "c08-nomodel", "WT3-001", [],
                                         env={"WT_STAGE3_WEIGHTS_DIR": str(empty_weights)})
    check("controls", "S3-C08 missing model is a prerequisite failure, not no-detection",
          code_w != 0 and meta_w.get("status") == "failed"
          and "missing_model" in json.dumps(meta_w.get("errors", [])),
          "exit=%s status=%s" % (code_w, meta_w.get("status")), ms_w)

    # S3-C09 deliberate invalid result in verification mode ------------------------
    if src_one.is_file():
        base = workdir / "c09-base"
        analyse(src_one, base, "WT3-001", ["--sample-fps", "0.5"])
        run_doc = json.loads((base / "run.json").read_text())
        if run_doc.get("observations"):
            tampered = dict(run_doc)
            bad = json.loads(json.dumps(run_doc["observations"]))
            bad[0]["bbox_xywh"] = [0.9, 0.9, 0.4, 0.4]          # outside the frame
            tampered["observations"] = bad
            vdir = workdir / "c09-verification-mode"
            vdir.mkdir(exist_ok=True)
            (vdir / "run.json").write_text(json.dumps(tampered))
            result, code_v, ms_v, _ = evaluate(vdir, "WT3-001")
            check("controls", "S3-C09 injected invalid result is rejected by the evaluator",
                  (not result.get("valid")) and result.get("status") == "invalid"
                  and result.get("errors"),
                  "status=%s errors=%s" % (result.get("status"),
                                           (result.get("errors") or [""])[0][:90]), ms_v)
        else:
            check("controls", "S3-C09 injected invalid result", None,
                  "the base run produced no observations to tamper with")

    # S3-C12 a future user-supplied recording through the same path ---------------
    if src_one.is_file():
        future = workdir / "future-user-recording.mp4"
        shutil.copyfile(src_one, future)
        code_f, meta_f, _, _, ms_f = analyse(future, workdir / "c12-future",
                                             "future-user-recording",
                                             ["--sample-fps", "0.5"])
        result_f, code_e, _, _ = evaluate(workdir / "c12-future", "future-user-recording")
        check("controls", "S3-C12 future recording analyses with no code change",
              code_f == 0 and meta_f.get("status") == "completed"
              and len(meta_f.get("observations", [])) > 0
              and meta_f.get("clip_id") == "future-user-recording",
              "status=%s observations=%d clip_id=%s" % (
                  meta_f.get("status"), len(meta_f.get("observations", [])),
                  meta_f.get("clip_id")), ms_f)
        check("controls", "S3-C12 unknown clip reports 'no annotations', not a fake pass",
              code_e == 1 and result_f.get("status") == "invalid"
              and any("not in the dataset" in e for e in result_f.get("errors", [])),
              "evaluator: %s" % (result_f.get("errors") or [""])[0][:80])

    # deliberate failure control ---------------------------------------------------
    check("controls", "control: this check is designed to fail", False,
          "deliberate: proves the panel shows a real failure instead of reporting "
          "success unconditionally", 0.0, control=True)
    check("controls", "control: the harness reported that failure",
          _CONTROL["seen"], "the deliberate failure was recorded as FAIL"
          if _CONTROL["seen"] else "THE HARNESS SWALLOWED A FAILURE")
    return _delta(before)


# ----------------------------------------------------------------------------------
# the helper's own suite, the detector's units, and the existing regressions
# ----------------------------------------------------------------------------------
def _suite(group, name, path, timeout=1800, needle=None):
    if not pathlib.Path(path).is_file():
        check(group, name, None, "suite not present: %s" % path)
        return
    code, out, err, ms = run([sys.executable, str(path)], timeout=timeout)
    passes = sum(1 for line in out.splitlines() if line.startswith("PASS "))
    fails = [line for line in out.splitlines() if line.startswith("FAIL ")]
    summary = ""
    for line in out.splitlines():
        if needle and needle in line:
            summary = line.strip()
    tail = out.strip().splitlines()[-1] if out.strip() else err.strip()[:120]
    check(group, name, code == 0 and not fails,
          "%s%s" % (summary or tail, (" | %d FAIL lines" % len(fails)) if fails else ""), ms)
    for line in fails[:5]:
        check(group, name + ": " + line[5:70], False, "reported by the suite")


def group_checks():
    before = dict(_RESULT)
    _suite("checks", "common Stage 3 evidence helper (13 tests)", HELPER_TESTS,
           needle="OK")
    _suite("checks", "Stage 3 detector unit checks", DETECTOR_TESTS)
    return _delta(before)


def group_regressions():
    before = dict(_RESULT)
    _suite("regressions", "existing tracking contract suite", TRACKING_TESTS,
           needle="PASS, ")
    _suite("regressions", "existing Labs worker suite", WORKER_TESTS)
    for label, path in (("shape_observations self-test", SHAPE_SELFTEST),
                        ("object_profile self-test", PROFILE_SELFTEST)):
        if not pathlib.Path(path).is_file():
            check("regressions", label, None, "not present")
            continue
        code, out, err, ms = run([sys.executable, str(path)], timeout=900)
        import re
        m = re.search(r"(\d+)/(\d+) checks passed", out)
        check("regressions", label, code == 0 and m is not None,
              (m.group(0) if m else out.strip()[-80:]), ms)
    return _delta(before)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--group", default="all",
                    choices=["all", "supplied", "controls", "checks", "regressions"])
    ap.add_argument("--runs-dir", default="")
    ap.add_argument("--recordings", default="")
    ap.add_argument("--workdir", default="")
    ap.add_argument("--recording", default="")
    ap.add_argument("--clip-id", default="")
    ap.add_argument("--dataset", default="")
    args = ap.parse_args(argv)

    runs_dir = pathlib.Path(args.runs_dir or
                            (pathlib.Path.home() / ".local/share/Cilex Vision/"
                             "Watchtower/stage3/runs"))
    recordings = args.recordings or _default_recordings()
    workdir = pathlib.Path(args.workdir or tempfile.mkdtemp(prefix="stage3-checks-"))
    groups = (["supplied", "controls", "checks", "regressions"]
              if args.group == "all" else [args.group])
    started = time.time()
    for name in groups:
        before = dict(_RESULT)
        if name == "supplied":
            group_supplied(runs_dir, recordings, args.dataset)
        elif name == "controls":
            group_controls(workdir, recordings, args.dataset)
        elif name == "checks":
            group_checks()
        else:
            group_regressions()
        group(name, _delta(before))

    real_failed = _RESULT["failed"] - _RESULT["control_failed"]
    emit({"event": "done", "passed": _RESULT["passed"], "failed": _RESULT["failed"],
          "skipped": _RESULT["skipped"], "control_failed": _RESULT["control_failed"],
          "real_failed": real_failed, "control_ok": _CONTROL["seen"],
          "elapsed_s": round(time.time() - started, 2), "workdir": str(workdir)})
    return 0 if (real_failed == 0 and _CONTROL["seen"]) else 1


if __name__ == "__main__":
    sys.exit(main())
