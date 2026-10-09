"""Corrected Stage 4 scoring: exact matching, class-scoped ignores, real coverage.

Three defects this module fixes, all named in the R2 prompt and each visible in the
R1 code:

1. **Matching.** R1 used augmenting paths for maximum cardinality and then a local
   swap heuristic for the IoU tie-break. A local optimum is not the global one, and
   the prompt forbids assuming it. Here cardinality comes from augmenting paths and
   the IoU tie-break is solved EXACTLY as a min-cost max-flow of exactly K units, so
   the result is the maximum total IoU among all maximum-cardinality matchings.
2. **Ignore regions.** R1's reference loader kept boxes and classes but dropped
   `ignore_regions` entirely, so ambiguous areas counted as false positives. Here a
   class-scoped ignore region swallows an UNMATCHED prediction of a listed class when
   at least half of the predicted area lies inside it (inclusive, per EVALUATION.md).
3. **Coverage.** R1 scored whatever frames it happened to have. Missing images,
   absent or duplicated prediction records and identity mismatches are now explicit
   evaluation failures, and successful zero-detection frames are counted coverage —
   not silently dropped and never converted into empty detections.

Metrics keep the raw counts first and declare every denominator. A class with
reference support but no predictions keeps its false negatives; a class with no
reference support reports recall as `not measured` instead of a perfect score.
"""
from __future__ import annotations

import math
from collections import deque

import numpy as np

CLASSES = ("human", "car", "animal")
SCALE = 10 ** 6          # IoU -> integer cost, so the flow stays exact


# ----------------------------------------------------------------------------------
# exact matching
# ----------------------------------------------------------------------------------
def iou_matrix(pred_boxes, ref_boxes) -> np.ndarray:
    a = np.asarray(pred_boxes, np.float64).reshape(-1, 4)
    b = np.asarray(ref_boxes, np.float64).reshape(-1, 4)
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


class _MinCostFlow:
    """Successive shortest paths with potentials (exact integer costs)."""

    def __init__(self, n):
        self.n = n
        self.graph = [[] for _ in range(n)]

    def add(self, u, v, cap, cost):
        self.graph[u].append([v, cap, cost, len(self.graph[v])])
        self.graph[v].append([u, 0, -cost, len(self.graph[u]) - 1])

    def flow(self, s, t, want):
        n = self.n
        total_flow = total_cost = 0
        while total_flow < want:
            dist = [math.inf] * n
            in_queue = [False] * n
            prev_v = [-1] * n
            prev_e = [-1] * n
            dist[s] = 0
            q = deque([s])
            in_queue[s] = True
            while q:
                u = q.popleft()
                in_queue[u] = False
                for i, (v, cap, cost, _rev) in enumerate(self.graph[u]):
                    if cap > 0 and dist[u] + cost < dist[v] - 1e-9:
                        dist[v] = dist[u] + cost
                        prev_v[v] = u
                        prev_e[v] = i
                        if not in_queue[v]:
                            q.append(v)
                            in_queue[v] = True
            if dist[t] == math.inf:
                break
            push = want - total_flow
            v = t
            while v != s:
                push = min(push, self.graph[prev_v[v]][prev_e[v]][1])
                v = prev_v[v]
            v = t
            while v != s:
                e = self.graph[prev_v[v]][prev_e[v]]
                e[1] -= push
                self.graph[v][e[3]][1] += push
                v = prev_v[v]
            total_flow += push
            total_cost += push * dist[t]
        return total_flow, total_cost


def max_cardinality_max_iou(iou: np.ndarray, threshold: float):
    """(pairs, total_iou, info) for the maximum-cardinality, max-total-IoU matching.

    `pairs` are (pred_index, ref_index) with iou >= threshold. Cardinality is
    maximal; among all matchings of that cardinality the total IoU is maximal,
    proved by the flow solution rather than by local swaps.
    """
    n_pred, n_ref = iou.shape
    allowed = [(i, j) for i in range(n_pred) for j in range(n_ref)
               if iou[i, j] >= threshold]
    if not allowed:
        return [], 0.0, {"cardinality": 0, "candidates": 0, "exact": True}

    # maximum cardinality by augmenting paths on the threshold graph
    adj = [[] for _ in range(n_pred)]
    for i, j in allowed:
        adj[i].append(j)

    def try_augment(p, seen, match_ref, match_pred):
        for r in adj[p]:
            if seen[r]:
                continue
            seen[r] = True
            if match_ref[r] == -1 or try_augment(match_ref[r], seen, match_ref, match_pred):
                match_ref[r] = p
                match_pred[p] = r
                return True
        return False

    match_ref = [-1] * n_ref
    match_pred = [-1] * n_pred
    cardinality = 0
    for p in range(n_pred):
        if try_augment(p, [False] * n_ref, match_ref, match_pred):
            cardinality += 1

    # exact tie-break for that cardinality: min-cost flow of exactly K units
    source, sink = 0, 1
    pred_base, ref_base = 2, 2 + n_pred
    mcf = _MinCostFlow(2 + n_pred + n_ref)
    for i in range(n_pred):
        mcf.add(source, pred_base + i, 1, 0)
    for j in range(n_ref):
        mcf.add(ref_base + j, sink, 1, 0)
    for i, j in allowed:
        cost = int(round((1.0 - float(iou[i, j])) * SCALE))
        mcf.add(pred_base + i, ref_base + j, 1, cost)
    pushed, cost = mcf.flow(source, sink, cardinality)
    pairs = []
    total = 0.0
    for i in range(n_pred):
        for edge in mcf.graph[pred_base + i]:
            v, cap, _c, _r = edge
            if ref_base <= v < ref_base + n_ref and cap == 0:
                j = v - ref_base
                if iou[i, j] >= threshold:
                    pairs.append((i, j))
                    total += float(iou[i, j])
    pairs.sort()
    exact = pushed == cardinality
    return pairs, total, {"cardinality": cardinality, "candidates": len(allowed),
                          "exact": exact, "flow": pushed}


# ----------------------------------------------------------------------------------
# ignore regions
# ----------------------------------------------------------------------------------
def ignored_by_region(box, ignore_regions, cls) -> str:
    """The first ignore region that swallows this UNMATCHED prediction, or "".

    Class-scoped: a region for `animal` must never hide a false `human`. The overlap
    test is inclusive at half of the PREDICTED area, so a small prediction inside a
    large ambiguous area is ignored while a large false box overlapping it slightly
    is not.
    """
    if not ignore_regions:
        return ""
    bx, by, bw, bh = (float(v) for v in box)
    area = bw * bh
    if area <= 0:
        return ""
    for index, region in enumerate(ignore_regions):
        classes = region.get("classes") or region.get("class_scope") or []
        if classes and cls not in classes:
            continue
        rbox = region.get("bbox_xywh") or region.get("box") or region.get("bbox")
        if not rbox or len(rbox) != 4:
            continue
        rx, ry, rw, rh = (float(v) for v in rbox)
        ix0, iy0 = max(bx, rx), max(by, ry)
        ix1, iy1 = min(bx + bw, rx + rw), min(by + bh, ry + rh)
        inter = max(0.0, ix1 - ix0) * max(0.0, iy1 - iy0)
        # Inclusive at exactly half, with a tolerance: 0.01/0.02 evaluates to
        # 0.4999999999999999 in binary floating point, so a strict >= 0.5 comparison
        # rejects a prediction that IS exactly half inside (found by this suite).
        if inter / area >= 0.5 - 1e-9:
            # The released regions carry no id, so one is derived from the position
            # and the stated reason, keeping the decision traceable to its source.
            return str(region.get("id") or region.get("instance_id")
                       or "ignore#%d:%s" % (index, str(region.get("reason", ""))[:40]))
    return ""


# ----------------------------------------------------------------------------------
# coverage
# ----------------------------------------------------------------------------------
def validate_coverage(requested_frames, prediction_records, references, images_present=None):
    """Explicit coverage: what was requested, what exists, and what is wrong.

    `requested_frames` is a list of {frame_index, frame_pts_ms}; `prediction_records`
    maps frame_index -> {"boxes", "scores", "classes"} (an EMPTY prediction list is a
    valid record: a successful zero-detection frame); `references` maps frame_index ->
    {"objects", "ignore_regions", "reviewed_classes"}.
    """
    problems = []
    seen = set()
    records = 0
    empty_ok = 0
    for fr in requested_frames:
        # The identity is the caller's key (clip + frame index). Using the bare frame
        # number collided across clips: 135 validation frames collapsed to 84 keys.
        idx = fr.get("key", fr["frame_index"])
        if idx in seen:
            problems.append("frame %s appears twice in the schedule" % idx)
            continue
        seen.add(idx)
        if idx not in prediction_records:
            problems.append("no prediction record for frame %s" % idx)
            continue
        records += 1
        record = prediction_records[idx]
        if record.get("frame_pts_ms") is not None and fr.get("frame_pts_ms") is not None \
                and abs(float(record["frame_pts_ms"]) - float(fr["frame_pts_ms"])) > 1.0:
            problems.append("frame %s prediction timestamp %.3f does not match the "
                            "schedule %.3f (tolerance 1 ms)"
                            % (idx, record["frame_pts_ms"], fr["frame_pts_ms"]))
        if idx not in references:
            problems.append("frame %s has a prediction record but no reference" % idx)
            continue
        if images_present is not None and not images_present.get(idx, True):
            problems.append("frame %s image is missing or unreadable" % idx)
        if not record.get("boxes"):
            empty_ok += 1
    return {"requested": len(requested_frames), "records": records,
            "empty_records": empty_ok, "complete": not problems,
            "problems": problems}


# ----------------------------------------------------------------------------------
# metrics
# ----------------------------------------------------------------------------------
def score(predictions, references, iou_threshold=0.5, classes=CLASSES,
          coverage=None):
    """Corrected scoring. Raw counts first, every denominator declared.

    `predictions`: frame_index -> {"boxes", "scores", "classes", "frame_pts_ms"}
    `references`:  frame_index -> {"objects": [...], "ignore_regions": [...]}
    Frames are scored in the order of `references`; `coverage` (from
    validate_coverage) is attached to the result and gates the "complete" claim.
    """
    per_class = {c: {"tp": 0, "fp": 0, "fn": 0, "ignored": 0, "iou_sum": 0.0,
                     "reference": 0, "predicted": 0, "frames_with_reference": 0}
                 for c in classes}
    matching_info = []
    for idx, ref in references.items():
        record = predictions.get(idx)
        if record is None:
            continue                      # coverage reports this; no silent zeros
        ref_boxes = np.array([o["bbox_xywh"] for o in ref.get("objects", [])],
                             np.float64).reshape(-1, 4)
        ref_classes = np.array([classes.index(o["class"]) for o in ref.get("objects", [])
                                if o["class"] in classes], np.int64)
        if len(ref_classes) != len(ref.get("objects", [])):
            ref_boxes = np.array([o["bbox_xywh"] for o in ref.get("objects", [])
                                  if o["class"] in classes],
                                 np.float64).reshape(-1, 4)
        pred_boxes = np.asarray(record.get("boxes", []), np.float64).reshape(-1, 4)
        pred_classes = np.asarray(record.get("classes", []), np.int64)
        ignores = ref.get("ignore_regions", [])
        for ci, cls in enumerate(classes):
            r_idx = np.where(ref_classes == ci)[0]
            p_idx = np.where(pred_classes == ci)[0]
            per_class[cls]["reference"] += len(r_idx)
            per_class[cls]["predicted"] += len(p_idx)
            if len(r_idx):
                per_class[cls]["frames_with_reference"] += 1
            if len(p_idx) and len(r_idx):
                m = iou_matrix(pred_boxes[p_idx], ref_boxes[r_idx])
                pairs, total, info = max_cardinality_max_iou(m, iou_threshold)
                info["frame_index"] = idx
                info["class"] = cls
                matching_info.append(info)
                per_class[cls]["tp"] += len(pairs)
                per_class[cls]["iou_sum"] += total
                matched_ref = {r for _p, r in pairs}
                per_class[cls]["fp"] += len(p_idx) - len(pairs)
                per_class[cls]["fn"] += len(r_idx) - len(pairs)
                matched_pred = {p for p, _r in pairs}
                for pi in range(len(p_idx)):
                    if pi in matched_pred:
                        continue
                    region = ignored_by_region(pred_boxes[p_idx[pi]], ignores, cls)
                    if region:
                        per_class[cls]["ignored"] += 1
                        per_class[cls]["fp"] -= 1
            elif len(r_idx):
                per_class[cls]["fn"] += len(r_idx)
                for pi in range(len(p_idx)):
                    if ignored_by_region(pred_boxes[p_idx[pi]], ignores, cls):
                        per_class[cls]["ignored"] += 1
            elif len(p_idx):
                for pi in range(len(p_idx)):
                    if ignored_by_region(pred_boxes[p_idx[pi]], ignores, cls):
                        per_class[cls]["ignored"] += 1
                    else:
                        per_class[cls]["fp"] += 1

    out = {}
    for cls, s in per_class.items():
        tp, fp, fn = s["tp"], s["fp"], s["fn"]
        support = s["reference"]
        prec = (tp / (tp + fp)) if (tp + fp) else None
        rec = (tp / support) if support else None
        f1 = (2 * prec * rec / (prec + rec)) if (prec is not None and rec is not None
                                                and (prec + rec) > 0) else (
            None if support == 0 else 0.0)
        out[cls] = {"tp": tp, "fp": fp, "fn": fn, "ignored": s["ignored"],
                    "reference": support, "predicted": s["predicted"],
                    "frames_with_reference": s["frames_with_reference"],
                    "precision": prec, "recall": rec, "f1": f1,
                    "mean_iou": (s["iou_sum"] / tp) if tp else None,
                    "recall_state": "measured" if support else "not measured",
                    "f1_state": "measured" if support else "not measured"}
    tp = sum(v["tp"] for v in out.values())
    fp = sum(v["fp"] for v in out.values())
    fn = sum(v["fn"] for v in out.values())
    ignored = sum(v["ignored"] for v in out.values())
    micro = {"tp": tp, "fp": fp, "fn": fn, "ignored": ignored,
             "precision": tp / (tp + fp) if (tp + fp) else None,
             "recall": tp / (tp + fn) if (tp + fn) else None}
    micro["f1"] = (2 * micro["precision"] * micro["recall"]
                   / (micro["precision"] + micro["recall"])
                   if micro["precision"] and micro["recall"] else None)
    measured = [v["f1"] for v in out.values() if v["f1"] is not None]
    supported = [k for k, v in out.items() if v["reference"]]
    macro = {"f1": (sum(measured) / len(measured)) if measured else None,
             "classes_measured": len(measured),
             "classes_supported": supported,
             "denominator_note": "macro averages the F1 of classes WITH reference "
                                 "support; classes without support are reported as "
                                 "not measured and excluded, never as a perfect score"}
    return {"iou_threshold": iou_threshold, "per_class": out, "micro": micro,
            "macro": macro, "matching": matching_info, "coverage": coverage}
