#!/usr/bin/env python3
"""Labs worker — hermetic tests. No network, no database, no live fleet.

A fake client serves units and segments and can REFUSE on cue with the exact slugs
the running service (1.0.57) returns; a fake decoder hands back synthetic frames.
Every case below is a rule that has already cost somebody a run.
"""
import glob, os, sys, tempfile, pathlib
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "labs"))
import worker as W                                   # noqa: E402
import plugins as P                                  # noqa: E402
import shape_observations as so                      # noqa: E402

fails = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"   [{detail}]" if detail and not cond else ""))
    if not cond: fails.append(name)

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

# ---------------------------------------------------------------- frame_difference (A1/A2)
import hashlib, labs_framediff as FDM
FD = P.FrameDifferencePlugin()

# The vendored module must stay BYTE-IDENTICAL to cilex-vision's: its threshold is
# calibrated to its own decoder, and a silent local edit would change what 2.0 means.
_cvfd = pathlib.Path("/home/cilex-vision/projects/cilex-vision/services/query-api/labs_framediff.py")
if _cvfd.exists():
    ours = hashlib.sha256((ROOT / "tools/labs/labs_framediff.py").read_bytes()).hexdigest()
    theirs = hashlib.sha256(_cvfd.read_bytes()).hexdigest()
    check("vendored labs_framediff.py is byte-identical to cilex-vision's", ours == theirs,
          f"ours {ours[:12]} theirs {theirs[:12]} -- re-vendor it")
else:
    print("SKIP vendored framediff vs source -- their checkout is not on this box")

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
          b.get("failed") is True and "window_has_a_hole" in (b.get("error") or ""), str(b))
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

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}", file=sys.stderr); sys.exit(1)
print("all passed")
