#!/usr/bin/env python3
"""Stage 4 training: approach A (from scratch) and approach B (pretrained trunk).

Real optimization on the released public labels, with everything a reviewer needs
to judge it: the frozen split, the augmentation policy, seeds, per-epoch logs,
checkpoint hashes, the BEFORE (untrained) and AFTER validation numbers on the same
frames, and the exact command line. Training resources are measured here and
reported separately from inference resources.

    stage4_train.py --approach A --epochs 40 --tag A-scratch
    stage4_train.py --approach B --epochs 30 --tag B-resnet18

Nothing is downloaded: approach B builds its trunk with pretrained weights ONCE,
from the local torchvision cache, and every checkpoint contains the full state
dict, so inference never needs the cache or the network.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import random
import sys
import time

import cv2
import numpy as np
import torch

_HERE = pathlib.Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import stage4_data as DATA          # noqa: E402
import stage4_evaluate as EV        # noqa: E402
import stage4_model as MODEL        # noqa: E402

ROOT = _HERE.parent.parent
ARTIFACTS = ROOT / "build" / "stage4"
# R1: the cache is versioned and MATCHES the model input. R0 trained from a 384px
# cache while converting labels with the 256px divisor, which scaled every target by
# 1.5 and dropped a third of the objects off the grid; `--cache` selects the cache
# and its own recorded transform is what every conversion uses.
CACHE = ARTIFACTS / "cache256"
SIZE = MODEL.INPUT_SIZE


def log(path, record: dict):
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, sort_keys=True) + "\n")


def capture_initial_state(model, path, *, capture_point: str,
                          context: dict = None) -> dict:
    """Snapshot a model's parameters BEFORE any optimisation, without aliases.

    R1's capture ran after the training loop and saved `model.state_dict()`, so the
    recorded "initial weights" were the FINAL weights — a tensor-storage audit found
    every recorded payload equal to the final one (R2 finding 3, coordinator
    geometry-artifact-audit.json). The recorded container hash differed from the
    final file only because the surrounding pickle differed, which proves nothing
    about the tensors.

    What is fixed here, and what is NOT: this helper is correct for FUTURE runs. It
    cannot and does not reconstruct the R1 initialization; those files are preserved
    as they are and the historical initialization comparison stays unverified.

    Guarantees, each covered by tools/tests/labs-stage4-provenance.py:
      * every tensor is `clone()`d out of the live module, so later in-place updates
        cannot change what was written;
      * the state hash is computed from the same detached copies that are saved;
      * the capture point is recorded in the file, not only in prose.
    """
    import hashlib
    state = {k: v.detach().clone() for k, v in model.state_dict().items()}
    digest = hashlib.sha256()
    for key in sorted(state):
        digest.update(key.encode())
        digest.update(state[key].cpu().numpy().tobytes())
    state_sha = digest.hexdigest()
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    torch.save({"state_dict": state, "capture_point": capture_point,
                "context": dict(context or {}),
                "state_sha256": state_sha,
                "note": "parameters as they were BEFORE the first optimizer update"},
               str(path))
    return {"path": str(path), "state_sha256": state_sha,
            "capture_point": capture_point,
            "checkpoint_sha256": sha256_file(path) if "sha256_file" in globals()
            else hashlib.sha256(path.read_bytes()).hexdigest()}


def peak_rss_bytes():
    import resource
    raw = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    return raw if sys.platform == "darwin" else raw * 1024


def load_index(cache_dir) -> tuple:
    """(manifest, entries) for a cache directory; geometry comes from the entries."""
    cache_dir = pathlib.Path(cache_dir)
    man = json.loads((cache_dir / "manifest.json").read_text())
    entries = json.loads((cache_dir / "entries.json").read_text())
    if int(man["size"]) != SIZE:
        raise SystemExit("cache %s was built at %d px but the model input is %d px; "
                         "use a cache that matches or pass --input-size"
                         % (cache_dir, man["size"], SIZE))
    return man, entries


#: What happened to every object target during training; logged with the manifest.
DROP_STATS = {"objects": 0, "encoded": 0, "outside_frame": 0, "off_grid": 0,
              "augmentation_clipped": 0}


def batch_tensors(entries, keys, rng, augment: bool):
    images, targets = [], []
    for key in keys:
        e = entries[key]
        img = cv2.imread(e["path"])
        if img is None:
            continue
        if img.shape[0] != SIZE:
            img = cv2.resize(img, (SIZE, SIZE))
        boxes = np.array([o["bbox_xywh"] for o in e["objects"]], np.float64).reshape(-1, 4)
        classes = np.array([DATA.CLASS_ID[o["class"]] for o in e["objects"]], np.int64)
        transform = e.get("transform") or DATA.letterbox_transform(e["src_w"], e["src_h"],
                                                                   SIZE)
        if boxes.size:
            boxes = DATA.boxes_to_model_frame(boxes, transform)
        if augment:
            img, boxes, keep = DATA.augment(img, boxes, rng)
            if keep is not None:
                clipped = int((~keep).sum()) if keep is not None else 0
                DROP_STATS["augmentation_clipped"] += clipped
                classes = classes[keep]
        t = MODEL.make_targets(boxes, classes, SIZE, stats=DROP_STATS)
        images.append(torch.from_numpy(
            cv2.cvtColor(img, cv2.COLOR_BGR2RGB).transpose(2, 0, 1).copy()).float() / 255.0)
        targets.append(t)
    if not images:
        return None, None
    x = torch.stack(images)
    heat = {s: torch.from_numpy(np.stack([t[0][s] for t in targets])) for s in MODEL.STRIDES}
    box = {s: torch.from_numpy(np.stack([t[1][s] for t in targets])) for s in MODEL.STRIDES}
    mask = {s: torch.from_numpy(np.stack([t[2][s] for t in targets])) for s in MODEL.STRIDES}
    return x, (heat, box, mask)


def validate(model, entries, keys, conf: float = 0.30):
    """Loss + fixed-threshold detection metrics on the held-out groups."""
    model.eval()
    losses = []
    predictions = {}
    with torch.inference_mode():
        for i in range(0, len(keys), 8):
            chunk = keys[i:i + 8]
            x, t = batch_tensors(entries, chunk, random.Random(0), augment=False)
            if x is None:
                continue
            out = model(x)
            lh, lb = MODEL.compute_loss(out, t)
            losses.append((float(lh.detach()), float(lb.detach())))
            for j, key in enumerate(chunk[:x.shape[0]]):
                single = {s: out[s][j:j + 1] for s in out}
                boxes, scores, classes = MODEL.decode(single, SIZE, conf, 64, 0.5)
                e = entries[key]
                transform = e.get("transform") or DATA.letterbox_transform(
                    e["src_w"], e["src_h"], SIZE)
                src = DATA.boxes_to_source_frame(boxes, transform)
                predictions[key] = (src, scores, classes)
    model.train()
    refs = {k: (np.array([o["bbox_xywh"] for o in entries[k]["objects"]],
                         np.float64).reshape(-1, 4),
                np.array([DATA.CLASS_ID[o["class"]] for o in entries[k]["objects"]],
                         np.int64))
            for k in keys}
    metrics = EV.score_predictions(predictions, refs, iou_threshold=0.5,
                                   classes=DATA.CLASSES)
    mean_lh = float(np.mean([l[0] for l in losses])) if losses else None
    mean_lb = float(np.mean([l[1] for l in losses])) if losses else None
    return {"loss_heatmap": mean_lh, "loss_box": mean_lb, "metrics": metrics}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--approach", required=True, choices=["A", "B"])
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--batch", type=int, default=12)
    ap.add_argument("--lr", type=float, default=None)
    ap.add_argument("--seed", type=int, default=20261006)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--tag", default=None)
    ap.add_argument("--unfreeze-layer4", action="store_true")
    ap.add_argument("--limit-train", type=int, default=0, help="debug: cap fitting frames")
    ap.add_argument("--val-every", type=int, default=5)
    ap.add_argument("--no-augment", action="store_true",
                    help="ablation: train without the augmentation pipeline")
    ap.add_argument("--cache", default=str(CACHE),
                    help="cache directory whose size matches the model input")
    ap.add_argument("--r1-tag", default=None,
                    help="write the run under this R1 directory name")
    args = ap.parse_args(argv)

    tag = args.tag or ("%s-%s" % (args.approach,
                                  "resnet18" if args.approach == "B" else "scratch"))
    run_dir = ARTIFACTS / (args.r1_tag or "training") / tag
    run_dir.mkdir(parents=True, exist_ok=True)
    log_path = run_dir / "train-log.jsonl"
    started = time.time()

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    random.seed(args.seed)
    torch.set_num_threads(int(args.threads))

    cache_man, entries = load_index(args.cache)
    split = json.loads((ARTIFACTS / "split.json").read_text())
    fit_keys = [k for k, e in entries.items() if e["clip_id"] in split["fitting"]]
    val_keys = [k for k, e in entries.items() if e["clip_id"] in split["validation"]]
    fit_keys.sort()
    val_keys.sort()
    if args.limit_train:
        fit_keys = fit_keys[:args.limit_train]

    model = MODEL.Stage4Detector(args.approach, unfreeze_layer4=args.unfreeze_layer4,
                                 pretrained=True)
    params = model.parameter_counts()
    lr = args.lr if args.lr is not None else (3e-3 if args.approach == "A" else 2e-3)
    opt = torch.optim.AdamW(model.trainable_parameters(), lr=lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs,
                                                       eta_min=lr * 0.05)
    command = "python3 tools/labs/stage4_train.py " + " ".join(argv if argv is not None
                                                               else sys.argv[1:])
    header = {"event": "start", "approach": args.approach, "tag": tag,
              "command": command, "seed": args.seed, "epochs": args.epochs,
              "batch": args.batch, "lr": lr, "threads": args.threads,
              "unfreeze_layer4": bool(args.unfreeze_layer4),
              "input_size": SIZE, "params": params,
              "fitting_frames": len(fit_keys), "validation_frames": len(val_keys),
              "split_sha256": split["split_sha256"],
              "cache_dir": str(args.cache), "cache_size": int(cache_man["size"]),
              "cache_manifest_sha256": DATA.sha256_file(pathlib.Path(args.cache) /
                                                        "manifest.json"),
              "effective_geometry": ("source -> letterbox(%d) -> model input(%d); the "
                                     "two are equal in R1" % (cache_man["size"], SIZE)),
              "pretrained_trunk": model.pretrained,
              "augmentation": ("none (ablation)" if args.no_augment else
                               "flip|scale0.85-1.25|translate0.06|brightness0.2|contrast0.2"),
              "target_encoding": "gaussian-heatmap + (dx,dy,w,h) stride units",
              "loss": "centernet focal (heatmap) + L1 (box)",
              "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    log(log_path, header)

    # Capture BEFORE the first optimizer update, and say so in the file itself.
    initial = capture_initial_state(
        model, run_dir / "initial-weights.pt",
        capture_point="epoch_0_before_first_optimizer_step",
        context={"approach": args.approach, "seed": args.seed,
                 "epochs_planned": args.epochs, "cache": str(args.cache),
                 "resumed_from": None})
    log(log_path, {"event": "initial_state_captured", **initial})
    before = validate(model, entries, val_keys)
    log(log_path, {"event": "before_training_validation", **before})
    print(json.dumps({"event": "before", **{k: before[k] for k in
                                            ("loss_heatmap", "loss_box")}}), flush=True)

    rng = random.Random(args.seed)
    step = 0
    for epoch in range(1, args.epochs + 1):
        order = list(fit_keys)
        rng.shuffle(order)
        epoch_losses = []
        t0 = time.time()
        model.train()
        for i in range(0, len(order), args.batch):
            chunk = order[i:i + args.batch]
            x, t = batch_tensors(entries, chunk, rng, augment=not args.no_augment)
            if x is None:
                continue
            out = model(x)
            lh, lb = MODEL.compute_loss(out, t)
            loss = lh + lb
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.trainable_parameters(), 10.0)
            opt.step()
            step += 1
            epoch_losses.append((float(lh.detach()), float(lb.detach())))
        sched.step()
        rec = {"event": "epoch", "epoch": epoch, "step": step,
               "loss_heatmap": float(np.mean([e[0] for e in epoch_losses])),
               "loss_box": float(np.mean([e[1] for e in epoch_losses])),
               "lr": float(sched.get_last_lr()[0]),
               "seconds": round(time.time() - t0, 2),
               "elapsed_s": round(time.time() - started, 1)}
        if epoch % args.val_every == 0 or epoch == args.epochs:
            val = validate(model, entries, val_keys)
            rec["validation"] = val
            ckpt = MODEL.save_checkpoint(model, run_dir / ("ckpt-epoch-%03d.pt" % epoch),
                                         {"approach": args.approach, "epoch": epoch,
                                          "width": 64, "tag": tag,
                                          "input_size": SIZE, "seed": args.seed})
            rec["checkpoint_sha256"] = ckpt["checkpoint_sha256"]
            print(json.dumps({"event": "epoch", "epoch": epoch,
                              "loss": round(rec["loss_heatmap"] + rec["loss_box"], 4),
                              "val_f1_micro": val["metrics"]["micro"]["f1"],
                              "seconds": rec["seconds"]}), flush=True)
        log(log_path, rec)

    final = MODEL.save_checkpoint(model, run_dir / "final.pt",
                                  {"approach": args.approach, "epoch": args.epochs,
                                   "width": 64, "tag": tag, "input_size": SIZE,
                                   "seed": args.seed, "split_sha256": split["split_sha256"]})
    after = validate(model, entries, val_keys)
    manifest = {"schema_version": 1, "approach": args.approach, "tag": tag,
                "command": command, "seed": args.seed, "epochs": args.epochs,
                "batch": args.batch, "lr": lr, "threads": args.threads,
                "unfreeze_layer4": bool(args.unfreeze_layer4),
                "input_size": SIZE, "params": params,
                "pretrained_trunk": model.pretrained,
                "fitting_frames": len(fit_keys), "validation_frames": len(val_keys),
                "augmentation": ("none (ablation)" if args.no_augment else
                                 "flip|scale0.85-1.25|translate0.06|brightness0.2|contrast0.2"),
                "split_sha256": split["split_sha256"],
                "split_rule": split["rule"],
                "cache_dir": str(args.cache), "cache_size": int(cache_man["size"]),
                "cache_manifest_sha256": DATA.sha256_file(pathlib.Path(args.cache) /
                                                          "manifest.json"),
                "effective_geometry": ("source -> letterbox(%d) -> model input(%d)"
                                       % (cache_man["size"], SIZE)),
                "target_drop_stats": dict(DROP_STATS),
                "fitting_clips": split["fitting"], "validation_clips": split["validation"],
                "before_training_validation": before,
                "after_training_validation": after,
                "final_checkpoint": {k: final[k] for k in
                                     ("checkpoint", "checkpoint_sha256",
                                      "checkpoint_bytes")},
                "initial_weights": initial,
                "training_seconds": round(time.time() - started, 1),
                "training_peak_rss_bytes": peak_rss_bytes(),
                "resource_note": ("training resources measured separately from the "
                                  "inference budget; tracemalloc is not used, RSS is "
                                  "the process high-water mark"),
                "finished_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    (run_dir / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True))
    log(log_path, {"event": "finish", "after_training_validation": after,
                   "training_seconds": manifest["training_seconds"]})
    print(json.dumps({"event": "finish", "tag": tag,
                      "after_micro": after["metrics"]["micro"],
                      "before_micro": before["metrics"]["micro"],
                      "seconds": manifest["training_seconds"],
                      "checkpoint_sha256": final["checkpoint_sha256"],
                      "params": params}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
