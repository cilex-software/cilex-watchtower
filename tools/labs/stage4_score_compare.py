#!/usr/bin/env python3
"""Score ONE frozen prediction set twice: R1 semantics vs corrected semantics.

Nothing is inferred again here. The set produced by stage4_frozen_predictions.py is
loaded once and fed to both paths, so every difference in the totals is a SCORING
difference and never a recognition improvement.

    old path  = tools/labs/stage4_evaluate.score_predictions  (R1: local-swap
                tie-break, no ignore regions, no coverage records)
    new path  = tools/labs/stage4_scoring.score               (exact matching,
                class-scoped ignore regions, explicit coverage, declared
                denominators)

Also reports which per-class counts moved and why: ignore regions can only move
predictions from FP to IGNORED; the exact matcher can change WHICH reference a
prediction is paired with (and the mean IoU) but not the cardinality, so TP/FP/FN
from matching are unchanged by it.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

import numpy as np

_HERE = pathlib.Path(__file__).resolve().parent
ROOT = _HERE.parent.parent
sys.path.insert(0, str(_HERE))

import stage4_data as DATA          # noqa: E402
import stage4_evaluate as OLD       # noqa: E402
import stage4_scoring as NEW        # noqa: E402

BUILD = ROOT / "build" / "stage4"
DEFAULT_DIR = BUILD / "R2-frozen-predictions"


def load_jsonl(path):
    out = []
    for line in pathlib.Path(path).read_text().splitlines():
        line = line.strip()
        if line:
            out.append(json.loads(line))
    return out


def load_set(directory, approach):
    d = pathlib.Path(directory)
    preds = load_jsonl(d / ("predictions-%s.jsonl" % approach))
    refs = load_jsonl(d / ("references-%s.jsonl" % approach))
    identity = json.loads((d / ("identity-%s.json" % approach)).read_text())
    return preds, refs, identity


def frame_maps(preds, refs):
    """Keyed by the record's own identity (clip + frame index).

    Keying by frame_index alone collided across the three validation clips and
    silently reduced 135 frames to 84 — the coverage check caught it.
    """
    p = {rec.get("key", "%s:f%06d" % (rec.get("clip_id", "?"), rec["frame_index"])): rec
         for rec in preds}
    r = {rec.get("key", "%s:f%06d" % (rec.get("clip_id", "?"), rec["frame_index"])): rec
         for rec in refs}
    return p, r


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=str(DEFAULT_DIR))
    ap.add_argument("--out", default=str(BUILD / "R2-scoring-comparison.json"))
    args = ap.parse_args(argv)

    report = {"schema": "stage4-r2-scoring-comparison/1",
              "note": "identical frozen predictions scored by both paths; a scoring "
                      "correction is not improved recognition",
              "approaches": {}}
    for approach in ("A", "B"):
        preds, refs, identity = load_set(args.dir, approach)
        pmap, rmap = frame_maps(preds, refs)

        # ---------------- coverage (new requirement) --------------------------
        requested = [{"key": k, "frame_index": rec["frame_index"], "frame_pts_ms": None}
                     for k, rec in rmap.items()]
        records = {}
        for idx, rec in pmap.items():
            records[idx] = {"boxes": rec["boxes"], "classes": rec["classes"],
                            "frame_pts_ms": rec.get("frame_pts_ms")}
        coverage = NEW.validate_coverage(requested, records, rmap)

        # ---------------- old path (R1 semantics) -----------------------------
        old_preds = {idx: (np.array(rec["boxes"], np.float64).reshape(-1, 4),
                           np.array(rec["scores"], np.float64),
                           np.array(rec["classes"], np.int64))
                     for idx, rec in pmap.items()}
        old_refs = {idx: (np.array([o["bbox_xywh"] for o in rec["objects"]],
                                   np.float64).reshape(-1, 4),
                          np.array([DATA.CLASS_ID[o["class"]] for o in rec["objects"]],
                                   np.int64))
                    for idx, rec in rmap.items()}
        old_scored = OLD.score_predictions(old_preds, old_refs, iou_threshold=0.5)

        # ---------------- new path -------------------------------------------
        new_preds = {idx: {"boxes": rec["boxes"], "scores": rec["scores"],
                           "classes": rec["classes"], "frame_pts_ms": rec.get("frame_pts_ms")}
                     for idx, rec in pmap.items()}
        new_refs = {idx: {"objects": [o for o in rec["objects"] if o["class"] in NEW.CLASSES],
                          "ignore_regions": rec.get("ignore_regions", []),
                          "reviewed_classes": rec.get("reviewed_classes", [])}
                    for idx, rec in rmap.items()}
        new_scored = NEW.score(new_preds, new_refs, 0.5, coverage=coverage)

        deltas = {}
        for cls in NEW.CLASSES:
            o = old_scored["per_class"][cls]
            n = new_scored["per_class"][cls]
            deltas[cls] = {k: n[k] - o[k] for k in ("tp", "fp", "fn")}
            deltas[cls]["ignored_new"] = n["ignored"]
        report["approaches"][approach] = {
            "identity": identity,
            "coverage": coverage,
            "old": {"per_class": old_scored["per_class"], "micro": old_scored["micro"],
                    "macro": old_scored["macro"]},
            "new": {"per_class": new_scored["per_class"], "micro": new_scored["micro"],
                    "macro": new_scored["macro"]},
            "deltas": deltas,
            "explanation": {
                "ignore_regions": "unmatched predictions at least half inside a "
                                  "class-scoped released ignore region move from FP to "
                                  "IGNORED; they stay visible in the raw counts",
                "matching": "cardinality is identical in both paths (verified), so "
                            "TP/FP/FN from matching cannot move because of the exact "
                            "tie-break; what changes is WHICH reference a prediction is "
                            "paired with and therefore the mean IoU and any "
                            "matched-pair analysis",
                "coverage": "frames are scored only where a prediction record exists; "
                            "the coverage block states how many were requested, "
                            "recorded and empty",
            },
        }
        print("%s: old micro tp=%d fp=%d fn=%d | new tp=%d fp=%d fn=%d ignored=%d | "
              "coverage %d/%d complete=%s"
              % (approach, old_scored["micro"]["tp"], old_scored["micro"]["fp"],
                 old_scored["micro"]["fn"], new_scored["micro"]["tp"],
                 new_scored["micro"]["fp"], new_scored["micro"]["fn"],
                 new_scored["micro"]["ignored"], coverage["records"],
                 coverage["requested"], coverage["complete"]))
    pathlib.Path(args.out).write_text(json.dumps(report, indent=1, sort_keys=True))
    print("wrote", args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
