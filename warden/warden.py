#!/usr/bin/env python3
"""wt-warden — supervisor, crash collector, and uploader for Cilex Watchtower.

Warden is the PARENT process of Watchtower (both platforms — plan CW-06): it
spawns the app, restarts it on death (~2 s, guard's screen first), turns each
death into a forensic bundle (CW-09/10), and ships bundles to Cilex Vision over
the frozen two-PUT contract (CW-11; letters 2026-07-26-client-crash-report-
ingest*.md). stdlib only, deliberately boring: guard boxes are frozen at
install, so the smarts stay server-side and in the analysis tooling.

Subcommands:
  run             supervise + collect + upload (the service entry point)
  bundle-now      mint a `manual` report from the current flight-recorder state
  export DEST     copy pending+sent bundles to DEST (the USB path, CW-12)
  reimport DIR    re-upload bundles found in DIR (dedup is server-side: the
                  ~2 KB manifest PUT answers bundle_state=stored -> skip)
  status          one-line spool/station summary

Config: /etc/watchtower-warden.conf then ~/.config/watchtower-warden/warden.conf
(KEY=VALUE lines), env WT_WARDEN_* overrides. See warden.conf.example.
"""
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

WARDEN_VERSION = "1.1.0"          # 1.1: dead-man heartbeat (CW-19 client half)
SCHEMA = 1

# ---------------------------------------------------------------- config

DEFAULTS = {
    "BACKEND_URL": "http://192.168.1.79:8000",
    "STATION_TOKEN": "",                # X-Cilex-Station-Token (TOFU bootstrap secret)
    "APP_CMD": "",                      # e.g. /home/user/projects/cilex-watchtower/run.sh
    "APP_ENV": "",                      # extra env, comma-separated K=V
    "DATA_DIR": "",                     # app data dir (flightrec/, crash/); auto if empty
    "WARDEN_DIR": "",                   # spool home; default ~/.local/share/watchtower-warden
    "HANG_S": "120",                    # flightrec silence -> hang (MEMTEL ticks every 30 s)
    "MAX_BUNDLE_MB": "512",             # CV contract: refused above this (413)
    "LOOP_WINDOW_S": "600",             # minting policy (reply4, contractual)
    "LOOP_SINGLES": "3",
    "LOOP_QUIET_S": "1800",
    "MANIFEST_PUT_MIN_S": "60",
    "SENT_KEEP_DAYS": "14",
    # CW-13 (decided in 2026-07-27-warden-dead-man-heartbeat.md §8): the alarm
    # channel IS the server (Prometheus→Alertmanager→ntfy, fed by the heartbeat).
    # ALARM_CMD ships EMPTY by design — it is a per-site escalation hook wired by
    # installers (local relay, GPIO buzzer…), never a product behaviour.
    "ALARM_CMD": "",
    "HEARTBEAT_S": "60",                # CW-19 contract cadence (server stale window 180 s)
}


def load_config():
    cfg = dict(DEFAULTS)
    for p in ("/etc/watchtower-warden.conf",
              str(Path.home() / ".config/watchtower-warden/warden.conf")):
        try:
            for line in Path(p).read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip()
        except OSError:
            pass
    for k in cfg:
        cfg[k] = os.environ.get("WT_WARDEN_" + k, cfg[k])
    if not cfg["DATA_DIR"]:
        cfg["DATA_DIR"] = str(Path.home() / ".local/share/Cilex Vision/Watchtower")
    if not cfg["WARDEN_DIR"]:
        cfg["WARDEN_DIR"] = str(Path.home() / ".local/share/watchtower-warden")
    return cfg


CFG = load_config()
W = Path(CFG["WARDEN_DIR"])
PENDING, SENT, QUAR, CONSOLE = W / "pending", W / "sent", W / "quarantine", W / "console"
DATA = Path(CFG["DATA_DIR"])
CRASH, FLTREC = DATA / "crash", DATA / "flightrec"


def log(msg):
    print(f"[warden] {time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}", flush=True)


def alarm(kind, text):
    # CW-13 (channel TBD): loud log line now; ALARM_CMD hook so the operator
    # channel can be wired later WITHOUT touching frozen guard boxes.
    log(f"ALARM [{kind}] {text}")
    if CFG["ALARM_CMD"]:
        try:
            subprocess.Popen([CFG["ALARM_CMD"], kind, text],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            log(f"alarm hook failed: {e}")


def machine_id_hash():
    for p in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        try:
            mid = Path(p).read_text().strip()
            return "sha256:" + hashlib.sha256(mid.encode()).hexdigest()
        except OSError:
            continue
    return ""


def core_pattern_ok():
    """True when kernel cores will actually land in our crash dir. On stock
    Ubuntu, apport owns kernel.core_pattern (a `|pipe`), which silently makes
    core-writing a no-op for us — CV's reply6 spotted exactly that in the first
    five bundles. The gap must be self-announcing: annotated in every manifest
    (a core-less bundle then explains itself server-side) and alarmed once at
    startup. Fix on a box: sudo warden/setup-root.sh."""
    try:
        pat = Path("/proc/sys/kernel/core_pattern").read_text().strip()
    except OSError:
        return False, ""
    return pat.startswith(str(CRASH)), pat


def os_facts():
    ok, pat = core_pattern_ok()
    facts = {"host": socket.gethostname(), "machine_id_hash": machine_id_hash(),
             "os": "", "kernel": "", "display": os.environ.get(
                 "XDG_SESSION_TYPE", "wayland" if os.environ.get("WAYLAND_DISPLAY") else ""),
             "cores_available": ok, "core_pattern": pat[:120]}
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if line.startswith("PRETTY_NAME="):
                facts["os"] = line.split("=", 1)[1].strip('"')
    except OSError:
        pass
    try:
        facts["kernel"] = os.uname().release
    except OSError:
        pass
    return facts


# ---------------------------------------------------------------- collection

SCRUB = re.compile(rb"access_token=[^\s;\"']+")


def scrubbed(path: Path, cap: int) -> bytes:
    data = path.read_bytes()
    if len(data) > cap:
        data = data[-cap:]                      # tails matter: the crash is at the end
    return SCRUB.sub(b"access_token=REDACTED", data)


def parse_marker(path: Path):
    """First line JSON header, rest raw backtrace (FlightRecorder CW-03)."""
    try:
        lines = path.read_text(errors="replace").splitlines()
        head = json.loads(lines[0])
        head["backtrace"] = "\n".join(lines[1:])[:8192]
        return head
    except (OSError, json.JSONDecodeError, IndexError):
        return None


TRIG = {11: "sigsegv", 6: "sigabrt", 7: "sigbus", 8: "sigfpe", 9: "sigkill"}


def build_manifest(report_id, trigger, head, extra=None):
    app_facts = {"build": head.get("build", "unknown"), "qt": head.get("qt", ""),
                 "warden": WARDEN_VERSION}
    m = {
        "schema": SCHEMA, "report_id": report_id,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "station": os_facts(), "app": app_facts, "trigger": trigger,
        "crashed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                    time.gmtime(head.get("epoch", time.time()))),
        "uptime_s": head.get("uptime_s"), "rss_mb": head.get("rss_mb"),
        "signal": head.get("signal"), "backtrace": head.get("backtrace", ""),
    }
    if extra:
        m.update(extra)
    return m


def package(report_dir: Path, manifest: dict, artifacts: list):
    """(Re)write manifest.json + bundle.tar.gz in report_dir. artifacts =
    [(arcname, source_path_or_bytes)]. Applies the size cap; a dropped core is
    recorded in the manifest (last-write-wins re-PUT carries the change)."""
    cap = int(CFG["MAX_BUNDLE_MB"]) * 1024 * 1024
    names = []
    bundle = report_dir / "bundle.tar.gz"
    with tarfile.open(bundle, "w:gz") as tar:
        def add_bytes(name, data):
            import io
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            ti.mtime = int(time.time())
            tar.addfile(ti, io.BytesIO(data))
            names.append(name)

        add_bytes("manifest.json", json.dumps(manifest, indent=1).encode())
        for arc, src in artifacts:
            try:
                if isinstance(src, bytes):
                    add_bytes(arc, src)
                elif src.exists():
                    if src.stat().st_size > cap:            # oversized raw (a core)
                        manifest.setdefault("notes", []).append(
                            f"{arc} truncated from {src.stat().st_size} bytes")
                        with src.open("rb") as f:
                            add_bytes(arc + ".trunc", f.read(cap))
                    else:
                        tar.add(str(src), arcname=arc)
                        names.append(arc)
            except OSError as e:
                log(f"package: skipping {arc}: {e}")
    manifest["artifacts"] = names
    manifest["bundle_bytes"] = bundle.stat().st_size
    (report_dir / "manifest.json").write_text(json.dumps(manifest, indent=1))
    return bundle


def collect(report_id, trigger, head, console_file, marker_path=None, core=None):
    """Marker (or synthesized head) -> a pending/<report_id>/ spool entry.
    Idempotent: an existing entry is left alone (boot replay re-runs this)."""
    rd = PENDING / report_id
    if rd.exists() or (SENT / report_id).exists() or (QUAR / report_id).exists():
        return None
    rd.mkdir(parents=True)
    manifest = build_manifest(report_id, trigger, head)
    arts = []
    if marker_path and marker_path.exists():
        arts.append(("marker.json", scrubbed(marker_path, 64 * 1024)))
    for f in sorted(FLTREC.glob("watchtower.log*")) if FLTREC.exists() else []:
        arts.append((f"flightrec/{f.name}", scrubbed(f, 12 * 1024 * 1024)))
    for name in ("modules.txt", "maps.txt"):
        f = FLTREC / name
        if f.exists():
            arts.append((f"flightrec/{name}", scrubbed(f, 4 * 1024 * 1024)))
    if console_file and console_file.exists():
        arts.append(("console.log", scrubbed(console_file, 2 * 1024 * 1024)))
    if core and core.exists():
        arts.append((f"core/{core.name}", core))
    # Windows analogue of cores_available (CV reply² §3d): the in-app exception
    # filter writes crash/minidump-<report_id>.dmp (CW-04). A bundle that explains
    # its own gaps beats a thread nobody remembers — so the station block says
    # whether the dump was written, and the .dmp ships when it exists. Harmless
    # no-op on Linux (the file never exists there).
    dump = CRASH / f"minidump-{report_id}.dmp"
    if sys.platform == "win32" or dump.exists():
        manifest["station"]["minidump_written"] = dump.exists()
    if dump.exists():
        arts.append((f"minidump/{dump.name}", dump))
    package(rd, manifest, arts)
    if dump.exists():
        dump.rename(rd / "minidump.consumed.dmp")   # consumed like markers: no double-collect
    (rd / "state.json").write_text(json.dumps(
        {"phase": "manifest", "attempts": 0, "next_retry": 0}))
    if marker_path and marker_path.exists():
        marker_path.rename(rd / "marker.consumed.json")     # consume: boot replay key
    log(f"collected report={report_id} trigger={trigger} "
        f"bundle={manifest['bundle_bytes']}B")
    return rd


def find_core(death_ts, pid):
    """A core matching this death in the crash dir (setup-root.sh core_pattern
    core-%e-%t-%P) — or None; collection is complete without one."""
    best = None
    if not CRASH.exists():
        return None
    for c in CRASH.glob("core*"):
        try:
            st = c.stat()
        except OSError:
            continue
        if abs(st.st_mtime - death_ts) < 60 and (pid is None or str(pid) in c.name):
            if best is None or st.st_mtime > best.stat().st_mtime:
                best = c
    return best


# ---------------------------------------------------------------- heartbeat

# Shared, GIL-safe state. HB is written by the Supervisor (app lifecycle) and
# read by the heartbeat thread; CONTACT is touched by both HTTP paths.
HB = {"app_state": "stopped_expected", "app_state_reason": "warden_stopping",
      "app_pid": None, "app_spawned": None, "backoff_s": 1, "loop_open": False,
      "deaths_1h": [], "warden_started": time.time()}
CONTACT = {"last_ok": None, "unreachable_since": None}


def contact_ok():
    """Any 2xx from the backend (ingest ack or heartbeat). unreachable_since is
    cleared only AFTER it has ridden one successful heartbeat (see payload) —
    the retroactive marker CV asked for in the CW-13 letter §8: the first beat
    after a network gap must still carry when the gap began, so silence gets
    attributed to the network instead of a dead Warden."""
    CONTACT["last_ok"] = time.time()


def contact_failed():
    if CONTACT["unreachable_since"] is None:
        CONTACT["unreachable_since"] = time.time()


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts)) if ts else None


class Heartbeat(threading.Thread):
    """CW-19 client half (contract: 2026-07-27-warden-dead-man-heartbeat.md §3).
    Rules encoded from that letter: NEVER spooled, never counted against upload
    pacing, fire-and-forget with a short timeout, and sent whether or not the
    app is running — a beat saying 'stopped on purpose' is what keeps the
    server quiet; silence is what alarms."""
    daemon = True

    def __init__(self):
        super().__init__(name="heartbeat")
        self.stale_after = 180.0

    def payload(self):
        now = time.time()
        HB["deaths_1h"] = [t for t in HB["deaths_1h"] if now - t < 3600]
        pend = list(PENDING.iterdir()) if PENDING.exists() else []
        oldest = min((p.stat().st_mtime for p in pend), default=None)
        facts = os_facts()
        p = {
            "machine_id_hash": facts["machine_id_hash"],
            "station": {"host": facts["host"], "machine_id_hash": facts["machine_id_hash"]},
            "warden_version": WARDEN_VERSION,
            "warden_started_at": iso(HB["warden_started"]),
            "app_state": HB["app_state"],
            "app_state_reason": HB["app_state_reason"],
            "app_pid": HB["app_pid"],
            "app_uptime_s": int(now - HB["app_spawned"]) if HB["app_spawned"] else None,
            "restarts_1h": len(HB["deaths_1h"]),
            "backoff_s": HB["backoff_s"],
            "loop_open": HB["loop_open"],
            "flightrec_age_s": None,
            "cores_available": facts.get("cores_available", False),
            "spool": {"pending": len(pend),
                      "sent": len(list(SENT.iterdir())) if SENT.exists() else 0,
                      "quarantine": len(list(QUAR.iterdir())) if QUAR.exists() else 0,
                      "oldest_pending_age_s": int(now - oldest) if oldest else None},
            "upload_frozen": UPLOAD_FROZEN.get("frozen", False),
            "spool_free_mb": int(shutil.disk_usage(str(W)).free / (1024 * 1024)),
            "last_successful_contact_at": iso(CONTACT["last_ok"]),
            "backend_unreachable_since": iso(CONTACT["unreachable_since"]),
        }
        try:
            p["flightrec_age_s"] = int(now - (FLTREC / "watchtower.log").stat().st_mtime)
        except OSError:
            pass
        return p

    def send(self):
        gap_being_reported = CONTACT["unreachable_since"]
        req = urllib.request.Request(
            CFG["BACKEND_URL"] + "/client/stations/heartbeat",
            data=json.dumps(self.payload()).encode(), method="POST",
            headers={"Content-Type": "application/json",
                     "X-Cilex-Station-Token": CFG["STATION_TOKEN"]})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                body = json.loads(r.read().decode() or "{}")
                contact_ok()
                if gap_being_reported:
                    # The gap has now been reported once post-recovery — clear it.
                    CONTACT["unreachable_since"] = None
                    log(f"heartbeat: backend reachable again (gap since "
                        f"{iso(gap_being_reported)} reported)")
                sa = body.get("stale_after_s")
                if sa:
                    self.stale_after = float(sa)
                return True
        except (urllib.error.URLError, urllib.error.HTTPError, OSError,
                json.JSONDecodeError) as e:
            contact_failed()
            return False

    def run(self):
        first = True
        while True:
            if CFG["STATION_TOKEN"]:
                ok = self.send()
                if first and ok:
                    log(f"heartbeat: first beat accepted (stale_after={self.stale_after}s) "
                        f"— station monitoring is now ARMED server-side, permanently")
                    first = False
            # Contract cadence 60 s; never slower than a third of the server's
            # stale window even if the server widens it.
            time.sleep(min(int(CFG["HEARTBEAT_S"]), max(20, int(self.stale_after / 3))))


UPLOAD_FROZEN = {"frozen": False}

# ---------------------------------------------------------------- uploader

class Uploader(threading.Thread):
    """One report in flight at a time (contract: 1/station). State machine per
    reply letters: manifest PUT -> (skip on stored) bundle PUT -> sent/."""
    daemon = True

    def __init__(self):
        super().__init__(name="uploader")

    @property
    def frozen(self):
        return UPLOAD_FROZEN["frozen"]   # shared with the heartbeat (upload_frozen field)

    @frozen.setter
    def frozen(self, v):
        UPLOAD_FROZEN["frozen"] = v

    def put(self, path, data, ctype, timeout):
        req = urllib.request.Request(
            CFG["BACKEND_URL"] + path, data=data, method="PUT",
            headers={"Content-Type": ctype,
                     "X-Cilex-Station-Token": CFG["STATION_TOKEN"]})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                contact_ok()
                return r.status, json.loads(r.read().decode() or "{}"), {}
        except urllib.error.HTTPError as e:
            contact_ok()                 # an HTTP status IS the backend answering
            hdrs = {k.lower(): v for k, v in e.headers.items()}
            try:
                body = json.loads(e.read().decode() or "{}")
            except (json.JSONDecodeError, OSError):
                body = {}
            return e.code, body, hdrs
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
            contact_failed()
            return -1, {"error": str(e)}, {}

    def run(self):
        while True:
            time.sleep(3)
            if self.frozen or not CFG["STATION_TOKEN"]:
                continue
            now = time.time()
            for rd in sorted(PENDING.iterdir()) if PENDING.exists() else []:
                st_file = rd / "state.json"
                try:
                    st = json.loads(st_file.read_text())
                except (OSError, json.JSONDecodeError):
                    continue
                if st.get("next_retry", 0) > now:
                    continue
                self.advance(rd, st)
                break                     # one at a time, contract rate

    def backoff(self, rd, st, retry_after=None):
        st["attempts"] = st.get("attempts", 0) + 1
        delay = retry_after or min(60 * (2 ** min(st["attempts"], 6)), 3600)
        st["next_retry"] = time.time() + delay
        (rd / "state.json").write_text(json.dumps(st))

    def finish(self, rd, dest, why):
        dest.mkdir(exist_ok=True)
        target = dest / rd.name
        if target.exists():
            shutil.rmtree(str(rd))
        else:
            rd.rename(target)
        log(f"report {rd.name} -> {dest.name}/ ({why})")

    def advance(self, rd, st):
        rid = rd.name
        if st["phase"] == "manifest":
            code, body, hdrs = self.put(f"/client/reports/{rid}",
                                        (rd / "manifest.json").read_bytes(),
                                        "application/json", 30)
            log(f"manifest PUT {rid} -> {code} bundle_state={body.get('bundle_state')}")
            if code in (200, 201):
                if body.get("bundle_state") == "stored":
                    self.finish(rd, SENT, "bundle already held")   # USB re-import dedup
                    return
                st["phase"] = "bundle"
                st["attempts"] = 0
                st["next_retry"] = 0
                (rd / "state.json").write_text(json.dumps(st))
            elif code == 400:
                alarm("upload-400", f"deterministic reject of manifest {rid} — warden bug")
                self.finish(rd, QUAR, "400")
            elif code == 401:
                self.frozen = True
                alarm("upload-401", f"station token refused ({body.get('detail', '')}) "
                                    f"— uploads FROZEN, nothing deleted")
            elif code == 403:
                alarm("upload-403", f"{rid} belongs to another station?! spool corruption")
                self.finish(rd, QUAR, "403")
            elif code == 429 or code == 503:
                self.backoff(rd, st, int(hdrs.get("retry-after", 0)) or None)
            else:
                self.backoff(rd, st)
        elif st["phase"] == "bundle":
            code, body, hdrs = self.put(f"/client/reports/{rid}/bundle",
                                        (rd / "bundle.tar.gz").read_bytes(),
                                        "application/gzip", 600)
            log(f"bundle PUT {rid} -> {code} state={body.get('bundle_state')} "
                f"dup={body.get('duplicate')}")
            if code in (200, 201):
                self.finish(rd, SENT, "stored")
            elif code == 409:              # manifest lost server-side? replay it
                st["phase"] = "manifest"
                (rd / "state.json").write_text(json.dumps(st))
            elif code == 413:
                # Rebuild without the core (degenerate truncation), re-PUT the
                # manifest too — last-write-wins records the smaller artifact set.
                alarm("upload-413", f"{rid} over the size cap — repacking without core")
                self.strip_core(rd)
                st["phase"] = "manifest"
                st["attempts"] = 0
                (rd / "state.json").write_text(json.dumps(st))
            elif code == 400:
                alarm("upload-400", f"deterministic reject of bundle {rid}")
                self.finish(rd, QUAR, "400")
            elif code == 401:
                self.frozen = True
                alarm("upload-401", "station token refused — uploads FROZEN")
            elif code == 403:
                alarm("upload-403", f"bundle {rid} cross-station?!")
                self.finish(rd, QUAR, "403")
            elif code == 429 or code == 503:
                self.backoff(rd, st, int(hdrs.get("retry-after", 0)) or None)
            else:
                self.backoff(rd, st)

    def strip_core(self, rd):
        manifest = json.loads((rd / "manifest.json").read_text())
        manifest.setdefault("notes", []).append("core dropped after 413")
        arts = []
        with tarfile.open(rd / "bundle.tar.gz", "r:gz") as tar:
            for m in tar.getmembers():
                if m.name.startswith("core/") or m.name == "manifest.json":
                    continue
                arts.append((m.name, tar.extractfile(m).read()))
        package(rd, manifest, arts)


# ---------------------------------------------------------------- supervisor

class Supervisor:
    def __init__(self):
        self.deaths = []                 # timestamps, minting-policy window
        self.loop_id = None              # open restart-loop report id
        self.loop_count = 0
        self.loop_first = 0
        self.loop_last_put = 0
        self.backoff_idx = 0
        self.stopping = False

    def app_env(self):
        env = dict(os.environ)
        for kv in CFG["APP_ENV"].split(","):
            if "=" in kv:
                k, v = kv.split("=", 1)
                env[k.strip()] = v.strip()
        return env

    def spawn(self):
        CONSOLE.mkdir(parents=True, exist_ok=True)
        for old in sorted(CONSOLE.glob("console-*.log"))[:-5]:
            old.unlink(missing_ok=True)
        out = CONSOLE / f"console-{int(time.time())}.log"
        with out.open("wb") as fh:       # Popen dups the fd; don't leak ours per spawn
            proc = subprocess.Popen(
                [CFG["APP_CMD"]], env=self.app_env(),
                stdout=fh, stderr=subprocess.STDOUT,
                start_new_session=True)  # our SIGTERM never reaches the child implicitly
        log(f"spawned watchtower pid={proc.pid} console={out.name}")
        HB.update(app_state="running", app_state_reason=None,
                  app_pid=proc.pid, app_spawned=time.time())
        return proc, out

    def flightrec_age(self):
        try:
            return time.time() - (FLTREC / "watchtower.log").stat().st_mtime
        except OSError:
            return 0

    def watch(self, proc):
        """Wait for death; SIGABRT a hung child (flightrec silence — CW-08 outer
        net; the in-app watchdog usually fires first)."""
        hang_s = int(CFG["HANG_S"])
        while True:
            try:
                proc.wait(timeout=10)
                return "died"
            except subprocess.TimeoutExpired:
                # Housekeeping while healthy: a loop must close on QUIET TIME, not
                # only on the next death — otherwise a crash hours later would fold
                # into a stale loop report instead of minting its own.
                self.loop_tick()
            if self.stopping:
                proc.terminate()
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    proc.kill()
                return "stopped"
            if hang_s > 0 and self.flightrec_age() > hang_s:
                alarm("hang", f"flightrec silent {int(self.flightrec_age())}s — "
                              f"SIGABRT pid={proc.pid} for a marked crash")
                try:
                    proc.send_signal(signal.SIGABRT)
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.send_signal(signal.SIGCONT)   # in case it was STOPped
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                return "hung"

    # Explicit shutdown intent (heartbeat-contract §4: "a marker is the truth").
    # The app writes crash/shutdown-intent on Window.onClosing (the guard's close
    # button / compositor close); a fresh marker turns an exit into operator_quit.
    def consume_quit_marker(self, spawn_ts):
        f = CRASH / "shutdown-intent"
        try:
            if f.exists() and f.stat().st_mtime >= spawn_ts - 1:
                f.unlink()
                return True
            f.unlink(missing_ok=True)    # stale marker from an older run — discard
        except OSError:
            pass
        return False

    def death_facts(self, proc, spawn_ts, hung):
        rc = proc.returncode
        sig = -rc if rc is not None and rc < 0 else None
        head = {"epoch": int(time.time()), "uptime_s": int(time.time() - spawn_ts),
                "signal": sig, "build": "unknown", "qt": ""}
        marker = None
        if CRASH.exists():
            fresh = [m for m in CRASH.glob("marker-*.json")
                     if m.stat().st_mtime >= spawn_ts - 1]
            if fresh:
                marker = max(fresh, key=lambda m: m.stat().st_mtime)
                parsed = parse_marker(marker)
                if parsed:
                    head = parsed
        if hung:
            trigger = "hang-watchdog"
        elif sig is not None:
            trigger = TRIG.get(sig, f"signal-{sig}")
        else:
            trigger = f"exit-{rc}"
        return trigger, head, marker

    def mint(self, trigger, head, marker, console, death_ts, pid):
        """Reply4 minting policy: <=LOOP_SINGLES singles per rolling window, then
        ONE restart-loop report updated by manifest re-PUTs (no new rows)."""
        win = int(CFG["LOOP_WINDOW_S"])
        self.deaths = [t for t in self.deaths if death_ts - t < win] + [death_ts]
        core = find_core(death_ts, pid)
        if len(self.deaths) <= int(CFG["LOOP_SINGLES"]) and self.loop_id is None:
            rid = (head.get("report_id") or str(uuid.uuid4()))
            collect(rid, trigger, head, console, marker, core)
            return
        if self.loop_id is None:
            self.loop_id = str(uuid.uuid4())
            self.loop_count = len(self.deaths)      # absorbs the window's deaths
            self.loop_first = self.deaths[0]
            log(f"restart-loop OPEN report={self.loop_id} (deaths={self.loop_count})")
            collect(self.loop_id, "restart-loop", head, console, marker, core)
        else:
            self.loop_count += 1
            # Consume the folded death's marker (CW-15 endurance finding F2): an
            # unconsumed marker gets boot-replayed as a FRESH single after a
            # warden restart — double-counting a death the loop report already
            # owns. Filed into the loop's report dir, it becomes evidence instead.
            if marker and marker.exists():
                for base in (PENDING, SENT):
                    rd = base / self.loop_id
                    if rd.exists():
                        marker.rename(rd / f"marker.death-{self.loop_count}.json")
                        break
                else:
                    marker.rename(marker.with_suffix(".consumed"))
        self.update_loop(head, trigger)

    def update_loop(self, head, last_trigger):
        """Coalesced (>=60 s apart) manifest refresh of the open loop report."""
        rd = None
        for base in (PENDING, SENT):
            if (base / self.loop_id).exists():
                rd = base / self.loop_id
                break
        if rd is None:
            return
        if time.time() - self.loop_last_put < int(CFG["MANIFEST_PUT_MIN_S"]):
            return
        self.loop_last_put = time.time()
        try:
            manifest = json.loads((rd / "manifest.json").read_text())
        except (OSError, json.JSONDecodeError):
            return
        manifest["loop"] = {"deaths": self.loop_count,
                            "first": time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                                   time.gmtime(self.loop_first)),
                            "last_trigger": last_trigger}
        manifest["backtrace"] = head.get("backtrace", manifest.get("backtrace", ""))
        (rd / "manifest.json").write_text(json.dumps(manifest, indent=1))
        if rd.parent == SENT:            # already uploaded once -> re-PUT the update
            rd.rename(PENDING / rd.name)
            rd = PENDING / rd.name
        st = {"phase": "manifest", "attempts": 0, "next_retry": 0}
        (rd / "state.json").write_text(json.dumps(st))

    def loop_tick(self):
        if self.loop_id and self.deaths and \
                time.time() - self.deaths[-1] > int(CFG["LOOP_QUIET_S"]):
            log(f"restart-loop CLOSED report={self.loop_id} deaths={self.loop_count}")
            self.loop_id = None
            self.loop_count = 0
            self.deaths = []

    def boot_replay(self):
        """Markers left by a run Warden never saw die (guard power-cycled)."""
        if not CRASH.exists():
            return
        for m in sorted(CRASH.glob("marker-*.json")):
            head = parse_marker(m)
            if not head:
                m.rename(m.with_suffix(".unparsed"))
                continue
            rid = head.get("report_id") or str(uuid.uuid4())
            trigger = TRIG.get(head.get("signal"), "signal-unknown")
            log(f"boot replay: marker {m.name} -> report {rid}")
            self.mint_replay(rid, trigger, head, m)

    def mint_replay(self, rid, trigger, head, marker):
        self.deaths = [t for t in self.deaths
                       if time.time() - t < int(CFG["LOOP_WINDOW_S"])] + [time.time()]
        collect(rid, trigger, head, None, marker,
                find_core(head.get("epoch", 0), head.get("pid")))

    def run(self):
        for d in (PENDING, SENT, QUAR, CONSOLE):
            d.mkdir(parents=True, exist_ok=True)
        if not CFG["APP_CMD"]:
            log("FATAL: APP_CMD not configured")
            return 2
        signal.signal(signal.SIGTERM, lambda *_: setattr(self, "stopping", True))
        signal.signal(signal.SIGINT, lambda *_: setattr(self, "stopping", True))
        ok, pat = core_pattern_ok()
        if not ok:
            alarm("no-cores", f"kernel.core_pattern is '{pat[:80]}' — crash bundles "
                              f"will carry NO core (backtrace+logs only). "
                              f"Fix: sudo warden/setup-root.sh")
        self.boot_replay()
        Uploader().start()
        hb = Heartbeat()
        hb.start()
        prune_sent()
        while not self.stopping:
            spawn_ts = time.time()
            proc, console = self.spawn()
            why = self.watch(proc)
            if why == "stopped":
                log("supervisor stopping (SIGTERM) — no report for a clean stop")
                break
            death_ts = time.time()
            trigger, head, marker = self.death_facts(proc, spawn_ts, why == "hung")
            alive_s = death_ts - spawn_ts
            HB["deaths_1h"].append(death_ts)
            operator_quit = trigger == "exit-0" and self.consume_quit_marker(spawn_ts)
            if trigger == "exit-0":
                # Heartbeat intent (§4): exit 0 reads as deliberate — with the
                # app's shutdown-intent marker as the stronger truth when present.
                HB.update(app_state="stopped_expected", app_state_reason="operator_quit",
                          app_pid=None, app_spawned=None)
                log("clean exit 0 — kiosk restart, no report"
                    + (" (operator quit marker consumed)" if operator_quit else ""))
            else:
                reason = ("restart_loop" if self.loop_id else
                          "killed" if trigger == "sigkill" else
                          "failed_start" if alive_s < 10 else "crashed")
                HB.update(app_state="stopped_unexpected", app_state_reason=reason,
                          app_pid=None, app_spawned=None)
                self.mint(trigger, head, marker, console, death_ts, proc.pid)
            self.loop_tick()
            HB["loop_open"] = self.loop_id is not None
            # Restart backoff: reset after a healthy run, escalate through a loop.
            self.backoff_idx = 0 if alive_s > 120 else min(self.backoff_idx + 1, 4)
            delay = [1, 5, 15, 60, 60][self.backoff_idx] if alive_s <= 120 else 1
            HB["backoff_s"] = delay
            log(f"restart in {delay}s (alive {int(alive_s)}s, cause {trigger})")
            t0 = time.time()
            while time.time() - t0 < delay and not self.stopping:
                time.sleep(0.5)
        # Going down ON PURPOSE (systemd stop / host shutdown): one final beat
        # carrying the intent — this is what keeps the server quiet instead of
        # paging about a dead Warden (the case the whole design bends around).
        HB.update(app_state="stopped_expected", app_state_reason="warden_stopping",
                  app_pid=None, app_spawned=None)
        if CFG["STATION_TOKEN"]:
            hb.send()
            log("final heartbeat sent (stopped_expected/warden_stopping)")
        return 0


def prune_sent():
    cutoff = time.time() - int(CFG["SENT_KEEP_DAYS"]) * 86400
    if SENT.exists():
        for rd in SENT.iterdir():
            try:
                if rd.stat().st_mtime < cutoff:
                    shutil.rmtree(str(rd))
            except OSError:
                pass


# ---------------------------------------------------------------- commands

def cmd_bundle_now():
    head = {"epoch": int(time.time()), "uptime_s": None, "signal": None,
            "build": "unknown", "qt": ""}
    rid = str(uuid.uuid4())
    rd = collect(rid, "manual", head, None, None, None)
    print(rd / "bundle.tar.gz" if rd else "collection failed")


def cmd_export(dest):
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    n = 0
    for base in (PENDING, SENT):
        for rd in base.iterdir() if base.exists() else []:
            tgt = dest / f"report-{rd.name}"
            tgt.mkdir(exist_ok=True)
            for f in ("manifest.json", "bundle.tar.gz"):
                if (rd / f).exists():
                    shutil.copy2(str(rd / f), str(tgt / f))
            n += 1
    print(f"exported {n} report(s) -> {dest}")


def cmd_reimport(src):
    """USB import on a connected box: manifest PUT first — bundle_state=stored
    means the ~512 MB never crosses the wire (contract §2.3)."""
    up = Uploader()
    n = 0
    for mf in Path(src).glob("**/manifest.json"):
        manifest = json.loads(mf.read_text())
        rid = manifest["report_id"]
        code, body, _ = up.put(f"/client/reports/{rid}", mf.read_bytes(),
                               "application/json", 30)
        state = body.get("bundle_state")
        print(f"{rid}: manifest -> {code} bundle_state={state}")
        if code in (200, 201) and state != "stored":
            bundle = mf.parent / "bundle.tar.gz"
            if bundle.exists():
                code, body, _ = up.put(f"/client/reports/{rid}/bundle",
                                       bundle.read_bytes(), "application/gzip", 600)
                print(f"{rid}: bundle -> {code} state={body.get('bundle_state')}")
        n += 1
    print(f"reimport: {n} report(s) processed")


def cmd_status():
    def count(d):
        return len(list(d.iterdir())) if d.exists() else 0
    print(f"warden {WARDEN_VERSION} spool={W} pending={count(PENDING)} "
          f"sent={count(SENT)} quarantine={count(QUAR)} "
          f"backend={CFG['BACKEND_URL']} token={'set' if CFG['STATION_TOKEN'] else 'MISSING'}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "run":
        sys.exit(Supervisor().run())
    elif cmd == "bundle-now":
        cmd_bundle_now()
    elif cmd == "export" and len(sys.argv) > 2:
        cmd_export(sys.argv[2])
    elif cmd == "reimport" and len(sys.argv) > 2:
        cmd_reimport(sys.argv[2])
    elif cmd == "status":
        cmd_status()
    else:
        print(__doc__)
        sys.exit(2)
