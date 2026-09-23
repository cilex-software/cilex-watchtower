#!/usr/bin/env python3
"""The client must handle every recording state cilex-vision can emit.

WHY. notRecordingCount is rendered in three places (HealthScreen, OpsSidebar,
TopBar) and its ONLY live input is the token `stalled` -- `not_recording` was
renamed to it on their side already. recStateFrom()'s fallback returns
RecUnknown, so if `stalled` were renamed the same way, that counter would read 0
and three surfaces would report all-clear during a real fleet failure. Nothing
would throw. That is green-by-default for an unknown state, reached by a silent
fallback rather than a wrong branch.

Two assertions, the second only when cilex-vision's checkout is present:

  1. the fallback still WARNS (so a rename is loud at runtime, on any box)
  2. every token their recording_state() can return is handled EXPLICITLY here,
     not swallowed by the fallback (so a rename is loud at COMMIT time, on this
     box, before anyone runs it)

Recorded vocabulary, enumerated from their AST 2026-09-23:
    armed | disabled | offline | recording | stalled
If that list changes, this test is how you find out.

WT_NO_VOCAB_PIN=1 skips it.
"""
import ast, os, re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "src" / "models" / "CameraModel.cpp"
RECORDED = {"armed", "disabled", "offline", "recording", "stalled"}
# Overridable so this lint can be tested against a mutated copy without touching
# cilex-vision's tree, which is theirs and which I do not edit.
CV = pathlib.Path(os.environ.get("WT_CV_STREAMS_PY",
      "/home/cilex-vision/projects/cilex-vision/services/query-api/routers/streams.py"))

if os.environ.get("WT_NO_VOCAB_PIN") == "1":
    sys.exit(0)

text = SRC.read_text(encoding="utf-8")
m = re.search(r"CameraStatus::RecState recStateFrom\(.*?\n\}", text, re.S)
if not m:
    sys.exit("FAIL  recStateFrom() not found in CameraModel.cpp")
body = m.group(0)

fails = []

handled = set(re.findall(r'QLatin1String\("([a-z_]+)"\)', body))
print(f"PASS  recStateFrom handles: {', '.join(sorted(handled))}")

if "qWarning" not in body:
    fails.append("recStateFrom()'s fallback no longer warns. An unknown token would be\n"
                 "      counted as UNKNOWN in silence, and notRecordingCount would\n"
                 "      under-report a fleet fault with nothing in the log.")
else:
    print("PASS  the unknown-token fallback still warns")

# Cross-check against the real source when it is there; skip cleanly when it is not,
# because this lint runs in three checkouts and only one of them has their tree.
if CV.exists():
    tree = ast.parse(CV.read_text(encoding="utf-8"))
    live = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "recording_state":
            for n in ast.walk(node):
                if isinstance(n, ast.Return) and isinstance(n.value, ast.Constant) \
                   and isinstance(n.value.value, str):
                    live.add(n.value.value)
    if not live:
        fails.append("found cilex-vision's streams.py but could not enumerate "
                     "recording_state()'s returns; the cross-check is not running.")
    else:
        if live != RECORDED:
            print(f"NOTE  their vocabulary has CHANGED since it was recorded.\n"
                  f"      recorded {sorted(RECORDED)}\n"
                  f"      live     {sorted(live)}")
        missing = sorted(live - handled)
        if missing:
            fails.append(f"cilex-vision can emit {missing}, which recStateFrom() does not\n"
                         f"      handle explicitly -- it would fall through to RecUnknown. If that\n"
                         f"      token replaced 'stalled', notRecordingCount now reads 0 on a wall\n"
                         f"      that is genuinely failing.")
        else:
            print(f"PASS  all {len(live)} tokens their recording_state() returns are handled explicitly")
else:
    print("SKIP  cilex-vision checkout not present; runtime warning is the only guard here")

if fails:
    print("\nFAIL  " + "\n\nFAIL  ".join(fails), file=sys.stderr)
    sys.exit(1)
print("all passed")
