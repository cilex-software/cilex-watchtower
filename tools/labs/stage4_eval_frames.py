#!/usr/bin/env python3
"""R1: evaluate a Stage 4 checkpoint on frames, with the CORRECTED transforms.

This is the "corrected evaluator" the repair round needs. It works from checkpoints
rather than from run directories so the same code scores four things on identical
frames:

  * the R0 frozen checkpoint (its weights untouched) under correct geometry,
  * a fresh random initialization of the same architecture,
  * an R1 freshly retrained checkpoint,
  * (optionally) a mini overfit model, on its own fitting frames.

Everything runs on the released public frames in `build/stage4/cache256`, whose
per-entry transform is the one used to map predictions back to source coordinates.
Confidence and IoU defaults are the ORIGINAL frozen settings (0.30 / 0.50); 0.3 IoU
is reported as a sensitivity figure, never as the primary score.

    stage4_eval_frames.py --approach A --checkpoint PATH [--random-init]
                          [--split validation|fitting] [--limit N] [--out FILE]
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
import stage4_evaluate as EV        # noqa: E402
import stage4_model as MODEL        # noqa: E402

ARTIFACTS = ROOT / "build" / "stage4"
R1 = ARTIFACTS / "R1"


def cache_at(size: int):
    return ARTIFACTS / ("cache%d" % size)


def load_entries(cache_dir):
    return json.loads((pathlib.Path(cache_dir) / "entries.json").read_text())


def keys_for(entries, split_path, which: str, limit: int = 0):
    split = json.loads(pathlib.Path(split_path).read_text())
    clips = set(split[which])
    keys = sorted(k for k, e in entries.items() if e["clip_id"] in clips)
    return keys[:limit] if limit else keys


def predict(model, entries, keys, size: int, conf: float, topk: int = 64,
            nms_iou: float = 0.5):
    """Per-frame predictions in SOURCE coordinates, including empty frames."""
    out = {}
    model.eval()
    with torch.inference_mode():
        for key in keys:
            e = entries[key]
            img = cv2.imread(e["path"])
            if img is None:
                out[key] = (np.zeros((0, 4)), np.zeros(0), np.zeros(0, int))
                continue
            if img.shape[0] != size:
                img = cv2.resize(img, (size, size))
            x = torch.from_numpy(cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
                                 .transpose(2, 0, 1).copy()).float().unsqueeze(0) / 255.0
            outputs = model(x)
            boxes, scores, classes = MODEL.decode(outputs, size, conf, topk, nms_iou)
            transforms = e.get("transform") or DATA.letterbox_transform(
                e["src_w"], e["src_h"], size)
            src = DATA.boxes_to_source_frame(boxes, transforms)
            out[key] = (src, scores, classes)
    return out


def references(entries, keys):
    refs = {}
    for key in keys:
        e = entries[key]
        refs[key] = (np.array([o["bbox_xywh"] for o in e["objects"]],
                              np.float64).reshape(-1, 4),
                     np.array([DATA.CLASS_ID[o["class"]] for o in e["objects"]], np.int64))
    return refs


def evaluate(model, entries, keys, size: int, conf: float, iou: float = 0.5):
    preds = predict(model, entries, keys, size, conf)
    refs = references(entries, keys)
    return EV.score_predictions(preds, refs, iou_threshold=iou), preds, refs


def load_model(approach: str, checkpoint=None, random_init=False, seed=20261006):
    if random_init:
        torch.manual_seed(seed)
        model = MODEL.Stage4Detector(approach, pretrained=True)
        return model, {"initialization": "fresh random", "seed": seed,
                       "pretrained_trunk": model.pretrained}
    model, meta = MODEL.load_checkpoint(approach, checkpoint)
    return model, meta


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--approach", required=True, choices=["A", "B"])
    ap.add_argument("--checkpoint")
    ap.add_argument("--random-init", action="store_true")
    ap.add_argument("--split", default="validation", choices=["validation", "fitting"])
    ap.add_argument("--split-file", default=str(ARTIFACTS / "split.json"))
    ap.add_argument("--cache", default=None, help="cache dir (default cache256)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--conf", type=float, default=0.30)
    ap.add_argument("--iou", type=float, default=0.50)
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--label", default="")
    ap.add_argument("--out")
    args = ap.parse_args(argv)
    torch.set_num_threads(int(args.threads))

    cache = pathlib.Path(args.cache) if args.cache else cache_at(MODEL.INPUT_SIZE)
    entries = load_entries(cache)
    size = int(json.loads((cache / "manifest.json").read_text())["size"])
    keys = keys_for(entries, args.split_file, args.split, args.limit)
    model, meta = load_model(args.approach, args.checkpoint, args.random_init)

    primary, preds, refs = evaluate(model, entries, keys, size, args.conf, args.iou)
    sensitivity, _, _ = evaluate(model, entries, keys, size, args.conf, 0.30)
    frame_stats = {
        "frames": len(keys),
        "frames_with_predictions": sum(1 for k in keys if len(preds[k][0])),
        "frames_with_references": sum(1 for k in keys if len(refs[k][0])),
        "predictions": int(sum(len(preds[k][0]) for k in keys)),
        "references": int(sum(len(refs[k][0]) for k in keys)),
    }
    result = {"schema": "stage4-r1-frame-evaluation/1", "approach": args.approach,
              "label": args.label, "checkpoint": args.checkpoint,
              "random_init": bool(args.random_init),
              "checkpoint_sha256": (DATA.sha256_file(args.checkpoint)
                                    if args.checkpoint else None),
              "model_meta": {k: v for k, v in (meta or {}).items()
                             if k in ("initialization", "seed", "tag", "epoch",
                                      "pretrained_trunk")},
              "cache": str(cache), "cache_size": size, "input_size": size,
              "confidence": args.conf, "primary_iou": args.iou,
              "split": args.split, "frame_stats": frame_stats,
              "primary": primary, "sensitivity_iou_0.3": sensitivity["micro"],
              "sensitivity_per_class": {c: v["f1"] for c, v in
                                        sensitivity["per_class"].items()}}
    if args.out:
        pathlib.Path(args.out).write_text(json.dumps(result, indent=1, sort_keys=True))
    m = primary["micro"]
    print("%-10s %-10s conf %.2f IoU %.2f | frames %d preds %d refs %d | "
          "tp %d fp %d fn %d | P %s R %s F1 %s"
          % (args.approach, args.label or ("random" if args.random_init else "ckpt"),
             args.conf, args.iou, frame_stats["frames"], frame_stats["predictions"],
             frame_stats["references"], m["tp"], m["fp"], m["fn"],
             "n/a" if m["precision"] is None else "%.4f" % m["precision"],
             "n/a" if m["recall"] is None else "%.4f" % m["recall"],
             "n/a" if m["f1"] is None else "%.4f" % m["f1"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
