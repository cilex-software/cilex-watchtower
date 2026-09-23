#!/usr/bin/env python3
"""Self-test for the A4-A6 analyser. No network, no footage, no RNG.

DETERMINISTIC BY NECESSITY AND BY CHOICE. Smart App Control on this booth blocks
`numpy.random._philox` outright ("Политика управления приложениями заблокировала
этот файл") while permitting numpy and cv2 themselves -- its verdict is per file
hash, so a dependency is not simply allowed or denied. A classifier test wants
reproducible geometry anyway: every scene below is drawn with slices.

Run:  C:\\wt\\labs-venv\\Scripts\\python.exe tools/labs/selftest_shape_observations.py
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np

from shape_observations import (
    ANALYSER_VERSION,
    SHAPE_CLASSES,
    AnalyserState,
    Config,
    Frame,
    Observation,
    SegmentMeta,
    analyse_segment,
    classify,
)

FAILS: list[str] = []
CHECKS = [0]


def check(cond: bool, label: str, detail: str = "") -> None:
    CHECKS[0] += 1
    if cond:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}" + (f"\n          {detail}" if detail else ""))
        FAILS.append(label)


def scene(w: int, h: int) -> np.ndarray:
    """A flat background with fixed texture. No RNG."""
    bg = np.full((h, w), 50, np.uint8)
    bg[::7, ::11] = 56
    bg[::13, ::5] = 46
    return bg


def moving(
    w: int,
    h: int,
    boxes,
    n: int = 60,
    warm: int = 30,
    step: float = 1.0,
) -> list[Frame]:
    """Frames where each box moves. A STATIONARY object is absorbed into the
    background by MOG2 and correctly disappears, so anything meant to be detected
    has to move -- that is the model behaving, not a test artefact."""
    bg = scene(w, h)
    out = []
    for i in range(n):
        f = bg.copy()
        if i >= warm:
            k = i - warm
            for (bx, by, bw, bh, dx, dy) in boxes:
                x = bx + dx * k
                y = by + dy * k
                x = max(0, min(w - bw, x))
                y = max(0, min(h - bh, y))
                f[y : y + bh, x : x + bw] = 205
        out.append(Frame(index=i, t_offset_s=i * step, luma=f))
    return out


def run(frames, meta=None, cfg=None, state=None):
    cfg = cfg or Config()
    st = state or AnalyserState(cfg)
    return analyse_segment(frames, meta or SegmentMeta(segment_id="s1", camera_id="cam1"), st, cfg)


print("=== analyser version ===")
print(" ", ANALYSER_VERSION)
check(
    "objcount=per_frame" in ANALYSER_VERSION,
    "version string states the object_count reading",
    "semantics only recorded in a letter are semantics that get lost",
)

print("=== 1. classify() against known geometry ===")
cfg = Config()
c, k = classify(aspect=2.5, area_frac=0.01, fill_ratio=0.9, n_blobs=1, coherence=None, cfg=cfg)
check(c == "blob_tall", "tall geometry -> blob_tall", f"got {c}")
check(0.5 <= k <= 0.95, "confidence in range", f"got {k}")
c, _ = classify(aspect=0.35, area_frac=0.01, fill_ratio=0.9, n_blobs=1, coherence=None, cfg=cfg)
check(c == "blob_wide", "wide geometry -> blob_wide", f"got {c}")
c, _ = classify(aspect=1.1, area_frac=0.45, fill_ratio=0.9, n_blobs=1, coherence=None, cfg=cfg)
check(c == "blob_large", "large area outranks shape", f"got {c}")
c, _ = classify(aspect=1.05, area_frac=0.004, fill_ratio=0.8, n_blobs=1, coherence=None, cfg=cfg)
check(c == "blob_compact", "small and square -> blob_compact", f"got {c}")
c, _ = classify(aspect=1.15, area_frac=0.10, fill_ratio=0.3, n_blobs=1, coherence=None, cfg=cfg)
check(c == "shape_indeterminate", "non-discriminating -> shape_indeterminate", f"got {c}")

# blob_multi must require MEASURED coherence, per the registry's "correlated motion"
c, _ = classify(aspect=1.2, area_frac=0.01, fill_ratio=0.8, n_blobs=4, coherence=None, cfg=cfg)
check(c != "blob_multi", "4 blobs but coherence unmeasured -> NOT blob_multi", f"got {c}")
c, _ = classify(aspect=1.2, area_frac=0.01, fill_ratio=0.8, n_blobs=4, coherence=0.2, cfg=cfg)
check(c != "blob_multi", "4 blobs with scattered motion -> NOT blob_multi", f"got {c}")
c, _ = classify(aspect=1.2, area_frac=0.01, fill_ratio=0.8, n_blobs=4, coherence=0.95, cfg=cfg)
check(c == "blob_multi", "4 blobs moving together -> blob_multi", f"got {c}")

check(
    all(s in SHAPE_CLASSES for s in
        {classify(a, ar, f, n, co, cfg)[0]
         for a in (0.2, 0.9, 1.0, 1.2, 3.0) for ar in (0.001, 0.05, 0.5)
         for f in (0.2, 0.9) for n in (1, 3) for co in (None, 0.1, 0.9)}),
    "classify() only ever returns registered slugs",
)

print("=== 2. end to end: a tall moving object ===")
obs, st = run(moving(320, 240, [(40, 60, 12, 40, 9, 0)]))
check(len(obs) > 0, "observations produced", f"stats notes={st.notes}")
if obs:
    o = obs[0]
    check(o.shape_class == "blob_tall", "classified blob_tall", f"got {o.shape_class} aspect={o.aspect}")
    check(o.object_count == 1, "object_count == 1", f"got {o.object_count}")
    check(0.0 <= o.bbox_x <= 1.0 and 0.0 <= o.bbox_y <= 1.0, "bbox origin normalised 0..1")
    check(o.bbox_w > 0.0 and o.bbox_h > 0.0, "bbox w/h STRICTLY > 0 (API refuses otherwise)",
          f"w={o.bbox_w} h={o.bbox_h}")
    check(o.bbox_x + o.bbox_w <= 1.0 + 1e-9 and o.bbox_y + o.bbox_h <= 1.0 + 1e-9,
          "bbox stays inside the frame")

print("=== 3. end to end: a wide moving object ===")
obs, _ = run(moving(320, 240, [(30, 90, 48, 14, 7, 0)]))
check(len(obs) > 0 and obs[0].shape_class == "blob_wide",
      "wide object -> blob_wide", f"got {obs[0].shape_class if obs else 'none'}")

print("=== 4. two objects moving TOGETHER -> blob_multi, count 2 ===")
obs, _ = run(moving(320, 240, [(30, 60, 14, 22, 8, 0), (30, 140, 14, 22, 8, 0)]))
got = [o for o in obs if o.object_count >= 2]
check(len(got) > 0, "saw 2+ blobs in a frame", f"counts={[o.object_count for o in obs][:8]}")
check(any(o.shape_class == "blob_multi" for o in got),
      "correlated motion -> blob_multi",
      f"classes={[o.shape_class for o in got][:8]} coh={[o.motion_coherence for o in got][:8]}")

print("=== 5. two objects moving APART -> not blob_multi ===")
obs, _ = run(moving(320, 240, [(150, 60, 14, 22, 9, 0), (150, 140, 14, 22, -9, 0)]))
multi = [o for o in obs if o.shape_class == "blob_multi" and o.object_count >= 2]
check(len(multi) == 0, "divergent motion never claims blob_multi",
      f"coherences={[o.motion_coherence for o in obs if o.object_count >= 2][:8]}")

print("=== 6. object_class is NEVER set ===")
obs, _ = run(moving(320, 240, [(40, 60, 12, 40, 9, 0)]))
fields = set(Observation.__dataclass_fields__.keys())
check("object_class" not in fields, "no object_class field on Observation")
check("confidence" not in fields, "no bare `confidence` field (that is object_class's)")
if obs:
    p = obs[0].as_payload()
    check("object_class" not in p and "confidence" not in p,
          "payload carries neither object_class nor its confidence", f"keys={sorted(p)}")
    check("shape_confidence" in p, "payload DOES carry shape_confidence (else 422)")

print("=== 7. quiet scene -> zero observations, no crash ===")
bg = scene(320, 240)
quiet = [Frame(index=i, t_offset_s=float(i), luma=bg.copy()) for i in range(60)]
obs, st = run(quiet)
check(len(obs) == 0, "a quiet window yields no observations", f"got {len(obs)}")
check(st.frames_seen == 60, "all frames were seen", f"{st.frames_seen}")
print(f"        (an empty result is still a RESULT the worker must submit: "
      f"'it was quiet' has to differ from 'nobody looked')")

print("=== 8. MOG2 history is derived per camera from the frame step ===")
s = AnalyserState(Config())
check(s.calibrate(1.0) == 100, "1.00 s step (GOP 15) -> history 100 frames", f"{s.calibrate(1.0)}")
s = AnalyserState(Config())
check(s.calibrate(3.31) == 30, "3.31 s step (GOP 50) -> history 30 frames", f"{s.calibrate(3.31)}")
s = AnalyserState(Config())
check(s.calibrate(1.0 / 15) == 1500, "full rate (0.067 s) -> history 1500 frames",
      f"{s.calibrate(1.0/15)}")
print("        3.3x fewer frames for the same 100 s of scene memory -- which is exactly")
print("        why a single history constant is wrong on a fleet with mixed GOP.")
s = AnalyserState(Config())
h = s.calibrate(None)
check(h >= 12, "no timestamps -> still a usable history, not a crash", f"{h}")

print("=== 9. nullable metadata does not crash (codec/width/height are nullable) ===")
m = SegmentMeta.from_api({"segment_id": "x", "camera_id": "c", "codec": "unknown",
                          "width": None, "height": None, "duration_s": None})
check(m.codec is None, "codec 'unknown' normalised to None", f"{m.codec}")
check(m.width is None and m.height is None, "null width/height preserved as None")
obs, st = run(moving(320, 240, [(40, 60, 12, 40, 9, 0)]), meta=m)
check(len(obs) > 0, "analyses fine with fully null metadata", f"notes={st.notes}")
m2 = SegmentMeta.from_api({"segment_id": "y", "duration_s": "4.0", "width": "640"})
check(m2.duration_s == 4.0 and m2.width == 640,
      "4-second segment metadata parses (they exist, alongside 30 s)")

print("=== 10a. the FIRST segment is not a reset ===")
state = AnalyserState(Config())
_, s0 = run(moving(320, 240, [(40, 60, 12, 40, 9, 0)]), state=state)
check(s0.model_resets == 0,
      "creating the model on frame 1 is not counted as a reset",
      f"got {s0.model_resets} -- a health signal that fires on every healthy start is useless")

print("=== 10. a resolution change mid-window resets the model ===")
a = moving(320, 240, [(40, 60, 12, 40, 9, 0)], n=45, warm=30)
b = moving(160, 120, [(20, 30, 6, 20, 4, 0)], n=45, warm=30)
for i, f in enumerate(b):
    b[i] = Frame(index=45 + i, t_offset_s=float(45 + i), luma=f.luma)
state = AnalyserState(Config())
_, st = run(a + b, state=state)
check(st.model_resets == 1, "exactly one reset recorded on frame-size change",
      f"resets={st.model_resets}")
check(len(st.resolutions) == 2, "both resolutions recorded", f"{st.resolutions}")
check(any("resolution changed" in n for n in st.notes), "the change is in the notes",
      f"{st.notes}")

print("=== 11. the model carries ACROSS segments (it cannot converge inside one) ===")
state = AnalyserState(Config())
frames = moving(320, 240, [(30, 60, 12, 40, 9, 0)], n=30, warm=0, step=1.0)
o1, s1 = analyse_segment(frames, SegmentMeta(segment_id="a", camera_id="c"), state)
frames2 = [Frame(index=30 + i, t_offset_s=float(30 + i), luma=f.luma)
           for i, f in enumerate(moving(320, 240, [(30, 60, 12, 40, 9, 0)], n=30, warm=0))]
o2, s2 = analyse_segment(frames2, SegmentMeta(segment_id="b", camera_id="c"), state)
check(s2.model_resets == 0, "second segment reuses the model, no reset", f"{s2.model_resets}")
check(state.warm_frames == 60, "warm-up accumulated across both segments",
      f"{state.warm_frames}")
check(all(o.segment_id == "b" for o in o2), "observations attributed to their own segment")

print()
print(f"=== {CHECKS[0] - len(FAILS)}/{CHECKS[0]} checks passed ===")
if FAILS:
    print("FAILED:")
    for f in FAILS:
        print("  -", f)
    sys.exit(1)
print("all good")
