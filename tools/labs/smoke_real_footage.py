#!/usr/bin/env python3
"""End-to-end on REAL footage, without touching the Labs API.

Real segments from the filer, the real shared decoder, both real analysers, and the
worker's real translation -- but a fake client, so nothing is claimed and nothing is
submitted. Every body the worker WOULD send is validated against ObservationIn as
read from the running service's OpenAPI. This is the bridge between the hermetic
tests (synthetic frames) and a live run (a globally visible write).
"""
import json, os, subprocess, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import worker as W, plugins as P, frame_source

API = os.environ.get("WT_API", "http://127.0.0.1:8000")
FILER = "http://localhost:8888/buckets"

schema = json.load(urllib.request.urlopen(f"{API}/openapi.json", timeout=15))
OBS = schema["components"]["schemas"]["ObservationIn"]
REQ, PROPS = set(OBS.get("required", [])), OBS["properties"]
SCENE = {"day", "dusk", "night", "ir", "unknown"}

def validate(o):
    bad = [f"missing {k}" for k in REQ if k not in o]
    bad += [f"unknown key {k}" for k in o if k not in PROPS]
    for k in ("confidence", "shape_confidence"):
        if o.get(k) is not None and not (0.0 <= o[k] <= 1.0):
            bad.append(f"{k}={o[k]} out of [0,1]")
    if o.get("scene_light") is not None and o["scene_light"] not in SCENE:
        bad.append(f"scene_light={o['scene_light']!r} would be 422 unknown_scene_light")
    return bad

def pick(cam, stream, n):
    sql = (f"select segment_id, storage_uri, start_time, end_time, duration_s, bytes, "
           f"stream_type, width, height, codec from video_segments "
           f"where camera_id='{cam}' and stream_type='{stream}' and bytes>100000 "
           f"order by start_time desc limit {n}")
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
    return list(reversed(out))

class FilerClient:
    """Serves real bytes; claims and submits NOTHING."""
    def __init__(self, segs): self.segs, self.bodies = segs, []
    def claim(self, *a): raise AssertionError("smoke test must not claim")
    def segments(self, u, limit, stream_type): return [s for s, _ in self.segs][:limit]
    def fetch(self, seg, dest):
        uri = dict((s.segment_id, u) for s, u in self.segs)[seg.segment_id]
        urllib.request.urlretrieve(f"{FILER}/{uri.replace('s3://','',1)}", dest)
        return os.path.getsize(dest)
    def submit(self, u, body): self.bodies.append(body)

def decode(path, kf, want_chroma):
    return list(frame_source.iter_frames(path, keyframes_only=kf, want_chroma=want_chroma))

total_bad = 0
for plugin, cam, stream, n in ((P.IlluminationPlugin(), "hiwatch-04eecdd45e2d", "main", 2),
                               (P.ShapePlugin(), "hiwatch-849459c4f13d", "sub", 12)):
    segs = pick(cam, stream, n)
    c = FilerClient(segs)
    u = W.ScanUnit(cam, "smoke", plugin.name, None, 0)
    o = W.run_unit(c, plugin, u, decode=decode, states={})
    obs = c.bodies[0]["observations"] if c.bodies else []
    bad = [b for ob in obs for b in validate(ob)]
    total_bad += len(bad)
    print(f"{plugin.name:14s} {cam:24s} {stream:4s} segs={o.segments_scanned:2d} "
          f"decoder_runs={o.decoder_runs:2d} submitted={o.submitted} observations={len(obs):4d} "
          f"schema_violations={len(bad)}")
    if obs:
        s = obs[0]
        print(f"      first: " + json.dumps({k: s[k] for k in list(s)[:6]}, default=str)[:150])
    for b in bad[:5]: print("      VIOLATION:", b)
print()
print("RESULT:", "every body valid against the live ObservationIn" if total_bad == 0
      else f"{total_bad} schema violations")
sys.exit(1 if total_bad else 0)
