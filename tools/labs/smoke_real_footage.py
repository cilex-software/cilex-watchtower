#!/usr/bin/env python3
"""End-to-end on REAL footage, without touching the Labs API.

Real segments from the filer, the real shared decoder, both real analysers, and the
worker's real translation -- but a fake client, so nothing is claimed and nothing is
submitted. Every body the worker WOULD send is validated against ObservationIn as
read from the running service's OpenAPI. This is the bridge between the hermetic
tests (synthetic frames) and a live run (a globally visible write).
"""
import json, os, subprocess, sys, time, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import worker as W, plugins as P, frame_source

API = os.environ.get("WT_API", "http://127.0.0.1:8000")
FILER = "http://localhost:8888/buckets"

schema = json.load(urllib.request.urlopen(f"{API}/openapi.json", timeout=15))
OBS = schema["components"]["schemas"]["ObservationIn"]
REQ, PROPS = set(OBS.get("required", [])), OBS["properties"]
SCENE = {"day", "dusk", "night", "ir", "unknown"}

def validate(o):
    # TWO layers, because the schema is not the whole contract. The OpenAPI schema
    # carries required fields and types; cilex-vision's `_clean_metrics` enforces the
    # metrics caps in Python, where the schema cannot show them. Checking only the
    # first reported "0 violations" for a body the server would refuse with 422.
    bad = []
    try:
        W.check_metrics(o.get("metrics"))
    except W.MetricsViolation as e:
        bad.append(f"server metrics rule: {e}")
    bad += [f"missing {k}" for k in REQ if k not in o]
    bad += [f"unknown key {k}" for k in o if k not in PROPS]
    for k in ("confidence", "shape_confidence"):
        if o.get(k) is not None and not (0.0 <= o[k] <= 1.0):
            bad.append(f"{k}={o[k]} out of [0,1]")
    if o.get("scene_light") is not None and o["scene_light"] not in SCENE:
        bad.append(f"scene_light={o['scene_light']!r} would be 422 unknown_scene_light")
    return bad

def pick(cam, stream, n, hour):
    """Up to n segments of one camera and stream that START inside `hour` (a real
    claimed-hour shape: the analysers that bound rows to the hour need one)."""
    sql = (f"SET statement_timeout='10s'; "
           f"select segment_id, storage_uri, start_time, end_time, duration_s, bytes, "
           f"stream_type, width, height, codec from video_segments "
           f"where camera_id='{cam}' and stream_type='{stream}' and bytes>100000 "
           f"and start_time >= '{hour}' and start_time < timestamptz '{hour}' + interval '1 hour' "
           f"order by start_time limit {n}")
    r = subprocess.run(["docker","exec","-i","timescaledb","psql","-U","cilex","-d",
                        "vidanalytics","-At","-F","|"], input=sql, capture_output=True,
                       text=True, timeout=60)
    out = []
    for l in r.stdout.splitlines():
        p = l.split("|")
        if len(p) != 10: continue
        st = p[2].replace(" ", "T"); en = p[3].replace(" ", "T")
        st = st + ":00" if st[-3] in "+-" else st; en = en + ":00" if en[-3] in "+-" else en
        out.append((W.Segment(p[0], p[1], st, en, float(p[4] or 0), int(p[5] or 0),
                              p[6], int(p[7] or 0), int(p[8] or 0), p[9]), p[1]))
    return out

class FilerClient:
    """Serves real bytes; claims and submits NOTHING."""
    def __init__(self, segs): self.segs, self.bodies = segs, []
    def claim(self, *a): raise AssertionError("smoke test must not claim")
    def segments(self, u, limit, stream_type, window=None, window_at=None):
        return [s for s, _ in self.segs][:window or limit]
    def fetch(self, seg, dest):
        uri = dict((s.segment_id, u) for s, u in self.segs)[seg.segment_id]
        urllib.request.urlretrieve(f"{FILER}/{uri.replace('s3://','',1)}", dest)
        return os.path.getsize(dest)
    def submit(self, u, body): self.bodies.append(body)

def decode(path, kf, want_chroma, want_planes=False):
    return list(frame_source.iter_frames(path, ffmpeg=P.ffmpeg_exe(), keyframes_only=kf,
                                         want_chroma=want_chroma, want_planes=want_planes))

DAY = os.environ.get("WT_SMOKE_DAY", "2026-09-26T10:00:00+00:00")      # 13:00 MSK
NIGHT = os.environ.get("WT_SMOKE_NIGHT", "2026-09-26T01:00:00+00:00")  # 04:00 MSK
BUSY, IRCAM, AUDIO = "hiwatch-849459c4f007", "hiwatch-04eecdd45e2d", "hiwatch-04eecdd44de8"
CASES = (
    # label, plugin, camera, stream, segments, hour
    ("illumination",      P.IlluminationPlugin(),    IRCAM, "main", 2, DAY),
    ("blob_geometry",     P.ShapePlugin(),           "hiwatch-849459c4f13d", "sub", 12, DAY),
    ("frame_difference",  P.FrameDifferencePlugin(), "hiwatch-849459c4f13d", "main", 4, DAY),
    # CONTROL PAIR: the one camera recording audio vs one without -- different answers.
    ("audio_energy",      P.AudioEnergyPlugin(),     AUDIO, "main", 6, DAY),
    ("audio (no audio)",  P.AudioEnergyPlugin(),     "hiwatch-849459c4f13d", "main", 2, DAY),
    ("optical_flow",      P.OpticalFlowPlugin(),     BUSY, "sub", 6, DAY),
    ("perceptual_hash",   P.PerceptualHashPlugin(),  BUSY, "sub", 12, DAY),
    ("camera_health",     P.CameraHealthPlugin(),    IRCAM, "main", 4, DAY),
    ("foreground_mask",   P.ForegroundMaskPlugin(),  BUSY, "sub", 8, DAY),
    # CONTROL PAIR: colour by day, the IR gate by night, on the same kind of camera.
    ("colour_histogram",  P.ColourHistogramPlugin(), BUSY, "sub", 8, DAY),
    ("colour (night)",    P.ColourHistogramPlugin(), IRCAM, "sub", 8, NIGHT),
    ("track_linking",     P.TrackLinkingPlugin(),    BUSY, "sub", 20, DAY),
)

total_bad = 0
for label, plugin, cam, stream, n, hour in CASES:
    segs = pick(cam, stream, n, hour)
    c = FilerClient(segs)
    u = W.ScanUnit(cam, hour.replace("+00:00", "Z"), plugin.name, None, 0)
    t0, c0 = time.time(), os.times()
    o = W.run_unit(c, plugin, u, decode=decode, states={})
    c1 = os.times()
    cpu = (c1.user + c1.system + c1.children_user + c1.children_system) - \
          (c0.user + c0.system + c0.children_user + c0.children_system)
    body = c.bodies[0] if c.bodies else {}
    obs = body.get("observations") or []
    bad = [b for ob in obs for b in validate(ob)]
    total_bad += len(bad)
    state = "FAILED: " + (body.get("error") or "")[:90] if body.get("failed") else f"{len(obs)} rows"
    print(f"{label:17s} {cam:21s} {stream:4s} segs={o.segments_scanned:2d}/{len(segs):2d} "
          f"{time.time()-t0:5.1f}s cpu={cpu:5.1f}s  {state}  schema_violations={len(bad)}")
    for ob in obs[:2]:
        typed = {k: v for k, v in ob.items() if k not in ("metrics",)}
        m = ob.get("metrics") or {}
        keys = [k for k in ("scene_light", "astro", "colour", "gate", "object_count", "frozen", "moved",
                            "defocused", "ir", "dir_label", "peak", "sustained_s", "loud_db", "no_audio",
                            "dwell_s", "identical_count") if k in m or k in typed]
        print("      " + json.dumps({k: (typed.get(k) if k in typed else m.get(k)) for k in keys}, default=str)[:170])
    for b in bad[:5]: print("      VIOLATION:", b)
print()
print("RESULT:", "every body passes BOTH the live ObservationIn schema AND the server's "
      "code-level metrics rules" if total_bad == 0 else f"{total_bad} violations")
sys.exit(1 if total_bad else 0)
