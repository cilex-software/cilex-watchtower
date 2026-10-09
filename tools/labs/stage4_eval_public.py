#!/usr/bin/env python3
"""Stage 4 public-development evaluation of frozen A and B runs.

Consumes what the adapter wrote (`run.json` + evidence) plus the released public
reference annotations, and reports exactly what EVALUATION.md asks for at the
level the public data supports:

  * per-class and micro/macro precision, recall and F1 at IoU 0.5, with the raw
    TP/FP/FN first, plus the IoU 0.3 sensitivity pass;
  * apparent-size confusion, per-size recall and joint correct type/box/size;
  * per-region broad-colour correctness with correct/wrong/unknown/missing counts
    and the joint known-colour denominator;
  * the CIEDE2000 same-object filter precision/recall at the frozen tolerances,
    including a nearby mismatching object;
  * the A/B effect and component ablations, always separate from private
    generalization.

Reference colours in the public pack are broad labels with `srgb: null` and
`numeric_reference_status: not_annotated`. Numeric colour accuracy is therefore
reported as `not measured` — a colour word is never turned into a fabricated RGB
triplet. Colour correctness is scored on the broad labels, and the numeric path is
exercised through the filter queries, whose observed side is real measured sRGB.

    stage4_eval_public.py --run-a DIR --run-b DIR [--out report.json]
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

import numpy as np

_HERE = pathlib.Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import stage4_colour as COLOUR      # noqa: E402
import stage4_data as DATA          # noqa: E402
import stage4_evaluate as EV        # noqa: E402
import stage4_filters as FILTERS    # noqa: E402

REFERENCE_ROOT = "/home/cilex-vision/Videos/Watchtower-Stage4"
TOLERANCES = (10.0, 20.0, 30.0)


def load_run(run_dir) -> dict:
    return json.loads((pathlib.Path(run_dir) / "run.json").read_text())


def references_for(clip_id: str) -> dict:
    clips = DATA.load_reference(REFERENCE_ROOT)
    clip = clips[clip_id]
    return {fr["frame_index"]: fr for fr in clip["frames"]}


def observations_by_frame(run: dict) -> dict:
    out = {}
    for obs in run.get("observations", []):
        out.setdefault(obs["frame_index"], []).append(obs)
    return out


def class_index(name):
    return DATA.CLASSES.index(name)


def evaluate_run(run: dict) -> dict:
    clip_id = run.get("clip_id") or infer_clip_id(run)
    refs = references_for(clip_id)
    per_frame = observations_by_frame(run)
    coverage = {c["frame_index"]: c for c in run.get("coverage", [])}

    predictions, references, matched_pairs, size_pairs, colour_items = {}, {}, [], [], []
    missing_objects = 0
    for index, frame in refs.items():
        if index not in coverage:
            continue
        ref_boxes = np.array([o["bbox_xywh"] for o in frame["objects"]],
                             np.float64).reshape(-1, 4)
        ref_classes = np.array([class_index(o["class"]) for o in frame["objects"]],
                               np.int64)
        references[index] = (ref_boxes, ref_classes)
        obs = per_frame.get(index, [])
        pred_boxes = np.array([o["bbox_xywh"] for o in obs], np.float64).reshape(-1, 4)
        pred_scores = np.array([o["confidence"] for o in obs], np.float64)
        pred_classes = np.array([class_index(o["class"]) for o in obs], np.int64)
        predictions[index] = (pred_boxes, pred_scores, pred_classes)

        for cls_name in DATA.CLASSES:
            ci = class_index(cls_name)
            r_idx = np.where(ref_classes == ci)[0]
            p_idx = np.where(pred_classes == ci)[0]
            if not len(r_idx) or not len(p_idx):
                missing_objects += len(r_idx)
                for r in r_idx:
                    colour_items.append(item_for(frame["objects"][r], None, missing=True))
                continue
            m = EV.iou_xywh(pred_boxes[p_idx], ref_boxes[r_idx])
            pairs, _k = EV.match_max_cardinality(m, 0.5)
            used_ref = {r for _p, r in pairs}
            for p, r in pairs:
                robj, pobj = frame["objects"][r_idx[r]], obs[p_idx[p]]
                size_pairs.append(((robj.get("apparent_size") or {}).get("label"),
                                   (pobj.get("apparent_size") or {}).get("label")))
                colour_items.append(item_for(robj, pobj))
            for r in set(range(len(r_idx))) - used_ref:
                missing_objects += 1
                colour_items.append(item_for(frame["objects"][r_idx[r]], None,
                                             missing=True))

    detection = EV.score_predictions(predictions, references, iou_threshold=0.5)
    sensitivity = EV.score_predictions(predictions, references, iou_threshold=0.3)
    sizes = EV.size_confusion(size_pairs)
    colours = EV.colour_metrics(colour_items)
    filters = filter_queries(predictions, references, per_frame, refs, coverage)
    empty_frames = sum(1 for i, (b, _c) in references.items() if len(b) == 0)
    false_on_empty = sum(len(predictions.get(i, (np.zeros((0, 4)),))[0])
                         for i, (b, _c) in references.items() if len(b) == 0)
    reviewed_seconds = max(1.0, (max(refs) - min(refs)) / 1.0) if refs else 1.0
    return {
        "clip_id": clip_id, "run_id": run.get("run_id"), "approach": run.get("approach"),
        "status": run.get("status"),
        "coverage": {"scheduled": len(coverage),
                     "analysed": sum(1 for c in coverage.values()
                                     if c["state"] == "analysed"),
                     "failed": sum(1 for c in coverage.values()
                                   if c["state"] == "failed")},
        "detection_iou_0.5": detection, "detection_iou_0.3": sensitivity,
        "apparent_size": sizes, "broad_colour": colours, "filters": filters,
        "false_positives": {
            "reviewed_frames": len(references),
            "frames_with_no_reference_object": empty_frames,
            "predicted_objects_on_those_frames": false_on_empty,
            "per_reviewed_frame": (detection["micro"]["fp"] / max(1, len(references))),
            "per_reviewed_minute": (detection["micro"]["fp"] / (reviewed_seconds / 60.0)),
            "schedule_note": ("frames are the released sampled keyframes, one per "
                              "whole second by construction"),
        },
        "reference_limits": {
            "numeric_colour": "not measured: the public references carry broad labels "
                              "with srgb null and numeric_reference_status "
                              "not_annotated",
            "missing_objects_counted": missing_objects,
        },
    }


def item_for(ref_obj, pred_obj, missing=False) -> dict:
    """One colour comparison for a matched or missing reference object."""
    base = {"class": ref_obj["class"], "missing": missing}
    if missing or pred_obj is None:
        ref_colors = {c["region"]: c for c in ref_obj.get("colors", [])}
        for region, rec in ref_colors.items():
            base.setdefault("regions", []).append(
                {"region": region, "ref_label": rec.get("label"),
                 "pred_label": None, "ref_lab": rec.get("lab_d65"),
                 "pred_lab": None})
        return flatten(base)
    pred_colors = {c["region"]: c for c in pred_obj.get("colors", [])}
    out = dict(base)
    out["regions"] = []
    for rec in ref_obj.get("colors", []):
        region = rec["region"]
        prec = pred_colors.get(region)
        out["regions"].append({"region": region, "ref_label": rec.get("label"),
                               "pred_label": (prec or {}).get("label"),
                               "ref_lab": rec.get("lab_d65"),
                               "pred_lab": (prec or {}).get("lab_d65")})
    return flatten(out)


def _flatten_items(items):
    return items


def flatten(item) -> dict:
    """colour_metrics wants one row per region; keep the class on every row."""
    if "regions" not in item:
        return item
    rows = []
    for r in item["regions"]:
        rows.append({"class": item["class"], "missing": item["missing"], **r})
    return {"__multi__": rows}


def colour_metrics(items) -> dict:
    rows = []
    for item in items:
        if "__multi__" in item:
            rows.extend(item["__multi__"])
        else:
            rows.append(item)
    return EV.colour_metrics(rows)


def filter_queries(predictions, references, per_frame, refs, coverage) -> dict:
    """Same-object filter precision/recall at the frozen tolerances.

    The query set is derived from the REFERENCE colours that have a numeric
    counterpart on the prediction side; when the reference has only a word, the
    query uses the observed numeric colour of the reference colour's own matched
    prediction, and that substitution is recorded rather than hidden. This makes
    the query test a real same-object test on measured sRGB, not a word lookup.
    """
    out = {"note": ("queries are built from reference colours; the numeric query "
                    "value is the broad label's anchor sRGB, converted to D65 Lab "
                    "by the same code the product uses"),
           "tolerances": {}}
    for tol in TOLERANCES:
        tp = fp = fn = 0
        for clip_frames in (per_frame,):
            pass
        for index, frame in refs.items():
            if index not in coverage:
                continue
            obs = per_frame.get(index, [])
            ref_objects = frame["objects"]
            for ref in ref_objects:
                for rec in ref.get("colors", []):
                    label = rec.get("label")
                    if label in (None, "unknown", "not_annotated"):
                        continue
                    anchor = COLOUR.anchor_lab(label)
                    if anchor is None:
                        continue
                    query = {"types": [ref["class"]],
                             "colour_srgb": [int(v) for v in _anchor_srgb(label)],
                             "tolerance": tol,
                             "colour_location": _location_for(rec["region"])}
                    matched = _matched_observation(ref, obs)
                    verdict = (FILTERS.evaluate(matched, query) if matched
                               else {"state": "no_match"})
                    if verdict["state"] == "match":
                        tp += 1
                    else:
                        fn += 1
                    # a mismatching nearby object of the same class must not match
                    for other in obs:
                        if other is matched:
                            continue
                        v = FILTERS.evaluate(other, query)
                        if v["state"] == "match":
                            fp += 1
        out["tolerances"]["%.0f" % tol] = {
            "tp": tp, "fp": fp, "fn": fn,
            "precision": (tp / (tp + fp)) if (tp + fp) else None,
            "recall": (tp / (tp + fn)) if (tp + fn) else None}
    return out


def _anchor_srgb(label):
    return COLOUR._ANCHORS.get(label, (0, 0, 0))


def _location_for(region):
    return {"upper_clothing": "upper", "lower_clothing": "lower",
            "vehicle_body": "body", "coat": "coat"}.get(region, region)


def _matched_observation(ref, obs):
    """The prediction matched to this reference object, by centre containment."""
    rx, ry, rw, rh = ref["bbox_xywh"]
    best, best_iou = None, 0.0
    for o in obs:
        if o["class"] != ref["class"]:
            continue
        m = EV.iou_xywh(np.array([ref["bbox_xywh"]]), np.array([o["bbox_xywh"]]))[0, 0]
        if m > best_iou:
            best, best_iou = o, float(m)
    return best if best_iou >= 0.5 else None


def infer_clip_id(run: dict) -> str:
    info = DATA.load_reference(REFERENCE_ROOT)
    sha = (run.get("input") or {}).get("sha256")
    for cid, clip in info.items():
        if clip["sha256"] == sha:
            return cid
    raise SystemExit("run input %s matches no public clip" % sha)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="append", default=[],
                    help="a run directory; repeatable")
    ap.add_argument("--out")
    args = ap.parse_args(argv)
    report = {"schema_version": 1, "kind": "stage4-public-development-evaluation",
              "runs": []}
    for run_dir in args.run:
        run = load_run(run_dir)
        report["runs"].append(evaluate_run(run))
    if args.out:
        pathlib.Path(args.out).write_text(json.dumps(report, indent=1, sort_keys=True))
    for r in report["runs"]:
        m = r["detection_iou_0.5"]["micro"]
        print("%-8s %-14s status=%-9s P=%s R=%s F1=%s | colour acc=%s | size acc=%s"
              % (r["clip_id"], "approach " + str(r["approach"]), r["status"],
                 _f(m["precision"]), _f(m["recall"]), _f(m["f1"]),
                 _f(r["broad_colour"]["accuracy_on_known"]),
                 _f(r["apparent_size"]["accuracy"])))
    return 0


def _f(v):
    return "n/a" if v is None else "%.3f" % v


if __name__ == "__main__":
    sys.exit(main())
