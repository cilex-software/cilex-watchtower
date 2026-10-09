"""Stage 4 training data: released labels -> a frozen grouped split -> tensors.

WHAT IS LEARNED FROM WHAT. Only the released public reference labels are used, and
only for FITTING and VALIDATION of the learned components. Colour is deliberately
NOT trained here: the V1 colour method is analytical (region sampling + CIELAB), so
the colour reference labels are used for evaluation and for the colour-method
ablation, never as gradient targets. That is disclosed in the submission.

THE SPLIT is frozen before any training and before any prediction is looked at:

  * unit = `minimum_leakage_group` from the released leakage_groups.json, so
    neighbouring frames, crops, augmentations and alternative encodings of one
    scene can never straddle fitting and validation;
  * VALIDATION_GROUPS is a fixed, named set chosen by label coverage (each of the
    three classes has positives in validation, and the fitting side keeps as much
    animal data as possible). It is a constant in this file, so the split cannot
    drift between runs; `split.json` records it with hashes.

Images are the released decoded keyframes (JPEG). DATASET.md permits them as
declared training inputs; official video inference still runs on decoded video
pixels, which this module is not part of.
"""
from __future__ import annotations

import hashlib
import json
import pathlib

import cv2
import numpy as np

CLASSES = ("human", "car", "animal")
CLASS_ID = {c: i for i, c in enumerate(CLASSES)}
IGNORE_CLASS_ID = -1

#: Frozen validation groups. Chosen by measured label coverage on 2026-10-06
#: (VAL_COVERAGE below): each class has positives, and the fitting side keeps 57 of
#: the 101 animal instances rather than the 52 it would keep with the animal-heavy
#: group moved over.
VALIDATION_GROUPS = ("archive-scene-008", "archive-scene-016", "archive-scene-019")
SPLIT_RULE = ("minimum_leakage_group unit; VALIDATION_GROUPS fixed by name; "
              "chosen by per-group class coverage before training; no randomness")
VAL_COVERAGE = {"human": 146, "car": 52, "animal": 44}


def sha256_file(path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def sha256_obj(obj) -> str:
    blob = json.dumps(obj, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def load_reference(root) -> dict:
    """Every released annotation file, keyed by clip, with its own hash."""
    root = pathlib.Path(root)
    groups = {e["clip_id"]: e["minimum_group"]
              for e in json.loads((root / "leakage_groups.json").read_text())["groups"]}
    inputs = json.loads((root / "inputs.json").read_text())
    clips = {}
    for entry in inputs["clips"]:
        cid = entry["clip_id"]
        ann_path = root / entry["annotations"]
        ann = json.loads(ann_path.read_text())
        # Frame geometry (source pixel size) lives in the frames manifest, not in
        # the annotation file; the letterbox mapping needs it, so merge on index.
        geometry = {}
        if entry.get("frames_manifest"):
            fm = json.loads((root / entry["frames_manifest"]).read_text())
            geometry = {int(fr["frame_index"]): (int(fr["width"]), int(fr["height"]))
                        for fr in fm.get("frames", []) if fr.get("width")}
        frames = []
        for fr in ann["frames"]:
            objects = []
            for ob in fr.get("objects", []):
                cls = ob["class"]
                if cls not in CLASS_ID:
                    continue                       # no bicycle/bus/truck relabelling
                objects.append({
                    "instance_id": ob.get("instance_id"),
                    "class": cls,
                    "bbox_xywh": [float(v) for v in ob["bbox_xywh"]],
                    "size_label": (ob.get("apparent_size") or {}).get("label"),
                    "area_fraction": (ob.get("apparent_size") or {}).get("area_fraction"),
                    "colors": ob.get("colors", []),
                    "truncated": ob.get("truncated"),
                    "occluded": ob.get("occluded"),
                })
            w_h = geometry.get(int(fr["frame_index"]), (0, 0))
            frames.append({
                "frame_index": int(fr["frame_index"]),
                "frame_pts_ms": float(fr["frame_pts_ms"]),
                "width": w_h[0], "height": w_h[1],
                "image": str(root / fr["image"]) if fr.get("image") else None,
                "reviewed_classes": fr.get("reviewed_classes", []),
                "objects": objects,
                "ignore_regions": fr.get("ignore_regions", []),
            })
        clips[cid] = {"clip_id": cid, "group": groups[cid], "sha256": entry["sha256"],
                      "video": str(root / entry["video"]),
                      "annotations_sha256": sha256_file(ann_path),
                      "frames": frames}
    return clips


def build_split(clips: dict) -> dict:
    fitting, validation = [], []
    for cid, clip in sorted(clips.items()):
        (validation if clip["group"] in VALIDATION_GROUPS else fitting).append(cid)

    def counts(ids):
        out = {c: 0 for c in CLASSES}
        frames = 0
        for cid in ids:
            for fr in clips[cid]["frames"]:
                frames += 1
                for ob in fr["objects"]:
                    out[ob["class"]] += 1
        return {"frames": frames, "instances": out}

    split = {"schema_version": 1, "rule": SPLIT_RULE,
             "validation_groups": list(VALIDATION_GROUPS),
             "fitting": fitting, "validation": validation,
             "fitting_counts": counts(fitting), "validation_counts": counts(validation),
             "clip_hashes": {cid: clips[cid]["sha256"] for cid in sorted(clips)},
             "annotation_hashes": {cid: clips[cid]["annotations_sha256"]
                                   for cid in sorted(clips)}}
    split["split_sha256"] = sha256_obj({k: split[k] for k in
                                        ("rule", "validation_groups", "fitting",
                                         "validation", "clip_hashes")})
    return split


# ----------------------------------------------------------------------------------
# letterboxed tensors
# ----------------------------------------------------------------------------------
def letterbox(image: np.ndarray, size: int, bgr_mean=(114, 114, 114)):
    """(image, scale, pad_x, pad_y) resized to `size` with aspect preserved."""
    h, w = image.shape[:2]
    scale = min(size / float(w), size / float(h))
    nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    resized = cv2.resize(image, (nw, nh), interpolation=cv2.INTER_AREA
                         if scale < 1 else cv2.INTER_LINEAR)
    out = np.full((size, size, 3), bgr_mean, dtype=np.uint8)
    px, py = (size - nw) // 2, (size - nh) // 2
    out[py:py + nh, px:px + nw] = resized
    return out, scale, px, py


# ==================================================================================
# R1: ONE EXPLICIT TRANSFORM, AND IT REFUSES TO BE INCONSISTENT
# ==================================================================================
# The R0 training path letterboxed frames at cache size 384, then converted the
# labels with `size=256` (the model input), so every target was 384/256 = 1.5x its
# correct coordinate: object centres moved 16.7 cells on a 64-cell grid and 33.1% of
# all labelled objects fell off the grid entirely (measured, tools/tests/
# labs-stage4-geometry.py). Nothing raised, because both numbers were "just
# integers". These functions take the geometry as a dict and verify it, so a size
# that does not belong to the scale/padding pair is an error, not a silent shift.
def letterbox_transform(src_w: int, src_h: int, size: int) -> dict:
    """The single definition of the source -> letterbox mapping."""
    if not src_w or not src_h or not size:
        raise ValueError("letterbox_transform needs positive sizes, got %r"
                         % ((src_w, src_h, size),))
    scale = min(size / float(src_w), size / float(src_h))
    return {"size": int(size), "src_w": int(src_w), "src_h": int(src_h),
            "scale": float(scale),
            "pad_x": (size - src_w * scale) / 2.0,
            "pad_y": (size - src_h * scale) / 2.0}


def validate_transform(t: dict) -> dict:
    """Reject a geometry whose scale/padding do not belong to its size."""
    size, src_w, src_h = t["size"], t["src_w"], t["src_h"]
    want = min(size / float(src_w), size / float(src_h))
    if abs(t["scale"] - want) > 1e-6:
        raise ValueError(
            "inconsistent letterbox geometry: scale %.6f does not match size %d for a "
            "%dx%d source (expected %.6f). This is the R0 defect: a cache built at one "
            "resolution converted with another resolution's divisor."
            % (t["scale"], size, src_w, src_h, want))
    if abs(t["pad_x"] - (size - src_w * t["scale"]) / 2.0) > 0.5 \
            or abs(t["pad_y"] - (size - src_h * t["scale"]) / 2.0) > 0.5:
        raise ValueError("inconsistent letterbox padding for size %d" % size)
    return t


def boxes_to_model_frame(boxes, t: dict):
    """Source-normalized boxes -> normalized boxes in the model input frame."""
    validate_transform(t)
    boxes = np.asarray(boxes, dtype=np.float64).reshape(-1, 4)
    if boxes.size == 0:
        return boxes.reshape(0, 4)
    size, s = float(t["size"]), t["scale"]
    out = np.empty_like(boxes)
    out[:, 0] = (boxes[:, 0] * t["src_w"] * s + t["pad_x"]) / size
    out[:, 1] = (boxes[:, 1] * t["src_h"] * s + t["pad_y"]) / size
    out[:, 2] = boxes[:, 2] * t["src_w"] * s / size
    out[:, 3] = boxes[:, 3] * t["src_h"] * s / size
    return out


def boxes_to_source_frame(boxes, t: dict):
    """Model-input-normalized boxes -> source-normalized boxes, clipped to frame."""
    validate_transform(t)
    boxes = np.asarray(boxes, dtype=np.float64).reshape(-1, 4)
    if boxes.size == 0:
        return boxes.reshape(0, 4)
    size, s = float(t["size"]), t["scale"]
    out = np.empty_like(boxes)
    out[:, 0] = (boxes[:, 0] * size - t["pad_x"]) / (s * t["src_w"])
    out[:, 1] = (boxes[:, 1] * size - t["pad_y"]) / (s * t["src_h"])
    out[:, 2] = boxes[:, 2] * size / (s * t["src_w"])
    out[:, 3] = boxes[:, 3] * size / (s * t["src_h"])
    out[:, 0] = np.clip(out[:, 0], 0.0, 1.0)
    out[:, 1] = np.clip(out[:, 1], 0.0, 1.0)
    out[:, 2] = np.clip(out[:, 2], 1e-6, 1.0 - out[:, 0])
    out[:, 3] = np.clip(out[:, 3], 1e-6, 1.0 - out[:, 1])
    return out


def boxes_to_letterbox(boxes, src_w: int, src_h: int, scale: float, px: int, py: int,
                       size: int):
    """Normalized SOURCE boxes -> normalized boxes in the letterboxed image.

    The contract's boxes are fractions of the full source frame, so the padding
    and the scale have to be undone exactly in both directions; this pair is the
    single place that does it, and the unit checks pin the round trip.
    """
    boxes = np.asarray(boxes, dtype=np.float64).reshape(-1, 4)
    if boxes.size == 0:
        return boxes.reshape(0, 4)
    validate_transform({"size": int(size), "src_w": int(src_w), "src_h": int(src_h),
                        "scale": float(scale), "pad_x": float(px), "pad_y": float(py)})
    out = np.empty_like(boxes)
    out[:, 0] = (boxes[:, 0] * src_w * scale + px) / size
    out[:, 1] = (boxes[:, 1] * src_h * scale + py) / size
    out[:, 2] = boxes[:, 2] * src_w * scale / size
    out[:, 3] = boxes[:, 3] * src_h * scale / size
    return out


def letterbox_to_boxes(boxes, src_w: int, src_h: int, scale: float, px: int, py: int,
                       size: int):
    """Normalized letterboxed boxes -> normalized SOURCE boxes, clipped to frame."""
    boxes = np.asarray(boxes, dtype=np.float64).reshape(-1, 4)
    if boxes.size == 0:
        return boxes.reshape(0, 4)
    validate_transform({"size": int(size), "src_w": int(src_w), "src_h": int(src_h),
                        "scale": float(scale), "pad_x": float(px), "pad_y": float(py)})
    out = np.empty_like(boxes)
    out[:, 0] = (boxes[:, 0] * size - px) / (scale * src_w)
    out[:, 1] = (boxes[:, 1] * size - py) / (scale * src_h)
    out[:, 2] = boxes[:, 2] * size / (scale * src_w)
    out[:, 3] = boxes[:, 3] * size / (scale * src_h)
    out[:, 0] = np.clip(out[:, 0], 0.0, 1.0)
    out[:, 1] = np.clip(out[:, 1], 0.0, 1.0)
    out[:, 2] = np.clip(out[:, 2], 1e-6, 1.0 - out[:, 0])
    out[:, 3] = np.clip(out[:, 3], 1e-6, 1.0 - out[:, 1])
    return out


def build_cache(clips, split, cache_dir, size=384, quality=90, limit=None) -> dict:
    """Decode each released keyframe once and store a letterboxed JPEG.

    Reading a 2560x1440 JPEG per epoch is pure I/O cost; the cache keeps training
    epochs CPU-bound and bounded. Cache lives under build/ (git-ignored).
    """
    cache_dir = pathlib.Path(cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)
    index = {}
    written = 0
    for cid in sorted(clips):
        for fr in clips[cid]["frames"]:
            if not fr["image"]:
                continue
            key = "%s-f%05d" % (cid, fr["frame_index"])
            dest = cache_dir / (key + ".jpg")
            img = cv2.imread(fr["image"]) if not dest.is_file() else None
            if img is not None:
                small, scale, pad_x, pad_y = letterbox(img, size)
                cv2.imwrite(str(dest), small, [int(cv2.IMWRITE_JPEG_QUALITY), quality])
                written += 1
                src_w, src_h = img.shape[1], img.shape[0]
            else:
                if not dest.is_file():
                    continue
                cached = cv2.imread(str(dest))
                src_w, src_h = 0, 0
                scale = pad_x = pad_y = 0
                if cached is not None:
                    # geometry is recomputed from the stored frame metadata
                    src_w, src_h = int(fr.get("width") or 0), int(fr.get("height") or 0)
                    if src_w and src_h:
                        scale = min(size / float(src_w), size / float(src_h))
                        pad_x = (size - int(round(src_w * scale))) // 2
                        pad_y = (size - int(round(src_h * scale))) // 2
            transform = letterbox_transform(src_w, src_h, size) if src_w and src_h else None
            index[key] = {"clip_id": cid, "frame_index": fr["frame_index"],
                          "path": str(dest), "objects": fr["objects"],
                          "transform": transform,
                          "ignore_regions": fr["ignore_regions"],
                          "reviewed_classes": fr["reviewed_classes"],
                          "group": clips[cid]["group"],
                          "src_w": int(src_w), "src_h": int(src_h),
                          "scale": float(scale), "pad_x": int(pad_x), "pad_y": int(pad_y)}
            if limit and len(index) >= limit:
                break
    manifest = {"schema_version": 1, "size": size, "quality": quality,
                "cache_dir": str(cache_dir), "written_now": written,
                "frames": len(index),
                "entries": index}
    manifest["cache_sha256"] = sha256_obj({k: index[k]["path"] for k in sorted(index)})
    return manifest


def targets_for(entry, size: int, strides=(4, 8), max_objects=32):
    """Heatmap/box targets for one cached frame, from the released labels."""
    heat = {s: np.zeros((3, size // s, size // s), np.float32) for s in strides}
    box = {s: np.zeros((4, size // s, size // s), np.float32) for s in strides}
    mask = {s: np.zeros((size // s, size // s), np.float32) for s in strides}
    boxes, classes = [], []
    for ob in entry["objects"][:max_objects]:
        x, y, w, h = ob["bbox_xywh"]
        area = w * h
        level = strides[0] if area < 0.01 else strides[-1]
        cx, cy = (x + w / 2.0) * size, (y + h / 2.0) * size
        gx, gy = int(cx / level), int(cy / level)
        gh, gw = heat[level].shape[1], heat[level].shape[2]
        if not (0 <= gx < gw and 0 <= gy < gh):
            continue
        cls = CLASS_ID[ob["class"]]
        heat[level][cls, gy, gx] = 1.0
        box[level][:, gy, gx] = [cx / level - gx, cy / level - gy,
                                 w * size / level, h * size / level]
        mask[level][gy, gx] = 1.0
        boxes.append([x, y, w, h])
        classes.append(cls)
    return heat, box, mask, np.array(boxes, np.float64).reshape(-1, 4), \
        np.array(classes, np.int64)


def augment(image, boxes, rng, scale_range=(0.85, 1.25), translate=0.06,
            brightness=0.2, contrast=0.2, flip=True):
    """Bounded, recorded augmentation: flip / scale / translate / photometric."""
    h, w = image.shape[:2]
    out = image
    new_boxes = boxes.copy()
    if flip and rng.random() < 0.5:
        out = out[:, ::-1]
        if new_boxes.size:
            new_boxes[:, 0] = 1.0 - (new_boxes[:, 0] + new_boxes[:, 2])
    s = float(rng.uniform(*scale_range))
    if abs(s - 1.0) > 1e-3:
        # One affine mapping for the image AND its boxes. The previous version
        # pasted the scaled image at the canvas origin while shifting the boxes by
        # the crop offset, so every shrunken frame carried boxes displaced by up
        # to 8% of the image -- enough label noise to keep the heatmap flat at the
        # class prior (measured: max score 0.10 across 135 validation frames after
        # 1000 steps, while a single unaugmented image overfits in 50).
        matrix = np.float32([[s, 0, (w - s * w) / 2.0], [0, s, (h - s * h) / 2.0]])
        out = cv2.warpAffine(np.ascontiguousarray(out), matrix, (w, h),
                             borderValue=(114, 114, 114))
        if new_boxes.size:
            new_boxes[:, 0] = new_boxes[:, 0] * s + (1.0 - s) / 2.0
            new_boxes[:, 1] = new_boxes[:, 1] * s + (1.0 - s) / 2.0
            new_boxes[:, 2] = new_boxes[:, 2] * s
            new_boxes[:, 3] = new_boxes[:, 3] * s
    if translate > 0:
        dx = float(rng.uniform(-translate, translate))
        dy = float(rng.uniform(-translate, translate))
        m = np.float32([[1, 0, dx * w], [0, 1, dy * h]])
        out = cv2.warpAffine(out, m, (w, h), borderValue=(114, 114, 114))
        if new_boxes.size:
            new_boxes[:, 0] += dx
            new_boxes[:, 1] += dy
    if brightness or contrast:
        alpha = 1.0 + float(rng.uniform(-contrast, contrast))
        beta = float(rng.uniform(-brightness, brightness)) * 255.0
        out = np.clip(out.astype(np.float32) * alpha + beta, 0, 255).astype(np.uint8)
    keep = None
    if new_boxes.size:
        x0 = np.clip(new_boxes[:, 0], 0.0, 1.0)
        y0 = np.clip(new_boxes[:, 1], 0.0, 1.0)
        x1 = np.clip(new_boxes[:, 0] + new_boxes[:, 2], 0.0, 1.0)
        y1 = np.clip(new_boxes[:, 1] + new_boxes[:, 3], 0.0, 1.0)
        keep = (x1 - x0 > 0.004) & (y1 - y0 > 0.004)
        new_boxes = np.stack([x0, y0, x1 - x0, y1 - y0], axis=1)[keep]
    # The caller MUST apply the same mask to its class ids, or boxes and classes
    # silently pair up wrongly and the model learns the wrong labels.
    return out, new_boxes, keep
