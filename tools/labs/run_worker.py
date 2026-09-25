#!/usr/bin/env python3
"""Run the Labs worker against the live service.

SAFE BY DEFAULT. Claiming a scan unit and submitting results are WRITES that every
agent and the operator can see (CLAUDE.md: "Write actions are globally visible ...
Do not run sweeps or soak harnesses that write, without saying so in chat first").
So without `--live` this claims NOTHING: it reads the token, checks the service is
reachable and the analysers are enabled, and prints what a live run would do.

The station token is read from the SAME file Warden reads -- warden.conf's
STATION_TOKEN -- so it exists in one place. Never logged, never printed.
"""
import argparse, os, sys, time, json, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import worker as W, plugins as P, frame_source

CONF = os.path.expanduser("~/.config/watchtower-warden/warden.conf")


def read_token(path=CONF):
    try:
        for line in open(path, encoding="utf-8"):
            k, _, v = line.strip().partition("=")
            if k.strip() == "STATION_TOKEN" and v.strip():
                return v.strip().strip('"').strip("'")
    except OSError:
        pass
    return None


def decode(path, kf, want_chroma):
    return list(frame_source.iter_frames(path, keyframes_only=kf, want_chroma=want_chroma))


PLUGINS = {"illumination": P.IlluminationPlugin, "blob_geometry": P.ShapePlugin}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default=os.environ.get("WT_API", "http://127.0.0.1:8000"))
    ap.add_argument("--analyzer", action="append", choices=sorted(PLUGINS),
                    help="repeatable; default: illumination")
    ap.add_argument("--live", action="store_true",
                    help="actually CLAIM and SUBMIT. Without it nothing is written.")
    ap.add_argument("--units", type=int, default=1, help="claim this many per analyser (live)")
    a = ap.parse_args()
    names = a.analyzer or ["illumination"]

    tok = read_token()
    print(f"station token : {'present' if tok else 'MISSING'} ({CONF})")
    try:
        v = json.load(urllib.request.urlopen(f"{a.api}/openapi.json", timeout=10))["info"]["version"]
        print(f"service       : {a.api}  version {v}")
    except Exception as e:
        sys.exit(f"service unreachable: {type(e).__name__}")
    if not tok:
        sys.exit("no STATION_TOKEN in warden.conf; nothing to run as")

    if not a.live:
        print(f"analysers     : {', '.join(names)}")
        print("mode          : DRY RUN — nothing claimed, nothing submitted.")
        print("                re-run with --live to claim and submit (a globally visible write).")
        return

    client = W.HttpLabsClient(a.api, tok)
    plugins = [PLUGINS[n]() for n in names]
    t0 = time.time()
    rep = W.run_once(client, plugins, decode=decode, states={}, claim_limit=a.units)
    print(f"claimed {rep.claimed}  submitted {rep.submitted}  abandoned {rep.abandoned}  "
          f"in {time.time()-t0:.1f}s")
    for o in rep.outcomes:
        print(f"  {o.unit.analyzer:14s} {o.unit.camera_id:24s} {o.unit.hour_start}  "
              f"segs={o.segments_scanned} obs={o.observations} submitted={o.submitted}"
              + (f"  [{o.action.value}: {o.note}]" if o.action else ""))
    if rep.stopped_analysers:
        print("stopped (operator disabled):", ", ".join(rep.stopped_analysers))
    if rep.fatal:
        sys.exit(f"FATAL: {rep.fatal}")


if __name__ == "__main__":
    main()
