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

print("=== 12. a RECURRING SOURCE folds; anything that moves does not (1.1.0) ===")
# Synthetic detections, not frames: what is under test is the folding, and the
# live case it answers is known exactly -- one streak near the lens at (0.56, 0.15),
# hit every ~11 s for an hour (hiwatch-083bc1df39d1, 2026-09-26 22:00Z).
import math
import shape_observations as so

cfg = Config()
K, M, SPAN = cfg.recur_min_prior, cfg.recur_window_s, cfg.recur_min_span_s


def det(seg, t, cx, cy, area=0.0008, w=0.02, h=0.03, cls="shape_indeterminate"):
    return Observation(segment_id=seg, frame_index=int(t), t_offset_s=t,
                       bbox_x=cx - w / 2, bbox_y=cy - h / 2, bbox_w=w, bbox_h=h,
                       object_count=1, shape_class=cls, shape_confidence=0.6,
                       aspect=h / w, area_frac=area, fill_ratio=0.24)


def feed(hits):
    r = so._Recurrence(cfg)
    rows = []
    for d, t in hits:
        rows += r.offer(d, t)
    return rows + r.close_all()


streak = [(det("s", float(k), 0.56, 0.15), float(k)) for k in range(0, 3600, 11)]
rows = feed(streak)
check(sum(r.recur_count for r in rows) == len(streak),
      "every detection is counted exactly once (the rows' recur_count sums to the hits)",
      f"{sum(r.recur_count for r in rows)} vs {len(streak)}")
check(len(rows) <= math.ceil(SPAN / 11) + 1 + math.ceil(3600 / M) + 1,
      f"the streak's {len(streak)} hits file as {len(rows)} rows (bounded per source)",
      f"{len(rows)} rows")
n_first = next(i for i, r in enumerate(rows) if r.recur_folded)
first = rows[:n_first]
check([(r.recur_folded, r.recur_hits, r.recur_count, r.t_offset_s) for r in first]
      == [(False, i, 1, 11.0 * i) for i in range(math.ceil(SPAN / 11))],
      "a new source's first MINUTE of detections files on its own, at exact times",
      f"{[(r.recur_hits, r.t_offset_s) for r in first]}")
folded = [r for r in rows if r.recur_folded]
check(bool(folded) and all(r.recur_window_s == M and r.recur_hits >= K and r.recur_count >= 1
                           for r in folded),
      "folded rows name themselves: recur_folded, recur_window_s = M, recur_hits >= K")
starts = [r.t_offset_s for r in folded]
check(all(b - a >= M for a, b in zip(starts, starts[1:])),
      "at most one folded row per window, each timed at its OWN first hit", f"{starts}")
check(len(folded) >= math.floor((3600 - SPAN - 11) / M),
      "...and a source that persists keeps filing one per window (it is not swallowed "
      "into a single row for the hour)", f"{len(folded)} folded rows")

walk = [(det("s", float(i), 0.05 + 0.1 * i, 0.5, cls="blob_tall"), float(i)) for i in range(10)]
rows = feed(walk)
check(len(rows) == 10 and all(not r.recur_folded and r.recur_hits == 0 for r in rows),
      "something that MOVES never folds: 10 detections along a path, 10 rows")

# The booth's own case, seen in a crop: two people walking SLOWLY, caught on 1 s
# keyframes at nearly one spot -- K hits within the radius in a few seconds.
stroll = [(det("s", float(i), 0.45 + 0.002 * i, 0.24, area=0.0006, cls="blob_tall"), float(i))
          for i in range(20)]
rows = feed(stroll)
check(len(rows) == 20 and not any(r.recur_folded for r in rows)
      and max(r.recur_hits for r in rows) >= K,
      "people LINGERING at one spot for 20 s are not a source: K+ hits, but under a "
      "minute, so all 20 file (the two walkers on the booth's capture)")

car = det("s", 150.5, 0.56, 0.15, area=0.01, w=0.15, h=0.06, cls="blob_wide")
rows = feed([h for h in streak if h[1] < 300] + [(car, 150.5)])
mine = [r for r in rows if r.area_frac == 0.01]
check(len(mine) == 1 and not mine[0].recur_folded and mine[0].t_offset_s == 150.5,
      "a different-sized blob AT the recurring spot is not folded into it (a car passing "
      "the cobweb files on its own, at its exact time)", f"{mine}")

sparse = [(det("s", float(k), 0.3, 0.3), float(k)) for k in range(0, 3600, 250)]
rows = feed(sparse)
check(len(rows) == len(sparse) and not any(r.recur_folded for r in rows),
      "a spot hit only every 250 s never folds (fewer than K in any window)")


def unit(prefix, hh, mm0=0):
    """12 x 30 s segments of one camera, a streak hit every 5 s, start_time set."""
    out = []
    for i in range(12):
        s = 60 * mm0 + 30 * i
        meta = SegmentMeta(segment_id=f"{prefix}{i}", camera_id="c",
                           start_time=f"2026-09-26T{hh}:{s // 60:02d}:{s % 60:02d}+00:00")
        out.append((meta, [float(t) for t in range(0, 30, 5)]))
    return out


def fake_segment(frames, meta, state, cfg=None, frame_step_s=None):
    obs = [det(meta.segment_id, t, 0.56, 0.15) for t in frames]
    st = so.WindowStats()
    st.observations = len(obs)
    return obs, st


real_segment = so.analyse_segment
so.analyse_segment = fake_segment
try:
    state = AnalyserState(cfg)
    u1 = list(so.analyse_window(iter(unit("a", "22")), state, cfg))
    # Forward, straight after u1 ends (22:06:00): the case where a carried look-back
    # would bite, because u1's last 10 minutes are still inside it. It must run
    # DIRECTLY after u1 -- a unit from another hour in between would age the
    # carried history out and hide exactly the defect this is here to catch.
    u3 = list(so.analyse_window(iter(unit("c", "22", mm0=6)), state, cfg))
    u2 = list(so.analyse_window(iter(unit("b", "21")), state, cfg))   # the hour BEFORE: newest-first
    again = list(so.analyse_window(iter(unit("a", "22")), AnalyserState(cfg), cfg))
    nostart = list(so.analyse_window(iter([(SegmentMeta(segment_id="n", camera_id="c"),
                                            [0.0, 5.0, 10.0, 15.0, 20.0])]), AnalyserState(cfg), cfg))
finally:
    so.analyse_segment = real_segment

check([m.segment_id for m, _, _ in u1] == [f"a{i}" for i in range(12)],
      "analyse_window yields exactly once per segment, in order (the adapter pops one per yield)")
rows1 = [r for _, obs, _ in u1 for r in obs]
check(sum(r.recur_count for r in rows1) == 12 * 6 and sum(s.observations for _, _, s in u1) == len(rows1),
      "a whole unit accounts for every detection, and stats count the rows filed")
tail = [r for r in u1[-1][1] if r.recur_folded]
# hits every 5 s: the first minute (t 0..55, 12 hits) files on its own; t = 60 s is
# the first hit whose prior hits reach back a minute -> segment a2, offset 0.0.
check(len(tail) == 1 and tail[0].segment_id == "a2" and tail[0].t_offset_s == 0.0
      and tail[0].recur_count == 12 * 6 - 12,
      "the fold still open at the end rides the LAST yield, naming its own first hit "
      "(segment a2, 0.0 s), not the last segment", f"{tail}")
rows2 = [r for _, obs, _ in u2 for r in obs]
rows3 = [r for _, obs, _ in u3 for r in obs]
check([(r.recur_folded, r.recur_hits) for r in rows2[:K]] == [(False, i) for i in range(K)]
      and [(r.recur_folded, r.recur_hits) for r in rows3[:K]] == [(False, i) for i in range(K)],
      "NOTHING carries into the next unit, even with the same model state -- the hour "
      "before, or the minutes straight after: its first detections file on their own")
check([r.measurements() for _, obs, _ in again for r in obs] == [r.measurements() for r in rows1],
      "deterministic: the same unit folds to the same rows")
nrows = nostart[0][1]
check(len(nrows) == 5 and all(r.recur_hits is None and r.recur_folded is None for r in nrows)
      and any("no start_time" in n for n in nostart[0][2].notes),
      "no start_time: rows file unfolded, recurrence left UNSET (not 0), and the notes say so")

m = tail[0].measurements()
extra = {k for k in m if k not in Observation.API_COLUMNS}
check({"recur_hits", "recur_count", "recur_window_s", "recur_folded"} <= extra
      and len(extra) <= 24 and all(k == k.lower() and len(k) <= 40 for k in extra),
      "the recurrence fields reach `metrics`, inside the server's caps (<= 24 keys, "
      "lowercase, <= 40 chars)", f"{sorted(extra)}")
check("recur=" in ANALYSER_VERSION, "the version string names the recurrence parameters",
      ANALYSER_VERSION)

print()
print(f"=== {CHECKS[0] - len(FAILS)}/{CHECKS[0]} checks passed ===")
if FAILS:
    print("FAILED:")
    for f in FAILS:
        print("  -", f)
    sys.exit(1)
print("all good")
