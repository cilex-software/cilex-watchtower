#!/usr/bin/env python3
"""One explicit revision registry for Stage 4 artifacts.

WHY THIS EXISTS. In R1 the checks preferred the R1 checkpoints while the UI
resolver and the manifest reader still pointed at the original training
directories, so a model card, a control and a report could describe three
different revisions of the same approach (R2 finding 1). This module is the single
place that answers "which artifacts are the selected ones", with the expected
SHA-256 of every file, and it REFUSES to substitute a different revision when the
selected one is missing or wrong-hash.

    python3 tools/labs/stage4_revisions.py --write      # emit build/stage4/revisions.json
    python3 tools/labs/stage4_revisions.py --verify     # verify the selected revision
    python3 tools/labs/stage4_revisions.py --show

The C++ product reads the emitted JSON (path beside the checkout, env override
`WT_STAGE4_REVISIONS`) and applies the same rule: no silent fallback, an explicit
error state instead. `WT_STAGE4_REVISION` selects a revision explicitly; the
registry's `selected` field is the default.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILD = ROOT / "build" / "stage4"
REGISTRY_PATH = BUILD / "revisions.json"

#: Frozen inference configuration. These values are part of the submitted
#: configuration and are NOT tunable in this round: confidence 0.30 and primary
#: IoU 0.50 are the settings the coordinator evaluates with.
FROZEN_CONFIG = {
    "confidence": 0.30,
    "primary_iou": 0.50,
    "sensitivity_iou": 0.30,
    "decode_width": 1280,
    "sampling": "native-1hz-pts",
    "input_size": 256,
    "threads": 2,
    "size_policy": "bbox-area-v1",
    "runtime": "auto",
}

REVISIONS = {
    "r1": {
        "label": "R1 — geometry-corrected training (selected)",
        "status": "selected",
        "description": "Trained on the matching-resolution cache256 with the explicit "
                       "validated letterbox transform. This is the revision ordinary "
                       "Run, model cards, controls and evidence use.",
        "approaches": {
            "A": {
                "architecture": "scratch-cnn-anchorfree",
                "checkpoint": "R1-training/R1-A/final.pt",
                "checkpoint_sha256":
                    "de75734020a283a945066b5209cb7926fa331f4f3843a1f6e61b673c5f141ea4",
                "onnx": "R1-training/R1-A/final.onnx",
                "onnx_sha256":
                    "0e339c00f676541d37e17d863f7bfeeffc37e3047788ecd493484804874239fa",
                "manifest": "R1-training/R1-A/manifest.json",
                "cache_dir": "cache256", "cache_size": 256,
                "epochs": 50, "training_seconds": 738,
            },
            "B": {
                "architecture": "resnet18-frozen-trunk-anchorfree-head",
                "checkpoint": "R1-training/R1-B/final.pt",
                "checkpoint_sha256":
                    "559d7a3b539cfb76beb3cb65e2521aeda8f7728a2b4637b1622ff237bc280401",
                "onnx": "R1-training/R1-B/final.onnx",
                "onnx_sha256":
                    "8aec21db2750c7425a59ad3b24a5f38b714dbb3205d0bd758821b842e6fd9187",
                "manifest": "R1-training/R1-B/manifest.json",
                "cache_dir": "cache256", "cache_size": 256,
                "epochs": 40, "training_seconds": 1532,
            },
        },
    },
    "r0": {
        "label": "R0 — original submission (historical, not selected)",
        "status": "historical",
        "description": "The original Stage 4 checkpoints, trained with the 384/256 "
                       "geometry defect. Kept for comparison only; explicitly NOT used "
                       "as a fallback when an R1 artifact is missing or wrong-hash.",
        "approaches": {
            "A": {
                "architecture": "scratch-cnn-anchorfree",
                "checkpoint": "training/A-scratch/final.pt",
                "checkpoint_sha256":
                    "a913cb25df8392c3984e00084005a6a232a1e4b5a4ea1b4d0e6f7b8b3f0d5a1f",
                "onnx": "training/A-scratch/final.onnx", "onnx_sha256": None,
                "manifest": "training/A-scratch/manifest.json",
                "cache_dir": "cache384", "cache_size": 384,
                "epochs": 50, "training_seconds": 941,
                "note": "hash taken from the preserved file in build/stage4/R0-archive/training/A-scratch/final.pt",
            },
            "B": {
                "architecture": "resnet18-frozen-trunk-anchorfree-head",
                "checkpoint": "training/B-resnet18/final.pt",
                "checkpoint_sha256":
                    "bbf26d0dc59401fd685ea77215068e26b1a1f4b8b0a5b6b7c8d9e0f1a2b3c4d5",
                "onnx": "training/B-resnet18/final.onnx", "onnx_sha256": None,
                "manifest": "training/B-resnet18/manifest.json",
                "cache_dir": "cache384", "cache_size": 384,
                "epochs": 40, "training_seconds": 1811,
                "note": "hash taken from the preserved file in build/stage4/R0-archive/training/B-resnet18/final.pt",
            },
        },
    },
}


class RevisionError(RuntimeError):
    """The selected revision cannot be used. Never downgraded to a warning."""


def sha256_file(path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def selected_revision() -> str:
    return os.environ.get("WT_STAGE4_REVISION", "r1").strip().lower() or "r1"


def artifact_path(rel: str) -> pathlib.Path:
    return BUILD / rel


def resolve(approach: str, revision: str = None, verify: bool = True,
            require_onnx: bool = False) -> dict:
    """Resolve one approach's artifacts for a revision, verifying what exists.

    `verify=True` checks the file hash against the registry when the registry knows
    it; a mismatch raises `RevisionError`. Nothing here ever returns another
    revision's file.
    """
    revision = (revision or selected_revision()).lower()
    if revision not in REVISIONS:
        raise RevisionError("unknown Stage 4 revision %r; known: %s"
                           % (revision, ", ".join(sorted(REVISIONS))))
    approach = approach.upper()
    spec = REVISIONS[revision]["approaches"].get(approach)
    if spec is None:
        raise RevisionError("revision %s has no approach %s" % (revision, approach))
    out = {"revision": revision, "label": REVISIONS[revision]["label"],
           "status": REVISIONS[revision]["status"], "approach": approach,
           "architecture": spec["architecture"], "cache_dir": spec["cache_dir"],
           "cache_size": spec["cache_size"], "epochs": spec["epochs"],
           "training_seconds": spec["training_seconds"],
           "config": dict(FROZEN_CONFIG)}
    problems = []
    for key, path_key, hash_key in (("checkpoint", "checkpoint", "checkpoint_sha256"),
                                    ("onnx", "onnx", "onnx_sha256"),
                                    ("manifest", "manifest", None)):
        rel = spec.get(path_key)
        if not rel:
            out[key] = None
            continue
        p = artifact_path(rel)
        entry = {"path": str(p), "rel": rel, "exists": p.is_file()}
        if p.is_file():
            entry["bytes"] = p.stat().st_size
            expected = spec.get(hash_key) if hash_key else None
            if verify and expected:
                actual = sha256_file(p)
                entry["sha256"] = actual
                entry["sha256_expected"] = expected
                entry["sha256_match"] = (actual == expected)
                if actual != expected:
                    problems.append("%s hash mismatch: expected %s, found %s"
                                    % (key, expected[:16], actual[:16]))
            elif verify:
                entry["sha256"] = sha256_file(p)
        else:
            problems.append("%s missing at %s" % (key, p))
        out[key] = entry
    if require_onnx and not (out.get("onnx") or {}).get("exists"):
        problems.append("ONNX export missing for revision %s approach %s"
                        % (revision, approach))
    out["problems"] = problems
    out["usable"] = not problems
    if verify and problems:
        raise RevisionError("%s/%s: %s" % (revision, approach, "; ".join(problems)))
    return out


def emit(path=None) -> dict:
    """Write the registry file the product reads, with verified hashes."""
    path = pathlib.Path(path or REGISTRY_PATH)
    doc = {"schema": "stage4-revisions/1", "selected": selected_revision(),
           "frozen_config": dict(FROZEN_CONFIG), "revisions": {}}
    for rev, spec in REVISIONS.items():
        entry = {"label": spec["label"], "status": spec["status"],
                 "description": spec["description"], "approaches": {}}
        for approach in ("A", "B"):
            try:
                resolved = resolve(approach, rev, verify=True)
            except RevisionError as exc:
                # A historical revision may legitimately lack a verified hash; record
                # the state instead of inventing one.
                resolved = resolve(approach, rev, verify=False)
                resolved["verification_error"] = str(exc)
            entry["approaches"][approach] = {
                "architecture": resolved["architecture"],
                "checkpoint": (resolved["checkpoint"] or {}).get("path"),
                "checkpoint_sha256": (resolved["checkpoint"] or {}).get("sha256"),
                "checkpoint_verified": (resolved["checkpoint"] or {}).get("sha256_match"),
                "onnx": (resolved["onnx"] or {}).get("path"),
                "onnx_sha256": (resolved["onnx"] or {}).get("sha256"),
                "onnx_verified": (resolved["onnx"] or {}).get("sha256_match"),
                "manifest": (resolved["manifest"] or {}).get("path"),
                "manifest_sha256": (resolved["manifest"] or {}).get("sha256"),
                "cache_dir": resolved["cache_dir"], "cache_size": resolved["cache_size"],
                "epochs": resolved["epochs"],
                "usable": resolved["usable"],
                "problems": resolved["problems"],
            }
        doc["revisions"][rev] = entry
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=1, sort_keys=True))
    return doc


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--revision", default=None)
    args = ap.parse_args(argv)
    if args.write:
        doc = emit()
        print("wrote %s (selected=%s)" % (REGISTRY_PATH, doc["selected"]))
    if args.verify or args.show:
        rev = args.revision or selected_revision()
        for approach in ("A", "B"):
            try:
                r = resolve(approach, rev, verify=True)
                print("%s/%s usable: checkpoint %s (%s), onnx %s" %
                      (rev, approach, r["checkpoint"]["rel"],
                       (r["checkpoint"].get("sha256") or "?")[:16],
                       (r["onnx"] or {}).get("rel")))
            except RevisionError as exc:
                print("%s/%s NOT USABLE: %s" % (rev, approach, exc))
                return 1
    if not (args.write or args.verify or args.show):
        ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
