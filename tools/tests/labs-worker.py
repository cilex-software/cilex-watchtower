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
    def segments(self, u, limit, stream_type):
        self.seg_calls.append((u.camera_id, limit, stream_type))
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
