#!/usr/bin/env python3
"""Run each preserved R1 checkpoint ONCE and save every frame's raw predictions.

The R1 evaluation artifacts contain only summaries, so the prompt's
regenerate-once rule applies: one inference pass per approach, under the frozen
configuration, with the raw per-frame predictions written to disk BEFORE any
scoring. Both the old and the corrected scoring paths then consume this identical
set, which is what makes the comparison a scoring comparison rather than a new
accuracy experiment.

Frozen here, not tunable: confidence 0.30, primary IoU 0.50, input 256, one sample
per whole second, decode width 1280, two threads, the released validation split.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

import cv2
import numpy as np
import torch

_HERE = pathlib.Path(__file__).resolve().parent
ROOT = _HERE.parent.parent
sys.path.insert(0, str(_HERE))

import stage4_data as DATA          # noqa: E402
import stage4_model as MODEL        # noqa: E402
import stage4_revisions as REV      # noqa: E402

BUILD = ROOT / "build" / "stage4"
OUT = BUILD / "R2-frozen-predictions"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--approach", action="append", default=None)
    ap.add_argument("--split", default="validation")
    ap.add_argument("--cache", default=str(BUILD / "cache256"))
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--threads", type=int, default=REV.FROZEN_CONFIG["threads"])
    args = ap.parse_args(argv)
    torch.set_num_threads(int(args.threads))

    cache = pathlib.Path(args.cache)
    entries = json.loads((cache / "entries.json").read_text())
    cache_manifest_sha = DATA.sha256_file(cache / "manifest.json")
    split_path = BUILD / "split.json"
    split = json.loads(split_path.read_text())
    split_sha = split["split_sha256"]
    clips = set(split[args.split])
    keys = sorted(k for k, e in entries.items() if e["clip_id"] in clips)
    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    approaches = args.approach or ["A", "B"]
    for approach in approaches:
        rev = REV.resolve(approach, verify=True)
        checkpoint = rev["checkpoint"]["path"]
        model, meta = MODEL.load_checkpoint(approach, checkpoint)
        model.eval()
        size = int(rev["cache_size"])
        records, references = [], []
        with torch.inference_mode():
            for key in keys:
                e = entries[key]
                img = cv2.imread(e["path"])
                if img is None:
                    # A missing image is a coverage failure, not an empty detection:
                    # record the frame as failed and let coverage report it.
                    records.append({"key": "%s:f%06d" % (e["clip_id"], e["frame_index"]),
                                    "clip_id": e["clip_id"],
                                    "frame_index": e["frame_index"],
                                    "frame_pts_ms": None, "boxes": [], "scores": [],
                                    "classes": [], "error": "image unreadable",
                                    "image": e["path"]})
                    continue
                if img.shape[0] != size:
                    img = cv2.resize(img, (size, size))
                x = torch.from_numpy(cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
                                     .transpose(2, 0, 1).copy()).float().unsqueeze(0) / 255.0
                boxes, scores, classes = MODEL.decode(
                    model(x), size, REV.FROZEN_CONFIG["confidence"], 64,
                    REV.FROZEN_CONFIG["primary_iou"])
                transform = e.get("transform") or DATA.letterbox_transform(
                    e["src_w"], e["src_h"], size)
                src = DATA.boxes_to_source_frame(boxes, transform)
                records.append({"key": "%s:f%06d" % (e["clip_id"], e["frame_index"]),
                                "clip_id": e["clip_id"],
                                "frame_index": e["frame_index"],
                                "frame_pts_ms": e.get("frame_pts_ms"),
                                "boxes": [[round(float(v), 6) for v in row] for row in src],
                                "scores": [round(float(v), 6) for v in scores],
                                "classes": [int(v) for v in classes],
                                "image": e["path"]})
                references.append({"key": "%s:f%06d" % (e["clip_id"], e["frame_index"]),
                                   "clip_id": e["clip_id"],
                                   "frame_index": e["frame_index"],
                                   "objects": e["objects"],
                                   "ignore_regions": e["ignore_regions"],
                                   "reviewed_classes": e["reviewed_classes"],
                                   "image": e.get("image")})
        pred_path = out_dir / ("predictions-%s.jsonl" % approach)
        with open(pred_path, "w", encoding="utf-8") as fh:
            for rec in records:
                fh.write(json.dumps(rec, sort_keys=True) + "\n")
        ref_path = out_dir / ("references-%s.jsonl" % approach)
        with open(ref_path, "w", encoding="utf-8") as fh:
            for rec in references:
                fh.write(json.dumps(rec, sort_keys=True) + "\n")
        identity = {
            "schema": "stage4-frozen-predictions/1",
            "approach": approach, "revision": rev["revision"],
            "checkpoint": checkpoint, "checkpoint_sha256": rev["checkpoint"]["sha256"],
            "checkpoint_verified": rev["checkpoint"]["sha256_match"],
            "cache": str(cache), "cache_size": size,
            "cache_manifest_sha256": cache_manifest_sha,
            "split": args.split, "split_path": str(split_path), "split_sha256": split_sha,
            "frames": len(records), "predictions": int(sum(len(r["boxes"]) for r in records)),
            "frozen_config": dict(REV.FROZEN_CONFIG),
            "predictions_file": str(pred_path),
            "predictions_sha256": DATA.sha256_file(pred_path),
            "references_file": str(ref_path),
            "references_sha256": DATA.sha256_file(ref_path),
            "note": "one pass per checkpoint; raw predictions saved BEFORE scoring",
        }
        (out_dir / ("identity-%s.json" % approach)).write_text(
            json.dumps(identity, indent=1, sort_keys=True))
        print("%s: %d frames, %d predictions, checkpoint %s verified=%s -> %s"
              % (approach, len(records), identity["predictions"],
                 identity["checkpoint_sha256"][:16],
                 identity["checkpoint_verified"], pred_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
