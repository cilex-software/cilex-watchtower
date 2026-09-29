#!/usr/bin/env python3
"""Self-test for V1 object_profile. No network, no footage, no RNG.

Two halves:
  1. THE COLOUR RULE on hand-built views (exact: no background model in the way): bands,
     shadows, a second colour, every gate, unknown, and Colour's thresholds used unchanged.
  2. THE WIRING through shape_observations.analyse_window on synthetic 4:2:0 frames: the
     observer sees every frame, a passage keeps its largest detection's view, and the rows
     blob_geometry files are identical with and without an observer.

Run:  python3 tools/labs/selftest_object_profile.py
"""
from __future__ import annotations

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cv2
import numpy as np

import labs_colour_histogram as C
import object_profile as op
import shape_observations as so

FAILS: list[str] = []
CHECKS = [0]


def check(cond: bool, label: str, detail: str = "") -> None:
    CHECKS[0] += 1
    if cond:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}" + (f"\n          {detail}" if detail else ""))
        FAILS.append(label)


def planes(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """RGB (H, W, 3), H and W even, to full-range BT.709 4:2:0 planes, as the cameras deliver."""
    ycc = C.rgb_to_ycbcr(rgb.astype(np.float32))
    y = np.clip(np.rint(ycc[..., 0]), 0, 255).astype(np.uint8)
    h, w = y.shape
    u = np.clip(np.rint(ycc[..., 1].reshape(h // 2, 2, w // 2, 2).mean((1, 3))), 0, 255).astype(np.uint8)
    v = np.clip(np.rint(ycc[..., 2].reshape(h // 2, 2, w // 2, 2).mean((1, 3))), 0, 255).astype(np.uint8)
    return y, u, v


def view(obj: np.ndarray, mask: np.ndarray, bg_rgb=(120, 120, 120), frame=(640, 360),
         scene_chroma=5.0, bg_chroma=4.0, bg=True) -> op.View:
    """A view of a crop `obj` (RGB), its blob `mask` (bool, same size) and a flat background."""
    y, u, v = planes(obj)
    h, w = y.shape
    b = None
    if bg:
        by, bu, bv = planes(np.broadcast_to(np.array(bg_rgb, np.uint8), (h, w, 3)))
        b = np.stack([cv2.resize(by, (w // 2, h // 2), interpolation=cv2.INTER_AREA), bu, bv], -1).astype(np.float32)
    return op.View(segment_id="s", t_offset_s=0.0, frame_w=frame[0], frame_h=frame[1],
                   x0=0, y0=0, x1=w, y1=h, bx=0, by=0, bw=w, bh=h, y=y, u=u, v=v, mask=mask,
                   bg=b, bg_frames=24 if bg else 0, scene_chroma=scene_chroma, bg_chroma=bg_chroma)


GREY = (120, 120, 120)


def car(w=120, h=60, body=(200, 30, 30), windows=(25, 25, 30), wheels=(15, 15, 15), win=0.25, whl=0.2):
    """A side-on car: dark glass on top, its body, black wheels at the bottom; the blob is all of it."""
    img = np.empty((h, w, 3), np.uint8)
    img[:] = body
    img[: int(h * win)] = windows
    img[h - int(h * whl):] = wheels
    return img, np.ones((h, w), bool)


print("=== 0. Colour's thresholds, used unchanged ===")
check(op.DEFAULT.colour is C.DEFAULT, "object_profile's colour config IS Colour's default, not a copy")
check(op.VERSION == "op-1" and op.ANALYZER == "object_profile", "slug and version")

print("=== 1. the colour rule ===")
img, m = car()
r0 = op.colour_of(view(img, m), top_band=0.0, bottom_band=0.0)
r = op.colour_of(view(img, m))
check(r.get("colour_1") == "red" and r["colour_1_share"] > 0.9,
      "a red car with dark glass and black wheels reads red with the default bands",
      f"got {r.get('colour_1')} {r.get('colour_1_share')}")
check(r0.get("colour_1_share", 1.0) < r["colour_1_share"] and r0["shares"].get("black", 0) > 0.2,
      "without bands the glass and wheels vote black (the pooling failure Colour describes)",
      f"no bands: {r0.get('shares')}")
check(r["band_px"] > 0 and r["body_px"] + r["band_px"] <= r["eroded_px"], "band pixels counted, and accounted",
      str({k: r.get(k) for k in ("eroded_px", "band_px", "body_px")}))

# a shadow in the blob: the background's chroma at half its luma, beside the car
img, m = car(body=(30, 60, 200))
wide = np.zeros((60, 180, 3), np.uint8)
wide[:] = GREY
wide[:, :120] = img
wide[30:, 120:] = (60, 60, 60)          # the shadow on the paving: GREY at 0.5x, no chroma
mask = np.zeros((60, 180), bool)
mask[:, :120] = True
mask[30:, 120:] = True
r = op.colour_of(view(wide, mask))
check(r.get("illum_px", 0) >= 0.8 * (30 * 60 / 4) * 0.5 and r.get("colour_1") == "blue"
      and r["shares"].get("black", 0) < 0.10,
      "a shadow on the background is removed as illumination change: the car stays blue, the shadow's black goes",
      str({k: r.get(k) for k in ("illum_px", "colour_1", "shares")}))
r_nobg = op.colour_of(view(wide, mask, bg=False))
check("illum_px" not in r_nobg and r_nobg["shares"].get("black", 0) > 0.15,
      "without a background model no shadow removal is claimed, and the shadow votes black",
      str(r_nobg.get("shares")))

# the blob's edge mixes the thing with what is behind it: a ring the erosion must take off
ring = np.empty((100, 160, 3), np.uint8)
ring[:] = GREY
ring[20:80, 20:140] = (235, 235, 235)    # a 2 px white fringe (one chroma sample) ...
ring[22:78, 22:138] = (200, 30, 30)      # ... around a red body
rm = np.zeros((100, 160), bool)
rm[20:80, 20:140] = True
r = op.colour_of(view(ring, rm))
check(r.get("colour_1") == "red" and r["shares"].get("white", 0) < 0.01 and r["eroded_px"] < r["blob_px"],
      "the 3x3 erosion takes the blob's edge ring off (a white fringe does not vote)",
      str({k: r.get(k) for k in ("blob_px", "eroded_px", "shares")}))

# a white van with a blue stripe
van = np.empty((80, 160, 3), np.uint8)
van[:] = (235, 235, 235)
van[36:56] = (30, 60, 200)
vm = np.ones((80, 160), bool)
r = op.colour_of(view(van, vm, bg_rgb=(90, 90, 90)))
check(r.get("colour_1") == "white" and r.get("colour_2") == "blue",
      "a white van with a blue stripe: white, then blue", str({k: r.get(k) for k in ("shares", "colour_1", "colour_2")}))
r = op.colour_of(view(van, vm, bg_rgb=(90, 90, 90)), second_share=0.6)
check("colour_2" not in r, "no second colour below second_share")

print("=== 2. gates ===")
img, m = car()
r = op.colour_of(view(img, m, scene_chroma=0.0))
check(r.get("colour_gate") == "ir" and "colour_1" not in r, "scene chroma at the IR cut: gate ir, no colour")
r = op.colour_of(view(img, m, scene_chroma=C.DEFAULT.ir_chroma_max + 0.01))
check(r.get("colour_gate") is None, "just above the IR cut: not gated")
r = op.colour_of(view(img, m, bg_chroma=C.DEFAULT.cast_chroma_min))
check(r.get("colour_gate") == "light_cast" and "colour_1" not in r and "colour_1_share" not in r,
      "background lit chroma at the cast cut: gate light_cast, no colour and no share", str(r))
check("chroma_mean" in r and "shares" in r, "a cast-gated row keeps its evidence")
small, sm = car(w=24, h=12)
r = op.colour_of(view(small, sm, frame=(1280, 720)))
check(r.get("colour_gate") == "too_small" and r["body_px"] > 0,
      "a real body under min_region_frac of the frame: too_small", str({k: r.get(k) for k in ("colour_gate", "body_px")}))
grey_obj = np.empty((60, 120, 3), np.uint8)
grey_obj[:] = (96, 96, 96)               # the background's chroma at 0.8x its luma
r = op.colour_of(view(grey_obj, np.ones((60, 120), bool)))
check(r.get("colour_gate") == "no_body_pixels" and r["body_px"] == 0,
      "grey on grey is all 'illumination change' (Colour's documented cost): no_body_pixels", str(r))

print("=== 3. unknown and other ===")
patch = np.empty((80, 160, 3), np.uint8)
cols = [(200, 30, 30), (30, 60, 200), (30, 160, 40), (230, 210, 20)]
for i, cc in enumerate(cols):
    patch[:, i * 40:(i + 1) * 40] = cc
r = op.colour_of(view(patch, np.ones((80, 160), bool)))
check(r.get("colour_1") == "unknown" and "colour_2" not in r,
      "four colours of ~25% each: colour_1 unknown, and no second colour", str(r.get("shares")))
purple = np.empty((60, 120, 3), np.uint8)
purple[:] = (140, 40, 200)
r = op.colour_of(view(purple, np.ones((60, 120), bool)))
check(r.get("colour_1") == "unknown" and r["other_share"] > 0.9, "purple is Colour's 'other': unknown, not forced",
      str(r.get("shares")))

print("=== 4. thumbnail and key ===")
yy = np.arange(480 * 720, dtype=np.uint32)
noise = ((yy * 2654435761) >> 13 & 255).astype(np.uint8).reshape(480, 720)
rgb = np.stack([noise, noise[::-1], noise[:, ::-1]], -1)
jpg = op.thumbnail(view(rgb, np.ones((480, 720), bool)))
im = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR)
check(len(jpg) <= 32 * 1024 and max(im.shape[:2]) <= 320, "noise at 720x480: a JPEG of <= 32 KB, longest side <= 320",
      f"{len(jpg)} bytes, {im.shape}")
img, m = car(w=40, h=30)
im = cv2.imdecode(np.frombuffer(op.thumbnail(view(img, m)), np.uint8), cv2.IMREAD_COLOR)
check(im.shape[:2] == (30, 40), "a small crop is not enlarged", str(im.shape))
check(abs(int(im[15, 20, 2]) - 200) < 25 and int(im[15, 20, 0]) < 70, "the thumbnail's colours are the crop's (red body)",
      str(im[15, 20]))
yy = np.arange(240 * 320, dtype=np.uint32)
noise = ((yy * 2654435761) >> 13 & 255).astype(np.uint8).reshape(240, 320)
jpg = op.thumbnail(view(np.stack([noise, noise[::-1], noise[:, ::-1]], -1), np.ones((240, 320), bool)))
check(len(jpg) <= 32 * 1024, "noise at 320x240 (53 KB at quality 88): the ladder brings it under 32 KB",
      f"{len(jpg)} bytes")
taken: set[str] = set()
keys = [op.thumb_key(ms, taken) for ms in (0, 1234, 1234, 3_599_999, 1234)]
check(all(re.fullmatch(r"[a-z0-9-]{1,40}", k) for k in keys) and len(set(keys)) == len(keys),
      "keys match [a-z0-9-]{1,40} and stay unique on a collision", str(keys))

print("=== 5. the wiring through analyse_window ===")
W_, H_ = 320, 180


def frames(n=70, warm=30, step=1.0, planes_on=True):
    base = np.empty((H_, W_, 3), np.uint8)
    base[:] = (150, 150, 150)
    base[::7, ::11] = (160, 160, 160)
    out = []
    for i in range(n):
        f = base.copy()
        if i >= warm:
            k = i - warm
            x = 10 + 6 * k
            w = 40 + (k if k < 12 else 24 - k if k < 24 else 0)       # grows, then shrinks
            if x + w < W_:
                f[80:110, x:x + w] = (220, 20, 20)
        y, u, v = planes(f)
        out.append(so.Frame(index=i, t_offset_s=i * step, luma=y,
                            u=u if planes_on else None, v=v if planes_on else None))
    return out


def unit(observer):
    cfg = so.Config()
    meta = so.SegmentMeta(segment_id="seg-1", camera_id="cam-1", start_time="2026-09-28T12:00:00+00:00")
    rows = []
    for _m, obs, _s in so.analyse_window([(meta, frames())], so.AnalyserState(cfg), cfg, observer=observer):
        rows.extend(obs)
    return rows


obsv = op.Observer()
with_obs = unit(obsv)
without = unit(None)
check(len(with_obs) >= 1, "the moving car is filed", f"{len(with_obs)} rows")
check([r.measurements() for r in with_obs] == [r.measurements() for r in without],
      "blob_geometry's rows are IDENTICAL with and without an observer")
check(all("view" not in r.measurements() for r in with_obs), "a view is never a measurement")
check(obsv.frames == 70, "the observer saw every frame, warm-up included", f"{obsv.frames}")
row = max(with_obs, key=lambda r: r.recur_count or 1)
vw = row.view
check(vw is not None and (vw.bw, vw.bh) == (round(row.bbox_w * W_), round(row.bbox_h * H_)),
      "the passage's view is its LARGEST detection's (the row's own box)",
      f"view {None if vw is None else (vw.bw, vw.bh)}, row {(row.bbox_w * W_, row.bbox_h * H_)}")
res = op.colour_of(vw) if vw is not None else {}
check(res.get("colour_1") == "red", "and that view reads red", str(res))
check(vw is not None and vw.bg is not None and vw.bg_frames == op.DEFAULT.ring,
      "its background is the median of a full ring", f"{None if vw is None else vw.bg_frames}")
try:
    op.Observer().frame(frames(n=1, planes_on=False)[0])
    check(False, "a frame without U and V planes is refused")
except ValueError:
    check(True, "a frame without U and V planes is refused")

print()
print(f"=== {CHECKS[0] - len(FAILS)}/{CHECKS[0]} checks passed ===")
if FAILS:
    print("FAILED:", *FAILS, sep="\n  ")
    sys.exit(1)
print("all good")
