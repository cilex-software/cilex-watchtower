#!/usr/bin/env python3
"""Stage-3 target checklist and review store — the ONLY code that reads labels.

`semantic_objects.py` never sees dataset.json, inputs.json, a filename, a
clip id or a hash when deciding what to report. This module is the other half:
AFTER a run exists, it loads the public manifest, asks the common helper
(`stage3_evidence.py`) to validate the run and find candidate evidence per
target, and records a human reviewer's decisions against an immutable digest of
the run.

The boundary matters:

  * `evaluate` produces CANDIDATES. `review_required` means "a structurally
    valid observation of the right class and colours exists and a person must
    now look at it". It never means the target was detected correctly.
  * `review` stores a decision (`accepted` / `rejected` / `unreviewable`) with a
    reviewer identifier and a reason. A supplied reviewer string is attribution,
    not authentication, and this module says so; it will not accept a review that
    does not bind to the exact run digest.
  * Nothing here computes precision/recall/F1. CASES.md's annotation plan is the
    only route to those numbers and it has not been executed.

Watchtower drives this through `LabsSemanticJob`/`LabsSemanticRuns`; the same
commands work from a terminal for reproducibility:

    python3 tools/labs/stage3_checklist.py evaluate --run RUN.json --clip-id WT3-005
    python3 tools/labs/stage3_checklist.py review   --run RUN.json --clip-id WT3-005 \
        --reviewer NAME --decisions '[{"target_id": "...", "decision": "accepted", \
        "observation_ids": ["o000001"], "note": "..."}]' --out REVIEW.json
    python3 tools/labs/stage3_checklist.py status   --run RUN.json --review REVIEW.json --clip-id WT3-005
"""
from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import stage3_evidence as E                                  # noqa: E402

DEFAULT_DATASET = os.path.join(HERE, os.pardir, os.pardir,
                               "docs", "benchmarks", "labs-detection-stage3", "dataset.json")


def load_dataset(path: str | None = None) -> dict:
    p = path or os.environ.get("WT_LABS_S3_DATASET") or os.path.normpath(DEFAULT_DATASET)
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def clip_by_id(dataset: dict, clip_id: str) -> dict | None:
    for c in dataset.get("clips", []):
        if c.get("clip_id") == clip_id:
            return c
    return None


def load_run(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def evaluate(run_path: str, clip_id: str, dataset_path: str | None = None) -> dict:
    """Candidates for every target of one clip against one finished run."""
    run = load_run(run_path)
    dataset = load_dataset(dataset_path)
    clip = clip_by_id(dataset, clip_id)
    out = {"run_id": run.get("run_id"), "clip_id": clip_id,
           "run_path": os.path.abspath(run_path),
           "input_sha256": run.get("input_sha256"),
           "run_sha256": E.evidence_digest(run),
           "run_status": run.get("status")}
    if clip is None:
        out.update({"manifest": False,
                    "note": "no manifest entry for this clip id: the target checklist does not "
                            "apply to arbitrary recordings; the run itself is still valid evidence",
                    "validation_errors": [], "targets": [], "summary": {}})
        return out
    if run.get("input_sha256") != clip.get("sha256"):
        out.update({"manifest": True, "identity_mismatch": True,
                    "note": "the run's input hash does not match this manifest clip; refusing to "
                            "score one clip's run against another clip's targets",
                    "validation_errors": ["input_sha256 does not match clip"],
                    "targets": [], "summary": {}})
        return out
    errors = E.validate_run(run, clip)
    out.update({"manifest": True, "identity_mismatch": False,
                "validation_errors": errors})
    if errors:
        out.update({"status": "invalid", "targets": [], "summary": {}})
        return out
    res = E.assess_targets(run, clip)
    # The helper's rows carry candidate ids and status; the manifest side of each
    # target (its class and required colours) is attached HERE, in the only module
    # allowed to read annotations, so the UI can show what is being asked for.
    by_id = {t.get("target_id"): t for t in clip.get("targets", [])}
    for row in res["targets"]:
        src = by_id.get(row.get("target_id"), {})
        row["class"] = src.get("class")
        row["required_colors"] = src.get("required_colors", [])
    out.update({"status": res["status"], "targets": res["targets"], "summary": res["summary"],
                "clip_title": clip.get("title"),
                "camera_label": (clip.get("filename_provenance") or {}).get("camera_label"),
                "buckets": (clip.get("metadata_buckets") or {}).get("easy")})
    return out


def review(run_path: str, clip_id: str, reviewer: str, decisions: list,
           dataset_path: str | None = None) -> dict:
    """Record a human decision set against the run's digest. Never auto-accepts."""
    run = load_run(run_path)
    dataset = load_dataset(dataset_path)
    clip = clip_by_id(dataset, clip_id)
    if clip is None:
        raise ValueError(f"no manifest clip {clip_id}")
    obj = {"run_id": run.get("run_id"), "input_sha256": run.get("input_sha256"),
           "run_sha256": E.evidence_digest(run), "reviewer": reviewer, "targets": decisions}
    res = E.assess_targets(run, clip, review=obj)
    if not res.get("valid"):
        raise ValueError("review rejected by the common helper: " + "; ".join(res.get("errors", [])))
    return {"review": obj, "assessment": {"status": res["status"], "targets": res["targets"],
                                          "summary": res["summary"]}}


def status(run_path: str, review_path: str | None, clip_id: str,
           dataset_path: str | None = None) -> dict:
    run = load_run(run_path)
    dataset = load_dataset(dataset_path)
    clip = clip_by_id(dataset, clip_id)
    if clip is None:
        return {"status": "no_manifest", "targets": [], "summary": {}}
    rev = None
    if review_path and os.path.isfile(review_path):
        rev = json.load(open(review_path, encoding="utf-8"))
    res = E.assess_targets(run, clip, review=rev)
    return {"status": res["status"], "targets": res["targets"], "summary": res["summary"],
            "errors": res.get("errors", [])}


def control_invalid(run_path: str, clip_id: str, dataset_path: str | None = None) -> dict:
    """Deliberate-failure control (CASES.md S3-C09), in LABELLED verification mode.

    Takes a REAL finished run, corrupts one observation the way a broken
    detector would (a box outside the frame, a confidence above 1, a duplicated
    observation id), writes the corrupt document to its own path with a
    `verification_control` marker, and returns the common helper's structural
    verdict. The corrupt document is never stored among real runs and never
    shown as one: it exists to prove the interface displays a genuine failure.
    """
    run = load_run(run_path)
    corrupt = json.loads(json.dumps(run))
    corrupt["run_id"] = "VERIFICATION-INVALID-" + str(run.get("run_id"))
    corrupt["verification_control"] = ("deliberately invalid evidence; not a real analysis; "
                                       "never mix with clip findings")
    if corrupt.get("observations"):
        ob = corrupt["observations"][0]
        ob["bbox_xywh"] = [0.9, 0.9, 0.5, 0.5]          # leaves the frame
        ob["confidence"] = 1.7                            # outside 0..1
        corrupt["observations"].append(dict(ob, id=ob["id"]))   # duplicate id
    else:
        corrupt["observations"] = [{"id": "x", "frame_index": -1, "frame_pts_ms": -5,
                                    "class": "person", "confidence": 2.0,
                                    "bbox_xywh": [0, 0, 2, 2], "colors": []}]
    out_path = run_path.replace(".json", ".verification-invalid.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(corrupt, f, ensure_ascii=True, allow_nan=False)
    dataset = load_dataset(dataset_path)
    clip = clip_by_id(dataset, clip_id)
    errors = E.validate_run(corrupt, clip) if clip else ["no manifest clip"]
    return {"control": "deliberate-invalid", "invalid_run_path": os.path.abspath(out_path),
            "validation_errors": errors,
            "expected": "the common validation and the Labs interface must report failure",
            "assessment_status": (E.assess_targets(corrupt, clip).get("status") if clip else "invalid")}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="stage3_checklist", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("evaluate", "review", "status", "control-invalid"):
        p = sub.add_parser(name)
        p.add_argument("--run", required=True)
        p.add_argument("--clip-id", required=True)
        p.add_argument("--dataset", default="")
        if name == "review":
            p.add_argument("--reviewer", required=True)
            p.add_argument("--decisions", required=True)
            p.add_argument("--out", required=True)
        if name == "status":
            p.add_argument("--review", default="")
        if name == "control-invalid":
            pass
    args = ap.parse_args(argv)
    ds = args.dataset or None
    if args.cmd == "evaluate":
        json.dump(evaluate(args.run, args.clip_id, ds), sys.stdout, ensure_ascii=False, indent=1)
        print()
        return 0
    if args.cmd == "review":
        decisions = json.loads(args.decisions)
        out = review(args.run, args.clip_id, args.reviewer, decisions, ds)
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(out["review"], f, ensure_ascii=False, indent=1)
        json.dump(out["assessment"], sys.stdout, ensure_ascii=False, indent=1)
        print()
        return 0
    if args.cmd == "control-invalid":
        res = control_invalid(args.run, args.clip_id, ds)
        json.dump(res, sys.stdout, ensure_ascii=False, indent=1)
        print()
        return 0
    res = status(args.run, args.review, args.clip_id, ds)
    json.dump(res, sys.stdout, ensure_ascii=False, indent=1)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
