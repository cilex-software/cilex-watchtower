#!/usr/bin/env python3
"""Hermetic unit checks for the Stage 3 analyser internals.

No footage, no torch, no network: synthetic images with known colours, known
boxes and known geometry, plus the timestamp-pairing rule that a real decode
depends on. These are development checks of the plumbing; they say nothing about
recognition quality, and none of them reads dataset.json.

Run: python3 tools/tests/labs-stage3-detector.py     (exit 0 when all pass)
"""
import importlib.util
import json
import pathlib
import sys

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
LABS = ROOT / "tools" / "labs"
sys.path.insert(0, str(LABS))

import stage3_colour as C          # noqa: E402
import stage3_models as M          # noqa: E402
import stage3_detect as D          # noqa: E402

fails = []
passed = [0]


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (("   [%s]" % detail) if detail and not cond else ""))
    if cond:
        passed[0] += 1
    else:
        fails.append(name)


def solid(bgr, h=120, w=80):
    img = np.zeros((h, w, 3), np.uint8)
    img[:, :] = bgr
    return img


def scene(patch_bgr, bg_bgr=(40, 60, 40), h=200, w=200, box=(60, 60, 80, 120)):
    img = np.zeros((h, w, 3), np.uint8)
    img[:, :] = bg_bgr
    x, y, bw, bh = box
    img[y:y + bh, x:x + bw] = patch_bgr
    return img, [x / w, y / h, bw / w, bh / h]


# ---- palette ---------------------------------------------------------------------
def test_palette():
    cases = [((0, 0, 0), "black"), ((20, 20, 20), "black"), ((90, 90, 90), "dark_gray"),
             ((245, 245, 245), "white"), ((160, 160, 160), "light_gray"),
             ((0, 0, 220), "red"), ((200, 0, 0), "blue"), ((0, 160, 0), "green"),
             ((0, 200, 240), "yellow"), ((180, 120, 60), "blue")]
    for bgr, want in cases:
        img = solid(bgr)
        labels = C.color_labels(img)
        got = labels[60, 40]
        check("palette %s -> %s" % (bgr, want), got == want, "got %s" % got)
    # the narrow mid-grey band has no honest coarse name
    img = solid((128, 128, 128))
    check("palette mid-grey band abstains", C.color_labels(img)[60, 40] == "unknown",
          C.color_labels(img)[60, 40])


def test_region_geometry():
    box = [0.2, 0.2, 0.4, 0.6]
    upper = C.region_box(box, "upper_clothing")
    lower = C.region_box(box, "lower_clothing")
    body = C.region_box(box, "vehicle_body")
    check("upper clothing lies inside the person box and above its middle",
          upper[1] >= box[1] and upper[1] + upper[3] <= box[1] + box[3] * 0.5,
          json.dumps(upper))
    check("lower clothing lies below the upper region", lower[1] > upper[1] + upper[3])
    check("vehicle body is the middle band of the car box",
          body[1] > box[1] and body[1] + body[3] < box[1] + box[3], json.dumps(body))
    for region in C.REGION_GEOMETRY:
        rb = C.region_box(box, region)
        check("region %s stays inside the object box" % region,
              0 <= rb[0] and 0 <= rb[1] and rb[0] + rb[2] <= box[0] + box[2] + 1e-9
              and rb[1] + rb[3] <= box[1] + box[3] + 1e-9)
    try:
        C.region_box(box, "nonsense")
        check("unknown region is refused", False)
    except ValueError:
        check("unknown region is refused", True)


# ---- object-linked sampling ------------------------------------------------------
def test_dominant_colour():
    img, box = scene((0, 0, 230))                       # red patch
    label, conf, rbox, crop, dist = C.dominant_color(img, box, "upper_clothing")
    check("red object reads red", label == "red", "%s %.2f" % (label, conf))
    check("confidence is the bucket share", 0.8 <= conf <= 1.0, "%.3f" % conf)
    check("region box is inside the object box",
          rbox[0] >= box[0] and rbox[1] >= box[1]
          and rbox[0] + rbox[2] <= box[0] + box[2] + 1e-9)
    check("region crop matches the region box size",
          crop is not None and abs(crop.shape[1] / img.shape[1] - rbox[2]) <= 0.05)
    check("distribution is reported", isinstance(dist, dict) and dist.get("red", 0) > 0.5,
          json.dumps(dist))

    # a tiny object is not judged
    small = np.zeros((60, 60, 3), np.uint8)
    small[28:32, 28:32] = (0, 0, 230)
    label, conf, _, _, _ = C.dominant_color(small, [0.45, 0.45, 0.08, 0.08],
                                            "upper_clothing")
    check("too-small region abstains", label == "unknown", label)

    # an object whose sampled region is split four ways has no dominant bucket
    img2 = np.zeros((200, 200, 3), np.uint8)
    img2[56:192, 56:144] = (0, 0, 230)          # red object
    img2[56:124, 56:100] = (200, 0, 0)          # quadrant: blue
    img2[124:192, 100:144] = (0, 160, 0)        # quadrant: green
    img2[56:124, 100:144] = (0, 200, 240)       # quadrant: yellow
    label, conf, _, _, dist = C.dominant_color(img2, [0.28, 0.28, 0.44, 0.68],
                                               "clothing")
    check("no dominant bucket abstains", label == "unknown",
          "%s %.2f %s" % (label, conf, json.dumps(dist)))


def test_colour_is_from_the_stated_region_only():
    """The upper-clothing answer must NOT come from pixels below the waist."""
    img = np.zeros((200, 200, 3), np.uint8)
    img[60:150, 60:140] = (0, 0, 230)          # torso: red
    img[150:190, 60:140] = (230, 0, 0)         # legs: blue
    box = [60 / 200, 60 / 200, 80 / 200, 130 / 200]
    upper, _, _, _, _ = C.dominant_color(img, box, "upper_clothing")
    lower, _, _, _, _ = C.dominant_color(img, box, "lower_clothing")
    check("upper region answers from the torso", upper == "red", upper)
    check("lower region answers from the legs", lower == "blue", lower)
    check("the two regions disagree, as the pixels do", upper != lower)


# ---- detection post-processing ---------------------------------------------------
def test_nms_and_class_map():
    boxes = [[0.1, 0.1, 0.2, 0.2], [0.11, 0.11, 0.2, 0.2], [0.6, 0.6, 0.2, 0.2]]
    scores = [0.9, 0.8, 0.7]
    keep = D.nms(boxes, scores, 0.5)
    check("NMS keeps one of two overlapping boxes",
          keep == [0, 2], json.dumps(keep))
    names = M.coco_names()
    mapped = {names[i]: c for i, c in sorted(M.CLASS_MAP.items())}
    check("person and car map to the contract classes",
          mapped.get("person") == "person" and mapped.get("car") == "car", json.dumps(mapped))
    check("bus, truck, motorcycle and bicycle do NOT become car",
          all(names[i] not in M.CLASS_MAP for i in (2, 4, 6, 8)))
    check("suitcase maps to bag, not to a new class", mapped.get("suitcase") == "bag")


def test_linker():
    linker = D.Linker()
    a = linker.assign("person", [0.10, 0.10, 0.05, 0.10], 0)
    b = linker.assign("person", [0.11, 0.10, 0.05, 0.10], 400)
    check("a steadily moving object keeps one track id", a == b, "%s vs %s" % (a, b))
    c = linker.assign("car", [0.50, 0.50, 0.20, 0.10], 400)
    check("a different class starts its own track", c != a)
    d = linker.assign("person", [0.90, 0.90, 0.05, 0.10], 800)
    check("a far-away person is a new track, not the old one", d != a)
    e = linker.assign("person", [0.11, 0.10, 0.05, 0.10], 9000)
    check("a long absence ends the track", e != a)


# ---- timestamps ------------------------------------------------------------------
def test_showinfo_parser_counts_one_entry_per_frame():
    """The exact bug that halved every PTS: showinfo logs two lines per frame."""
    frame_line = ("[Parsed_showinfo_1 @ 0x55] n:  99 pts:  67584 pts_time:6.6    "
                  "duration: 512 duration_time:0.05 fmt:bgr24 cl:left sar:1/1")
    format_line = ("[Parsed_showinfo_1 @ 0x55]   color_range:tv "
                   "mean:[1 2 3] stdev:[0 0 0]")
    config_line = ("[Parsed_showinfo_1 @ 0x55] config in time_base: 1/10240, "
                   "frame_rate: 20/1")
    matches = [bool(D._SHOWINFO_PTS.search(line))
               if D._SHOWINFO_PTS is not None else None
               for line in (frame_line, format_line, config_line)]
    if D._SHOWINFO_PTS is None:
        check("showinfo parser is initialised", False, "pattern not built yet")
        return
    check("only the frame line carries a PTS",
          matches == [True, False, False], json.dumps(matches))
    check("the captured value is the frame's own pts_time",
          D._SHOWINFO_PTS.search(frame_line).group(1) == "6.6")


def test_observation_shape():
    """build_observation emits exactly the contract's observation fields."""
    img, box = scene((0, 0, 230))
    obs = D.build_observation(img, ("person", "person", 0.9, box), 1200, 7, "s3t0001",
                              "/tmp/stage3-unit-out", 3, {"score_threshold": 0.5})
    required = {"id", "frame_index", "frame_pts_ms", "class", "confidence", "bbox_xywh"}
    check("observation carries the contract fields",
          required <= set(obs), json.dumps(sorted(obs)))
    check("frame index and PTS are the caller's, not derived",
          obs["frame_index"] == 7 and obs["frame_pts_ms"] == 1200)
    check("there is at most one colour per region",
          len({c["region"] for c in obs["colors"]}) == len(obs["colors"]))
    for color in obs["colors"]:
        check("colour %s names its region and a palette label" % color["region"],
              color["region"] in C.REGION_GEOMETRY and color["label"] in
              {"black", "dark_gray", "white", "light_gray", "red", "blue", "brown",
               "pink", "green", "yellow", "orange", "unknown"})
        check("colour %s keeps its crop reference" % color["region"],
              "region_crop" in color["evidence"])
    check("the class comes from the map, not the native name twice",
          "native_class" not in obs or obs["native_class"] != obs["class"])


def test_detector_never_reads_annotations():
    """The inference path must not LOAD annotations -- checked on the code, not prose.

    Comments are allowed to say what the detector deliberately does not read, so
    this parses the modules and inspects string constants that are actually used,
    ignoring docstrings.
    """
    import ast
    banned = ("dataset.json", "targets", "target_id", "accepted_labels")
    for name in ("stage3_detect.py", "stage3_colour.py", "stage3_models.py"):
        tree = ast.parse((LABS / name).read_text())
        docstrings = set()
        for node in ast.walk(tree):
            if isinstance(node, (ast.Module, ast.FunctionDef, ast.ClassDef, ast.AsyncFunctionDef)):
                body = getattr(node, "body", [])
                if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) \
                        and isinstance(body[0].value.value, str):
                    docstrings.add(id(body[0].value))
        hits = [n.value for n in ast.walk(tree)
                if isinstance(n, ast.Constant) and isinstance(n.value, str)
                and id(n) not in docstrings
                and any(b in n.value for b in banned)]
        check("%s has no annotation string in executable code" % name, not hits,
              json.dumps(hits[:3]))
    evaluator = ast.parse((LABS / "stage3_evaluate.py").read_text())
    check("the evaluator is the module that names the dataset",
          any(isinstance(n, ast.Constant) and isinstance(n.value, str)
              and "dataset.json" in n.value for n in ast.walk(evaluator)))


def test_backend_registry():
    info = M.backend(M.DEFAULT_BACKEND)
    check("the default backend is BSD-3 licensed", info["licence"] == "BSD-3-Clause",
          info["licence"])
    check("the default backend names its source", info["source"].startswith("https://"))
    state = M.check_backend(M.DEFAULT_BACKEND)
    check("model probe reports the weights state",
          "weights_present" in state and "weights_sha256" in state)
    try:
        M.backend("nope")
        check("unknown backend is refused", False)
    except KeyError:
        check("unknown backend is refused", True)


def main():
    for fn in (test_palette, test_region_geometry, test_dominant_colour,
               test_colour_is_from_the_stated_region_only, test_nms_and_class_map,
               test_linker, test_showinfo_parser_counts_one_entry_per_frame,
               test_observation_shape, test_detector_never_reads_annotations,
               test_backend_registry):
        fn()
    print("\n%d PASS, %d FAIL" % (passed[0], len(fails)))
    if fails:
        print("failed: " + ", ".join(fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
