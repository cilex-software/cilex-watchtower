#!/usr/bin/env python3
"""R1 overlays: source boxes, model-input boxes and decoded boxes, side by side.

The prompt asks for visual inspection of real training-frame overlays rather than
trusting a falling loss: a model can minimise its loss while every box sits in the
wrong place, and the R0 defect did exactly that. Each panel shows, for one fitting
frame:

  * left  — the SOURCE frame with the released boxes (green) and the model's decoded
            predictions mapped back to source coordinates (red);
  * right — the actual MODEL INPUT pixels (the letterboxed 256 frame) with the
            released boxes after the forward transform (yellow) and the raw decoded
            boxes in that frame (red).

If the geometry is right, the yellow boxes sit on the objects in the input panel and
the red boxes land near the green ones in the source panel. Nothing here is a scored
result: it is an inspection aid, and it says which model and which cache it used.
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

ARTIFACTS = ROOT / "build" / "stage4"
GREEN = (90, 200, 90)
YELLOW = (60, 200, 240)
RED = (60, 60, 235)


def draw(img, boxes, colour, label=None, thickness=2):
    h, w = img.shape[:2]
    for i, (x, y, bw, bh) in enumerate(np.asarray(boxes).reshape(-1, 4)):
        p1 = (int(x * w), int(y * h))
        p2 = (int((x + bw) * w), int((y + bh) * h))
        cv2.rectangle(img, p1, p2, colour, thickness)
        if label:
            cv2.putText(img, label, (p1[0], max(14, p1[1] - 4)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.5, colour, 1)
    return img


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--approach", required=True, choices=["A", "B"])
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--cache", default=str(ARTIFACTS / "cache256"))
    ap.add_argument("--frames", type=int, default=4)
    ap.add_argument("--skip", type=int, default=0)
    ap.add_argument("--conf", type=float, default=0.30)
    ap.add_argument("--out", default=str(ARTIFACTS / "R1-overlays"))
    args = ap.parse_args(argv)
    torch.set_num_threads(2)

    cache = pathlib.Path(args.cache)
    entries = json.loads((cache / "entries.json").read_text())
    size = int(json.loads((cache / "manifest.json").read_text())["size"])
    split = json.loads((ARTIFACTS / "split.json").read_text())
    fitting = set(split["fitting"])
    keys = sorted(k for k, e in entries.items()
                  if e["clip_id"] in fitting and e["objects"])[args.skip:]
    keys = keys[:args.frames]

    # frame_index -> released keyframe image, from the released annotations (the
    # cache key carries the DECODED index, which is not the keyframe number)
    reference = DATA.load_reference("/home/cilex-vision/Videos/Watchtower-Stage4")
    source_image = {(cid, fr["frame_index"]): fr["image"]
                    for cid, clip in reference.items() for fr in clip["frames"]}

    model, meta = MODEL.load_checkpoint(args.approach, args.checkpoint)
    model.eval()
    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    report = []
    with torch.inference_mode():
        for key in keys:
            e = entries[key]
            letter = cv2.imread(e["path"])
            src_path = source_image.get((e["clip_id"], e["frame_index"]))
            src = cv2.imread(src_path) if src_path else None
            if src is None or letter is None:
                continue
            if letter.shape[0] != size:
                letter = cv2.resize(letter, (size, size))
            x = torch.from_numpy(cv2.cvtColor(letter, cv2.COLOR_BGR2RGB)
                                 .transpose(2, 0, 1).copy()).float().unsqueeze(0) / 255.0
            boxes, scores, classes = MODEL.decode(model(x), size, args.conf, 64, 0.5)
            t = e.get("transform") or DATA.letterbox_transform(e["src_w"], e["src_h"], size)
            ref_src = np.array([o["bbox_xywh"] for o in e["objects"]], np.float64)
            ref_model = DATA.boxes_to_model_frame(ref_src, t)
            pred_src = DATA.boxes_to_source_frame(boxes, t)

            # the model input is square; draw the letterboxed canvas as it is
            left = src.copy()
            draw(left, ref_src, GREEN, "ref")
            draw(left, pred_src, RED, "pred", 3)
            right = letter.copy()
            draw(right, ref_model, YELLOW, "ref", 3)
            draw(right, boxes, RED, "pred", 1)
            h = 420
            left_r = cv2.resize(left, (int(left.shape[1] * h / left.shape[0]), h))
            right_r = cv2.resize(right, (int(right.shape[1] * h / right.shape[0]), h))
            canvas = np.hstack([left_r, np.full((h, 12, 3), 25, np.uint8), right_r])
            cv2.putText(canvas, "%s %s %s | refs %d preds %d" %
                        (args.approach, pathlib.Path(args.checkpoint).stem, key,
                         len(ref_src), len(boxes)),
                        (10, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (240, 240, 240), 1)
            path = out_dir / ("%s-%s-overlay.png" % (args.approach, key))
            cv2.imwrite(str(path), canvas)
            # best IoU of any prediction against any reference, for the index only
            ious = (float(max(_iou(pred, ref) for pred in pred_src for ref in ref_src))
                    if len(ref_src) and len(pred_src) else 0.0)
            report.append({"key": key, "clip": e["clip_id"], "refs": len(ref_src),
                           "preds": len(boxes), "best_iou": round(ious, 3),
                           "overlay": str(path)})
    (out_dir / ("%s-index.json" % args.approach)).write_text(
        json.dumps({"approach": args.approach, "checkpoint": args.checkpoint,
                    "cache": str(cache), "confidence": args.conf,
                    "frames": report}, indent=1, sort_keys=True))
    for row in report:
        print("%-18s refs %2d preds %2d best IoU %.3f -> %s"
              % (row["key"], row["refs"], row["preds"], row["best_iou"], row["overlay"]))
    return 0


def _iou(a, b) -> float:
    xx0, yy0 = max(a[0], b[0]), max(a[1], b[1])
    xx1, yy1 = min(a[0] + a[2], b[0] + b[2]), min(a[1] + a[3], b[1] + b[3])
    inter = max(0.0, xx1 - xx0) * max(0.0, yy1 - yy0)
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union > 0 else 0.0


if __name__ == "__main__":
    sys.exit(main())
