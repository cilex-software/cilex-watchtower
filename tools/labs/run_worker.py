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

Since worker-0.3.5 each analyser is a lane of its own (lanes.py) and each unit runs in a
process of its own (unit_proc.py). Since worker-0.3.8 every connected lane runs its unit at
the same time, one per lane, with no station-wide cap: how many run at once is how many
hoses the operator connects (their rule, 2026-09-29). --slots / WT_LABS_SLOTS are ignored.
"""
import argparse, logging, os, sys, threading, time, json, urllib.request
from datetime import datetime, timezone
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import worker as W, plugins as P, frame_source, station as S
import lanes as L

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
           "colour_histogram": P.ColourHistogramPlugin, "track_linking": P.TrackLinkingPlugin,
           "object_profile": P.ObjectProfilePlugin}


def make_plugin(name):
    # camera_health's per-camera Baseline must outlive this process (see its class).
    if name == "camera_health":
        return P.CameraHealthPlugin(state_dir=os.path.join(P.labs_state_dir(), "camera_health"))
    return PLUGINS[name]()


# ----------------------------------------------------------------------------------
# Station scanning: the loop behind --loop
# ----------------------------------------------------------------------------------
FATAL_S = 600.0          # this station cannot work (no token, no ffmpeg): look again in ten minutes
RECHECK_S = 900.0        # re-read the server's capabilities (a deploy can add one)
# cilex-vision 1.0.61 and older hand out the hour STILL IN PROGRESS (routers/labs.py:996,
# `newest_useful = now`, hours newest-first -- measured on the first live unit,
# 2026-09-26): a unit claimed a minute into its hour is labelled from that minute and then
# marked done. Their abccd08 (claim only hours that ended >= 10 min ago) and 84b4cd9
# (camera_health oldest-first) deploy after 1.0.61. Until the station sees a newer server,
# the LOOP claims nothing, whatever the pause flag says, and the Labs screen shows every
# analyser as needing a server update. One-off --live runs are deliberate and unaffected.
MIN_SERVER = (1, 0, 62)


def server_too_old(version) -> bool:
    try:
        return tuple(int(x) for x in str(version).split(".")[:3]) < MIN_SERVER
    except (TypeError, ValueError):
        return True     # a version this cannot read is not evidence of the fix


class Heartbeat:
    """Keeps status.json fresh from its own thread. The main loop can sit inside one
    unit for minutes -- a whole hour of footage -- and without this the app would call
    a working station "not running". Writes are atomic (station._write_atomic)."""

    def __init__(self, base: dict, write=S.write_status, every: float = S.HEARTBEAT_S):
        self.fields = dict(base)
        self._lock = threading.Lock()
        # Writes in ORDER. Each flush copies the fields and then writes; unserialised, a
        # heartbeat that copied "running" could land after stop() wrote "stopped", and
        # the file would say running until it went stale.
        self._wlock = threading.Lock()
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
        # The heartbeat thread first, THEN the last word. The write lock already keeps
        # "stopped" from being overtaken (pinned by a test); the join is what leaves no
        # thread half-way through a write -- a stray .tmp- file -- when the process exits
        # right after this. That second part no test pins.
        self._stop.set()
        if self._thread.is_alive() and threading.current_thread() is not self._thread:
            self._thread.join(timeout=10)
        self.update(**kw)

    def _flush(self):
        with self._wlock:
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


def stop_decoders(unit, why, kill=None, log=None):
    """The reporter's on_abort: kill the unit's decoders at once, and SAY how many.
    cilex-vision's second live test (2026-09-28) could not tell whether a decoder was
    running when its Stop landed, because this count went unlogged."""
    if kill is None:
        import vitals as V
        kill = V.kill_children
    n = kill()
    (log or logging.getLogger("labs.report")).warning(
        "labs: %s decoder process(es) stopped for %s %s %s",
        "an unknown number of (this station cannot list them)" if n is None else n,
        unit.analyzer, unit.camera_id, unit.hour_start)
    return n


unit_summary = L.unit_summary   # moved to lanes.py (worker-0.3.5); the name stays


# Windows NTSTATUS exits that mean a process could not START (not that it failed on input).
_START_FAILURES = {0xC0000142: "STATUS_DLL_INIT_FAILED", 0xC0000135: "STATUS_DLL_NOT_FOUND",
                   0xC000007B: "STATUS_INVALID_IMAGE_FORMAT", 0xC0000022: "STATUS_ACCESS_DENIED"}


def decoder_start_fault(exe=None, run=None, timeout_s: float = 15.0):
    """None when this station can START its decoder; otherwise why not, in words.

    `ffmpeg -version`: no input, no footage, ~50 ms. A decoder that cannot even start is the
    STATION's fault, never the footage's. Measured on the office, 2026-09-29 02:14-02:25 MSK
    (Windows agent): after the worker's console host was killed, every ffmpeg exited
    3221225794 (0xC0000142 STATUS_DLL_INIT_FAILED), and each unit was filed as if its footage
    were bad."""
    import subprocess
    exe = exe or P.ffmpeg_exe()
    run = run or subprocess.run
    try:
        r = run([exe, "-hide_banner", "-version"], capture_output=True, timeout=timeout_s)
    except FileNotFoundError:
        return f"the decoder is not installed here ({exe})"
    except Exception as e:                           # OSError, a timeout: it did not start
        return f"the decoder could not start ({exe}): {type(e).__name__}: {e}"
    if r.returncode != 0:
        code = r.returncode & 0xFFFFFFFF
        name = _START_FAILURES.get(code)
        return (f"the decoder could not start ({exe}): exit {r.returncode}"
                + (f" = 0x{code:08X} {name}" if name else ""))
    return None


def loop_main(a) -> int:
    if a.slots is not None or os.environ.get("WT_LABS_SLOTS"):
        # Said once, where the station's log reads it: a station still set to "2" (or "1")
        # runs every connected lane at once all the same.
        logging.getLogger("labs.station").warning(
            "labs: --slots / WT_LABS_SLOTS are ignored since worker-0.3.8 -- every connected lane "
            "runs its unit at once, one per lane; unplug a hose to run fewer")
    all_plugins = [make_plugin(n) for n in (a.analyzer or sorted(PLUGINS))]
    hb = Heartbeat({"state": "starting", "worker_version": W.WORKER_VERSION, "server": a.api,
                    "started_at": S.now_iso(), "totals": {}, "last_unit": None,
                    "current": None, "note": "",
                    # What this station CAN run (its plugin registry), shown in the Labs
                    # screen whether or not it is scanning right now.
                    "registered": [p.name for p in all_plugins]}).start()
    cache = {"t": -1e18, "plugins": [], "version": None}

    def supported():
        # Re-read the server's capabilities now and then: a deploy can add `window`
        # (frame_difference) while this runs. Keep the last list if the read fails.
        if time.monotonic() - cache["t"] >= RECHECK_S:
            try:
                oa = json.load(urllib.request.urlopen(f"{a.api}/openapi.json", timeout=10))
                cache["version"] = oa.get("info", {}).get("version")
                if server_too_old(cache["version"]):
                    cache["plugins"] = []
                else:
                    cache["plugins"] = [p for p in all_plugins
                                        if not getattr(p, "supported_by", lambda _o: None)(oa)]
                hb.update(server_version=cache["version"],
                          skipped=[p.name for p in all_plugins if p not in cache["plugins"]])
            except Exception:
                pass
            cache["t"] = time.monotonic()
        return cache["plugins"]

    reporter, sched = None, None

    def on_sigterm(_sig, _frame):
        raise KeyboardInterrupt           # systemd's stop: end as a Ctrl-C would, saying "stopped"

    try:
        import signal
        signal.signal(signal.SIGTERM, on_sigterm)
    except (ValueError, OSError, AttributeError):
        pass
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
            # The control plane (cilex-vision, 2026-09-28): report every ~2 s, take the
            # server's orders, drop what it takes back. Against a server without the
            # endpoint it probes once a minute and the local control file governs.
            import vitals as V
            import reporter as RP
            import unit_proc as U
            ask = lambda u: reporter.abort_reason(u) if reporter is not None else None
            # Also asked by _file_failed in THIS process, when a unit it dropped is filed.
            W.STATION_CHECK = decoder_start_fault
            if a.in_process:
                # worker-0.3.4's way, kept for a station that cannot start unit processes:
                # one unit at a time, in this process.
                runner = L.InProcessRunner(client, decode=decode, abort_reason=ask)
            else:
                runner = U.ProcessRunner(
                    U.production_spec(a.api, tok), abort_reason=ask,
                    say_killed=lambda unit, why, n: stop_decoders(unit, why, kill=lambda: n),
                    file_failed=lambda unit, plugin, why: W._file_failed(
                        client, plugin, unit, W.UnitOutcome(unit), why, W.Action.BUG))
            if reporter is None:
                reporter = RP.Reporter(
                    client, vitals=V.Vitals(), worker_version=W.WORKER_VERSION,
                    on_abort=lambda unit, why: sched.abort(unit, why) if sched is not None else None,
                    on_change=lambda snap: hb.update(**snap)).start()
                hb.update(vitals_source=V.source())
            sched = L.Scheduler(client, supported, runner=runner, hb=hb, names=[p.name for p in all_plugins],
                                reporter=reporter, station_check=decoder_start_fault)
            sched.run()
    except KeyboardInterrupt:
        pass
    finally:
        if sched is not None:
            sched.stop()
        if reporter is not None:
            reporter.stop()
        hb.stop(state="stopped", current=None, note="the worker was stopped")
    return 0


def control_main(a) -> int:
    if a.status:
        for name in (S.CONTROL, S.STATUS):
            p = os.path.join(S.state_dir(), name)
            print(f"== {p}")
            try:
                print(S.read_text(p).strip())
            except FileNotFoundError:
                print("(absent)")
        return 0
    if a.hold is not None:
        print(json.dumps(S.write_hold(a.hold, by="cli")))
        return 0
    if a.release:
        print(json.dumps(S.clear_hold(by="cli")))
        return 0
    if a.pause is not None and governed_now():
        # Operator decision 2026-09-28: once the server governs, ITS Start/Pause/Stop are
        # the switch. Writing the local flag now would change nothing -- a silent no-op --
        # so say where the switch is instead. (The wall's safety check uses --hold.)
        print("This station is governed by the server's Labs controls: use Start / Pause / Stop "
              "on the Labs admin page (or the Watchtower Labs screen). Nothing was written.\n"
              "To keep Labs off on THIS computer whatever the server says, use --hold \"why\".",
              file=sys.stderr)
        return 2
    cur = S.read_control()
    paused = cur["paused"] if a.pause is None else a.pause
    ch = None if a.camera_health is None else (a.camera_health == "on")
    doc = S.write_control(paused, camera_health=ch, by="cli")
    print(json.dumps(doc))
    return 0


def governed_now() -> bool:
    """Does the running worker say the server governs? From its status file, and only
    while that file is fresh: a worker that stopped long ago proves nothing."""
    try:
        st = S.read_json(os.path.join(S.state_dir(), S.STATUS))
    except Exception:
        return False
    if not isinstance(st, dict) or st.get("governed") is not True:
        return False
    at = W._hour(st.get("updated_at"))
    return at is not None and (datetime.now(timezone.utc) - at).total_seconds() <= S.STALE_AFTER_S


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
    ap.add_argument("--hold", metavar="WHY",
                    help="hold Labs OFF on this computer whatever the server says, until --release "
                         "(the wall's safety check uses this); reported to the server with WHY")
    ap.add_argument("--release", action="store_true", help="release this computer's hold")
    # Kept so a launcher that still passes it does not stop the worker from starting.
    ap.add_argument("--slots", type=int, default=None,
                    help="IGNORED since worker-0.3.8: every connected lane runs its unit at once, "
                         "one per lane, with no station-wide cap (the operator's rule)")
    ap.add_argument("--in-process", action="store_true",
                    help="--loop: run units in this process, one at a time (worker-0.3.4's way), "
                         "for a station that cannot start unit processes")
    a = ap.parse_args()
    if a.status or a.pause is not None or a.camera_health is not None or a.hold is not None or a.release:
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
    if rep.busy:
        sys.exit(f"BUSY (the server answered but could not serve the claim; try again later): {rep.busy}")
    if rep.unreachable:
        sys.exit(f"UNREACHABLE (the server did not answer; try again later): {rep.unreachable}")
    if rep.fatal:
        sys.exit(f"FATAL (this station cannot work until fixed): {rep.fatal}")


if __name__ == "__main__":
    sys.exit(main())
