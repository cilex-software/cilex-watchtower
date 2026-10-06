"""Shared Stage 3 evidence validation, called by Watchtower's in-app evaluator.

validate_run(run, clip) -> list of structural errors; [] means valid evidence.
evidence_digest(run) -> SHA-256 of canonical JSON; required as review.run_sha256.
assess_targets(run, clip, review=None) -> {valid, errors, status, targets, summary}.
Target results contain class_observation_ids, qualifying_observation_ids (every
required colour on ONE observation), color_candidates, and status. Statuses are
review_required/not_detected/not_verified or accepted/rejected/unreviewable after
human review; the aggregate uses reviewed when every target has a human decision.
Summary counts those states, not accuracy. Filename annotations supply positive
targets, not exhaustive spatial ground truth: this module never computes accuracy.
Invalid evidence/reviews produce valid=False, status=invalid, and no target results.
"""

import hashlib
import json
import math
import re
from collections import Counter

CLASSES = {"person", "car", "dog", "bag", "scooter", "other"}
REGIONS = {"vehicle_body", "clothing", "upper_clothing", "lower_clothing"}
COLORS = {"black", "dark_gray", "white", "light_gray", "red", "blue", "brown",
          "pink", "green", "yellow", "orange", "unknown"}
DECISIONS = {"accepted", "rejected", "unreviewable"}


def _text(value):
    return isinstance(value, str) and bool(value.strip())


def _number(value, minimum=0, maximum=None):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value) and value >= minimum and (maximum is None or value <= maximum)
    except OverflowError:
        return False


def _hash(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{64}", value) is not None


def _one_of(value, allowed):
    return isinstance(value, str) and value in allowed


def evidence_digest(run):
    """Bind a review to all evidence, including config, model and predictions.

    Canonical bytes are UTF-8 of json.dumps(sort_keys=True, separators=(',', ':'),
    ensure_ascii=True, allow_nan=False). Invalid JSON raises rather than hashing.
    """
    canonical = json.dumps(run, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def validate_run(run, clip):
    """Validate schema v1 and bind predictions to the supplied clip's bytes."""
    errors = []

    def need(condition, message):
        if not condition:
            errors.append(message)

    if not isinstance(run, dict) or not isinstance(clip, dict):
        return ["run and clip must be objects"]
    try:
        json.dumps([run, clip], allow_nan=False, sort_keys=True)
    except (TypeError, ValueError, OverflowError, RecursionError):
        return ["run and clip must contain finite, serializable JSON values"]
    need(type(run.get("schema_version")) is int and run["schema_version"] == 1, "schema_version must be 1")
    for name in ("run_id", "clip_id", "source_revision"):
        need(_text(run.get(name)), name + " must be a nonempty string")
    need(_text(clip.get("clip_id")), "clip.clip_id must be a nonempty string")
    need(_hash(run.get("input_sha256")), "input_sha256 must be a SHA-256 hex digest")
    need(_hash(clip.get("sha256")), "clip.sha256 must be a SHA-256 hex digest")
    need(run.get("clip_id") == clip.get("clip_id"), "clip_id does not match clip")
    need(run.get("input_sha256") == clip.get("sha256"), "input_sha256 does not match clip")
    need(_one_of(run.get("status"), {"completed", "failed", "cancelled"}), "invalid run status")
    for name in ("analyser", "model", "config", "measurements"):
        need(isinstance(run.get(name), dict), name + " must be an object")
    analyser = run.get("analyser") if isinstance(run.get("analyser"), dict) else {}
    need(_text(analyser.get("id")) and _text(analyser.get("version")), "analyser requires id and version")
    model = run.get("model") if isinstance(run.get("model"), dict) else {}
    need(_text(model.get("name")), "model.name must be a nonempty string")
    need("weights_sha256" in model, "model.weights_sha256 is required")
    if model.get("weights_sha256") is None:
        need(_text(model.get("reason_no_weights")), "unweighted model requires reason_no_weights")
    else:
        need(_hash(model["weights_sha256"]), "model.weights_sha256 must be a SHA-256 hex digest")
    need(isinstance(run.get("errors"), list) and all(isinstance(e, str) for e in run["errors"]),
         "errors must be a list of strings")
    need(run.get("status") != "completed" or run.get("errors") == [], "completed run must have no errors")
    media = clip.get("media") if isinstance(clip.get("media"), dict) else {}
    duration = media.get("duration_ms")
    need(_number(duration) and duration > 0, "clip.media.duration_ms must be positive and finite")
    observations = run.get("observations")
    need(isinstance(observations, list), "observations must be a list")
    seen, frame_times = set(), {}
    for i, ob in enumerate(observations if isinstance(observations, list) else []):
        prefix = "observations[%d]: " % i
        if not isinstance(ob, dict):
            errors.append(prefix + "must be an object")
            continue
        oid = ob.get("id")
        need(_text(oid), prefix + "id must be a nonempty string")
        if _text(oid):
            need(oid not in seen, prefix + "duplicate id")
            seen.add(oid)
        need(_number(ob.get("frame_pts_ms"), maximum=duration if _number(duration) else None), prefix + "invalid frame_pts_ms")
        need(type(ob.get("frame_index")) is int and ob["frame_index"] >= 0, prefix + "invalid frame_index")
        if type(ob.get("frame_index")) is int and ob["frame_index"] >= 0 and _number(ob.get("frame_pts_ms")):
            index, pts = ob["frame_index"], ob["frame_pts_ms"]
            need(index not in frame_times or frame_times[index] == pts, prefix + "conflicting PTS for frame_index")
            frame_times[index] = pts
        need(_one_of(ob.get("class"), CLASSES), prefix + "invalid class")
        need(_number(ob.get("confidence"), maximum=1), prefix + "invalid confidence")
        box = ob.get("bbox_xywh")
        box_ok = isinstance(box, list) and len(box) == 4 and all(_number(n, maximum=1) for n in box)
        need(box_ok and box[2] > 0 and box[3] > 0 and box[0] + box[2] <= 1 and box[1] + box[3] <= 1,
             prefix + "bbox_xywh must be a positive normalized in-frame box")
        need("track_id" not in ob or _text(ob["track_id"]), prefix + "invalid track_id")
        colors = ob.get("colors")
        need(isinstance(colors, list), prefix + "colors must be a list")
        regions = set()
        for color in colors if isinstance(colors, list) else []:
            need(isinstance(color, dict) and _one_of(color.get("region"), REGIONS)
                 and _one_of(color.get("label"), COLORS) and _number(color.get("confidence"), maximum=1),
                 prefix + "invalid color")
            if isinstance(color, dict) and _one_of(color.get("region"), REGIONS):
                need(color["region"] not in regions, prefix + "only one color prediction per region is allowed")
                regions.add(color["region"])
    ordered_times = [frame_times[index] for index in sorted(frame_times)]
    need(all(a < b for a, b in zip(ordered_times, ordered_times[1:])), "PTS must increase across distinct frame indices")
    targets = clip.get("targets")
    need(isinstance(targets, list) and bool(targets), "clip.targets must be a nonempty list")
    seen = set()
    for target in targets if isinstance(targets, list) else []:
        if not isinstance(target, dict):
            errors.append("target must be an object")
            continue
        tid = target.get("target_id")
        need(_text(tid) and _text(target.get("subject_id")), "target requires target_id and subject_id")
        if _text(tid):
            need(tid not in seen, "duplicate target_id")
            seen.add(tid)
        need(_one_of(target.get("class"), CLASSES), "invalid target class")
        required = target.get("required_colors")
        need(isinstance(required, list), "target.required_colors must be a list")
        for color in required if isinstance(required, list) else []:
            labels = color.get("accepted_labels") if isinstance(color, dict) else None
            need(isinstance(color, dict) and _one_of(color.get("region"), REGIONS)
                 and isinstance(labels, list) and bool(labels)
                 and all(_one_of(label, COLORS - {"unknown"}) for label in labels), "invalid required color")
    return errors


def assess_targets(run, clip, review=None):
    """Find evidence candidates, never equating matching labels with correctness."""
    errors = validate_run(run, clip)
    invalid = lambda: {"valid": False, "errors": errors, "status": "invalid", "targets": [], "summary": {}}
    if errors:
        return invalid()
    rows = []
    for target in clip["targets"]:
        same_class = [ob for ob in run["observations"] if ob["class"] == target["class"]]
        colors = [{"region": c["region"], "accepted_labels": c["accepted_labels"], "observation_ids": [
            ob["id"] for ob in same_class if any(p["region"] == c["region"] and p["label"] in c["accepted_labels"]
                                                for p in ob["colors"])]} for c in target["required_colors"]]
        qualifying = [ob["id"] for ob in same_class if all(ob["id"] in c["observation_ids"] for c in colors)]
        rows.append({"target_id": target["target_id"], "subject_id": target["subject_id"],
                     "class_observation_ids": [ob["id"] for ob in same_class],
                     "qualifying_observation_ids": qualifying, "color_candidates": colors,
                     "status": "not_verified" if run["status"] != "completed" else
                               "review_required" if same_class else "not_detected"})
    if review is not None:
        if not isinstance(review, dict):
            errors.append("review must be an object")
            return invalid()
        if review.get("run_id") != run["run_id"] or review.get("input_sha256") != run["input_sha256"]:
            errors.append("review does not match run_id and input_sha256")
        if review.get("run_sha256") != evidence_digest(run):
            errors.append("review.run_sha256 does not match current evidence")
        if not _text(review.get("reviewer")):
            errors.append("reviewer must be a nonempty string")
        decisions = review.get("targets")
        if not isinstance(decisions, list):
            errors.append("review.targets must be a list")
            return invalid()
        by_target = {row["target_id"]: row for row in rows}
        obs_ids = {ob["id"] for ob in run["observations"]}
        seen, owners = set(), {}
        for decision in decisions:
            if not isinstance(decision, dict) or not _text(decision.get("target_id")):
                errors.append("invalid review target")
                continue
            tid, kind, ids = decision["target_id"], decision.get("decision"), decision.get("observation_ids")
            if tid not in by_target or tid in seen or not _one_of(kind, DECISIONS):
                errors.append("unknown, duplicate or invalid review target: " + tid)
                continue
            seen.add(tid)
            if (not isinstance(ids, list) or not all(_text(i) and i in obs_ids for i in ids)
                    or len(set(ids)) != len(ids) or not isinstance(decision.get("note"), str)
                    or (kind in {"rejected", "unreviewable"} and not _text(decision["note"]))):
                errors.append("invalid observation_ids or note for " + tid)
                continue
            row = by_target[tid]
            if kind == "accepted":
                if run["status"] != "completed" or not set(ids).intersection(row["qualifying_observation_ids"]):
                    errors.append("accepted target needs completed, same-observation class/color evidence: " + tid)
                for oid in ids:
                    if oid in owners and owners[oid] != row["subject_id"]:
                        errors.append("observation reused across distinct subjects: " + oid)
                    owners[oid] = row["subject_id"]
            row.update(status=kind if run["status"] == "completed" else "not_verified",
                       reviewed_observation_ids=ids, review_note=decision["note"])
        if errors:
            return invalid()
    counts = dict(Counter(row["status"] for row in rows))
    status = ("not_verified" if run["status"] != "completed" else "reviewed" if all(row["status"] in DECISIONS for row in rows)
              else "review_required" if any(row["status"] == "review_required" for row in rows) else "not_detected")
    return {"valid": True, "errors": [], "status": status, "targets": rows,
            "summary": {"target_count": len(rows), "status_counts": counts}}
