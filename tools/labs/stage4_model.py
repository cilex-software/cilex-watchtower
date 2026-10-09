"""Stage 4 detectors: approach A (from scratch) and approach B (pretrained trunk).

SHARED HEAD, DIFFERENT TRUNKS, and that is the point of the A/B comparison:

  * **A — from scratch.** A small convolutional trunk whose every weight starts
    from a seeded random initialization. No pretrained semantic backbone,
    detector, segmentation/pose head, Haar cascade or default people-detector
    weight supplies anything here. Standard convolution, batch normalization and
    an anchor-free head are fixed architecture, not learned knowledge.
  * **B — a NEW pretrained feature encoder.** torchvision **ResNet-18**
    (IMAGENET1K_V1, BSD-3-Clause) — not the MobileNetV3-Large used by the
    preceding stage, and not a YOLO-family weight. The trunk is FROZEN by default;
    the lateral projections and the whole detection head are newly initialized
    and trained on the released data. `--unfreeze-layer4` is offered as a declared
    variant, and the manifest records which layers were frozen/trained.

Both use the same anchor-free head, the same target encoding, the same decode and
the same NMS, so a difference between A and B measures the trunk, not the recipe.

Head output per level: `3` class heatmap channels (human, car, animal) + `4` box
channels (centre offsets and size in stride units). The heatmap/focal formulation
and the offset parameterization are the published CenterNet formulation,
independently implemented here; no CenterNet weight or code is used.
"""
from __future__ import annotations

import hashlib
import json
import pathlib

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

CLASSES = ("human", "car", "animal")
INPUT_SIZE = 256
#: One detection level. A two-level assignment (stride 4 + 8) was measured to
#: produce competing boxes for the same object from the level the object was NOT
#: trained on, and the wrong-size one sometimes won -- the duplicate then survived
#: NMS because its box was too small to overlap. A single stride-4 level gives
#: small objects 6+ cells across at 256 px and large objects 100+, and the head
#: costs half as much at inference.
STRIDES = (4,)
NATIVE_CONFIG = {
    "input_size": INPUT_SIZE, "strides": list(STRIDES), "num_classes": len(CLASSES),
    "score_threshold": 0.30, "topk": 100, "nms_iou": 0.5,
    "small_area_boundary": 0.01, "big_area_boundary": 0.10,
    "policy": "bbox-area-v1", "device": "cpu", "threads": 2,
}


def sha256_file(path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _norm(channels: int, kind: str):
    """Normalization layer by name.

    `group` for approach A: with a from-scratch trunk, batch 12 and heavy
    augmentation, BatchNorm's running statistics suppressed the heatmap at
    evaluation time -- measured on one checkpoint, max class score 0.075-0.12 in
    eval mode against 0.13-0.20 in train mode, both near the 0.10 class prior.
    GroupNorm carries no running statistics, so what is trained is what is
    evaluated. `batch` stays for approach B, whose trunk carries pretrained frozen
    BatchNorm statistics that should not be disturbed.
    """
    if kind == "group":
        groups = 8 if channels % 8 == 0 else (4 if channels % 4 == 0 else 1)
        return nn.GroupNorm(groups, channels)
    return nn.BatchNorm2d(channels)


def _block(cin, cout, stride=1, norm="batch"):
    return nn.Sequential(
        nn.Conv2d(cin, cout, 3, stride=stride, padding=1, bias=False),
        _norm(cout, norm), nn.ReLU(inplace=True))


class ScratchTrunk(nn.Module):
    """Approach A's trunk: 5 strided convolutions, random initialization."""

    def __init__(self, norm="group"):
        super().__init__()
        self.norm = norm
        self.stem = _block(3, 24, 2, norm)          # /2
        self.s2 = _block(24, 48, 2, norm)           # /4
        self.s4 = _block(48, 80, 2, norm)           # /8
        self.s8 = _block(80, 112, 2, norm)          # /16
        self.s16 = _block(112, 128, 2, norm)        # /32
        self.out_channels = {4: 48, 8: 80}

    def forward(self, x):
        x = self.stem(x)
        c4 = self.s2(x)
        c8 = self.s4(c4)
        _ = self.s16(self.s8(c8))
        return {4: c4, 8: c8}


class ResNet18Trunk(nn.Module):
    """Approach B's trunk: torchvision ResNet-18 IMAGENET1K_V1, frozen by default."""

    def __init__(self, freeze: bool = True, unfreeze_layer4: bool = False,
                 pretrained: bool = True):
        super().__init__()
        from torchvision.models import resnet18, ResNet18_Weights
        # `pretrained=False` builds the SAME architecture with random weights and
        # never touches the network or the download cache: inference loads a
        # Stage 4 checkpoint over it and must work with no connectivity at all.
        net = resnet18(weights=ResNet18_Weights.IMAGENET1K_V1 if pretrained else None)
        self.stem = nn.Sequential(net.conv1, net.bn1, net.relu, net.maxpool)
        self.layer1, self.layer2 = net.layer1, net.layer2      # /4, /8
        self.layer3, self.layer4 = net.layer3, net.layer4      # /16, /32
        self.norm = "batch"            # the trunk's own pretrained statistics
        self.proj4 = nn.Conv2d(64, 64, 1)
        self.proj8 = nn.Conv2d(128, 96, 1)
        self.pretrained_weights = (str(ResNet18_Weights.IMAGENET1K_V1.url)
                                   if pretrained else None)
        self.out_channels = {4: 64, 8: 96}
        for p in self.parameters():
            p.requires_grad = not freeze
        if unfreeze_layer4:
            for p in self.layer4.parameters():
                p.requires_grad = True
        # Laterals and head are ALWAYS trained, whatever the trunk setting is.
        for p in list(self.proj4.parameters()) + list(self.proj8.parameters()):
            p.requires_grad = True
        self.frozen = freeze and not unfreeze_layer4

    def forward(self, x):
        x = self.stem(x)
        c4 = self.layer1(x)
        c8 = self.layer2(c4)
        if any(p.requires_grad for p in self.layer3.parameters()):
            c16 = self.layer3(c8)
            _ = self.layer4(c16)
        else:
            with torch.no_grad():
                c16 = self.layer3(c8)
                _ = self.layer4(c16)
        return {4: self.proj4(c4), 8: self.proj8(c8)}


#: Prior probability of "object here" at initialization. Without it the ~15k
#: negative cells per image dominate the shared head weights and the heatmap
#: collapses to a uniform low map that never produces a peak (measured: every
#: class score 0.05-0.10 and zero true positives after 120 optimizer steps).
#: -2.19 is the usual sparse-detection prior (sigmoid(-2.19) ~ 0.10): a declared
#: initialization choice, not learned knowledge and not a pretrained weight.
CLASS_BIAS_PRIOR = -2.19


class Head(nn.Module):
    """Anchor-free head: per-level class heatmap + box parameterization."""

    def __init__(self, channels: dict, num_classes=len(CLASSES), width=64,
                 class_bias_prior: float = CLASS_BIAS_PRIOR, norm="batch"):
        super().__init__()
        self.norm = norm
        self.branches = nn.ModuleDict()
        for stride, cin in channels.items():
            final = nn.Conv2d(width, num_classes + 4, 1)
            with torch.no_grad():
                final.bias[:num_classes].fill_(class_bias_prior)
                final.bias[num_classes:].zero_()
            self.branches[str(int(stride))] = nn.Sequential(
                nn.Conv2d(cin, width, 3, padding=1, bias=False),
                _norm(width, norm), nn.ReLU(inplace=True),
                final)

    def forward(self, feats):
        return {int(k): self.branches[str(k)](v) for k, v in feats.items()}


class Stage4Detector(nn.Module):
    def __init__(self, approach: str, unfreeze_layer4: bool = False, width=64,
                 pretrained: bool = True, strides=STRIDES):
        super().__init__()
        self.strides = tuple(strides)
        if approach == "A":
            self.trunk = ScratchTrunk(norm="group")
            self.pretrained = None
            self.norm = "group"
        elif approach == "B":
            self.trunk = ResNet18Trunk(freeze=True, unfreeze_layer4=unfreeze_layer4,
                                       pretrained=pretrained)
            self.pretrained = self.trunk.pretrained_weights
            self.norm = "batch"
        else:
            raise ValueError("approach must be A or B, not %r" % (approach,))
        self.approach = approach
        self.head = Head({k: v for k, v in self.trunk.out_channels.items()
                          if k in self.strides}, width=width, norm=self.norm)

    def forward(self, x):
        feats = self.trunk(x)
        return self.head({k: v for k, v in feats.items() if k in self.strides})

    def trainable_parameters(self):
        return [p for p in self.parameters() if p.requires_grad]

    def parameter_counts(self) -> dict:
        total = sum(p.numel() for p in self.parameters())
        trainable = sum(p.numel() for p in self.trainable_parameters())
        return {"total": int(total), "trainable": int(trainable),
                "frozen": int(total - trainable)}


# ----------------------------------------------------------------------------------
# targets, loss, decode
# ----------------------------------------------------------------------------------
def gaussian_target(heat, gx, gy, cls, radius):
    h, w = heat.shape[1], heat.shape[2]
    x0, x1 = max(0, gx - radius), min(w, gx + radius + 1)
    y0, y1 = max(0, gy - radius), min(h, gy + radius + 1)
    if x0 >= x1 or y0 >= y1:
        return
    ys = np.arange(y0, y1)[:, None]
    xs = np.arange(x0, x1)[None, :]
    sigma = max(0.6, radius / 3.0)
    g = np.exp(-((xs - gx) ** 2 + (ys - gy) ** 2) / (2 * sigma * sigma))
    np.maximum(heat[cls, y0:y1, x0:x1], g.astype(np.float32),
               out=heat[cls, y0:y1, x0:x1])


def make_targets(boxes: np.ndarray, classes: np.ndarray, size: int, strides=STRIDES,
                 stats: dict = None):
    """Gaussian heatmaps + (dx, dy, log w, log h) boxes at the assigned level.

    `stats`, when given, counts what happened to every object: encoded, dropped
    because it falls outside the model input frame after augmentation (legitimate
    clipping), or dropped because its centre maps off the target grid although it
    IS inside the frame -- the latter is a geometry error and must stay at zero.
    """
    heat = {s: np.zeros((len(CLASSES), size // s, size // s), np.float32) for s in strides}
    box = {s: np.zeros((4, size // s, size // s), np.float32) for s in strides}
    mask = {s: np.zeros((size // s, size // s), np.float32) for s in strides}
    if stats is not None:
        stats.setdefault("objects", 0)
        stats.setdefault("encoded", 0)
        stats.setdefault("outside_frame", 0)
        stats.setdefault("off_grid", 0)
    for (x, y, w, h), cls in zip(boxes, classes):
        if stats is not None:
            stats["objects"] += 1
            if x < 0 or y < 0 or x + w > 1.0 + 1e-9 or y + h > 1.0 + 1e-9:
                stats["outside_frame"] += 1
                continue
        level = strides[0]
        cx, cy = (x + w / 2.0) * size, (y + h / 2.0) * size
        gx, gy = int(cx / level), int(cy / level)
        grid_h, grid_w = heat[level].shape[1], heat[level].shape[2]
        if not (0 <= gx < grid_w and 0 <= gy < grid_h):
            if stats is not None:
                stats["off_grid"] += 1
            continue
        if stats is not None:
            stats["encoded"] += 1
        px_w, px_h = w * size, h * size
        radius = int(max(1, min(4, round(min(px_w, px_h) / (2.0 * level)))))
        gaussian_target(heat[level], gx, gy, int(cls), radius)
        # log-space size: raw cell sizes span two orders of magnitude, and the
        # decoder exponentiates, so the encoder MUST write the log (a mismatch
        # here costs every detection: measured as zero TP with plausible scores).
        box[level][:, gy, gx] = [cx / level - gx, cy / level - gy,
                                 float(np.log(max(px_w, 1e-3) / level)),
                                 float(np.log(max(px_h, 1e-3) / level))]
        mask[level][gy, gx] = 1.0
    return heat, box, mask


def focal_loss(pred_logit, target):
    p = torch.sigmoid(pred_logit).clamp(1e-4, 1 - 1e-4)
    pos = target.ge(0.999)
    pos_loss = -torch.log(p[pos]) * ((1 - p[pos]) ** 2) if pos.any() else p.sum() * 0
    neg = ~pos
    neg_loss = -torch.log(1 - p[neg]) * (p[neg] ** 2) * ((1 - target[neg]) ** 4)
    n = max(1, int(pos.sum().item()))
    return (pos_loss.sum() + neg_loss.sum()) / n


def box_loss(pred_box, target_box, mask):
    if mask.sum() == 0:
        return pred_box.sum() * 0
    m = mask.unsqueeze(1)
    return (torch.abs(pred_box - target_box) * m).sum() / (m.sum() * 4)


def compute_loss(outputs, targets):
    heat_t, box_t, mask_t = targets
    levels = sorted(outputs)
    lh = sum(focal_loss(outputs[s][:, :len(CLASSES)], heat_t[s]) for s in levels)
    lb = sum(box_loss(outputs[s][:, len(CLASSES):], box_t[s], mask_t[s])
             for s in levels)
    return lh, lb


def decode(outputs, size: int, conf: float, topk: int, nms_iou: float):
    """Heatmap peaks -> (boxes_xywh_letterbox_normalized, scores, class_ids)."""
    boxes, scores, classes = [], [], []
    for level in sorted(outputs):
        out = outputs[level]
        heat = torch.sigmoid(out[:, :len(CLASSES)])
        box = out[:, len(CLASSES):]
        keep = (F.max_pool2d(heat, 3, stride=1, padding=1) - heat).abs() < 1e-6
        hmax = heat * keep
        flat = hmax.view(hmax.shape[0], len(CLASSES), -1)
        k = min(topk, flat.shape[-1])
        top_scores, top_idx = torch.topk(flat, k, dim=-1)
        for c in range(len(CLASSES)):
            for score, idx in zip(top_scores[0, c], top_idx[0, c]):
                if float(score) < conf:
                    continue
                gy = int(idx) // hmax.shape[-1]
                gx = int(idx) % hmax.shape[-1]
                dx, dy, log_w, log_h = (float(v) for v in box[0, :, gy, gx])
                cx = (gx + dx) * level / size
                cy = (gy + dy) * level / size
                # the encoder writes log sizes, so the decoder must exponentiate;
                # a mismatch here produced plausible scores with boxes ~3x too
                # small, which no threshold could fix
                w = float(np.exp(np.clip(log_w, -6.0, 6.0))) * level / size
                h = float(np.exp(np.clip(log_h, -6.0, 6.0))) * level / size
                if w <= 0 or h <= 0:
                    continue
                boxes.append([cx - w / 2, cy - h / 2, w, h])
                scores.append(float(score))
                classes.append(c)
    if not boxes:
        return np.zeros((0, 4)), np.zeros(0), np.zeros(0, int)
    b = np.array(boxes, np.float64)
    s = np.array(scores, np.float64)
    c = np.array(classes, np.int64)
    keep = nms(b, s, c, nms_iou)
    return b[keep], s[keep], c[keep]


def nms(boxes, scores, classes, iou_threshold=0.5):
    keep_all = []
    for cls in np.unique(classes):
        idx = np.where(classes == cls)[0]
        order = idx[np.argsort(-scores[idx])]
        while order.size:
            i = order[0]
            keep_all.append(int(i))
            if order.size == 1:
                break
            rest = order[1:]
            xx0 = np.maximum(boxes[i, 0], boxes[rest, 0])
            yy0 = np.maximum(boxes[i, 1], boxes[rest, 1])
            xx1 = np.minimum(boxes[i, 0] + boxes[i, 2], boxes[rest, 0] + boxes[rest, 2])
            yy1 = np.minimum(boxes[i, 1] + boxes[i, 3], boxes[rest, 1] + boxes[rest, 3])
            inter = np.maximum(0, xx1 - xx0) * np.maximum(0, yy1 - yy0)
            union = boxes[i, 2] * boxes[i, 3] + boxes[rest, 2] * boxes[rest, 3] - inter
            iou = inter / np.maximum(1e-9, union)
            order = rest[iou <= iou_threshold]
    keep_all.sort()
    return np.array(keep_all, np.int64)


def save_checkpoint(model: Stage4Detector, path, meta: dict) -> dict:
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    torch.save({"state_dict": model.state_dict(), "meta": meta}, str(path))
    meta = dict(meta)
    meta["checkpoint"] = str(path)
    meta["checkpoint_sha256"] = sha256_file(path)
    meta["checkpoint_bytes"] = path.stat().st_size
    meta["parameters"] = model.parameter_counts()
    return meta


def load_checkpoint(approach: str, path, unfreeze_layer4: bool = False):
    """Rebuild the architecture WITHOUT any download, then load trained weights."""
    obj = torch.load(str(path), map_location="cpu", weights_only=False)
    meta = obj.get("meta", {})
    model = Stage4Detector(approach, unfreeze_layer4=unfreeze_layer4,
                           width=int(meta.get("width", 64)), pretrained=False)
    model.load_state_dict(obj["state_dict"])
    model.eval()
    return model, meta
