#!/usr/bin/env python3
"""Hermetic checks for the evaluator imported by Watchtower's Stage 3 panel."""
import copy
import importlib.util
from pathlib import Path
import sys
import unittest

spec = importlib.util.spec_from_file_location("stage3_evidence", Path(__file__).parents[1] / "labs/stage3_evidence.py")
E = importlib.util.module_from_spec(spec)
spec.loader.exec_module(E)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.clip = {"clip_id": "clip-01", "sha256": "a" * 64, "media": {"duration_ms": 1000}, "targets": [
            {"target_id": "t1", "subject_id": "p1", "class": "person", "required_colors": [
                {"region": "clothing", "accepted_labels": ["red"]}]}]}
        self.run = {"schema_version": 1, "run_id": "r1", "clip_id": "clip-01", "input_sha256": "a" * 64,
                    "status": "completed", "source_revision": "test", "analyser": {"id": "fixture", "version": "1"},
                    "model": {"name": "fixture", "weights_sha256": None, "reason_no_weights": "test predictions"},
                    "config": {}, "errors": [], "measurements": {}, "observations": [
                        {"id": "o1", "frame_pts_ms": 500, "frame_index": 5, "class": "person", "confidence": .9,
                         "bbox_xywh": [.1, .1, .2, .4], "colors": [{"region": "clothing", "label": "red", "confidence": .8}]}]}

    def review(self, decision="accepted", ids=None):
        return {"run_id": "r1", "input_sha256": "a" * 64, "run_sha256": E.evidence_digest(self.run),
                "reviewer": "operator", "targets": [
            {"target_id": "t1", "decision": decision, "observation_ids": ids if ids is not None else ["o1"], "note": "viewed"}]}

    def test_candidates_are_not_accuracy(self):
        result = E.assess_targets(self.run, self.clip)
        self.assertTrue(result["valid"])
        self.assertEqual(result["status"], "review_required")
        self.assertEqual(result["targets"][0]["qualifying_observation_ids"], ["o1"])
        self.assertEqual(set(result["summary"]), {"target_count", "status_counts"})
        self.assertEqual(E.assess_targets(self.run, self.clip, self.review())["status"], "reviewed")

    def test_malformed_observations(self):
        for key, values in {"frame_pts_ms": [True, -1, 1001, float("nan"), float("inf")],
                            "frame_index": [True, -1, .5], "confidence": [False, -.1, 1.1, float("nan")],
                            "bbox_xywh": [[0, 0, 0, 1], [.9, 0, .2, 1], [0, 0, 1, float("inf")], [0, 0, True, 1]],
                            "class": ["human", []], "colors": [None, [{"region": "clothing", "label": "red", "confidence": True}]]}.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    run = copy.deepcopy(self.run)
                    run["observations"][0][key] = value
                    self.assertTrue(E.validate_run(run, self.clip))

    def test_bad_identity_schema_and_duplicates(self):
        for key, value in [("input_sha256", "b" * 64), ("clip_id", "other"), ("schema_version", True),
                           ("errors", ["execution failed"]), ("config", {"threshold": float("nan")})]:
            run = copy.deepcopy(self.run)
            run[key] = value
            self.assertFalse(E.assess_targets(run, self.clip)["valid"])
        self.run["observations"] *= 2
        self.assertTrue(E.validate_run(self.run, self.clip))

    def test_nonserializable_evidence_stops_validation(self):
        cyclic = {}
        cyclic["self"] = cyclic
        nested = []
        # CPython's C JSON encoder can exceed the Python recursion limit.
        for _ in range(max(10000, sys.getrecursionlimit() * 10)):
            nested = [nested]
        for value in (cyclic, nested):
            self.run["config"] = {"value": value}
            self.assertEqual(len(E.validate_run(self.run, self.clip)), 1)
            self.assertEqual(E.assess_targets(self.run, self.clip)["status"], "invalid")

    def test_frame_time_consistency(self):
        second = copy.deepcopy(self.run["observations"][0])
        second["id"] = "o2"
        self.run["observations"].append(second)
        self.assertEqual(E.validate_run(self.run, self.clip), [])  # two objects in one frame
        second["frame_pts_ms"] = 501
        self.assertTrue(E.validate_run(self.run, self.clip))
        second["frame_index"] = 6
        self.assertEqual(E.validate_run(self.run, self.clip), [])
        for pts in (499, 500):
            second["frame_pts_ms"] = pts
            self.assertTrue(E.validate_run(self.run, self.clip))
        second["frame_pts_ms"] = 501
        self.run["observations"].reverse()
        self.assertEqual(E.validate_run(self.run, self.clip), [])  # list ordering is immaterial

    def test_one_color_per_region(self):
        colors = self.run["observations"][0]["colors"]
        colors.append({"region": "clothing", "label": "blue", "confidence": .9})
        self.assertTrue(E.validate_run(self.run, self.clip))
        colors[-1]["region"] = "lower_clothing"
        self.assertEqual(E.validate_run(self.run, self.clip), [])

    def test_color_cannot_come_from_another_object(self):
        second = copy.deepcopy(self.run["observations"][0])
        second.update(id="o2", **{"class": "bag"})
        self.run["observations"][0]["colors"] = []
        self.run["observations"].append(second)
        result = E.assess_targets(self.run, self.clip)
        self.assertEqual(result["targets"][0]["qualifying_observation_ids"], [])
        self.assertFalse(E.assess_targets(self.run, self.clip, self.review(ids=["o1", "o2"]))["valid"])

    def test_colors_must_cooccur_on_one_observation(self):
        self.clip["targets"][0]["required_colors"].append({"region": "lower_clothing", "accepted_labels": ["black"]})
        second = copy.deepcopy(self.run["observations"][0])
        second.update(id="o2", colors=[{"region": "lower_clothing", "label": "black", "confidence": .9}])
        self.run["observations"].append(second)
        self.assertEqual(E.assess_targets(self.run, self.clip)["targets"][0]["qualifying_observation_ids"], [])

    def test_unknown_is_abstention(self):
        self.run["observations"][0]["colors"][0]["label"] = "unknown"
        self.assertEqual(E.validate_run(self.run, self.clip), [])
        self.assertEqual(E.assess_targets(self.run, self.clip)["targets"][0]["qualifying_observation_ids"], [])
        self.assertFalse(E.assess_targets(self.run, self.clip, self.review())["valid"])

    def test_review_binding_and_subject_uniqueness(self):
        for key, value in [("run_id", "stale"), ("input_sha256", "b" * 64), ("run_sha256", "b" * 64), ("reviewer", " ")]:
            review = self.review()
            review[key] = value
            self.assertFalse(E.assess_targets(self.run, self.clip, review)["valid"])
        target = copy.deepcopy(self.clip["targets"][0])
        target.update(target_id="t2", subject_id="p2")
        self.clip["targets"].append(target)
        review = self.review()
        review["targets"].append({**review["targets"][0], "target_id": "t2"})
        self.assertFalse(E.assess_targets(self.run, self.clip, review)["valid"])

    def test_evidence_digest_rejects_reused_run_id(self):
        review = self.review()
        reordered = dict(reversed(list(self.run.items())))
        self.assertEqual(E.evidence_digest(reordered), review["run_sha256"])
        for field, value in (("config", {"threshold": .7}), ("model", {**self.run["model"], "name": "different"}),
                             ("observations", [{**self.run["observations"][0], "confidence": .8}])):
            changed = copy.deepcopy(self.run)
            changed[field] = value
            self.assertFalse(E.assess_targets(changed, self.clip, review)["valid"])
        self.assertTrue(E.assess_targets(self.run, self.clip, review)["valid"])

    def test_negative_review_needs_reason(self):
        for decision in ("rejected", "unreviewable"):
            review = self.review(decision)
            review["targets"][0]["note"] = "  "
            self.assertFalse(E.assess_targets(self.run, self.clip, review)["valid"])
            review["targets"][0]["note"] = "subject obscured"
            self.assertTrue(E.assess_targets(self.run, self.clip, review)["valid"])

    def test_empty_and_incomplete_runs(self):
        observations = self.run["observations"]
        self.run["observations"] = []
        self.assertEqual(E.assess_targets(self.run, self.clip)["status"], "not_detected")
        for status in ("failed", "cancelled"):
            self.run["status"] = status
            self.run["observations"] = observations
            result = E.assess_targets(self.run, self.clip)
            self.assertEqual(result["status"], "not_verified")
            self.assertEqual(result["targets"][0]["status"], "not_verified")
            self.assertFalse(E.assess_targets(self.run, self.clip, self.review())["valid"])
        self.assertEqual(E.assess_targets(self.run, self.clip, self.review("unreviewable", []))["status"], "not_verified")


if __name__ == "__main__":
    unittest.main(verbosity=2)
