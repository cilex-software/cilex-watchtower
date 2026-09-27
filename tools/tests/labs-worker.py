#!/usr/bin/env python3
"""Labs worker — hermetic tests. No network, no database, no live fleet.

A fake client serves units and segments and can REFUSE on cue with the exact slugs
the running service (1.0.57) returns; a fake decoder hands back synthetic frames.
Every case below is a rule that has already cost somebody a run.
"""
import glob, os, sys, tempfile, pathlib, threading
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "labs"))
import worker as W                                   # noqa: E402
import plugins as P                                  # noqa: E402
import shape_observations as so                      # noqa: E402

fails = []
_passed = [0]
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"   [{detail}]" if detail and not cond else ""))
    if not cond: fails.append(name)
    else: _passed[0] += 1

def _crashed(t, e, tb):
    # An uncaught exception ends the run with exit 1 and, until now, NO failure line: the
    # booth saw "213 PASS, 0 FAIL, exit 1" once (2026-09-27) and the traceback, on
    # stderr, was not kept. Say it on stdout too, where the result is read.
    print(f"FAIL the suite CRASHED after {_passed[0]} passing checks: {t.__name__}: {e}")
    sys.__excepthook__(t, e, tb)
sys.excepthook = _crashed

def _run(cmd, timeout, **kw):
    """subprocess.run that cannot crash the suite: a timeout comes back as returncode
    None with the reason in stderr, so the check that reads it FAILS by name."""
    import subprocess as _sp
    try:
        return _sp.run(cmd, capture_output=True, timeout=timeout, **kw)
    except _sp.TimeoutExpired:
        why = f"TIMED OUT after {timeout} s"
        return _sp.CompletedProcess(cmd, None, "" if kw.get("text") else b"",
                                    why if kw.get("text") else why.encode())

TMP = tempfile.mkdtemp(prefix="wtest-")
def leftovers(): return glob.glob(os.path.join(TMP, "*.ts"))

def unit(cam="cam-a", hour="2026-09-24T10:00:00Z", a="illumination"):
    return W.ScanUnit(cam, hour, a, "2026-09-24T10:20:00Z", 1)

def seg(i, start="2026-09-24T10:00:00+00:00", dur=30.0):
    return W.Segment(f"seg-{i}", f"http://x/labs/segments/seg-{i}", start,
                     "2026-09-24T10:00:30+00:00", dur, 6_000_000, "main", 64, 48, "h264")

class Fake:
    def __init__(self, units=None, segs=None, refuse=None):
        self.units = units or {}          # analyser -> [ScanUnit]
        self.segs = segs or {}            # unit key -> [Segment]
        self.refuse = refuse or {}        # ("claim"|"fetch"|"submit", key) -> [Refusal,...]
        self.submitted, self.claims, self.fetched = [], [], []
        self.seg_calls = []
    def _pop(self, op, key):
        q = self.refuse.get((op, key))
        if q:
            r = q.pop(0)
            if r: raise r
    def claim(self, analyzer, limit):
        self.claims.append(analyzer); self._pop("claim", analyzer)
        u = self.units.get(analyzer, []); self.units[analyzer] = []
        return u, 0
    def segments(self, u, limit, stream_type, window=None, window_at=None):
        self.seg_calls.append((u.camera_id, limit, stream_type))
        self.window_calls = getattr(self, "window_calls", []) + [(window, window_at)]
        return list(self.segs.get((u.camera_id, u.hour_start), []))
    def fetch(self, s, dest):
        self.fetched.append(s.segment_id)
        assert os.path.exists(dest), "worker must hand a real temp path"
        self._pop("fetch", s.segment_id)
        open(dest, "wb").write(b"x" * 100)
        return 100
    def submit(self, u, body):
        self._pop("submit", u.camera_id)
        self.submitted.append((u, body))

def R(status, slug, retryable=None): return W.Refusal(status, slug, retryable, "msg")

def decode_chroma(value):
    def d(path, kf, want_chroma):
        L = np.full((48, 64), 100, np.uint8)
        return [so.Frame(i, float(i * 4), L, value if want_chroma else None) for i in range(4)]
    return d

B1 = P.IlluminationPlugin()
run = lambda c, p, u, **k: W.run_unit(c, p, u, decode=k.pop("decode", decode_chroma(11.5)),
                                      states=k.pop("states", {}), tmpdir=TMP, **k)

# ---------------------------------------------------------------- the error contract
check("422 is a BUG in the worker, never retried", W.action_for(R(422, None)) is W.Action.BUG)
check("analyzer_disabled stops the analyser",      W.action_for(R(409, "analyzer_disabled", False)) is W.Action.STOP_ANALYSER)
check("held elsewhere -> reclaim",                 W.action_for(R(409, "scan_unit_held_by_another_station")) is W.Action.RECLAIM)
check("lease died mid-hour (403) -> reclaim",      W.action_for(R(403, "segment_outside_lease")) is W.Action.RECLAIM)
check("segment gone -> skip that segment only",    W.action_for(R(404, "segment_not_found")) is W.Action.SKIP_SEGMENT)
check("object store down -> retry later",          W.action_for(R(503, "object_storage_unavailable", True)) is W.Action.RETRY_LATER)
check("bad station token -> FATAL",                W.action_for(R(401, "station_token_not_recognised", False)) is W.Action.FATAL)
check("an UNKNOWN slug is FATAL, never guessed",   W.action_for(R(409, "something_new")) is W.Action.FATAL)
check("an unknown slug marked retryable retries",  W.action_for(R(500, "something_new", True)) is W.Action.RETRY_LATER)
check("409 alone decides nothing: slug decides",
      len({W.action_for(R(409, s)) for s in ("analyzer_disabled", "scan_unit_not_open")}) == 2)

# ---------------------------------------------------------------- empty is a result
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]})
o = run(c, B1, u)
check("happy path submits", o.submitted and len(c.submitted) == 1)
body = c.submitted[0][1]
check("body carries analyzer_version and segments_scanned",
      body["segments_scanned"] == 2 and body["analyzer_version"].startswith("b1-1+"))

class Nothing:
    name="illumination"; version="t"; segment_limit=2; keyframes_only=True
    want_chroma=True; stateful=False
    def new_state(self): return None
    def analyse(self, segs, st, u, ctx): return []
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]})
o = run(c, Nothing(), u)
check("ZERO observations is still SUBMITTED (it means 'looked, found nothing')",
      o.submitted and c.submitted and c.submitted[0][1]["observations"] == [])

u = unit(); c = Fake(segs={})
o = run(c, B1, u)
check("an hour with NO segments is submitted as scanned=0, not skipped",
      o.submitted and c.submitted[0][1]["segments_scanned"] == 0)

# ---------------------------------------------------------------- lease and segment loss
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]},
                     refuse={("fetch", "seg-2"): [R(403, "segment_outside_lease")]})
o = run(c, B1, u)
check("lease died mid-hour -> unit ABANDONED, nothing submitted",
      not o.submitted and not c.submitted and o.action is W.Action.RECLAIM)

u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2), seg(3)]},
                     refuse={("fetch", "seg-2"): [R(404, "segment_not_found")]})
o = run(c, B1, u)
check("one missing segment is skipped and the unit still submits",
      o.submitted and o.skipped_segments == 1 and o.segments_scanned == 2)

# ---------------------------------------------------------------- analyser failure
class Boom(Nothing):
    def analyse(self, *a): raise RuntimeError("model exploded")
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]})
o = run(c, Boom(), u)
b = c.submitted[0][1] if c.submitted else {}
check("an analyser crash is REPORTED as failed, not hidden",
      o.submitted and b.get("failed") is True and "RuntimeError" in (b.get("error") or ""))

# ---------------------------------------------------------------- temp files never leak
for f in leftovers(): os.unlink(f)
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]},
                     refuse={("fetch", "seg-2"): [R(403, "segment_outside_lease")]})
run(c, B1, u)
check("temp files removed when a FETCH is refused", leftovers() == [], str(leftovers()))
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]})
def bad_decode(p, k, w): raise ValueError("corrupt segment")
try: run(c, B1, u, decode=bad_decode)
except ValueError: pass
check("temp files removed when DECODE raises", leftovers() == [], str(leftovers()))
run(c, Boom(), unit())
check("temp files removed when the ANALYSER raises", leftovers() == [], str(leftovers()))

# ---------------------------------------------------------------- stream and state
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]})
run(c, B1, u)
check("B1 requests MAIN (its IR floor was measured on main)", c.seg_calls[0][2] == "main", str(c.seg_calls))
check("B1 asks for 2 segments, not the hour", c.seg_calls[0][1] == 2)

class Stateful(Nothing):
    stateful = True; seen = []
    def new_state(self): return object()
    def analyse(self, segs, st, u, ctx): Stateful.seen.append((u.camera_id, id(st))); return []
states = {}
for cam in ("cam-a", "cam-a", "cam-b"):
    uu = unit(cam=cam); cc = Fake(segs={(uu.camera_id, uu.hour_start): [seg(1)]})
    run(cc, Stateful(), uu, states=states)
ids = Stateful.seen
check("ONE state per camera, reused across that camera's units", ids[0][1] == ids[1][1])
check("a different camera gets its own state", ids[0][1] != ids[2][1])

# ---------------------------------------------------------------- the loop
c = Fake(units={"illumination": [unit()]},
         refuse={("claim", "illumination"): [R(503, "object_storage_unavailable", True), None]},
         segs={("cam-a", "2026-09-24T10:00:00Z"): [seg(1)]})
slept = []
rep = W.run_once(c, [B1], decode=decode_chroma(11.5), states={}, sleep=slept.append)
check("a transient claim refusal is retried with backoff", rep.submitted == 1 and slept, str(rep))

c = Fake(units={"illumination": [unit()]},
         refuse={("claim", "illumination"): [R(409, "analyzer_disabled", False)]})
rep = W.run_once(c, [B1], decode=decode_chroma(11.5), states={})
check("analyzer_disabled at claim stops that analyser cleanly",
      "illumination" in rep.stopped_analysers and rep.fatal is None)

c = Fake(refuse={("claim", "illumination"): [R(401, "station_token_not_recognised", False)]})
rep = W.run_once(c, [B1], decode=decode_chroma(11.5), states={})
check("a bad token is FATAL and stops the run", rep.fatal is not None)

c = Fake(refuse={("claim", "illumination"): [R(422, None)]})
slept = []
rep = W.run_once(c, [B1], decode=decode_chroma(11.5), states={}, sleep=slept.append)
check("a 422 is NOT retried", rep.fatal is not None and slept == [])

c = Fake(units={"illumination": [unit()]})
rep = W.run_once(c, [B1], decode=decode_chroma(11.5), states={}, gate=lambda: False)
check("a closed gate claims nothing", c.claims == [] and rep.claimed == 0)

# ---------------------------------------------------------------- B1 translation
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]})
run(c, B1, u, decode=decode_chroma(0.0))
ob = c.submitted[0][1]["observations"][0]
check("B1 reports `ir` from pixels with NO astronomy available", ob["scene_light"] == "ir", str(ob))
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]})
run(c, B1, u, decode=decode_chroma(11.5))
ob = c.submitted[0][1]["observations"][0]
check("...and `unknown` otherwise, never a guessed day/night", ob["scene_light"] == "unknown", str(ob))
check("B1 always carries chroma in metrics for the server to resolve",
      "chroma_mean" in ob.get("metrics", {}))
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]})
run(c, B1, u, decode=decode_chroma(11.5), context={"astronomical": "day"})
check("with astronomy supplied, B1 passes it through",
      c.submitted[0][1]["observations"][0]["scene_light"] == "day")

# ---------------------------------------------------------------- per-segment astronomy
# cilex-vision 1.0.58: Segment.scene_light_astronomical, per SEGMENT. Three states:
# a value; null = "no solar row" (NOT night); key ABSENT = server predates 1.0.58.
def aseg(i, astro, present=True):
    return W.Segment(f"seg-{i}", f"http://x/labs/segments/seg-{i}",
                     "2026-09-24T15:00:00+00:00", "2026-09-24T15:00:30+00:00", 30.0,
                     6_000_000, "main", 64, 48, "h264",
                     scene_light_astronomical=astro, astro_key_present=present)

def b1_rows(segs, chroma=11.5, context=None):
    u = unit(hour="2026-09-24T15:00:00Z"); c = Fake(segs={(u.camera_id, u.hour_start): segs})
    run(c, B1, u, decode=decode_chroma(chroma), context=context or {})
    return c.submitted[0][1]["observations"]

rows = b1_rows([aseg(1, "day"), aseg(2, "dusk")])
check("astronomy is PER SEGMENT: an hour holding sunset files both day AND dusk",
      [r["scene_light"] for r in rows] == ["day", "dusk"], str([r["scene_light"] for r in rows]))

rows = b1_rows([aseg(1, None, present=True)])
check("null means 'no solar row' -> unknown, NEVER coerced to night",
      rows[0]["scene_light"] == "unknown", rows[0]["scene_light"])
check("...and the row says WHY it is unknown",
      rows[0]["metrics"]["astro_source"] == "no_solar_row", str(rows[0]["metrics"].get("astro_source")))

rows = b1_rows([aseg(1, None, present=False)])
check("a MISSING key means an old server, not null -> unknown",
      rows[0]["scene_light"] == "unknown")
check("...recorded as a different fact from null",
      rows[0]["metrics"]["astro_source"] == "server_predates_1_0_58",
      str(rows[0]["metrics"].get("astro_source")))

rows = b1_rows([aseg(1, "day")], chroma=0.0)
check("IR in astronomical DAYLIGHT files `ir`", rows[0]["scene_light"] == "ir")
check("...and STILL records that the sky said day (the disagreement survives per row)",
      rows[0]["metrics"].get("astro") == "day", str(rows[0]["metrics"].get("astro")))
check("...and flags it as a possible stuck filter",
      "stuck filter" in rows[0]["metrics"].get("notes", ""), rows[0]["metrics"].get("notes", ""))

rows = b1_rows([aseg(1, "night")], chroma=11.5)
check("astronomical night WITHOUT IR files `night` and notes the artificial-light case",
      rows[0]["scene_light"] == "night" and "artificially lit" in rows[0]["metrics"].get("notes", ""))

rows = b1_rows([aseg(1, "day", present=True)], context={"astronomical": "night"})
check("the server's per-segment value beats a stale context value",
      rows[0]["scene_light"] == "day")

# ---------------------------------------------------------------- the server's metrics caps
# Enforced in cilex-vision's PYTHON (_clean_metrics), not in its OpenAPI schema -- so a
# schema check alone passes a body the server will 422. Found when a B1 note reached 141.
rows = b1_rows([aseg(1, "night")], chroma=0.0)   # the case that produced 141 chars
b1_single = []
u = unit(hour="2026-09-24T15:00:00Z")
c = Fake(segs={(u.camera_id, u.hour_start): [aseg(1, "night")]})
def one_zero_frame(p, k, w):
    return [so.Frame(0, 0.0, np.full((48, 64), 100, np.uint8), 0.0 if w else None)]
run(c, B1, u, decode=one_zero_frame)
note = c.submitted[0][1]["observations"][0]["metrics"].get("notes", "") if c.submitted else ""
check("the note that reached 141 chars now fits the server's 120",
      0 < len(note) <= W.MAX_METRIC_STR_LEN, f"{len(note)} chars")
check("...and says it was cut rather than pretending it was whole", note.endswith("\u2026"), note[-8:])

for bad, why in (({"x" * 41: 1}, "key too long"), ({"Bad-Key": 1}, "key not a slug"),
                 ({"k": [1, 2]}, "nested value"), ({"k": "y" * 121}, "string too long"),
                 ({f"k{i}": 1 for i in range(25)}, "too many keys")):
    try:
        W.check_metrics(bad); ok = False
    except W.MetricsViolation:
        ok = True
    check(f"check_metrics rejects: {why}", ok)
W.check_metrics({"astro": None, "ir": True, "n": 3, "s": "y" * 120})
check("check_metrics accepts None, bool, number, and a 120-char string", True)

class Oversize(Nothing):
    def analyse(self, segs, st, u, ctx):
        return [{"start_time": "2026-09-24T15:00:00Z", "end_time": "2026-09-24T15:00:00Z",
                 "metrics": {"note": "z" * 500}}]
# A plugin bug is FILED as failed with its real reason -- not raised out of the loop
# (which would kill the worker), and not abandoned to the lease (which cilex-vision's
# code would record as 'lease expired', erasing the cause: labs.py :978/:1038/:1072).
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]})
o = run(c, Oversize(), u)
b = c.submitted[0][1] if c.submitted else {}
check("an oversized metric never reaches the server as an observation",
      b.get("observations") == [], str(b.get("observations"))[:60])
check("...the unit is FILED as failed, not raised out of the loop and not abandoned",
      o.submitted and b.get("failed") is True, f"submitted={o.submitted} body={b}")
check("...and the filed error names the REAL cause, not 'lease expired'",
      "metrics_violation" in (b.get("error") or ""), b.get("error"))

class Refuse422:
    def __init__(self): self.calls = 0
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]},
                     refuse={("submit", u.camera_id): [R(422, None)]})
o = run(c, B1, u)
check("a 422 on submit is filed as failed ONCE with the refusal as its reason",
      len(c.submitted) == 1 and c.submitted[0][1].get("failed") is True
      and "submit_refused" in (c.submitted[0][1].get("error") or ""), str(c.submitted)[:120])

u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]},
                     refuse={("submit", u.camera_id): [R(422, None), R(422, None)]})
o = run(c, B1, u)
check("if filing it failed is refused too, nothing more is tried (no loop)",
      c.submitted == [] and "refused too" in o.note, o.note)

u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]},
                     refuse={("fetch", "seg-2"): [R(403, "segment_outside_lease")]})
o = run(c, B1, u)
check("a LOST lease is still never filed -- the unit is not ours to report on",
      c.submitted == [], str(c.submitted)[:80])

# A FAILURE REPORT MUST CARRY NO OBSERVATIONS. cilex-vision's submit_results checks
# observations (:1441 count cap, :1510 _clean_metrics) BEFORE it reads `failed`
# (:1512), so a report still carrying the offending rows is refused for the very
# reason it reports and ends up 'lease expired'. Each case below uses a plugin that
# DID produce observations, so a leak would be visible rather than vacuously absent.
class ProducesThenBad(Nothing):
    def analyse(self, segs, st, u, ctx):
        return [{"start_time": "2026-09-24T15:00:00Z", "end_time": "2026-09-24T15:00:00Z",
                 "metrics": {"fine": 1}},
                {"start_time": "2026-09-24T15:00:00Z", "end_time": "2026-09-24T15:00:00Z",
                 "metrics": {"bad": "z" * 500}}]
class ProducesThenCrash(Nothing):
    def analyse(self, segs, st, u, ctx):
        self.partial = [{"start_time": "x", "end_time": "x"}]
        raise RuntimeError("after producing rows")

for label, plugin, refuse in (
        ("metrics_violation", ProducesThenBad(), None),
        ("submit_refused",    B1, [R(422, None)]),
        ("analyser_raised",   ProducesThenCrash(), None)):
    u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]},
                         refuse={("submit", u.camera_id): list(refuse)} if refuse else {})
    run(c, plugin, u)
    failed = [b for _, b in c.submitted if b.get("failed")]
    check(f"failure report for {label} carries NO observations",
          len(failed) == 1 and failed[0]["observations"] == [],
          f"{len(failed)} failed bodies; obs={[len(b['observations']) for b in failed]}")
    check(f"...and names {label} as its cause",
          bool(failed) and failed[0]["error"].startswith(label), failed[0]["error"] if failed else "-")

check("filed error is fitted to the server's silent 500-char slice, visibly",
      len(W.fit("e" * 900, 500)) == 500 and W.fit("e" * 900, 500).endswith("\u2026"))

for pl in (P.IlluminationPlugin(), P.ShapePlugin()):
    v = f"{pl.version}+{W.WORKER_VERSION}"
    check(f"analyzer_version fits the server's max_length 64 ({pl.name}: {len(v)})",
          1 <= len(v) <= 64, v)

# PIN THE MIRROR against cilex-vision's source, when their checkout is on this box.
import re
cvsrc = pathlib.Path("/home/cilex-vision/projects/cilex-vision/services/query-api/routers/labs.py")
if cvsrc.exists():
    t = cvsrc.read_text(encoding="utf-8")
    m = re.search(r"analyzer_version: str = Field\(min_length=1, max_length=(\d+)\)", t)
    check(f"analyzer_version cap in cilex-vision's source is still 64 ({m.group(1) if m else None})",
          m is not None and int(m.group(1)) == 64)
    for name in ("MAX_METRIC_KEYS", "MAX_METRIC_KEY_LEN", "MAX_METRIC_STR_LEN"):
        m = re.search(rf"^{name}\s*=\s*(\d+)", t, re.M)
        theirs = int(m.group(1)) if m else None
        check(f"{name} matches cilex-vision's source ({theirs})", theirs == getattr(W, name),
              f"ours {getattr(W, name)}, theirs {theirs}")
    m = re.search(r'^GROUP_MAX_SPAN_S\s*=\s*float\(os\.environ\.get\("LABS_GROUP_MAX_SPAN_S",\s*"(\d+)"\)\)', t, re.M)
    theirs = float(m.group(1)) if m else None
    check(f"GROUP_MAX_SPAN_S matches cilex-vision's source default ({theirs})", theirs == W.GROUP_MAX_SPAN_S,
          f"ours {W.GROUP_MAX_SPAN_S}, theirs {theirs}")
else:
    print("SKIP metrics caps vs cilex-vision source -- their checkout is not on this box")

# ---------------------------------------------------------------- transport failures
# The fault the week's measurements predicted and 72 assertions never injected: the
# server NOT ANSWERING. Every deploy refuses connections for 8.8-17 s. Until
# 2026-09-26 a refused or reset connection at any call escaped as a raw exception and
# crashed the worker -- every fault above is the server answering with a refusal.
import urllib.error
class Gap:
    """Fails at one call site with a real transport exception, n times (inf = never back)."""
    def __init__(self, where, n=10**9, exc=None):
        self.where, self.left, self.bodies, self.exc = where, n, [], exc
    def _hit(self, here):
        if self.where == here and self.left > 0:
            self.left -= 1
            raise self.exc or (ConnectionResetError(104, "reset") if here in ("fetch", "submit")
                               else urllib.error.URLError(ConnectionRefusedError(111, "refused")))
    def claim(self, a, n):
        self._hit("claim"); return [unit(a=a)], 0
    def segments(self, u, n, st, window=None, window_at=None):
        self._hit("segments"); return [seg(1)]
    def fetch(self, sg, d):
        self._hit("fetch"); open(d, "wb").write(b"x"); return 1
    def submit(self, u, b):
        self._hit("submit"); self.bodies.append(b)

for where in ("claim", "segments", "fetch", "submit"):
    try:
        rep = W.run_once(Gap(where), [B1], decode=decode_chroma(11.5), states={}, sleep=lambda s: None)
        ok = True
    except Exception as e:
        ok, rep = False, e
    check(f"a PERMANENT outage at {where} does not crash the worker", ok, repr(rep)[:90])

for where in ("claim", "segments", "fetch", "submit"):
    slept = []; c = Gap(where, n=3)
    rep = W.run_once(c, [B1], decode=decode_chroma(11.5), states={}, sleep=slept.append)
    check(f"a deploy-sized gap at {where} is ridden out and the unit submitted",
          rep.submitted == 1 and len(slept) == 3, f"submitted={rep.submitted} retries={len(slept)}")

c = Gap("claim")
rep = W.run_once(c, [B1], decode=decode_chroma(11.5), states={}, sleep=lambda s: None)
check("a server that never answers is UNREACHABLE, not FATAL",
      rep.unreachable is not None and rep.fatal is None, f"unreachable={rep.unreachable!r} fatal={rep.fatal!r}")
c = Fake(refuse={("claim", "illumination"): [R(401, "station_token_not_recognised", False)]})
rep = W.run_once(c, [B1], decode=decode_chroma(11.5), states={})
check("...while a bad token is still FATAL, not unreachable",
      rep.fatal is not None and rep.unreachable is None)

# The retry must resend the IDENTICAL body: cilex-vision's version-scoped DELETE heals a
# half-written submission only while analyzer_version is unchanged.
c = Gap("submit", n=2)
seen = []
orig = c.submit
def spy(u, b):
    seen.append(id(b)); return orig(u, b)
c.submit = spy
W.run_unit(c, B1, unit(), decode=decode_chroma(11.5), states={}, tmpdir=TMP, sleep=lambda s: None)
check("a retried submission sends the IDENTICAL body, never a rebuilt one",
      len(seen) == 3 and len(set(seen)) == 1, f"{len(seen)} calls, {len(set(seen))} distinct bodies")

# Narrow on purpose: a local disk fault is NOT a network blip and must not be retried away.
c = Gap("fetch", exc=PermissionError(13, "Permission denied"))
try:
    W.run_unit(c, B1, unit(), decode=decode_chroma(11.5), states={}, tmpdir=TMP, sleep=lambda s: None)
    swallowed = True
except PermissionError:
    swallowed = False
check("a PermissionError while fetching is NOT treated as a transient network fault", not swallowed)

check("an HTTPError is the server answering, never classed as transport",
      not W._is_transport(urllib.error.HTTPError("u", 503, "x", {}, None)))
check("a refused connection IS transport",
      W._is_transport(urllib.error.URLError(ConnectionRefusedError(111, "refused"))))
check("the backoff spans the longest measured deploy gap (~17 s)", sum(W.BACKOFF_S) >= 17,
      str(sum(W.BACKOFF_S)))

# ---------------------------------------------------------------- the REAL HTTP client
# Every test above uses a fake client. These drive the real HttpLabsClient against a
# real HTTP server on an ephemeral local port, so its status handling is exercised,
# not assumed.
import http.server, threading, json as _json

class _H(http.server.BaseHTTPRequestHandler):
    status, payload = 200, {}
    seen_token = []
    def _reply(self):
        _H.seen_token.append(self.headers.get("x-cilex-station-token"))
        n = int(self.headers.get("content-length") or 0)
        if n: self.rfile.read(n)
        b = _json.dumps(_H.payload).encode()
        self.send_response(_H.status); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    do_PUT = do_POST = do_GET = _reply
    def log_message(self, *a): pass

srv = http.server.HTTPServer(("127.0.0.1", 0), _H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{srv.server_address[1]}"
hc = W.HttpLabsClient(base, "tok-real-client", timeout_s=5)

# cilex-vision labs.py:1435-1439: a retry after a cut that DID commit returns 200
# {"status": "already_recorded"} BEFORE touching anything -- deliberately a success.
_H.status, _H.payload = 200, {"status": "already_recorded", "observations": 8}
try:
    hc.submit(unit(), {"analyzer_version": "b1-1+w", "segments_scanned": 1, "observations": []})
    ok = True
except Exception as e:
    ok = False
check("REAL client: 200 already_recorded is a SUCCESS, not a refusal", ok)

u = unit(); c = W.HttpLabsClient(base, "tok-real-client", timeout_s=5)
class Via(Fake):                      # real submit, fake everything else
    def submit(self, uu, b): return c.submit(uu, b)
fk = Via(segs={(u.camera_id, u.hour_start): [seg(1)]})
o = run(fk, B1, u)
check("...so a unit whose retry is already_recorded reports submitted, and stops",
      o.submitted and o.action is None, f"submitted={o.submitted} action={o.action}")

_H.status, _H.payload = 409, {"code": "scan_unit_not_open", "detail": "scan_unit_not_open",
                               "message": "gone", "retryable": False}
try:
    hc.submit(unit(), {"analyzer_version": "x", "segments_scanned": 0, "observations": []})
    r = None
except W.Refusal as e:
    r = e
check("REAL client: a coded 409 becomes a Refusal carrying its slug and retryable",
      r is not None and r.detail == "scan_unit_not_open" and r.retryable is False, repr(r))

_H.status, _H.payload = 422, {"detail": [{"type": "missing", "loc": ["body", "x"]}]}
try:
    hc.submit(unit(), {}); r = None
except W.Refusal as e:
    r = e
check("REAL client: a FastAPI 422 (detail is a LIST) parses without crashing",
      r is not None and r.status == 422 and r.detail is None, repr(r))
check("REAL client: sends the station token header", "tok-real-client" in _H.seen_token)
srv.shutdown()

# and a real closed port: nothing listens, exactly what a deploy's refusal window is
dead = W.HttpLabsClient(f"http://127.0.0.1:{srv.server_address[1]}", "t", timeout_s=2)
try:
    W._guard(dead.claim, "illumination", 1); r = None
except W.Refusal as e:
    r = e
check("REAL client: a closed port becomes a retryable transport_error",
      r is not None and r.detail == "transport_error" and W.action_for(r) is W.Action.RETRY_LATER, repr(r))

# ---------------------------------------------------------------- vendored analysers
# These modules are cilex-vision's, vendored BYTE-IDENTICAL: each analyser's thresholds
# are calibrated to its own decoder, and a silent local edit would change what they
# mean (frame_difference's 2.0 is the case that proved it). Each is pinned twice:
#   1. by the hash recorded HERE. This runs on EVERY box, so a local edit fails on the
#      Windows and Mac checkouts too -- they have no cilex-vision source to compare to,
#      and until 2026-09-26 they checked nothing and printed nothing about it;
#   2. against cilex-vision's own file where that checkout exists (the Linux box), so
#      an upstream change fails there until it is re-vendored and its row updated.
# Re-vendor = copy the file from the named commit, then update its row. Never edit it.
VENDORED = {   # module: (cilex-vision commit, sha256 of services/query-api/<module>.py)
    # 3505b6b: `-vsync 0` -> `-fps_mode passthrough` (a current ffmpeg rejects -vsync
    # and decoded NOTHING on the booth); stderr drained on a thread (a noisy stream
    # deadlocked it); a failed zero-frame decode now logs its cause at WARNING.
    "labs_framediff":       ("3505b6b", "0a62674410778f3af657a46348b5d63ab15d02dcc2a75a8689b6fde94929fb71"),
    "labs_camera_health":   ("3505b6b", "74925789d9e73dca067c5ef6e26a21daf499e79a005c4cd691b717c4cbf178cc"),
    "labs_perceptual_hash": ("fde4ab5", "c995830cdf02bd19bdcd21811b7b2e21d527cae4cd731e0390fb165b4fff3e7b"),
    "labs_optical_flow":    ("631241d", "6fbb3493450f6bed39ec05017b008a2bc54db55dd2a5d491882973bda336115f"),
    # 071c278 moved `import resource` off module top (fe28fae's copy made `import
    # plugins` fail on Windows); 21258fd clamps an hour's tail into its last window,
    # since one row starting past the hour's end makes the server refuse the unit.
    "labs_audio_energy":    ("21258fd", "20ba1b82eca02e18c6ae88d478cada3d3ac253ae508b871cb06c86a6ab03835f"),
    # Handed over by the Windows agent (92e7c1b), who cannot read cilex-vision's repo.
    # dd33367: stream-mode MOG2 history from the median of the first real steps; a
    # step under 0.01 s (a keyframe pair, 11 us) is a duplicate. Primed mode, which
    # B3/B7 window scoring uses, is unchanged -- VERSION stays b3-1.
    "labs_foreground_mask":  ("dd33367", "a84ba8d54c9c38a2727196dff89d98b26614ca98ecaed5a062663173b2f8844b"),
    "labs_colour_histogram": ("f7ecd57", "b94271bd1d8dea49e7fbb7fa95fa2ac7049f89df52d802a0fc593223e94d9fcb"),
    # dd33367: VERSION b6-1 -> b6-2 (its stream-mode mask changed through fm).
    "labs_track_linking":    ("dd33367", "09940cbc60f4849c5d39ce894ea18af4e0e64d3ca0440e8c3b9f082cff9bda2d"),
}
import hashlib
_CV = pathlib.Path("/home/cilex-vision/projects/cilex-vision/services/query-api")
_on_disk = {p.stem for p in (ROOT / "tools/labs").glob("labs_*.py")}
check("every vendored labs_*.py has a pin", _on_disk == set(VENDORED),
      f"unpinned {sorted(_on_disk - set(VENDORED))}  pinned-but-absent {sorted(set(VENDORED) - _on_disk)}")
for mod, (commit, pinned) in VENDORED.items():
    ours = hashlib.sha256((ROOT / f"tools/labs/{mod}.py").read_bytes()).hexdigest()
    check(f"vendored {mod}.py matches its pin (cilex-vision {commit})", ours == pinned,
          f"ours {ours[:16]} pinned {pinned[:16]} -- edited locally? re-vendor from {commit}")
    if (_CV / f"{mod}.py").exists():
        theirs = hashlib.sha256((_CV / f"{mod}.py").read_bytes()).hexdigest()
        check(f"...and cilex-vision's {mod}.py has not moved on since {commit}", theirs == pinned,
              f"theirs {theirs[:16]} -- re-vendor it and update its VENDORED row")
    else:
        print(f"SKIP {mod}.py vs cilex-vision's source -- their checkout is not on this box")

# ---------------------------------------------------------------- frame_difference (A1/A2)
import labs_framediff as FDM
FD = P.FrameDifferencePlugin()

u1 = W.ScanUnit("c", "2026-09-26T01:00:00Z", "frame_difference", None, 1)
u2 = W.ScanUnit("c", "2026-09-26T02:00:00Z", "frame_difference", None, 1)
check("window_at is DETERMINISTIC per hour (a retry must score the same minutes)",
      FD.window_at(u1) == FD.window_at(u1))
check("...different hours look at different minutes", FD.window_at(u1) != FD.window_at(u2))
check("...and stays inside 0..1", all(0.0 <= FD.window_at(W.ScanUnit("c", f"2026-09-26T{h:02d}:00:00Z",
      "fd", None, 1)) < 1.0 for h in range(24)))

def fseg(i, dur=30.0, start="2026-09-26T01:10:00+00:00", end="2026-09-26T01:10:30+00:00"):
    return W.Segment(f"f{i}", f"http://x/f{i}", start, end, dur, 5_000_000, "main", 2560, 1440, "hevc")

got = {}
def fake_analyse(chunks, span_s=None, **k):
    got["bytes"] = b"".join(chunks); got["span_s"] = span_s
    return FDM.Scores(peak=9.5, sustained=3, ratio=None, frames=30, median_delta=0.4,
                      sustained_s=12.0, keyframe_interval_s=4.0)
_real = P.fdiff.analyse
P.fdiff.analyse = fake_analyse
try:
    segs = [fseg(1, start="2026-09-26T01:10:00+00:00", end="2026-09-26T01:10:30+00:00"),
            fseg(2, start="2026-09-26T01:10:30+00:00", end="2026-09-26T01:11:00+00:00"),
            fseg(3, start="2026-09-26T01:11:00+00:00", end="2026-09-26T01:11:30+00:00")]
    c = Fake(segs={(u1.camera_id, u1.hour_start): segs})
    o = W.run_unit(c, FD, u1, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    wc = c.window_calls[-1]
    check("asks for a WINDOW, not a limit", wc[0] == 4 and c.seg_calls[-1][2] == "main", str(wc))
    check("...at the deterministic position for this hour", wc[1] == FD.window_at(u1))
    obs = c.submitted[0][1]["observations"] if c.submitted else []
    check("ONE observation per window", len(obs) == 1, str(len(obs)))
    ob = obs[0] if obs else {}
    check("...spanning the first segment's start to the last one's end",
          ob.get("start_time") == "2026-09-26T01:10:00Z" and ob.get("end_time") == "2026-09-26T01:11:30Z", str(ob))
    check("...with NO object class, count, bbox or shape: it observes activity, not an object",
          not {"object_class", "object_count", "bbox_x", "shape_class", "scene_light"} & set(ob))
    check("metrics are as_metrics() passed through UNCHANGED",
          ob.get("metrics") == FDM.Scores(peak=9.5, sustained=3, ratio=None, frames=30, median_delta=0.4,
                                          sustained_s=12.0, keyframe_interval_s=4.0).as_metrics(), str(ob.get("metrics")))
    check("span_s is ALWAYS passed, as the sum of the segments' durations", got.get("span_s") == 90.0, str(got.get("span_s")))
    check("the analyser received every segment's bytes, in order, as a stream", got.get("bytes") == b"x" * 300,
          f"{len(got.get('bytes', b''))} bytes")
    check("one decoder run for the whole window", o.decoder_runs == 1, str(o.decoder_runs))
    check("raw-path temp files are removed", leftovers() == [], str(leftovers()))

    c = Fake(segs={(u1.camera_id, u1.hour_start): []})
    W.run_unit(c, FD, u1, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    check("NO footage in the window is a real answer: filed EMPTY, not failed",
          b.get("observations") == [] and not b.get("failed"), str(b))

    P.fdiff.analyse = lambda chunks, span_s=None, **k: (list(chunks), None)[1]
    c = Fake(segs={(u1.camera_id, u1.hour_start): segs})
    W.run_unit(c, FD, u1, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    check("footage that could not be DECODED is a failure to measure, filed with its cause",
          b.get("failed") is True and "no_keyframes_decoded" in (b.get("error") or ""), str(b))
    P.fdiff.analyse = fake_analyse

    c = Fake(segs={(u1.camera_id, u1.hour_start): [fseg(i) for i in range(9)]})
    W.run_unit(c, FD, u1, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    check("a server that IGNORED `window` (returned 9 for 4) is refused, not scored",
          b.get("failed") is True and "server_ignored_window" in (b.get("error") or ""), str(b))

    c = Fake(segs={(u1.camera_id, u1.hour_start): segs},
             refuse={("fetch", "f2"): [R(404, "segment_not_found")]})
    W.run_unit(c, FD, u1, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    check("a HOLE in a consecutive window is a failure, never silently skipped",
          b.get("failed") is True and "stream_has_a_hole" in (b.get("error") or ""), str(b))
    check("...and its temp files are removed too", leftovers() == [], str(leftovers()))
finally:
    P.fdiff.analyse = _real

# the real HTTP client: window and limit never mix
_H.status, _H.payload = 200, []
srv2 = http.server.HTTPServer(("127.0.0.1", 0), _H)
paths_seen = []
_orig = _H._reply
def _rec(self): paths_seen.append(self.path); return _orig(self)
_H.do_GET = _rec
threading.Thread(target=srv2.serve_forever, daemon=True).start()
hc2 = W.HttpLabsClient(f"http://127.0.0.1:{srv2.server_address[1]}", "t", timeout_s=5)
hc2.segments(u1, 4, "main", 4, 0.25)
check("REAL client sends window + window_at + stream_type and NO limit",
      paths_seen and "window=4" in paths_seen[-1] and "window_at=0.25" in paths_seen[-1]
      and "stream_type=main" in paths_seen[-1] and "limit=" not in paths_seen[-1], paths_seen[-1] if paths_seen else "")
try:
    hc2.segments(u1, 4, None, 4, 0.5); raised = False
except ValueError:
    raised = True
check("...and refuses window WITHOUT stream_type before sending (server: window_without_stream_type)", raised)
srv2.shutdown(); _H.do_GET = _orig

check("capability check refuses a server without `window`",
      FD.supported_by({"paths": {"/labs/scan/{a}/{c}/{h}/segments": {"get": {"parameters": [{"name": "limit"}]}}}}) is not None)
check("...and accepts one with it",
      FD.supported_by({"paths": {"/labs/scan/{a}/{c}/{h}/segments": {"get": {"parameters":
            [{"name": "limit"}, {"name": "window"}, {"name": "window_at"}]}}}}) is None)

# ---------------------------------------------------------------- audio / flow / phash
# The analysers are cilex-vision's (vendored and pinned above, 49-57 tests each on their
# side). These pin the WORKER-side rules each plugin depends on, with analysers stubbed.
def rseg(i, size=100, start="2026-09-26T01:00:00+00:00"):
    return W.Segment(f"r{i}", f"http://x/r{i}", start, "2026-09-26T01:00:30+00:00", 30.0, size,
                     "main", 2560, 1440, "hevc")
class SizedFake(Fake):
    def __init__(self, sizes, **k): super().__init__(**k); self.sizes = sizes
    def fetch(self, sg, d):
        self.fetched.append(sg.segment_id); open(d, "wb").write(b"a" * self.sizes[sg.segment_id]); return 1

# Every self-decoding analyser must be NAMED the working ffmpeg: each defaults to a bare
# `ffmpeg`, which the booth does not have on PATH. A sentinel proves the plugin passes
# ffmpeg_exe() through, rather than the analyser falling back to its default.
_real_ffmpeg = P._FFMPEG
P._FFMPEG = "/sentinel/bin/ffmpeg"
AU = P.AudioEnergyPlugin()
_ae = P.ae.analyse_raw_unit
try:
    au_kw = {}
    def fake_ae(chunks, segs, **k):
        au_kw.update(k); b"".join(chunks); return []
    P.ae.analyse_raw_unit = fake_ae
    u = unit(a="audio_energy")
    c = SizedFake({"r1": 100, "r2": 100}, segs={(u.camera_id, u.hour_start): [rseg(1), rseg(2)]})
    W.run_unit(c, AU, u, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    check("audio: [] is a RESULT and is filed empty, not failed", b.get("observations") == [] and not b.get("failed"), str(b))
    check("audio: the CLAIMED hour is passed, exactly (one row past its end = the whole unit refused)",
          au_kw.get("hour_start") == P._parse(u.hour_start), str(au_kw.get("hour_start")))
    check("audio: named the working ffmpeg, not a bare `ffmpeg`",
          au_kw.get("ffmpeg") == "/sentinel/bin/ffmpeg", str(au_kw.get("ffmpeg")))
    c = SizedFake({"r1": 110, "r2": 90}, segs={(u.camera_id, u.hour_start): [rseg(1), rseg(2)]})
    W.run_unit(c, AU, u, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    check("audio: COMPENSATING size errors (110+90 = 100+100) are caught per file",
          b.get("failed") is True and "fetched_size_mismatch" in (b.get("error") or ""), str(b))
    P.ae.analyse_raw_unit = lambda chunks, segs, **k: (_ for _ in ()).throw(ValueError("raw stream ended short"))
    c = SizedFake({"r1": 100}, segs={(u.camera_id, u.hour_start): [rseg(1)]})
    W.run_unit(c, AU, u, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    check("audio: a decode/split error is filed FAILED, never as an empty result",
          b.get("failed") is True and "ValueError" in (b.get("error") or ""), str(b))
finally:
    P.ae.analyse_raw_unit = _ae
check("audio: requests main (sub carries no audio)", AU.stream_type == "main")

OF = P.OpticalFlowPlugin()
_ab, _to = P.oflow.analyse_burst, P.oflow.to_observation
seen_types = []
try:
    _calls = {"n": 0, "ffmpeg": set()}
    def fake_burst(path, **k):
        # The FIRST burst fails to decode. (An earlier version keyed this on a path
        # suffix the worker's random temp names never had, so the branch never ran and
        # a mutation reporting a failed decode as "still" survived.)
        _calls["n"] += 1
        _calls["ffmpeg"].add(k.get("ffmpeg"))
        if _calls["n"] == 1:
            raise P.oflow.DecodeError("undecodable burst")
        return "burst"
    def fake_to(r, *, start_time, segment_id=None, stream_type=None, **k):
        seen_types.append(type(start_time).__name__)
        return None if segment_id == "r2" else {"start_time": "2026-09-26T01:00:00Z",
                                                "end_time": "2026-09-26T01:00:10Z", "metrics": {"dir_label": "right"}}
    P.oflow.analyse_burst, P.oflow.to_observation = fake_burst, fake_to
    u = unit(a="optical_flow")
    c = Fake(segs={(u.camera_id, u.hour_start): [rseg(1), rseg(2), rseg(3)]},
             refuse={("fetch", "r3"): [R(404, "segment_not_found")]})
    o = W.run_unit(c, OF, u, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    check("flow: each segment is its own burst, one decoder each", o.decoder_runs == 2, str(o.decoder_runs))
    check("flow: a MISSING segment is skipped, not a hole (bursts are independent)",
          o.submitted and o.skipped_segments == 1 and not b.get("failed"), f"{o.skipped_segments} {b}")
    # r1 fails to decode, r2 is "nothing moved" (None), r3 is missing -> ZERO rows.
    # A decode failure reported as "still" would make this 1.
    check("flow: an UNDECODABLE burst is skipped, never reported as 'still'",
          b.get("observations") == [] and _calls["n"] == 2, f"rows={b.get('observations')} calls={_calls['n']}")
    check("flow: start_time reaches to_observation as a DATETIME, not the wire string",
          seen_types and all(t == "datetime" for t in seen_types), str(seen_types))
    check("flow: a PARTIAL unit is reported as partial (1 burst undecodable)",
          o.undecodable_segments == 1, str(o.undecodable_segments))
    check("flow: named the working ffmpeg on every burst", _calls["ffmpeg"] == {"/sentinel/bin/ffmpeg"},
          str(_calls["ffmpeg"]))
    check("flow: temp files removed", leftovers() == [], str(leftovers()))

    # NOT ONE burst decodes. [] would file "checked, nothing moved" -- the body a truly
    # still hour gets (the Windows agent measured 1 MB of junk filing exactly that).
    def junk_burst(path, **k):
        raise P.oflow.DecodeError("decoder produced no frames: Invalid data found when processing input")
    P.oflow.analyse_burst = junk_burst
    c = Fake(segs={(u.camera_id, u.hour_start): [rseg(1), rseg(2)]})
    o = W.run_unit(c, OF, u, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    check("flow: NOTHING decodable is filed FAILED in ffmpeg's words, never as 'nothing moved'",
          b.get("failed") is True and "Invalid data found" in (b.get("error") or ""), str(b))
    check("...and counts both bursts as undecodable", o.undecodable_segments == 2, str(o.undecodable_segments))

    # Every listed segment GONE: nothing was fetched, so nothing was looked at either.
    c = Fake(segs={(u.camera_id, u.hour_start): [rseg(1), rseg(2)]},
             refuse={("fetch", "r1"): [R(404, "segment_not_found")], ("fetch", "r2"): [R(404, "segment_not_found")]})
    o = W.run_unit(c, OF, u, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    check("flow: every segment GONE is filed FAILED, not 'nothing moved'",
          b.get("failed") is True and "nothing_looked_at: 2 listed, 2 gone" in (b.get("error") or ""), str(b))
finally:
    P.oflow.analyse_burst, P.oflow.to_observation = _ab, _to

PH = P.PerceptualHashPlugin()
_pa = P.ph.analyse
try:
    got = {}
    def fake_ph(chunks, starts, *, hour_start_s=None, per_keyframe=False, **k):
        got.update(starts=starts, hs=hour_start_s, n=len(b"".join(chunks)), ffmpeg=k.get("ffmpeg"))
        return [{"start_time": "2026-09-26T01:00:00Z", "end_time": "2026-09-26T01:01:00Z", "metrics": {"rep_hash": "ab"}}]
    P.ph.analyse = fake_ph
    u = unit(hour="2026-09-26T01:00:00Z", a="perceptual_hash")
    c = Fake(segs={(u.camera_id, u.hour_start): [rseg(1), rseg(2, start="2026-09-26T01:00:30+00:00")]})
    W.run_unit(c, PH, u, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    ob = c.submitted[0][1]["observations"][0] if c.submitted else {}
    check("phash: its OWN decoder gets the raw stream, not shared frames", got.get("n") == 200, str(got.get("n")))
    check("phash: each segment's start is passed so true PTS maps back to its segment",
          len(got.get("starts", [])) == 2 and got["starts"][1] - got["starts"][0] == 30.0, str(got.get("starts")))
    check("phash: hour_start is passed (windows past the hour end fold back)", got.get("hs") is not None)
    check("phash: rows are tagged with the stream", ob.get("metrics", {}).get("stream") == "sub", str(ob))
    check("phash: named the working ffmpeg", got.get("ffmpeg") == "/sentinel/bin/ffmpeg", str(got.get("ffmpeg")))
    c = Fake(segs={(u.camera_id, u.hour_start): [rseg(1), W.Segment("rX", "http://x/rX", None, None, 30.0, 100,
                                                                     "sub", 1, 1, "h264")]})
    W.run_unit(c, PH, u, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    check("phash: a segment with no start time FAILS the unit rather than misattributing",
          b.get("failed") is True and "no start_time" in (b.get("error") or ""), str(b))
finally:
    P.ph.analyse = _pa

_fa = P.fdiff.analyse
try:
    fd_kw = {}
    def fake_fd(chunks, span_s=None, **k):
        fd_kw.update(k); list(chunks)
        return FDM.Scores(peak=1.0, sustained=0, ratio=None, frames=8, median_delta=0.1,
                          sustained_s=0.0, keyframe_interval_s=4.0)
    P.fdiff.analyse = fake_fd
    uf = W.ScanUnit("c", "2026-09-26T01:00:00Z", "frame_difference", None, 1)
    c = Fake(segs={(uf.camera_id, uf.hour_start): [fseg(1)]})
    W.run_unit(c, FD, uf, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    check("fdiff: named the working ffmpeg", fd_kw.get("ffmpeg") == "/sentinel/bin/ffmpeg", str(fd_kw.get("ffmpeg")))
finally:
    P.fdiff.analyse = _fa
P._FFMPEG = _real_ffmpeg

# the 500-row cap, on EVERY submit path (they now share _finish)
class Many(Nothing):
    def analyse(self, segs, st, u, ctx):
        return [{"start_time": "2026-09-26T01:00:00Z", "end_time": "2026-09-26T01:00:00Z", "metrics": {}}] * 501
class ManyRaw:
    name = "many"; version = "t"; segment_limit = 1; keyframes_only = True
    want_chroma = False; stateful = False; wants_raw = True
    def new_state(self): return None
    def window_at(self, u): return 0.5
    def analyse_raw(self, chunks, segs, u):
        list(chunks); return [{"start_time": "2026-09-26T01:00:00Z", "end_time": "2026-09-26T01:00:00Z", "metrics": {}}] * 501
for label, plug in (("frame path", Many()), ("raw path", ManyRaw())):
    u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]})
    W.run_unit(c, plug, u, decode=decode_chroma(11.5), states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    check(f"501 rows on the {label} are filed FAILED with the cause, never sent to the server",
          b.get("failed") is True and "too_many_observations" in (b.get("error") or "")
          and b.get("observations") == [], str(b)[:120])

# ---------------------------------------------------------------- timestamps
try:
    P._parse("2026-09-24T10:00:00")
    check("a NAIVE segment timestamp is refused, not read as local", False)
except ValueError:
    check("a NAIVE segment timestamp is refused, not read as local", True)

# ---------------------------------------------------------------- the token never leaks
hc = W.HttpLabsClient("http://127.0.0.1:1", "SECRET-TOKEN-XYZ", timeout_s=0.5)
# (A test asserting the token was absent from the base URL was removed 2026-09-25: it
#  could not fail, since the base URL never contains the token. The meaningful
#  guarantee is the one below -- nothing a failed request RAISES may carry it.)
try:
    hc.claim("illumination", 1)
    msg = ""
except Exception as e:
    msg = str(e) + repr(e)
check("token is not in any exception a failed request raises", "SECRET-TOKEN-XYZ" not in msg, msg[:80])

# ---------------------------------------------------------------- could not look != nothing there
# frame_source RAISES on a segment it cannot read. The frame path called it with no
# except, so ONE corrupt segment took down run_once and left every leased unit to
# expire as 'lease expired' (found reading the code, 2026-09-26, before any live run).
import logging
class IdFake(Fake):
    """Writes each segment's id into its file, so a decoder can fail on chosen ones."""
    def fetch(self, s, dest):
        self.fetched.append(s.segment_id); self._pop("fetch", s.segment_id)
        open(dest, "wb").write(s.segment_id.encode()); return 1
def decode_failing_on(bad):
    ok = decode_chroma(11.5)
    def d(path, kf, want_chroma):
        if open(path, "rb").read().decode() in bad:
            raise RuntimeError("decoder produced no frames (exit 1): Invalid data found when processing input")
        return ok(path, kf, want_chroma)
    return d

u = unit(); c = IdFake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]})
try:
    o = run(c, B1, u, decode=decode_failing_on({"seg-1"})); crashed = None
except Exception as e:
    o, crashed = None, e
b = c.submitted[0][1] if c.submitted else {}
check("frame path: an UNDECODABLE segment is skipped, never raised out of the loop",
      crashed is None and o.submitted and not b.get("failed") and len(b.get("observations", [])) == 1,
      repr(crashed) if crashed else str(b)[:160])
check("...and the unit reports it as partial", o is not None and o.undecodable_segments == 1,
      str(o and o.undecodable_segments))

u = unit(); c = IdFake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]})
o = run(c, B1, u, decode=decode_failing_on({"seg-1", "seg-2"}))
b = c.submitted[0][1] if c.submitted else {}
check("frame path: NOTHING decodable is filed FAILED with the decoder's words, not as an empty result",
      b.get("failed") is True and "nothing_looked_at: 2 listed, 0 gone, 2 undecodable" in (b.get("error") or "")
      and "Invalid data found" in (b.get("error") or ""), str(b))

u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]},
                     refuse={("fetch", "seg-1"): [R(404, "segment_not_found")], ("fetch", "seg-2"): [R(404, "segment_not_found")]})
o = run(c, B1, u)
b = c.submitted[0][1] if c.submitted else {}
check("frame path: every listed segment GONE is filed FAILED, not 'looked, found nothing'",
      b.get("failed") is True and "nothing_looked_at: 2 listed, 2 gone" in (b.get("error") or ""), str(b))

u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): []})
o = run(c, Nothing(), u)
b = c.submitted[0][1] if c.submitted else {}
check("control: an hour with NO footage listed is still a real, EMPTY result",
      o.submitted and b.get("observations") == [] and not b.get("failed"), str(b))

ua, ub = unit(cam="cam-a"), unit(cam="cam-b")
c = IdFake(units={"illumination": [ua, ub]},
           segs={(ua.camera_id, ua.hour_start): [seg(1)], (ub.camera_id, ub.hour_start): [seg(2)]})
try:
    rep = W.run_once(c, [B1], decode=decode_failing_on({"seg-1"}), states={}, sleep=lambda s: None); crashed = None
except Exception as e:
    rep, crashed = None, e
check("run_once: a unit that cannot be decoded does not stop the batch -- both units are filed",
      crashed is None and rep.submitted == 2 and rep.fatal is None,
      repr(crashed) if crashed else f"submitted={rep.submitted} fatal={rep.fatal}")

# A failure names its cause. The analysers log the decoder's own words at WARNING
# (3505b6b); the worker appends the last such line to a failed unit's reason.
_fa = P.fdiff.analyse
_root_handlers = list(logging.getLogger().handlers)
try:
    _nh = logging.NullHandler()        # handled, so Python's last-resort printer stays quiet
    logging.getLogger("labs_framediff").addHandler(_nh)
    logging.getLogger("labs_framediff").warning("stale warning from BEFORE this unit")
    logging.getLogger("labs_framediff").removeHandler(_nh)
    def fd_rejects(chunks, span_s=None, **k):
        list(chunks)
        logging.getLogger("labs_framediff").warning(
            "ffmpeg exited 8 and decoded no frames: Unrecognized option 'vsync'.")
        return None
    P.fdiff.analyse = fd_rejects
    uf = W.ScanUnit("c", "2026-09-26T01:00:00Z", "frame_difference", None, 1)
    c = Fake(segs={(uf.camera_id, uf.hour_start): [fseg(1)]})
    W.run_unit(c, FD, uf, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    err = c.submitted[0][1].get("error") if c.submitted else ""
    check("a failed unit carries the analyser's last WARNING (no_keyframes_decoded now says why)",
          err.startswith("no_keyframes_decoded") and "Unrecognized option 'vsync'" in err, err)
    check("control: a warning logged BEFORE the unit is not attributed to it", "stale" not in err, err)
    P.fdiff.analyse = lambda chunks, span_s=None, **k: (list(chunks), None)[1]
    c = Fake(segs={(uf.camera_id, uf.hour_start): [fseg(1)]})
    W.run_unit(c, FD, uf, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    err = c.submitted[0][1].get("error") if c.submitted else ""
    check("control: a unit that logged nothing carries no stale warning from the one before",
          err == "no_keyframes_decoded", err)
    check("the capture is removed after every unit (no handler leaks onto the root logger)",
          logging.getLogger().handlers == _root_handlers, str(logging.getLogger().handlers))
finally:
    P.fdiff.analyse = _fa

# No working ffmpeg on the station: refuse BEFORE claiming. Otherwise every unit it
# claimed would be filed failed, three attempts each, on real camera-hours.
import run_worker as RW, urllib.request as _ur
_fe, _uo, _argv = P.ffmpeg_exe, _ur.urlopen, sys.argv
_opened = []
try:
    def _no_ffmpeg():
        raise RuntimeError("no working ffmpeg found. Tried: ffmpeg")
    P.ffmpeg_exe = _no_ffmpeg
    _ur.urlopen = lambda *a, **k: _opened.append(a) or (_ for _ in ()).throw(AssertionError("network"))
    sys.argv = ["run_worker.py", "--live"]
    try:
        RW.main(); exited = ""
    except SystemExit as e:
        exited = str(e.code)
    check("run_worker: no working ffmpeg -> FATAL before anything is claimed",
          "cannot decode; nothing claimed" in exited and not _opened, f"exit={exited!r} network={len(_opened)}")
finally:
    P.ffmpeg_exe, _ur.urlopen, sys.argv = _fe, _uo, _argv
    for h in logging.getLogger().handlers[:]:
        if h not in _root_handlers:
            logging.getLogger().removeHandler(h)

# THE BOOTH'S CONDITION, REPRODUCED HERE: no ffmpeg on PATH at all. Every raw analyser
# runs through run_unit on a REAL clip, decoded by the real ffmpeg -- which it can only
# find if the plugin names it. Before 2026-09-26 three of these filed FileNotFoundError.
import subprocess
try:
    _ff = P.ffmpeg_exe()
except RuntimeError:
    _ff = None
_clip = os.path.join(TMP, "clip.ts.src")
# libx264 first; the booth's ffmpeg is an LGPL build without it, so libopenh264 there
# (the Windows agent's measurement, 2026-09-26) -- the test then RUNS on the booth
# instead of skipping.
_made = False
for _enc in ("libx264", "libopenh264"):
    _made = bool(_ff) and _run(
        [_ff, "-hide_banner", "-loglevel", "error", "-y",
         "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=15",
         "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=16000",
         "-t", "4", "-c:v", _enc, "-g", "15", "-bf", "0", "-pix_fmt", "yuv420p",
         "-c:a", "aac", "-b:a", "32k", "-f", "mpegts", _clip],
        timeout=60).returncode == 0
    if _made:
        break
if not _made:
    print("SKIP no-ffmpeg-on-PATH run -- could not make a test clip "
          f"({'no working ffmpeg' if not _ff else 'neither libx264 nor libopenh264, or no aac'})")
else:
    _size = os.path.getsize(_clip)
    class ClipFake(Fake):
        def fetch(self, s, dest):
            self.fetched.append(s.segment_id)
            with open(_clip, "rb") as f_in, open(dest, "wb") as f_out:
                f_out.write(f_in.read())
            return _size
    def clipseg(stream):
        return W.Segment("clip1", "http://x/clip1", "2026-09-26T01:10:00+00:00",
                         "2026-09-26T01:10:04+00:00", 4.0, _size, stream, 320, 180, "h264")
    _path = os.environ.get("PATH", "")
    _empty = tempfile.mkdtemp(prefix="nopath-")
    os.environ["PATH"] = _empty
    try:
        for plug in (P.FrameDifferencePlugin(), P.AudioEnergyPlugin(),
                     P.OpticalFlowPlugin(), P.PerceptualHashPlugin(), P.TrackLinkingPlugin()):
            uc = W.ScanUnit("cam-clip", "2026-09-26T01:00:00Z", plug.name, None, 1)
            c = ClipFake(segs={(uc.camera_id, uc.hour_start): [clipseg(plug.stream_type)]})
            o = W.run_unit(c, plug, uc, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
            b = c.submitted[0][1] if c.submitted else {}
            check(f"no ffmpeg on PATH: {plug.name} still decodes a real clip and files a result",
                  o.submitted and not b.get("failed"), (b.get("error") or str(b))[:200])
    finally:
        os.environ["PATH"] = _path

# ---------------------------------------------------------------- the frame path STREAMS
# It used to decode a whole unit into a list first. One real 30 s -sub segment of a
# 1280x720 GOP-15 camera is 27.65 MB of luma (measured 2026-09-26), so an hour held
# ~3.3 GB in the worker on the pilot host.
import weakref, random
from datetime import timezone as _tz, timedelta as _td, datetime as _dt
class FrameList(list):
    pass                                   # a list subclass can be weakly referenced
_refs, _alive = [], []
def decode_tracked(path, kf, want_chroma, **k):
    fl = FrameList(decode_chroma(11.5)(path, kf, want_chroma)); _refs.append(weakref.ref(fl)); return fl
class Peek:
    name = "peek"; version = "t"; segment_limit = 10; keyframes_only = True
    want_chroma = True; stateful = False
    def new_state(self): return None
    def analyse(self, segs, st, u, ctx):
        for _seg, _frames in segs:
            _alive.append(sum(1 for r in _refs if r() is not None))
        return []
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(i) for i in range(8)]})
run(c, Peek(), u, decode=decode_tracked)
check("the frame path STREAMS: one segment's frames alive at a time, not the hour's",
      len(_alive) == 8 and max(_alive) <= 1, str(_alive))

# Two stateful analysers on ONE camera: state used to be keyed by camera alone.
_got = []
class StA:
    name = "st_a"; version = "t"; segment_limit = 1; keyframes_only = True
    want_chroma = True; stateful = True
    def new_state(self): return {"owner": self.name}
    def analyse(self, segs, st, u, ctx):
        list(segs); _got.append((self.name, st["owner"])); return []
class StB(StA):
    name = "st_b"
ua = W.ScanUnit("cam-x", "2026-09-24T10:00:00Z", "st_a", None, 1)
ub = W.ScanUnit("cam-x", "2026-09-24T10:00:00Z", "st_b", None, 1)
c = Fake(units={"st_a": [ua], "st_b": [ub]}, segs={(ua.camera_id, ua.hour_start): [seg(1)]})
W.run_once(c, [StA(), StB()], decode=decode_chroma(11.5), states={}, sleep=lambda s: None)
check("two stateful analysers on ONE camera each get their OWN state",
      _got == [("st_a", "st_a"), ("st_b", "st_b")], str(_got))

# A picture of the RECENT PAST (blob_geometry's background model) is carried only into
# the camera's NEXT hour. Claims go newest-first, so without this a model that learned
# the end of 04:00Z met the start of 03:00Z (measured at dawn: 10 rows in minute 0 that
# a fresh model does not file, and none in minutes 3-6 where it files 12).
class Recent:
    name = "recent"; version = "t"; segment_limit = 1; keyframes_only = True
    want_chroma = True; stateful = True; state_is_recent_past = True
    seen = []
    def new_state(self): return object()
    def analyse(self, segs, st, u, ctx): list(segs); type(self).seen.append(id(st)); return []
class Keeps(Recent):
    name = "keeps"; state_is_recent_past = False; seen = []
def run_hour(plug, hour, states_):
    uu = unit(cam="cam-r", hour=hour, a=plug.name)
    run(Fake(segs={(uu.camera_id, uu.hour_start): [seg(1)]}), plug, uu, states=states_)
st_ = {}
for hr in ("2026-09-26T04:00:00Z", "2026-09-26T03:00:00Z",
           "2026-09-26T04:00:00.000+00:00", "2026-09-26T04:00:00Z"):
    run_hour(Recent(), hr, st_)
s_ = Recent.seen
check("recent-past state is NOT carried backwards (04:00Z, then 03:00Z)", s_[1] != s_[0])
check("... IS carried into the next hour, however the server spells it (03:00Z, then 04:00:00.000+00:00)",
      s_[2] == s_[1])
check("... is NOT carried into a second run of the same hour (a retry starts fresh)", s_[3] != s_[2])
Recent.seen = []; st_ = {}
run_hour(Recent(), "not-a-time", st_); run_hour(Recent(), "not-a-time", st_)
check("an hour that will not parse carries nothing", Recent.seen[0] != Recent.seen[1])
st_ = {}
run_hour(Keeps(), "2026-09-26T04:00:00Z", st_); run_hour(Keeps(), "2026-09-26T03:00:00Z", st_)
check("a state that is not a picture of the recent past (camera_health's) is carried as before",
      Keeps.seen[0] == Keeps.seen[1])
check("blob_geometry's model is flagged recent-past; camera_health's Baseline is not",
      getattr(P.ShapePlugin, "state_is_recent_past", False) is True
      and not getattr(P.CameraHealthPlugin, "state_is_recent_past", False))

# A4-A6 rows are timed from THEIR OWN segment. The same thing as the yield's segment
# today; not once the analyser folds a recurring source and flushes it at the end of
# the unit, when the row's first hit sits segments back.
class _Ob:
    def __init__(self, sid, t): self.sid, self.t = sid, t
    def as_payload(self):
        return {"segment_id": self.sid, "t_offset_s": self.t, "shape_class": "shape_indeterminate",
                "object_count": 1, "recur_hits": 10, "recur_count": 7, "recur_window_s": 600.0,
                "recur_folded": True}
class _ObTimed(_Ob):
    def as_payload(self):
        return dict(super().as_payload(), end_time="2026-09-24T10:10:05+00:00")
def _sets_end_time(stream, state, cfg):
    for meta, frames in stream:
        list(frames); yield meta, [_ObTimed(meta.segment_id, 1.0)], None
def _flush_at_end(stream, state, cfg):
    metas = []
    for meta, frames in stream:
        list(frames); metas.append(meta)
        yield meta, ([_Ob(metas[0].segment_id, 5.0)] if len(metas) == 3 else []), None
def _names_elsewhere(stream, state, cfg):
    for meta, frames in stream:
        list(frames); yield meta, [_Ob("elsewhere", 1.0)], None
segs3 = [W.Segment(f"s{i}", f"http://x/labs/segments/s{i}", f"2026-09-24T10:0{i}:00+00:00",
                   f"2026-09-24T10:0{i}:30+00:00", 30.0, 6_000_000, "sub", 64, 48, "h264") for i in range(3)]
ub_ = unit(hour="2026-09-24T10:00:00Z", a="blob_geometry")
_orig_window = P.so.analyse_window
try:
    P.so.analyse_window = _flush_at_end
    c = Fake(segs={(ub_.camera_id, ub_.hour_start): segs3})
    run(c, P.ShapePlugin(), ub_)
    rows_ = c.submitted[0][1].get("observations") or []
    check("a row flushed at the end of the unit is timed from ITS OWN segment (10:00:05, not 10:02:05)",
          len(rows_) == 1 and rows_[0]["start_time"].startswith("2026-09-24T10:00:05"), str(rows_))
    # An event group may never span more than GROUP_MAX_SPAN_S, and a longer row can never
    # join one (cilex-vision: /labs/regroup then retries it forever). A fold's 600 s
    # window lives in metrics, never in the row's span.
    check("a FOLDED A4-A6 row is a point in time: end_time == start_time, its window in metrics",
          len(rows_) == 1 and rows_[0]["end_time"] == rows_[0]["start_time"]
          and (rows_[0].get("metrics") or {}).get("recur_window_s") == 600.0, str(rows_))
    P.so.analyse_window = _sets_end_time
    c = Fake(segs={(ub_.camera_id, ub_.hour_start): segs3[:1]})
    run(c, P.ShapePlugin(), ub_)
    b_ = c.submitted[0][1]
    check("an A4-A6 payload that sets its own end_time files the unit FAILED, never a 600 s row",
          b_.get("failed") is True and "timed here, as points" in (b_.get("error") or ""), str(b_)[:200])
    P.so.analyse_window = _names_elsewhere
    c = Fake(segs={(ub_.camera_id, ub_.hour_start): segs3[:1]})
    run(c, P.ShapePlugin(), ub_)
    b_ = c.submitted[0][1]
    check("a row naming a segment the unit never streamed files the unit FAILED, with that cause",
          b_.get("failed") is True and "never streamed" in (b_.get("error") or ""), str(b_)[:200])
finally:
    P.so.analyse_window = _orig_window

# A lost lease mid-stream must abandon the unit even if the analyser catches Exception.
class Greedy:
    name = "greedy"; version = "t"; segment_limit = 3; keyframes_only = True
    want_chroma = True; stateful = False
    def new_state(self): return None
    def analyse(self, segs, st, u, ctx):
        try:
            for _ in segs:
                pass
        except Exception:
            return [{"start_time": "2026-09-24T10:00:00Z", "end_time": "2026-09-24T10:00:00Z", "metrics": {}}]
        return []
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]},
                     refuse={("fetch", "seg-2"): [R(409, "scan_unit_not_claimed")]})
o = run(c, Greedy(), u)
check("a lease lost mid-stream abandons the unit, even through an analyser that catches Exception",
      not c.submitted and o.action is W.Action.RECLAIM, f"submitted={len(c.submitted)} action={o.action}")

# Planes are asked for only by the analyser that needs them (B1 pays for one float).
_kw = []
def decode_kw(path, kf, want_chroma, **k):
    _kw.append(k); return decode_chroma(11.5)(path, kf, want_chroma)
for plug, expect in ((B1, {}), (P.ColourHistogramPlugin(), {"want_planes": True})):
    _kw.clear(); u = unit(a=plug.name); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]})
    run(c, plug, u, decode=decode_kw)
    check(f"{plug.name}: the decoder is asked for U/V planes only when the analyser needs them",
          _kw == [expect], str(_kw))

# tolerates_holes: track_linking handles a gap itself, so the segment leaves BOTH lists.
_raw = {}
class HoleOK:
    name = "hole_ok"; version = "t"; segment_limit = 3; keyframes_only = False
    want_chroma = False; stateful = False; wants_raw = True; tolerates_holes = True
    def new_state(self): return None
    def analyse_raw(self, chunks, segs, u):
        _raw.update(ids=[s.segment_id for s in segs], n=len(b"".join(chunks))); return []
class HoleNo(HoleOK):
    name = "hole_no"; tolerates_holes = False
for plug in (HoleOK(), HoleNo()):
    u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2), seg(3)]},
                         refuse={("fetch", "seg-2"): [R(404, "segment_not_found")]})
    _raw.clear(); o = run(c, plug, u); b = c.submitted[0][1] if c.submitted else {}
    if plug.tolerates_holes:
        check("tolerates_holes: a missing segment leaves the stream AND the list, in step",
              _raw.get("ids") == ["seg-1", "seg-3"] and _raw.get("n") == 200 and o.skipped_segments == 1
              and not b.get("failed"), f"{_raw} {b}")
    else:
        check("...while any other raw analyser still refuses the hole",
              b.get("failed") is True and "stream_has_a_hole" in (b.get("error") or ""), str(b))

# windows() is plan_windows, streamed. Pinned against the REAL plan_windows on 300 random
# hours: seams, gaps either side of 1.5 s, 4 s motion segments, segments with no end.
import labs_foreground_mask as FMM
_rng, _mismatch = random.Random(20260926), None
for trial in range(300):
    t, rows = _dt(2026, 9, 26, 1, 0, tzinfo=_tz.utc), []
    for i in range(_rng.randint(0, 14)):
        st = t + _td(seconds=_rng.choice([0.0, 0.02, 0.08, 1.4, 1.5, 1.6, 7.0]))
        dur = _rng.choice([30.0, 29.9, 4.0])
        en = st + _td(seconds=dur)
        rows.append(W.Segment(f"s{i}", "u", st.isoformat(), None if _rng.random() < 0.05 else en.isoformat(),
                              dur, 1, "sub", 1, 1, "h264"))
        t = en
    ours = [[s.segment_id for s, _ in w] for w in P.windows(((s, None) for s in rows), 4)]
    theirs = [[s.segment_id for s in w] for w in FMM.plan_windows(rows, run=4)]
    if ours != theirs:
        _mismatch = (trial, ours, theirs); break
check("windows() cuts EXACTLY the windows plan_windows cuts (300 random hours)", _mismatch is None, str(_mismatch)[:240])

# ---------------------------------------------------------------- the new analysers, REAL code
# Synthetic scenes through the real vendored modules, each with a control that can fail.
def texture(h, w, seed):
    r = np.random.default_rng(seed)
    return (r.integers(40, 200, (h // 8, w // 8), dtype=np.uint8).repeat(8, 0).repeat(8, 1))
_BG = texture(360, 640, 7)
def scene(moving, ir=False, n_segs=4, per_seg=8, colour=(90, 200)):
    """n_segs consecutive 30 s segments of keyframes every 30/per_seg s; a bright square
    walks across when `moving`. Chroma planes: grey under IR, else coloured where the
    square is."""
    segs_, frames_ = [], {}
    k = 0
    for s in range(n_segs):
        st = _dt(2026, 9, 26, 1, 10, tzinfo=_tz.utc) + _td(seconds=30.0 * s)
        sid = f"seg-{s}"
        segs_.append(W.Segment(sid, f"http://x/{sid}", st.isoformat(), (st + _td(seconds=30)).isoformat(),
                               30.0, 1000, "sub", 640, 360, "h264"))
        fr = []
        for j in range(per_seg):
            L = _BG.copy(); U = np.full((180, 320), 128, np.uint8); V = U.copy()
            if moving:
                x = 20 + (k * 17) % 560
                L[150:230, x:x + 60] = 250
                if not ir:
                    U[75:115, x // 2:x // 2 + 30] = colour[0]; V[75:115, x // 2:x // 2 + 30] = colour[1]
            ce = 0.0 if ir else float(np.abs(U.astype(int) - 128).mean() + np.abs(V.astype(int) - 128).mean())
            fr.append(so.Frame(k, j * 30.0 / per_seg, L, ce, U, V)); k += 1
        frames_[sid] = fr
    return segs_, frames_
class SceneFake(Fake):
    def fetch(self, s, dest):
        self.fetched.append(s.segment_id); open(dest, "wb").write(s.segment_id.encode()); return 1
def scene_decode(frames_):
    def d(path, kf, want_chroma, **k):
        return list(frames_[open(path, "rb").read().decode()])
    return d
def run_scene(plug, segs_, frames_, hour="2026-09-26T01:00:00Z", states=None, cam="cam-s"):
    u = W.ScanUnit(cam, hour, plug.name, None, 1)
    c = SceneFake(segs={(u.camera_id, u.hour_start): segs_})
    o = W.run_unit(c, plug, u, decode=scene_decode(frames_), states={} if states is None else states,
                   tmpdir=TMP, sleep=lambda s: None)
    return o, (c.submitted[0][1] if c.submitted else {})
def metrics_ok(rows):
    try:
        for r in rows: W.check_metrics(r.get("metrics"))
        return True
    except W.MetricsViolation:
        return False

FMP = P.ForegroundMaskPlugin()
o, b = run_scene(FMP, *scene(moving=True))
rows = b.get("observations") or []
check("B3: ONE row per window of four segments, spanning first start to last end",
      len(rows) == 1 and rows[0]["start_time"].startswith("2026-09-26T01:10:00")
      and rows[0]["end_time"].startswith("2026-09-26T01:12:00"), str(rows)[:200])
check("B3: a moving square is SEEN (object_count >= 1)", rows and (rows[0].get("object_count") or 0) >= 1, str(rows)[:200])
check("B3: rows pass the server's metrics rules", metrics_ok(rows))
o, b = run_scene(FMP, *scene(moving=False))
rows0 = b.get("observations") or []
check("control: B3 on a still scene LOOKS and finds none (object_count 0), not silence",
      len(rows0) == 1 and rows0[0].get("object_count") == 0, str(rows0)[:200])
o, b = run_scene(FMP, *scene(moving=True, n_segs=3))
check("B3: fewer than four consecutive segments is not scored (their rule), filed empty",
      b.get("observations") == [] and not b.get("failed"), str(b)[:160])

CHP = P.ColourHistogramPlugin()
o, b = run_scene(CHP, *scene(moving=True))
rows = b.get("observations") or []
m = rows[0].get("metrics", {}) if rows else {}
check("B7: a coloured moving region is NAMED, not gated", len(rows) == 1 and m.get("colour") and not m.get("gate"), str(m)[:200])
check("B7: rows pass the server's metrics rules", metrics_ok(rows))
o, b = run_scene(CHP, *scene(moving=True, ir=True))
m = ((b.get("observations") or [{}])[0]).get("metrics", {})
check("control: B7 under IR says so (gate=ir) and names no colour", m.get("gate") == "ir" and "colour" not in m, str(m)[:200])

CHM = P.CameraHealthPlugin()
st = {}
o, b = run_scene(CHM, *scene(moving=False, n_segs=4, per_seg=8), hour="2026-09-26T01:00:00Z", states=st)
rows = b.get("observations") or []
check("B2: at most ONE row per unit, spanning the sampled segments",
      len(rows) == 1 and rows[0]["start_time"].startswith("2026-09-26T01:10:00")
      and rows[0]["end_time"].startswith("2026-09-26T01:12:00"), str(rows)[:200])
check("B2: rows pass the server's metrics rules (<= 24 keys)", metrics_ok(rows) and len(rows[0].get("metrics", {})) <= 24 if rows else False)
hst = st.get(("camera_health", "cam-s"))
taught = hst.baseline.windows if hst else None
run_scene(CHM, *scene(moving=False), hour="2026-09-26T00:00:00Z", states=st)
check("B2 FORWARD-ONLY: an OLDER hour is scored but does not teach the Baseline",
      hst is not None and hst.baseline.windows == taught
      and hst.taught_until == _dt(2026, 9, 26, 1, 0, tzinfo=_tz.utc), f"{taught} -> {hst and hst.baseline.windows}")
run_scene(CHM, *scene(moving=False), hour="2026-09-26T02:00:00Z", states=st)
check("...and a NEWER hour does", hst.baseline.windows == (taught or 0) + 1
      and hst.taught_until == _dt(2026, 9, 26, 2, 0, tzinfo=_tz.utc), str(hst.baseline.windows))

_sd = tempfile.mkdtemp(prefix="chstate-")
CHP1 = P.CameraHealthPlugin(state_dir=_sd)
run_scene(CHP1, *scene(moving=False), hour="2026-09-26T03:00:00Z", states={}, cam="cam-p")
loaded = P.CameraHealthPlugin(state_dir=_sd).load_state("cam-p")
check("B2 state PERSISTS across worker runs (Baseline and the forward-only mark)",
      loaded is not None and loaded.baseline.windows == 1
      and loaded.taught_until == _dt(2026, 9, 26, 3, 0, tzinfo=_tz.utc), str(loaded and loaded.__dict__)[:160])
open(os.path.join(_sd, "cam-p.json"), "w").write("{not json")
_lg = logging.getLogger("plugins"); _lvl = _lg.level; _lg.setLevel(logging.CRITICAL)
try:
    again = P.CameraHealthPlugin(state_dir=_sd).load_state("cam-p")
finally:
    _lg.setLevel(_lvl)
aside = [f for f in os.listdir(_sd) if ".unreadable-" in f]
check("B2: an UNREADABLE state file is set aside (never trusted, never deleted), and the camera starts fresh",
      again is None and len(aside) == 1 and not os.path.exists(os.path.join(_sd, "cam-p.json")), str(os.listdir(_sd)))

TLP = P.TrackLinkingPlugin()
_ta, _to2 = P.tl.analyse, P.tl.to_observations
_tk = {}
try:
    P.tl.analyse = lambda chunks, segs, **k: (_tk.update(ff=k.get("ffmpeg"), ids=[s.segment_id for s in segs]), list(chunks), "res")[2]
    def fake_to_obs(res, *, hour_start=None, hour_end=None, **k):
        _tk.update(hs=hour_start, he=hour_end); return [], {}
    P.tl.to_observations = fake_to_obs
    _real_ff = P._FFMPEG; P._FFMPEG = "/sentinel/bin/ffmpeg"
    u = W.ScanUnit("cam-t", "2026-09-26T01:00:00Z", "track_linking", None, 1)
    c = Fake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]})
    W.run_unit(c, TLP, u, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None)
    check("B6: episodes are bounded to the CLAIMED hour [start, start+1h)",
          _tk.get("hs") == _dt(2026, 9, 26, 1, 0, tzinfo=_tz.utc) and _tk.get("he") == _dt(2026, 9, 26, 2, 0, tzinfo=_tz.utc), str(_tk))
    check("B6: named the working ffmpeg", _tk.get("ff") == "/sentinel/bin/ffmpeg", str(_tk.get("ff")))
finally:
    P.tl.analyse, P.tl.to_observations = _ta, _to2
    P._FFMPEG = _real_ff

# ---------------------------------------------------------------- where the time went
# The first live unit took 45.6 s wall for ~15 CPU-s and nothing said why. Each unit
# now carries its phases; the frame path's analyse time is NET of the fetch and decode
# it pulls through the stream, or slow footage would be blamed on the analyser.
import time as _time
class SlowFake(Fake):
    def fetch(self, s, dest):
        _time.sleep(0.05); return super().fetch(s, dest)
def slow_decode(path, kf, want_chroma, **k):
    _time.sleep(0.03); return decode_chroma(11.5)(path, kf, want_chroma)
u = unit(); c = SlowFake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]})
o = run(c, B1, u, decode=slow_decode)
tm = o.timings
check("a unit reports its phases: list, fetch, decode, analyse, submit, total",
      {"list_s", "fetch_s", "decode_s", "analyse_s", "submit_s", "total_s"} <= set(tm), str(tm))
check("...fetch and decode carry THEIR time (2 x 0.05 s, 2 x 0.03 s injected)",
      0.09 <= tm.get("fetch_s", 0) < 0.5 and 0.05 <= tm.get("decode_s", 0) < 0.5, str(tm))
check("...and the analyser's time is net of them, not their sum",
      0 <= tm.get("analyse_s", -1) < 0.05, str(tm))
check("...and the phases fit inside the total",
      sum(v for k, v in tm.items() if k != "total_s") <= tm.get("total_s", 0) + 0.01, str(tm))

# ---------------------------------------------------------------- one OpenCV thread
# PROCESS-GLOBAL, and only two plugins set it, so blob_geometry's cost depended on which
# analyser ran first. The worker must pin it before any analyser runs. A fresh process,
# because the setting would otherwise leak between these tests.
_pin_probe = ("import sys; sys.path.insert(0, sys.argv[1])\n"
              "import cv2, plugins as P, run_worker as RW\n"
              "before = cv2.getNumThreads()\n"
              "def _none(): raise RuntimeError('no ffmpeg')\n"
              "P.ffmpeg_exe = _none\n"
              "sys.argv = ['run_worker.py']\n"
              "try:\n    RW.main()\nexcept SystemExit:\n    pass\n"
              "print('THREADS', before, cv2.getNumThreads())\n")
_pr = _run([sys.executable, "-c", _pin_probe, str(ROOT / "tools" / "labs")], timeout=120, text=True)
_m = [l.split() for l in _pr.stdout.splitlines() if l.startswith("THREADS")]
if _m and int(_m[0][1]) <= 1:
    print("SKIP OpenCV thread pin -- this box already runs OpenCV single-threaded, so it cannot show")
else:
    check("run_worker pins OpenCV to ONE thread before any analyser runs (the default was "
          f"{_m[0][1] if _m else '?'} here)", bool(_m) and _m[0][2] == "1", _pr.stdout.strip() + _pr.stderr[-200:])

# ---------------------------------------------------------------- station scanning (--loop)
# The Labs screen pauses and resumes this station through station.py's control file,
# and shows what it is doing from status.json. Default-deny: scanning spends this
# station's CPU and writes to the shared pilot, so it starts only when someone says so.
import station as ST, json as _j
_sd2 = tempfile.mkdtemp(prefix="station-")
check("control: NO file means PAUSED (never started here), and says so",
      ST.read_control(_sd2) == {"paused": True, "camera_health": False, "why": "never started on this station"},
      str(ST.read_control(_sd2)))
open(os.path.join(_sd2, ST.CONTROL), "w").write("{not json")
check("control: an UNREADABLE file means paused", ST.read_control(_sd2)["paused"] is True)
open(os.path.join(_sd2, ST.CONTROL), "w").write('{"paused": "no"}')
check("control: anything but a boolean `paused` means paused", ST.read_control(_sd2)["paused"] is True)
ST.write_control(False, camera_health=True, by="test", directory=_sd2)
ST.write_control(True, by="test", directory=_sd2)
_c = ST.read_control(_sd2)
check("control: pausing KEEPS the station's camera_health opt-in", _c["paused"] is True and _c["camera_health"] is True, str(_c))
ST.write_control(False, by="test", directory=_sd2)
check("control: an explicit resume is honoured", ST.read_control(_sd2)["paused"] is False)
check("control: every write is a whole document (no temp file left behind)",
      sorted(os.listdir(_sd2)) == [ST.CONTROL], str(os.listdir(_sd2)))

class HbRec:
    def __init__(self): self.log = []; self.fields = {}
    def update(self, **kw): self.fields.update(kw); self.log.append(dict(kw))
class Clock:
    def __init__(self): self.t = 0.0
    def now(self): return self.t
    def sleep(self, s): self.t += max(s, 0.001)
def ctl_seq(*states):
    """A control file that reads `paused` from a list, one value per read, last repeats."""
    st = list(states)
    def f():
        v = st.pop(0) if len(st) > 1 else st[0]
        return {"paused": v["paused"], "camera_health": v.get("ch", False), "why": "paused" if v["paused"] else ""}
    return f
class NamedPlug(Nothing):
    def __init__(self, name): self.name = name
def loop_world(names, units_per=1):
    units = {n: [W.ScanUnit(f"cam-{n}-{i}", "2026-09-26T08:00:00Z", n, None, 1) for i in range(units_per)] for n in names}
    segs = {(u.camera_id, u.hour_start): [seg(1)] for us in units.values() for u in us}
    return Fake(units=units, segs=segs), [NamedPlug(n) for n in names]

RW2 = RW   # run_worker, imported above for the ffmpeg check
c, plugs = loop_world(["illumination", "foreground_mask"])
hb, clk = HbRec(), Clock()
RW2.scan_loop(c, lambda: plugs, decode=decode_chroma(11.5), hb=hb, control=ctl_seq({"paused": True}),
              sleep=clk.sleep, clock=clk.now, passes=1)
check("loop: PAUSED claims nothing and says so", c.claims == [] and hb.fields.get("state") == "paused", f"{c.claims} {hb.fields.get('state')}")

# Paused, it still keeps "what this station could run" current: the capability check is a
# read of the server's OpenAPI, and without it a worker paused since an old server showed
# "needs a server update" for every analyser however far the server had moved.
_asked = []
c, plugs = loop_world(["illumination"])
hb, clk = HbRec(), Clock()
RW2.scan_loop(c, lambda: _asked.append(clk.t) or plugs, decode=decode_chroma(11.5), hb=hb,
              control=ctl_seq({"paused": True}), sleep=clk.sleep, clock=clk.now, passes=3)
check("loop: PAUSED still re-reads what the server can run, at least every RECHECK_S, and claims nothing",
      len(_asked) == 3 and c.claims == [] and max(b - a for a, b in zip(_asked, _asked[1:])) <= RW2.RECHECK_S + 1,
      f"{_asked} {c.claims}")

c, plugs = loop_world(["illumination", "foreground_mask"])
hb, clk = HbRec(), Clock()
tot = RW2.scan_loop(c, lambda: plugs, decode=decode_chroma(11.5), hb=hb, control=ctl_seq({"paused": False}),
                    sleep=clk.sleep, clock=clk.now, passes=2)
check("loop: running asks for ONE unit of each analyser in turn", c.claims[:2] == ["illumination", "foreground_mask"], str(c.claims))
check("loop: every unit is counted and the last one is shown",
      tot == {"claimed": 2, "done": 2, "failed": 0, "abandoned": 0}
      and (hb.fields.get("last_unit") or {}).get("analyzer") == "foreground_mask", f"{tot} {hb.fields.get('last_unit')}")
check("loop: a pass with nothing to claim goes IDLE (and waits, rather than spinning)",
      hb.fields.get("state") == "idle" and clk.t >= RW2.IDLE_S - RW2.PAUSED_POLL_S, f"{hb.fields.get('state')} t={clk.t}")

c, plugs = loop_world(["illumination", "foreground_mask"])
hb, clk = HbRec(), Clock()
# reads: pass start (running), before plugin 1 (running), gate (running), before plugin 2 (PAUSED) ...
RW2.scan_loop(c, lambda: plugs, decode=decode_chroma(11.5), hb=hb,
              control=ctl_seq({"paused": False}, {"paused": False}, {"paused": False}, {"paused": True}),
              sleep=clk.sleep, clock=clk.now, passes=1)
check("loop: a Pause takes effect at the NEXT claim, not mid-unit", c.claims == ["illumination"], str(c.claims))

c, plugs = loop_world(["illumination", "camera_health"])
hb, clk = HbRec(), Clock()
RW2.scan_loop(c, lambda: plugs, decode=decode_chroma(11.5), hb=hb, control=ctl_seq({"paused": False}),
              sleep=clk.sleep, clock=clk.now, passes=1)
check("loop: camera_health is NOT run on a station that has not opted in (one station only)",
      "camera_health" not in c.claims and hb.fields.get("camera_health") is False, str(c.claims))
c, plugs = loop_world(["illumination", "camera_health"])
RW2.scan_loop(c, lambda: plugs, decode=decode_chroma(11.5), hb=HbRec(), control=ctl_seq({"paused": False, "ch": True}),
              sleep=Clock().sleep, clock=Clock().now, passes=1)
check("...and IS run where the control file opts this station in", "camera_health" in c.claims, str(c.claims))

c, plugs = loop_world(["illumination"])
c.refuse = {("claim", "illumination"): [R(401, "station_token_not_recognised")]}
hb, clk = HbRec(), Clock()
RW2.scan_loop(c, lambda: plugs, decode=decode_chroma(11.5), hb=hb, control=ctl_seq({"paused": False}),
              sleep=clk.sleep, clock=clk.now, passes=1)
check("loop: a refused station token is shown as FATAL, with the server's reason, then retried later",
      hb.fields.get("state") == "fatal" and "station_token_not_recognised" in (hb.fields.get("note") or "")
      and clk.t >= RW2.FATAL_S - RW2.PAUSED_POLL_S, f"{hb.fields.get('state')} {hb.fields.get('note')} t={clk.t}")

check("loop: a server that hands out the hour IN PROGRESS (1.0.61 and older) gets NO claims from the loop",
      RW2.server_too_old("1.0.61") and RW2.server_too_old("1.0.9") and not RW2.server_too_old("1.0.62")
      and not RW2.server_too_old("1.1.0") and RW2.server_too_old(None) and RW2.server_too_old("garbage"))
_sd3 = tempfile.mkdtemp(prefix="hb-")
_hb = RW2.Heartbeat({"state": "starting"}, write=lambda d: ST.write_status(d, directory=_sd3), every=0.05).start()
# Read as the app does -- through the retrying reader. A bare open() here is what crashed
# this suite on the booth (PermissionError while the heartbeat thread replaced the file).
_s1 = ST.read_json(os.path.join(_sd3, ST.STATUS))
_hb.update(state="running", current="illumination")
_time.sleep(0.25)
_s2 = ST.read_json(os.path.join(_sd3, ST.STATUS))
_hb.stop(state="stopped")
_s3 = ST.read_json(os.path.join(_sd3, ST.STATUS))
check("status: written at once, kept current, and says when the worker stopped",
      _s1.get("state") == "starting" and _s2.get("state") == "running" and _s2.get("current") == "illumination"
      and _s3.get("state") == "stopped" and {"updated_at", "pid", "host"} <= set(_s3), f"{_s1} {_s2} {_s3}")

# "stopped" is the LAST word even when a heartbeat write is in flight. Each flush copies
# the fields and then writes; unserialised, a heartbeat that copied "running" could land
# after stop() wrote "stopped", and the file said running until it went stale.
_landed, _in_write = [], threading.Event()
def _slow_write(d):
    if threading.current_thread().name == "hb-thread":
        _in_write.set(); _time.sleep(0.3)        # the write lands AFTER this pause
    _landed.append(d.get("state"))
_hb2 = RW2.Heartbeat({"state": "running"}, write=_slow_write, every=0.01)
_hb2._thread.name = "hb-thread"
_hb2.start()
_in_write.wait(2)
_hb2.stop(state="stopped")
_hb2._thread.join(2)                  # look only after every write has LANDED
check("status: 'stopped' is the last write, even with a heartbeat write in flight",
      _landed[-1:] == ["stopped"], str(_landed))

# The same for ANY update, which pins the write lock on its own (stop() also joins the
# thread, so the check above holds with either guard). A heartbeat write holding "idle"
# is in flight; an update to "running" must not be overtaken by it.
_landed2, _in2, _go2 = [], threading.Event(), threading.Event()
def _held_write(d):
    if threading.current_thread().name == "hb-thread-2":
        _in2.set(); _go2.wait(5)
    _landed2.append(d.get("state"))
_hb3 = RW2.Heartbeat({"state": "idle"}, write=_held_write, every=0.01)
_hb3._thread.name = "hb-thread-2"
_hb3.start()
_in2.wait(2)
_t2 = threading.Thread(target=lambda: _hb3.update(state="running")); _t2.start()
_time.sleep(0.1)                      # the update runs now: it writes, or it waits its turn
_go2.set(); _t2.join(5)
_hb3.stop(state="stopped")
_hb3._thread.join(2)                  # look only after every write has LANDED
_first = _landed2.index("running") if "running" in _landed2 else None
check("status: an update is never overtaken by an older heartbeat write already in flight",
      _first is not None and "idle" not in _landed2[_first:], str(_landed2))

# ---- Windows: both sides of an atomic replace are refused for a moment (see station.py).
_sd4 = tempfile.mkdtemp(prefix="win-")
_real_replace, _calls = os.replace, []
def _refused(n):
    def rep(a, b):
        _calls.append(1)
        if len(_calls) <= n:
            raise PermissionError(13, "Access is denied")
        return _real_replace(a, b)
    return rep
try:
    os.replace = _refused(3)
    try:
        ST.write_status({"state": "running"}, directory=_sd4); _wrote = True
    except PermissionError:
        _wrote = False
    check("a replace REFUSED 3 times (Windows, reader holding the file) still writes status.json",
          _wrote and len(_calls) == 4 and ST.read_json(os.path.join(_sd4, ST.STATUS)).get("state") == "running",
          f"{_wrote} {len(_calls)}")
    _calls.clear(); os.replace = _refused(10 ** 6)
    try:
        ST.write_status({"state": "idle"}, directory=_sd4); _raised = False
    except PermissionError:
        _raised = True
    check("...refused for good, it RAISES after RETRIES tries (the heartbeat reports it) and leaves no temp file",
          _raised and len(_calls) == ST.RETRIES
          and not [f for f in os.listdir(_sd4) if f.startswith(".tmp-")], f"{_raised} {len(_calls)} {os.listdir(_sd4)}")
finally:
    os.replace = _real_replace

import builtins as _bi
_opens = []
def _flaky_open(n):
    def op(*a, **k):
        _opens.append(1)
        if len(_opens) <= n:
            raise PermissionError(13, "Access is denied")
        return _bi.open(*a, **k)
    return op
ST.write_control(False, camera_health=True, by="test", directory=_sd4)
try:
    _opens.clear(); ST.open = _flaky_open(3)
    _c = ST.read_control(_sd4)
    check("control: an open refused mid-replace is RETRIED, not read as a spurious pause",
          _c["paused"] is False and _c["camera_health"] is True and len(_opens) == 4, f"{_c} {len(_opens)}")
    _opens.clear(); ST.open = _flaky_open(10 ** 6)
    try:
        ST.write_control(True, by="test", directory=_sd4); _raised = False
    except PermissionError:
        _raised = True
finally:
    del ST.open
_after = ST.read_json(os.path.join(_sd4, ST.CONTROL))
check("control: a control.json that will not open is NOT overwritten (the camera_health opt-in survives)",
      _raised and _after.get("camera_health") is True and _after.get("paused") is False, f"{_raised} {_after}")

# ---------------------------------------------------------------- imports on Windows
# c934dda vendored a module with `import resource` at its top. `resource` is Unix-only,
# so on Windows `import plugins` failed: no station there could load the worker, and
# this very test failed in pre-commit and blocked EVERY commit on the booth PC. Nothing
# run on Linux could see it -- the second such break in two days (execinfo.h, 854cb4c,
# was the first). Two checks now make this class visible from Linux:
#   1. static: no tools/labs module imports a Unix-only module when it LOADS;
#   2. live: the worker really imports with `resource` removed -- the exact failure.
# Boundary, stated so nobody over-reads a pass: neither catches a Unix-only ATTRIBUTE
# (os.fork, signal.SIGKILL) or a Unix-only path taken at run time. Only a Windows run
# sees those.
import ast, subprocess
UNIX_ONLY = {"posix", "pwd", "grp", "termios", "tty", "pty", "fcntl", "resource", "syslog",
             "crypt", "spwd", "nis", "readline", "curses", "_posixsubprocess"}
_GUARDS = {"ImportError", "ModuleNotFoundError", "Exception", "BaseException"}

def _guarded(t):
    for h in t.handlers:
        if h.type is None:
            return True
        names = h.type.elts if isinstance(h.type, ast.Tuple) else [h.type]
        if any(isinstance(n, ast.Name) and n.id in _GUARDS for n in names):
            return True
    return False

def load_time_imports(stmts):
    """(line, top-level package) for every import that runs when the module LOADS:
    its body, including if/with/for/try blocks and class bodies, but not function
    bodies (they run when called, if ever). The body of a try that catches ImportError
    is guarded -- that import is allowed to fail -- so it is not counted."""
    for st in stmts:
        if isinstance(st, ast.Import):
            for a in st.names:
                yield st.lineno, a.name.split(".")[0]
        elif isinstance(st, ast.ImportFrom):
            if st.level == 0 and st.module:
                yield st.lineno, st.module.split(".")[0]
        elif isinstance(st, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        else:
            skip_body = isinstance(st, ast.Try) and _guarded(st)
            for fname, value in ast.iter_fields(st):
                if (skip_body and fname == "body") or not isinstance(value, list):
                    continue
                for v in value:
                    if isinstance(v, ast.stmt):
                        yield from load_time_imports([v])
                    elif isinstance(v, (ast.ExceptHandler, ast.match_case)):
                        yield from load_time_imports(v.body)

def unix_only_at_load(src):
    return [(ln, m) for ln, m in load_time_imports(ast.parse(src).body) if m in UNIX_ONLY]

# Controls first: a checker that cannot fail proves nothing.
check("control: a top-level `import resource` IS flagged",
      unix_only_at_load("import json\nimport resource\n") == [(2, "resource")])
check("control: `from fcntl import ...` inside an `if` at module level IS flagged",
      unix_only_at_load("import os\nif os.name == 'posix':\n    from fcntl import flock\n") == [(3, "fcntl")])
check("control: the same import inside a FUNCTION is not (it runs only when called)",
      unix_only_at_load("def _cpu():\n    import resource\n    return resource\n") == [])
check("control: a try/except ImportError guard is not flagged",
      unix_only_at_load("try:\n    import resource\nexcept ImportError:\n    resource = None\n") == [])

_bad = [f"{py.name}:{ln} {m}" for py in sorted((ROOT / "tools/labs").glob("*.py"))
        for ln, m in unix_only_at_load(py.read_text(encoding="utf-8"))]
check("no tools/labs module imports a Unix-only module when it loads", not _bad, ", ".join(_bad))

_probe = ("import sys\n"
          "sys.modules['resource'] = None\n"
          "try:\n    import resource\n    print('control-not-blocked')\n"
          "except ImportError:\n    print('control-blocked')\n"
          "sys.path.insert(0, sys.argv[1])\n"
          "import plugins, run_worker\n"
          "print('worker-imported')\n")
_r = _run([sys.executable, "-c", _probe, str(ROOT / "tools" / "labs")], timeout=120, text=True)
check("control: in the probe, `import resource` really fails (as on Windows)",
      "control-blocked" in _r.stdout, _r.stdout.strip())
_tail = (_r.stderr.strip().splitlines() or [""])[-1]
check("the worker (plugins + run_worker) imports with `resource` absent",
      _r.returncode == 0 and "worker-imported" in _r.stdout, _tail)

# ---------------------------------------------------------------- the registry
# c934dda built three plugins and did not register them: run_worker could not run any
# of them. A plugin that exists but cannot be selected is a silent no-op.
import run_worker as RW
_built = {c.name: c for c in vars(P).values()
          if isinstance(c, type) and c.__module__ == P.__name__
          and isinstance(getattr(c, "name", None), str) and hasattr(c, "version")}
check("every plugin in plugins.py is registered in run_worker",
      set(_built) == set(RW.PLUGINS),
      f"unregistered {sorted(set(_built) - set(RW.PLUGINS))}  unknown {sorted(set(RW.PLUGINS) - set(_built))}")
check("...each under its own analyser name (what --analyzer names is what gets claimed)",
      all(cls.name == key for key, cls in RW.PLUGINS.items()),
      str({k: c.name for k, c in RW.PLUGINS.items() if c.name != k}))

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}", file=sys.stderr); sys.exit(1)
print("all passed")
