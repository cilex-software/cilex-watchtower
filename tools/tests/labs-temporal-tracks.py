#!/usr/bin/env python3
"""Labs temporal tracking — contract tests. Hermetic: no camera, no station, no
network, no database, no live worker, no footage and no model.

Everything here is offline and deterministic. The published cases in
`docs/benchmarks/labs-tracking/fixtures/cases.json` are run twice, once straight
into `temporal_tracks.Tracker` and once through `replay_temporal_tracks.py` as
JSONL subprocesses (which is also what checks each stream's exit status), by the
interpreter in `fixtures/temporal_tracks/case_harness.py`. The rest of this file
is written against CONTRACT.md directly: association, ambiguity, time,
replay/checkpoints, validation, the adapter, the CLI protocol, bounded state and
the section-13 resource workload.

The checks are written to FAIL on a plausible defect, not to pass on a
skeleton: exact IDs, exact statuses, exact quantised costs where the contract
quantises, exact closure reasons and times, exact snapshot digests, and exact
error codes. A test that only asserts "no exception" would keep passing after
the tracker stopped associating, so there are almost none of those.

Run:  python3 tools/tests/labs-temporal-tracks.py            (exit 1 on failure)
      WT_SHORT=1 python3 tools/tests/labs-temporal-tracks.py  (skip the 100k-batch
                                                               resource workload)
"""
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "labs"))
sys.path.insert(0, str(ROOT / "tools" / "tests" / "fixtures" / "temporal_tracks"))

import temporal_tracks as tt                                 # noqa: E402
from temporal_tracks import Tracker, TrackingError            # noqa: E402
import temporal_tracks_adapter as ad                          # noqa: E402
import case_harness as H                                      # noqa: E402
import workload as WL                                         # noqa: E402

CLI = ROOT / "tools" / "labs" / "replay_temporal_tracks.py"
CAM = "cam-t"
UNIT = "unit-t"
SHORT = os.environ.get("WT_SHORT") == "1"

fails = []
_passed = [0]


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"   [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)
    else:
        _passed[0] += 1


def _crashed(t, e, tb):
    print(f"FAIL the suite CRASHED after {_passed[0]} passing checks: {t.__name__}: {e}")
    sys.__excepthook__(t, e, tb)


sys.excepthook = _crashed


# ---------------------------------------------------------------- helpers
def det(did, x, y, w=0.04, h=0.04, app=None):
    d = {"id": did, "bbox": [x, y, w, h]}
    if app is not None:
        d["appearance"] = app
    return d


def cdet(did, cx, cy, w=0.04, h=0.04, app=None):
    """A detection placed by its CENTRE. The geometry below is written in centres
    and in dyadic fractions (0.25, 0.3125, ...) so that a distance that the
    contract makes inclusive is exactly representable and the check tests the
    rule rather than this file's floating point."""
    return det(did, cx - w / 2.0, cy - h / 2.0, w, h, app)


def batch(seq, t_ms, dets, camera=CAM, unit=UNIT, reset=None, **extra):
    b = {"camera_id": camera, "unit_id": unit, "seq": seq, "t_ms": t_ms, "detections": list(dets)}
    if reset is not None:
        b["reset"] = reset
    b.update(extra)
    return b


def code_of(fn, *a, **k):
    """The TrackingError code a call raises, or None when it does not raise."""
    try:
        fn(*a, **k)
    except TrackingError as e:
        return e.code
    except BaseException as e:                       # noqa: BLE001 - a crash IS the answer
        return f"<{type(e).__name__}: {e}>"
    return None


def pairs(receipt):
    """[(detection_id, track_id, status, reason)] of a receipt, in receipt order."""
    return [(a["detection_id"], a["track_id"], a["status"], a["reason"])
            for a in receipt["assignments"]]


def cli(lines, timeout=120.0, env=None):
    """(responses, returncode, stderr) from one JSONL subprocess run."""
    payload = "".join(json.dumps(c) + "\n" for c in lines)
    e = dict(os.environ)
    e.update(env or {})
    proc = subprocess.run([sys.executable, str(CLI)], input=payload.encode("utf-8"),
                          capture_output=True, timeout=timeout, env=e)
    out = proc.stdout.decode("utf-8", "replace")
    responses = []
    for ln in out.split("\n"):
        if ln.strip():
            try:
                responses.append(json.loads(ln))
            except ValueError:
                responses.append({"unparsable": ln})
    return responses, proc.returncode, proc.stderr.decode("utf-8", "replace")


def raw_cli(text, timeout=60.0):
    """(raw stdout lines, returncode) for lines that are not valid JSON."""
    proc = subprocess.run([sys.executable, str(CLI)], input=text.encode("utf-8"),
                          capture_output=True, timeout=timeout)
    lines = [ln for ln in proc.stdout.decode("utf-8", "replace").split("\n") if ln.strip()]
    return lines, proc.returncode


def new_tracker(config=None, camera=CAM, unit=UNIT):
    return Tracker(camera, unit, config)


def feed_one(tr, seq, t_ms, dets, **kw):
    return tr.feed(batch(seq, t_ms, dets, **kw))


def full_state(tr):
    return tt.canonical_state_json(tr.snapshot()["state"])


# =========================================================================
print("--- published cases: contract fixtures, API path")
# =========================================================================
DOC = H.load()
CHECKS = [c["id"] for c in DOC["cases"]]
check("the published case file is the one this suite was written against",
      len(CHECKS) == 8 and DOC["schema"] == "labs-temporal-tracking-public-cases/v1",
      str(CHECKS))
API_RESULTS = {}
for case in DOC["cases"]:
    res = H.run_case_api(case)
    bad = [(n, d) for n, ok, d in res if not ok]
    check(f"case {case['id']} (api, {len(res)} operations)", not bad,
          "; ".join(f"{n}: {d[:200]}" for n, d in bad[:3]))
    API_RESULTS[case["id"]] = res

# =========================================================================
print("\n--- published cases: the same fixtures through the JSONL CLI")
# =========================================================================
if SHORT:
    print("SKIP  CLI fixture replay (WT_SHORT=1)")
else:
    for case in DOC["cases"]:
        res = H.run_case_cli(case)
        bad = [(n, d) for n, ok, d in res if not ok]
        check(f"case {case['id']} (cli, {len(res)} operations and exit codes)", not bad,
              "; ".join(f"{n}: {d[:200]}" for n, d in bad[:3]))

EPISODES_BY_CASE = {c["id"]: H.drained_episodes(c) for c in DOC["cases"]}
ADAPTER_RESULTS = H.run_adapter_examples(DOC, EPISODES_BY_CASE)
for name, ok, detail in ADAPTER_RESULTS:
    check(f"published {name}", ok, detail[:300])

# =========================================================================
print("\n--- association: unique and global assignment")
# =========================================================================
# A single unambiguous object stays one track, and the receipt says so exactly.
tr = new_tracker()
r = []
for n in range(5):
    r.append(feed_one(tr, n, n * 1000, [det(f"d{n}", 0.1 + 0.02 * n, 0.4)]))
check("five observations of one thing are one track",
      all(pairs(x) == [(f"d{n}", "t00000001", "born" if n == 0 else "matched", None)]
          for n, x in enumerate(r)), str([pairs(x) for x in r]))

# Maximum cardinality beats the individually cheapest edge: t1 could take
# `middle` for less, but then t2 has nothing and a track is lost.
tr = new_tracker()
feed_one(tr, 0, 0, [det("a", 0.10, 0.40, 0.1, 0.1), det("b", 0.30, 0.40, 0.1, 0.1)])
rec = feed_one(tr, 1, 1000, [det("middle", 0.19, 0.40, 0.1, 0.1), det("left", 0.0, 0.40, 0.1, 0.1)])
check("a cheaper individual edge does not win against maximum cardinality",
      pairs(rec) == [("left", "t00000001", "matched", None),
                     ("middle", "t00000002", "matched", None)], str(pairs(rec)))

# A non-greedy case the public example does not cover: three tracks, three
# detections, where the cheapest edge first strands two tracks.
tr = new_tracker({"gate_base": 0.4, "gate_speed": 0.0})
feed_one(tr, 0, 0, [det("t-a", 0.10, 0.5, 0.04, 0.04), det("t-b", 0.30, 0.5, 0.04, 0.04),
                    det("t-c", 0.50, 0.5, 0.04, 0.04)])
# t1 -> d1 (0.12) is cheap, t2 -> d1 (0.18) and t2 -> d2 (0.22), t3 -> d2 (0.02),
# t3 -> d3 (0.22). Greedy on cost takes t3-d2 first, then t2-d1, then strands t1.
rec = feed_one(tr, 1, 1000, [det("d1", 0.28, 0.5, 0.04, 0.04),
                             det("d2", 0.48, 0.5, 0.04, 0.04),
                             det("d3", 0.68, 0.5, 0.04, 0.04)])
check("three tracks keep three detections under a global optimum",
      pairs(rec) == [("d1", "t00000001", "matched", None),
                     ("d2", "t00000002", "matched", None),
                     ("d3", "t00000003", "matched", None)], str(pairs(rec)))

# Detection-list order is immaterial: a permutation gives the same receipt.
tr2 = new_tracker({"gate_base": 0.4, "gate_speed": 0.0})
feed_one(tr2, 0, 0, [det("t-c", 0.50, 0.5), det("t-a", 0.10, 0.5), det("t-b", 0.30, 0.5)])
rec2 = feed_one(tr2, 1, 1000, [det("d3", 0.68, 0.5), det("d1", 0.28, 0.5), det("d2", 0.48, 0.5)])
check("permuted input order gives the identical receipt and identical IDs",
      rec2 == rec, f"{pairs(rec2)} vs {pairs(rec)}")
tr.feed(batch(2, 2000, []))
tr2.feed(batch(2, 2000, []))
check("permuted input order gives an identical checkpoint", full_state(tr) == full_state(tr2))

# Births take IDs in ascending detection-ID order, not input order.
tr = new_tracker()
rec = feed_one(tr, 0, 0, [det("zz", 0.10, 0.10), det("aa", 0.50, 0.10), det("mm", 0.80, 0.10)])
check("new IDs are allocated in ascending detection-ID order",
      pairs(rec) == [("aa", "t00000001", "born", None), ("mm", "t00000002", "born", None),
                     ("zz", "t00000003", "born", None)], str(pairs(rec)))

# An isolated detection with no feasible edge starts a new track; the far one
# does not steal an existing track's identity.
tr = new_tracker({"gate_base": 0.05, "gate_speed": 0.0})
feed_one(tr, 0, 0, [det("a", 0.10, 0.10)])
rec = feed_one(tr, 1, 1000, [det("b", 0.11, 0.10), det("far", 0.90, 0.90)])
check("a near detection matches and an isolated one is born",
      pairs(rec) == [("b", "t00000001", "matched", None), ("far", "t00000002", "born", None)],
      str(pairs(rec)))

# Area-ratio gate is inclusive on both sides and refuses outside them. All the
# boxes here are dyadic so the ratio is exact, not a rounding accident.
tr = new_tracker({"gate_base": 0.5, "max_area_ratio": 4.0})
feed_one(tr, 0, 0, [det("a", 0.10, 0.10, 0.25, 0.25)])          # area 0.0625
rec = feed_one(tr, 1, 1000, [det("b", 0.10, 0.10, 0.5, 0.5)])    # area 0.25 == ratio exactly 4
check("an area ratio exactly at max_area_ratio is feasible",
      pairs(rec) == [("b", "t00000001", "matched", None)], str(pairs(rec)))
tr = new_tracker({"gate_base": 0.5, "max_area_ratio": 4.0})
feed_one(tr, 0, 0, [det("a", 0.10, 0.10, 0.25, 0.25)])
rec = feed_one(tr, 1, 1000, [det("b", 0.10, 0.10, 0.5000001, 0.5)])
check("an area ratio a hair past max_area_ratio is infeasible, so a new track is born",
      pairs(rec) == [("b", "t00000002", "born", None)] and rec["closed"] == [], str(rec))
tr = new_tracker({"gate_base": 0.5, "max_area_ratio": 4.0})
feed_one(tr, 0, 0, [det("a", 0.10, 0.10, 0.5, 0.5)])             # area 0.25
rec = feed_one(tr, 1, 1000, [det("b", 0.10, 0.10, 0.25, 0.25)])  # ratio exactly 1/4
check("an area ratio exactly at 1/max_area_ratio is feasible",
      pairs(rec) == [("b", "t00000001", "matched", None)], str(pairs(rec)))
tr = new_tracker({"gate_base": 0.5, "max_area_ratio": 4.0})
feed_one(tr, 0, 0, [det("a", 0.10, 0.10, 0.5, 0.5)])
rec = feed_one(tr, 1, 1000, [det("b", 0.10, 0.10, 0.2499999, 0.25)])
check("an area ratio a hair below 1/max_area_ratio is infeasible",
      pairs(rec) == [("b", "t00000002", "born", None)], str(pairs(rec)))

# Distance gate is inclusive: d == g is feasible, d a hair beyond is not.
tr = new_tracker({"gate_base": 0.25, "gate_speed": 0.0})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5)])
rec = feed_one(tr, 1, 1000, [cdet("b", 0.5, 0.5)])
check("a detection exactly at the gate distance is feasible",
      pairs(rec) == [("b", "t00000001", "matched", None)], str(pairs(rec)))
tr = new_tracker({"gate_base": 0.25, "gate_speed": 0.0})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5)])
rec = feed_one(tr, 1, 1000, [cdet("b", 0.5 + 2.0 ** -20, 0.5)])
check("a detection a hair beyond the gate is infeasible",
      pairs(rec) == [("b", "t00000002", "born", None)], str(pairs(rec)))

# =========================================================================
print("\n--- prediction, velocity and occlusion")
# =========================================================================
# Constant velocity: the PREDICTION, not the last position, is what gates.
# Steps of 0.015625 per second with a 0.02 gate, so the second observation is
# associable and the difference between predicting and not is 0.03125 -- clearly
# inside or clearly outside, never a rounding question.
tr = new_tracker({"gate_base": 0.02, "gate_speed": 0.0, "max_gap_ms": 5000})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5)])
feed_one(tr, 1, 1000, [cdet("b", 0.265625, 0.5)])
rec = feed_one(tr, 2, 3000, [cdet("c", 0.296875, 0.5)])
check("a coasting prediction carries the track forward at its own velocity",
      pairs(rec) == [("c", "t00000001", "matched", None)], str(pairs(rec)))
tr2 = new_tracker({"gate_base": 0.02, "gate_speed": 0.0, "max_gap_ms": 5000})
feed_one(tr2, 0, 0, [cdet("a", 0.25, 0.5)])
feed_one(tr2, 1, 1000, [cdet("b", 0.265625, 0.5)])
rec = feed_one(tr2, 2, 3000, [cdet("c", 0.265625, 0.5)])
check("the last position alone is not associable once the track has a velocity",
      pairs(rec) == [("c", "t00000002", "born", None)], str(pairs(rec)))

# max_speed caps the vector's MAGNITUDE without changing its direction. The raw
# velocity here is (0.078125, 0.0390625)/s, its magnitude 0.0873.../s, so a cap
# of 0.01 shortens the five-second step to 0.05 in the same direction. Clipping
# each component instead would predict (0.315625, 0.3078125), which is 0.028
# away -- outside the 0.02 gate, so this check tells the two apart.
import math                                                     # noqa: E402

P0 = (0.25, 0.25)
P1 = (0.265625, 0.2578125)
RAW = ((P1[0] - P0[0]) / 0.2, (P1[1] - P0[1]) / 0.2)
K = 0.01 / math.hypot(*RAW)
CAPPED = (P1[0] + RAW[0] * K * 5.0, P1[1] + RAW[1] * K * 5.0)
PER_COMPONENT = (P1[0] + 0.01 * 5.0, P1[1] + 0.01 * 5.0)
check("the test geometry really does separate magnitude capping from component clipping",
      math.dist(CAPPED, PER_COMPONENT) > 0.02, str((CAPPED, PER_COMPONENT)))
tr = new_tracker({"gate_base": 0.02, "gate_speed": 0.0, "max_speed": 0.01, "max_gap_ms": 10000})
feed_one(tr, 0, 0, [cdet("a", *P0)])
feed_one(tr, 1, 200, [cdet("b", *P1)])
rec = feed_one(tr, 2, 5200, [cdet("c", *CAPPED)])
check("max_speed caps the predicted step's magnitude, keeping its direction",
      pairs(rec) == [("c", "t00000001", "matched", None)], str(pairs(rec)))
uncapped = new_tracker({"gate_base": 0.02, "gate_speed": 0.0, "max_speed": 1.0,
                        "max_gap_ms": 10000})
feed_one(uncapped, 0, 0, [cdet("a", *P0)])
feed_one(uncapped, 1, 200, [cdet("b", *P1)])
rec = feed_one(uncapped, 2, 5200, [cdet("c", *CAPPED)])
check("the same geometry without the cap predicts somewhere else entirely",
      pairs(rec) == [("c", "t00000002", "born", None)], str(pairs(rec)))
uncapped2 = new_tracker({"gate_base": 0.02, "gate_speed": 0.0, "max_speed": 1.0,
                         "max_gap_ms": 10000})
feed_one(uncapped2, 0, 0, [cdet("a", *P0)])
feed_one(uncapped2, 1, 200, [cdet("b", *P1)])
rec = feed_one(uncapped2, 2, 5200, [cdet("c", P1[0] + RAW[0] * 5.0, P1[1] + RAW[1] * 5.0)])
check("...and an uncapped tracker matches at the uncapped prediction instead",
      pairs(rec) == [("c", "t00000001", "matched", None)], str(pairs(rec)))

# A single observation has zero velocity: it predicts where it was, however long
# the gap.
tr = new_tracker({"gate_base": 0.02, "gate_speed": 0.0, "max_gap_ms": 10000})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5)])
rec = feed_one(tr, 1, 5000, [cdet("b", 0.25, 0.5)])
check("with one observation the velocity is zero, so it predicts its own position",
      pairs(rec) == [("b", "t00000001", "matched", None)], str(pairs(rec)))

# gate_speed widens the gate with dt, which is what lets an occlusion be bridged.
for gb, gs, dx, expect in ((0.05, 0.0, 0.0625, "born"),
                           (0.05, 0.1, 0.0625, "matched"),
                           (0.0625, 0.03125, 0.125, "matched"),
                           (0.0625, 0.03125, 0.125 + 2.0 ** -20, "born")):
    tr = new_tracker({"gate_base": gb, "gate_speed": gs, "max_gap_ms": 5000})
    feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5)])
    rec = feed_one(tr, 1, 2000, [cdet("b", 0.25 + dx, 0.5)])
    check(f"gate {gb}+{gs}*2s against a {dx} move is {expect}",
          pairs(rec)[0][2] == expect, str(pairs(rec)))

# Coasting through empty batches keeps the velocity and creates no evidence.
tr = new_tracker({"gate_base": 0.02, "gate_speed": 0.0, "max_gap_ms": 10000})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5)])
feed_one(tr, 1, 1000, [cdet("b", 0.265625, 0.5)])
for n in range(2, 6):
    rec = feed_one(tr, n, n * 1000, [])
    check(f"empty batch seq={n} advances time, assigns nothing and closes nothing",
          rec == {"seq": n, "replayed": False, "assignments": [], "closed": []}, str(rec))
rec = feed_one(tr, 6, 6000, [cdet("c", 0.265625, 0.5)])
check("five seconds later the stale position is NOT where the track is predicted",
      pairs(rec) == [("c", "t00000002", "born", None)], str(pairs(rec)))
tr3 = new_tracker({"gate_base": 0.02, "gate_speed": 0.0, "max_gap_ms": 10000})
feed_one(tr3, 0, 0, [cdet("a", 0.25, 0.5)])
feed_one(tr3, 1, 1000, [cdet("b", 0.265625, 0.5)])
for n in range(2, 6):
    feed_one(tr3, n, n * 1000, [])
rec = feed_one(tr3, 6, 6000, [cdet("c", 0.265625 + 0.015625 * 5, 0.5)])
check("an object reappearing at the predicted place after a 5 s occlusion is the same track",
      pairs(rec) == [("c", "t00000001", "matched", None)], str(pairs(rec)))
tr3.finish()
eps = tr3.drain()
check("the occluded track kept no synthetic observation: 3 accepted over 6 s",
      len(eps) == 1 and eps[0]["observations"] == 3 and eps[0]["start_ms"] == 0
      and eps[0]["end_ms"] == 6000 and eps[0]["max_observation_gap_ms"] == 5000
      and [s[0] for s in eps[0]["path"]] == [0, 1000, 6000], str(eps))

# Only a successful, unambiguous assignment updates the measurement: after an
# abstention the prediction still comes from the older evidence.
tr = new_tracker({"gate_base": 0.125, "gate_speed": 0.0, "ambiguity_margin": 0})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5), cdet("b", 0.375, 0.5)])
rec = feed_one(tr, 1, 1000, [cdet("mid", 0.3125, 0.5)])
check("one detection equidistant from two tracks is a cost tie",
      pairs(rec) == [("mid", None, "ambiguous", "cost_tie")], str(pairs(rec)))
rec = feed_one(tr, 2, 2000, [cdet("x", 0.25, 0.5)])
check("an abstained batch updated no measurement, so t1 still predicts its own position",
      pairs(rec) == [("x", "t00000001", "matched", None)], str(pairs(rec)))

# =========================================================================
print("\n--- ambiguity, merges and explicit abstention")
# =========================================================================
# ambiguity_margin is an INCLUSIVE bound on how much worse a different
# maximum-cardinality matching may be. Costs here are exactly 250000 and
# 750000 (d/g = 0.25 and 0.75 with a 0.25 gate), so the difference is exactly
# 500000 and the boundary is not a rounding question.
def margin_case(margin, at=0.3125):
    tr = new_tracker({"gate_base": 0.25, "gate_speed": 0.0, "ambiguity_margin": margin})
    feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5), cdet("b", 0.5, 0.5)])
    return feed_one(tr, 1, 1000, [cdet("mid", at, 0.5)])


check("an exact cost tie is ambiguous even at margin 0",
      pairs(margin_case(0, at=0.375)) == [("mid", None, "ambiguous", "cost_tie")],
      str(pairs(margin_case(0, at=0.375))))
check("a clearly cheaper alternative is unambiguous at margin 0",
      pairs(margin_case(0))[0][2] == "matched", str(pairs(margin_case(0))))
check("an alternative exactly ambiguity_margin worse is ambiguous (inclusive bound)",
      pairs(margin_case(500000))[0][2] == "ambiguous", str(pairs(margin_case(500000))))
check("an alternative one unit past the margin is decisive",
      pairs(margin_case(499999))[0][2] == "matched", str(pairs(margin_case(499999))))
check("the largest permitted margin makes almost anything ambiguous",
      pairs(margin_case(1000000))[0][2] == "ambiguous", str(pairs(margin_case(1000000))))
check("the accepted matching under a decisive margin is the cheaper one",
      pairs(margin_case(0)) == [("mid", "t00000001", "matched", None)], str(pairs(margin_case(0))))

# The alternative must have the SAME cardinality: a smaller one, however cheap,
# does not make a component ambiguous. This is the public global-assignment
# geometry with the margin wide open.
tr = new_tracker({"ambiguity_margin": 1000000})
feed_one(tr, 0, 0, [det("a", 0.10, 0.40, 0.1, 0.1), det("b", 0.30, 0.40, 0.1, 0.1)])
rec = feed_one(tr, 1, 1000, [det("left", 0.0, 0.40, 0.1, 0.1), det("middle", 0.19, 0.40, 0.1, 0.1)])
check("a cheaper size-1 alternative does not void a size-2 matching",
      pairs(rec) == [("left", "t00000001", "matched", None),
                     ("middle", "t00000002", "matched", None)], str(pairs(rec)))

# Whole-component abstention: a third track that shares the component but is not
# part of the tie must abstain too, and gain no evidence.
tr = new_tracker({"gate_base": 0.5, "gate_speed": 0.0, "ambiguity_margin": 0})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5), cdet("b", 0.375, 0.5), cdet("c", 0.875, 0.5)])
rec = feed_one(tr, 1, 1000, [cdet("mid", 0.3125, 0.5), cdet("far", 0.875, 0.5)])
check("one tie voids the WHOLE connected component, including its innocent members",
      pairs(rec) == [("far", None, "ambiguous", "cost_tie"),
                     ("mid", None, "ambiguous", "cost_tie")], str(pairs(rec)))
tr.finish()
eps = {e["track_id"]: e for e in tr.drain()}
check("every track of an abstaining component counts the batch once and gains no observation",
      sorted(eps) == ["t00000001", "t00000002", "t00000003"]
      and all(eps[t]["ambiguous_batches"] == 1 and eps[t]["observations"] == 1 for t in eps),
      str({t: (eps[t]["ambiguous_batches"], eps[t]["observations"]) for t in eps}))
check("an abstaining batch leaves the tracks' evidence where it was",
      all(eps[t]["end_ms"] == 0 and eps[t]["path_length"] == 0 and eps[t]["reason"] == "finish"
          for t in eps), str(eps))

# A component can be ambiguous while one of its detections has a SINGLE feasible
# edge: abstention is a property of the component, not of the detection's own
# options. Here `mid` ties between t1 and t2 while `solo` can only reach t3, and
# both are in one connected component, so both must abstain.
tr = new_tracker({"gate_base": 0.25, "gate_speed": 0.0, "ambiguity_margin": 0})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.375), cdet("b", 0.25, 0.625), cdet("c", 0.5, 0.5)])
rec = feed_one(tr, 1, 1000, [cdet("mid", 0.25, 0.5), cdet("solo", 0.625, 0.5)])
check("a detection with ONE feasible edge still abstains with its component",
      pairs(rec) == [("mid", None, "ambiguous", "cost_tie"),
                     ("solo", None, "ambiguous", "cost_tie")], str(pairs(rec)))
tr.finish()
ABSTAINED = tr.drain()
check("...and no track in that component gains an observation",
      sorted((e["track_id"], e["observations"], e["ambiguous_batches"]) for e in ABSTAINED)
      == [("t00000001", 1, 1), ("t00000002", 1, 1), ("t00000003", 1, 1)],
      str(sorted((e["track_id"], e["observations"]) for e in ABSTAINED)))

# A merge takes precedence over a cost tie, and voids a UNIQUE matching too.
tr = new_tracker({"gate_base": 0.25, "gate_speed": 0.0, "max_area_ratio": 100.0,
                  "ambiguity_margin": 0})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5), cdet("b", 0.5, 0.5)])
rec = feed_one(tr, 1, 1000, [det("wide", 0.25, 0.4, 0.25, 0.2)])   # spans x 0.25..0.5
check("a wide box with both predicted centres on its boundaries reports merge, not cost_tie",
      pairs(rec) == [("wide", None, "ambiguous", "merge")], str(pairs(rec)))
tr = new_tracker({"gate_base": 0.5, "gate_speed": 0.0, "max_area_ratio": 100.0,
                  "ambiguity_margin": 0})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5), cdet("b", 0.375, 0.5)])
rec = feed_one(tr, 1, 1000, [det("wide", 0.25, 0.4, 0.25, 0.2)])
check("a merge voids a matching that was otherwise unique and decisive",
      pairs(rec) == [("wide", None, "ambiguous", "merge")], str(pairs(rec)))
tr = new_tracker({"gate_base": 0.5, "gate_speed": 0.0, "max_area_ratio": 100.0,
                  "ambiguity_margin": 0})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5), cdet("b", 0.875, 0.5)])
rec = feed_one(tr, 1, 1000, [det("wide", 0.25, 0.4, 0.25, 0.2)])
check("ONE centre inside the box is not a merge, and the unique matching stands",
      pairs(rec) == [("wide", "t00000001", "matched", None)], str(pairs(rec)))
tr = new_tracker({"gate_base": 0.5, "gate_speed": 0.0, "max_area_ratio": 100.0,
                  "ambiguity_margin": 0})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5), cdet("b", 0.375, 0.5)])
rec = feed_one(tr, 1, 1000, [det("wide", 0.25, 0.4, 0.0625, 0.2)])   # spans x 0.25..0.3125
check("ONE centre, exactly on the box boundary, is not a merge and the match stands",
      pairs(rec) == [("wide", "t00000001", "matched", None)], str(pairs(rec)))
tr = new_tracker({"gate_base": 0.5, "gate_speed": 0.0, "max_area_ratio": 100.0,
                  "ambiguity_margin": 0})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5), cdet("b", 0.375, 0.5)])
rec = feed_one(tr, 1, 1000, [det("wide", 0.25 + 2.0 ** -20, 0.4, 0.0625, 0.2)])
check("a centre a hair outside the box is not inside it, so there is still no merge",
      pairs(rec) == [("wide", "t00000001", "matched", None)], str(pairs(rec)))

# An unresolved crossing stays unresolved: two identical objects, no descriptor.
tr = new_tracker({"gate_base": 0.3, "gate_speed": 0.0})
feed_one(tr, 0, 0, [det("l", 0.30 - 0.02, 0.50 - 0.02), det("r", 0.40 - 0.02, 0.50 - 0.02)])
rec = feed_one(tr, 1, 1000, [det("m", 0.35 - 0.02, 0.50 - 0.02)])
check("an indistinguishable crossing is allowed to stay unresolved",
      pairs(rec) == [("m", None, "ambiguous", "cost_tie")], str(pairs(rec)))

# A supplied descriptor resolves the same crossing without inventing evidence.
tr = new_tracker({"gate_base": 0.3, "gate_speed": 0.0})
feed_one(tr, 0, 0, [det("l", 0.30 - 0.02, 0.50 - 0.02, app=[1, 0, 0, 0]),
                    det("r", 0.40 - 0.02, 0.50 - 0.02, app=[0, 1, 0, 0])])
rec = feed_one(tr, 1, 1000, [det("m", 0.35 - 0.02, 0.50 - 0.02, app=[0, 1, 0, 0])])
check("a supplied descriptor makes the same crossing resolvable",
      pairs(rec) == [("m", "t00000002", "matched", None)], str(pairs(rec)))

# Appearance gates: a = 0.5 * L1, inclusive at appearance_gate.
tr = new_tracker({"gate_base": 0.5, "appearance_gate": 0.5})
feed_one(tr, 0, 0, [det("a", 0.30 - 0.02, 0.50 - 0.02, app=[1, 0, 0, 0])])
rec = feed_one(tr, 1, 1000, [det("b", 0.30 - 0.02, 0.50 - 0.02, app=[0.5, 0.5, 0, 0])])
check("an appearance distance exactly at appearance_gate is feasible",
      pairs(rec) == [("b", "t00000001", "matched", None)], str(pairs(rec)))
tr = new_tracker({"gate_base": 0.5, "appearance_gate": 0.5})
feed_one(tr, 0, 0, [det("a", 0.30 - 0.02, 0.50 - 0.02, app=[1, 0, 0, 0])])
rec = feed_one(tr, 1, 1000, [det("b", 0.30 - 0.02, 0.50 - 0.02, app=[0.4, 0.6, 0, 0])])
check("an appearance distance just past appearance_gate is infeasible",
      pairs(rec) == [("b", "t00000002", "born", None)], str(pairs(rec)))
# A null appearance on either side applies no appearance gate at all.
tr = new_tracker({"gate_base": 0.5, "appearance_gate": 0.0})
feed_one(tr, 0, 0, [det("a", 0.30 - 0.02, 0.50 - 0.02, app=[1, 0, 0, 0])])
rec = feed_one(tr, 1, 1000, [det("b", 0.30 - 0.02, 0.50 - 0.02)])
check("a detection with no descriptor is not gated by appearance, even at gate 0",
      pairs(rec) == [("b", "t00000001", "matched", None)], str(pairs(rec)))
tr = new_tracker({"gate_base": 0.5, "appearance_gate": 0.0})
feed_one(tr, 0, 0, [det("a", 0.30 - 0.02, 0.50 - 0.02)])
rec = feed_one(tr, 1, 1000, [det("b", 0.30 - 0.02, 0.50 - 0.02, app=[1, 0, 0, 0])])
check("a track with no descriptor yet is not gated by appearance either",
      pairs(rec) == [("b", "t00000001", "matched", None)], str(pairs(rec)))
# The track's descriptor is its most recent NON-NULL accepted one: a detection
# that supplies none does not clear it, and the kept descriptor goes on gating.
tr = new_tracker({"gate_base": 0.5, "appearance_gate": 0.0})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5, app=[1, 0, 0, 0])])
rec = feed_one(tr, 1, 1000, [cdet("b", 0.25, 0.5)])
check("a detection with no descriptor is not gated by appearance, even at gate 0",
      pairs(rec) == [("b", "t00000001", "matched", None)], str(pairs(rec)))
rec = feed_one(tr, 2, 2000, [cdet("c", 0.25, 0.5, app=[0, 1, 0, 0])])
check("...and it does not clear the track's descriptor, which still gates the next batch",
      pairs(rec) == [("c", "t00000002", "born", None)], str(pairs(rec)))
rec = feed_one(tr, 3, 3000, [cdet("d", 0.25, 0.5, app=[0, 1, 0, 0])])
check("an accepted descriptor replaces the previous one",
      pairs(rec) == [("d", "t00000002", "matched", None)], str(pairs(rec)))

# Appearance enters the COST, not only the gate: the geometrically nearer
# detection loses when its descriptor is worse and appearance_weight says so.
tr = new_tracker({"gate_base": 0.5, "gate_speed": 0.0, "appearance_weight": 2.0,
                  "appearance_gate": 1.0})
feed_one(tr, 0, 0, [det("a", 0.20 - 0.02, 0.50 - 0.02, app=[1, 0, 0, 0]),
                    det("b", 0.60 - 0.02, 0.50 - 0.02, app=[0, 1, 0, 0])])
rec = feed_one(tr, 1, 1000, [det("p", 0.24 - 0.02, 0.50 - 0.02, app=[0, 1, 0, 0]),
                             det("q", 0.58 - 0.02, 0.50 - 0.02, app=[1, 0, 0, 0])])
check("appearance_weight can outweigh a shorter distance in the cost",
      pairs(rec) == [("p", "t00000002", "matched", None), ("q", "t00000001", "matched", None)],
      str(pairs(rec)))
same = new_tracker({"gate_base": 0.5, "gate_speed": 0.0, "appearance_weight": 0.0,
                    "appearance_gate": 1.0})
feed_one(same, 0, 0, [det("a", 0.18, 0.48, app=[1, 0, 0, 0]), det("b", 0.58, 0.48, app=[0, 1, 0, 0])])
rec = feed_one(same, 1, 1000, [det("p", 0.22, 0.48, app=[0, 1, 0, 0]),
                               det("q", 0.56, 0.48, app=[1, 0, 0, 0])])
check("with appearance_weight 0 the nearer detection wins instead",
      pairs(rec) == [("p", "t00000001", "matched", None), ("q", "t00000002", "matched", None)],
      str(pairs(rec)))

# The quantised cost itself, read off a component whose two alternatives differ
# only in the appearance term: d/g = 0 both ways, so the winner is decided by
# floor(1e6 * appearance_weight * a + 0.5).
tr = new_tracker({"gate_base": 0.5, "gate_speed": 0.0, "appearance_weight": 0.25,
                  "appearance_gate": 1.0, "ambiguity_margin": 0})
feed_one(tr, 0, 0, [det("a", 0.20 - 0.02, 0.50 - 0.02, app=[1, 0, 0, 0])])
rec = feed_one(tr, 1, 1000, [det("b", 0.20 - 0.02, 0.50 - 0.02, app=[0.9, 0.1, 0, 0])])
check("a single feasible edge is accepted whatever its quantised cost",
      pairs(rec) == [("b", "t00000001", "matched", None)], str(pairs(rec)))

# =========================================================================
print("\n--- time: expiry, boundaries, discontinuity and isolation")
# =========================================================================
def boundary(gap=None, span=None, times=(0, 1000, 2000), pos=0.10):
    cfg = {"gate_base": 0.5, "gate_speed": 0.0}
    if gap is not None:
        cfg["max_gap_ms"] = gap
    if span is not None:
        cfg["max_span_ms"] = span
    tr = new_tracker(cfg)
    out = []
    for n, t in enumerate(times):
        out.append(feed_one(tr, n, t, [det(f"d{n}", pos - 0.02, 0.50 - 0.02)]))
    return tr, out

tr, recs = boundary(gap=1000, times=(0, 1000))
check("a gap of exactly max_gap_ms keeps the track (the bound is strict >)",
      pairs(recs[1]) == [("d1", "t00000001", "matched", None)] and recs[1]["closed"] == [],
      str(recs[1]))
tr, recs = boundary(gap=1000, times=(0, 1001))
check("one millisecond past max_gap_ms closes the track",
      pairs(recs[1]) == [("d1", "t00000002", "born", None)] and recs[1]["closed"] == ["t00000001"],
      str(recs[1]))
tr.finish()
ep = tr.drain()[0]
check("a gap closure ends at the LAST OBSERVATION, not at the timeout",
      ep["end_ms"] == 0 and ep["reason"] == "gap" and ep["observations"] == 1, str(ep))
tr, recs = boundary(span=2000, times=(0, 1000, 2000))
check("a span of exactly max_span_ms keeps the track",
      pairs(recs[2]) == [("d2", "t00000001", "matched", None)] and recs[2]["closed"] == [],
      str(recs[2]))
tr, recs = boundary(span=2000, times=(0, 1000, 2001))
check("one millisecond past max_span_ms closes the track",
      recs[2]["closed"] == ["t00000001"], str(recs[2]))
tr.finish()
eps = {e["track_id"]: e for e in tr.drain()}
check("a span closure ends at the last observation and says span",
      eps["t00000001"]["reason"] == "span" and eps["t00000001"]["end_ms"] == 1000, str(eps))
# gap is tested first: a batch that trips both reports gap.
tr, recs = boundary(gap=500, span=600, times=(0, 700))
tr.finish()
ep = tr.drain()[0]
check("when a batch trips both limits the reason is gap, tested first",
      ep["reason"] == "gap" and ep["end_ms"] == 0, str(ep))

# Reset: everything closes, the closure ends at real evidence, and the same
# batch's detections start fresh IDs. The gap limit is deliberately wide, and
# the control below proves the closure came from `reset` and not from expiry.
tr = new_tracker({"max_gap_ms": 10000})
feed_one(tr, 0, 0, [det("a", 0.10, 0.10), det("b", 0.50, 0.10)])
feed_one(tr, 1, 1000, [det("c", 0.11, 0.10), det("d", 0.51, 0.10)])
rec = feed_one(tr, 2, 2000, [det("e", 0.12, 0.10)], reset=True)
check("a reset batch closes every active track and lists them by (start_ms, track_id)",
      rec["closed"] == ["t00000001", "t00000002"], str(rec["closed"]))
check("the same reset batch still creates fresh tracks for its own detections",
      pairs(rec) == [("e", "t00000003", "born", None)], str(pairs(rec)))
tr.finish()
eps = {e["track_id"]: e for e in tr.drain()}
check("a reset closure ends at the last observation, not at the reset",
      all(eps[t]["reason"] == "reset" and eps[t]["end_ms"] == 1000
          for t in ("t00000001", "t00000002")), str(eps))
check("closed tracks are never reattached: the fresh track has one observation",
      eps["t00000003"]["observations"] == 1 and eps["t00000003"]["start_ms"] == 2000,
      str(eps["t00000003"]))
ctrl = new_tracker({"max_gap_ms": 10000})
feed_one(ctrl, 0, 0, [det("a", 0.10, 0.10), det("b", 0.50, 0.10)])
feed_one(ctrl, 1, 1000, [det("c", 0.11, 0.10), det("d", 0.51, 0.10)])
rec = feed_one(ctrl, 2, 2000, [det("e", 0.12, 0.10)])
check("the identical batch without reset closes nothing", rec["closed"] == [], str(rec))
tr2 = new_tracker()
rec = feed_one(tr2, 0, 0, [], reset=True)
check("a reset with nothing active is a quiet, accepted batch",
      rec == {"seq": 0, "replayed": False, "assignments": [], "closed": []}, str(rec))
tr3 = new_tracker({"max_gap_ms": 10000})
feed_one(tr3, 0, 0, [det("a", 0.10, 0.10)])
rec = feed_one(tr3, 1, 1000, [det("b", 0.10, 0.10)], reset=True)
check("reset and expiry are alternatives: the reason is reset, never both",
      rec["closed"] == ["t00000001"] and pairs(rec) == [("b", "t00000002", "born", None)], str(rec))
tr3.finish()
check("...and the episode says reset", tr3.drain()[0]["reason"] == "reset")

# Scope isolation: another camera's or unit's detection is never attached.
tr = new_tracker()
feed_one(tr, 0, 0, [det("a", 0.10, 0.10)])
check("a batch from another camera is wrong_scope",
      code_of(tr.feed, batch(1, 1000, [det("b", 0.10, 0.10)], camera="other")) == "wrong_scope")
check("a batch from another unit is wrong_scope",
      code_of(tr.feed, batch(1, 1000, [det("b", 0.10, 0.10)], unit="other")) == "wrong_scope")
rec = feed_one(tr, 1, 1000, [det("b", 0.10, 0.10)])
check("the refused out-of-scope batch did not consume its seq",
      pairs(rec) == [("b", "t00000001", "matched", None)] and rec["seq"] == 1, str(rec))
tr_other = new_tracker(camera="other")
check("a second tracker for another camera keeps its own ID space",
      pairs(feed_one(tr_other, 0, 0, [det("x", 0.10, 0.10)], camera="other"))
      == [("x", "t00000001", "born", None)])

# Sequence rules.
tr = new_tracker()
check("the first new batch must be seq 0", code_of(tr.feed, batch(1, 0, [])) == "sequence_error")
feed_one(tr, 0, 500, [])
check("a skipped seq is sequence_error", code_of(tr.feed, batch(2, 1000, [])) == "sequence_error")
check("an equal timestamp is sequence_error", code_of(tr.feed, batch(1, 500, [])) == "sequence_error")
check("a decreasing timestamp is sequence_error",
      code_of(tr.feed, batch(1, 499, [])) == "sequence_error")
check("a repeated seq with the same content inside the window is a replay, not an error",
      tr.feed(batch(0, 500, []))["replayed"] is True)
rec = feed_one(tr, 1, 501, [])
check("one millisecond forward is accepted", rec["seq"] == 1 and not rec["replayed"], str(rec))

# =========================================================================
print("\n--- replay window, atomicity and backpressure")
# =========================================================================
tr = new_tracker({"replay_batches": 2, "max_pending": 4, "max_tracks": 4})
first = feed_one(tr, 0, 0, [det("a", 0.10, 0.10)])
second = feed_one(tr, 1, 1000, [det("b", 0.11, 0.10)])
third = feed_one(tr, 2, 2000, [det("c", 0.12, 0.10)])
before = full_state(tr)
again = tr.feed(batch(2, 2000, [det("c", 0.12, 0.10)]))
check("a replay returns the original receipt with replayed=true",
      again == {"seq": 2, "replayed": True, "assignments": third["assignments"],
                "closed": third["closed"]}, str(again))
check("a replay changes nothing observable", full_state(tr) == before)
check("the retained receipt itself still says replayed=false",
      tr.feed(batch(2, 2000, [det("c", 0.12, 0.10)]))["replayed"] is True
      and json.loads(json.dumps(tr.snapshot()))["state"]["replay"][-1]["receipt"]["replayed"] is False)
# Equivalent normalised input: permuted detections, explicit defaults, and
# integer/float spellings of the same measurement.
tr = new_tracker({"replay_batches": 4})
feed_one(tr, 0, 0, [det("a", 0.0, 0.0, 0.1, 0.1), det("b", 0.5, 0.5, 0.1, 0.1, app=[1, 0, 0, 0])])
variants = [
    {"camera_id": CAM, "unit_id": UNIT, "seq": 0, "t_ms": 0, "reset": False,
     "detections": [{"id": "b", "bbox": [0.5, 0.5, 0.1, 0.1], "appearance": [1.0, 0.0, 0.0, 0.0]},
                    {"id": "a", "bbox": [0, 0, 0.1, 0.1], "appearance": None}]},
    {"camera_id": CAM, "unit_id": UNIT, "seq": 0, "t_ms": 0,
     "detections": [{"id": "a", "bbox": [0.0, 0.0, 0.1, 0.1]},
                    {"id": "b", "bbox": [0.5, 0.5, 0.1, 0.1], "appearance": [1, 0, 0, 0]}]},
]
for i, v in enumerate(variants):
    rec = tr.feed(v)
    check(f"normalisation variant {i} (permutation, explicit defaults, int/float) is a replay",
          rec["replayed"] is True and rec["seq"] == 0, str(rec))
check("a different measurement at a retained seq is replay_conflict",
      code_of(tr.feed, batch(0, 0, [det("a", 0.001, 0.0, 0.1, 0.1), det("b", 0.5, 0.5, 0.1, 0.1)]))
      == "replay_conflict")
check("a different detection SET at a retained seq is replay_conflict",
      code_of(tr.feed, batch(0, 0, [det("a", 0.0, 0.0, 0.1, 0.1)])) == "replay_conflict")
check("a different t_ms at a retained seq is replay_conflict",
      code_of(tr.feed, batch(0, 1, [det("a", 0.0, 0.0, 0.1, 0.1), det("b", 0.5, 0.5, 0.1, 0.1)]))
      == "replay_conflict")
check("a different reset flag at a retained seq is replay_conflict",
      code_of(tr.feed, batch(0, 0, [det("a", 0.0, 0.0, 0.1, 0.1), det("b", 0.5, 0.5, 0.1, 0.1)],
                             reset=True)) == "replay_conflict")
check("a different appearance descriptor at a retained seq is replay_conflict",
      code_of(tr.feed, batch(0, 0, [det("a", 0.0, 0.0, 0.1, 0.1),
                                    det("b", 0.5, 0.5, 0.1, 0.1, app=[0, 1, 0, 0])]))
      == "replay_conflict")
check("an appearance present in the replay but absent from the original is a conflict too",
      code_of(tr.feed, batch(0, 0, [det("a", 0.0, 0.0, 0.1, 0.1, app=[1, 0, 0, 0]),
                                    det("b", 0.5, 0.5, 0.1, 0.1, app=[1, 0, 0, 0])]))
      == "replay_conflict")
check("a conflict left the tracker untouched",
      code_of(tr.feed, batch(0, 0, [det("a", 0.0, 0.0, 0.1, 0.1),
                                    det("b", 0.5, 0.5, 0.1, 0.1, app=[1, 0, 0, 0])])) is None)

# The window holds exactly replay_batches accepted NEW batches.
tr = new_tracker({"replay_batches": 3, "max_pending": 64})
for n in range(6):
    feed_one(tr, n, n * 100, [det(f"d{n}", 0.10 + 0.001 * n, 0.10)])
for n, expect in ((5, None), (4, None), (3, None), (2, "stale_replay"), (0, "stale_replay")):
    got = code_of(tr.feed, batch(n, n * 100, [det(f"d{n}", 0.10 + 0.001 * n, 0.10)]))
    check(f"seq {n} against a 3-batch window after seq 5 -> {expect or 'replay'}", got == expect,
          str(got))

# A replay never restores drained output, and its receipt still names the
# closures of the ORIGINAL operation.
tr = new_tracker({"max_gap_ms": 1000, "max_pending": 8, "max_tracks": 4, "replay_batches": 4})
feed_one(tr, 0, 0, [det("a", 0.10, 0.10)])
rec = feed_one(tr, 1, 2000, [det("b", 0.10, 0.10)])
check("the expiry batch closed the old track", rec["closed"] == ["t00000001"], str(rec))
drained = tr.drain()
check("the episode was drained", len(drained) == 1 and drained[0]["reason"] == "gap", str(drained))
again = tr.feed(batch(1, 2000, [det("b", 0.10, 0.10)]))
check("the replay's receipt still describes the original closures",
      again["replayed"] is True and again["closed"] == ["t00000001"], str(again))
check("the replay did not requeue the drained episode", tr.drain() == [])

# Atomic capacity: track limit.
tr = new_tracker({"max_tracks": 1, "max_pending": 8, "max_gap_ms": 10000})
feed_one(tr, 0, 0, [det("a", 0.10, 0.10)])
snap = full_state(tr)
check("a batch that would exceed max_tracks is capacity",
      code_of(tr.feed, batch(1, 1000, [det("b", 0.80, 0.80)])) == "capacity")
check("the refused batch left the whole snapshot intact", full_state(tr) == snap)
rec = feed_one(tr, 1, 1000, [det("b", 0.10, 0.10)])
check("the next batch reuses the ID the refused one did not consume",
      pairs(rec) == [("b", "t00000001", "matched", None)], str(pairs(rec)))
tr = new_tracker({"max_tracks": 2, "max_pending": 8, "max_gap_ms": 10000})
feed_one(tr, 0, 0, [det("a", 0.05, 0.05), det("b", 0.45, 0.45)])
snap = full_state(tr)
check("a batch that would add a third track where two fit is capacity",
      code_of(tr.feed, batch(1, 1000, [det("c", 0.85, 0.05), det("d", 0.05, 0.85),
                                       det("e", 0.85, 0.85)])) == "capacity")
check("...and it applied nothing at all: no expiry, no birth, no counter move",
      full_state(tr) == snap)
tr2 = new_tracker({"max_tracks": 2})
check("a batch that needs three tracks at once is capacity and assigns nothing",
      code_of(tr2.feed, batch(0, 0, [det("c", 0.05, 0.05), det("d", 0.45, 0.45),
                                     det("e", 0.85, 0.85)])) == "capacity")
check("...and the tracker is still empty afterwards",
      tr2.snapshot()["state"]["tracks"] == [] and tr2.snapshot()["state"]["next_id"] == 1)
tr3 = new_tracker({"max_tracks": 3})
rec = feed_one(tr3, 0, 0, [det("c", 0.05, 0.05), det("d", 0.45, 0.45), det("e", 0.85, 0.85)])
check("exactly max_tracks births is accepted",
      [a["status"] for a in rec["assignments"]] == ["born", "born", "born"], str(rec))

# Atomic capacity: outbox limit, and the drain-then-retry recovery.
tr = new_tracker({"max_pending": 1, "max_tracks": 1, "max_gap_ms": 1000, "replay_batches": 4})
feed_one(tr, 0, 0, [det("a", 0.10, 0.10)])
feed_one(tr, 1, 2000, [det("b", 0.10, 0.10)])          # closes t1 -> outbox 1/1
snap = full_state(tr)
check("a batch whose closures would exceed max_pending is capacity",
      code_of(tr.feed, batch(2, 4000, [det("c", 0.10, 0.10)])) == "capacity")
check("the refused batch did not expire, advance or queue anything", full_state(tr) == snap)
held = tr.drain()
retry = tr.feed(batch(2, 4000, [det("c", 0.10, 0.10)]))
check("draining and retrying the IDENTICAL batch succeeds",
      retry["closed"] == ["t00000002"] and pairs(retry) == [("c", "t00000003", "born", None)],
      str(retry))
check("the retry produced exactly the operation the refusal would have",
      [e["track_id"] for e in held] == ["t00000001"] and len(tr.drain()) == 1)

# finish() obeys the same rule and does not seal on failure. max_pending >=
# max_tracks is a config rule, so an overflow needs a queued episode as well as
# live tracks: t1 is queued by a gap, then three tracks are live at once.
tr = new_tracker({"max_pending": 3, "max_tracks": 3, "max_gap_ms": 1000})
feed_one(tr, 0, 0, [det("a", 0.10, 0.10)])
feed_one(tr, 1, 2000, [det("b", 0.10, 0.10)])           # closes t1 -> outbox 1/3
feed_one(tr, 2, 2500, [det("c", 0.60, 0.60)])           # t3 born, active 2
feed_one(tr, 3, 2600, [det("d", 0.85, 0.20)])           # t4 born, active 3
snap = full_state(tr)
check("finish that would overflow the outbox is capacity", code_of(tr.finish) == "capacity")
check("a refused finish did not seal the tracker or close anything",
      full_state(tr) == snap and tr.finished is False)
check("...and the refused finish left the queued episode alone",
      [e["track_id"] for e in tr.drain()] == ["t00000001"])
check("after draining, the refused finish succeeds, seals and orders its closures",
      tr.finish() == ["t00000002", "t00000003", "t00000004"] and tr.finished is True)
FINISHED_EPS = tr.drain()
check("finish's episodes come out of the drain in the same order",
      [e["track_id"] for e in FINISHED_EPS] == ["t00000002", "t00000003", "t00000004"],
      str(FINISHED_EPS))
check("every finish closure says finish and ends at its own last observation",
      [(e["reason"], e["start_ms"], e["end_ms"]) for e in FINISHED_EPS]
      == [("finish", 2000, 2000), ("finish", 2500, 2500), ("finish", 2600, 2600)],
      str([(e["reason"], e["start_ms"], e["end_ms"]) for e in FINISHED_EPS]))
tr2 = new_tracker({"max_pending": 1, "max_tracks": 1})
feed_one(tr2, 0, 0, [det("a", 0.10, 0.10)])
check("finish fits when the outbox has room", tr2.finish() == ["t00000001"])
check("finish sealed that tracker", tr2.finished is True)
check("the finished tracker's episode waits for its drain",
      [e["track_id"] for e in tr2.drain()] == ["t00000001"])
check("a repeated finish returns [] and emits nothing", tr2.finish() == [] and tr2.drain() == [])
check("feeding a sealed tracker is finished, even as a replay",
      code_of(tr2.feed, batch(0, 0, [det("a", 0.10, 0.10)])) == "finished")
check("a sealed tracker still drains", tr2.drain() == [])
check("a sealed tracker still snapshots, and twice identically",
      tt.canonical_state_json(tr2.snapshot()["state"])
      == tt.canonical_state_json(tr2.snapshot()["state"]))
check("drain, snapshot and restore still work on a finished tracker",
      Tracker.restore(json.loads(json.dumps(tr2.snapshot()))).finished is True)
check("a restored finished tracker also refuses a feed",
      code_of(Tracker.restore(json.loads(json.dumps(tr2.snapshot()))).feed,
              batch(1, 1000, [])) == "finished")
tr3 = new_tracker()
check("finish on a tracker that never saw a batch seals it and returns []",
      tr3.finish() == [] and tr3.finished is True)

# =========================================================================
print("\n--- detection accounting: every detection exactly once")
# =========================================================================
# One batch with all three outcomes at once: an abstaining component, a clean
# single-edge match in a DIFFERENT component, and an isolated birth. This is the
# accounting the contract asks for -- every input detection appears exactly once
# in `assignments`, and no observation is invented for the one that abstained.
tr = new_tracker({"gate_base": 0.125, "gate_speed": 0.0, "ambiguity_margin": 0,
                  "max_tracks": 8, "max_pending": 8})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5), cdet("b", 0.375, 0.5), cdet("c", 0.75, 0.5)])
rec = feed_one(tr, 1, 1000, [cdet("z2", 0.55, 0.5), cdet("a3", 0.765625, 0.5),
                             cdet("m1", 0.3125, 0.5)])
check("a mixed batch accounts for every detection exactly once, in detection-ID order",
      [a["detection_id"] for a in rec["assignments"]] == ["a3", "m1", "z2"],
      str(rec["assignments"]))
check("...with the matched detection on its own component's track",
      pairs(rec)[0] == ("a3", "t00000003", "matched", None), str(pairs(rec)))
check("...with the tied detection abstaining and naming no track",
      pairs(rec)[1] == ("m1", None, "ambiguous", "cost_tie"), str(pairs(rec)))
check("...and the isolated detection born with the next free ID",
      pairs(rec)[2] == ("z2", "t00000004", "born", None), str(pairs(rec)))
check("the abstaining component's tracks both count the batch, the others do not",
      [(t["tid"], t["ambiguous_batches"]) for t in tr.snapshot()["state"]["tracks"]]
      == [("t00000001", 1), ("t00000002", 1), ("t00000003", 0), ("t00000004", 0)],
      str([(t["tid"], t["ambiguous_batches"]) for t in tr.snapshot()["state"]["tracks"]]))
check("no closed IDs are reported for a batch that closed nothing", rec["closed"] == [], str(rec))
tr.finish()
ACCOUNTED = tr.drain()
check("the episodes account for every accepted observation and nothing else",
      sum(e["observations"] for e in ACCOUNTED) == 5
      and sorted((e["track_id"], e["observations"], e["ambiguous_batches"]) for e in ACCOUNTED)
      == [("t00000001", 1, 1), ("t00000002", 1, 1), ("t00000003", 2, 0), ("t00000004", 1, 0)],
      str(sorted((e["track_id"], e["observations"]) for e in ACCOUNTED)))
check("every episode carries this tracker's own scope",
      all((e["camera_id"], e["unit_id"]) == (CAM, UNIT) for e in ACCOUNTED))

# A batch whose detections all land in one ambiguous component starts nothing.
tr = new_tracker({"gate_base": 0.5, "gate_speed": 0.0, "ambiguity_margin": 1000000})
feed_one(tr, 0, 0, [cdet("a", 0.25, 0.5), cdet("b", 0.375, 0.5)])
rec = feed_one(tr, 1, 1000, [cdet("m1", 0.28125, 0.5), cdet("m2", 0.34375, 0.5)])
check("a wholly ambiguous batch assigns nothing and births nothing",
      all(a["status"] == "ambiguous" and a["track_id"] is None for a in rec["assignments"])
      and rec["closed"] == [], str(rec))
check("...and the next batch still allocates t00000003, the ID the abstained one skipped",
      pairs(feed_one(tr, 2, 2000, [cdet("n", 0.9, 0.1)])) == [("n", "t00000003", "born", None)])

# Two cameras and two units in one process never share an ID space or a track.
SCOPES = [("cam-x", "unit-1"), ("cam-x", "unit-2"), ("cam-y", "unit-1")]
trackers = [Tracker(c, u) for c, u in SCOPES]
for i, t in enumerate(trackers):
    t.feed({"camera_id": SCOPES[i][0], "unit_id": SCOPES[i][1], "seq": 0, "t_ms": 0,
            "detections": [{"id": "d", "bbox": [0.1 * i + 0.1, 0.1, 0.04, 0.04]}]})
check("each camera/unit scope keeps its own ID counter starting at t00000001",
      all(t.snapshot()["state"]["next_id"] == 2 for t in trackers))
check("...and refuses a batch addressed to a sibling scope",
      code_of(trackers[0].feed, {"camera_id": SCOPES[1][0], "unit_id": SCOPES[1][1],
                                 "seq": 1, "t_ms": 1000, "detections": []}) == "wrong_scope")

# =========================================================================
print("\n--- evidence: episode measurements and the bounded path")
# =========================================================================
tr = new_tracker({"path_points": 4, "max_gap_ms": 10000, "max_area_ratio": 100.0})
boxes = [(0.10, 0.13, 0.04, 0.04), (0.20, 0.10, 0.10, 0.10), (0.30, 0.12, 0.06, 0.06),
         (0.40, 0.13, 0.04, 0.04), (0.50, 0.13, 0.04, 0.04)]
for n, (x, y, w, h) in enumerate(boxes):
    feed_one(tr, n, n * 1000, [det(f"d{n}", x, y, w, h)])
tr.finish()
ep = tr.drain()[0]
check("bbox is the largest-area accepted box", ep["bbox"] == [0.20, 0.10, 0.10, 0.10], str(ep["bbox"]))
check("bbox_at_ms is that box's own timestamp", ep["bbox_at_ms"] == 1000, str(ep["bbox_at_ms"]))
check("start/end are the first and last accepted observation",
      ep["start_ms"] == 0 and ep["end_ms"] == 4000, str(ep))
check("observations counts accepted detections including birth", ep["observations"] == 5, str(ep))
check("first and last centres come from actual observations",
      H.equal(ep["first_center"], [0.12, 0.15]) and H.equal(ep["last_center"], [0.52, 0.15]),
      str((ep["first_center"], ep["last_center"])))
check("path_length is the sum over EVERY accepted step, not the simplified path",
      H.equal(ep["path_length"], 0.40, ), str(ep["path_length"]))
check("net_displacement is first to last", H.equal(ep["net_displacement"], 0.40), str(ep))
check("mean_speed is path_length over elapsed seconds", H.equal(ep["mean_speed"], 0.1),
      str(ep["mean_speed"]))
check("max_observation_gap_ms is the largest accepted gap", ep["max_observation_gap_ms"] == 1000,
      str(ep["max_observation_gap_ms"]))
check("the path is bounded to path_points samples", len(ep["path"]) == 4, str(ep["path"]))
check("the path keeps the first and the latest sample",
      ep["path"][0][0] == 0 and ep["path"][-1][0] == 4000, str(ep["path"]))
check("every path sample is an actual observation timestamp",
      all(s[0] in [0, 1000, 2000, 3000, 4000] for s in ep["path"]), str(ep["path"]))
check("an episode has exactly the section-8 keys", set(ep) == set(tt.EPISODE_KEYS), str(sorted(ep)))

# A zero-duration episode: no mean_speed, no path length, no gap.
tr = new_tracker()
feed_one(tr, 0, 0, [det("a", 0.10, 0.10)])
tr.finish()
ep = tr.drain()[0]
check("a single observation has null mean_speed and zero distances",
      ep["mean_speed"] is None and ep["path_length"] == 0 and ep["net_displacement"] == 0
      and ep["max_observation_gap_ms"] == 0 and ep["observations"] == 1, str(ep))

# Equal-area boxes: the earliest wins the tie.
tr = new_tracker({"max_gap_ms": 10000})
feed_one(tr, 0, 0, [det("a", 0.10, 0.10, 0.10, 0.10)])
feed_one(tr, 1, 1000, [det("b", 0.30, 0.10, 0.10, 0.10)])
feed_one(tr, 2, 2000, [det("c", 0.50, 0.10, 0.10, 0.10)])
tr.finish()
ep = tr.drain()[0]
check("an equal-area tie is won by the earliest observation",
      ep["bbox"] == [0.10, 0.10, 0.10, 0.10] and ep["bbox_at_ms"] == 0, str(ep))

# The prescribed online simplifier: collinear samples tie, and the earliest
# interior timestamp goes first.
tr = new_tracker({"path_points": 3, "max_gap_ms": 10000})
for n in range(4):
    feed_one(tr, n, n * 1000, [det(f"d{n}", 0.10 + 0.05 * n, 0.20)])
tr.finish()
ep = tr.drain()[0]
check("a collinear path drops its earliest interior sample on an exact tie",
      [s[0] for s in ep["path"]] == [0, 2000, 3000], str(ep["path"]))
# A corner is worth more than a straight run: the bend survives.
tr = new_tracker({"path_points": 3, "max_gap_ms": 10000})
for n, (x, y) in enumerate([(0.10, 0.10), (0.20, 0.10), (0.30, 0.10), (0.30, 0.30)]):
    feed_one(tr, n, n * 1000, [det(f"d{n}", x - 0.02, y - 0.02)])
tr.finish()
ep = tr.drain()[0]
check("the simplifier keeps the bend and drops a collinear sample",
      [s[0] for s in ep["path"]] == [0, 2000, 3000], str(ep["path"]))
tr = new_tracker({"path_points": 2, "max_gap_ms": 10000})
for n in range(5):
    feed_one(tr, n, n * 1000, [det(f"d{n}", 0.10 + 0.01 * n, 0.10)])
tr.finish()
ep = tr.drain()[0]
check("path_points=2 keeps only the first and latest sample",
      [s[0] for s in ep["path"]] == [0, 4000] and ep["observations"] == 5, str(ep))

# Ambiguous batches are counted, and no interpolated point ever appears.
tr = new_tracker({"gate_base": 0.5, "gate_speed": 0.0, "ambiguity_margin": 0, "max_gap_ms": 9000})
feed_one(tr, 0, 0, [det("a", 0.20 - 0.02, 0.50 - 0.02), det("b", 0.30 - 0.02, 0.50 - 0.02)])
feed_one(tr, 1, 1000, [det("m", 0.25 - 0.02, 0.50 - 0.02)])
feed_one(tr, 2, 2000, [det("m", 0.25 - 0.02, 0.50 - 0.02)])
tr.finish()
eps = {e["track_id"]: e for e in tr.drain()}
check("two abstentions are counted as two ambiguous_batches",
      all(e["ambiguous_batches"] == 2 for e in eps.values()), str(eps))
check("an abstention contributes no timestamp, centre or path sample",
      all(e["observations"] == 1 and len(e["path"]) == 1 and e["end_ms"] == 0 for e in eps.values()),
      str(eps))
check("no episode invents a position at the unsampled crossing",
      all(all(s[1] != 0.25 for s in e["path"]) for e in eps.values()), str(eps))

# drain() empties the outbox and hands over independent data.
tr = new_tracker({"max_gap_ms": 10})
feed_one(tr, 0, 0, [det("a", 0.10, 0.10)])
feed_one(tr, 1, 100, [det("b", 0.10, 0.10)])
snap = tr.snapshot()
eps = tr.drain()
check("drain returns pending episodes in FIFO order", [e["track_id"] for e in eps] == ["t00000001"],
      str(eps))
check("a repeated drain returns []", tr.drain() == [])
eps[0]["path"].append([999, 9.0, 9.0])
eps[0]["observations"] = 999
check("mutating a drained episode cannot reach an earlier snapshot",
      snap["state"]["outbox"][0]["observations"] == 1
      and len(snap["state"]["outbox"][0]["path"]) == 1)
check("...and the earlier snapshot still restores", Tracker.restore(snap).drain()[0]["observations"] == 1)

# =========================================================================
print("\n--- checkpoints: determinism, equivalence and corruption")
# =========================================================================
tr = new_tracker({"max_gap_ms": 1500, "path_points": 5, "replay_batches": 3,
                  "max_pending": 8, "max_tracks": 4})
for n in range(4):
    feed_one(tr, n, n * 1000, [cdet(f"d{n}", 0.20 + 0.01 * n, 0.20), cdet(f"e{n}", 0.80, 0.80)])
rec = feed_one(tr, 4, 8000, [])                    # a jump that expires both tracks
s1, s2 = tr.snapshot(), tr.snapshot()
check("snapshot() is deterministic and does not mutate anything", s1 == s2, str(s1 == s2))
check("snapshot() closed nothing itself: the expiry batch did, and queued both",
      rec["closed"] == ["t00000001", "t00000002"]
      and [e["track_id"] for e in s1["state"]["outbox"]] == ["t00000001", "t00000002"],
      str(s1["state"]["outbox"]))
pending = tr.drain()
check("snapshot() did not drain the outbox",
      [e["track_id"] for e in pending] == ["t00000001", "t00000002"], str(pending))
check("...and a real drain does change the state, so the outbox is part of it",
      tr.snapshot() != s1)
check("the envelope has exactly schema, state and sha256",
      set(s1) == {"schema", "state", "sha256"} and s1["schema"] == tt.SCHEMA, str(sorted(s1)))
blob = tt.canonical_state_json(s1["state"])
check("sha256 is the digest of the canonical JSON of state",
      s1["sha256"] == hashlib.sha256(blob.encode("utf-8")).hexdigest()
      and len(s1["sha256"]) == 64 and s1["sha256"] == s1["sha256"].lower())
check("the state is JSON-compatible and finite",
      json.loads(blob) == json.loads(json.dumps(json.loads(blob))) and "NaN" not in blob
      and "Infinity" not in blob)

# Restore equivalence, including through a real second process and a different
# hash seed. The checkpoint is deliberately RICH: four queued episodes, two live
# tracks with velocity and a bounded path, and a replay window that is full and
# no longer covers seq 0 -- so a restore that dropped or reordered any of it
# shows up in the continuation instead of hiding behind an empty state.
tr = new_tracker({"max_gap_ms": 1000, "max_pending": 8, "max_tracks": 4,
                  "replay_batches": 3, "path_points": 4})
feed_one(tr, 0, 0, [cdet("a", 0.48, 0.48), cdet("b", 0.88, 0.48)])
feed_one(tr, 1, 500, [cdet("a1", 0.50, 0.48), cdet("b1", 0.90, 0.48)])
feed_one(tr, 2, 1600, [cdet("c", 0.48, 0.48), cdet("d", 0.88, 0.48)])   # the gap closes two
feed_one(tr, 3, 2000, [cdet("c3", 0.50, 0.48), cdet("d3", 0.90, 0.48)])
feed_one(tr, 4, 3100, [cdet("c4", 0.48, 0.48), cdet("d4", 0.88, 0.48)])  # and two more
feed_one(tr, 5, 3600, [cdet("c5", 0.50, 0.48), cdet("d5", 0.90, 0.48)])
feed_one(tr, 6, 4000, [cdet("c6", 0.52, 0.48), cdet("d6", 0.92, 0.48)])
checkpoint = tr.snapshot()
assert len(checkpoint["state"]["outbox"]) == 4, "this checkpoint must queue four episodes"
assert len(checkpoint["state"]["tracks"]) == 2, "this checkpoint must hold two live tracks"
assert [e["seq"] for e in checkpoint["state"]["replay"]] == [4, 5, 6], "and a full replay window"
TAIL = [batch(6, 4000, [cdet("c6", 0.52, 0.48), cdet("d6", 0.92, 0.48)]),   # a replay
        batch(7, 4200, [cdet("c7", 0.54, 0.48), cdet("d7", 0.94, 0.48)]),
        batch(8, 6000, [cdet("c8", 0.56, 0.48)]),                           # closes both
        batch(9, 6200, [])]


def continue_in_process(cp, tail):
    t = Tracker.restore(json.loads(json.dumps(cp)))
    out = [{"receipt": t.feed(b)} for b in tail]
    out.append({"drain": t.drain()})
    out.append({"finish": t.finish()})
    out.append({"drain": t.drain()})
    out.append({"snapshot": t.snapshot()["sha256"]})
    return json.loads(json.dumps(out, sort_keys=True))


def continue_uninterrupted(t, tail):
    out = [{"receipt": t.feed(b)} for b in tail]
    out.append({"drain": t.drain()})
    out.append({"finish": t.finish()})
    out.append({"drain": t.drain()})
    out.append({"snapshot": t.snapshot()["sha256"]})
    return json.loads(json.dumps(out, sort_keys=True))


live = continue_uninterrupted(tr, TAIL)
restored = continue_in_process(checkpoint, TAIL)
check("a restored tracker continues exactly as the uninterrupted one did",
      restored == live, H.describe(live, restored)[:400])
check("restore does not change the canonical state",
      tt.canonical_state_json(Tracker.restore(json.loads(json.dumps(checkpoint))).snapshot()["state"])
      == tt.canonical_state_json(checkpoint["state"]))

CHILD = """
import json, sys
sys.path.insert(0, sys.argv[2])
from temporal_tracks import Tracker
cp = json.load(open(sys.argv[1], encoding="utf-8"))
tail = json.load(open(sys.argv[3], encoding="utf-8"))
t = Tracker.restore(cp)
out = [{"receipt": t.feed(b)} for b in tail]
out.append({"drain": t.drain()})
out.append({"finish": t.finish()})
out.append({"drain": t.drain()})
out.append({"snapshot": t.snapshot()["sha256"]})
print(json.dumps(out, sort_keys=True))
"""
if SHORT:
    print("SKIP  fresh-process checkpoint equivalence (WT_SHORT=1)")
else:
    with tempfile.TemporaryDirectory(prefix="tt-test-") as tmp:
        cp_path = pathlib.Path(tmp) / "checkpoint.json"
        tail_path = pathlib.Path(tmp) / "tail.json"
        child_path = pathlib.Path(tmp) / "child.py"
        cp_path.write_text(json.dumps(checkpoint), encoding="utf-8")
        tail_path.write_text(json.dumps(TAIL), encoding="utf-8")
        child_path.write_text(CHILD, encoding="utf-8")
        runs = []
        for seed in ("0", "12345", "random"):
            proc = subprocess.run([sys.executable, str(child_path), str(cp_path),
                                   str(ROOT / "tools" / "labs"), str(tail_path)],
                                  capture_output=True, timeout=120,
                                  env=dict(os.environ, PYTHONHASHSEED=seed))
            runs.append((seed, proc.returncode, proc.stdout.decode(), proc.stderr.decode()))
        check("the checkpoint survives a file and a fresh process",
              all(rc == 0 for _s, rc, _o, _e in runs),
              str([(s, rc, e[:200]) for s, rc, _o, e in runs if rc != 0]))
        check("the fresh process continues identically to this one",
              all(json.loads(o) == live for _s, rc, o, _e in runs if rc == 0))
        check("no hash seed, path or process changes any output",
              len({o for _s, rc, o, _e in runs if rc == 0}) == 1,
              str([o[:80] for _s, rc, o, _e in runs]))

# Corruption: every one of these must be refused as invalid_snapshot, and a
# recomputed checksum over an invalid state must not rescue it.
def corrupt(fn, rehash=True):
    """Mutate a copy of the checkpoint. With `rehash`, the checksum is recomputed
    over the mutation, so only a REAL invariant check can catch it."""
    cp = json.loads(json.dumps(checkpoint))
    fn(cp)
    if rehash:
        try:
            cp["sha256"] = hashlib.sha256(
                tt.canonical_state_json(cp["state"]).encode("utf-8")).hexdigest()
        except ValueError:
            pass          # a state that cannot be serialised cannot have a matching digest
    return cp


def refuse(name, cp, want="invalid_snapshot"):
    got = code_of(Tracker.restore, cp)
    check(f"restore refuses {name}", got == want, f"got {got!r}")


base = json.loads(json.dumps(checkpoint))
refuse("nothing at all", None)
refuse("a list", [])
refuse("a string", "nope")
refuse("an unknown envelope key", dict(base, extra=1))
refuse("a missing envelope key", {k: v for k, v in base.items() if k != "sha256"})
refuse("another schema", dict(base, schema="labs-temporal-tracker/v2"))
refuse("a non-string schema", dict(base, schema=1))
refuse("a wrong checksum", dict(base, sha256="0" * 64), )
refuse("an uppercase checksum", dict(base, sha256=base["sha256"].upper()))
refuse("a short checksum", dict(base, sha256=base["sha256"][:32]))
refuse("a non-JSON state", dict(base, state={1: 2}))
refuse("a state that is not an object", dict(base, state=[1, 2]))


def _mutate_state(path, value, rehash=True):
    def f(cp):
        node = cp["state"]
        for key in path[:-1]:
            node = node[key]
        node[path[-1]] = value
    return corrupt(f, rehash)


refuse("an unknown state key", corrupt(lambda cp: cp["state"].update({"whatever": 1})))
refuse("a missing state key", corrupt(lambda cp: cp["state"].pop("next_id")))
refuse("an unknown state version", _mutate_state(("v",), 99))
refuse("a non-numeric counter", _mutate_state(("next_id",), "three"))
refuse("a boolean counter", _mutate_state(("next_id",), True))
refuse("a float counter", _mutate_state(("next_id",), 3.0))
refuse("a NaN counter", _mutate_state(("next_id",), float("nan"), rehash=False))
refuse("an infinite counter, unserialisable canonically",
       _mutate_state(("next_id",), float("inf"), rehash=False))
check("canonical_state_json itself refuses NaN and infinity",
      code_of(tt.canonical_state_json, {"x": float("nan")}) == "<ValueError: Out of range float values are not JSON compliant: nan>"
      and code_of(tt.canonical_state_json, {"x": float("inf")}).startswith("<ValueError"))
refuse("a zero counter", _mutate_state(("next_id",), 0))
refuse("a negative counter", _mutate_state(("next_id",), -1))
refuse("a bad camera ID", _mutate_state(("camera_id",), "not an id!"))
refuse("a bad unit ID", _mutate_state(("unit_id",), ""))
refuse("an unknown config key", corrupt(lambda cp: cp["state"]["config"].update({"nope": 1})))
refuse("an out-of-range config value", _mutate_state(("config", "max_gap_ms"), 0))
refuse("a config that breaks max_pending>=max_tracks",
       _mutate_state(("config", "max_pending"), 1))
refuse("a finished flag that is not a bool", _mutate_state(("finished",), 1))
refuse("a high-water seq without a time", _mutate_state(("last_t",), None))
refuse("a high-water time without a seq", _mutate_state(("last_seq",), None))
refuse("an out-of-range high-water time", _mutate_state(("last_t",), -5))
refuse("tracks that are not a list", _mutate_state(("tracks",), {"a": 1}))
refuse("a track ID that is not a track ID",
       corrupt(lambda cp: cp["state"]["tracks"][0].update({"tid": "x1"})))
refuse("a track ID that disagrees with its counter",
       corrupt(lambda cp: cp["state"]["tracks"][0].update({"tid": "t00000099"})))
refuse("a duplicate track ID",
       corrupt(lambda cp: cp["state"]["tracks"].append(json.loads(json.dumps(cp["state"]["tracks"][0])))))
refuse("tracks out of creation order",
       corrupt(lambda cp: cp["state"]["tracks"].reverse()))
refuse("a track observed after the high-water time",
       corrupt(lambda cp: cp["state"]["tracks"][0].update({"last_t": 10 ** 9})))
refuse("a track with no observations",
       corrupt(lambda cp: cp["state"]["tracks"][0].update({"observations": 0})))
refuse("a track with more path samples than observations",
       corrupt(lambda cp: cp["state"]["tracks"][0].update({"observations": 0, "path": [[0, 0.1, 0.1]]})))
refuse("a negative path length",
       corrupt(lambda cp: cp["state"]["tracks"][0].update({"path_length": -1.0})))
refuse("a path that does not end at the last observation",
       corrupt(lambda cp: cp["state"]["tracks"][0]["path"][-1].__setitem__(0, 1)))
refuse("a non-finite centre",
       corrupt(lambda cp: cp["state"]["tracks"][0].update({"cx": float("inf")})))
refuse("a centre that is not the last box's centre",
       corrupt(lambda cp: cp["state"]["tracks"][0].update({"cx": 0.9})))
refuse("a prev without a second observation",
       corrupt(lambda cp: cp["state"]["tracks"][0].update({"observations": 1, "prev": [0.1, 0.1, 0]})))
refuse("an impossible appearance descriptor",
       corrupt(lambda cp: cp["state"]["tracks"][0].update({"appearance": [1, 1, 1, 1]})))
refuse("more tracks than max_tracks",
       corrupt(lambda cp: cp["state"].update(
           {"config": dict(cp["state"]["config"], max_tracks=1, max_pending=8),
            "tracks": cp["state"]["tracks"] + cp["state"]["tracks"]})))
refuse("an episode with an unknown key",
       corrupt(lambda cp: cp["state"]["outbox"] and cp["state"]["outbox"][0].update({"nope": 1})))
refuse("an episode with a missing key",
       corrupt(lambda cp: cp["state"]["outbox"][0].pop("path_length")))
refuse("an episode with an impossible reason",
       corrupt(lambda cp: cp["state"]["outbox"][0].update({"reason": "lost"})))
refuse("an episode whose end precedes its start",
       corrupt(lambda cp: cp["state"]["outbox"][0].update({"end_ms": -1})))
refuse("an episode whose mean_speed is not path_length/elapsed",
       corrupt(lambda cp: cp["state"]["outbox"][0].update({"mean_speed": 99.0})))
refuse("an episode whose net displacement exceeds its path",
       corrupt(lambda cp: cp["state"]["outbox"][0].update({"net_displacement": 99.0})))
refuse("an episode from another camera",
       corrupt(lambda cp: cp["state"]["outbox"][0].update({"camera_id": "someone-else"})))
refuse("an episode path longer than path_points",
       corrupt(lambda cp: cp["state"]["outbox"][0].update(
           {"path": [[i, 0.1, 0.1] for i in range(0, 99)], "observations": 99})))
refuse("more queued episodes than max_pending",
       corrupt(lambda cp: cp["state"].update(
           {"config": dict(cp["state"]["config"], max_pending=1, max_tracks=1),
            "outbox": cp["state"]["outbox"] + cp["state"]["outbox"]})))
refuse("a replay entry with a receipt for another seq",
       corrupt(lambda cp: cp["state"]["replay"][0].update({"seq": 99})))
refuse("a replay entry whose receipt claims to be a replay",
       corrupt(lambda cp: cp["state"]["replay"][0]["receipt"].update({"replayed": True})))
refuse("a replay entry outside the retained window",
       corrupt(lambda cp: cp["state"]["replay"][0].update(
           {"seq": 0, "receipt": dict(cp["state"]["replay"][0]["receipt"], seq=0)})))
refuse("more replay entries than replay_batches",
       corrupt(lambda cp: cp["state"].update(
           {"config": dict(cp["state"]["config"], replay_batches=1),
            "replay": cp["state"]["replay"] + [dict(cp["state"]["replay"][-1], seq=99,
                                                    receipt=dict(cp["state"]["replay"][-1]["receipt"],
                                                                 seq=99))]})))
refuse("a replay window with no accepted batch",
       corrupt(lambda cp: cp["state"].update({"last_seq": None, "last_t": None})))
refuse("a finished tracker that still has live tracks",
       corrupt(lambda cp: cp["state"].update({"finished": True})))
check("every refused snapshot left no tracker behind",
      code_of(Tracker.restore, base) is None and Tracker.restore(base).camera_id == CAM)

# Aliasing: nothing returned shares structure with the tracker or the input.
tr = new_tracker({"replay_batches": 2})
cfg = {"max_gap_ms": 1234}
tr = Tracker(CAM, UNIT, cfg)
cfg["max_gap_ms"] = 9999
cfg["injected"] = True
check("mutating the supplied config dict cannot change the tracker",
      tr.config["max_gap_ms"] == 1234 and "injected" not in tr.config, str(tr.config))
b = batch(0, 0, [det("a", 0.10, 0.10, app=[1, 0, 0, 0])])
rec = tr.feed(b)
b["detections"][0]["bbox"][0] = 0.9
b["detections"][0]["appearance"][0] = 0.0
b["t_ms"] = 12345
b["seq"] = 77
check("mutating a supplied batch cannot change the tracker",
      tr.feed(batch(0, 0, [det("a", 0.10, 0.10, app=[1, 0, 0, 0])]))["replayed"] is True)
rec["assignments"][0]["track_id"] = "hijacked"
rec["closed"].append("t99999999")
rec["seq"] = -1
check("mutating a returned receipt cannot change the tracker",
      tr.feed(batch(0, 0, [det("a", 0.10, 0.10, app=[1, 0, 0, 0])]))["seq"] == 0
      and tr.feed(batch(0, 0, [det("a", 0.10, 0.10, app=[1, 0, 0, 0])]))["assignments"][0]["track_id"]
      == "t00000001")
snap = tr.snapshot()
digest = snap["sha256"]
snap["state"]["next_id"] = 999
snap["state"]["tracks"].append({})
snap["sha256"] = "0" * 64
check("mutating a returned snapshot cannot change the tracker",
      tr.snapshot()["sha256"] == digest and tr.snapshot()["state"]["next_id"] == 2)
check("the tracker's own config view is a copy", tr.config is not tr.config)
feed_one(tr, 1, 2000, [det("b", 0.50, 0.50)])
snap = tr.snapshot()
twin = Tracker.restore(snap)
snap["state"]["tracks"][0]["cx"] = 0.999
check("mutating a snapshot cannot change a tracker already restored from it",
      twin.snapshot()["state"]["tracks"][0]["cx"] != 0.999)

# Bounded retained state: the snapshot cannot grow with run length.
tr = new_tracker({"path_points": 8, "replay_batches": 4, "max_pending": 4, "max_tracks": 4})
sizes = []
for n in range(400):
    feed_one(tr, n, n * 100, [det(f"d{n}", 0.10 + 0.0005 * (n % 7), 0.10),
                              det(f"e{n}", 0.70, 0.70)])
    tr.drain()
    if n in (10, 100, 399):
        sizes.append((n, len(tt.canonical_state_json(tr.snapshot()["state"]).encode("utf-8"))))
check("retained state stays bounded as the run grows",
      sizes[2][1] <= sizes[0][1] * 1.2 and sizes[1][1] <= sizes[0][1] * 1.2, str(sizes))
check("...and the retained replay window is exactly replay_batches entries",
      len(tr.snapshot()["state"]["replay"]) == 4, str(len(tr.snapshot()["state"]["replay"])))

# The same property at the LARGEST configuration the contract allows: 128 live
# tracks holding 128 path samples each, 128 retained batch identities of 128
# detections each. Retained state must be a function of the LIMITS, so after the
# bounds are reached the checkpoint stops growing however long the stream runs.
BIG = {"max_tracks": 128, "max_detections": 128, "path_points": 128,
       "replay_batches": 128, "max_pending": 1024, "gate_base": 0.02,
       "gate_speed": 0.0, "max_gap_ms": 10000}
GRID = [(0.04 + 0.085 * (i % 12), 0.04 + 0.085 * (i // 12)) for i in range(128)]
big = new_tracker(BIG)
big_sizes = []
for n in range(200):
    feed_one(big, n, n * 100, [cdet(f"d{j}", GRID[j][0] + 0.001 * (n % 5), GRID[j][1])
                               for j in range(128)])
    big.drain()
    if n in (20, 150, 199):
        big_sizes.append((n, len(tt.canonical_state_json(big.snapshot()["state"]).encode("utf-8"))))
BIG_STATE = big.snapshot()["state"]
check("at the maximum configuration all 128 tracks stay live and matched",
      len(BIG_STATE["tracks"]) == 128
      and all(t["observations"] == 200 for t in BIG_STATE["tracks"]),
      str((len(BIG_STATE["tracks"]), BIG_STATE["tracks"][0]["observations"])))
check("each track holds at most path_points samples after 200 observations",
      all(len(t["path"]) == 128 for t in BIG_STATE["tracks"]))
check("the replay window holds exactly replay_batches identities of 128 detections",
      len(BIG_STATE["replay"]) == 128
      and all(len(e["input"][2]) == 128 for e in BIG_STATE["replay"]))
check("the maximum-configuration checkpoint grows only until its bounds are reached",
      big_sizes[0][1] < big_sizes[1][1] / 2, str(big_sizes))
check("...and then stops: two saturated checkpoints 49 batches apart differ by under 2%",
      big_sizes[2][1] <= big_sizes[1][1] * 1.02, str(big_sizes))
BIG_BYTES = big_sizes[2][1]
check(f"and it is still a small, writable object ({BIG_BYTES} bytes at every limit maximised)",
      BIG_BYTES < 8 * 1024 * 1024, str(BIG_BYTES))
big_checkpoint = big.snapshot()
big_twin = Tracker.restore(json.loads(json.dumps(big_checkpoint)))
check("a maximum-configuration checkpoint restores to an identical checkpoint",
      big_twin.snapshot() == big_checkpoint)
check("...and continues identically",
      [a["status"] for a in big_twin.feed(batch(200, 20000,
                                                [cdet(f"d{j}", GRID[j][0], GRID[j][1])
                                                 for j in range(128)]))["assignments"]]
      == ["matched"] * 128)

# =========================================================================
print("\n--- validation: configuration, batches, detections and numbers")
# =========================================================================
check("a malformed constructor camera ID is invalid_input",
      code_of(Tracker, "has space", UNIT) == "invalid_input")
check("a malformed constructor unit ID is invalid_input",
      code_of(Tracker, CAM, "x" * 65) == "invalid_input")
check("a non-string camera ID is invalid_input", code_of(Tracker, 7, UNIT) == "invalid_input")
for good in ("a", "A9", "cam-1_x.2:y", "z" * 64):
    check(f"ID {good[:12]!r}... is accepted", code_of(Tracker, good, good) is None)
for bad in ("", "has space", "x" * 65, "ünicode", "a/b", "a b", None, 3, True):
    check(f"ID {bad!r} is refused", code_of(Tracker, bad, UNIT) == "invalid_input")

BOUNDS = {k: v for k, v in tt.CONFIG_SPEC.items()}
check("the resolved default configuration is the contract's table",
      tt.DEFAULT_CONFIG == {"gate_base": 0.15, "gate_speed": 0.10, "max_speed": 1.0,
                            "max_gap_ms": 2000, "max_span_ms": 299000, "max_area_ratio": 4.0,
                            "appearance_weight": 0.25, "appearance_gate": 0.50,
                            "ambiguity_margin": 1000, "max_tracks": 64, "max_detections": 64,
                            "max_pending": 256, "replay_batches": 32, "path_points": 32},
      str(tt.DEFAULT_CONFIG))
check("an omitted config takes its default and an int real is accepted",
      new_tracker().config == tt.resolve_config(None)
      and new_tracker({"max_area_ratio": 100}).config["max_area_ratio"] == 100.0)
# max_pending >= max_tracks is a cross-key rule, so testing one bound of either
# key needs a companion value for the other; every other key stands alone.
COMPANION = {"max_pending": {"max_tracks": 1}, "max_tracks": {"max_pending": 1024}}
for key, (default, kind, low, high, low_open, high_open) in sorted(BOUNDS.items()):
    good_low = low + 1 if low_open else low
    good_high = high - 1 if high_open else high
    cfg = {key: good_low if kind == "int" else float(good_low), **COMPANION.get(key, {})}
    check(f"{key}: the low bound {good_low} is accepted",
          code_of(new_tracker, cfg) is None, str(code_of(new_tracker, cfg)))
    cfg = {key: good_high if kind == "int" else float(good_high), **COMPANION.get(key, {})}
    check(f"{key}: the high bound {good_high} is accepted",
          code_of(new_tracker, cfg) is None, str(code_of(new_tracker, cfg)))
    bad_low = low if low_open else low - 1
    bad_high = high if high_open else high + 1
    check(f"{key}: {bad_low} is below its range -> invalid_config",
          code_of(new_tracker, {key: bad_low if kind == "int" else float(bad_low)})
          == "invalid_config")
    check(f"{key}: {bad_high} is above its range -> invalid_config",
          code_of(new_tracker, {key: bad_high if kind == "int" else float(bad_high)})
          == "invalid_config")
    if kind == "int":
        check(f"{key}: a float is not an integer -> invalid_config",
              code_of(new_tracker, {key: float(good_low)}) == "invalid_config")
        check(f"{key}: a bool is not an integer -> invalid_config",
              code_of(new_tracker, {key: True}) == "invalid_config")
        check(f"{key}: a numeric string is not an integer -> invalid_config",
              code_of(new_tracker, {key: str(good_low)}) == "invalid_config")
    else:
        check(f"{key}: NaN is refused -> invalid_config",
              code_of(new_tracker, {key: float("nan")}) == "invalid_config")
        check(f"{key}: infinity is refused -> invalid_config",
              code_of(new_tracker, {key: float("inf")}) == "invalid_config")
        check(f"{key}: a numeric string is refused -> invalid_config",
              code_of(new_tracker, {key: "0.5"}) == "invalid_config")
        check(f"{key}: a bool is not a real -> invalid_config",
              code_of(new_tracker, {key: False}) == "invalid_config")
check("an unknown configuration key is invalid_config",
      code_of(new_tracker, {"gate_base": 0.2, "nope": 1}) == "invalid_config")
check("a misspelled configuration key is invalid_config, not a silent default",
      code_of(new_tracker, {"max_gap": 10}) == "invalid_config")
check("max_pending < max_tracks is invalid_config",
      code_of(new_tracker, {"max_tracks": 8, "max_pending": 7}) == "invalid_config")
check("max_pending == max_tracks is allowed",
      code_of(new_tracker, {"max_tracks": 8, "max_pending": 8}) is None)
check("a non-object config is invalid_config", code_of(new_tracker, [1, 2]) == "invalid_config")
check("a non-numeric config value is invalid_config",
      code_of(new_tracker, {"gate_base": "wide"}) == "invalid_config")

# Batch structure.
tr = new_tracker()
for name, mut in (
        ("a missing key", lambda b: b.pop("t_ms")),
        ("an unknown key", lambda b: b.update({"extra": 1})),
        ("a non-object batch", None),
        ("a non-list detections", lambda b: b.update({"detections": {"a": 1}})),
        ("a string detections", lambda b: b.update({"detections": "abc"})),
        ("a float seq", lambda b: b.update({"seq": 0.0})),
        ("a bool seq", lambda b: b.update({"seq": False})),
        ("a negative seq", lambda b: b.update({"seq": -1})),
        ("a seq past its maximum", lambda b: b.update({"seq": 2147483648})),
        ("a float t_ms", lambda b: b.update({"t_ms": 0.0})),
        ("a negative t_ms", lambda b: b.update({"t_ms": -1})),
        ("a t_ms past its maximum", lambda b: b.update({"t_ms": 9007199254740992})),
        ("a non-bool reset", lambda b: b.update({"reset": 1})),
        ("a bad camera ID", lambda b: b.update({"camera_id": "no pe"})),
        ("a detection that is not an object", lambda b: b.update({"detections": ["a"]})),
        ("a detection without an id", lambda b: b.update({"detections": [{"bbox": [0, 0, 0.1, 0.1]}]})),
        ("a detection without a bbox", lambda b: b.update({"detections": [{"id": "a"}]})),
        ("a detection with an unknown key",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0, 0.1, 0.1], "score": 1}]})),
        ("a duplicate detection ID",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0, 0.1, 0.1]},
                                            {"id": "a", "bbox": [0.5, 0.5, 0.1, 0.1]}]})),
        ("a malformed detection ID",
         lambda b: b.update({"detections": [{"id": "has space", "bbox": [0, 0, 0.1, 0.1]}]})),
        ("a bbox of three numbers",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0, 0.1]}]})),
        ("a bbox of five numbers",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0, 0.1, 0.1, 0.1]}]})),
        ("a bbox that is a string",
         lambda b: b.update({"detections": [{"id": "a", "bbox": "0,0,.1,.1"}]})),
        ("a negative bbox origin",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [-0.1, 0, 0.1, 0.1]}]})),
        ("a zero bbox side",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0, 0, 0.1]}]})),
        ("a bbox side below 1e-6",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0, 1e-7, 0.1]}]})),
        ("a bbox wider than the frame",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0.95, 0, 0.1, 0.1]}]})),
        ("a bbox wider than the frame by less than a millionth",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0.9000005, 0, 0.1, 0.1]}]})),
        ("a bbox taller than the frame by less than a millionth",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0.9000005, 0.1, 0.1]}]})),
        ("a bbox taller than the frame",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0.95, 0.1, 0.1]}]})),
        ("a NaN in a bbox",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [float("nan"), 0, 0.1, 0.1]}]})),
        ("an infinity in a bbox",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0, float("inf"), 0.1]}]})),
        ("a numeric string in a bbox",
         lambda b: b.update({"detections": [{"id": "a", "bbox": ["0", 0, 0.1, 0.1]}]})),
        ("a bool in a bbox",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [True, 0, 0.1, 0.1]}]})),
        ("an appearance of three numbers",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0, 0.1, 0.1],
                                             "appearance": [1, 0, 0]}]})),
        ("an appearance that does not sum to 1",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0, 0.1, 0.1],
                                             "appearance": [0.5, 0.2, 0.2, 0.0]}]})),
        ("an appearance outside 0..1",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0, 0.1, 0.1],
                                             "appearance": [1.5, -0.5, 0, 0]}]})),
        ("an appearance with a NaN",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0, 0.1, 0.1],
                                             "appearance": [float("nan"), 1, 0, 0]}]})),
        ("an appearance that is a string",
         lambda b: b.update({"detections": [{"id": "a", "bbox": [0, 0, 0.1, 0.1],
                                             "appearance": "1,0,0,0"}]})),
):
    b = batch(0, 0, [det("a", 0.10, 0.10)])
    if mut is None:
        payload = "not an object"
        got = code_of(tr.feed, payload)
    else:
        mut(b)
        got = code_of(tr.feed, b)
    check(f"batch validation: {name} -> invalid_input", got == "invalid_input", str(got))

check("an appearance summing to 1 within 1e-9 is accepted",
      code_of(tr.feed, batch(0, 0, [det("a", 0.1, 0.1, app=[1 / 3, 1 / 3, 1 / 3, 0])])) is None)
check("an appearance summing to 1 outside 1e-9 is refused",
      code_of(tr.feed, batch(1, 1, [det("a", 0.1, 0.1, app=[0.5, 0.5, 0.002, 0])]))
      == "invalid_input")
check("an empty detection list is valid and advances time",
      new_tracker().feed(batch(0, 0, [])) == {"seq": 0, "replayed": False, "assignments": [],
                                              "closed": []})
tr = new_tracker({"max_detections": 2})
check("more detections than max_detections is invalid_input",
      code_of(tr.feed, batch(0, 0, [det("a", 0.1, 0.1), det("b", 0.5, 0.1), det("c", 0.8, 0.1)]))
      == "invalid_input")
check("exactly max_detections is accepted",
      code_of(tr.feed, batch(0, 0, [det("a", 0.1, 0.1), det("b", 0.5, 0.1)])) is None)
check("the refused over-long batch did not advance the tracker",
      tr.feed(batch(1, 1000, []))["seq"] == 1)
check("a bbox exactly filling the frame is valid",
      code_of(new_tracker().feed, batch(0, 0, [{"id": "a", "bbox": [0, 0, 1, 1]}])) is None)
check("a bbox touching the far edge exactly is valid",
      code_of(new_tracker().feed, batch(0, 0, [{"id": "a", "bbox": [0.9, 0.9, 0.1, 0.1]}])) is None)

# A Python caller may hand over tuples and mappings; the API returns lists and
# dicts either way, and the extremes of every documented range are accepted.
import types                                                  # noqa: E402

tr = new_tracker()
rec = tr.feed({"camera_id": CAM, "unit_id": UNIT, "seq": 0, "t_ms": 0,
               "detections": ({"id": "a", "bbox": (0.1, 0.1, 0.1, 0.1),
                              "appearance": (1, 0, 0, 0)},)})
check("tuple detections, bbox and appearance are accepted and normalised to lists",
      pairs(rec) == [("a", "t00000001", "born", None)]
      and tr.snapshot()["state"]["tracks"][0]["bbox"] == [0.1, 0.1, 0.1, 0.1], str(rec))
check("a Mapping that is not a dict is accepted as config",
      Tracker(CAM, UNIT, types.MappingProxyType({"gate_base": 0.2})).config["gate_base"] == 0.2)
tr = new_tracker()
check("a seq above the documented maximum is invalid_input, not sequence_error",
      code_of(tr.feed, batch(2147483648, 0, [])) == "invalid_input")
# The top of the seq range is only reachable through a checkpoint: the first new
# batch must be seq 0 and every new batch must be the previous plus one.
TOP = new_tracker().snapshot()
TOP["state"]["last_seq"] = 2147483646
TOP["state"]["last_t"] = 1
TOP["sha256"] = hashlib.sha256(
    tt.canonical_state_json(TOP["state"]).encode("utf-8")).hexdigest()
tr = Tracker.restore(TOP)
check("seq at its documented maximum is accepted",
      tr.feed(batch(2147483647, 2, []))["seq"] == 2147483647)
check("...after which no further NEW batch is representable",
      code_of(tr.feed, batch(2147483648, 3, [])) == "invalid_input"
      and code_of(tr.feed, batch(2147483647, 3, [])) == "replay_conflict"
      and code_of(tr.feed, batch(2147483646, 3, [])) == "stale_replay"
      and tr.feed(batch(2147483647, 2, []))["replayed"] is True)
tr = new_tracker()
check("t_ms at its documented maximum is accepted",
      tr.feed(batch(0, 9007199254740991, []))["seq"] == 0)
check("...and a later batch cannot exceed it, which is sequence_error not a crash",
      code_of(tr.feed, batch(1, 9007199254740991, [])) == "sequence_error")
tr = new_tracker({"max_detections": 128, "max_tracks": 128, "max_pending": 1024})
rec = tr.feed(batch(0, 0, [{"id": f"d{i}", "bbox": [0.001 * i, 0.001, 1e-6, 1e-6]}
                           for i in range(128)]))
check("128 detections, the documented maximum, are all accounted for",
      len(rec["assignments"]) == 128 and all(a["status"] == "born" for a in rec["assignments"]))
check("129 detections are refused",
      code_of(tr.feed, batch(1, 1, [{"id": f"d{i}", "bbox": [0.001 * i, 0.001, 1e-6, 1e-6]}
                                     for i in range(129)])) == "invalid_input")
try:
    import numpy as np                                        # noqa: E402
    tr = new_tracker()
    rec = tr.feed(batch(0, 0, [{"id": "a", "bbox": [np.float64(0.1), np.float64(0.1), 0.1, 0.1]}]))
    check("a NumPy float measurement is accepted and converted to a JSON-native float",
          pairs(rec) == [("a", "t00000001", "born", None)]
          and all(type(v) is float for v in tr.snapshot()["state"]["tracks"][0]["bbox"]),
          str(tr.snapshot()["state"]["tracks"][0]["bbox"]))
    check("a NumPy integer is not an integer for an integer-typed field",
          code_of(tr.feed, batch(1, np.int64(1000), [])) == "invalid_input")
except ImportError:
    print("SKIP  NumPy scalar handling -- numpy is not installed on this box")
check("an ID of exactly 64 allowed characters is accepted, and 65 is refused",
      code_of(Tracker, "a" * 64, "u_.:-9") is None
      and code_of(Tracker, "a" * 65, "u") == "invalid_input"
      and code_of(Tracker, "u", "b" * 65) == "invalid_input")

# =========================================================================
print("\n--- the JSONL command line protocol")
# =========================================================================
INIT = {"op": "init", "camera_id": CAM, "unit_id": UNIT, "config": {}}
FEED0 = {"op": "feed", "batch": batch(0, 0, [det("a", 0.10, 0.10)])}
res, rc, err = cli([INIT, FEED0, {"op": "drain"}, {"op": "finish"}, {"op": "drain"}])
check("a successful stream is one response per line and exits 0",
      rc == 0 and len(res) == 5 and err == "", f"rc={rc} err={err[:200]}")
check("a success response is exactly ok and result",
      all(set(r) == {"ok", "result"} and r["ok"] is True for r in res), str(res))
check("init and restore results are null", res[0]["result"] is None, str(res[0]))
check("other results are the Python API's own return values",
      res[1]["result"] == {"seq": 0, "replayed": False,
                           "assignments": [{"detection_id": "a", "track_id": "t00000001",
                                            "status": "born", "reason": None}],
                           "closed": []}
      and res[2]["result"] == [] and res[3]["result"] == ["t00000001"]
      and len(res[4]["result"]) == 1 and res[4]["result"][0]["reason"] == "finish",
      str([r["result"] for r in res])[:400])
res, rc, _ = cli([])
check("an empty stream succeeds with no output and exit 0", rc == 0 and res == [], str((rc, res)))
res, rc, _ = cli([{"op": "drain"}])
check("a command before init is not_initialized and exits 1",
      rc == 1 and res == [{"ok": False, "error": {"code": "not_initialized"}}], str(res))
res, rc, _ = cli([{"op": "snapshot"}, {"op": "finish"}, {"op": "feed", "batch": FEED0["batch"]}])
check("every tracker command before init is not_initialized",
      rc == 1 and all(r["error"]["code"] == "not_initialized" for r in res), str(res))
res, rc, _ = cli([{"op": "init", "camera_id": CAM, "unit_id": UNIT}, {"op": "drain"}])
check("config may be omitted on init and defaults apply", rc == 0 and res[1]["ok"], str(res))
res, rc, _ = cli([INIT, {"op": "feed", "batch": batch(5, 0, [])}])
check("sequence_error passes through the CLI unchanged",
      rc == 1 and res[1] == {"ok": False, "error": {"code": "sequence_error"}}, str(res[1]))
CAP_INIT = {"op": "init", "camera_id": CAM, "unit_id": UNIT, "config": {"max_tracks": 1}}
res, rc, _ = cli([CAP_INIT, FEED0,
                  {"op": "feed", "batch": batch(1, 1000, [det("a", 0.9, 0.9)])},
                  {"op": "feed", "batch": batch(1, 1000, [det("a", 0.11, 0.1)])},
                  {"op": "feed", "batch": batch(1, 1000, [det("a", 0.5, 0.5)])}])
check("capacity and then replay_conflict both pass through the CLI",
      [(r["ok"], (r.get("error") or {}).get("code")) for r in res[1:]]
      == [(True, None), (False, "capacity"), (True, None), (False, "replay_conflict")],
      str(res[1:])[:400])
res, rc, _ = cli([{"op": "init", "camera_id": "bad id", "unit_id": UNIT}])
check("invalid_input from the constructor passes through",
      rc == 1 and res[0]["error"]["code"] == "invalid_input", str(res[0]))
res, rc, _ = cli([INIT, {"op": "feed", "batch": batch(7, 0, [])}])
check("a failure response is exactly ok and error.code, with no message field",
      set(res[1]) == {"ok", "error"} and set(res[1]["error"]) == {"code"}
      and res[1]["ok"] is False, str(res[1]))
res, rc, _ = cli([INIT, {"op": "feed", "batch": batch(5, 0, [])}, {"op": "drain"}])
check("the stream continues after an error", rc == 1 and len(res) == 3 and res[2]["ok"], str(res))

# Unknown op, malformed commands, duplicate keys, non-finite JSON tokens.
for name, cmd in (("an unknown op", {"op": "frobnicate"}),
                  ("a missing op", {"camera_id": CAM}),
                  ("a non-string op", {"op": 7}),
                  ("an unknown key on init", {"op": "init", "camera_id": CAM, "unit_id": UNIT,
                                              "extra": 1}),
                  ("a missing key on init", {"op": "init", "camera_id": CAM}),
                  ("an unknown key on feed", {"op": "feed", "batch": FEED0["batch"], "x": 1}),
                  ("a missing batch on feed", {"op": "feed"}),
                  ("an unknown key on drain", {"op": "drain", "now": True}),
                  ("an unknown key on restore", {"op": "restore"}),
                  ("an unknown key on finish", {"op": "finish", "please": 1}),
                  ("an unknown key on snapshot", {"op": "snapshot", "pretty": True})):
    res, rc, _ = cli([cmd])
    check(f"CLI refuses {name} with invalid_input",
          rc == 1 and res and res[0] == {"ok": False, "error": {"code": "invalid_input"}}, str(res))
res, rc, _ = cli([INIT], )
lines, rc = raw_cli('{"op":"init","camera_id":"c","unit_id":"u","camera_id":"c2"}\n')
check("a duplicate object key is invalid_input",
      rc == 1 and json.loads(lines[0]) == {"ok": False, "error": {"code": "invalid_input"}},
      str(lines))
lines, rc = raw_cli('{"op":"init","camera_id":"c","unit_id":"u","config":{"nested":1,"nested":2}}\n')
check("a duplicate key in a NESTED object is invalid_input", rc == 1 and len(lines) == 1, str(lines))
for token in ("NaN", "Infinity", "-Infinity"):
    lines, rc = raw_cli('{"op":"init","camera_id":"c","unit_id":"u","config":{"gate_base":%s}}\n'
                        % token)
    check(f"a {token} JSON token is invalid_input",
          rc == 1 and json.loads(lines[0])["error"]["code"] == "invalid_input", str(lines))
lines, rc = raw_cli("not json at all\n")
check("bad JSON is invalid_input", rc == 1 and json.loads(lines[0])["error"]["code"] == "invalid_input",
      str(lines))
lines, rc = raw_cli("[1,2,3]\n")
check("a JSON array is not a command", rc == 1 and json.loads(lines[0])["error"]["code"] == "invalid_input",
      str(lines))
lines, rc = raw_cli('"a string"\n')
check("a JSON string is not a command", rc == 1 and json.loads(lines[0])["error"]["code"] == "invalid_input",
      str(lines))
lines, rc = raw_cli("\n\n   \n\t\n")
check("blank lines produce no response at all and exit 0", rc == 0 and lines == [], str(lines))
lines, rc = raw_cli('{"op":"drain"}\n\n{"op":"drain"}\n')
check("blank lines between commands do not shift the responses",
      rc == 1 and len(lines) == 2, str(lines))
res, rc, _ = cli([INIT, FEED0, {"op": "snapshot"}])
check("a stream ends where its last command ended: no implicit finish",
      rc == 0 and len(res) == 3 and res[2]["result"]["state"]["finished"] is False
      and len(res[2]["result"]["state"]["tracks"]) == 1
      and res[2]["result"]["state"]["outbox"] == [], str(res[2])[:300])
res, rc, _ = cli([INIT, FEED0])
check("EOF adds no response of its own and no implicit drain",
      rc == 0 and len(res) == 2 and res[1]["ok"], str(res))
CLOSE_INIT = {"op": "init", "camera_id": CAM, "unit_id": UNIT, "config": {"max_gap_ms": 1000}}
res, rc, _ = cli([CLOSE_INIT, FEED0, {"op": "feed", "batch": batch(1, 2000, [])}])
check("a stream that never drains still exits 0 with exactly one response per line",
      rc == 0 and len(res) == 3 and res[2]["result"]["closed"] == ["t00000001"], str(res))

# init/restore replace the tracker only after validation.
res, rc, _ = cli([INIT, FEED0, {"op": "init", "camera_id": "bad id", "unit_id": UNIT}, {"op": "drain"}])
check("a failed init preserves the previous tracker", rc == 1 and res[1]["ok"]
      and res[2]["error"]["code"] == "invalid_input" and res[3]["ok"], str(res))
res, rc, _ = cli([INIT, FEED0, {"op": "init", "camera_id": "other", "unit_id": UNIT},
                  {"op": "feed", "batch": batch(0, 0, [], camera="other")}])
check("a SUCCESSFUL init replaces the tracker and its scope",
      rc == 0 and res[3]["ok"] and res[3]["result"]["seq"] == 0, str(res))
good = json.loads(json.dumps(checkpoint))
res, rc, _ = cli([INIT, FEED0, {"op": "restore", "snapshot": dict(good, sha256="0" * 64)},
                  {"op": "drain"}])
check("a failed restore preserves the previous tracker",
      rc == 1 and res[2]["error"]["code"] == "invalid_snapshot" and res[3]["ok"]
      and res[3]["result"] == [], str(res))
res, rc, _ = cli([{"op": "restore", "snapshot": good}, {"op": "drain"}])
check("a restore initialises the stream", rc == 0 and res[0]["result"] is None
      and isinstance(res[1]["result"], list) and res[1]["result"], str(res))
res, rc, _ = cli([INIT, {"op": "snapshot"}, {"op": "restore", "snapshot": None}])
check("restore of a non-object snapshot is invalid_snapshot",
      rc == 1 and res[2]["error"]["code"] == "invalid_snapshot", str(res[2]))
res, rc, err = cli([INIT, FEED0, {"op": "snapshot"}])
check("stdout stays finite valid JSONL for a snapshot response",
      rc == 0 and json.dumps(res[2]) and "NaN" not in json.dumps(res[2]), str(rc))
check("the CLI writes no banner and no logging to stdout",
      all(set(r) <= {"ok", "result", "error"} for r in res), str(res))
res, rc, err = cli([INIT], env={"PYTHONHASHSEED": "999"})
res2, rc2, err2 = cli([INIT, FEED0, {"op": "snapshot"}], env={"PYTHONHASHSEED": "1"})
res3, rc3, err3 = cli([INIT, FEED0, {"op": "snapshot"}], env={"PYTHONHASHSEED": "424242"})
check("the CLI's snapshot digest does not depend on the hash seed",
      res2[2]["result"]["sha256"] == res3[2]["result"]["sha256"],
      str((res2[2]["result"]["sha256"], res3[2]["result"]["sha256"])))
proc = subprocess.run([sys.executable, str(CLI), "--help"], capture_output=True, timeout=60)
check("unexpected command-line arguments are refused, not silently ignored",
      proc.returncode == 2 and proc.stdout == b"", str((proc.returncode, proc.stdout[:80])))

# =========================================================================
print("\n--- adapter: MaskFrame mapping and the offline wire preview")
# =========================================================================
import labs_foreground_mask as fm                            # noqa: E402


class Frame:
    def __init__(self, t_s, run, scored, blobs):
        self.t_s = t_s
        self.run = run
        self.scored = scored
        self.blobs = blobs


def blob(label, x, y, w, h, area=None, fw=100, fh=80):
    return fm.Blob(label=label, x=x, y=y, w=w, h=h, area=area if area is not None else w * h,
                   cx=x + w / 2.0, cy=y + h / 2.0, frame_w=fw, frame_h=fh)


b = blob(7, 10, 20, 20, 20, fw=100, fh=80)
f = Frame(1.2345, 2, True, (b,))
got = ad.mask_frame_batch(f, camera_id=CAM, unit_id=UNIT, seq=0, previous_run=1)
check("a real fm.Blob maps to b<label> with its normalised bbox",
      got == {"camera_id": CAM, "unit_id": UNIT, "seq": 0, "t_ms": 1235,
              "detections": [{"id": "b7", "bbox": [0.1, 0.25, 0.2, 0.25]}], "reset": True},
      str(got))
check("t_ms is floor(1000*t_s + 0.5)",
      ad.mask_frame_batch(Frame(0.0, 0, True, ()), camera_id=CAM, unit_id=UNIT, seq=0)["t_ms"] == 0
      and ad.mask_frame_batch(Frame(0.0004, 0, True, ()), camera_id=CAM, unit_id=UNIT,
                              seq=0)["t_ms"] == 0
      and ad.mask_frame_batch(Frame(0.0005, 0, True, ()), camera_id=CAM, unit_id=UNIT,
                              seq=0)["t_ms"] == 1
      and ad.mask_frame_batch(Frame(1.2344999, 0, True, ()), camera_id=CAM, unit_id=UNIT,
                              seq=0)["t_ms"] == 1234)
check("no appearance key is invented for a blob that has none",
      all("appearance" not in d for d in got["detections"]), str(got))
check("reset is true exactly when a previous run was supplied and differs",
      ad.mask_frame_batch(f, camera_id=CAM, unit_id=UNIT, seq=0, previous_run=1)["reset"] is True
      and ad.mask_frame_batch(f, camera_id=CAM, unit_id=UNIT, seq=0, previous_run=2)["reset"] is False
      and ad.mask_frame_batch(f, camera_id=CAM, unit_id=UNIT, seq=0)["reset"] is False)
unscored = ad.mask_frame_batch(Frame(1.0, 3, False, ("not a blob",)),
                               camera_id=CAM, unit_id=UNIT, seq=0)
check("an unscored frame maps to no detections and its blobs are never inspected",
      unscored["detections"] == [] and unscored["reset"] is False, str(unscored))
multi = ad.mask_frame_batch(Frame(2.0, 0, True, (blob(3, 10, 10, 10, 10), blob(11, 50, 50, 10, 10))),
                            camera_id=CAM, unit_id=UNIT, seq=4)
check("every blob of a scored frame becomes a detection, in blob order",
      [d["id"] for d in multi["detections"]] == ["b3", "b11"] and multi["seq"] == 4, str(multi))
check("the adapter's batch is accepted by feed",
      code_of(new_tracker().feed, ad.mask_frame_batch(
          Frame(2.0, 0, True, (blob(3, 10, 10, 10, 10), blob(11, 50, 50, 10, 10))),
          camera_id=CAM, unit_id=UNIT, seq=0)) is None)
check("...and its detection IDs are the blob labels, ordered by feed",
      pairs(new_tracker().feed(ad.mask_frame_batch(
          Frame(2.0, 0, True, (blob(11, 50, 50, 10, 10), blob(3, 10, 10, 10, 10))),
          camera_id=CAM, unit_id=UNIT, seq=0)))
      == [("b11", "t00000001", "born", None), ("b3", "t00000002", "born", None)])
for name, frame, args in (
        ("a negative t_s", Frame(-0.5, 0, True, ()), {}),
        ("a NaN t_s", Frame(float("nan"), 0, True, ()), {}),
        ("an infinite t_s", Frame(float("inf"), 0, True, ()), {}),
        ("a finite t_s too large to express in milliseconds", Frame(1e308, 0, True, ()), {}),
        ("a t_s that rounds past t_ms's maximum", Frame(1e16, 0, True, ()), {}),
        ("a string t_s", Frame("1.0", 0, True, ()), {}),
        ("a None t_s", Frame(None, 0, True, ()), {}),
        ("a bool t_s", Frame(True, 0, True, ()), {}),
        ("a negative run", Frame(1.0, -1, True, ()), {}),
        ("a float run", Frame(1.0, 1.5, True, ()), {}),
        ("a bool scored", Frame(1.0, 0, 1, ()), {}),
        ("a negative previous_run", Frame(1.0, 0, True, ()), {"previous_run": -1}),
        ("a float previous_run", Frame(1.0, 0, True, ()), {"previous_run": 1.0}),
        ("a bad camera_id", Frame(1.0, 0, True, ()), {}),
        ("a float seq", Frame(1.0, 0, True, ()), {}),
        ("a frame with no blobs attribute", None, {}),
        ("a duplicate blob label", Frame(1.0, 0, True, (blob(2, 1, 1, 1, 1), blob(2, 5, 5, 1, 1))), {}),
        ("a negative blob label", Frame(1.0, 0, True, (blob(-1, 1, 1, 1, 1),)), {}),
        ("a float blob label", Frame(1.0, 0, True, (blob(1.5, 1, 1, 1, 1),)), {}),
        ("a blob with no label", Frame(1.0, 0, True, (object(),)), {}),
        ("a zero-width blob box", Frame(1.0, 0, True, (blob(1, 0, 0, 0, 5),)), {}),
        ("a blob box outside the frame", Frame(1.0, 0, True, (blob(1, 95, 0, 10, 5),)), {}),
        ("blobs that are not a sequence", Frame(1.0, 0, True, 5), {}),
):
    kwargs = {"camera_id": CAM, "unit_id": UNIT, "seq": 0}
    if name == "a bad camera_id":
        kwargs["camera_id"] = "not an id"
    if name == "a float seq":
        kwargs["seq"] = 0.0
    kwargs.update(args)
    target = frame if frame is not None else Frame(1.0, 0, True, ())
    if frame is None:
        class NoBlobs:
            t_s = 1.0
            run = 0
            scored = True
        target = NoBlobs()
    got = code_of(ad.mask_frame_batch, target, **kwargs)
    check(f"adapter refuses {name} with invalid_input", got == "invalid_input", str(got))
check("the adapter does not validate blob order or count (feed enforces capacity)",
      code_of(ad.mask_frame_batch,
              Frame(1.0, 0, True, tuple(blob(i, 1, 1, 1, 1) for i in range(200))),
              camera_id=CAM, unit_id=UNIT, seq=0) is None)
check("an over-long adapter batch is then refused by feed, not by the adapter",
      code_of(new_tracker({"max_detections": 2}).feed,
              ad.mask_frame_batch(Frame(1.0, 0, True, tuple(blob(i, 1, 1, 1, 1) for i in range(3))),
                                  camera_id=CAM, unit_id=UNIT, seq=0)) == "invalid_input")
_tr = new_tracker()
_b0 = ad.mask_frame_batch(Frame(1.0001, 0, True, ()), camera_id=CAM, unit_id=UNIT, seq=0)
_b1 = ad.mask_frame_batch(Frame(1.0002, 0, True, ()), camera_id=CAM, unit_id=UNIT, seq=1)
_tr.feed(_b0)
check("two frames that round to the same millisecond are refused by feed, not combined",
      _b0["t_ms"] == _b1["t_ms"] and code_of(_tr.feed, _b1) == "sequence_error",
      str((_b0["t_ms"], _b1["t_ms"])))

# The offline wire preview.
eps = EPISODES_BY_CASE["one-object-unique-and-bounded-path"]
rows = ad.labs_rows(json.loads(json.dumps(eps)),
                    hour_start=datetime.fromisoformat("2026-10-04T03:00:00+03:00"))
check("labs_rows renders the existing ObservationIn names and nothing else",
      rows == [{"start_time": "2026-10-04T00:00:00.000Z", "end_time": "2026-10-04T00:00:03.000Z",
                "object_count": 1, "bbox_x": 0.1, "bbox_y": 0.2, "bbox_w": 0.1, "bbox_h": 0.2,
                "metrics": {"track_id": "t00000001", "observations": 4, "ambiguous_batches": 0,
                            "path_length": 0.15, "net_displacement": 0.15, "mean_speed": 0.05,
                            "max_gap_s": 1, "end_reason": "finish"}}]
      or H.equal(rows, [{"start_time": "2026-10-04T00:00:00.000Z",
                         "end_time": "2026-10-04T00:00:03.000Z", "object_count": 1,
                         "bbox_x": 0.1, "bbox_y": 0.2, "bbox_w": 0.1, "bbox_h": 0.2,
                         "metrics": {"track_id": "t00000001", "observations": 4,
                                     "ambiguous_batches": 0, "path_length": 0.15,
                                     "net_displacement": 0.15, "mean_speed": 0.05,
                                     "max_gap_s": 1, "end_reason": "finish"}}]), str(rows))
check("no ts/span_s alias and no object_class, confidence or kind is added",
      all(set(r) == set(ad.ROW_KEYS) and set(r["metrics"]) == set(ad.METRIC_KEYS)
          and "object_class" not in r["metrics"] and "confidence" not in r["metrics"]
          for r in rows), str(rows))
check("no nested path is smuggled into metrics",
      all(not isinstance(v, (list, dict)) for r in rows for v in r["metrics"].values()))
import worker as W                                           # noqa: E402
check("the worker's own metrics gate accepts every preview row",
      all(W.check_metrics(r["metrics"]) is None for r in rows))
check("the preview obeys the worker's row and span caps",
      len(rows) <= W.MAX_OBSERVATIONS_PER_UNIT
      and all(len(r["metrics"]) <= W.MAX_METRIC_KEYS for r in rows))


def fake_episode(**over):
    """A real two-observation episode, with fields overridden for a limit test.

    Built by running the tracker rather than written by hand, so the base is a
    genuine section-8 episode and only the field under test is synthetic.
    """
    tr = new_tracker()
    feed_one(tr, 0, 0, [det("a", 0.10, 0.10)])
    feed_one(tr, 1, 1000, [det("b", 0.20, 0.10)])
    tr.finish()
    ep = tr.drain()[0]
    ep.update(over)
    return ep


HOUR = datetime(2026, 10, 4, 0, 0, tzinfo=timezone.utc)

# Two tracks over two seconds, so the preview has an order to preserve and a
# non-zero span to render.
tr = new_tracker({"max_gap_ms": 10000})
for n in range(3):
    feed_one(tr, n, n * 1000, [det(f"d{n}", 0.10 + 0.01 * n, 0.10), det(f"e{n}", 0.70, 0.70)])
tr.finish()
EPISODES2 = tr.drain()
rows = ad.labs_rows(EPISODES2, hour_start=HOUR)
check("episode order is preserved into the preview",
      [r["metrics"]["track_id"] for r in rows] == [e["track_id"] for e in EPISODES2]
      == ["t00000001", "t00000002"], str(rows))
check("the row times are hour_start plus start_ms/end_ms, in UTC with milliseconds",
      rows[0]["start_time"] == "2026-10-04T00:00:00.000Z"
      and rows[0]["end_time"] == "2026-10-04T00:00:02.000Z", str(rows[0]))
check("the row bbox is the episode's largest-area box",
      (rows[0]["bbox_x"], rows[0]["bbox_y"], rows[0]["bbox_w"], rows[0]["bbox_h"])
      == tuple(EPISODES2[0]["bbox"]), str(rows[0]))
check("object_count is 1: one tracked region, never a class or a count of blobs",
      all(r["object_count"] == 1 for r in rows), str(rows))
LONG = fake_episode(end_ms=240000, path=[[0, 0.12, 0.12], [240000, 0.22, 0.12]],
                    mean_speed=0.1 / 240.0, max_observation_gap_ms=240000)
check("an episode four minutes long renders its own end time, four minutes on",
      ad.labs_rows([LONG], hour_start=HOUR)[0]["end_time"] == "2026-10-04T00:04:00.000Z",
      str(ad.labs_rows([LONG], hour_start=HOUR)[0]))
check("max_gap_s is max_observation_gap_ms over 1000",
      ad.labs_rows([LONG], hour_start=HOUR)[0]["metrics"]["max_gap_s"] == 240.0)

check("labs_rows refuses more than 500 episodes rather than truncating",
      code_of(ad.labs_rows, [fake_episode()] * 501, hour_start=HOUR) == "invalid_input")
check("labs_rows accepts exactly 500 episodes",
      code_of(ad.labs_rows, [fake_episode()] * 500, hour_start=HOUR) is None)
check("labs_rows refuses an empty episode list only if it is not a list",
      code_of(ad.labs_rows, "nope", hour_start=HOUR) == "invalid_input"
      and ad.labs_rows([], hour_start=HOUR) == [])
check("labs_rows refuses a start_ms outside the hour",
      code_of(ad.labs_rows, [fake_episode(start_ms=3600000, end_ms=3600000)], hour_start=HOUR)
      == "invalid_input")
check("labs_rows refuses a negative start_ms",
      code_of(ad.labs_rows, [fake_episode(start_ms=-1)], hour_start=HOUR) == "invalid_input")
# Every other field of this episode is consistent, so the span rule is the only
# thing that can refuse it: a 300000 ms episode could never join an event group.
SPAN_300000 = dict(end_ms=300000, path=[[0, 0.12, 0.12], [300000, 0.22, 0.12]],
                   mean_speed=0.1 / 300.0, max_observation_gap_ms=300000)
check("labs_rows renders a 299999 ms episode, the longest it may",
      code_of(ad.labs_rows, [fake_episode(**dict(SPAN_300000, end_ms=299999,
                                                 path=[[0, 0.12, 0.12], [299999, 0.22, 0.12]],
                                                 mean_speed=0.1 / 299.999,
                                                 max_observation_gap_ms=299999))],
                            hour_start=HOUR) is None)
check("labs_rows refuses a span of exactly 300000 ms",
      code_of(ad.labs_rows, [fake_episode(**SPAN_300000)], hour_start=HOUR) == "invalid_input")
check("labs_rows refuses a span just over 300000 ms",
      code_of(ad.labs_rows, [fake_episode(**dict(SPAN_300000, end_ms=300001,
                                                 path=[[0, 0.12, 0.12], [300001, 0.22, 0.12]],
                                                 mean_speed=0.1 / 300.001,
                                                 max_observation_gap_ms=300001))],
                            hour_start=HOUR) == "invalid_input")
check("labs_rows refuses an episode that is not a section-8 episode",
      code_of(ad.labs_rows, [{"nope": 1}], hour_start=HOUR) == "invalid_input")
check("labs_rows validates EVERY episode before returning any row",
      code_of(ad.labs_rows, [fake_episode(), {"nope": 1}], hour_start=HOUR) == "invalid_input")
for name, hs in (("naive", datetime(2026, 10, 4, 0, 0)),
                 ("not a datetime", "2026-10-04T00:00:00Z"),
                 ("a minute past the hour", datetime(2026, 10, 4, 0, 1, tzinfo=timezone.utc)),
                 ("a second past the hour", datetime(2026, 10, 4, 0, 0, 1, tzinfo=timezone.utc)),
                 ("a microsecond past the hour",
                  datetime(2026, 10, 4, 0, 0, tzinfo=timezone.utc).replace(microsecond=1)),
                 ("a half-hour zone that does not land on a whole UTC hour",
                  datetime(2026, 10, 4, 3, 0, tzinfo=timezone(timedelta(hours=3, minutes=30))))):
    check(f"labs_rows refuses an hour_start that is {name}",
          code_of(ad.labs_rows, [fake_episode()], hour_start=hs) == "invalid_input")
check("labs_rows accepts any aware whole UTC hour, including a non-UTC zone",
      code_of(ad.labs_rows, [fake_episode()],
              hour_start=datetime(2026, 10, 4, 3, 0, tzinfo=timezone(timedelta(hours=3)))) is None)
check("...and a half-hour zone that normalises ONTO the UTC hour is accepted too",
      code_of(ad.labs_rows, [fake_episode()],
              hour_start=datetime(2026, 10, 4, 3, 30,
                                   tzinfo=timezone(timedelta(hours=3, minutes=30)))) is None)
ONE_SHOT = new_tracker()
feed_one(ONE_SHOT, 0, 0, [det("a", 0.10, 0.10)])
ONE_SHOT.finish()
SOLE = ONE_SHOT.drain()
check("a zero-duration episode renders with a null mean_speed",
      SOLE[0]["mean_speed"] is None
      and ad.labs_rows(SOLE, hour_start=HOUR)[0]["metrics"]["mean_speed"] is None,
      str(SOLE[0]["mean_speed"]))
check("...and the worker's metrics gate accepts that null as a scalar",
      W.check_metrics(ad.labs_rows(SOLE, hour_start=HOUR)[0]["metrics"]) is None)
check("labs_rows does not mutate the episodes it renders",
      (lambda eps: (ad.labs_rows(eps, hour_start=HOUR),
                    eps == json.loads(json.dumps(eps)))[1])(json.loads(json.dumps(EPISODES2))))

# The adapter imports with no image library and no NumPy available at all.
BLOCK = """
import sys
for name in ("cv2", "numpy"):
    sys.modules[name] = None
sys.path.insert(0, sys.argv[1])
import temporal_tracks, temporal_tracks_adapter as ad
tr = temporal_tracks.Tracker("c", "u")
tr.feed({"camera_id": "c", "unit_id": "u", "seq": 0, "t_ms": 0,
         "detections": [{"id": "a", "bbox": [0.1, 0.1, 0.1, 0.1]}]})
tr.finish()
rows = ad.labs_rows(tr.drain(), hour_start=__import__("datetime").datetime(
    2026, 10, 4, tzinfo=__import__("datetime").timezone.utc))
class F:
    t_s, run, scored, blobs = 1.5, 0, False, ()
print(ad.mask_frame_batch(F(), camera_id="c", unit_id="u", seq=1), rows[0]["metrics"]["track_id"])
"""
proc = subprocess.run([sys.executable, "-c", BLOCK, str(ROOT / "tools" / "labs")],
                      capture_output=True, timeout=60)
check("the core and the adapter import and run with cv2 and numpy blocked",
      proc.returncode == 0 and "t00000001" in proc.stdout.decode(),
      proc.stderr.decode()[-400:])
ADAPTER_IMPORTS = [ln.strip() for ln in
                   (ROOT / "tools/labs/temporal_tracks_adapter.py").read_text(encoding="utf-8").split("\n")
                   if ln.strip().startswith(("import ", "from "))]
check("the adapter imports no image or array library, only the standard library and the core",
      not any(("cv2" in ln or "numpy" in ln or "labs_foreground_mask" in ln) for ln in ADAPTER_IMPORTS),
      str(ADAPTER_IMPORTS))
CORE_IMPORTS = [ln.strip() for ln in
                (ROOT / "tools/labs/temporal_tracks.py").read_text(encoding="utf-8").split("\n")
                if ln.strip().startswith(("import ", "from "))]
check("the core imports only the standard library and its own matching helper",
      not any(("cv2" in ln or "numpy" in ln) for ln in CORE_IMPORTS), str(CORE_IMPORTS))

# =========================================================================
print("\n--- scope: nothing existing was rewired")
# =========================================================================
plugins_src = (ROOT / "tools" / "labs" / "plugins.py").read_text(encoding="utf-8")
run_worker_src = (ROOT / "tools" / "labs" / "run_worker.py").read_text(encoding="utf-8")
check("plugins.py does not mention the new tracker", "temporal_tracks" not in plugins_src)
check("run_worker.py does not mention the new tracker", "temporal_tracks" not in run_worker_src)
IMPORT_PROBE = """
import sys
sys.path.insert(0, sys.argv[1])
import plugins, run_worker
leaked = sorted(m for m in sys.modules if m.startswith("temporal_tracks"))
print(",".join(leaked))
"""
proc = subprocess.run([sys.executable, "-c", IMPORT_PROBE, str(ROOT / "tools" / "labs")],
                      capture_output=True, timeout=120)
check("importing the production plugin registry never imports the new tracker or adapter",
      proc.returncode == 0 and proc.stdout.decode().strip() == "",
      f"rc={proc.returncode} imported={proc.stdout.decode().strip()!r} "
      f"stderr={proc.stderr.decode()[-200:]}")
import plugins as P                                          # noqa: E402
import run_worker as RW                                      # noqa: E402
check("the new tracker is not a registered analyser",
      all("temporal" not in name for name in RW.PLUGINS), str(sorted(RW.PLUGINS)))
check("the default plugin registry still builds its own plugins",
      RW.make_plugin("track_linking").name == "track_linking")
check("TrackLinkingPlugin is untouched and still the B6 vendored analyser",
      P.TrackLinkingPlugin.name == "track_linking" and P.TrackLinkingPlugin.wants_raw is True)
import labs_track_linking as tl                              # noqa: E402
check("B6's own Linker/Episode/to_observations interface is still there",
      hasattr(tl, "Linker") and hasattr(tl, "Episode") and hasattr(tl, "to_observations")
      and hasattr(tl, "MAX_OBSERVATIONS") and tl.MAX_OBSERVATIONS == ad.MAX_OBSERVATIONS)
check("the preview's metric caps are the worker's",
      (ad.MAX_METRIC_KEYS, ad.MAX_METRIC_KEY_LEN, ad.MAX_METRIC_STR_LEN, ad.MAX_OBSERVATIONS)
      == (W.MAX_METRIC_KEYS, W.MAX_METRIC_KEY_LEN, W.MAX_METRIC_STR_LEN,
          W.MAX_OBSERVATIONS_PER_UNIT))
vendored = sorted(p.stem for p in (ROOT / "tools" / "labs").glob("labs_*.py"))
check("no new file joined the vendored labs_*.py family",
      vendored == sorted(["labs_audio_energy", "labs_camera_health", "labs_colour_histogram",
                          "labs_framediff", "labs_foreground_mask", "labs_optical_flow",
                          "labs_perceptual_hash", "labs_track_linking"]), str(vendored))

# =========================================================================
print("\n--- determinism and the resource workload")
# =========================================================================
def stream(batches=40, dets=4, order=None):
    """A 40-batch stream with four drifting detections, as one JSON string.

    `order` permutes each batch's detection list before feeding it: detection
    order is immaterial, so every permutation must produce the SAME bytes.
    """
    tr = new_tracker({"max_gap_ms": 3000, "path_points": 6})
    out = []
    for n in range(batches):
        d = []
        for j in range(dets):
            x = 0.05 + 0.2 * j + 0.01 * ((n + j) % 5)
            d.append(det(f"d{j}", min(max(x, 0.0), 0.95), 0.10 + 0.2 * (j % 3)))
        if order is not None:
            d = [d[i] for i in order]
        rec = tr.feed(batch(n, n * 500, d))
        out.append(rec)
        out.extend(tr.drain())
    out.append(tr.finish())
    out.extend(tr.drain())
    out.append(tr.snapshot())
    return json.dumps(out, sort_keys=True, default=repr)


BASE_STREAM = stream()
check("the same stream twice in one process is byte-identical", BASE_STREAM == stream())
check("reversing the detection order in every batch gives the byte-identical stream",
      BASE_STREAM == stream(order=[3, 2, 1, 0]))
check("rotating the detection order in every batch gives the byte-identical stream",
      BASE_STREAM == stream(order=[2, 0, 3, 1]))
check("a stream really did produce tracks and episodes to compare",
      "t00000001" in BASE_STREAM and "observations" in BASE_STREAM)

if SHORT:
    print("SKIP  contract section-13 resource workload (WT_SHORT=1)")
    REP = None
else:
    REP = WL.run()
    a, b = REP["streams"]["a"], REP["streams"]["b"]
    check("stream A fed the contract's 100000 batches of eight detections",
          a["batches"] == 100000 and a["detections"] == 800000, str(a["batches"]))
    check("stream B fed the contract's 250 batches of 32 detections",
          b["batches"] == 250 and b["detections"] == 8000, str(b["batches"]))
    check("every detection of both streams was assigned",
          a["assigned"] == a["detections"] and b["assigned"] == b["detections"],
          str((a["assigned"], b["assigned"])))
    check("no batch of either stream was ambiguous",
          a["ambiguous"] == 0 and b["ambiguous"] == 0, str((a["ambiguous"], b["ambiguous"])))
    check("observation accounting balances: born == episodes, episode observations == assigned",
          a["born"] == a["episodes"] and b["born"] == b["episodes"]
          and a["episode_observations"] == a["assigned"]
          and b["episode_observations"] == b["assigned"],
          str((a["born"], a["episodes"], a["episode_observations"], b["born"], b["episodes"])))
    check("span closures happened and started new tracks, as the contract allows",
          a["closed_reasons"].get("span", 0) > 0 and a["closed_reasons"].get("finish") == 8,
          str(a["closed_reasons"]))
    check("stream B closed only at finish", b["closed_reasons"] == {"finish": 32},
          str(b["closed_reasons"]))
    check("every sampled snapshot is under the 2 MiB cap",
          a["snapshot_bytes_max"] <= WL.SNAPSHOT_BYTE_CAP
          and b["snapshot_bytes_max"] <= WL.SNAPSHOT_BYTE_CAP
          and a["snapshots"] == 100 and b["snapshots"] == 1,
          str((a["snapshots"], a["snapshot_bytes_max"], b["snapshots"], b["snapshot_bytes_max"])))
    check("checkpoint equivalence held inside the workload",
          a["checkpoint_checks"] > 0 and not REP["problems"], str(REP["problems"][:3]))
    check(f"both streams finished inside the 180 s budget ({REP['elapsed_s']} s measured here)",
          REP["elapsed_s"] <= WL.TIME_BUDGET_S, str(REP["elapsed_s"]))
    check(f"additional peak RSS stayed inside 128 MiB ({REP['rss_additional_peak_mib']} MiB here)",
          REP["rss_additional_peak_mib"] <= WL.RSS_BUDGET_MIB, str(REP["rss_additional_peak_mib"]))
    check("the workload reported no invariant problem", not REP["problems"], str(REP["problems"][:5]))
    print(f"      workload: {REP['elapsed_s']} s, "
          f"{REP['throughput_batches_per_s']} batches/s, "
          f"{REP['throughput_detections_per_s']} detections/s, "
          f"peak RSS {REP['rss_peak_mib']} MiB (+{REP['rss_additional_peak_mib']}), "
          f"python {REP['python']}, {REP['cpus']} CPUs visible")

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}", file=sys.stderr)
    sys.exit(1)
print(f"all passed ({_passed[0]} checks)")
