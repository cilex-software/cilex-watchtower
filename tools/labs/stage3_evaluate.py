#!/usr/bin/env python3
"""Stage 3 target evaluator: the ONLY place clip annotations are read.

WHY THIS IS A SEPARATE PROGRAM FROM THE DETECTOR. The Stage 3 rules require that
expected targets and evaluation labels stay out of the inference code path. The
detector (`stage3_detect.py`) never opens this file's inputs; it sees pixels and
writes observations. This program opens `dataset.json`, binds a run to the clip it
claims, calls the common evidence helper, and reports candidate observations per
target. A candidate is not a pass: the helper returns `review_required` until a
named human records a decision.

    stage3_evaluate.py --run RUNDIR [--clip-id ID] [--review review.json]
    stage3_evaluate.py --list-targets --clip-id WT3-001
    stage3_evaluate.py --eval-schedule --clip-id WT3-001

Output is one JSON object on stdout. Exit 0 when the run is structurally valid
(with or without candidates), 1 when it is invalid or the inputs are missing.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import stage3_evidence as E                     # noqa: E402  (common helper, verbatim)

DEFAULT_STAGE3_DOCS = _HERE.parent.parent / "docs" / "benchmarks" / "labs-detection-stage3"


def sha256_file(path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def load_dataset(path=None) -> dict:
    path = pathlib.Path(path or (DEFAULT_STAGE3_DOCS / "dataset.json"))
    data = json.loads(path.read_text(encoding="utf-8"))
    data["_path"] = str(path)
    data["_sha256"] = sha256_file(path)
    return data


def clip_entry(data: dict, clip_id: str) -> dict:
    """The helper's clip view: identity, media duration and the target list."""
    for clip in data.get("clips", []):
        if clip.get("clip_id") == clip_id:
            return {"clip_id": clip["clip_id"], "sha256": clip["sha256"],
                    "media": {"duration_ms": clip["media"]["duration_ms"],
                              "width": clip["media"].get("width"),
                              "height": clip["media"].get("height")},
                    "targets": clip["targets"],
                    "_source_filename": clip.get("source_filename"),
                    "_title": clip.get("title")}
    raise KeyError("clip %r is not in the dataset" % clip_id)


def evidence_coverage(run: dict, run_dir: pathlib.Path) -> dict:
    """Do the crops an observation NAMES actually exist on disk?

    The common helper reads JSON only; a run can be structurally perfect while
    pointing at crops that were never written. This is the check that closes that
    gap, and it is reported rather than enforced so a missing crop is visible.
    """
    present, missing, region_present, region_missing = 0, [], 0, 0
    for ob in run.get("observations", []):
        ref = (ob.get("evidence") or {}).get("object_crop")
        if ref:
            if (run_dir / ref).is_file():
                present += 1
            else:
                missing.append(ref)
        for color in ob.get("colors", []):
            cref = (color.get("evidence") or {}).get("region_crop")
            if cref:
                if (run_dir / cref).is_file():
                    region_present += 1
                else:
                    region_missing += 1
    pts = [ob["frame_pts_ms"] for ob in run.get("observations", [])
           if isinstance(ob.get("frame_pts_ms"), (int, float))]
    by_index = {}
    for ob in run.get("observations", []):
        if isinstance(ob.get("frame_index"), int) and isinstance(ob.get("frame_pts_ms"), (int, float)):
            by_index.setdefault(ob["frame_index"], ob["frame_pts_ms"])
    ordered = [by_index[k] for k in sorted(by_index)]
    classes = {}
    for ob in run.get("observations", []):
        classes[ob.get("class")] = classes.get(ob.get("class"), 0) + 1
    return {"object_crops_present": present, "object_crops_missing": missing[:10],
            "region_crops_present": region_present,
            "region_crops_missing": region_missing,
            "observations": len(run.get("observations", [])),
            "classes": classes,
            "pts_increasing": all(a < b for a, b in zip(ordered, ordered[1:])),
            "first_pts_ms": ordered[0] if ordered else None,
            "last_pts_ms": ordered[-1] if ordered else None,
            "distinct_frames": len(ordered)}


def evaluate(run_dir: pathlib.Path, clip_id: str = None, dataset=None,
             review_path=None) -> dict:
    data = dataset if isinstance(dataset, dict) else load_dataset(dataset)
    run_path = run_dir / "run.json"
    if not run_path.is_file():
        return {"valid": False, "errors": ["no run.json in %s" % run_dir],
                "status": "invalid", "targets": [], "summary": {}}
    run = json.loads(run_path.read_text(encoding="utf-8"))
    clip_id = clip_id or run.get("clip_id")
    try:
        entry = clip_entry(data, clip_id)
    except KeyError as exc:
        return {"valid": False, "errors": [str(exc)], "status": "invalid",
                "targets": [], "summary": {}}
    review = None
    if review_path:
        review = json.loads(pathlib.Path(review_path).read_text(encoding="utf-8"))
    result = E.assess_targets(run, entry, review)
    result["clip_id"] = clip_id
    result["run_id"] = run.get("run_id")
    result["run_status"] = run.get("status")
    result["run_sha256"] = E.evidence_digest(run) if isinstance(run, dict) else None
    result["input_sha256"] = run.get("input_sha256")
    result["reviewer"] = (review or {}).get("reviewer")
    result["provenance"] = {
        "dataset_path": data.get("_path"), "dataset_sha256": data.get("_sha256"),
        "clip_sha256": entry["sha256"],
        "run_input_sha256": run.get("input_sha256"),
        "input_matches_clip": run.get("input_sha256") == entry["sha256"],
        "analyser": run.get("analyser"), "model": run.get("model"),
        "source_revision": run.get("source_revision"),
        "measurements": run.get("measurements"),
        "config": run.get("config"),
        "neutral_title": entry.get("_title")}
    result["coverage"] = evidence_coverage(run, run_dir)
    result["observation_detail"] = [
        {"id": ob.get("id"), "class": ob.get("class"),
         "frame_index": ob.get("frame_index"), "frame_pts_ms": ob.get("frame_pts_ms"),
         "confidence": ob.get("confidence"), "bbox_xywh": ob.get("bbox_xywh"),
         "track_id": ob.get("track_id"),
         "colors": [{"region": c.get("region"), "label": c.get("label"),
                     "confidence": c.get("confidence")} for c in ob.get("colors", [])],
         "crop": (ob.get("evidence") or {}).get("object_crop")}
        for ob in run.get("observations", [])]
    return result


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run")
    ap.add_argument("--clip-id")
    ap.add_argument("--dataset")
    ap.add_argument("--review")
    ap.add_argument("--out")
    ap.add_argument("--list-targets", action="store_true")
    ap.add_argument("--eval-schedule", action="store_true")
    ap.add_argument("--json", action="store_true", help="accepted; output is JSON anyway")
    args = ap.parse_args(argv)

    data = load_dataset(args.dataset)

    if args.list_targets:
        if not args.clip_id:
            print(json.dumps({"error": "--clip-id is required"}, indent=1))
            return 1
        entry = clip_entry(data, args.clip_id)
        print(json.dumps({"clip_id": entry["clip_id"], "title": entry["_title"],
                          "source_filename": entry["_source_filename"],
                          "targets": entry["targets"],
                          "dataset_sha256": data["_sha256"]}, indent=1))
        return 0

    if args.eval_schedule:
        if not args.clip_id:
            print(json.dumps({"error": "--clip-id is required"}, indent=1))
            return 1
        entry = clip_entry(data, args.clip_id)
        duration = entry["media"]["duration_ms"]
        schedule = list(range(0, int(duration), 1000))
        print(json.dumps({"clip_id": entry["clip_id"], "duration_ms": duration,
                          "requested_frame_pts_ms": schedule,
                          "rule": "first decoded frame at or after each whole second "
                                  "relative to the first decoded frame"},
                         indent=1))
        return 0

    if not args.run:
        print(json.dumps({"error": "--run is required"}, indent=1))
        return 1
    result = evaluate(pathlib.Path(args.run), args.clip_id, data, args.review)
    text = json.dumps(result, indent=1, sort_keys=True, allow_nan=False)
    if args.out:
        pathlib.Path(args.out).write_text(text, encoding="utf-8")
    print(text)
    return 0 if result.get("valid") else 1


if __name__ == "__main__":
    sys.exit(main())
