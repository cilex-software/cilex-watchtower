"""Stage 4 evaluation: matching, detection metrics, size/colour scores.

The matching rule is the one EVALUATION.md declares: same-class, one-to-one,
maximum cardinality first and maximum total IoU second, at IoU 0.5 primary with
0.3 reported as a sensitivity result. Reported numbers are per class plus micro
and macro precision/recall/F1, with the raw TP/FP/FN they come from; a class with
no reference positives reports recall as `not measured`, never as 100%.

Colour scoring keeps the contract's distinctions: broad-label correctness on
matched objects, unknown/wrong/missing counts, and the numeric CIEDE2000 query
accuracy at the frozen tolerances. Nothing here fabricates a numeric reference
from a colour word: where the released reference has no reviewed numeric colour,
the numeric score is `not measured`.
"""
from __future__ import annotations

import math

import numpy as np

CLASSES = ("human", "car", "animal")
SIZE_LABELS = ("small", "medium", "big")


def iou_xywh(a, b) -> np.ndarray:
    a = np.asarray(a, np.float64).reshape(-1, 4)
    b = np.asarray(b, np.float64).reshape(-1, 4)
    if a.size == 0 or b.size == 0:
        return np.zeros((a.shape[0], b.shape[0]), np.float64)
    ax0, ay0 = a[:, 0][:, None], a[:, 1][:, None]
    ax1, ay1 = (a[:, 0] + a[:, 2])[:, None], (a[:, 1] + a[:, 3])[:, None]
    bx0, by0 = b[:, 0][None, :], b[:, 1][None, :]
    bx1, by1 = (b[:, 0] + b[:, 2])[None, :], (b[:, 1] + b[:, 3])[None, :]
    inter = np.maximum(0, np.minimum(ax1, bx1) - np.maximum(ax0, bx0)) * \
        np.maximum(0, np.minimum(ay1, by1) - np.maximum(ay0, by0))
    union = (a[:, 2] * a[:, 3])[:, None] + (b[:, 2] * b[:, 3])[None, :] - inter
    return inter / np.maximum(1e-12, union)


def _augment_path(adj, match_ref, match_pred, seen, p):
    for r in range(len(adj[p])):
        q = int(adj[p][r])
        if seen[q]:
            continue
        seen[q] = True
        if match_ref[q] == -1 or _augment_path(adj, match_ref, match_pred, seen,
                                               match_ref[q]):
            match_ref[q] = p
            match_pred[p] = q
            return True
    return False


def match_max_cardinality(iou: np.ndarray, threshold: float):
    """(pairs, cardinality) with maximum cardinality, then maximum total IoU.

    Cardinality comes from augmenting paths on the threshold graph; the IoU pass
    then improves the total among the largest matchings (a swap search), so the
    reported mean IoU does not depend on the order boxes happen to arrive in.
    TP/FP/FN depend only on the cardinality, which is invariant.
    """
    n_p, n_r = iou.shape
    adj = [[j for j in range(n_r) if iou[i, j] >= threshold] for i in range(n_p)]
    match_ref = [-1] * n_r
    match_pred = [-1] * n_p
    for p in range(n_p):
        _augment_path(adj, match_ref, match_pred, [False] * n_r, p)
    pairs = [(p, match_pred[p]) for p in range(n_p) if match_pred[p] != -1]
    improved = True
    while improved and len(pairs) > 1:
        improved = False
        for i in range(len(pairs)):
            for j in range(i + 1, len(pairs)):
                a, b = pairs[i], pairs[j]
                cur = iou[a[0], a[1]] + iou[b[0], b[1]]
                alt = iou[a[0], b[1]] + iou[b[0], a[1]]
                if alt > cur + 1e-12 and iou[a[0], b[1]] >= threshold \
                        and iou[b[0], a[1]] >= threshold:
                    pairs[i], pairs[j] = (a[0], b[1]), (b[0], a[1])
                    improved = True
    return pairs, len(pairs)


def score_predictions(predictions: dict, references: dict, iou_threshold: float = 0.5,
                      classes=CLASSES, conf_threshold: float = None) -> dict:
    """Per-class and micro/macro precision, recall and F1 with raw counts."""
    per_class = {c: {"tp": 0, "fp": 0, "fn": 0, "iou_sum": 0.0, "ref": 0, "pred": 0}
                 for c in classes}
    for key, (ref_boxes, ref_classes) in references.items():
        pred_boxes, pred_scores, pred_classes = predictions.get(
            key, (np.zeros((0, 4)), np.zeros(0), np.zeros(0, int)))
        if conf_threshold is not None and len(pred_scores):
            keep = pred_scores >= conf_threshold
            pred_boxes, pred_classes = pred_boxes[keep], pred_classes[keep]
        for c in classes:
            r_idx = np.where(np.asarray(ref_classes) == classes.index(c))[0]
            p_idx = np.where(np.asarray(pred_classes) == classes.index(c))[0]
            per_class[c]["ref"] += len(r_idx)
            per_class[c]["pred"] += len(p_idx)
            if len(r_idx) == 0:
                per_class[c]["fp"] += len(p_idx)
                continue
            if len(p_idx) == 0:
                per_class[c]["fn"] += len(r_idx)
                continue
            m = iou_xywh(np.asarray(pred_boxes)[p_idx], np.asarray(ref_boxes)[r_idx])
            pairs, k = match_max_cardinality(m, iou_threshold)
            per_class[c]["tp"] += k
            per_class[c]["fp"] += len(p_idx) - k
            per_class[c]["fn"] += len(r_idx) - k
            per_class[c]["iou_sum"] += float(sum(m[p, r] for p, r in pairs))
    out = {}
    for c, s in per_class.items():
        tp, fp, fn = s["tp"], s["fp"], s["fn"]
        prec = tp / (tp + fp) if (tp + fp) else None
        rec = tp / (tp + fn) if (tp + fn) else None
        f1 = (2 * prec * rec / (prec + rec)) if (prec and rec) else (0.0 if prec == 0 or rec == 0 else None)
        out[c] = {"tp": tp, "fp": fp, "fn": fn, "reference": s["ref"],
                  "predicted": s["pred"], "precision": prec, "recall": rec, "f1": f1,
                  "mean_iou": (s["iou_sum"] / tp) if tp else None,
                  "recall_state": "measured" if (tp + fn) else "not measured"}
    tp = sum(v["tp"] for v in out.values())
    fp = sum(v["fp"] for v in out.values())
    fn = sum(v["fn"] for v in out.values())
    micro = {"tp": tp, "fp": fp, "fn": fn,
             "precision": tp / (tp + fp) if (tp + fp) else None,
             "recall": tp / (tp + fn) if (tp + fn) else None}
    micro["f1"] = (2 * micro["precision"] * micro["recall"]
                   / (micro["precision"] + micro["recall"])
                   if micro["precision"] and micro["recall"] else 0.0)
    measured = [v for v in out.values() if v["f1"] is not None]
    macro = {"f1": float(np.mean([v["f1"] for v in measured])) if measured else None,
             "classes_measured": len(measured)}
    return {"iou_threshold": iou_threshold, "per_class": out, "micro": micro,
            "macro": macro}


def size_label(area_fraction: float) -> str:
    """The V1 apparent-size policy, exactly as FILTERS_V1.md states it."""
    if area_fraction <= 0:
        return "unknown"
    if area_fraction < 0.01:
        return "small"
    if area_fraction < 0.10:
        return "medium"
    return "big"


def size_confusion(matched_pairs) -> dict:
    """matched_pairs: iterable of (reference_size_label, predicted_size_label)."""
    table = {r: {p: 0 for p in SIZE_LABELS} for r in SIZE_LABELS}
    correct = 0
    total = 0
    for ref, pred in matched_pairs:
        if ref not in table or pred not in table[ref]:
            continue
        table[ref][pred] += 1
        total += 1
        correct += int(ref == pred)
    return {"confusion": table, "matched": total,
            "correct": correct,
            "accuracy": (correct / total) if total else None,
            "state": "measured" if total else "not measured"}


def colour_metrics(matched) -> dict:
    """Broad-colour correctness on matched objects, with the right denominators.

    `matched` items: {class, region, ref_label, pred_label, ref_lab, pred_lab}.
    Unknown reference colours are excluded from the correctness denominator but
    counted; a missed object whose colour is known stays in the joint denominator
    (the caller adds those as missing=True items).
    """
    known_ref = unknown_ref = wrong = correct = missing = 0
    numeric_pairs = []
    for m in matched:
        if m.get("missing"):
            missing += 1
            known_ref += 1
            continue
        ref, pred = m.get("ref_label"), m.get("pred_label")
        if ref in (None, "unknown", "not_annotated"):
            unknown_ref += 1
            continue
        known_ref += 1
        if pred == ref:
            correct += 1
        elif pred in (None, "unknown"):
            pass
        else:
            wrong += 1
        if m.get("ref_lab") and m.get("pred_lab"):
            numeric_pairs.append((m["ref_lab"], m["pred_lab"]))
    d = [float(np.linalg.norm(np.asarray(a) - np.asarray(b))) for a, b in numeric_pairs]
    return {"known_reference": known_ref, "unknown_reference": unknown_ref,
            "correct": correct, "wrong": wrong, "abstained_unknown": known_ref - correct - wrong,
            "missing_object": missing,
            "accuracy_on_known": (correct / known_ref) if known_ref else None,
            "coverage": (correct / (correct + wrong)) if (correct + wrong) else None,
            "numeric_pairs": len(numeric_pairs),
            "lab_delta_e_mean": (float(np.mean(d)) if d else None),
            "numeric_state": "measured" if numeric_pairs else "not measured"}
