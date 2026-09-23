#!/usr/bin/env python3
"""An `unknown` wall cell must never paint over the composited picture.

THE DEFECT (2026-09-24, from an operator screenshot of a 16-camera wall).
Every tile read AVAILABILITY UNKNOWN, every roll-call row read "availability
unknown", the aside read "0/16 RECORDING", and not one tile showed video. The
wall looked dead. It was not.

The chain, all of it in the client:

  1. These cameras report `recording_profile.mode` = "continuous", not "motion".
     That is a documented value -- Types.h:53 says `"motion" | "continuous" | ""`.
  2. WallPlayback._isMotionMode() is therefore false for every camera, so
     footageSpans() returns null, so cellStateOf() answers "unknown" sixteen times.
     All of that is CORRECT: for a continuously-recording camera, absence of
     MOTION is not absence of FOOTAGE, and claiming otherwise would be a lie.
  3. WpCell then treated `unknown` as a dark state and drew an opaque 6px hatch
     over the whole cell -- on top of a composite that WAS delivering frames,
     because VideoOutput is declared before the cell overlays in playerArea.

So the honest verdict at step 2 was rendered as a blackout at step 3. A guard saw
sixteen empty tiles with no way to tell them from a dead wall.

THE RULE THIS PINS. The hatch means "we can prove there is nothing here". It is
for `dormant`, which IS proof, and for nothing else. `unknown` is the absence of
proof, so it shows whatever the composite has and says, in a corner badge, that
we cannot vouch for it. CLAUDE.md: "Never clear an on-screen image except on a
REAL identity change" -- hiding server pixels behind a hatch is exactly that, and
the same failure as the every-poll tile blanking (888c5da) and the events-rail
strobe (f5021b7), both of which defeated machinery built to prevent them.

This does NOT re-open the original sin. That sin was letting a black cell be READ
as "nothing recorded". The badge names the uncertainty out loud, and a composite
that produces no frames at all is still caught by renderGuard in WallPlayback.

The permanent fix is per-cell availability on the mosaic manifest, which is
cilex-vision's to ship. Until then this is the honest rendering of not knowing.

WT_NO_WALL_UNKNOWN_PIN=1 skips it.
"""
import os
import re
import sys
import pathlib

if os.environ.get("WT_NO_WALL_UNKNOWN_PIN") == "1":
    sys.exit(0)

ROOT = pathlib.Path(__file__).resolve().parents[2]
# Overridable so this lint can be run against a MUTATED COPY to prove it still
# fails when the defect is reintroduced. A pin nobody has watched fail is a pin
# nobody knows is connected -- same reason recording-vocab.py takes an override.
CELL = pathlib.Path(os.environ.get("WT_WPCELL_QML", ROOT / "qml" / "WpCell.qml"))
WALL = pathlib.Path(os.environ.get("WT_WALLPLAYBACK_QML", ROOT / "qml" / "WallPlayback.qml"))

fails = []


def check(cond, passed, failed):
    if cond:
        print("PASS  " + passed)
    else:
        fails.append(failed)


cell = CELL.read_text(encoding="utf-8")
wall = WALL.read_text(encoding="utf-8")

# ---- 1. the hatch is dormant-only -------------------------------------------
m = re.search(r"readonly\s+property\s+bool\s+_hatched\s*:\s*(.+)", cell)
check(m is not None,
      "WpCell defines _hatched",
      "WpCell no longer defines `_hatched`. The hatch gate is how this rule is\n"
      "      enforced; if it was renamed, re-point this test at the new name.")
if m:
    expr = m.group(1).strip()
    check('"unknown"' not in expr,
          f"_hatched excludes `unknown`  ({expr})",
          f"_hatched is `{expr}` -- it includes `unknown` again. An unknown cell\n"
          "      would hatch over a live composite and the wall would look dead.")
    check('"dormant"' in expr,
          "_hatched still covers `dormant` (which IS proof of nothing)",
          f"_hatched is `{expr}` and no longer covers `dormant`. A cell that\n"
          "      provably recorded nothing must still be drawn, not left looking live.")

# ---- 2. `_dark` must not come back ------------------------------------------
# It was one property meaning two different things -- "hatch this" and "this has
# no picture" -- and conflating them is what put a hatch over live video.
check("_dark" not in cell,
      "the conflated `_dark` property is gone from WpCell",
      "`_dark` is back in WpCell.qml. It meant BOTH 'hatch this cell' and 'this\n"
      "      cell has no picture', and `unknown` is the case where those two\n"
      "      differ. Keep them separate (_hatched / _hasPicture).")

# ---- 3. the full-cell hatch is gated on _hatched ----------------------------
check(re.search(r"visible:\s*cell\._hatched", cell) is not None,
      "the full-cell hatch is gated on cell._hatched",
      "the full-cell hatch block is no longer gated on `cell._hatched`. Whatever\n"
      "      gates it now must exclude `unknown`.")

# ---- 4. unknown is SAID, and said without covering the picture --------------
# The words must still appear (never silently drop to looking-like-recording)...
check("AVAILABILITY UNKNOWN" in cell,
      "an unknown cell still SAYS so",
      "WpCell no longer renders AVAILABILITY UNKNOWN anywhere. An unknown that\n"
      "      renders as an ordinary picture is an unknown rendered as healthy.")
# ...but not from a block that fills the cell.
def enclosing_blocks(src, pattern):
    """Every QML block containing a line that matches `pattern`.

    Brace-COUNTED rather than regex-matched: a QML element holds `anchors { ... }`
    and child elements, so a flat `[^{}]*` never spans one and silently finds
    nothing -- which reads as "the badge is missing" when it is right there.
    """
    out = []
    for mm in re.finditer(pattern, src):
        # walk back to the `{` that opens this element
        depth, i = 0, mm.start()
        while i > 0:
            if src[i] == "}":
                depth += 1
            elif src[i] == "{":
                if depth == 0:
                    break
                depth -= 1
            i -= 1
        # walk forward to its matching `}`
        depth, j = 0, i
        while j < len(src):
            if src[j] == "{":
                depth += 1
            elif src[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out.append(src[i:j + 1])
    return out


unknown_blocks = enclosing_blocks(cell, r"visible:[^\n]*state\s*===\s*\"unknown\"")
check(bool(unknown_blocks),
      f"the unknown affordance is bound to state === \"unknown\" ({len(unknown_blocks)} block(s))",
      "no block in WpCell is gated on state === \"unknown\". The badge is how the\n"
      "      state stays visible now that the hatch is gone.")
for b in unknown_blocks:
    check("anchors.fill: parent" not in b,
          "the unknown affordance does not fill the cell",
          "a block gated on state === \"unknown\" uses `anchors.fill: parent`. That\n"
          "      is the blackout again by another name -- it must be a corner badge.")

# ---- 5. the tally must not report an unknown as a zero ----------------------
check("unknownCount" in wall,
      "WallPlayback counts unknown cells separately",
      "WallPlayback has no `unknownCount`. Without it the aside prints\n"
      "      \"0/16 RECORDING\", which is a CLAIM that nothing is recording, made\n"
      "      about sixteen cells whose state is by definition unknown.")
check(re.search(r"readonly\s+property\s+string\s+rollCallTally", wall) is not None,
      "one shared `rollCallTally` phrasing",
      "`rollCallTally` is gone. The aside and the roll-call header each built\n"
      "      their own string and could disagree about what the wall is claiming.")
# Neither render site may hand-roll the old "N/M RECORDING" from recordingCount.
handrolled = re.findall(r"text:[^\n]*recordingCount[^\n]*RECORDING", wall)
check(not handrolled,
      "no render site hand-rolls the RECORDING tally from recordingCount",
      f"{len(handrolled)} render site(s) build the tally from recordingCount directly:\n"
      + "".join(f"        {h.strip()}\n" for h in handrolled)
      + "      Use rollCallTally, or an all-unknown wall reports 0 recording as fact.")

if fails:
    print("\nFAIL  " + "\n\nFAIL  ".join(fails), file=sys.stderr)
    sys.exit(1)
print("all passed")
