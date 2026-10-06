#!/usr/bin/env python3
"""Build review contact sheets from a run's OWN evidence, outside the repo.

The Stage 3 pack keeps evidence local and puts no footage in Git, so the sheets
this writes -- one per target: the annotated full frame beside the object and
region crops the analyser saved -- live wherever you point --out (default: a temp
directory). Nothing here runs inference: it reads `run.json`, the saved crops and
the clip, draws the boxes THE RUN claims, and writes an image a human can judge.

    stage3_review_sheets.py [--runs-dir DIR] [--out DIR] [--dataset PATH]

It is the tool the development review used; an operator can rebuild the same
sheets for any run, including a run made after this submission.
"""
"""Build review contact sheets from a run's OWN evidence (no new inference).

For each target: the annotated full frame (box + region box drawn where the
analyser claims them) beside the object crop and the region crops it kept.
"""
import json, os, pathlib, subprocess, sys
import cv2, numpy as np
sys.path.insert(0, "tools/labs")
import stage3_evaluate as EV

def _default_runs() -> pathlib.Path:
    override = os.environ.get("WT_STAGE3_RUNS")
    if override:
        return pathlib.Path(override)
    if sys.platform == "darwin":
        return (pathlib.Path.home() / "Library/Application Support/Cilex Vision/"
                "Watchtower/stage3/runs")
    return (pathlib.Path.home() / ".local/share/Cilex Vision/Watchtower/stage3/runs")


def _default_clips() -> pathlib.Path:
    override = os.environ.get("WT_STAGE3_CLIPS")
    if override:
        return pathlib.Path(override)
    movies = pathlib.Path.home() / ("Movies" if sys.platform == "darwin" else "Videos")
    candidate = movies / "Watchtower-Stage3"
    if candidate.is_dir():
        return candidate
    dev = pathlib.Path("/home/cilex-vision/Videos/Watchtower-Stage3")
    return dev if dev.is_dir() else candidate


RUNS = _default_runs()
CLIPS = _default_clips()
OUT = pathlib.Path(os.environ.get("WT_STAGE3_SHEETS", "/tmp/stage3-review-sheets"))
OUT.mkdir(parents=True, exist_ok=True)
data = EV.load_dataset()

def newest(clip):
    return sorted([d for d in RUNS.glob(clip + "-*") if (d / "run.json").is_file()])[-1]

def frame_image(clip_file, index, width=900):
    out = subprocess.run(["ffmpeg", "-v", "error", "-i", str(clip_file),
                          "-vf", "select=eq(n\\,%d),scale=%d:-2" % (index, width),
                          "-frames:v", "1", "-f", "image2pipe", "-vcodec", "png", "-"],
                         capture_output=True)
    return cv2.imdecode(np.frombuffer(out.stdout, np.uint8), cv2.IMREAD_COLOR)

def sheet(clip_id, target_id, obs_id):
    d = newest(clip_id)
    run = json.loads((d / "run.json").read_text())
    ob = next(o for o in run["observations"] if o["id"] == obs_id)
    entry = EV.clip_entry(data, clip_id)
    img = frame_image(CLIPS / ("clip-%s.mp4" % clip_id.split("-")[1]), ob["frame_index"])
    if img is None:
        return None
    h, w = img.shape[:2]
    x, y, bw, bh = ob["bbox_xywh"]
    p1 = (int(x * w), int(y * h)); p2 = (int((x + bw) * w), int((y + bh) * h))
    cv2.rectangle(img, p1, p2, (90, 200, 90), 2)
    for c in ob["colors"]:
        rb = c["evidence"]["region_box_xywh"]
        cv2.rectangle(img, (int(rb[0] * w), int(rb[1] * h)),
                      (int((rb[0] + rb[2]) * w), int((rb[1] + rb[3]) * h)), (60, 160, 240), 1)
    cv2.putText(img, "%s %s %.2f" % (ob["class"], target_id, ob["confidence"]),
                (p1[0], max(18, p1[1] - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (90, 200, 90), 2)
    y0 = 0
    for c in ob["colors"]:
        cv2.putText(img, "%s=%s %.2f" % (c["region"], c["label"], c["confidence"]),
                    (10, 24 + y0), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                    (60, 160, 240) if c["label"] != "unknown" else (150, 150, 150), 2)
        y0 += 26
    strips = []
    obj = cv2.imread(str(d / ob["evidence"]["object_crop"]))
    if obj is not None:
        scale = 260 / obj.shape[0]
        strips.append(cv2.resize(obj, (max(1, int(obj.shape[1] * scale)), 260)))
    for c in ob["colors"]:
        ref = c["evidence"].get("region_crop")
        if not ref:
            continue
        rc = cv2.imread(str(d / ref))
        if rc is None:
            continue
        scale = 260 / rc.shape[0]
        rc = cv2.resize(rc, (max(1, int(rc.shape[1] * scale)), 260))
        strips.append(rc)
    if strips:
        strip = np.hstack([np.pad(s, ((0, 0), (0, 8), (0, 0)), constant_values=30)
                           for s in strips])
        target_h = max(img.shape[0], strip.shape[0])
        def pad_to(a, h):
            if a.shape[0] == h:
                return a
            return np.pad(a, ((0, h - a.shape[0]), (0, 0), (0, 0)), constant_values=25)
        img = np.hstack([pad_to(img, target_h), pad_to(strip, target_h)])
    path = OUT / ("%s-%s-%s.png" % (clip_id, target_id, obs_id))
    cv2.imwrite(str(path), img)
    return path, ob

report = []
for clip in data["clips"]:
    cid = clip["clip_id"]
    d = newest(cid)
    if not d:
        continue
    run = json.loads((d / "run.json").read_text())
    for target in clip["targets"]:
        same = [o for o in run["observations"] if o["class"] == target["class"]]
        qualify = []
        for o in same:
            ok = all(any(c["region"] == req["region"] and c["label"] in req["accepted_labels"]
                         for c in o["colors"]) for req in target["required_colors"])
            if ok:
                qualify.append(o)
        pick = max(qualify, key=lambda o: o["confidence"]) if qualify else (
            max(same, key=lambda o: o["confidence"]) if same else None)
        if not pick:
            report.append({"clip": cid, "target": target["target_id"], "observation": None})
            continue
        made = sheet(cid, target["target_id"], pick["id"])
        report.append({"clip": cid, "target": target["target_id"], "class": target["class"],
                       "required": target["required_colors"],
                       "observation": pick["id"], "pts_ms": pick["frame_pts_ms"],
                       "confidence": pick["confidence"],
                       "colors": [(c["region"], c["label"], c["confidence"]) for c in pick["colors"]],
                       "qualifying": bool(qualify), "sheet": str(made[0]) if made else None,
                       "candidates": len(same)})
(OUT / "index.json").write_text(json.dumps(report, indent=1))
for r in report:
    print("%-8s %-14s %-7s obs=%-10s n=%-4s %s %s" % (
        r["clip"], r["target"], r.get("class", ""), r.get("observation"),
        r.get("candidates"), "QUALIFYING" if r.get("qualifying") else "-",
        r.get("colors", "")))
