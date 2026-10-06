"""Object-linked broad-colour sampling for the Stage 3 analysers.

The Stage 3 contract asks for a coarse colour attached to THE RIGHT OBJECT and to
a NAMED REGION of it (`vehicle_body`, `clothing`, `upper_clothing`,
`lower_clothing`), with `unknown` as a valid abstention. This module is that
sampler and nothing else: it takes a decoded BGR frame, one detected box and one
region name, and returns at most ONE dominant label plus the crop that supported
it.

WHAT IT DOES NOT DO, stated because the temptation is real:
  * it never looks at another object, another frame, or the background by
    accident -- the region is a sub-rectangle of THIS box (geometry below);
  * it never invents a colour: a region that is too small, or whose dominant
    bucket does not really dominate, returns `unknown` with the measured share;
  * it does not read filenames, clips ids or expected labels. Pixels in, colour
    out.

THE GEOMETRY is configuration, recorded in every run, not a hidden constant:
  vehicle_body   x 0.18..0.82, y 0.35..0.80   (paint band: below the greenhouse,
                                              above the wheels)
  clothing       x 0.20..0.80, y 0.12..0.88   (whole garment, head excluded)
  upper_clothing x 0.22..0.78, y 0.10..0.45   (torso above the waist)
  lower_clothing x 0.32..0.68, y 0.55..0.92   (narrower than the torso: a bag
                                              carried at the hip sits outside it)
Fractions are of the detected box. The side margins exist because a detector box
around a person usually includes background on both sides, and the lower-clothing
band is narrower still because a bag or case carried at the hip must not supply
the person's colour (measured on WT3-007: a white shopping bag at the hip took
the whole-body lower band before this was narrowed).

THE PALETTE RULE is deliberately coarse, and its thresholds are configuration:
very dark pixels are `black`; low-saturation pixels below 45% brightness are
`dark_gray`; at or above 55% they are `light_gray`, and at or above 80% `white`;
the narrow 45-55% band and any mid-tone hue outside the palette abstain as
`unknown`, because it has no honest coarse name. The rest are placed by hue.
`brown` is a dark, low-value orange band, and `pink` a bright, low-saturation
magenta band, because both are in the contract's label set.
"""
from __future__ import annotations

import math

import cv2
import numpy as np

__all__ = ["REGION_GEOMETRY", "DEFAULT_CONFIG", "color_labels", "dominant_color",
           "region_box", "crop_region", "distribution"]

#: region -> (x0, x1, y0, y1) as fractions of the detected box.
REGION_GEOMETRY = {
    "vehicle_body": (0.18, 0.82, 0.35, 0.80),
    "clothing": (0.20, 0.80, 0.12, 0.88),
    "upper_clothing": (0.22, 0.78, 0.10, 0.45),
    "lower_clothing": (0.32, 0.68, 0.55, 0.92),
}

#: Thresholds of the HSV palette rule. Every value here is recorded in the run's
#: effective configuration, so a reviewer can see exactly what produced a label.
DEFAULT_CONFIG = {
    "black_v_max": 0.16,
    "dark_gray_v_max": 0.45,
    "dark_gray_s_max": 0.50,
    "white_v_min": 0.80,
    "light_gray_v_min": 0.55,
    "gray_s_max": 0.16,
    "min_share": 0.30,          # dominant bucket must really dominate
    "min_pixels": 120,          # else the region is too small to judge
    "brown_v_max": 0.55,
    "brown_s_min": 0.35,
    "pink_s_max": 0.45,
    # Background guard: a strong majority is taken at face value; a weak one is
    # re-tested with the pixels that look like the box's own surroundings removed,
    # because a person's box usually includes some of what is behind them.
    "strong_share": 0.55,
    "reduced_share": 0.55,
    "bg_ring": 0.12,          # thickness of the box's border ring, as a fraction
    "bg_tolerance": 0.18,     # HSV distance under which a pixel "looks like" the ring
    # An object cut off by the frame edge has a truncated region: the pixels that
    # would have decided the colour are not in the recording, so the honest answer
    # is unknown, recorded as `clipped`.
    "min_region_completeness": 0.6,
}


def _hsv(frame_bgr: np.ndarray) -> np.ndarray:
    hsv = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2HSV)
    out = hsv.astype(np.float32)
    out[..., 0] *= 2.0 / 360.0      # OpenCV hue is 0..179 (degrees/2)
    out[..., 1] /= 255.0
    out[..., 2] /= 255.0
    return out


def color_labels(frame_bgr: np.ndarray, config: dict = None) -> np.ndarray:
    """One palette label per pixel of a BGR crop, as a 2-D array of strings."""
    cfg = dict(DEFAULT_CONFIG)
    if config:
        cfg.update(config)
    hsv = _hsv(frame_bgr)
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    labels = np.full(h.shape, "unknown", dtype=object)

    black = v < cfg["black_v_max"]
    dark_gray = (~black) & (v < cfg["dark_gray_v_max"]) & (s < cfg["dark_gray_s_max"])
    gray = (~black) & (~dark_gray) & (s < cfg["gray_s_max"])
    white = gray & (v >= cfg["white_v_min"])
    light_gray = gray & (v >= cfg["light_gray_v_min"]) & (~white)
    other_gray = gray & (~white) & (~light_gray)
    labels[black] = "black"
    labels[dark_gray] = "dark_gray"
    labels[white] = "white"
    labels[light_gray] = "light_gray"
    labels[other_gray] = "unknown"          # mid grey: no honest coarse name

    chromatic = (~black) & (~dark_gray) & (~gray)
    hue = h * 360.0
    red = chromatic & ((hue < 15.0) | (hue >= 345.0))
    orange = chromatic & (hue >= 15.0) & (hue < 45.0)
    yellow = chromatic & (hue >= 45.0) & (hue < 70.0)
    green = chromatic & (hue >= 70.0) & (hue < 165.0)
    cyan = chromatic & (hue >= 165.0) & (hue < 200.0)
    blue = chromatic & (hue >= 200.0) & (hue < 260.0)
    magenta = chromatic & (hue >= 260.0) & (hue < 345.0)
    labels[red] = "red"
    # A dark, saturated orange is what "brown" means at this coarseness.
    labels[orange & (v < cfg["brown_v_max"]) & (s >= cfg["brown_s_min"])] = "brown"
    labels[orange & (labels == "unknown")] = "orange"
    labels[yellow] = "yellow"
    labels[green] = "green"
    labels[cyan] = "unknown"                # not in the contract's palette
    labels[blue] = "blue"
    labels[magenta & (s <= cfg["pink_s_max"]) & (v >= 0.5)] = "pink"
    labels[magenta & (labels == "unknown")] = "unknown"
    return labels


def region_box(bbox_xywh, region: str):
    """The named region of a normalized box, as a normalized box."""
    if region not in REGION_GEOMETRY:
        raise ValueError("unknown colour region %r" % (region,))
    x, y, w, h = (float(v) for v in bbox_xywh)
    fx0, fx1, fy0, fy1 = REGION_GEOMETRY[region]
    return [x + fx0 * w, y + fy0 * h, (fx1 - fx0) * w, (fy1 - fy0) * h]


def crop_region(frame_bgr: np.ndarray, box_xywh):
    """The pixel crop of a normalized box, clamped to the frame, or None."""
    h, w = frame_bgr.shape[:2]
    x, y, bw, bh = (float(v) for v in box_xywh)
    x0 = max(0, min(w - 1, int(round(x * w))))
    y0 = max(0, min(h - 1, int(round(y * h))))
    x1 = max(x0 + 1, min(w, int(round((x + bw) * w))))
    y1 = max(y0 + 1, min(h, int(round((y + bh) * h))))
    if x1 - x0 < 2 or y1 - y0 < 2:
        return None
    return frame_bgr[y0:y1, x0:x1]


def _ring(frame_bgr: np.ndarray, box_xywh, cfg):
    """(labels, mean HSV) of the box's outer ring -- what surrounds the object."""
    h, w = frame_bgr.shape[:2]
    x, y, bw, bh = (float(v) for v in box_xywh)
    x0 = max(0, min(w - 1, int(round(x * w))))
    y0 = max(0, min(h - 1, int(round(y * h))))
    x1 = max(x0 + 1, min(w, int(round((x + bw) * w))))
    y1 = max(y0 + 1, min(h, int(round((y + bh) * h))))
    crop = frame_bgr[y0:y1, x0:x1]
    if crop.size == 0:
        return np.array([], dtype=object), np.zeros(3, np.float32)
    t = max(1, int(round(min(crop.shape[0], crop.shape[1]) * float(cfg["bg_ring"]))))
    mask = np.ones(crop.shape[:2], bool)
    if crop.shape[0] > 2 * t and crop.shape[1] > 2 * t:
        mask[t:-t, t:-t] = False
    hsv = _hsv(crop)
    return color_labels(crop, cfg)[mask], (hsv[mask].mean(axis=0) if mask.any()
                                            else np.zeros(3, np.float32))


def distribution(labels: np.ndarray) -> dict:
    """Share of each palette label in a label array (descending), for the record."""
    if labels.size == 0:
        return {}
    flat = labels.reshape(-1)
    values, counts = np.unique(flat, return_counts=True)
    total = float(flat.size)
    pairs = sorted(zip(values.tolist(), counts.tolist()), key=lambda p: -p[1])
    return {str(k): round(v / total, 6) for k, v in pairs}


def _complete(frame_bgr: np.ndarray, rbox) -> float:
    """How much of the intended region the frame actually contains (0..1)."""
    h, w = frame_bgr.shape[:2]
    x, y, bw, bh = (float(v) for v in rbox)
    want = (bw * w) * (bh * h)
    if want <= 1.0:
        return 0.0
    x0 = max(0, min(w - 1, int(round(x * w))))
    y0 = max(0, min(h - 1, int(round(y * h))))
    x1 = max(x0 + 1, min(w, int(round((x + bw) * w))))
    y1 = max(y0 + 1, min(h, int(round((y + bh) * h))))
    return ((x1 - x0) * (y1 - y0)) / want


def dominant_color(frame_bgr: np.ndarray, box_xywh, region: str,
                   config: dict = None):
    """(label, confidence, region_box, region_crop, distribution).

    `unknown` is returned -- with the measured share as its confidence -- when
      * the region is smaller than `min_pixels`;
      * the object is cut off by the frame edge, so part of the region is not in
        the recording at all (`clipped`) -- recorded, because guessing the missing
        pixels would be exactly the invention this contract forbids;
      * no bucket reaches `min_share`, or the weak-but-leading bucket is
        indistinguishable from the box's own surroundings.
    The confidence of a real label is that bucket's share of the region's pixels;
    it is a coverage measure, not a calibrated probability.
    """
    cfg = dict(DEFAULT_CONFIG)
    if config:
        cfg.update(config)
    rbox = region_box(box_xywh, region)
    if _complete(frame_bgr, rbox) < float(cfg["min_region_completeness"]):
        return "unknown", 0.0, rbox, crop_region(frame_bgr, rbox), {"clipped": 1.0}
    crop = crop_region(frame_bgr, rbox)
    if crop is None:
        return "unknown", 0.0, rbox, None, {}
    labels = color_labels(crop, cfg)
    dist = distribution(labels)
    total = labels.size
    if total < int(cfg["min_pixels"]):
        return "unknown", 0.0, rbox, crop, dist
    best = max(dist.items(), key=lambda kv: kv[1]) if dist else ("unknown", 0.0)
    if best[0] == "unknown" or best[1] < float(cfg["min_share"]):
        return "unknown", float(best[1]), rbox, crop, dist
    if best[1] >= float(cfg["strong_share"]):
        return best[0], float(best[1]), rbox, crop, dist

    # WEAK MAJORITY: re-test with the pixels that look like the surroundings gone.
    # A person's box usually contains some of what is behind them; if the weak
    # leader is the same colour as the box's own border ring, the honest reading is
    # "these pixels do not decide it", and the answer becomes unknown.
    ring_labels, ring_hsv = _ring(frame_bgr, box_xywh, cfg)
    ring_dist = distribution(ring_labels)
    if not ring_dist:
        return "unknown", float(best[1]), rbox, crop, dist
    ring_label, ring_share = max(ring_dist.items(), key=lambda kv: kv[1])
    if ring_label == "unknown" or ring_label != best[0] or ring_share < 0.30:
        return best[0], float(best[1]), rbox, crop, dist
    hsv = _hsv(crop)
    distance = np.abs(hsv[..., 1] - ring_hsv[1]) + np.abs(hsv[..., 2] - ring_hsv[2])
    keep = distance > float(cfg["bg_tolerance"])
    if int(keep.sum()) < int(cfg["min_pixels"]):
        return "unknown", float(best[1]), rbox, crop, dist
    reduced = distribution(labels[keep])
    if not reduced:
        return "unknown", float(best[1]), rbox, crop, dist
    r_label, r_share = max(reduced.items(), key=lambda kv: kv[1])
    if r_label == "unknown" or r_share < float(cfg["reduced_share"]):
        return "unknown", float(r_share), rbox, crop, dist
    return r_label, float(r_share), rbox, crop, dist
