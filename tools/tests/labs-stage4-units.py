#!/usr/bin/env python3
"""Stage 4 unit checks: colour formula, size policy, geometry, model, filters,
schedule validation and the "no YOLO, no annotation reads" rules.

Hermetic wherever it can be: the published CIEDE2000 pairs, synthetic images and
synthetic heatmaps, so a failure here means the code is wrong, not that a model
was weak. Model construction checks never download anything.
"""
from __future__ import annotations

import ast
import json
import os
import pathlib
import sys
import tempfile

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "labs"))

import stage4_colour as COLOUR      # noqa: E402
import stage4_data as DATA          # noqa: E402
import stage4_filters as FILTERS    # noqa: E402
import stage4_model as MODEL        # noqa: E402
import stage4_evaluate as EV        # noqa: E402

FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures" / "stage4"
PASS, FAIL = [], []


def check(name, condition, detail=""):
    (PASS if condition else FAIL).append(name)
    print("%-5s %s%s" % ("PASS" if condition else "FAIL", name,
                         ("  [%s]" % detail) if detail and not condition else ""))


def main() -> int:
    # ---- 1. CIEDE2000 against the published pairs --------------------------------
    text = (FIXTURES / "ciede2000testdata.txt").read_text().splitlines()
    rows = [[float(v) for v in line.split()] for line in text if line.strip()][1:]
    worst = 0.0
    for r in rows:
        worst = max(worst, abs(COLOUR.delta_e_2000(r[0:3], r[3:6]) - r[6]))
    check("CIEDE2000 matches all %d published pairs (max |error| %.1e < 1e-3)"
          % (len(rows), worst), len(rows) >= 30 and worst < 1e-3, "worst=%g" % worst)
    check("CIEDE2000 identity is 0",
          COLOUR.delta_e_2000([50, 20, -30], [50, 20, -30]) == 0.0)
    check("CIEDE2000 is symmetric",
          all(abs(COLOUR.delta_e_2000(r[0:3], r[3:6]) - COLOUR.delta_e_2000(r[3:6], r[0:3]))
              < 1e-9 for r in rows))

    # ---- 2. sRGB <-> Lab --------------------------------------------------------
    grid = [(r, g, b) for r in (0, 40, 128, 200, 255) for g in (0, 90, 180, 255)
            for b in (0, 60, 170, 255)]
    bad = [c for c in grid if COLOUR.lab_to_srgb(COLOUR.srgb_to_lab(c)) != c]
    check("sRGB->Lab->sRGB round-trips exactly on %d colours" % len(grid), not bad,
          "bad=%s" % bad[:3])
    check("white is L*=100",
          abs(COLOUR.srgb_to_lab((255, 255, 255))[0] - 100.0) < 0.01)
    check("black is L*=0", COLOUR.srgb_to_lab((0, 0, 0))[0] == 0.0)

    # ---- 3. broad labels -------------------------------------------------------
    expect = {(0, 0, 0): "black", (70, 70, 70): "dark_gray", (170, 170, 170): "light_gray",
              (255, 255, 255): "white"}
    got = {c: COLOUR.nearest_broad_label(COLOUR.srgb_to_lab(c)) for c in expect}
    check("black/grey/white are first-class labels", got == expect, str(got))
    check("the deliberate mid-grey band abstains",
          COLOUR.nearest_broad_label(COLOUR.srgb_to_lab((128, 128, 128))) == "unknown")
    check("a saturated red is labelled red",
          COLOUR.nearest_broad_label(COLOUR.srgb_to_lab((200, 30, 30))) == "red")

    # ---- 4. tolerance boundary inclusivity and monotonicity ----------------------
    observed = COLOUR.srgb_to_lab((200, 30, 30))
    q = (190, 40, 35)
    d = COLOUR.delta_e_2000(COLOUR.srgb_to_lab(q), observed)
    check("a distance exactly at the tolerance is a match (<=)",
          COLOUR.query_match(q, observed, d)["state"] == "match"
          and COLOUR.query_match(q, observed, d - 0.001)["state"] == "no_match",
          "deltaE=%.4f" % d)
    monotone = all(COLOUR.query_match(q, observed, t)["state"] == "match"
                   for t in (d, d + 1, 10, 20, 30, 40))
    check("increasing tolerance never removes a known match", monotone)
    unknown_verdict = COLOUR.query_match((200, 30, 30), None, 40)
    check("an unknown observed colour is uncertain and never a match",
          unknown_verdict["state"] == "uncertain")

    # ---- 5. apparent size policy ------------------------------------------------
    cases = [(0.0, "unknown"), (0.0001, "small"), (0.009999, "small"),
             (0.01, "medium"), (0.0999, "medium"), (0.10, "big"), (1.0, "big")]
    got = [(a, EV.size_label(a)) for a, _ in cases]
    check("apparent-size boundaries are 0.01/0.10 exactly",
          all(EV.size_label(a) == want for a, want in cases), str(got))
    check("negative/zero area is unknown, not small", EV.size_label(0.0) == "unknown")

    # ---- 6. letterbox geometry round trip ---------------------------------------
    boxes = np.array([[0.1, 0.2, 0.3, 0.4], [0.0, 0.0, 1.0, 1.0], [0.94, 0.9, 0.06, 0.1]])
    t256 = DATA.letterbox_transform(2560, 1440, 256)
    back = DATA.boxes_to_source_frame(DATA.boxes_to_model_frame(boxes, t256), t256)
    check("source<->model box mapping round-trips",
          float(np.abs(back - boxes).max()) < 1e-9)

    # ---- 7. target encoding and decode on synthetic input ------------------------
    heat, _box_t, _mask = MODEL.make_targets(np.array([[0.2, 0.3, 0.05, 0.1]]),
                                             np.array([0]), 256)
    check("a small object is encoded on the stride-4 level",
          heat[4].sum() > 0 and float(heat[4][0].max()) == 1.0)
    heat2, _b2, m2 = MODEL.make_targets(np.array([[0.2, 0.3, 0.5, 0.5]]),
                                        np.array([1]), 256)
    check("a big object is encoded on the same single level",
          heat2[4].sum() > 0 and m2[4].sum() == 1)
    gy, gx = np.argwhere(m2[4] > 0)[0]
    check("the heatmap peak is exactly at the object centre",
          abs(gx - int(round((0.2 + 0.25) * 256 / 4))) <= 1
          and abs(gy - int(round((0.3 + 0.25) * 256 / 4))) <= 1, "cell=(%d,%d)" % (gy, gx))
    synthetic = {4: MODEL.torch.full((1, 7, 64, 64), -12.0)}   # nothing else fires
    synthetic[4][0, 0, 16, 32] = 6.0                     # human peak at cell (32,16)
    synthetic[4][0, 3, 16, 32] = 0.0                     # centre offset dx (cells)
    synthetic[4][0, 4, 16, 32] = 0.0                     # centre offset dy (cells)
    synthetic[4][0, 5, 16, 32] = float(np.log(8.0))      # size is in LOG space
    synthetic[4][0, 6, 16, 32] = float(np.log(4.0))
    boxes_d, scores_d, classes_d = MODEL.decode(synthetic, 256, 0.30, 20, 0.5)
    check("decode turns a synthetic peak into one box of the right class",
          boxes_d.shape[0] == 1 and int(classes_d[0]) == 0 and scores_d[0] > 0.9)
    check("decoded box centre and size follow the encoded offsets",
          abs(boxes_d[0][0] + boxes_d[0][2] / 2 - 0.5) < 0.01
          and abs(boxes_d[0][2] - 0.125) < 0.01 and abs(boxes_d[0][3] - 0.0625) < 0.01,
          str(boxes_d))
    # the invariant that matters: what the encoder writes, the decoder reads back
    rt_boxes = np.array([[0.171, 0.567, 0.082, 0.169], [0.05, 0.3, 0.5, 0.4]])
    rt_classes = np.array([0, 2])
    rt_heat, rt_box, rt_mask = MODEL.make_targets(rt_boxes, rt_classes, 256)
    rt_out = {4: MODEL.torch.full((1, 7, 64, 64), -12.0)}
    for i, (cls, (x, y, w, h)) in enumerate(zip(rt_classes, rt_boxes)):
        gy, gx = np.argwhere(rt_mask[4] > 0)[i]
        rt_out[4][0, int(cls), gy, gx] = 6.0
        rt_out[4][0, 3:7, gy, gx] = MODEL.torch.tensor(rt_box[4][:, gy, gx])
    rt_decoded, _s, rt_cls = MODEL.decode(rt_out, 256, 0.30, 20, 0.5)
    if len(rt_decoded) == 2:
        err = max(min(float(np.abs(d - b).max()) for b in rt_boxes) for d in rt_decoded)
    else:
        err = 9.9
    check("target encoding and decoding round-trip within 1e-3 of the box",
          len(rt_decoded) == 2 and err < 1e-3,
          "decoded=%d max err=%.4f" % (len(rt_decoded), err))

    # ---- 8. matching: max cardinality, then max total IoU -------------------------
    refs = {"f": (np.array([[0.0, 0.0, 0.2, 0.2], [0.5, 0.5, 0.2, 0.2]]),
                  np.array([0, 0]))}
    preds = {"f": (np.array([[0.02, 0.02, 0.2, 0.2], [0.51, 0.51, 0.2, 0.2],
                             [0.8, 0.8, 0.1, 0.1]]),
                   np.array([0.9, 0.8, 0.7]), np.array([0, 0, 0]))}
    m = EV.score_predictions(preds, refs)
    check("two true positives and one false positive are counted",
          m["per_class"]["human"]["tp"] == 2 and m["per_class"]["human"]["fp"] == 1
          and m["per_class"]["human"]["fn"] == 0, json.dumps(m["per_class"]["human"]))
    check("a class with no references reports recall as not measured",
          m["per_class"]["car"]["recall_state"] == "not measured")
    check("micro F1 is computed from the raw counts",
          abs(m["micro"]["f1"] - 2 * (2 / 3) * 1.0 / ((2 / 3) + 1.0)) < 1e-9)

    # ---- 9. colour region isolation on a synthetic image -------------------------
    img = np.full((200, 200, 3), 180, np.uint8)             # light grey background
    img[80:120, 80:120] = (95, 95, 95)                      # dark-grey torso (L*=40)
    img[150:200, 80:120] = (30, 30, 200)                    # a red bag in the lower band
    torso = COLOUR.dominant_color(img, [0.4, 0.4, 0.2, 0.35], "upper_clothing")
    check("upper clothing is read from the torso, not the surroundings",
          torso["label"] == "dark_gray" and torso["srgb"] is not None, str(torso["label"]))
    # A blue bag at the hip sits inside the WIDE lower band but outside the narrow
    # one; the narrowed geometry is what keeps it from supplying the person colour.
    wide_box = COLOUR.region_box([0.4, 0.4, 0.2, 0.35], "lower_clothing")
    wide_px = (int(wide_box[0] * 200), int(wide_box[1] * 200),
               int((wide_box[0] + wide_box[2]) * 200), int((wide_box[1] + wide_box[3]) * 200))
    hip = img.copy()
    hip[wide_px[1]:wide_px[3], wide_px[0]:wide_px[0] + 4] = (200, 30, 30)   # red hip bag
    narrow = COLOUR.dominant_color(hip, [0.4, 0.4, 0.2, 0.35], "lower_clothing")
    check("a hip bag outside the narrowed lower band does not supply the colour",
          narrow["label"] != "red", str(narrow["label"]))
    mask_path = None
    with tempfile.TemporaryDirectory() as td:
        os.makedirs(os.path.join(td, "masks"), exist_ok=True)
        os.makedirs(os.path.join(td, "cols"), exist_ok=True)
        rec = COLOUR.dominant_color(img, [0.4, 0.4, 0.2, 0.35], "upper_clothing",
                                    mask_dir=os.path.join(td, "masks"),
                                    crop_dir=os.path.join(td, "cols"), name="x-upper")
        mask_path = rec["support_mask"]
        check("a known colour keeps a support mask and a crop",
              rec["support_mask"] and rec["crop"] and rec["support_pixel_count"] > 0,
              str({k: rec[k] for k in ("support_mask", "crop", "support_pixel_count")}))
        check("support_fraction is the share of region pixels that voted",
              0 < rec["support_fraction"] <= 1.0)
        blank = np.full((200, 200, 3), 128, np.uint8)
        abstain = COLOUR.dominant_color(blank, [0.4, 0.4, 0.2, 0.35], "upper_clothing")
        check("a flat mid-grey region abstains with a reason",
              abstain["label"] == "unknown" and abstain["reason"]
              and abstain["srgb"] is None and abstain["lab_d65"] is None,
              str(abstain["reason"])[:60])
        clipped = COLOUR.dominant_color(img, [0.98, 0.4, 0.2, 0.35], "upper_clothing")
        check("an object cut off by the frame edge abstains",
              clipped["label"] == "unknown" and "cut off" in (clipped["reason"] or ""),
              str(clipped["reason"])[:60])

    # ---- 10. V1 filters: same-object AND and the uncertain bucket ----------------
    cases = json.loads((FIXTURES / "filter_cases.json").read_text())["cases"]
    wrong = []
    for case in cases:
        got_state = FILTERS.evaluate(case["observation"], case["query"],
                                     case.get("recording") or {})["state"]
        if got_state != case["expected"]:
            wrong.append((case["name"], got_state, case["expected"]))
    check("all %d shared filter cases agree with their expectation" % len(cases),
          not wrong, str(wrong))
    both = [{"observation_id": "h1", "class": "human",
             "apparent_size": {"label": "medium"},
             "colors": [{"region": "upper_clothing", "label": "black",
                         "lab_d65": [8.0, 0.5, 1.0]}]},
            {"observation_id": "c1", "class": "car", "apparent_size": {"label": "big"},
             "colors": [{"region": "vehicle_body", "label": "red",
                         "lab_d65": [48.0, 61.0, 42.0]}]}]
    result = FILTERS.apply(both, {"types": ["human"], "colour_srgb": [200, 30, 30],
                                  "tolerance": 20, "colour_location": "upper"})
    check("a red car beside a human does not satisfy human+red",
          result["matched"] == 0 and result["uncertain"] == 0, json.dumps(result))
    result = FILTERS.apply(both, {"types": ["car"], "colour_srgb": [200, 30, 30],
                                  "tolerance": 20, "colour_location": "body"})
    check("the same red car does satisfy car+red", result["matched"] == 1)
    uncertain = FILTERS.apply(
        [{"observation_id": "h2", "class": "human", "apparent_size": {"label": "small"},
          "colors": [{"region": "upper_clothing", "label": "unknown", "lab_d65": None}]}],
        {"types": ["human"], "colour_srgb": [200, 30, 30], "tolerance": 20,
         "colour_location": "upper"})
    check("unknown colour stays in a separate bucket, not in the match count",
          uncertain["matched"] == 0 and uncertain["uncertain"] == 1)
    try:
        FILTERS.normalise({"types": ["bicycle"]})
        check("an unknown object type is rejected", False)
    except ValueError:
        check("an unknown object type is rejected", True)
    try:
        FILTERS.normalise({"tolerance": 55})
        check("a tolerance outside the V1 control range is rejected", False)
    except ValueError:
        check("a tolerance outside the V1 control range is rejected", True)

    # ---- 11. schedule validation -------------------------------------------------
    sys.path.insert(0, str(ROOT / "tools" / "labs"))
    import stage4_detect as DETECT
    decoded = {0: 0.0, 1: 40.0, 2: 80.0}
    with tempfile.TemporaryDirectory() as td:
        def write(spec):
            p = pathlib.Path(td) / "s.json"
            p.write_text(json.dumps(spec))
            return p
        ok, errors = DETECT.load_schedule(write({"schema_version": 1, "input_sha256": "aa",
                                                 "frames": [{"frame_index": 1,
                                                             "frame_pts_ms": 40.5}]}),
                                          "aa", decoded)
        check("a schedule inside the 1 ms PTS tolerance is accepted",
              len(ok) == 1 and not errors, str(errors))
        _ok, errors = DETECT.load_schedule(write({"schema_version": 1, "input_sha256": "aa",
                                                  "frames": [{"frame_index": 1,
                                                              "frame_pts_ms": 41.5}]}),
                                           "aa", decoded)
        check("a schedule 1.5 ms off the decoded PTS is rejected",
              any("tolerance 1 ms" in e for e in errors), str(errors))
        _ok, errors = DETECT.load_schedule(write({"schema_version": 1, "input_sha256": "bb",
                                                  "frames": [{"frame_index": 0,
                                                              "frame_pts_ms": 0.0}]}),
                                           "aa", decoded)
        check("a schedule for different bytes is rejected",
              any("does not match the input" in e for e in errors), str(errors))
        _ok, errors = DETECT.load_schedule(write({"schema_version": 1, "input_sha256": "aa",
                                                  "frames": [{"frame_index": 9,
                                                              "frame_pts_ms": 0.0}]}),
                                           "aa", decoded)
        check("a schedule naming a frame the input does not have is rejected",
              any("not a decoded presentation frame" in e for e in errors), str(errors))
        _ok, errors = DETECT.load_schedule(write({"schema_version": 1, "input_sha256": "aa",
                                                  "frames": []}), "aa", decoded)
        check("an empty schedule is rejected instead of silently analysing nothing",
              any("carries no frames" in e for e in errors), str(errors))

    # the native policy: one frame per whole second from the first frame's own PTS
    native = DETECT.native_schedule([(0, 100.0), (1, 200.0), (2, 1100.0), (3, 2100.0)])
    check("the native sampling policy picks the first frame at/after each second",
          [f["frame_index"] for f in native] == [2, 3], json.dumps(native))

    # ---- 12. no YOLO, no annotation reads, no hidden lookup tables ---------------
    def executable_strings(path):
        """Every string in EXECUTABLE code: docstrings and comments excluded.

        A comment or docstring is allowed to say "this is not YOLO" or "no
        expected labels are read"; only real code and real data may not.
        """
        src = (ROOT / "tools" / "labs" / path).read_text()
        tree = ast.parse(src)
        docstrings = set()
        for node in ast.walk(tree):
            if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef,
                                 ast.ClassDef)):
                body = getattr(node, "body", [])
                if body and isinstance(body[0], ast.Expr)                         and isinstance(body[0].value, ast.Constant)                         and isinstance(body[0].value.value, str):
                    docstrings.add(id(body[0].value))
        out = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) \
                    and id(node) not in docstrings:
                out.append((node.lineno, node.value))
        return out

    banned = ("ultralytics", "yolov", "yolov5", "yolov8", "yolo_", "import yolo")
    offenders = []
    for name in ("stage4_detect.py", "stage4_model.py", "stage4_colour.py",
                 "stage4_data.py", "stage4_filters.py", "stage4_analyse.py"):
        for lineno, value in executable_strings(name):
            low = value.lower()
            offenders += [(name, lineno, token) for token in banned if token in low]
    check("no YOLO/ultralytics reference exists in Stage 4 executable code",
          not offenders, str(offenders))

    leaks = []
    for name in ("stage4_detect.py", "stage4_colour.py", "stage4_filters.py",
                 "stage4_analyse.py"):
        for lineno, value in executable_strings(name):
            low = value.lower()
            if any(t in low for t in ("annotations/", "dataset.json", "inputs.json",
                                      "leakage_groups.json", "ground_truth",
                                      "expected_classes", "expected_boxes")):
                leaks.append((name, lineno, value[:60]))
    check("inference executable code contains no annotation/dataset/expected path",
          not leaks, str(leaks[:4]))
    check("no MobileNetV3 is constructed or imported in the Stage 4 model code",
          not any("mobilenet" in v.lower() for _l, v in
                  executable_strings("stage4_model.py")),
          "an executable string mentions mobilenet")

    # ---- 13. model identity and offline loading ----------------------------------
    os.environ["TORCH_HOME"] = tempfile.mkdtemp()
    model_a = MODEL.Stage4Detector("A")
    # pretrained=False: this check is about architecture identity, and it must not
    # need the network or the weight cache to run.
    model_b = MODEL.Stage4Detector("B", pretrained=False)
    names_b = {n.split(".")[0] for n, _ in model_b.named_parameters()}
    check("approach A has no pretrained trunk at all", model_a.pretrained is None)
    check("approach B's trunk is ResNet-18 (not a YOLO or MobileNetV3 backbone)",
          "resnet18" in model_b.trunk.__class__.__name__.lower())
    check("approach B freezes the trunk and trains the head",
          model_b.parameter_counts()["frozen"] > 0
          and model_b.parameter_counts()["trainable"] > 0,
          json.dumps(model_b.parameter_counts()))
    check("approach A's components are all trainable",
          model_a.parameter_counts()["frozen"] == 0)
    print("\n%d PASS, %d FAIL" % (len(PASS), len(FAIL)))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
