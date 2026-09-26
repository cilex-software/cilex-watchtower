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
import argparse, logging, os, sys, time, json, urllib.request
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
    # ffmpeg named, not searched for: find_ffmpeg() RUNS each candidate to prove it
    # works, and without this that would be one extra process per segment.
    return list(frame_source.iter_frames(path, ffmpeg=P.ffmpeg_exe(), keyframes_only=kf,
                                         want_chroma=want_chroma))


PLUGINS = {"illumination": P.IlluminationPlugin, "blob_geometry": P.ShapePlugin,
           "frame_difference": P.FrameDifferencePlugin, "audio_energy": P.AudioEnergyPlugin,
           "optical_flow": P.OpticalFlowPlugin, "perceptual_hash": P.PerceptualHashPlugin}


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
    # The analysers' own WARNINGs (a decoder that failed, and why) go to stderr as
    # they happen; the worker also appends the last one to a failed unit's reason.
    logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(name)s %(levelname)s %(message)s")

    tok = read_token()
    print(f"station token : {'present' if tok else 'MISSING'} ({CONF})")
    # A station with no working ffmpeg would file EVERY unit it claims as failed --
    # three attempts each, on real camera-hours. Refuse before claiming anything.
    try:
        print(f"ffmpeg        : {P.ffmpeg_exe()}")
    except RuntimeError as e:
        sys.exit(f"FATAL (this station cannot decode; nothing claimed): {e}")
    try:
        oa = json.load(urllib.request.urlopen(f"{a.api}/openapi.json", timeout=10))
        print(f"service       : {a.api}  version {oa['info']['version']}")
    except Exception as e:
        sys.exit(f"service unreachable: {type(e).__name__}")
    # NEVER CLAIM WORK THIS SERVER CANNOT SERVE. A claimed unit that cannot be done is
    # either abandoned (recorded as 'lease expired', naming the wrong cause) or filed
    # failed (counting towards its three attempts, and staying failed after the server
    # is upgraded). So a plugin that needs a server capability is dropped HERE, before
    # anything is leased.
    keep = []
    for n in names:
        why = getattr(PLUGINS[n], "supported_by", lambda _oa: None)(oa)
        if why:
            print(f"skipping      : {n} -- {why}")
        else:
            keep.append(n)
    names = keep
    if not names:
        sys.exit("nothing this server can run")
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
              + (f" gone={o.skipped_segments}" if o.skipped_segments else "")
              + (f" undecodable={o.undecodable_segments}" if o.undecodable_segments else "")
              + (f"  [{o.action.value}: {o.note}]" if o.action else ""))
    if rep.stopped_analysers:
        print("stopped (operator disabled):", ", ".join(rep.stopped_analysers))
    if rep.unreachable:
        sys.exit(f"UNREACHABLE (the server did not answer; try again later): {rep.unreachable}")
    if rep.fatal:
        sys.exit(f"FATAL (this station cannot work until fixed): {rep.fatal}")


if __name__ == "__main__":
    main()
