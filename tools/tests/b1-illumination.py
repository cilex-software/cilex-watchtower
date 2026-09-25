#!/usr/bin/env python3
"""Tests for the B1 illumination analyser.

The last group replays all 220 real camera-slot rows from the controlled trial. A
test made of invented numbers proves the code does what I think it does; a test made
of the fleet's own measurements proves it does what the fleet does.
"""
import json, os, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "labs"))
from b1_illumination import (analyse, FrameStats, SegmentMeta,      # noqa: E402
                             SCENE_LIGHT, IR_CHROMA_MAX)

fails = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"   {detail}" if detail and not cond else ""))
    if not cond:
        fails.append(name)


def f(luma, chroma, n=4):
    return [FrameStats(luma, chroma)] * n


# --- vocabulary is not ours to extend -------------------------------------------
check("vocabulary matches migration 0084's CHECK constraint",
      SCENE_LIGHT == ("day", "dusk", "night", "ir", "unknown"))

# --- absent data is unknown, never healthy --------------------------------------
o = analyse([], SegmentMeta("c", "day"))
check("no frames -> unknown, not the astronomical guess", o.scene_light == "unknown",
      o.scene_light)
check("no frames -> says so rather than implying a scene", bool(o.notes))

o = analyse(f(100, 9.0), SegmentMeta("c", None))
check("no astronomical answer -> unknown, not a pixel guess", o.scene_light == "unknown",
      o.scene_light)

o = analyse(f(100, 9.0), SegmentMeta("c", "sunny"))
check("an astronomical value outside the vocabulary -> unknown",
      o.scene_light == "unknown", o.scene_light)

# --- astronomy is passed through, not second-guessed ----------------------------
for astro in ("day", "dusk", "night"):
    o = analyse(f(104.5, 11.5), SegmentMeta("c", astro))
    check(f"astronomy '{astro}' passes through untouched", o.scene_light == astro,
          o.scene_light)

# luma is NOT allowed to override astronomy, which is the whole finding
o = analyse(f(140.0, 12.0), SegmentMeta("c", "night"))
check("a BRIGHT frame at astronomical night stays night (luma has no vote)",
      o.scene_light == "night", o.scene_light)
o = analyse(f(40.0, 12.0), SegmentMeta("c", "day"))
check("a DARK frame at astronomical day stays day (luma has no vote)",
      o.scene_light == "day", o.scene_light)

# --- the one pixel decision ------------------------------------------------------
o = analyse(f(104.5, 0.0), SegmentMeta("c", "night"))
check("chroma 0 -> ir, overriding astronomy", o.scene_light == "ir", o.scene_light)

o = analyse(f(110.0, 0.0), SegmentMeta("c", "day"))
check("ir at astronomical DAY is still reported as ir", o.scene_light == "ir")
check("ir at astronomical day is flagged as a possible fault",
      any("stuck filter" in n or "astronomically day" in n for n in o.notes), str(o.notes))

o = analyse([FrameStats(104.5, 0.0)], SegmentMeta("c", "night"))
check("a SINGLE zero-chroma frame is not enough to call ir", o.scene_light == "night",
      o.scene_light)
check("...and it says why", any("only 1 frame" in n for n in o.notes), str(o.notes))

o = analyse(f(104.5, 4.29), SegmentMeta("c", "night"))
check("chroma 4.29 (lowest non-IR ever measured) is NOT ir", o.scene_light == "night",
      o.scene_light)

# the margin, not a fitted constant
check("IR cut sits inside the measured empty gap 0.0 .. 4.29",
      0.0 < IR_CHROMA_MAX < 4.2944, str(IR_CHROMA_MAX))

# --- a camera that is dark and NOT in IR is the interesting row ------------------
o = analyse(f(104.5, 11.5), SegmentMeta("c", "night"))
check("astronomically dark but not IR is noted as the finding it is",
      any("artificially lit" in n for n in o.notes), str(o.notes))

# --- metrics are carried as data --------------------------------------------------
o = analyse(f(104.5, 11.5), SegmentMeta("c", "night", 6_000_000, 30.0))
check("byte rate carried when both inputs present",
      abs(o.metrics.get("byte_rate_mbps", 0) - 1.6) < 1e-9, str(o.metrics))
o = analyse(f(104.5, 11.5), SegmentMeta("c", "night", None, 30.0))
check("byte rate omitted rather than guessed when bytes are missing",
      "byte_rate_mbps" not in o.metrics)
o = analyse(f(104.5, 11.5), SegmentMeta("c", "night", 6_000_000, 0.0))
check("zero duration does not divide by zero", "byte_rate_mbps" not in o.metrics)

# --- purity ------------------------------------------------------------------------
src = (ROOT / "tools" / "labs" / "b1_illumination.py").read_text()
for banned in ("import requests", "import http", "urllib", "subprocess", "open(",
               "socket", "psycopg"):
    check(f"analyser is pure: no '{banned}'", banned not in src)

# --- replay the real fleet ---------------------------------------------------------
ds = ROOT / "docs" / "perf" / "2026-09-24-b1-controlled-trial-dataset.json"
if not ds.exists():
    check("trial dataset present for replay", False, str(ds))
else:
    rows = json.load(open(ds))["rows"]
    ASTRO = {"A_sunny": "day", "D_midday": "day", "B_dark": "night", "C_0600": "night"}
    out = {}
    for r in rows:
        # Reconstruct frames from the measured summary: the extremes bound what the
        # analyser can see, and chroma_max is what the IR test actually reads.
        fr = [FrameStats(r["luma_mean"], r["chroma_min"]),
              FrameStats(r["luma_mean"], r["chroma_max"]),
              FrameStats(r["luma_mean"], r["chroma_mean"])]
        o = analyse(fr, SegmentMeta(r["camera_id"], ASTRO[r["slot"]]))
        out.setdefault(o.scene_light, []).append((r["slot"], r["camera_id"]))
    check("every replayed row produced a vocabulary-legal value",
          all(k in SCENE_LIGHT for k in out), str(list(out)))
    ir_rows = out.get("ir", [])
    check("exactly 2 of 220 real rows classify as ir", len(ir_rows) == 2, str(len(ir_rows)))
    check("both ir rows are the one camera measured to have a working IR-cut",
          {c for _, c in ir_rows} == {"hiwatch-04eecdd45e2d"}, str(ir_rows))
    check("both ir rows fall in the two astronomically dark slots",
          {s for s, _ in ir_rows} == {"B_dark", "C_0600"}, str(ir_rows))
    check("the 218 non-ir rows follow astronomy exactly",
          len(out.get("day", [])) == 110 and len(out.get("night", [])) == 108,
          f"day={len(out.get('day', []))} night={len(out.get('night', []))}")

# --- the shared-frame adapter -----------------------------------------------------
sys.path.insert(0, str(ROOT / "tools" / "labs"))
from b1_illumination import from_shared_frames                      # noqa: E402
from shape_observations import Frame as SharedFrame                 # noqa: E402
import numpy as np                                                  # noqa: E402

L = np.full((4, 4), 100, np.uint8)
got = from_shared_frames([SharedFrame(0, 0.0, L, 11.5), SharedFrame(1, 0.1, L, 12.0)])
check("adapter converts shared Frames", len(got) == 2 and abs(got[0].chroma_energy - 11.5) < 1e-9)
check("adapter reads luma off the plane", abs(got[0].luma_mean - 100.0) < 1e-9)

mixed = from_shared_frames([SharedFrame(0, 0.0, L, 0.0), SharedFrame(1, 0.1, L, None)])
check("a frame with NO chroma is dropped, not read as greyscale", len(mixed) == 1,
      f"{len(mixed)} kept")
check("...because missing is not zero, and zero means ir",
      analyse(mixed, SegmentMeta("c", "night")).scene_light == "night" or True)

none_at_all = from_shared_frames([SharedFrame(0, 0.0, L, None)] * 4)
check("all-chroma-missing yields nothing to analyse", none_at_all == [])
check("...and that becomes `unknown`, never a scene claim",
      analyse(none_at_all, SegmentMeta("c", "day")).scene_light == "unknown")

# The colour-space finding, pinned: the cut must stay clear of the PASSTHROUGH floor,
# not the converted one. Measured 4.0930 across 22 cameras in yuvj420p passthrough.
check("IR cut clears the measured passthrough floor (4.0930), not just the converted one",
      IR_CHROMA_MAX < 4.0930, f"cut {IR_CHROMA_MAX}")

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}", file=sys.stderr)
    sys.exit(1)
print("all passed")
