#!/usr/bin/env python3
"""R1 geometry regression checks: every expectation is calculated BY HAND.

The rule this file follows (prompt §2): "A forward/inverse round trip alone is
insufficient: two wrong transforms can cancel." So the expected numbers below are
written out independently — derived from source pixel geometry on paper — and the
functions under test have to agree with them. The suite also contains an explicit
check that the R0 combination *fails*, so reintroducing it cannot pass silently, and
an accounting of why any object target is dropped (legitimate augmentation clipping
vs a mapping error).
"""
from __future__ import annotations

import json
import pathlib
import random
import sys

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "labs"))

import stage4_data as DATA      # noqa: E402
import stage4_model as MODEL    # noqa: E402

CACHE = ROOT / "build" / "stage4" / "cache256"
PASS, FAIL = [], []


def check(name, condition, detail=""):
    (PASS if condition else FAIL).append(name)
    print("%-5s %s%s" % ("PASS" if condition else "FAIL", name,
                         ("  [%s]" % detail) if detail and not condition else ""))


def approx(a, b, tol=1e-9):
    return abs(float(a) - float(b)) <= tol


def main() -> int:
    # ---------------------------------------------------------------- padding
    # 1920x1080 into 256: scale 256/1920 = 0.133333..., the image becomes 256x144,
    # so 56 px of padding top and bottom. A source box at (0.25, 0.5) of size
    # (0.1, 0.2) is at pixels (480, 540) sized (192, 216).
    t = DATA.letterbox_transform(1920, 1080, 256)
    check("landscape padding is the arithmetic value (scale 0.133333, pad_y 56)",
          approx(t["scale"], 256 / 1920) and approx(t["pad_y"], 56.0)
          and approx(t["pad_x"], 0.0), json.dumps(t))
    got = DATA.boxes_to_model_frame([[0.25, 0.5, 0.1, 0.2]], t)[0]
    # by hand: x = (480*0.133333 + 0)/256 = 0.25
    #          y = (540*0.133333 + 56)/256 = 0.5
    #          w = 192*0.133333/256       = 0.1
    #          h = 216*0.133333/256       = 0.1125
    check("landscape box maps to the hand-computed coordinates",
          all(approx(g, e, 1e-9) for g, e in zip(got, [0.25, 0.5, 0.1, 0.1125])),
          str(got))

    # 1080x1920 into 256: the padding is horizontal, and the numbers mirror.
    t2 = DATA.letterbox_transform(1080, 1920, 256)
    got2 = DATA.boxes_to_model_frame([[0.5, 0.25, 0.2, 0.1]], t2)[0]
    # by hand: x = (540*0.133333 + 56)/256 = 0.5  ; y = (480*0.133333)/256 = 0.25
    #          w = 0.2*1080*0.133333/256    = 0.1125   (the width is scaled too -- the
    #          first version of this expectation forgot that and was simply wrong)
    #          h = 0.1*1920*0.133333/256    = 0.1
    check("portrait box maps to the hand-computed coordinates",
          all(approx(g, e, 1e-9) for g, e in zip(got2, [0.5, 0.25, 0.1125, 0.1])),
          str(got2))

    # ---------------------------------------------------------------- resize
    # The invariant R0 broke: letterboxing at 384 and then resizing the whole canvas
    # to 256 leaves the NORMALIZED box unchanged.
    boxes = [[0.25, 0.5, 0.1, 0.2], [0.0, 0.0, 1.0, 1.0], [0.9, 0.1, 0.1, 0.05]]
    for src_w, src_h in ((1920, 1080), (2560, 1440), (1080, 1920), (640, 480)):
        t384 = DATA.letterbox_transform(src_w, src_h, 384)
        t256 = DATA.letterbox_transform(src_w, src_h, 256)
        a = DATA.boxes_to_model_frame(boxes, t384)
        b = DATA.boxes_to_model_frame(boxes, t256)
        check("canvas resize %dx%d keeps normalized boxes identical" % (src_w, src_h),
              np.abs(a - b).max() < 1e-12, "max diff %.2e" % float(np.abs(a - b).max()))

    # ------------------------------------------------- the R0 defect must fail
    r0_shape = {"size": 256, "src_w": 2560, "src_h": 1440, "scale": 0.15,
                "pad_x": 0.0, "pad_y": 84.0}          # 384 geometry, 256 divisor
    raised = False
    try:
        DATA.validate_transform(r0_shape)
    except ValueError:
        raised = True
    check("the R0 cache-384/model-256 geometry is REJECTED, not silently used", raised)
    # and its error, computed by hand, is exactly cache/model = 1.5 on every axis
    t_r0 = DATA.letterbox_transform(2560, 1440, 384)
    correct = DATA.boxes_to_model_frame([[0.40469, 0.10556, 0.02656, 0.11667]],
                                        DATA.letterbox_transform(2560, 1440, 256))[0]
    # the R0 formula: (x*src*scale384 + pad384) / 256
    bx = [0.40469, 0.10556, 0.02656, 0.11667]
    r0 = [((bx[0] * 2560 * t_r0["scale"]) + t_r0["pad_x"]) / 256,
          ((bx[1] * 1440 * t_r0["scale"]) + t_r0["pad_y"]) / 256,
          (bx[2] * 2560 * t_r0["scale"]) / 256,
          (bx[3] * 1440 * t_r0["scale"]) / 256]
    ratios = [r / c for r, c in zip(r0, correct)]
    check("the R0 error is exactly 384/256 = 1.5 on every axis",
          all(approx(r, 1.5, 1e-9) for r in ratios), str(ratios))
    # the consequence: the encoded cell moves, and a third of the set left the grid
    off = (r0[0] + r0[2] / 2) * 256 / 4 - (correct[0] + correct[2] / 2) * 256 / 4
    # analytically the displacement is 0.5 * centre_cell: the centre moves by half of
    # its own coordinate, so a box in the middle of a 64-cell grid lands ~16 cells
    # away and one near the edge rather less. The S4-001 example measured 16.7 cells.
    centre_cells = (correct[0] + correct[2] / 2) * 256 / 4
    check("the R0 error displaces the centre by half its own distance from the origin",
          approx(abs(off), 0.5 * centre_cells, 1e-6) and abs(off) > 10.0,
          "%.1f cells moved, centre at %.1f" % (float(off), float(centre_cells)))

    # ---------------------------------------------------------- augmentation
    img = np.zeros((64, 64, 3), np.uint8)
    box = np.array([[0.25, 0.25, 0.2, 0.2]])

    flipped, fbox, _keep = DATA.augment(img, box.copy(), random.Random(1),
                                        scale_range=(1.0, 1.0), translate=0.0,
                                        brightness=0.0, contrast=0.0, flip=True)
    # a flip maps x -> 1 - (x + w); Random(1).random() < 0.5 decides, so assert the
    # mapping only when the flip actually happened.
    if len(fbox) and fbox[0][0] > box[0][0]:      # flipped
        check("flip maps x to 1-(x+w) exactly",
              approx(fbox[0][0], 1.0 - (box[0][0] + box[0][2])) and
              approx(fbox[0][2], box[0][2]))
    else:
        check("flip maps x to 1-(x+w) exactly", len(fbox) == 1 and approx(fbox[0][0], 0.25),
              str(fbox))

    _t, tbox, _k = DATA.augment(img, box.copy(), random.Random(2),
                                scale_range=(1.0, 1.0), translate=0.06,
                                brightness=0.0, contrast=0.0, flip=False)
    # a translate adds dx to x and leaves the size alone; dx is in [-0.06, 0.06]
    check("translation shifts x by the applied dx and keeps the size",
          len(tbox) == 1 and abs(tbox[0][2] - 0.2) < 1e-9
          and abs(tbox[0][0] - 0.25) <= 0.06 + 1e-9, str(tbox))

    _t2, sbox, _k2 = DATA.augment(img, box.copy(), random.Random(3),
                                  scale_range=(0.5, 0.5), translate=0.0,
                                  brightness=0.0, contrast=0.0, flip=False)
    # a centred 0.5x zoom keeps the centre and halves the size:
    # centre 0.35 -> 0.35, size 0.2 -> 0.1, so x = 0.30
    # a centred 0.5x zoom maps the centre c -> 0.5c + 0.25 and the size -> 0.5*size.
    # For c = 0.35: centre 0.425, size 0.1, so x = 0.375. (The first version of this
    # expectation used 0.25*0.5 = 0.125 for the centre and was simply wrong.)
    check("a 0.5x zoom maps the centre to 0.5c+0.25 and halves the size",
          len(sbox) == 1 and approx(sbox[0][0], 0.375, 1e-9) and approx(sbox[0][2], 0.1, 1e-9),
          str(sbox))

    # clipping: a box pushed out of the frame is dropped by the keep mask
    outside = np.array([[0.98, 0.5, 0.2, 0.2]])
    _t3, cbox, keep = DATA.augment(img, outside.copy(), random.Random(4),
                                   scale_range=(1.0, 1.0), translate=0.06,
                                   brightness=0.0, contrast=0.0, flip=False)
    # The augmenter CLIPS to the frame and keeps the box while any of it remains:
    # that is legitimate augmentation clipping (the visible extent shrinks), not a
    # mapping error, and it can never be confused with one because a mapping error
    # leaves the size alone and moves the centre off the grid.
    check("a box partly outside the frame is clipped to the frame, not silently moved",
          len(cbox) == 1 and float(cbox[0][0] + cbox[0][2]) <= 1.0 + 1e-9
          and approx(cbox[0][3], 0.2, 1e-9)
          and cbox[0][2] < 0.2,
          "boxes=%s keep=%s" % (cbox.tolist(), None if keep is None else keep.tolist()))

    # an object ON the frame edge stays inside after padding: it must be encoded,
    # not dropped (the R0 error is what pushed such objects off the grid)
    t_edge = DATA.letterbox_transform(1920, 1080, 256)
    edge_box = DATA.boxes_to_model_frame([[0.995, 0.02, 0.005, 0.96]], t_edge)
    stats = {}
    heat, _b, _m = MODEL.make_targets(edge_box, np.array([0]), 256, stats=stats)
    check("an object touching the frame edge is encoded, not dropped",
          stats["encoded"] == 1 and stats["off_grid"] == 0, json.dumps(stats))

    # ------------------------------------------------- real cache: cell audit
    entries = json.loads((CACHE / "entries.json").read_text())
    worst_cells = 0.0
    mapped = 0
    for e in list(entries.values()):
        for ob in e["objects"]:
            x, y, w, h = ob["bbox_xywh"]
            m = DATA.boxes_to_model_frame([[x, y, w, h]], e["transform"])[0]
            # the cell the encoder will use, and the cell by hand from source pixels
            cell = ((m[0] + m[2] / 2) * 256 / 4, (m[1] + m[3] / 2) * 256 / 4)
            s = e["transform"]["scale"]
            hand = (((x * e["src_w"] + w * e["src_w"] / 2) * s
                     + e["transform"]["pad_x"]) / 256 * 256 / 4,
                    ((y * e["src_h"] + h * e["src_h"] / 2) * s
                     + e["transform"]["pad_y"]) / 256 * 256 / 4)
            worst_cells = max(worst_cells, abs(cell[0] - hand[0]), abs(cell[1] - hand[1]))
            mapped += 1
    check("all %d cache objects encode to the hand-computed cell" % mapped,
          worst_cells < 1e-9, "worst %.2e cells" % worst_cells)

    # ------------------------------------------------- drop accounting on real data
    stats = {}
    clipped = 0
    for e in list(entries.values()):
        boxes = np.array([o["bbox_xywh"] for o in e["objects"]], np.float64).reshape(-1, 4)
        classes = np.array([DATA.CLASS_ID[o["class"]] for o in e["objects"]], np.int64)
        if not boxes.size:
            continue
        m = DATA.boxes_to_model_frame(boxes, e["transform"])
        MODEL.make_targets(m, classes, 256, stats=stats)
    check("no object in the real cache is dropped for a mapping reason",
          stats.get("off_grid", 0) == 0,
          json.dumps({k: stats.get(k) for k in ("objects", "encoded", "off_grid",
                                                "outside_frame")}))
    check("the drop accounting adds up (encoded + outside + off_grid == objects)",
          stats["encoded"] + stats["outside_frame"] + stats["off_grid"]
          == stats["objects"],
          json.dumps(stats))

    print("\n%d PASS, %d FAIL" % (len(PASS), len(FAIL)))
    print("drop accounting over the whole cache: %s"
          % json.dumps({k: stats.get(k) for k in ("objects", "encoded", "off_grid",
                                                  "outside_frame")}))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
