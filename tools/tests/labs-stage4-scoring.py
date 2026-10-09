#!/usr/bin/env python3
"""Scoring checks: exact matching, ignore regions, coverage, denominators.

The matcher is compared against BRUTE FORCE (every matching of maximum cardinality,
enumerated) on small cases, which is what the R2 prompt asks for: a local swap
heuristic is not evidence of a global optimum. Where the old R1 heuristic and the
exact solver disagree, the test reports it instead of asserting a difference that
may not exist.
"""
from __future__ import annotations

import itertools
import pathlib
import sys

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "labs"))

import stage4_scoring as S      # noqa: E402
import stage4_evaluate as OLD   # noqa: E402

PASS, FAIL = [], []


def check(name, condition, detail=""):
    (PASS if condition else FAIL).append(name)
    print("%-5s %s%s" % ("PASS" if condition else "FAIL", name,
                         ("  [%s]" % detail) if detail and not condition else ""))


def brute_force_best(iou, threshold):
    """Every matching (not just maximum cardinality) by enumeration; returns the
    best (cardinality, total_iou) with cardinality taking precedence."""
    n_pred, n_ref = iou.shape
    best = (0, 0.0)
    refs = range(n_ref)
    for size in range(0, min(n_pred, n_ref) + 1):
        for preds in itertools.combinations(range(n_pred), size):
            for perm in itertools.permutations(refs, size):
                pairs = list(zip(preds, perm))
                if any(iou[i, j] < threshold for i, j in pairs):
                    continue
                total = sum(float(iou[i, j]) for i, j in pairs)
                if size > best[0] or (size == best[0] and total > best[1] + 1e-12):
                    best = (size, total)
    return best


def main() -> int:
    rng = np.random.default_rng(7)

    # ---------------------------------------------------------------- exactness
    cases = 0
    mismatches = []
    for trial in range(120):
        n_p = int(rng.integers(1, 6))
        n_r = int(rng.integers(1, 6))
        m = rng.random((n_p, n_r))
        m = np.where(m > 0.45, rng.uniform(0.5, 1.0, m.shape), m)
        threshold = 0.5
        pairs, total, info = S.max_cardinality_max_iou(m, threshold)
        want_k, want_total = brute_force_best(m, threshold)
        cases += 1
        if len(pairs) != want_k or abs(total - want_total) > 1e-9:
            mismatches.append((n_p, n_r, len(pairs), want_k, round(total, 6),
                               round(want_total, 6)))
    check("exact matching equals brute force on %d small cases" % cases, not mismatches,
          str(mismatches[:3]))

    # does the OLD heuristic ever differ? report honestly either way
    old_worse = 0
    cardinality_differs = 0
    checked = 0
    for trial in range(400):
        n_p = int(rng.integers(2, 6))
        n_r = int(rng.integers(2, 6))
        m = rng.random((n_p, n_r))
        m = np.where(m > 0.5, rng.uniform(0.5, 1.0, m.shape), m)
        pairs_new, total_new, _ = S.max_cardinality_max_iou(m, 0.5)
        pairs_old, k_old = OLD.match_max_cardinality(m, 0.5)
        total_old = sum(float(m[i, j]) for i, j in pairs_old)
        checked += 1
        if len(pairs_old) != len(pairs_new):
            cardinality_differs += 1
        if total_old < total_new - 1e-9:
            old_worse += 1
    check("the R1 local-swap heuristic never matched a HIGHER total IoU than the exact "
          "solver (%d of %d cases differ, %d in cardinality)"
          % (old_worse, checked, cardinality_differs),
          cardinality_differs == 0 and old_worse > 0,
          "cardinality must agree; the total IoU must differ somewhere, otherwise the "
          "correction would be cosmetic")

    # a hand-built case where greedy-order alone would be wrong: the exact solver
    # must prefer the globally better assignment of two equal-IoU candidates
    m = np.array([[0.90, 0.80], [0.85, 0.10]])
    pairs, total, _ = S.max_cardinality_max_iou(m, 0.5)
    check("the tie-break picks the global optimum, not the first greedy pair",
          sorted(pairs) == [(0, 1), (1, 0)] and abs(total - 1.65) < 1e-9,
          "%s total=%.3f" % (pairs, total))

    # ------------------------------------------------------------ ignore regions
    ignores = [{"id": "ig1", "classes": ["animal"], "bbox_xywh": [0.4, 0.4, 0.2, 0.2]}]
    swallowed = S.ignored_by_region([0.42, 0.42, 0.05, 0.05], ignores, "animal")
    not_swallowed_class = S.ignored_by_region([0.42, 0.42, 0.05, 0.05], ignores, "human")
    check("a class-scoped ignore region swallows its own class", swallowed == "ig1")
    check("an animal ignore region does NOT swallow a false human",
          not_swallowed_class == "")
    exactly_half = S.ignored_by_region([0.30, 0.40, 0.20, 0.10], ignores, "animal")
    check("the half-area overlap threshold is inclusive", exactly_half == "ig1",
          "prediction half inside must be ignored")
    less_than_half = S.ignored_by_region([0.28, 0.40, 0.20, 0.10], ignores, "animal")
    check("a prediction less than half inside is NOT ignored", less_than_half == "")

    # ------------------------------------------------------------ ignore in score
    refs = {0: {"objects": [{"class": "human", "bbox_xywh": [0.05, 0.05, 0.1, 0.1]}],
                "ignore_regions": ignores},
            }
    preds = {0: {"boxes": [[0.05, 0.05, 0.1, 0.1], [0.42, 0.42, 0.05, 0.05]],
                 "scores": [0.9, 0.8], "classes": [0, 2], "frame_pts_ms": 0.0}}
    scored = S.score(preds, refs, 0.5)
    check("an unmatched prediction inside a class-scoped ignore region is counted as "
          "ignored, not as a false positive",
          scored["per_class"]["animal"]["ignored"] == 1
          and scored["per_class"]["animal"]["fp"] == 0,
          str(scored["per_class"]["animal"]))
    check("ignored predictions still appear in the raw counts",
          scored["micro"]["ignored"] == 1 and scored["per_class"]["human"]["tp"] == 1)

    # ------------------------------------------------------------------ coverage
    requested = [{"frame_index": 0, "frame_pts_ms": 0.0},
                 {"frame_index": 1, "frame_pts_ms": 1000.0},
                 {"frame_index": 2, "frame_pts_ms": 2000.0}]
    records = {0: {"boxes": [[0.1, 0.1, 0.1, 0.1]], "classes": [0], "frame_pts_ms": 0.0},
               1: {"boxes": [], "classes": [], "frame_pts_ms": 1000.0}}   # zero-detection
    references = {0: {"objects": [], "ignore_regions": []},
                  1: {"objects": [], "ignore_regions": []}}
    cov = S.validate_coverage(requested, records, references)
    check("a zero-detection frame is valid coverage", cov["empty_records"] == 1
          and cov["records"] == 2)
    check("a missing prediction record is reported as incomplete coverage",
          not cov["complete"] and any("no prediction record for frame 2" in p
                                      for p in cov["problems"]), str(cov["problems"]))
    dup = S.validate_coverage([{"frame_index": 0, "frame_pts_ms": 0.0},
                               {"frame_index": 0, "frame_pts_ms": 0.0}], records,
                              references)
    check("a duplicated frame is reported, not silently scored twice",
          any("appears twice" in p for p in dup["problems"]))
    drift = S.validate_coverage([{"frame_index": 0, "frame_pts_ms": 999.0}], records,
                                references)
    check("a prediction timestamp that disagrees with the schedule is an error",
          any("does not match the schedule" in p for p in drift["problems"]))
    missing_img = S.validate_coverage([{"frame_index": 0, "frame_pts_ms": 0.0}],
                                      records, references,
                                      images_present={0: False})
    check("a missing image is an error, not an empty detection",
          any("missing or unreadable" in p for p in missing_img["problems"]))

    # -------------------------------------------------------------- denominators
    refs2 = {0: {"objects": [{"class": "animal", "bbox_xywh": [0.5, 0.5, 0.2, 0.2]}],
                 "ignore_regions": []}}
    preds2 = {0: {"boxes": [], "classes": [], "scores": [], "frame_pts_ms": 0.0}}
    s2 = S.score(preds2, refs2, 0.5)
    check("a supported class with NO predictions keeps its false negatives",
          s2["per_class"]["animal"]["fn"] == 1 and s2["per_class"]["animal"]["recall"] == 0.0,
          str(s2["per_class"]["animal"]))
    check("a class with no reference support reports 'not measured', not 1.0",
          s2["per_class"]["car"]["recall_state"] == "not measured"
          and s2["per_class"]["car"]["f1_state"] == "not measured")
    check("macro F1 declares its denominator (supported classes only)",
          s2["macro"]["classes_supported"] == ["animal"]
          and s2["macro"]["denominator_note"].startswith("macro averages"))

    print("\n%d PASS, %d FAIL" % (len(PASS), len(FAIL)))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
