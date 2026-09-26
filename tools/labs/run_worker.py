#!/usr/bin/env python3
"""Run the Labs worker against the live service.

SAFE BY DEFAULT. Claiming a scan unit and submitting results are WRITES that every
agent and the operator can see (CLAUDE.md: "Write actions are globally visible ...
Do not run sweeps or soak harnesses that write, without saying so in chat first").
So without `--live` this claims NOTHING: it reads the token, checks the service is
reachable and the analysers are enabled, and prints what a live run would do.

The station token is read from the SAME file Warden reads -- warden.conf's
STATION_TOKEN -- so it exists in one place. Never logged, never printed.

STATION SCANNING (--loop): scan continuously, as a background service, until
stopped. It obeys station.py's control file before EVERY claim and starts PAUSED
unless that file says otherwise, so nothing is claimed until someone presses Resume
in the app's Labs screen (or runs --resume). It reports through status.json, kept
fresh by a heartbeat thread, which is what the Labs screen shows.
"""
import argparse, logging, os, sys, threading, time, json, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import worker as W, plugins as P, frame_source, station as S

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


def decode(path, kf, want_chroma, want_planes=False):
    # ffmpeg named, not searched for: find_ffmpeg() RUNS each candidate to prove it
    # works, and without this that would be one extra process per segment.
    return list(frame_source.iter_frames(path, ffmpeg=P.ffmpeg_exe(), keyframes_only=kf,
                                         want_chroma=want_chroma, want_planes=want_planes))


PLUGINS = {"illumination": P.IlluminationPlugin, "blob_geometry": P.ShapePlugin,
           "frame_difference": P.FrameDifferencePlugin, "audio_energy": P.AudioEnergyPlugin,
           "optical_flow": P.OpticalFlowPlugin, "perceptual_hash": P.PerceptualHashPlugin,
           "camera_health": P.CameraHealthPlugin, "foreground_mask": P.ForegroundMaskPlugin,
           "colour_histogram": P.ColourHistogramPlugin, "track_linking": P.TrackLinkingPlugin}


def make_plugin(name):
    # camera_health's per-camera Baseline must outlive this process (see its class).
    if name == "camera_health":
        return P.CameraHealthPlugin(state_dir=os.path.join(P.labs_state_dir(), "camera_health"))
    return PLUGINS[name]()


# ----------------------------------------------------------------------------------
# Station scanning: the loop behind --loop
# ----------------------------------------------------------------------------------
PAUSED_POLL_S = 5.0      # how soon a Pause or a Resume is honoured while waiting
IDLE_S = 120.0           # nothing claimable: look again in two minutes
UNREACHABLE_S = 60.0     # the server did not answer: try again in a minute
FATAL_S = 600.0          # this station cannot work (no token, no ffmpeg, token refused)
RECHECK_S = 900.0        # re-read the server's capabilities (a deploy can add one)


class Heartbeat:
    """Keeps status.json fresh from its own thread. The main loop can sit inside one
    unit for minutes -- a whole hour of footage -- and without this the app would call
    a working station "not running". Writes are atomic (station._write_atomic)."""

    def __init__(self, base: dict, write=S.write_status, every: float = S.HEARTBEAT_S):
        self.fields = dict(base)
        self._lock = threading.Lock()
        self._write, self._every = write, every
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._warned = False

    def start(self):
        self._flush()
        self._thread.start()
        return self

    def update(self, **kw):
        with self._lock:
            self.fields.update(kw)
        self._flush()

    def stop(self, **kw):
        self.update(**kw)
        self._stop.set()

    def _flush(self):
        with self._lock:
            doc = dict(self.fields)
        try:
            self._write(doc)
        except Exception as e:
            # A status file this station cannot write must not stop the scanning; say
            # so once, where a person running it would see it.
            if not self._warned:
                self._warned = True
                logging.getLogger("labs.station").warning("cannot write status.json: %s", e)

    def _run(self):
        while not self._stop.wait(self._every):
            self._flush()


def unit_summary(o) -> dict:
    """One unit, as the Labs screen shows it."""
    outcome = ("failed" if o.filed_failed else "done") if o.submitted else "abandoned"
    return {"analyzer": o.unit.analyzer, "camera_id": o.unit.camera_id,
            "hour_start": o.unit.hour_start, "outcome": outcome,
            "observations": o.observations, "segments": o.segments_scanned,
            "note": W.fit(o.note or "", 200), "seconds": o.timings.get("total_s"),
            "at": S.now_iso()}


def scan_loop(client, supported, *, decode, hb, control=S.read_control,
              sleep=time.sleep, clock=time.monotonic, passes=None) -> dict:
    """Scan until stopped (or for `passes` passes, in tests).

    One pass asks for ONE unit per analyser this station runs, in turn. Before every
    claim it re-reads the control file, so a Pause takes effect at the next claim --
    never by abandoning a unit already leased, which would waste the lease and leave
    the hour marked 'lease expired'. camera_health runs only where the control file
    opts this station in (exactly one station may run it).
    """
    states = {}
    totals = {"claimed": 0, "done": 0, "failed": 0, "abandoned": 0}

    def wait(seconds, until_paused):
        # Return early the moment the pause flag becomes `until_paused`.
        end = clock() + seconds
        while clock() < end:
            if control()["paused"] == until_paused:
                return
            sleep(min(PAUSED_POLL_S, max(0.0, end - clock())))

    n = 0
    while passes is None or n < passes:
        n += 1
        ctl = control()
        if ctl["paused"]:
            hb.update(state="paused", note=ctl["why"], current=None)
            wait(3600.0, until_paused=False)
            continue
        plugins = [p for p in supported()
                   if p.name != "camera_health" or ctl["camera_health"]]
        hb.update(runs=[p.name for p in plugins], camera_health=ctl["camera_health"])
        claimed, stop = 0, None
        for p in plugins:
            if control()["paused"]:
                break
            hb.update(state="running", note="", current=p.name)
            rep = W.run_once(client, [p], decode=decode, states=states,
                             gate=lambda: not control()["paused"], claim_limit=1, sleep=sleep)
            claimed += rep.claimed
            totals["claimed"] += rep.claimed
            for o in rep.outcomes:
                summary = unit_summary(o)
                totals[summary["outcome"]] += 1
                hb.update(last_unit=summary, totals=dict(totals))
            if rep.fatal:
                stop = ("fatal", rep.fatal, FATAL_S)
                break
            if rep.unreachable:
                stop = ("unreachable", rep.unreachable, UNREACHABLE_S)
                break
        hb.update(current=None)
        if stop:
            state, note, wait_s = stop
            hb.update(state=state, note=W.fit(note, 300))
            wait(wait_s, until_paused=True)
        elif claimed == 0 and not control()["paused"]:
            hb.update(state="idle", note="nothing to claim for the analysers switched on")
            wait(IDLE_S, until_paused=True)
    return totals


def loop_main(a) -> int:
    hb = Heartbeat({"state": "starting", "worker_version": W.WORKER_VERSION, "server": a.api,
                    "started_at": S.now_iso(), "totals": {}, "last_unit": None,
                    "current": None, "note": ""}).start()
    all_plugins = [make_plugin(n) for n in (a.analyzer or sorted(PLUGINS))]
    cache = {"t": -1e18, "plugins": [], "version": None}

    def supported():
        # Re-read the server's capabilities now and then: a deploy can add `window`
        # (frame_difference) while this runs. Keep the last list if the read fails.
        if time.monotonic() - cache["t"] >= RECHECK_S:
            try:
                oa = json.load(urllib.request.urlopen(f"{a.api}/openapi.json", timeout=10))
                cache["plugins"] = [p for p in all_plugins
                                    if not getattr(p, "supported_by", lambda _o: None)(oa)]
                cache["version"] = oa.get("info", {}).get("version")
                hb.update(server_version=cache["version"],
                          skipped=[p.name for p in all_plugins if p not in cache["plugins"]])
            except Exception:
                pass
            cache["t"] = time.monotonic()
        return cache["plugins"]

    try:
        while True:
            # Preconditions, re-checked rather than fatal-and-exit: a service that dies
            # on a missing token restarts every few seconds and says nothing useful.
            tok = read_token()
            problem = None
            if not tok:
                problem = f"no STATION_TOKEN in {CONF}"
            else:
                try:
                    P.ffmpeg_exe()
                except RuntimeError as e:
                    problem = f"this station cannot decode: {e}"
            if problem:
                hb.update(state="fatal", note=problem)
                time.sleep(FATAL_S)
                continue
            client = W.HttpLabsClient(a.api, tok)
            scan_loop(client, supported, decode=decode, hb=hb, passes=None)
    except KeyboardInterrupt:
        pass
    finally:
        hb.stop(state="stopped", current=None, note="the worker was stopped")
    return 0


def control_main(a) -> int:
    if a.status:
        for name in (S.CONTROL, S.STATUS):
            p = os.path.join(S.state_dir(), name)
            print(f"== {p}")
            try:
                print(open(p, encoding="utf-8").read().strip())
            except FileNotFoundError:
                print("(absent)")
        return 0
    cur = S.read_control()
    paused = cur["paused"] if a.pause is None else a.pause
    ch = None if a.camera_health is None else (a.camera_health == "on")
    doc = S.write_control(paused, camera_health=ch, by="cli")
    print(json.dumps(doc))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default=os.environ.get("WT_API", "http://127.0.0.1:8000"))
    ap.add_argument("--analyzer", action="append", choices=sorted(PLUGINS),
                    help="repeatable; default: illumination")
    ap.add_argument("--live", action="store_true",
                    help="actually CLAIM and SUBMIT. Without it nothing is written.")
    ap.add_argument("--units", type=int, default=1, help="claim this many per analyser (live)")
    ap.add_argument("--loop", action="store_true",
                    help="station scanning: run until stopped, obeying the control file "
                         "(starts PAUSED unless it says otherwise). Implies --live.")
    ap.add_argument("--pause", dest="pause", action="store_const", const=True, default=None,
                    help="pause this station's scanning (writes the control file) and exit")
    ap.add_argument("--resume", dest="pause", action="store_const", const=False,
                    help="resume this station's scanning and exit")
    ap.add_argument("--camera-health", choices=("on", "off"),
                    help="opt THIS station in or out of camera_health (one station only)")
    ap.add_argument("--status", action="store_true", help="print the control and status files")
    a = ap.parse_args()
    if a.status or a.pause is not None or a.camera_health is not None:
        return control_main(a)
    names = a.analyzer or ["illumination"]
    P.pin_opencv_threads()          # before ANY analyser runs; see its docstring
    # The analysers' own WARNINGs (a decoder that failed, and why) go to stderr as
    # they happen; the worker also appends the last one to a failed unit's reason.
    logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    if a.loop:
        return loop_main(a)

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
    plugins = [make_plugin(n) for n in names]
    t0 = time.time()
    rep = W.run_once(client, plugins, decode=decode, states={}, claim_limit=a.units)
    print(f"claimed {rep.claimed}  submitted {rep.submitted}  abandoned {rep.abandoned}  "
          f"in {time.time()-t0:.1f}s")
    for o in rep.outcomes:
        print(f"  {o.unit.analyzer:14s} {o.unit.camera_id:24s} {o.unit.hour_start}  "
              f"segs={o.segments_scanned} obs={o.observations} submitted={o.submitted}"
              + (f" gone={o.skipped_segments}" if o.skipped_segments else "")
              + (f" undecodable={o.undecodable_segments}" if o.undecodable_segments else "")
              + (f"  [{o.action.value}: {o.note}]" if o.action else (f"  [{o.note}]" if o.note else "")))
        if o.timings:
            print("      " + "  ".join(f"{k[:-2]} {v:.2f}s" for k, v in o.timings.items()))
    if rep.stopped_analysers:
        print("stopped (operator disabled):", ", ".join(rep.stopped_analysers))
    if rep.unreachable:
        sys.exit(f"UNREACHABLE (the server did not answer; try again later): {rep.unreachable}")
    if rep.fatal:
        sys.exit(f"FATAL (this station cannot work until fixed): {rep.fatal}")


if __name__ == "__main__":
    sys.exit(main())
