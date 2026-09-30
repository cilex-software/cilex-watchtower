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
# cilex-vision 2026-09-28: a 5xx with no JSON at all (Starlette's plain "Internal Server
# Error") is the server FAILING -- its claim query over a 30 s database timeout -- not a
# refusal. It must not be mistaken for an unknown slug, and an unknown slug not for it.
_bare500 = W._refusal_from(500, b"Internal Server Error")
check("a bare 500 (no JSON body) is an UNCODED server error",
      W._uncoded_server_error(_bare500) and _bare500.detail is None and _bare500.retryable is None)
check("...a CODED 500 is not: its slug decides", not W._uncoded_server_error(R(500, "something_new")))
check("...nor is a bare 4xx (the no-token 401 carries no code either)",
      not W._uncoded_server_error(W._refusal_from(401, b"")))
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

c = Fake(units={"illumination": [unit()]},
         refuse={("claim", "illumination"): [W._refusal_from(500, b"Internal Server Error")]},
         segs={("cam-a", "2026-09-24T10:00:00Z"): [seg(1)]})
slept = []
rep = W.run_once(c, [B1], decode=decode_chroma(11.5), states={}, sleep=slept.append)
check("a bare 500 at claim is BUSY (it answered; next pass) -- not FATAL, not 'unreachable', not re-asked in place",
      rep.busy is not None and rep.unreachable is None and rep.fatal is None and slept == []
      and c.claims == ["illumination"],
      f"busy={rep.busy!r} unreachable={rep.unreachable!r} fatal={rep.fatal!r} slept={slept} claims={c.claims}")
rep = W.run_once(c, [B1], decode=decode_chroma(11.5), states={}, sleep=slept.append)
check("...and the next pass claims and submits as normal", rep.submitted == 1 and rep.fatal is None, str(rep))
c = Fake(refuse={("claim", "illumination"): [R(500, "something_new")]})
rep = W.run_once(c, [B1], decode=decode_chroma(11.5), states={})
check("...while a CODED unknown 500 at claim is still FATAL, never guessed at",
      rep.fatal is not None and rep.unreachable is None and rep.busy is None)

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
        return [{"start_time": "2026-09-24T10:15:00Z", "end_time": "2026-09-24T10:15:00Z",
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
        return [{"start_time": "2026-09-24T10:15:00Z", "end_time": "2026-09-24T10:15:00Z",
                 "metrics": {"fine": 1}},
                {"start_time": "2026-09-24T10:15:00Z", "end_time": "2026-09-24T10:15:00Z",
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
# One PASS, FAIL or SKIP line PER CHECK, so a box without their checkout can count what it
# did not run (the booth once had to infer a missing check from totals: one SKIP line
# used to stand for five checks).
cvsrc = pathlib.Path("/home/cilex-vision/projects/cilex-vision/services/query-api/routers/labs.py")
_t = cvsrc.read_text(encoding="utf-8") if cvsrc.exists() else None
_CAPS = [   # (what, pattern in their source, ours, parse)
    ("analyzer_version max_length", r"analyzer_version: str = Field\(min_length=1, max_length=(\d+)\)", 64, int),
    ("MAX_METRIC_KEYS", r"^MAX_METRIC_KEYS\s*=\s*(\d+)", W.MAX_METRIC_KEYS, int),
    ("MAX_METRIC_KEY_LEN", r"^MAX_METRIC_KEY_LEN\s*=\s*(\d+)", W.MAX_METRIC_KEY_LEN, int),
    ("MAX_METRIC_STR_LEN", r"^MAX_METRIC_STR_LEN\s*=\s*(\d+)", W.MAX_METRIC_STR_LEN, int),
    ("GROUP_MAX_SPAN_S default",
     r'^GROUP_MAX_SPAN_S\s*=\s*float\(os\.environ\.get\("LABS_GROUP_MAX_SPAN_S",\s*"(\d+)"\)\)', W.GROUP_MAX_SPAN_S, float),
]
for _what, _pat, _ours, _parse in _CAPS:
    if _t is None:
        print(f"SKIP {_what} vs cilex-vision's source -- their checkout is not on this box")
        continue
    m = re.search(_pat, _t, re.M)
    theirs = _parse(m.group(1)) if m else None
    check(f"{_what} matches cilex-vision's source ({theirs})", theirs == _ours, f"ours {_ours}, theirs {theirs}")

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
        return [{"start_time": "2026-09-24T10:00:00Z", "end_time": "2026-09-24T10:00:00Z", "metrics": {}}] * 501
class ManyRaw:
    name = "many"; version = "t"; segment_limit = 1; keyframes_only = True
    want_chroma = False; stateful = False; wants_raw = True
    def new_state(self): return None
    def window_at(self, u): return 0.5
    def analyse_raw(self, chunks, segs, u):
        list(chunks); return [{"start_time": "2026-09-24T10:00:00Z", "end_time": "2026-09-24T10:00:00Z", "metrics": {}}] * 501
for label, plug in (("frame path", Many()), ("raw path", ManyRaw())):
    u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]})
    W.run_unit(c, plug, u, decode=decode_chroma(11.5), states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    check(f"501 rows on the {label} are filed FAILED with the cause, never sent to the server",
          b.get("failed") is True and "too_many_observations" in (b.get("error") or "")
          and b.get("observations") == [], str(b)[:120])

# EVERY ROW MUST START INSIDE THE CLAIMED HOUR (worker-0.3.4). One that did not sank the whole
# unit: 422 observation_outside_claimed_hour, filed failed -- 16 blob_geometry units on
# 2026-09-28/29, some to their third attempt (Windows agent). The hour's last segment runs
# past the hour, and a shape seen in its tail was timed there. Dropped and counted, never moved.
_ROWS = [{"start_time": "2026-09-24T10:00:00Z", "end_time": "2026-09-24T10:00:00Z", "metrics": {}},     # the hour's first instant
         {"start_time": "2026-09-24T10:59:59.500Z", "end_time": "2026-09-24T10:59:59.500Z", "metrics": {}},
         {"start_time": "2026-09-24T11:00:00Z", "end_time": "2026-09-24T11:00:00Z", "metrics": {}},     # the NEXT hour's start
         {"start_time": "2026-09-24T11:00:17.250Z", "end_time": "2026-09-24T11:00:17.250Z", "metrics": {}}, # the last segment's tail
         {"start_time": "2026-09-24T09:59:59Z", "end_time": "2026-09-24T09:59:59Z", "metrics": {}}]       # before the hour
class _Tail(Nothing):
    def analyse(self, segs, st, u, ctx):
        for _ in segs: pass
        return [dict(r) for r in _ROWS]
class _TailRaw(ManyRaw):
    def analyse_raw(self, chunks, segs, u):
        list(chunks); return [dict(r) for r in _ROWS]
for label, plug in (("frame path", _Tail()), ("raw path", _TailRaw())):
    u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]})
    o = W.run_unit(c, plug, u, decode=decode_chroma(11.5), states={}, tmpdir=TMP, sleep=lambda s: None)
    b = c.submitted[0][1] if c.submitted else {}
    starts = [r["start_time"] for r in b.get("observations") or []]
    check(f"{label}: rows starting outside the claimed hour are DROPPED before submitting -- the unit is filed, not refused",
          o.submitted and not b.get("failed") and starts == ["2026-09-24T10:00:00Z", "2026-09-24T10:59:59.500Z"],
          f"submitted={o.submitted} failed={b.get('failed')} starts={starts}")
    check(f"{label}: ...and COUNTED, in the unit's note (3: the next hour's first instant, the tail, and one before)",
          o.rows_outside_hour == 3 and "3 row(s) outside the claimed hour" in (o.note or ""), f"{o.rows_outside_hour} {o.note!r}")
_k, _d = W._within_hour([{"start_time": "not a time"}, {"no": "start"}], unit())
check("a row whose start cannot be read is KEPT -- the server judges it, not a guess here", len(_k) == 2 and _d == 0)

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
    # A PASSAGE (A4-A6 1.2.0): one row from a moving blob's first detection to its last.
    class _Pass:
        def __init__(self, sid, span): self.sid, self.span = sid, span
        def as_payload(self):
            return {"segment_id": self.sid, "t_offset_s": 16.986, "shape_class": "blob_compact",
                    "object_count": 1, "recur_count": 19, "recur_folded": False, "span_s": self.span,
                    "shape_votes": "blob_compact:11,blob_wide:4"}
    def _passage(span):
        def w(stream, state, cfg):
            for meta, frames in stream:
                list(frames); yield meta, [_Pass(meta.segment_id, span)], None
        return w
    P.so.analyse_window = _passage(18.01)
    c = Fake(segs={(ub_.camera_id, ub_.hour_start): segs3[:1]})
    run(c, P.ShapePlugin(), ub_)
    rows_ = c.submitted[0][1].get("observations") or []
    check("a PASSAGE row lasts its span: from its first detection (10:00:16.986) to its last (10:00:34.996)",
          len(rows_) == 1 and rows_[0]["start_time"].startswith("2026-09-24T10:00:16.986")
          and rows_[0]["end_time"].startswith("2026-09-24T10:00:34.996")
          and (rows_[0].get("metrics") or {}).get("recur_count") == 19, str(rows_))
    P.so.analyse_window = _passage(300.0)
    c = Fake(segs={(ub_.camera_id, ub_.hour_start): segs3[:1]})
    run(c, P.ShapePlugin(), ub_)
    b_ = c.submitted[0][1]
    check("...and one at the 300 s group limit files the unit FAILED, never a row no group can hold",
          b_.get("failed") is True and "under 300 s" in (b_.get("error") or ""), str(b_)[:200])
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

# A JOIN THAT RUNS BACK BY A SECOND OR LESS IS THE CATALOGUE'S ROUNDING (2026-09-28).
# start_time is the recorder's whole-second file name, so a segment can be catalogued
# before its predecessor's last frame. The office's colour_histogram unit
# (hiwatch-083bc1df39e9, 02:00Z) failed on exactly that, every retry: "frame 100: t_s
# 89.000 is before the previous frame's 89.126". Reproduced on the real footage here.
def _seg_at(sid, start_s, dur=30.0):
    st = _dt(2026, 9, 28, 2, 7, tzinfo=_tz.utc) + _td(seconds=start_s)
    return W.Segment(sid, f"http://x/{sid}", st.isoformat(), (st + _td(seconds=dur)).isoformat(),
                     dur, 1000, "sub", 640, 360, "h264")
class _At:                                  # a frame: offset from ITS segment's first frame
    def __init__(self, t): self.t_offset_s, self.luma, self.u, self.v = t, None, None, None
def _times(win, moved=None):
    """The window's times -- or, if it raised, the error as a string (so a regression
    FAILS its check by name instead of crashing the suite)."""
    try:
        return [t for t, _ in P._window_frames(win, planes=False, moved=moved)]
    except ValueError as e:
        return f"raised: {e}"
def _near(a, b):
    return isinstance(a, list) and len(a) == len(b) and all(abs(x - y) < 1e-9 for x, y in zip(a, b))

# The office's numbers: the third segment's last frame is 60 + 29.126 = 89.126, and the
# fourth is catalogued at +89 s, so its first frame reads 89.000.
_mv = []
_ts = _times([(_seg_at("a", 0), [_At(0.0), _At(29.0)]), (_seg_at("b", 30), [_At(0.0), _At(29.0)]),
              (_seg_at("c", 60), [_At(0.0), _At(29.126)]),
              (_seg_at("d", 89), [_At(0.0), _At(1.0), _At(29.5)])], _mv)
check("join: the office's case -- a segment catalogued 0.126 s before the previous frame is moved "
      "later WHOLE: its first frame level with that frame, its own spacing kept",
      _near(_ts[6:], [89.126, 90.126, 118.626]) and len(_mv) == 1 and _mv[0][0] == "d"
      and abs(_mv[0][1] - 0.126) < 1e-9, f"{_ts} {_mv}")
check("join: segments that do not run back are NOT moved (start + offset, exactly)",
      _near(_ts[:6], [0.0, 29.0, 30.0, 59.0, 60.0, 89.126]), str(_ts))
_mv = []
_ts = _times([(_seg_at("a", 0), [_At(0.0), _At(29.95)]), (_seg_at("b", 30), [_At(0.0), _At(1.0)])], _mv)
check("join: a join that steps FORWARD, however little (0.05 s), is left alone",
      _near(_ts, [0.0, 29.95, 30.0, 31.0]) and _mv == [], f"{_ts} {_mv}")
_mv = []
_ts = _times([(_seg_at("a", 0), [_At(0.0), _At(29.4)]), (_seg_at("b", 29), [_At(0.0), _At(29.4)]),
              (_seg_at("c", 58), [_At(0.0), _At(29.4)])], _mv)
check("join: a chain -- the next segment runs back behind a MOVED one, and is moved by what IT needs",
      _near(_ts, [0.0, 29.4, 29.4, 58.8, 58.8, 88.2])
      and [s for s, _ in _mv] == ["b", "c"] and _near([b for _, b in _mv], [0.4, 0.8]), f"{_ts} {_mv}")
_mv = []
_ts = _times([(_seg_at("a", 0), [_At(0.0), _At(30.0)]), (_seg_at("b", 29), [_At(0.0)])], _mv)
check("join: exactly one second back is still the rounding (cilex-vision's bound: <= 1 s)",
      _near(_ts, [0.0, 30.0, 30.0]) and len(_mv) == 1, f"{_ts} {_mv}")
_why = _times([(_seg_at("a", 0), [_At(0.0), _At(29.5)]), (_seg_at("e", 28), [_At(0.0)])])
check("join: MORE than a second back is not the rounding -- refused, naming the segment",
      isinstance(_why, str) and "segment e starts 1.500 s before" in _why, str(_why))
_ts = _times([(_seg_at("a", 0), [_At(0.0), _At(5.0), _At(4.0)])])
_lum = np.zeros((36, 64), np.uint8)
try:
    list(FMM.iter_masks(((t, _lum) for t in _ts)))
    _why = None
except ValueError as e:
    _why = str(e)
check("join: a step back INSIDE a segment is not touched -- it is the decoder's, and B3 still refuses it",
      _near(_ts, [0.0, 5.0, 4.0]) and _why is not None and "before the previous frame" in _why,
      f"{_ts} {_why}")

def _early(segs_, early):
    """The scene's segments with some catalogued `early` seconds before their true
    start -- what whole-second rounding does -- and end_time = start + duration, as the
    recorder writes it (recorder-service main.py:607)."""
    out = []
    for s in segs_:
        d = early.get(s.segment_id, 0.0)
        st = _dt.fromisoformat(s.start_time) - _td(seconds=d)
        out.append(W.Segment(s.segment_id, s.fetch_url, st.isoformat(),
                             (st + _td(seconds=s.duration_s)).isoformat(), s.duration_s,
                             s.bytes, s.stream_type, s.width, s.height, s.codec))
    return out
# 32 keyframes per 30 s segment: the last one 29.0625 s in, so a segment catalogued a
# second early reads 0.0625 s behind its predecessor's last frame.
_sg, _fr = scene(moving=True, per_seg=32)
_sg = _early(_sg, {"seg-1": 1.0, "seg-3": 1.0})
for _plug, _label in ((FMP, "B3"), (CHP, "B7")):
    o, b = run_scene(_plug, _sg, _fr)
    _rows = b.get("observations") or []
    check(f"join: {_label} files its window when joins run back by the rounding (it FAILED, every retry)",
          not b.get("failed") and len(_rows) == 1 and o.segments_scanned == 4
          and _rows[0]["start_time"].startswith("2026-09-26T01:10:00"),
          f"failed={b.get('failed')} {str(b.get('error'))[:160]} rows={len(_rows)}")

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
# One clock for phase times, and a fine one. time.monotonic() is GetTickCount64 on Windows,
# 15.6 ms steps (measured on the booth): the check above failed there 1 run in 20. On Linux
# both clocks are CLOCK_MONOTONIC, so only this static pin can catch a revert from here.
import time as _tm
_wsrc = (ROOT / "tools" / "labs" / "worker.py").read_text(encoding="utf-8")
check("the worker times its phases with perf_counter, and nothing in it calls time.monotonic()",
      W._now is _tm.perf_counter and "time.monotonic(" not in _wsrc)

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
      ST.read_control(_sd2) == {"paused": True, "camera_health": False, "why": "never started on this station",
                                "hold": None},
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
import lanes as LN, random as _rnd
from concurrent.futures import ThreadPoolExecutor as _TPE

# ---- station scanning: one LANE per analyser (worker-0.3.5) --------------------------------
# The operator's requirement (2026-09-29, via cilex-vision's letter): each analyser runs on
# its own, so a busy or stuck one cannot stop the others. Until 0.3.4 one busy claim ended
# the whole alphabetical pass for a minute. The scheduler runs here on a fake clock with an
# executor that does each claim and unit at once, so every order below is exact.
T = LN.Timing()
def timed(c, clk):
    """Record when each claim was made, on the fake clock."""
    c.times, orig = [], c.claim
    def claim(a, limit):
        c.times.append((round(clk.t, 3), a)); return orig(a, limit)
    c.claim = claim
    return c
class LimitFake(Fake):
    """A server that honours `limit` (Fake hands over every unit it has at once)."""
    def claim(self, analyzer, limit):
        self.claims.append(analyzer); self._pop("claim", analyzer)
        q = self.units.get(analyzer, []); u, self.units[analyzer] = q[:limit], q[limit:]
        return u, len(self.units[analyzer])
def lane_world(names, units_per=1, cls=LimitFake):
    units = {n: [W.ScanUnit(f"cam-{n}-{i}", "2026-09-26T08:00:00Z", n, None, 1) for i in range(units_per)] for n in names}
    segs = {(u.camera_id, u.hour_start): [seg(1)] for us in units.values() for u in us}
    return cls(units=units, segs=segs), [NamedPlug(n) for n in names]
def sched(c, plugs, clk, control, *, reporter=None, station_check=None, order=None, runner=None,
          decode=None, supported=None, rng=None, hb=None):
    hb = hb if hb is not None else HbRec()
    names = [p.name for p in plugs]
    ask = reporter.abort_reason if reporter is not None else (lambda u: None)
    runner = runner or LN.InProcessRunner(c, decode=decode or decode_chroma(11.5), abort_reason=ask,
                                          tmpdir=TMP, sleep=lambda s: None)
    s = LN.Scheduler(c, supported or (lambda: plugs), runner=runner, hb=hb, names=names, control=control,
                     reporter=reporter, station_check=station_check, executor=LN.SyncExecutor(),
                     clock=clk.now, sleep=clk.sleep, order=None if rng is not None else (order or names), rng=rng)
    return s, hb
def done_by(c, name): return sum(1 for u, b in c.submitted if u.analyzer == name and not b.get("failed"))
def claims_of(c, name): return [t for t, a in c.times if a == name]

c, plugs = loop_world(["illumination", "foreground_mask"])
clk = Clock(); timed(c, clk)
s, hb = sched(c, plugs, clk, ctl_seq({"paused": True}))
s.run(until=lambda: clk.t >= 60)
check("lanes: PAUSED claims nothing and says so", c.claims == [] and hb.fields.get("state") == "paused",
      f"{c.claims} {hb.fields.get('state')}")

# Paused, it still keeps "what this station could run" current: the capability check is a
# read of the server's OpenAPI, and without it a worker paused since an old server showed
# "needs a server update" for every analyser however far the server had moved.
_asked = []
c, plugs = loop_world(["illumination"]); clk = Clock()
s, hb = sched(c, plugs, clk, ctl_seq({"paused": True}), supported=lambda: _asked.append(clk.t) or plugs)
s.run(until=lambda: clk.t >= 3 * T.legacy_poll_s)
check("lanes: PAUSED still asks what the server can run at every tick (supported() rate-limits its own reads), "
      "and claims nothing",
      len(_asked) >= 3 and c.claims == [] and max(b - a for a, b in zip(_asked, _asked[1:])) <= T.legacy_poll_s + 0.01,
      f"{_asked} {c.claims}")

c, plugs = loop_world(["illumination", "foreground_mask"]); clk = Clock(); timed(c, clk)
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}))
tot = s.run(until=lambda: clk.t >= T.idle_s + 10)
check("lanes: each lane claims ONE unit when its turn comes, in the queue's order",
      c.claims[:2] == ["illumination", "foreground_mask"], str(c.claims))
check("lanes: every unit is counted and the last one is shown",
      tot == {"claimed": 2, "done": 2, "failed": 0, "abandoned": 0, "revoked": 0}
      and (hb.fields.get("last_unit") or {}).get("analyzer") == "foreground_mask", f"{tot} {hb.fields.get('last_unit')}")
check("lanes: a lane with nothing to claim goes IDLE, and asks again only after idle_s -- no spinning",
      hb.fields.get("state") == "idle" and len(c.times) == 6 and all(t < 1 for t, _a in c.times[:4])
      and all(t >= T.idle_s for t, _a in c.times[4:]), f"{hb.fields.get('state')} {c.times}")

_box = {"paused": False, "camera_health": False, "why": "", "hold": None}
_dec = decode_chroma(11.5)
def _pause_mid_unit(path, kf, wc, **k):
    _box.update(paused=True, why="paused"); return _dec(path, kf, wc)
c, plugs = loop_world(["illumination", "foreground_mask"]); clk = Clock()
s, hb = sched(c, plugs, clk, lambda: dict(_box), decode=_pause_mid_unit)
tot = s.run(until=lambda: clk.t >= 30)
check("lanes: a Pause lands at the NEXT claim -- the unit in hand is finished and submitted, nothing more is claimed",
      c.claims == ["illumination"] and len(c.submitted) == 1 and tot["done"] == 1 and hb.fields.get("state") == "paused",
      f"{c.claims} {tot} {hb.fields.get('state')}")

c, plugs = loop_world(["illumination", "camera_health"]); clk = Clock()
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}))
s.run(until=lambda: clk.t >= 10)
check("lanes: camera_health is NOT run on a station that has not opted in (one station only)",
      "camera_health" not in c.claims and "illumination" in c.claims and hb.fields.get("camera_health") is False,
      str(c.claims))
c, plugs = loop_world(["illumination", "camera_health"]); clk = Clock()
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False, "ch": True}))
s.run(until=lambda: clk.t >= 10)
check("...and IS run where the control file opts this station in", "camera_health" in c.claims, str(c.claims))

c, plugs = loop_world(["illumination", "foreground_mask"]); clk = Clock(); timed(c, clk)
c.refuse = {("claim", "illumination"): [R(401, "station_token_not_recognised")]}
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}))
s.run(until=lambda: clk.t >= T.fatal_s + 5)
_fat = [e for e in hb.log if e.get("state") == "fatal"]
check("lanes: a refused station token is the STATION's fault -- FATAL with the server's reason, and NO lane "
      "claims until the fatal pause is over",
      _fat and "station_token_not_recognised" in (_fat[0].get("note") or "") and c.times[0][1] == "illumination"
      and len(c.times) >= 2 and all(t >= T.fatal_s for t, _a in c.times[1:]), f"{c.times} {_fat[:1]}")

c, plugs = lane_world(["illumination", "foreground_mask"], units_per=3); clk = Clock(); timed(c, clk)
c.refuse = {("claim", "illumination"): [W._refusal_from(500, b"Internal Server Error")]}
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}))
s.run(until=lambda: clk.t >= T.busy_s + 5)
_ill = claims_of(c, "illumination")
_busy = [e for e in hb.log if e.get("state") == "busy"]
check("lanes: a bare claim 500 is BUSY for THAT lane only -- a minute, not ten -- and says what happened",
      len(_ill) >= 2 and T.busy_s <= _ill[1] - _ill[0] < T.fatal_s and _busy and "no code" in (_busy[0].get("note") or ""),
      f"illumination at {_ill} busy={_busy[:1]}")
check("...while the other lane claims and finishes all its units meanwhile",
      done_by(c, "foreground_mask") == 3 and all(t < 1 for t in claims_of(c, "foreground_mask")[:3]),
      f"foreground_mask at {claims_of(c, 'foreground_mask')}")

# THE LETTER'S CASE (cilex-vision, 2026-09-29): after the v17 reconnect 10 of 11 claims in
# 8 minutes were audio_energy -- first in the alphabet -- and 9 timed out, while the other
# analysers waited behind it.
_names = ["audio_energy", "colour_histogram", "illumination"]
c, plugs = lane_world(_names, units_per=4); clk = Clock(); timed(c, clk)
c.refuse = {("claim", "audio_energy"): [R(503, "labs_busy", True)] * 50}
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}), order=_names)     # audio first, as the alphabet had it
s.run(until=lambda: clk.t >= 2 * T.busy_s + 5)
_a = claims_of(c, "audio_energy")
check("lanes: the letter's case -- audio_energy's claims come back busy, and ONLY its lane waits: the other two "
      "finish all their units at once",
      done_by(c, "colour_histogram") == 4 and done_by(c, "illumination") == 4
      and all(t < 1 for n in _names[1:] for t in claims_of(c, n)[:5]), f"{c.times[:14]}")
check("...and audio_energy asks again once a minute (busy_s), never in a tight loop",
      len(_a) == 3 and all(b - x >= T.busy_s for x, b in zip(_a, _a[1:])), str(_a))

_n3 = ["optical_flow", "blob_geometry", "track_linking"]
c, plugs = lane_world(_n3, units_per=2); clk = Clock(); timed(c, clk)
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}), order=_n3)
s.run(until=lambda: clk.t >= 5)
check("lanes: with the in-process runner (one unit at a time) the lanes take TURNS -- a lane that has just had "
      "its unit queues behind the others",
      [a for _t, a in c.times[:6]] == _n3 + _n3, str(c.times[:6]))

_firsts = []
for _seed in range(20):
    c, plugs = lane_world(sorted(RW2.PLUGINS)); clk = Clock()
    s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}), rng=_rnd.Random(_seed))
    s.run(max_ticks=1)
    _firsts.append(c.claims[0] if c.claims else None)
check("lanes: no analyser is always first -- the first order is shuffled at every start",
      None not in _firsts and len(set(_firsts)) >= 5 and _firsts.count("audio_energy") < len(_firsts), str(_firsts))

class _Blocking:
    """Units that take a moment, on real threads: how many run at once, in all and per lane?"""
    single_slot = False
    def __init__(self):
        self.lock, self.now, self.peak, self.ran = threading.Lock(), 0, 0, []
        self.per, self.per_peak = {}, 0
    def run(self, unit, plugin):
        with self.lock:
            self.now += 1; self.peak = max(self.peak, self.now); self.ran.append(unit.analyzer)
            self.per[unit.analyzer] = self.per.get(unit.analyzer, 0) + 1
            self.per_peak = max(self.per_peak, self.per[unit.analyzer])
        _time.sleep(0.05)
        with self.lock:
            self.now -= 1; self.per[unit.analyzer] -= 1
        o = W.UnitOutcome(unit); o.submitted = True
        return o
    def abort(self, u, why): return False
    def abort_all(self, why): pass
def _lanes_run(one_at_a_time=False):
    names = ["illumination", "foreground_mask", "colour_histogram", "optical_flow"]
    c, plugs = lane_world(names, units_per=3)
    r = _Blocking(); r.single_slot = one_at_a_time
    s = LN.Scheduler(c, lambda: plugs, runner=r, hb=HbRec(), names=names, control=ctl_seq({"paused": False}),
                     executor=_TPE(max_workers=8),
                     timing=LN.Timing(poll_s=0.01, legacy_poll_s=0.01, idle_s=0.2))
    th = threading.Thread(target=s.run, daemon=True); th.start()
    end = _time.time() + 20
    while len(r.ran) < 12 and _time.time() < end:
        _time.sleep(0.02)
    s.stop(); th.join(5)
    return r
_rall, _rone = _lanes_run(), _lanes_run(one_at_a_time=True)
# worker-0.3.8, the operator (2026-09-29): "i define how many analysers run in parallel - that is
# defined by how many hoses are connected to the machine". No station-wide cap.
check("lanes: EVERY connected lane runs its unit AT ONCE -- 4 lanes, 3 units each: all 4 in flight together, "
      "and never two units of one lane (hoses decide, no station-wide cap)",
      len(_rall.ran) == 12 and _rall.peak == 4 and _rall.per_peak == 1,
      f"ran={len(_rall.ran)} peak={_rall.peak} per-lane peak={_rall.per_peak}")
check("...and the in-process runner (a station that cannot start unit processes) still runs one unit at a time",
      len(_rone.ran) == 12 and _rone.peak == 1, f"ran={len(_rone.ran)} peak={_rone.peak}")

# ---- FILL (worker-0.3.10, opt-in): the operator, 2026-09-30, relayed by cilex-vision: "ok do
# office PC only to run analyser for vehicles but use full capacity of this PC to the limit".
# A lane getting work takes one more unit at a time while the machine measures room: an idle
# logical CPU, free memory for FILL_MEM_FACTOR of its largest unit, no unit in hand past
# FILL_LEASE_SHARE of its lease, and fewer claims and units in hand than logical CPUs (and than
# the 32 a report may list). Real threads here; the machine is a fake the test sets.
import dataclasses as _dc
class _FillProbe:
    """The machine fill sees: logical CPUs, free memory, the largest unit measured, and the
    idle CPU -- a number, or a function of the scheduler (set .s after building it)."""
    def __init__(self, cores=8, free=64 * 2**30, unit=2**28, idle=None, can_walk=True):
        self.cores, self.free, self._unit, self.can_walk = cores, free, unit, can_walk
        self.idle, self.s, self.samples = (float(cores) if idle is None else idle), None, 0
    def sample(self, now): self.samples += 1
    def idle_cores(self, now, window_s): return self.idle(self.s) if callable(self.idle) else self.idle
    def unit_bytes(self, analyzer): return self._unit if self.can_walk else None
class _FillRunner:
    """Units that take `secs` on real threads: how many run at once, per analyser?"""
    single_slot = False
    def __init__(self, secs=0.15):
        self.lock, self.secs, self.now, self.ran, self.per, self.per_peak = threading.Lock(), secs, 0, [], {}, {}
    def run(self, unit, plugin):
        with self.lock:
            self.now += 1; self.ran.append(unit.camera_id); a = unit.analyzer
            self.per[a] = self.per.get(a, 0) + 1; self.per_peak[a] = max(self.per_peak.get(a, 0), self.per[a])
        _time.sleep(self.secs)
        with self.lock:
            self.now -= 1; self.per[unit.analyzer] -= 1
        o = W.UnitOutcome(unit); o.submitted = True
        return o
    def abort(self, u, why): return False
    def abort_all(self, why): pass
    def unit_pids(self): return []
class _FillFake(LimitFake):
    """Hands out units thread-safely, each leased for `lease_s` from ITS claim (None: no lease named)."""
    def __init__(self, *a, lease_s=None, **k):
        super().__init__(*a, **k); self._lk, self.lease_s = threading.Lock(), lease_s
    def claim(self, analyzer, limit):
        with self._lk:
            u, n = super().claim(analyzer, limit)
        if self.lease_s is not None:
            exp = (_dt.now(_tz.utc) + _td(seconds=self.lease_s)).isoformat()
            u = [_dc.replace(x, lease_expires_at=exp) for x in u]
        return u, n
_FT = dict(poll_s=0.005, legacy_poll_s=0.005, idle_s=0.3, fill_every_s=0.02, fill_window_s=0.01)
class _Said(logging.Handler):
    """What the scheduler logs during the fill tests, kept here instead of printed."""
    def __init__(self): super().__init__(logging.WARNING); self.lines = []
    def emit(self, rec): self.lines.append(rec.getMessage())
_said, _lanes_log = _Said(), logging.getLogger("labs.lanes")
_lanes_log.addHandler(_said); _lanes_log.propagate = False
def _fill_run(probe, *, units=40, secs=0.15, want_ran=20, lease_s=None, timing=None, control=None,
              during=None, names=("object_profile",)):
    names = list(names)
    c, plugs = lane_world(names, units_per=units, cls=lambda **k: _FillFake(lease_s=lease_s, **k))
    r, hb = _FillRunner(secs), HbRec()
    s = LN.Scheduler(c, lambda: plugs, runner=r, hb=hb, names=names,
                     control=control or ctl_seq({"paused": False}), executor=_TPE(max_workers=80),
                     timing=LN.Timing(**dict(_FT, **(timing or {}))), fill=probe)
    if probe is not None and hasattr(probe, "s"):
        probe.s = s
    th = threading.Thread(target=s.run, daemon=True); th.start()
    if during is not None:
        during(s, r)
    end = _time.time() + 20
    while len(r.ran) < want_ran and _time.time() < end:
        _time.sleep(0.01)
    s.stop(); th.join(5)
    return s, r, hb, c
def _in_flight(s): return sum(1 for x in list(s.lanes.values()) if x.op is not None)
def _nots(hb): return {(e.get("fill") or {}).get("not_adding") for e in hb.log if "fill" in e}

_s, _r, _hb, _c = _fill_run(_FillProbe(cores=4, idle=8.0))
_keys = {k for e in _hb.log for k in (e.get("lane_states") or {})}
_slots = max([(e.get("fill") or {}).get("slots", {}).get("object_profile", 1) for e in _hb.log] or [1])
check("fill: a lane getting work widens to as many units at once as this machine has logical CPUs "
      "(4 here), never more -- the ceiling is the machine's own number",
      len(_r.ran) >= 20 and _r.per_peak.get("object_profile") == 4, f"ran={len(_r.ran)} per-lane peak={_r.per_peak}")
check("...its extra slots never reach the Labs screen's lane list, which names each analyser once; "
      "the status file's `fill` counts them",
      _keys == {"object_profile"} and _slots == 4, f"lane_states keys={_keys} most slots={_slots}")
check("...and every unit the server handed over ran exactly once (40 units, no unit twice)",
      len(_r.ran) == len(set(_r.ran)), f"ran={len(_r.ran)} distinct={len(set(_r.ran))}")

_s, _r, _hb, _c = _fill_run(_FillProbe(cores=16, idle=lambda s: 16.0 - 4.0 * _in_flight(s)))
check("fill: it stops adding when the machine has no idle logical CPU left -- each unit here "
      "takes 4 of 16, so it settles at 4 at once, far under the 16 CPUs",
      len(_r.ran) >= 20 and _r.per_peak.get("object_profile") == 4 and "cpu" in _nots(_hb),
      f"ran={len(_r.ran)} per-lane peak={_r.per_peak} not_adding={_nots(_hb)}")

_s, _r, _hb, _c = _fill_run(_FillProbe(cores=16, free=int(1.5 * 2**28)), want_ran=6)
check("fill: no unit is added while free memory holds fewer than FILL_MEM_FACTOR of its largest unit",
      len(_r.ran) >= 6 and _r.per_peak.get("object_profile") == 1 and "memory" in _nots(_hb),
      f"per-lane peak={_r.per_peak} not_adding={_nots(_hb)}")

_s, _r, _hb, _c = _fill_run(_FillProbe(cores=16, can_walk=False), want_ran=6)
check("fill: a station that cannot measure a unit's memory (Windows without psutil) adds none, and says why",
      _r.per_peak.get("object_profile") == 1 and "unmeasurable" in _nots(_hb),
      f"per-lane peak={_r.per_peak} not_adding={_nots(_hb)}")

_s, _r, _hb, _c = _fill_run(_FillProbe(cores=16), secs=1.0, lease_s=0.2, want_ran=1,
                            timing={"fill_every_s": 0.2}, during=lambda s, r: _time.sleep(0.6))
check("fill: no unit is added while a unit in hand has used more than FILL_LEASE_SHARE of its lease "
      "(the server's lease_expires_at, set at the claim and not renewed)",
      _r.per_peak.get("object_profile") == 1 and "lease" in _nots(_hb),
      f"per-lane peak={_r.per_peak} not_adding={_nots(_hb)}")

del _said.lines[:]
_s, _r, _hb, _c = _fill_run(_FillProbe(cores=16), secs=0.12, lease_s=0.1, want_ran=12,
                            timing={"fill_every_s": 0.005}, during=lambda s, r: _time.sleep(0.5))
_late = [x for x in _said.lines if "gives back an extra unit slot" in x and "of its lease" in x]
check("fill: an extra slot whose unit used more than FILL_LEASE_SHARE of its lease is given back "
      "(this many at once is too many to keep units inside their leases)",
      _s._fill_made.get("object_profile", 0) >= 1 and len(_late) >= 1,
      f"extras made={_s._fill_made} given back for the lease={len(_late)} said={_said.lines[:4]}")

_s, _r, _hb, _c = _fill_run(None, want_ran=10)
check("fill OFF (no --fill, no WT_LABS_FILL): one unit per lane, as in worker-0.3.8",
      len(_r.ran) >= 10 and _r.per_peak.get("object_profile") == 1 and "fill" not in _hb.fields,
      f"per-lane peak={_r.per_peak}")

def _until_dry(s, r):
    end = _time.time() + 10
    while (len(r.ran) < 3 or r.now or any(x.extra for x in list(s.lanes.values()))) and _time.time() < end:
        _time.sleep(0.005)
    _time.sleep(0.05)
_s, _r, _hb, _c = _fill_run(_FillProbe(cores=8), units=3, want_ran=3, during=_until_dry)
check("fill: when the claims find nothing the extra slots go, and each of the 3 units ran exactly once",
      len(_r.ran) == 3 and len(set(_r.ran)) == 3 and not any(x.extra for x in _s.lanes.values())
      and _s._fill_dry.get("object_profile") is not None and _s._fill_made.get("object_profile", 0) >= 1,
      f"ran={_r.ran} lanes={[x.name for x in _s.lanes.values()]} dry={_s._fill_dry} made={_s._fill_made}")

_hold = {"hold": None}
_phase = {}
def _hold_then_release(s, r):
    end = _time.time() + 10
    while r.per_peak.get("object_profile", 0) < 3 and _time.time() < end:
        _time.sleep(0.005)
    _hold["hold"] = {"why": "a test", "by": "wall-guard"}
    _phase["ran_at_hold"] = len(r.ran)
    end = _time.time() + 10
    while (r.now or any(x.extra for x in list(s.lanes.values()))) and _time.time() < end:
        _time.sleep(0.005)
    _phase["extras_held"] = [x.name for x in list(s.lanes.values()) if x.extra]
    _phase["ran_settled"] = len(r.ran)
    _time.sleep(0.1)
    _phase["ran_held"] = len(r.ran)
    with r.lock:
        r.per_peak.clear()
    _hold["hold"] = None
_hctl = lambda: {"paused": False, "camera_health": False, "why": "", "hold": _hold["hold"]}
_s, _r, _hb, _c = _fill_run(_FillProbe(cores=8), units=200, control=_hctl, during=_hold_then_release, want_ran=60)
check("fill: a hold (the wall guard's) gives back every extra slot once its unit ends, and claims nothing ...",
      _phase.get("extras_held") == [] and _phase.get("ran_held") == _phase.get("ran_settled") is not None,
      str(_phase))
check("...and after the release the lane fills again from one unit",
      _r.per_peak.get("object_profile", 0) >= 3, f"per-lane peak after release={_r.per_peak}")

_p = _FillProbe(cores=8)
_s1 = LN.Scheduler(Fake(), lambda: [], runner=_FillRunner(), hb=HbRec(), names=["object_profile"],
                   control=ctl_seq({"paused": False}), executor=LN.SyncExecutor(), fill=_p)
_rone = _FillRunner(); _rone.single_slot = True
_s2 = LN.Scheduler(Fake(), lambda: [], runner=_rone, hb=HbRec(), names=["object_profile"],
                   control=ctl_seq({"paused": False}), executor=LN.SyncExecutor(), fill=_p)
check("fill: the in-process runner ignores it (one unit at a time, as before)", _s1.fill is _p and _s2.fill is None)

from concurrent.futures import Future as _Fut
_p64 = _FillProbe(cores=64)
_s3 = LN.Scheduler(Fake(), lambda: [], runner=_FillRunner(), hb=HbRec(), names=["object_profile"],
                   control=ctl_seq({"paused": False}), executor=LN.SyncExecutor(), fill=_p64)
for _i in range(31):
    _x = LN.Lane(f"object_profile+{_i + 1}", analyzer="object_profile"); _x.op = _Fut(); _s3.lanes[_x.name] = _x
_s3.lanes["object_profile"].op = _Fut()
check("fill: on a machine with more than 32 logical CPUs it stops at the 32 units a report may list "
      "(cilex-vision refuses a longer `holding`, and then gives no claims)",
      _s3._room(0.0, "object_profile", adding=True)[0] == "ceiling"
      and LN.REPORT_HOLDING_MAX == 32, str(_s3._room(0.0, "object_profile", adding=True)))
_s3._leases[("object_profile", "c", "h")] = (0.0, -5.0)
check("fill: a unit whose lease had run out when its claim came back counts as past its lease",
      _s3._lease_used(W.ScanUnit("c", "h", "object_profile", None, 1), 1.0) == float("inf"))

class _M:
    def __init__(self): self.i = 0
    def __call__(self):
        self.i += 1                   # 4 CPUs; each call 10 CPU-s pass, 3 of them busy
        return __import__("vitals")._Machine(4, 8 * 2**30, 6 * 2**30, 3.0 * self.i, 10.0 * self.i)
class _Pids:
    def unit_pids(self): return [("object_profile", 101), ("object_profile", 102), ("illumination", 103)]
_sizes = {101: 300 * 2**20, 102: 500 * 2**20, 103: 90 * 2**20}
_mp = LN.MachineProbe(_Pids(), machine=_M(), tree=lambda pid: __import__("vitals")._Tree(1.0, _sizes[pid]),
                      can_walk=True)
_before = _mp.idle_cores(0.0, 15.0)
for _t in range(0, 21):
    _mp.sample(float(_t))
check("MachineProbe: idle logical CPUs over the window come from the machine's own counters "
      "(3 of every 10 CPU-s busy on 4 CPUs = 2.8 idle), and nothing before a whole window",
      _before is None and abs(_mp.idle_cores(20.0, 15.0) - 2.8) < 1e-9 and _mp.free == 2 * 2**30,
      f"{_before} {_mp.idle_cores(20.0, 15.0)} {_mp.free}")
check("MachineProbe: a unit's size is the largest process tree one unit of that analyser has had",
      _mp.unit_bytes("object_profile") == 500 * 2**20 and _mp.unit_bytes("illumination") == 90 * 2**20,
      f"{_mp.unit_bytes('object_profile')} {_mp.unit_bytes('illumination')}")
_mp2 = LN.MachineProbe(_Pids(), machine=_M(), tree=lambda pid: None, can_walk=False)
_mp2.sample(0.0)
check("MachineProbe: without a way to walk process trees, a unit's size is unknown -- never guessed",
      _mp2.unit_bytes("object_profile") is None)
def _boom(*a): raise OSError("counters unavailable")
_mp3 = LN.MachineProbe(_Pids(), machine=_M(), tree=_boom, can_walk=True)
for _t in range(0, 21):
    _mp3.sample(float(_t))
_mp3._machine = _boom
_mp3.sample(21.0)
check("MachineProbe: a measurement that raises leaves that figure unknown (so fill adds none) and never "
      "stops the worker",
      _mp3.free is None and _mp3.idle_cores(21.0, 15.0) is None and _mp3.unit_bytes("object_profile") is None
      and "counters unavailable" in (_mp3.error or ""), f"{_mp3.free} {_mp3.error}")
_real = LN.MachineProbe(type("R", (), {"unit_pids": lambda self: []})())
_real.sample(0.0); _time.sleep(0.3); _real.sample(0.3)
_ri = _real.idle_cores(0.3, 0.3)
check("MachineProbe on THIS machine's real counters (vitals.py): logical CPUs, free memory and an idle "
      "figure between 0 and the CPU count",
      _real.cores == os.cpu_count() and (_real.free or 0) > 0 and _ri is not None and 0.0 <= _ri <= _real.cores,
      f"cores={_real.cores} free={_real.free} idle={_ri} error={_real.error}")
_env0 = os.environ.pop("WT_LABS_FILL", None)
_A = lambda f: type("A", (), {"fill": f})()
_fw = [RW2.fill_wanted(_A(True)), RW2.fill_wanted(_A(False))]
for _v in ("1", "true", "on", "0", "", "no"):
    os.environ["WT_LABS_FILL"] = _v; _fw.append(RW2.fill_wanted(_A(False)))
os.environ.pop("WT_LABS_FILL", None)
if _env0 is not None:
    os.environ["WT_LABS_FILL"] = _env0
check("run_worker: --fill or WT_LABS_FILL=1/true/on turns fill on; unset, 0, empty or no leave it off",
      _fw == [True, False, True, True, True, False, False, False], str(_fw))
# ---- 0.3.11: leases while units are IN FLIGHT (the office, 2026-09-30 09:23: 16 at once, three
# units ran past their 20-min lease and were thrown away; the 75 % rule acted only when a unit ENDED).
def _capped(cores=16, n_in_hand=16, lease=100.0):
    p = _FillProbe(cores=cores)
    s = LN.Scheduler(Fake(), lambda: [NamedPlug("object_profile")], runner=_FillRunner(), hb=HbRec(),
                     names=["object_profile"], control=ctl_seq({"paused": False}), executor=LN.SyncExecutor(),
                     fill=p)
    ls = [s.lanes["object_profile"]]
    for i in range(n_in_hand - 1):
        x = LN.Lane(f"object_profile+{i + 1}", analyzer="object_profile"); s.lanes[x.name] = x; ls.append(x)
    us = []
    for i, x in enumerate(ls):
        u = W.ScanUnit(f"cam-{i}", "2026-09-30T05:00:00Z", "object_profile", None, 1)
        x.unit, x.op, x.op_kind = u, _Fut(), "unit"
        s._leases[(u.analyzer, u.camera_id, u.hour_start)] = (0.0, lease)
        us.append(u)
    return s, ls, us
def _ended(s, lane, u, now, **timings):
    lane.op = None
    o = W.UnitOutcome(u); o.submitted = True; o.timings.update(timings)
    s._unit_done(lane, o, now)

del _said.lines[:]
_s, _ls, _us = _capped()
_ended(_s, _ls[5], _us[5], 101.0, fetch_s=72.4, decode_s=400.1, analyse_s=380.2, total_s=912.0)
check("fill 0.3.11: a unit that ends past 3/4 of its lease caps its analyser at floor(N x 3/4 / used) "
      "-- 16 at once at 101 % -> 11 -- and its own extra slot goes",
      _s._fill_cap.get("object_profile", [None])[0] == 11 and "object_profile+5" not in _s.lanes,
      f"cap={_s._fill_cap} lanes={len(_s.lanes)}")
check("...then nothing is added while the analyser has as many slots as its safe width, and an extra "
      "slot above it does not claim again (15 slots > 11)",
      _s._room(101.0, "object_profile", adding=True)[0] == "lease_cap"
      and _s._room(101.0, "object_profile", adding=False)[0] == "lease_cap",
      f"{_s._room(101.0, 'object_profile', adding=True)} {_s._room(101.0, 'object_profile', adding=False)}")
_pl = [x for x in _said.lines if x.startswith("labs: unit done: object_profile cam-5")]
check("...and every unit leaves one line with its phases, how many of its analyser were in hand, and "
      "how much of its lease it used (the server keeps no timings)",
      len(_pl) == 1 and "in 912 s (fetch 72 s, decode 400 s, analyse 380 s), 16 of it at once, 101% of its lease" in _pl[0],
      str(_pl))
check("...and the Labs screen's last unit keeps the phases too",
      (_s.hb.fields.get("last_unit") or {}).get("phases") == {"fetch_s": 72.4, "decode_s": 400.1, "analyse_s": 380.2},
      str((_s.hb.fields.get("last_unit") or {}).get("phases")))

_s2b, _ls2, _us2 = _capped()
_ended(_s2b, _ls2[3], _us2[3], 86.0)
_c1 = _s2b._fill_cap["object_profile"][0]
_ended(_s2b, _ls2[4], _us2[4], 120.0)
check("fill 0.3.11: a second overrun while capped keeps the smaller safe width "
      f"(16 at 86 % -> {_c1}, then 15 at 120 % -> 9)",
      _c1 == 13 and _s2b._fill_cap["object_profile"][0] == 9, str(_s2b._fill_cap))

_s3b, _ls3, _us3 = _capped()
_ended(_s3b, _ls3[5], _us3[5], 101.0)
_w = [_s3b._fill_cap_of("object_profile", t) for t in (150.0, 201.0, 301.0, 401.0, 501.0, 601.0)]
check("fill 0.3.11: each lease length with no overrun allows one more at once, and the cap goes at the "
      "machine's ceiling -- a slow climb back, not a refill to 16",
      _w == [11, 12, 13, 14, 15, None], str(_w))

_s4b, _ls4, _us4 = _capped(n_in_hand=4)
check("fill 0.3.11: while ANY unit in hand is past 3/4 of its lease, an extra slot whose unit ended does "
      "not claim again (the width falls at once, and the late units get the rest) -- before that, it does",
      _s4b._room(80.0, "object_profile", adding=False)[0] == "lease"
      and _s4b._room(50.0, "object_profile", adding=False)[0] is None and not _s4b._fill_cap,
      f"{_s4b._room(80.0, 'object_profile', adding=False)} {_s4b._room(50.0, 'object_profile', adding=False)}")

# ...and on real threads: one slow unit crossing 3/4 of its lease makes the fast extras give back
# their slots as they end, through the claim loop.
class _SlowOne(_FillRunner):
    def run(self, unit, plugin):
        self.secs = 1.2 if unit.camera_id.endswith("-0") else 0.05
        return super().run(unit, plugin)
del _said.lines[:]
_c5, _p5 = lane_world(["object_profile"], units_per=60, cls=lambda **k: _FillFake(lease_s=0.4, **k))
_r5 = _SlowOne()
_s5 = LN.Scheduler(_c5, lambda: _p5, runner=_r5, hb=HbRec(), names=["object_profile"],
                   control=ctl_seq({"paused": False}), executor=_TPE(max_workers=40),
                   timing=LN.Timing(**dict(_FT, fill_every_s=0.01)), fill=_FillProbe(cores=8))
_th5 = threading.Thread(target=_s5.run, daemon=True); _th5.start()
_time.sleep(0.9)
_s5.stop(); _th5.join(5)
_shrunk = [x for x in _said.lines if "gives back an extra unit slot" in x and "fewer at once until they end" in x]
check("...on real threads: the fast extras give back their slots through the claim loop while the slow "
      "unit is past 3/4 of its lease",
      len(_shrunk) >= 1, f"{len(_shrunk)} {[x for x in _said.lines if 'gives back' in x][:3]}")

_lanes_log.removeHandler(_said); _lanes_log.propagate = True

c, plugs = lane_world(["illumination", "foreground_mask"], units_per=2); clk = Clock(); timed(c, clk)
c.refuse = {("claim", "illumination"): [R(409, "labs_lane_not_running", True)]}
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}))
s.run(until=lambda: clk.t >= 10)
check("lanes: a lane the server says is not running waits by itself; the other claims and finishes its units",
      len(claims_of(c, "illumination")) == 1 and done_by(c, "foreground_mask") == 2
      and s.lanes["illumination"].state == "not_running", f"{c.times} {s.lanes['illumination'].state}")

c, plugs = lane_world(["illumination", "foreground_mask"], units_per=2); clk = Clock(); timed(c, clk)
c.refuse = {("claim", "illumination"): [R(409, "a_slug_nobody_knows", False)]}
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}))
s.run(until=lambda: clk.t >= 30)
check("lanes: a refusal nobody expected stops THAT lane (never guessed at), not the station",
      len(claims_of(c, "illumination")) == 1 and done_by(c, "foreground_mask") == 2
      and not any(e.get("state") == "fatal" for e in hb.log) and "a_slug_nobody_knows" in s.lanes["illumination"].note,
      f"{c.times} {s.lanes['illumination'].note}")

c, plugs = lane_world(["illumination", "foreground_mask"], units_per=2); clk = Clock(); timed(c, clk)
c.refuse = {("claim", "illumination"): [R(503, "object_storage_unavailable", True)] * 10}
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}))
s.run(until=lambda: clk.t >= 125)
_ill = claims_of(c, "illumination")
_gaps = [round(b - x) for x, b in zip(_ill, _ill[1:])]
check("lanes: a claim refused 'retry later' is asked again by its lane alone, after 2, 4, 8, 16 and 32 s, then "
      "a minute -- and the slot goes to the others meanwhile",
      _gaps[:6] == [2, 4, 8, 16, 32, 60] and done_by(c, "foreground_mask") == 2
      and all(t < 1 for t in claims_of(c, "foreground_mask")[:2]), f"gaps={_gaps} {c.times[:6]}")

class _StallIllumination(LN.InProcessRunner):
    def run(self, unit, plugin):
        if unit.analyzer == "illumination":
            o = W.UnitOutcome(unit, note="it made no progress for 600 s"); o.stalled = True
            return o
        return super().run(unit, plugin)
c, plugs = lane_world(["illumination", "foreground_mask"], units_per=3); clk = Clock(); timed(c, clk)
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}),
              runner=_StallIllumination(c, decode=decode_chroma(11.5), tmpdir=TMP, sleep=lambda s: None))
tot = s.run(until=lambda: clk.t >= T.rest_s + 5)
_ill = claims_of(c, "illumination")
check("lanes: a unit that stopped making progress is dropped and ITS lane rests (rest_s); the other lane finishes",
      len(_ill) >= 2 and _ill[1] - _ill[0] >= T.rest_s and done_by(c, "foreground_mask") == 3
      and tot["abandoned"] >= 1, f"illumination at {_ill} {tot}")
class _StallFiled(LN.InProcessRunner):
    def run(self, unit, plugin):
        if unit.analyzer == "illumination":
            o = W.UnitOutcome(unit, note="stalled: no checkpoint for 10 min, its process was killed")
            o.stalled = o.submitted = o.filed_failed = True
            return o
        return super().run(unit, plugin)
c, plugs = lane_world(["illumination", "foreground_mask"], units_per=2); clk = Clock(); timed(c, clk)
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}),
              runner=_StallFiled(c, decode=decode_chroma(11.5), tmpdir=TMP, sleep=lambda s: None))
tot = s.run(until=lambda: clk.t >= 30)
check("...and one filed failed for it counts as FAILED, and its lane rests just the same",
      tot["failed"] == 1 and s.lanes["illumination"].state == "rest" and len(claims_of(c, "illumination")) == 1,
      f"{tot} {s.lanes['illumination'].state}")

c, plugs = loop_world(["illumination"], units_per=2); clk = Clock()
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}))
tot = s.run(until=lambda: clk.t >= 5)
check("lanes: a claim that returns more units than asked runs them all -- they are this station's already",
      tot["claimed"] == 2 and tot["done"] == 2 and len(c.submitted) == 2, str(tot))

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

# ================================================================ the Labs CONTROL PLANE
# cilex-vision, deployed 2026-09-28 (CONTRACT.md, "Station side"): the worker reports itself
# every ~2 s and takes its orders -- station and lane modes, units taken back -- from the
# reply. Operator decisions the same night: the SERVER is the switch once it answers (the
# local `paused` flag no longer governs), and the wall's safety check can HOLD Labs off on
# its computer, reported with its reason.
import reporter as RPT, vitals as VT

# ---- the changed refusals ---------------------------------------------------------------
check("claim refusals of the control plane map to their own actions, never FATAL",
      W.action_for(R(409, "labs_lane_not_running", True)) is W.Action.NOT_RUNNING
      and W.action_for(R(409, "labs_worker_not_reporting")) is W.Action.NOT_REPORTING
      and W.action_for(R(503, "labs_busy", True)) is W.Action.SERVER_BUSY
      and W.action_for(R(409, "scan_unit_revoked", False)) is W.Action.REVOKED)
_rf = W._refusal_from(503, b'{"detail": "The claim took too long", "code": "labs_busy", "retryable": true}')
check("a coded error whose `detail` is a sentence is read by its `code` (cilex-vision's CodedError)",
      _rf.detail == "labs_busy" and W.action_for(_rf) is W.Action.SERVER_BUSY, str(_rf))

class _NullQueue(W.HttpLabsClient):
    def _req(self, method, path, body=None, raw_to=None):
        return {"units": [{"camera_id": "c", "hour_start": "2026-09-28T01:00:00+00:00", "analyzer": "a"}],
                "queue_remaining": None}
try:
    _us, _qr = _NullQueue("http://x", "tok").claim("a", 1); _ok = True
except Exception as e:
    _us, _qr, _ok = [], "?", e
check("queue_remaining: null no longer crashes a claim (it did: int(None))",
      _ok is True and len(_us) == 1 and _qr is None, f"{_ok} {_qr}")

def _claim_refused(r):
    u = unit(a="illumination")
    c = Fake(units={"illumination": [u]}, segs={(u.camera_id, u.hour_start): [seg(1)]},
             refuse={("claim", "illumination"): [r, r, r, r, r, r, r]})
    rep = W.run_once(c, [B1], decode=decode_chroma(11.5), states={}, sleep=lambda s: None)
    return c, rep
c, rep = _claim_refused(R(409, "labs_lane_not_running", True))
check("claim: a lane that is not running is SKIPPED this pass (not fatal, not retried in place)",
      rep.not_running == ["illumination"] and not rep.fatal and not rep.unreachable and c.claims == ["illumination"],
      f"{rep.not_running} {rep.fatal} {c.claims}")
c, rep = _claim_refused(R(503, "labs_busy", True))
check("claim: labs_busy ends the pass for a minute as BUSY, not 'unreachable' -- asked ONCE, never re-asked in place",
      rep.busy and "busy" in rep.busy and not rep.unreachable and not rep.fatal and c.claims == ["illumination"],
      f"busy={rep.busy} unreachable={rep.unreachable} {c.claims}")
c, rep = _claim_refused(R(409, "labs_worker_not_reporting"))
check("claim: 'not reporting' is said as such (report, then retry soon), not as a fault",
      rep.not_reporting and not rep.fatal and c.claims == ["illumination"], f"{rep.not_reporting} {rep.fatal}")

# ---- a unit TAKEN BACK while it runs: dropped, nothing submitted, nothing filed ------------
class _Counting(Nothing):
    got = 0
    def analyse(self, segs, st, u, ctx):
        for _s, _f in segs:
            type(self).got += 1                # frames HANDED OVER to the analyser
        return []
_seen = {"n": 0}
def _decode_then_revoke(path, kf, want_chroma, **k):
    _seen["n"] += 1
    return decode_chroma(11.5)(path, kf, want_chroma)
u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(i) for i in range(4)]})
o = W.run_unit(c, _Counting(), u, decode=_decode_then_revoke, states={}, tmpdir=TMP, sleep=lambda s: None,
               abort_check=lambda: "taken back by the server" if _seen["n"] >= 1 else None)
check("frame path: a unit taken back mid-hour is DROPPED -- nothing submitted, not filed as failed",
      not o.submitted and not c.submitted and o.action is W.Action.REVOKED and _seen["n"] == 1,
      f"{o.action} {c.submitted} decoded={_seen['n']}")
check("...and the frames decoded after the Stop are never handed to the analyser",
      _Counting.got == 0, f"handed over: {_Counting.got}")
check("...and it leaves no temp file behind", leftovers() == [], str(leftovers()))

class _RawKilled:
    name = "frame_difference"; version = "t"; segment_limit = 4; keyframes_only = True
    want_chroma = False; stateful = False; wants_raw = True
    def new_state(self): return None
    def analyse_raw(self, chunks, segs, unit):
        list(chunks)
        raise RuntimeError("ffmpeg: killed")   # what a decoder killed under it looks like
u = unit(a="frame_difference"); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]})
_rev = {"on": False}
class _RawKilledLate(_RawKilled):
    def analyse_raw(self, chunks, segs, unit):
        list(chunks); _rev["on"] = True        # the Stop lands while its decoder runs
        raise RuntimeError("ffmpeg: killed")
o = W.run_unit(c, _RawKilledLate(), u, decode=lambda *a: [], states={}, tmpdir=TMP, sleep=lambda s: None,
               abort_check=lambda: "taken back by the server" if _rev["on"] else None)
check("raw path: the decoder a Stop killed is NOT filed as the footage's failure (no attempt spent)",
      not c.submitted and o.action is W.Action.REVOKED and "not filed" in o.note, f"{c.submitted} {o.action} {o.note}")

u = unit(); c = Fake(segs={(u.camera_id, u.hour_start): [seg(1)]},
                     refuse={("submit", u.camera_id): [R(409, "scan_unit_revoked", False)] * 5})
_n_sub = {"n": 0}
_orig_submit = c.submit
def _count_submit(uu, body):
    _n_sub["n"] += 1; return _orig_submit(uu, body)
c.submit = _count_submit
o = run(c, Nothing(), u)
check("submit refused 409 scan_unit_revoked: dropped, NOT retried, not filed as failed",
      not o.submitted and o.action is W.Action.REVOKED and _n_sub["n"] == 1, f"{o.action} submits={_n_sub['n']}")

# THE RACE THE SECOND LIVE TEST FOUND (cilex-vision, 2026-09-28 22:52 MSK): the report reply
# named the unit revoked (22:52:39.014) while a segment fetch was already in flight, and that
# fetch came back 403 segment_outside_lease (22:52:40.127). The unit was recorded "abandoned".
# A lease-lost refusal the station ALREADY knows the reason for is recorded as what happened.
_race = {"on": False, "seg": None, "err": None}
def _race_abort():
    return "taken back by the server" if _race["on"] else None
class _RaceFake(Fake):
    """The revocation arrives WHILE a call is in flight; then the call is refused."""
    def fetch(self, s, dest):
        if s.segment_id == _race["seg"]:
            self.fetched.append(s.segment_id); _race["on"] = True
            raise _race["err"]
        return super().fetch(s, dest)
    def segments(self, u, limit, stream_type, window=None, window_at=None):
        if _race["seg"] == "LIST":
            _race["on"] = True; raise _race["err"]
        return super().segments(u, limit, stream_type, window, window_at)
    def submit(self, u, body):
        if _race["seg"] == "SUBMIT":
            _race["on"] = True; raise _race["err"]
        return super().submit(u, body)
def _race_run(plug, where, err, abort=_race_abort, a="illumination"):
    u = unit(a=a); c = _RaceFake(segs={(u.camera_id, u.hour_start): [seg(1), seg(2)]})
    _race.update(on=False, seg=where, err=err)
    return run(c, plug, u, decode=decode_chroma(11.5), sleep=lambda s: None, abort_check=abort), c

o, c = _race_run(B1, "seg-2", R(403, "segment_outside_lease", True))
check("race: a fetch refused 403 AFTER the report named the unit revoked is recorded REVOKED, not abandoned",
      o.action is W.Action.REVOKED and not c.submitted and "segment_outside_lease" in (o.note or "")
      and "taken back" in (o.note or ""), f"{o.action} {o.note}")
o, c = _race_run(B1, "seg-2", R(403, "segment_outside_lease", True), abort=lambda: None)
check("control: the same 403 with no revocation known stays a LOST LEASE (reclaim)",
      o.action is W.Action.RECLAIM, f"{o.action} {o.note}")
o, c = _race_run(B1, "seg-2", R(401, "station_token_not_recognised", False))
check("...but a station fault stays FATAL even when a revocation is known",
      o.action is W.Action.FATAL, f"{o.action}")
o, c = _race_run(B1, "LIST", R(409, "scan_unit_not_open", True))
check("race on the segment LIST: revoked when the station already knows",
      o.action is W.Action.REVOKED and not c.submitted, f"{o.action} {o.note}")
o, c = _race_run(B1, "LIST", R(409, "scan_unit_not_open", True), abort=lambda: None)
check("control: the first live test's case -- revoked before the station knew it held the unit -- stays reclaim",
      o.action is W.Action.RECLAIM, f"{o.action}")
o, c = _race_run(_RawKilled(), "seg-2", R(403, "segment_outside_lease", True), a="frame_difference")
check("race on the RAW path's fetch: revoked, nothing submitted",
      o.action is W.Action.REVOKED and not c.submitted, f"{o.action} {o.note}")
class _PerSeg:
    name = "optical_flow"; version = "t"; segment_limit = 4; keyframes_only = False
    want_chroma = False; stateful = False; wants_raw_per_segment = True
    def new_state(self): return None
    def analyse_raw_segments(self, fetched, unit): return []
o, c = _race_run(_PerSeg(), "seg-2", R(403, "segment_outside_lease", True), a="optical_flow")
check("race on the PER-SEGMENT raw path's fetch: revoked, nothing submitted",
      o.action is W.Action.REVOKED and not c.submitted, f"{o.action} {o.note}")
o, c = _race_run(B1, "SUBMIT", R(404, "scan_unit_not_claimed", True))
check("race on SUBMIT: a lease-lost refusal after the report named the unit is revoked",
      o.action is W.Action.REVOKED, f"{o.action} {o.note}")

# The kill a Stop makes is COUNTED in the log: the second live test could not tell whether
# a decoder had been running, because this count went unlogged.
_logged = []
class _Log:
    def warning(self, fmt, *a): _logged.append(fmt % a)
_n = RW2.stop_decoders(unit(), "taken back", kill=lambda: 2, log=_Log())
check("a Stop's kill SAYS how many decoder processes it stopped",
      _n == 2 and "2 decoder process(es) stopped for illumination cam-a" in _logged[-1], str(_logged[-1:]))
RW2.stop_decoders(unit(), "taken back", kill=lambda: None, log=_Log())
check("...and says so when this station cannot count them (Windows without psutil)",
      "unknown number" in _logged[-1], str(_logged[-1:]))

# A STATION THAT CANNOT START ITS DECODER (worker-0.3.3). On the office, 2026-09-29 02:14-02:25
# MSK, every ffmpeg exited 3221225794 after the console host was killed, and ~25 units were
# filed failed as the footage's fault (Windows agent). Now: the cause is named, the unit is
# filed under it, the pass ends, and the loop claims nothing until the decoder starts again.
class _Rc:
    def __init__(self, rc): self.returncode = rc
_f = RW2.decoder_start_fault(exe="ffmpeg", run=lambda *a, **k: _Rc(3221225794))
check("decoder check: the office's exit 3221225794 is named -- 0xC0000142 STATUS_DLL_INIT_FAILED",
      bool(_f) and "0xC0000142 STATUS_DLL_INIT_FAILED" in _f, str(_f))
def _nf(*a, **k): raise FileNotFoundError("nope")
check("decoder check: a missing decoder is 'not installed'",
      "not installed" in (RW2.decoder_start_fault(exe="nope", run=_nf) or ""))
check("decoder check: a decoder that starts is fine (None)",
      RW2.decoder_start_fault(exe="ffmpeg", run=lambda *a, **k: _Rc(0)) is None)
_real = RW2.decoder_start_fault()
if _real is not None and "not installed" in _real:
    print(f"SKIP decoder check on this station: {_real}")
else:
    check("decoder check on THIS station: its decoder starts", _real is None, str(_real))

_FAULT = "the decoder could not start (ffmpeg): exit 3221225794 = 0xC0000142 STATUS_DLL_INIT_FAILED"
def _no_start(*a, **k): raise RuntimeError("ffmpeg exited 3221225794 and decoded no frames")
_old_sc = W.STATION_CHECK
W.STATION_CHECK = lambda: _FAULT
try:
    _u1, _u2 = unit(cam="cam-x"), unit(cam="cam-y", a="blob_geometry")
    c = Fake(units={"illumination": [_u1], "blob_geometry": [_u2]},
             segs={(_u1.camera_id, _u1.hour_start): [seg(1)], (_u2.camera_id, _u2.hour_start): [seg(1)]})
    rep = W.run_once(c, [B1, NamedPlug("blob_geometry")], decode=_no_start, states={}, sleep=lambda s: None, claim_limit=1)
    _body = c.submitted[0][1] if c.submitted else {}
    check("station fault: the unit is filed under THE STATION's cause, not the footage's",
          _body.get("failed") and str(_body.get("error", "")).startswith("station_fault:")
          and "0xC0000142" in _body.get("error", ""), str(_body)[:220])
    check("station fault: the pass ENDS as fatal -- the next analyser is not claimed",
          rep.fatal and "cannot start its decoder" in rep.fatal and c.claims == ["illumination"],
          f"fatal={rep.fatal!r} claims={c.claims}")
finally:
    W.STATION_CHECK = _old_sc
c = Fake(units={"illumination": [unit()]}, segs={(unit().camera_id, unit().hour_start): [seg(1)]})
rep = W.run_once(c, [B1], decode=_no_start, states={}, sleep=lambda s: None, claim_limit=1)
_body = c.submitted[0][1] if c.submitted else {}
check("control: with no station check (or a station that starts its decoder) the failure is the unit's own",
      _body.get("failed") and not str(_body.get("error", "")).startswith("station_fault:") and not rep.fatal,
      str(_body)[:160])

c, plugs = loop_world(["illumination", "foreground_mask"]); clk = Clock()
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}), station_check=lambda: _FAULT)
s.run(until=lambda: clk.t >= T.fatal_s - 1)
check("lanes: a station that cannot start its decoder claims NOTHING on ANY lane, says why, and waits the fatal pause",
      c.claims == [] and hb.fields.get("state") == "fatal" and "0xC0000142" in (hb.fields.get("note") or ""),
      f"{c.claims} {hb.fields.get('state')} t={clk.t}")
_fixed = {"n": 0}
def _fixed_later():
    _fixed["n"] += 1
    return _FAULT if _fixed["n"] == 1 else None
c, plugs = loop_world(["illumination"]); clk = Clock(); timed(c, clk)
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}), station_check=_fixed_later)
s.run(until=lambda: clk.t >= T.fatal_s + 5)
check("...and asks again after the pause: once the decoder starts, the lanes claim",
      c.times and all(t >= T.fatal_s for t, _a in c.times) and done_by(c, "illumination") == 1, str(c.times))
c, plugs = loop_world(["illumination"]); clk = Clock()
s, hb = sched(c, plugs, clk, ctl_seq({"paused": False}), station_check=lambda: None)
s.run(until=lambda: clk.t >= 5)
check("control: a station whose decoder starts claims as before", c.claims[:1] == ["illumination"], str(c.claims))

# ---- the reporter --------------------------------------------------------------------------
class _RepClient:
    def __init__(self, replies): self.replies, self.bodies = list(replies), []
    def report(self, body):
        self.bodies.append(body)
        r = self.replies.pop(0) if len(self.replies) > 1 else self.replies[0]
        if isinstance(r, Exception): raise r
        return r
class _Vit:
    def sample(self): return {"cores": 4, "mem_total_bytes": 8, "mem_used_bytes": 2,
                              "cpu_pct": 12.5, "labs_cpu_pct": None, "labs_rss_bytes": 7}
_ctl_box = {"c": {"paused": True, "camera_health": False, "why": "", "hold": None}}
_t = {"now": 0.0}
_aborts, _changes = [], []
def _mk(replies):
    return RPT.Reporter(_RepClient(replies), vitals=_Vit(), worker_version="worker-0.3",
                        control=lambda: _ctl_box["c"], clock=lambda: _t["now"],
                        on_abort=lambda un, why: _aborts.append(why), on_change=_changes.append)
_ORD = {"generated_at": "2026-09-28T09:00:00Z", "report_every_s": 2,
        "station": {"mode": "running", "level": None, "at": "2026-09-28T09:00:00Z"},
        "lanes": {"illumination": "running", "blob_geometry": "paused"}, "revoked": []}

rp = _mk([R(404, "Not Found", None)])
rp.tick(); rp.report_once()
check("reporter: a server WITHOUT the endpoint (404) is not governing; the local file still decides",
      rp.governed() is False and rp.station_mode() is None and rp._next == RPT.LEGACY_PROBE_S,
      f"{rp.governed()} next={rp._next}")

rp = _mk([_ORD]); rp.tick(); rp.report_once()
check("reporter: once the server answers, it governs -- station and lane modes come from its reply",
      rp.governed() and rp.station_mode() == "running" and rp.lane_mode("illumination") == "running"
      and rp.lane_mode("blob_geometry") == "paused" and rp.lane_mode("track_linking") is None)
_b = rp.client.bodies[-1]
check("reporter: the body carries the contract's fields, vitals included, null where unmeasured",
      _b["worker_version"] == "worker-0.3" and _b["state"] == "idle" and _b["slots"] is None and _b["holding"] == []
      and _b["cpu_pct"] == 12.5 and _b["labs_cpu_pct"] is None and "hold" not in _b, str(_b))
_t["now"] = 31.0
check("reporter: orders older than 30 s are UNKNOWN -- and unknown claims nothing new",
      rp.station_mode() is None and rp.lane_mode("illumination") is None and rp.governed())
_t["now"] = 0.0

_u = W.ScanUnit("cam-9", "2026-09-28T01:00:00.000+00:00", "illumination", None, 1)
rp = _mk([_ORD, dict(_ORD, revoked=[{"analyzer": "illumination", "camera_id": "cam-9",
                                     "hour_start": "2026-09-28T01:00:00Z"}])])
rp.set_holding(_u); rp.report_once()
_b = rp.client.bodies[-1]
check("reporter: while a unit is in hand the state is 'running' and the unit is listed, hour with its offset",
      _b["state"] == "running" and _b["holding"] == [{"analyzer": "illumination", "camera_id": "cam-9",
                                                    "hour_start": "2026-09-28T01:00:00.000+00:00"}], str(_b))
_aborts.clear(); rp.report_once(); rp.report_once()
check("reporter: a unit the server takes back is dropped ONCE (its decoders killed), however the hour is spelled",
      rp.abort_reason(_u) and len(_aborts) == 1, f"{rp.abort_reason(_u)} aborts={_aborts}")
rp.set_holding(None)

_ctl_box["c"] = dict(_ctl_box["c"], hold={"by": "wall-guard", "why": "dark tiles for 4 s", "at": "2026-09-28T09:01:00Z"})
rp = _mk([_ORD]); _aborts.clear()
rp.set_holding(_u); rp.tick()
check("reporter: a local HOLD drops the unit in hand at once, with its reason",
      rp.abort_reason(_u) == "held on this station: dark tiles for 4 s" and _aborts == ["held on this station: dark tiles for 4 s"],
      f"{rp.abort_reason(_u)} {_aborts}")
rp.report_once(); _b = rp.client.bodies[-1]
check("reporter: a held station reports 'paused' AND the hold -- never a hidden switch",
      _b["state"] == "paused" and _b.get("hold", {}).get("why") == "dark tiles for 4 s", str(_b))
_ctl_box["c"] = dict(_ctl_box["c"], hold=None)

rp = _mk([_ORD]); _changes.clear()
_real_now_iso, _ticks = RPT.S.now_iso, iter(range(100))
RPT.S.now_iso = lambda: f"2026-09-28T09:00:{next(_ticks):02d}Z"   # every report a new time
try:
    for _i in range(5):
        _t["now"] = _i * 2.0; rp.report_once(); rp.tick()
finally:
    RPT.S.now_iso = _real_now_iso
_t["now"] = 0.0
check("reporter: the status file is told when what it says CHANGES, not on every 2-s report",
      len(_changes) == 1 and _changes[0]["governed"] and _changes[0]["server_mode"] == "running", str(len(_changes)))

# ---- one holding list for every lane's units (worker-0.3.5) -----------------------------------
_ua = W.ScanUnit("cam-9", "2026-09-28T01:00:00.000+00:00", "illumination", None, 1)
_ub = W.ScanUnit("cam-7", "2026-09-28T02:00:00.000+00:00", "audio_energy", None, 1)
_dropped = []
rp = RPT.Reporter(_RepClient([_ORD, dict(_ORD, revoked=[{"analyzer": "illumination", "camera_id": "cam-9",
                                                         "hour_start": "2026-09-28T01:00:00Z"}])]),
                  vitals=_Vit(), worker_version="worker-0.3.5", control=lambda: _ctl_box["c"],
                  clock=lambda: _t["now"], on_abort=lambda un, why: _dropped.append((un.analyzer, why)))
rp.add_holding(_ua); rp.add_holding(_ub); rp.report_once()
_b = rp.client.bodies[-1]
check("reporter: ONE holding list covers every lane's units in hand; `slots` is null (no station-wide cap)",
      _b["state"] == "running" and _b["slots"] is None
      and sorted(h["analyzer"] for h in _b["holding"]) == ["audio_energy", "illumination"], str(_b))
rp.report_once(); rp.report_once()
check("reporter: a unit taken back is dropped ONCE, and ONLY that one -- the other lane's unit keeps running",
      [a for a, _w in _dropped] == ["illumination"] and rp.abort_reason(_ua) and rp.abort_reason(_ub) is None,
      str(_dropped))
rp.remove_holding(_ua); rp.report_once()
check("reporter: a unit handed back leaves the list; the others stay",
      [h["analyzer"] for h in rp.client.bodies[-1]["holding"]] == ["audio_energy"], str(rp.client.bodies[-1]["holding"]))
_ctl_box["c"] = dict(_ctl_box["c"], hold={"by": "wall-guard", "why": "dark tiles for 4 s", "at": "2026-09-28T09:01:00Z"})
_dropped.clear(); rp.add_holding(_ua); rp.tick(); rp.tick()
check("reporter: a local HOLD drops EVERY unit in hand, each once",
      sorted(a for a, _w in _dropped) == ["audio_energy", "illumination"], str(_dropped))
_ctl_box["c"] = dict(_ctl_box["c"], hold=None)

# ---- the lanes, governed ------------------------------------------------------------------------
class _Gov:
    def __init__(self, mode, lanes, level=None, at="2026-09-28T09:00:00Z"):
        self.mode, self.lanes, self.level, self.at = mode, lanes, level, at
        self.kicks, self.states, self.events = 0, [], []
    def governed(self): return True
    def station(self): return None if self.mode is None else {"mode": self.mode, "level": self.level, "at": self.at}
    def lane_mode(self, n): return self.lanes.get(n)
    def set_state(self, s): self.states.append(s)
    def add_holding(self, u): self.events.append(("in hand", u.analyzer))
    def remove_holding(self, u): self.events.append(("handed back", u.analyzer))
    def abort_reason(self, u): return None
    def kick(self): self.kicks += 1
    def snapshot(self): return {"lanes": dict(self.lanes)}
_LOCAL_PAUSED = {"paused": True, "camera_health": False, "why": "paused", "hold": None}
_LOCAL_RUN = {"paused": False, "camera_health": False, "why": "", "hold": None}

c, plugs = loop_world(["illumination", "blob_geometry"])
g = _Gov("running", {"illumination": "running", "blob_geometry": "paused"})
clk = Clock()
s, hb = sched(c, plugs, clk, lambda: _LOCAL_PAUSED, reporter=g)
s.run(until=lambda: clk.t >= 10)
check("governed: the SERVER decides -- a local `paused` flag no longer stops claims (operator decision)",
      c.claims[:1] == ["illumination"], str(c.claims))
check("governed: only lanes whose mode is `running` are claimed", "blob_geometry" not in c.claims, str(c.claims))
check("governed: the unit in hand is announced to the reporter and handed back, and a report follows each unit",
      g.events == [("in hand", "illumination"), ("handed back", "illumination")] and g.kicks >= 1,
      f"{g.events} kicks={g.kicks}")

# ---- a lane whose rest has run out must not make the loop spin (worker-0.3.9) ----------------
# The Windows agent, 2026-09-30: the booth's HELD worker-0.3.8 used 9.58 CPU-s in 10 s (96 % of a
# core) doing nothing. _next_wait counted a lane whose rest had already run out as a wait of 0, and
# nothing claims it while the station is held or the server has the lane stopped -- so run() spun.
# On the fake clock a zero wait advances 1 ms, so a spin shows as thousands of ticks.
_n_ctl = [0]
def _ctl_paused_count():
    _n_ctl[0] += 1
    return {"paused": True, "camera_health": False, "why": "paused", "hold": None}
c, plugs = loop_world(["illumination", "foreground_mask"]); clk = Clock()
s, hb = sched(c, plugs, clk, _ctl_paused_count)
s.lanes["illumination"].until = clk.t - 1.0          # a rest that has already run out
s.run(until=lambda: clk.t >= 20)
check("lanes: a PAUSED or HELD station with a lane whose rest has run out WAITS between ticks, it does not spin "
      "(the booth's held 0.3.8 worker used 96 % of a core)",
      _n_ctl[0] <= 20 / T.legacy_poll_s + 2 and c.claims == [], f"ticks in 20 s: {_n_ctl[0]}, claims {c.claims}")
_n_ctl2 = [0]
def _ctl_run_count():
    _n_ctl2[0] += 1
    return _LOCAL_RUN
c, plugs = loop_world(["illumination", "blob_geometry"])
g = _Gov("running", {"illumination": "running", "blob_geometry": "paused"})
clk = Clock()
s, hb = sched(c, plugs, clk, _ctl_run_count, reporter=g)
s.lanes["blob_geometry"].until = clk.t - 1.0         # rested once, and now the server has it stopped
s.run(until=lambda: clk.t >= 20)
check("lanes: RUNNING, a lane the server has stopped whose rest has run out does not make the loop spin either "
      "-- one tick a poll, and the running lane still works",
      _n_ctl2[0] <= 20 / T.poll_s + 10 and "illumination" in c.claims and "blob_geometry" not in c.claims,
      f"ticks in 20 s: {_n_ctl2[0]}, claims {c.claims}")

for _mode, _level, _at, _word, _says in (("paused", "station", "2026-09-28T09:05:00Z", "paused", "this workstation, since 2026-09-28T09:05:00Z"),
                                         ("stopped", None, None, "stopped_by_server", "never started"),
                                         (None, None, None, "waiting", "no fresh orders")):
    c, plugs = loop_world(["illumination"])
    g = _Gov(_mode, {"illumination": "running"}, level=_level, at=_at)
    clk = Clock()
    s, hb = sched(c, plugs, clk, lambda: _LOCAL_RUN, reporter=g)
    s.run(until=lambda: clk.t >= 10)
    check(f"governed, station mode {_mode}: claims nothing, and the status says so ('{_says}')",
          c.claims == [] and hb.fields.get("state") == _word and _says in (hb.fields.get("note") or ""),
          f"{c.claims} {hb.fields.get('state')} {hb.fields.get('note')}")

_HELD = dict(_LOCAL_RUN, hold={"by": "wall-guard", "why": "stall 3 s", "at": ""})
for _g in (_Gov("running", {"illumination": "running"}), None):
    c, plugs = loop_world(["illumination"])
    clk = Clock()
    s, hb = sched(c, plugs, clk, lambda: _HELD, reporter=_g)
    s.run(until=lambda: clk.t >= 10)
    check(f"a local HOLD beats {'a server Start' if _g else 'the local flag'}: nothing claimed, the reason shown",
          c.claims == [] and hb.fields.get("state") == "held" and "stall 3 s" in (hb.fields.get("note") or ""),
          f"{c.claims} {hb.fields.get('state')} {hb.fields.get('note')}")

c, plugs = loop_world(["camera_health", "illumination"])
g = _Gov("running", {"camera_health": "running", "illumination": "running"})
clk = Clock()
s, hb = sched(c, plugs, clk, lambda: _LOCAL_RUN, reporter=g)
s.run(until=lambda: clk.t >= 10)
check("governed: camera_health still needs THIS station's opt-in (one station only; the server does not enforce it)",
      "camera_health" not in c.claims and "illumination" in c.claims, str(c.claims))

# A NEW REASON NOT TO CLAIM IS SHOWN AT ONCE. Measured on the pilot at the 2026-09-28
# deploy: the server governed and said "stopped", while the status file -- and the reports
# -- still said the old local "paused" for up to RECHECK_S (15 min).
class _Flip(_Gov):
    """Not governed until the clock reaches `at_s` (the deploy); then stopped by the server."""
    def __init__(self, clk, at_s):
        super().__init__("stopped", {"illumination": "stopped"}, level="station", at="2026-09-28T05:46:57Z")
        self.clk, self.at_s = clk, at_s
    def governed(self): return self.clk.t >= self.at_s
class _HbT(HbRec):
    def __init__(self, clk): super().__init__(); self.clk = clk; self.when = []
    def update(self, **kw):
        super().update(**kw)
        if "state" in kw: self.when.append((self.clk.t, kw["state"]))
c, plugs = loop_world(["illumination"])
clk = Clock(); g = _Flip(clk, 10.0); hb = _HbT(clk)
s, _hb = sched(c, plugs, clk, lambda: _LOCAL_PAUSED, reporter=g, hb=hb)
s.run(until=lambda: clk.t >= 20)
_first = next((t for t, w in hb.when if w == "stopped_by_server"), None)
check("paused locally, then the server governs with 'stopped': the status says so within one tick, not 15 min later",
      c.claims == [] and _first is not None and _first < 10.0 + T.legacy_poll_s + T.poll_s
      and "stopped" in g.states[g.states.index("paused"):], f"{hb.when} {g.states[:3]}")
c, plugs = loop_world(["illumination"])
clk = Clock(); hb = _HbT(clk)
s, _hb = sched(c, plugs, clk, lambda: _LOCAL_PAUSED, hb=hb)
s.run(until=lambda: clk.t >= 2 * RW2.RECHECK_S)
check("control: an UNCHANGED reason writes the status once -- no churn while nothing changes",
      [w for _, w in hb.when] == ["paused"], str(hb.when))

# UNPLUG IS GENTLE (cilex-vision's v17 semantics, 5aefa39, 2026-09-28): when an admin unplugs a
# workstation x analyser "hose", the lane reads "stopped" but units in hand stay leased and are
# NOT listed in `revoked` -- the station finishes and submits them. Only a Stop revokes. The
# worker must drop nothing on a lane flip alone: lanes gate CLAIMS, never a unit in hand.
_cU, _plugsU = loop_world(["illumination"])
_gU = _Gov("running", {"illumination": "running"})
_dec = decode_chroma(11.5)
def _unplug_mid_unit(path, kf, want_chroma, **k):
    _gU.lanes["illumination"] = "stopped"      # the hose is unplugged while this unit decodes
    return _dec(path, kf, want_chroma)
_clkU = Clock()
_sU, _hbU = sched(_cU, _plugsU, _clkU, lambda: _LOCAL_RUN, reporter=_gU, decode=_unplug_mid_unit)
_tot = _sU.run(until=lambda: _clkU.t >= 10)
check("unplug mid-unit (lane -> stopped, nothing revoked): the unit in hand is FINISHED and submitted",
      len(_cU.submitted) == 1 and _tot.get("done") == 1 and _tot.get("abandoned", 0) == 0, f"{_cU.submitted} {_tot}")
_rf = W._refusal_from(409, b'{"detail": "labs_lane_not_running", "code": "labs_lane_not_running", '
                           b'"retryable": true, "mode": "stopped", "level": "lane", "never_started": false, '
                           b'"never_connected": true, "unplugged": false}')
check("v17's claim refusal with its two NEW keys (never_connected, unplugged) is still 'skip this lane'",
      W.action_for(_rf) is W.Action.NOT_RUNNING, str(_rf))

# An admin's Start on a lane must not wait out the idle pause: a change in the server's lane
# modes ends every idle lane's wait.
c, plugs = lane_world(["illumination", "foreground_mask"], units_per=0); clk = Clock(); timed(c, clk)
g = _Gov("running", {"illumination": "running", "foreground_mask": "paused"})
s, hb = sched(c, plugs, clk, lambda: _LOCAL_RUN, reporter=g)
s.run(until=lambda: clk.t >= 10)
g.lanes["foreground_mask"] = "running"
c.units["illumination"] = [W.ScanUnit("cam-late", "2026-09-26T08:00:00Z", "illumination", None, 1)]
c.segs[("cam-late", "2026-09-26T08:00:00Z")] = [seg(1)]
s.run(until=lambda: clk.t >= 20)
_ill = claims_of(c, "illumination")
check("governed: a change in the server's lane modes ends an idle lane's wait at once, not two minutes later",
      len(_ill) >= 2 and _ill[1] < 10 + T.poll_s + 1 and done_by(c, "illumination") == 1, str(c.times))

# ---- units in processes of their own (unit_proc.py, worker-0.3.5) -------------------------------
# Real processes: a unit's result comes back, a Stop kills ITS decoders and no other lane's,
# a unit that hangs is killed, one that dies is reported, and one whose worker is gone stops.
import textwrap as _tw, json as _json2
import unit_proc as UP
_CH = tempfile.mkdtemp(prefix="wt-child-")
_CH_OUT, _CH_PIDS = os.path.join(_CH, "submitted.jsonl"), os.path.join(_CH, "decoders.txt")
try:
    _FF = P.ffmpeg_exe()
except Exception:
    _FF = None
open(os.path.join(_CH, "labs_test_child.py"), "w", encoding="utf-8").write(_tw.dedent(f'''
    """Test doubles for unit processes (tools/tests/labs-worker.py). Written by the tests; not shipped."""
    import json, logging, os, subprocess, time
    import worker as W
    OUT, PIDS, FFMPEG = {_CH_OUT!r}, {_CH_PIDS!r}, {_FF!r}
    class FileClient:
        def segments(self, u, limit, stream_type, window=None, window_at=None):
            return [W.Segment(f"seg-{{i}}", f"http://x/labs/segments/seg-{{i}}", "2026-09-24T10:00:00+00:00",
                              "2026-09-24T10:00:30+00:00", 30.0, 100, "main", 64, 48, "h264") for i in range(2)]
        def fetch(self, s, dest):
            open(dest, "wb").write(b"x" * 100)
            return 100
        def submit(self, u, body):
            with open(OUT, "a", encoding="utf-8") as f:
                f.write(json.dumps({{"camera_id": u.camera_id, "failed": bool(body.get("failed")),
                                    "blas": os.environ.get("OPENBLAS_NUM_THREADS"), "pid": os.getpid()}}) + "\\n")
    def client(spec): return FileClient()
    def decode(path, kf, want_chroma, **k): return [None]
    class Plug:
        version = "t"; segment_limit = 2; keyframes_only = True; want_chroma = False; stateful = False
        def __init__(self, name): self.name = name
        def new_state(self): return None
        def analyse(self, stream, st, u, ctx):
            mode = u.camera_id.split("-")[0]
            if mode == "hang":
                time.sleep(60)      # bounded: a stall detector that failed must FAIL the check, not hang the suite
            if mode == "crash":
                os._exit(7)
            if mode == "slow":
                time.sleep(1.5)     # long enough to be seen running beside the others
            if mode == "warn":
                logging.getLogger("labs.test").warning("a warning from inside the unit process")
            if mode == "decoder":
                p = subprocess.Popen([FFMPEG, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc",
                                      "-f", "null", "-"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
                with open(PIDS, "a", encoding="utf-8") as f:
                    f.write(f"{{u.camera_id}} {{p.pid}}\\n")
                p.wait()
                raise RuntimeError(f"ffmpeg exited {{p.returncode}}")   # what a killed decoder looks like
            for _ in stream:
                pass
            return []
    def plugin(name): return Plug(name)
'''))
sys.path.insert(0, _CH)
_SPEC = {"client": "labs_test_child:client", "plugin": "labs_test_child:plugin", "decode": "labs_test_child:decode",
         "station_check": None}
def _rows():
    try:
        return [_json2.loads(x) for x in open(_CH_OUT, encoding="utf-8")]
    except FileNotFoundError:
        return []
def _pid_of(cam):
    try:
        for line in open(_CH_PIDS, encoding="utf-8"):
            k, v = line.split()
            if k == cam:
                return int(v)
    except FileNotFoundError:
        pass
    return None
def _alive(pid):
    if VT.psutil is not None:
        try:
            return VT.psutil.Process(pid).status() != VT.psutil.STATUS_ZOMBIE
        except VT.psutil.Error:
            return False
    if sys.platform.startswith("linux"):
        try:
            return open(f"/proc/{pid}/stat").read().split(")")[-1].split()[0] != "Z"
        except OSError:
            return False
    return None
_units_before = set(glob.glob(os.path.join(tempfile.gettempdir(), "wt-labs-unit-*")))
_logged2 = []
class _Cap(logging.Handler):
    def emit(self, r): _logged2.append(r.getMessage())
_cap = _Cap(); logging.getLogger("labs.test").addHandler(_cap)

_pr = UP.ProcessRunner(_SPEC, watch_s=0.05)
_o = _pr.run(W.ScanUnit("ok-1", "2026-09-24T10:00:00Z", "illumination", None, 1), NamedPlug("illumination"))
_r = [x for x in _rows() if x["camera_id"] == "ok-1"]
check("unit process: a unit runs in a process of its own, and its outcome comes back to the worker",
      _o.submitted and _o.segments_scanned == 2 and len(_r) == 1 and _r[0]["pid"] != os.getpid(), f"{_o} {_r}")
check("unit process: its BLAS/OpenMP pools are held to one thread (2.3-3.2 CPU-s per unit start without)",
      _r and _r[0]["blas"] == os.environ.get("OPENBLAS_NUM_THREADS", "1"), str(_r))

_o = _pr.run(W.ScanUnit("warn-1", "2026-09-24T10:00:00Z", "illumination", None, 1), NamedPlug("illumination"))
check("unit process: its warnings reach the worker's log (on Windows it does not inherit the worker's stderr)",
      _o.submitted and any("a warning from inside the unit process" in m and "warn-1" in m for m in _logged2),
      str(_logged2[-2:]))

_o = _pr.run(W.ScanUnit("crash-1", "2026-09-24T10:00:00Z", "illumination", None, 1), NamedPlug("illumination"))
check("unit process: one that DIES is reported as such (exit 7), nothing filed, and its lane rests",
      not _o.submitted and _o.stalled and "exit 7" in _o.note and not [x for x in _rows() if x["camera_id"] == "crash-1"],
      f"{_o.note} stalled={_o.stalled}")

# FILL (worker-0.3.10) runs several units of ONE analyser at once. Until then no station had,
# so this is the path proved for real: three spawned unit processes of one analyser side by side
# (the fakes decode nothing), each seen by unit_pids(), each walked by the probe, all outcomes back.
_prc = UP.ProcessRunner(_SPEC, watch_s=0.05)
_u3 = [W.ScanUnit(f"slow-{i}", "2026-09-24T10:00:00Z", "object_profile", None, 1) for i in range(3)]
_o3 = {}
_t3 = [threading.Thread(target=lambda u=u: _o3.__setitem__(u.camera_id, _prc.run(u, NamedPlug("object_profile"))))
       for u in _u3]
for _t in _t3:
    _t.start()
_end = _time.time() + 30
while len(_prc.unit_pids()) < 3 and _time.time() < _end:
    _time.sleep(0.02)
_seen3 = _prc.unit_pids()
_pb3 = LN.MachineProbe(_prc)
_pb3.sample(0.0)
for _t in _t3:
    _t.join(60)
check("unit process: THREE units of ONE analyser run at once, each in a process of its own, as fill runs "
      "them -- unit_pids() names each, and every outcome comes back",
      len(_seen3) == 3 and len({p for _, p in _seen3}) == 3 and {a for a, _ in _seen3} == {"object_profile"}
      and all(_o3.get(u.camera_id) is not None and _o3[u.camera_id].submitted for u in _u3)
      and len([x for x in _rows() if x["camera_id"].startswith("slow-")]) == 3 and _prc.unit_pids() == [],
      f"seen={_seen3} outcomes={ {k: v.submitted for k, v in _o3.items()} } after={_prc.unit_pids()}")
if _pb3.can_walk:
    # A spawned unit that decodes nothing measured 9.7 MiB of working set on the booth
    # (10,129,408 B, 2026-09-30) and more here, so the floor is only "a real process was
    # measured", not a size: 10 MiB, set from this box alone, failed there.
    check("...and the probe measures a real unit process's memory (its process tree, this machine's vitals)",
          (_pb3.unit_bytes("object_profile") or 0) > 2 * 2**20 and _pb3.error is None,
          f"{_pb3.unit_bytes('object_profile')} {_pb3.error}")
else:
    print("SKIP the probe on a real unit process's memory -- this box has no psutil and no /proc, so fill "
          "adds no unit here (checked above: 'cannot measure a unit's memory')")

# THE ORDER OF A STOP. The unit is told why FIRST; its decoders die only once it has answered
# (or ACK_WAIT_S passes). A killed decoder makes the analyser fail, and worker._file_failed
# records REVOKED instead of filing that failure only if the reason is already known: killed
# first, a Stop could spend one of the unit's three attempts. Real processes rarely lose that
# race on an idle machine, so the order itself is pinned here.
class _SpyConn:
    def __init__(self, ev): self.ev = ev
    def send(self, msg): self.ev.append(("told", msg[0]))
    def close(self): pass
class _SpyProc:
    pid = 424242
_ev = []
_sp = UP.ProcessRunner(_SPEC, kill=lambda pid: _ev.append(("killed decoders of", pid)) or 1,
                       say_killed=lambda u, why, n: None)
_uo = W.ScanUnit("order-1", "2026-09-24T10:00:00Z", "illumination", None, 1)
_co = UP._Child(unit=_uo, proc=_SpyProc(), recv=None, send=_SpyConn(_ev), progress=0.0)
_sp._children[UP._key(_uo)] = _co
_sp.abort(_uo, "taken back by the server (test)")
_after_abort = list(_ev)
_sp._kill_decoders(_co)                     # what the watcher does when the unit answers ("ack",)
check("unit process: a Stop TELLS the unit why first, and kills its decoders only after it has answered",
      _after_abort == [("told", "abort")] and _ev == [("told", "abort"), ("killed decoders of", 424242)], str(_ev))
_sp._kill_decoders(_co)
check("...and kills them once", _ev.count(("killed decoders of", 424242)) == 1, str(_ev))

_prs = UP.ProcessRunner(_SPEC, stall_s=1.0, grace_s=1.0, watch_s=0.05)
_t0 = _time.time()
_o = _prs.run(W.ScanUnit("hang-1", "2026-09-24T10:00:00Z", "illumination", None, 1), NamedPlug("illumination"))
check("unit process: one that makes NO progress is dropped after stall_s and KILLED after grace_s -- a thread "
      "could not be; its lane rests",
      not _o.submitted and _o.stalled and "no progress" in _o.note and "killed" in _o.note and _time.time() - _t0 < 15,
      f"{_o.note} {_time.time() - _t0:.1f}s")

# FILED, NOT LEFT TO LAPSE (cilex-vision, 2026-09-29): a unit this worker dropped -- no
# progress, or its process died -- is filed failed with why, so the hour is free at once
# and the ledger says what happened. A unit the server took back is never filed.
_filed = []
def _spy_file(u, plug, why):
    _filed.append((u.camera_id, why))
    o = W.UnitOutcome(u, note=why); o.submitted = o.filed_failed = True
    return o
_prf = UP.ProcessRunner(_SPEC, stall_s=1.0, grace_s=1.0, watch_s=0.05, file_failed=_spy_file)
_o = _prf.run(W.ScanUnit("hang-2", "2026-09-24T10:00:00Z", "illumination", None, 1), NamedPlug("illumination"))
check("unit process: one dropped for NO PROGRESS is filed failed, saying so -- not left to lapse as 'lease expired'",
      _filed[-1:] == [("hang-2", "stalled: no checkpoint for 1 s, its process was killed")]
      and _o.filed_failed and _o.stalled, f"{_filed} {_o.note}")
_o = _prf.run(W.ScanUnit("crash-2", "2026-09-24T10:00:00Z", "illumination", None, 1), NamedPlug("illumination"))
check("unit process: one whose process DIED is filed failed with its exit",
      _filed[-1][0] == "crash-2" and _filed[-1][1].startswith("unit_process_died:") and "exit 7" in _filed[-1][1]
      and _o.filed_failed and _o.stalled, str(_filed[-1:]))
_prr = UP.ProcessRunner(_SPEC, stall_s=100.0, grace_s=1.0, watch_s=0.05, file_failed=_spy_file)
_ur = W.ScanUnit("hang-3", "2026-09-24T10:00:00Z", "illumination", None, 1)
_resr, _n_filed = {}, len(_filed)
_tr = threading.Thread(target=lambda: _resr.update(o=_prr.run(_ur, NamedPlug("illumination"))), daemon=True)
_tr.start(); _time.sleep(1.5)
_prr.abort(_ur, "taken back by the server (test)")
_tr.join(30)
check("...while a unit the SERVER took back is never filed, even when it had to be killed",
      _resr.get("o") is not None and _resr["o"].action is W.Action.REVOKED and len(_filed) == _n_filed,
      f"{_resr.get('o')} filed={_filed[_n_filed:]}")

if _FF is None:
    print("SKIP unit process: the per-unit decoder kill and the orphan checks -- 3 checks; no ffmpeg on this station")
elif _alive(os.getpid()) is None:
    print("SKIP unit process: the per-unit decoder kill and the orphan checks -- 3 checks; this station cannot "
          "see whether a process is alive (no psutil, no /proc)")
else:
    _res = {}
    _ua2 = W.ScanUnit("decoder-a", "2026-09-24T10:00:00Z", "illumination", None, 1)
    _ub2 = W.ScanUnit("decoder-b", "2026-09-24T11:00:00Z", "audio_energy", None, 1)
    _ta = threading.Thread(target=lambda: _res.update(a=_pr.run(_ua2, NamedPlug("illumination"))), daemon=True)
    _tb = threading.Thread(target=lambda: _res.update(b=_pr.run(_ub2, NamedPlug("audio_energy"))), daemon=True)
    _ta.start(); _tb.start()
    _end = _time.time() + 30
    while (_pid_of("decoder-a") is None or _pid_of("decoder-b") is None) and _time.time() < _end:
        _time.sleep(0.05)
    _pa, _pb = _pid_of("decoder-a"), _pid_of("decoder-b")
    _pr.abort(_ua2, "taken back by the server (test)")
    _ta.join(20)
    _b_alive = _pb is not None and _alive(_pb)
    _oa = _res.get("a")
    check("unit process: a Stop on ONE unit kills ITS decoder and drops it as REVOKED -- not filed as a failure",
          _oa is not None and _oa.action is W.Action.REVOKED and not _oa.submitted and "not filed" in _oa.note
          and _pa is not None and _alive(_pa) is False and not [x for x in _rows() if x["camera_id"] == "decoder-a"],
          f"{_oa} a={_pa} alive={_pa and _alive(_pa)}")
    check("...while the OTHER lane's unit and its decoder keep running", _b_alive and _tb.is_alive(),
          f"b={_pb} alive={_b_alive} thread={_tb.is_alive()}")
    # The worker dies: its end of the unit's inbox closes. The unit must drop its work.
    with _pr._lock:
        _cb = next((x for x in _pr._children.values() if x.unit is _ub2), None)
    if _cb is not None:
        _cb.send.close()
    _tb.join(40)
    _ob = _res.get("b")
    check("unit process: when its worker is gone the unit stops its decoder and drops the unit (nothing filed)",
          _ob is not None and _ob.action is W.Action.REVOKED and "worker process ended" in _ob.note
          and _alive(_pb) is False and not [x for x in _rows() if x["camera_id"] == "decoder-b"],
          f"{_ob} b={_pb} alive={_alive(_pb)}")
check("unit process: no unit leaves its temporary directory behind",
      set(glob.glob(os.path.join(tempfile.gettempdir(), "wt-labs-unit-*"))) <= _units_before,
      str(set(glob.glob(os.path.join(tempfile.gettempdir(), "wt-labs-unit-*"))) - _units_before))
logging.getLogger("labs.test").removeHandler(_cap)

# ---- the CLI --------------------------------------------------------------------------------
import argparse as _ap
_sd5 = tempfile.mkdtemp(prefix="gov-")
_old_env = {k: os.environ.get(k) for k in ("XDG_STATE_HOME", "LOCALAPPDATA")}
os.environ["XDG_STATE_HOME"] = _sd5; os.environ["LOCALAPPDATA"] = _sd5
try:
    ST.write_control(False, by="test")
    ST.write_status({"state": "idle", "governed": True})
    _args = _ap.Namespace(status=False, pause=True, camera_health=None, hold=None, release=False)
    import io, contextlib
    with contextlib.redirect_stderr(io.StringIO()) as _err:
        _rc = RW2.control_main(_args)
    check("CLI --pause while the server governs: REFUSED with where the switch is, nothing written",
          _rc == 2 and ST.read_control()["paused"] is False and "server" in _err.getvalue(), f"rc={_rc}")
    with contextlib.redirect_stdout(io.StringIO()):
        RW2.control_main(_ap.Namespace(status=False, pause=None, camera_health=None, hold="wall degraded", release=False))
        _h = ST.read_control()["hold"]
        RW2.control_main(_ap.Namespace(status=False, pause=None, camera_health=None, hold=None, release=True))
    check("CLI --hold / --release set and clear this computer's hold",
          _h and _h["why"] == "wall degraded" and ST.read_control()["hold"] is None, str(_h))
finally:
    for k, v in _old_env.items():
        if v is None: os.environ.pop(k, None)
        else: os.environ[k] = v

# ---- vitals --------------------------------------------------------------------------------
_v = VT.Vitals()
_s1 = _v.sample(); _time.sleep(0.2); _s2 = _v.sample()
check("vitals: the first sample has no percentages (no previous); the second has them, in range",
      _s1["cpu_pct"] is None and _s1["labs_cpu_pct"] is None
      and (_s2["cpu_pct"] is None or 0.0 <= _s2["cpu_pct"] <= 100.0)
      and (_s2["mem_used_bytes"] is None or 0 < _s2["mem_used_bytes"] <= _s2["mem_total_bytes"]), f"{_s1} {_s2}")
check(f"vitals: this station measures its own tree ({VT.source()})",
      _s2["labs_rss_bytes"] is None or _s2["labs_rss_bytes"] > 0, str(_s2))
import subprocess as _sp
# A Stop kills DECODERS and nothing else (worker-0.3.3). The Python child stands in for all
# the worker owns that is not a decoder -- on Windows, its console host, which the old kill
# took down on the office (2026-09-29 02:13:36 MSK): every later ffmpeg died at DLL init.
def _kill_round(label):
    other = _sp.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    dec = None
    try:
        dec = _sp.Popen([P.ffmpeg_exe(), "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                         "-i", "anullsrc", "-f", "null", "-"],
                        stdin=_sp.DEVNULL, stdout=_sp.DEVNULL, stderr=_sp.DEVNULL)
    except OSError:
        pass
    _time.sleep(0.5)
    killed = VT.kill_children()
    def _rc(pr):
        try:
            return pr.wait(timeout=5)
        except Exception:
            pr.kill(); return "still running"
    dec_rc = _rc(dec) if dec is not None else None
    other_alive = other.poll() is None
    other.kill(); other.wait(timeout=5)
    if killed is None:
        print(f"SKIP vitals ({label}): kill_children -- this station cannot walk its process tree")
    elif dec is None:
        print(f"SKIP vitals ({label}): no decoder can be started here ({P.ffmpeg_exe()})")
    else:
        check(f"vitals ({label}): a Stop kills the worker's DECODER", killed >= 1 and dec_rc != "still running",
              f"killed={killed} rc={dec_rc}")
        check(f"vitals ({label}): ...and spares what is not a decoder (on Windows, its console host)",
              other_alive, "the non-decoder child was killed")
_kill_round("psutil" if VT.psutil is not None else "this station's own path")
if VT.psutil is not None and sys.platform.startswith("linux"):
    _ps, VT.psutil = VT.psutil, None             # the /proc path too, where psutil is missing
    try:
        _kill_round("/proc")
    finally:
        VT.psutil = _ps
else:
    # Named, so a count on another platform reconciles (Windows ran 322 where Linux ran 324,
    # 2026-09-29: these two checks). Every skip says so by name (482f8cc).
    print("SKIP vitals (/proc): a Stop kills the DECODER / spares the rest -- 2 checks; "
          + ("no /proc on this platform" if not sys.platform.startswith("linux")
             else "psutil is missing, so the round above already took the /proc path"))
class _Pr:
    def __init__(self, n): self.n, self.killed = n, False
    def name(self): return self.n
    def kill(self): self.killed = True
_tree = [_Pr("conhost.exe"), _Pr("ffmpeg.exe"), _Pr("python.exe"), _Pr("ffprobe.exe"), _Pr("cmd.exe")]
_nk = VT.kill_children(procs=_tree)
check("vitals: the Windows tree the office had -- only ffmpeg.exe and ffprobe.exe are killed, conhost.exe lives",
      _nk == 2 and [x.killed for x in _tree] == [False, True, False, True, False], str([(x.n, x.killed) for x in _tree]))
check("vitals: the allow-list -- decoders by name, with or without .exe or a build suffix; nothing else",
      all(VT.is_decoder(n) for n in ("ffmpeg", "ffmpeg.exe", "FFMPEG.EXE", "ffprobe.exe", "ffmpeg-v1144.exe"))
      and not any(VT.is_decoder(n) for n in ("conhost.exe", "python.exe", "cmd.exe", "sleep", "", None)))


# ---------------------------------------------------------------- object_profile (Vehicles, V1 op-2)
# cilex-vision reply4 (2026-09-29): a pilot of the real analyser on one station. Thumbnails are PUT
# under the lease FIRST, then the results that name them; four new refusals are the worker's bugs.
import re as _re
import labs_colour_histogram as _CH
import object_profile as _OP

def _op_frames(n=70, warm=30, step=0.4):
    """A red box crossing a flat grey scene, as 4:2:0 planes (the selftest's scene)."""
    base = np.empty((180, 320, 3), np.uint8); base[:] = (150, 150, 150); base[::7, ::11] = (160, 160, 160)
    out = []
    for i in range(n):
        f = base.copy()
        if i >= warm:
            x = 10 + 6 * (i - warm)
            if x + 40 < 320:
                f[80:110, x:x + 40] = (220, 20, 20)
        ycc = _CH.rgb_to_ycbcr(f.astype(np.float32))
        y = np.clip(np.rint(ycc[..., 0]), 0, 255).astype(np.uint8)
        u = np.clip(np.rint(ycc[..., 1].reshape(90, 2, 160, 2).mean((1, 3))), 0, 255).astype(np.uint8)
        v = np.clip(np.rint(ycc[..., 2].reshape(90, 2, 160, 2).mean((1, 3))), 0, 255).astype(np.uint8)
        out.append(so.Frame(index=i, t_offset_s=i * step, luma=y, u=u, v=v))
    return out

_OPF = _op_frames()
def _op_decode(path, kf, want_chroma, want_planes=False):
    assert want_planes, "object_profile must ask the decoder for the U and V planes"
    return list(_OPF)

class _ThumbFake(Fake):
    def __init__(self, *a, thumb_refuse=None, **k):
        super().__init__(*a, **k)
        self.log, self.thumbs = [], {}
        self.thumb_refuse = list(thumb_refuse or [])
    def put_thumb(self, u, key, jpeg):
        if self.thumb_refuse:
            r = self.thumb_refuse.pop(0)
            if r: raise r
        self.log.append(("thumb", key)); self.thumbs[key] = jpeg
        return {"status": "stored"}
    def submit(self, u, body):
        self.log.append(("submit",)); super().submit(u, body)

def _op_segs(cam):
    return [W.Segment(f"op-{i}", f"http://x/labs/segments/op-{i}", f"2026-09-24T10:00:{i * 30:02d}+00:00",
                      f"2026-09-24T10:00:{i * 30 + 28:02d}+00:00", 28.0, 3_000_000, "sub", 320, 180, "h264",
                      scene_light_astronomical="day", astro_key_present=True) for i in range(2)]

_OPP = P.ObjectProfilePlugin()
_uo = unit(a="object_profile")
_c = _ThumbFake(segs={(_uo.camera_id, _uo.hour_start): _op_segs(_uo.camera_id)})
_o = W.run_unit(_c, _OPP, _uo, decode=_op_decode, states={}, tmpdir=TMP, sleep=lambda s: None)
_b = _c.submitted[0][1] if _c.submitted else {}
_rows = _b.get("observations") or []
_named = [(r.get("metrics") or {}).get("thumb") for r in _rows]
check("object_profile: a unit of a moving red box is SUBMITTED with rows, as op-2+<the worker's version>",
      _o.submitted and len(_rows) >= 1 and _b.get("analyzer_version") == f"op-2+{W.WORKER_VERSION}",
      str((_o.note, _b.get("analyzer_version"), len(_rows))))
check("object_profile: EVERY thumbnail is PUT before the results, and only those the rows name",
      _c.log and _c.log[-1] == ("submit",) and all(e[0] == "thumb" for e in _c.log[:-1])
      and sorted(k for _, k in _c.log[:-1]) == sorted(_named) and _o.thumbs_uploaded == len(_named),
      str(_c.log))
check("object_profile: each thumbnail is a JPEG of at most 32,768 bytes, its key [a-z0-9-]{1,40}",
      _c.thumbs and all(j[:2] == b"\xff\xd8" and len(j) <= 32768 for j in _c.thumbs.values())
      and all(_re.fullmatch(r"[a-z0-9-]{1,40}", k) for k in _c.thumbs), str({k: len(j) for k, j in _c.thumbs.items()}))
_allowed = {"thumb", "stream", "best_at_s", "body_px", "scene_chroma", "bg_chroma",
            "colour_1", "colour_1_share", "colour_gate"}
check("object_profile: rows carry only the V1 keys and the two evidence keys -- NO colour_2 (the operator's call)",
      all(set((r.get("metrics") or {})) <= _allowed and "colour_2" not in r["metrics"]
          and "colour_2_share" not in r["metrics"] for r in _rows), str([sorted(r["metrics"]) for r in _rows]))
_ok_caps = True
for _r in _rows:
    try:
        W.check_metrics(_r["metrics"])
    except W.MetricsViolation:
        _ok_caps = False
check("object_profile: every row passes the server's metrics caps; stream is 'sub'",
      _ok_caps and all(r["metrics"]["stream"] == "sub" for r in _rows))
check("object_profile: each row is a passage -- inside the hour, span under 300 s, the box and shape typed",
      all(r["start_time"] >= "2026-09-24T10:00:00" and r["start_time"] < "2026-09-24T11:00:00"
          and r["end_time"] >= r["start_time"]
          and all(k in r for k in ("bbox_x", "bbox_y", "bbox_w", "bbox_h", "shape_class", "shape_confidence"))
          for r in _rows), str(_rows[:1]))
check("object_profile: the red box is named red (by day the cast gate does not apply)",
      any(r["metrics"].get("colour_1") == "red" for r in _rows),
      str([(r["metrics"].get("colour_1"), r["metrics"].get("colour_gate")) for r in _rows]))

# refusals of the thumbnail PUT
_c = _ThumbFake(segs={(_uo.camera_id, _uo.hour_start): _op_segs(_uo.camera_id)},
                thumb_refuse=[R(400, "bad_thumb_key", False)])
_o = W.run_unit(_c, P.ObjectProfilePlugin(), _uo, decode=_op_decode, states={}, tmpdir=TMP, sleep=lambda s: None)
_b = _c.submitted[0][1] if _c.submitted else {}
check("object_profile: a thumbnail REFUSED as malformed (400 bad_thumb_key) files the unit failed, with that cause",
      W.action_for(R(400, "bad_thumb_key", False)) is W.Action.BUG and _b.get("failed") is True
      and "thumb_refused" in (_b.get("error") or "") and _b.get("observations") == [], str(_b)[:200])
check("...and so are thumb_too_large, thumb_not_jpeg and thumbs_not_accepted (bugs, not stops)",
      all(W.action_for(R(st, sl, False)) is W.Action.BUG for st, sl in
          ((413, "thumb_too_large"), (415, "thumb_not_jpeg"), (404, "thumbs_not_accepted"))))
_c = _ThumbFake(segs={(_uo.camera_id, _uo.hour_start): _op_segs(_uo.camera_id)},
                thumb_refuse=[R(409, "scan_unit_revoked", False)])
_o = W.run_unit(_c, P.ObjectProfilePlugin(), _uo, decode=_op_decode, states={}, tmpdir=TMP, sleep=lambda s: None)
check("object_profile: the unit TAKEN BACK during the uploads is not submitted at all",
      not _c.submitted and _o.action is W.Action.REVOKED and not _o.submitted, str((_o.action, _o.note)))
_c = _ThumbFake(segs={(_uo.camera_id, _uo.hour_start): _op_segs(_uo.camera_id)},
                thumb_refuse=[R(0, "transport_error", True)])
_o = W.run_unit(_c, P.ObjectProfilePlugin(), _uo, decode=_op_decode, states={}, tmpdir=TMP, sleep=lambda s: None)
check("object_profile: a transport blip on a thumbnail is retried, and the unit still submits",
      _o.submitted and _c.log and _c.log[-1] == ("submit",), str((_o.note, _c.log[-2:])))

# the server capability that gates claiming, and the request itself
_oa_yes = {"paths": {"/labs/scan/{analyzer}/{camera_id}/{hour_start}/thumbs/{key}": {"put": {}},
                     "/labs/scan/claim": {"post": {}}}}
_oa_no = {"paths": {"/labs/scan/claim": {"post": {}}}}
check("object_profile: claimed only from a server with the thumbnail PUT (supported_by)",
      P.ObjectProfilePlugin.supported_by(_oa_yes) is None
      and "predates" in (P.ObjectProfilePlugin.supported_by(_oa_no) or ""))
import run_worker as _RW2
check("object_profile: registered in the worker (a lane of its own)",
      "object_profile" in _RW2.PLUGINS and isinstance(_RW2.make_plugin("object_profile"), P.ObjectProfilePlugin))
_seen = []
class _Resp:
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def read(self, *a): return b'{"status": "stored"}'
import urllib.request as _urq_op              # its own name: `_ur` is a ScanUnit by now (hang-3)
_uo2 = _urq_op.urlopen
try:
    _urq_op.urlopen = lambda req, timeout=None: _seen.append(req) or _Resp()
    _hc = W.HttpLabsClient("http://srv:8000", "tok-123")
    _res = _hc.put_thumb(W.ScanUnit("hiwatch-1", "2026-09-24T10:00:00Z", "object_profile", None, 1), "t0001234", b"\xff\xd8jpeg")
finally:
    _urq_op.urlopen = _uo2
_rq = _seen[0] if _seen else None
check("object_profile: the PUT goes to /labs/scan/object_profile/{camera}/{hour}/thumbs/{key}, image/jpeg, the JPEG as the body",
      _rq is not None and _rq.get_method() == "PUT"
      and _rq.full_url.endswith("/labs/scan/object_profile/hiwatch-1/2026-09-24T10%3A00%3A00Z/thumbs/t0001234")
      and _rq.get_header("Content-type") == "image/jpeg" and _rq.data == b"\xff\xd8jpeg"
      and _rq.get_header("X-cilex-station-token") == "tok-123" and _res == {"status": "stored"},
      str(_rq and (_rq.get_method(), _rq.full_url, _rq.header_items())))

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}", file=sys.stderr); sys.exit(1)
print("all passed")
