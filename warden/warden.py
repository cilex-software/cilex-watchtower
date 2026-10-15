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
import platform
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

# Everything Warden writes — spool, reports, consoles, cores — is private to the
# station account. 0775/0664 was measured on the spool (audit 2026-09-03); a crash
# bundle can hold a session token or a camera URL, so no other account gets to read
# it. Set once, here, so every mkdir/open below inherits it.
os.umask(0o077)
from pathlib import Path

WIN = sys.platform == "win32"
DARWIN = sys.platform == "darwin"
if DARWIN:
    # Also works when tests load warden.py by absolute importlib path. PyInstaller
    # collects this explicit import beside its entry point.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import warden_darwin as darwin

WARDEN_VERSION = "1.5.0"          # 1.1: heartbeat (CW-19) · 1.2: Windows leg (CW-16) · 1.3: cpu_pct/mem_pct · 1.3.1: deeplink_ok · 1.3.2: heartbeat restored (1.3.1 never beat) · 1.4.0: restarts_24h · 1.4.1: uplink{local_addr,via} · 1.4.2: subsystems + app_last_beat_at · 1.4.3: backend from the app, no baked address · 1.4.4: re-reads STATION_TOKEN per beat (the app can enrol a station without a restart) · 1.4.5: single-instance lock (one supervisor per machine) · 1.4.6: app_version on the beat, read from the app's own flight-recorder banner · 1.4.7: WT_WARDEN_TOKEN tells 'rejected' apart from 'set' (presence was never validity) · 1.4.8: WT_MACHINE_KEY, so enrolment upserts the server's existing row instead of forking a duplicate · 1.4.9: a changed STATION_TOKEN unfreezes uploads, so a re-provisioned station actually resumes · 1.4.10: app_version no longer caches a MISS forever (an early read made the field permanently null)
SCHEMA = 1

# ---------------------------------------------------------------- config

DEFAULTS = {
    # EMPTY by design. This carried "http://192.168.1.79:8000" until 2026-09-20 — a host
    # that has not existed for weeks and does not refuse, it times out after 46 s. A default
    # pointing at a dead address is worse than none: Warden posts into a void and says
    # nothing, which is exactly what wt-office-01 did for days. Empty means "ask the app",
    # see app_saved_backend() below: the wall already knows which server it is signed in to,
    # and two places to configure one address is the duplication this removes.
    "BACKEND_URL": "",
    "STATION_TOKEN": "",                # X-Cilex-Station-Token (TOFU bootstrap secret)
    "APP_CMD": "",                      # e.g. /home/user/projects/cilex-watchtower/run.sh
    "LOG_DIR": "",                     # Darwin private rotated diagnostics
    "APP_WORKING_DIR": "",             # literal absolute path; no shell quoting
    "INSTALLATION_ID": "",             # Darwin install/account lock and process records
    "SPAWN_GATE": "",                  # packaged Darwin cilex-spawn-gate executable
    "MAINTENANCE_FILE": "",             # optional private marker; suppress GUI restarts
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


# Where the APP is signed in — the single source of truth for the server address.
#
# Warden used to carry its own BACKEND_URL, separately from the wall's, and the two could
# disagree silently: on wt-office-01 the app talked to .4 while Warden held the installer's
# .79, so every heartbeat fell on the floor while the panel read like confirmation. One
# address, configured once, in the place a human actually sets it.
#
# Reads Qt's QSettings store for organisation "Cilex Vision", application "Watchtower",
# key auth/baseUrl (AuthController.cpp:281 writes it on every accepted session). Native
# format differs per platform, so all three are handled; any failure returns None and the
# caller falls back to an explicit BACKEND_URL.
def app_saved_backend():
    try:
        if WIN:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                                r"Software\Cilex Vision\Watchtower\auth") as k:
                return (winreg.QueryValueEx(k, "baseUrl")[0] or "").strip() or None
        if sys.platform == "darwin":
            import plistlib
            pl = Path.home() / "Library/Preferences/com.cilex-vision.Watchtower.plist"
            with open(pl, "rb") as fh:
                values = plistlib.load(fh)
            # Qt's native macOS plist encodes the auth/ group as a dotted key.
            # Keep compatibility with existing slash-key fixtures/migrations;
            # an explicitly empty native key must not revive a stale fallback.
            value = values.get("auth.baseUrl") if "auth.baseUrl" in values else values.get("auth/baseUrl")
            return value.strip() or None if isinstance(value, str) else None
        # Linux/BSD: QSettings writes an INI. Scanned by hand rather than with configparser
        # because Qt escapes keys in ways configparser does not expect, and we want exactly
        # one value out of a file that also holds the operator's whole UI state.
        ini = Path.home() / ".config/Cilex Vision/Watchtower.conf"
        section = ""
        for line in ini.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1]
            elif section == "auth" and line.startswith("baseUrl="):
                return line.split("=", 1)[1].strip() or None
    except Exception:
        pass          # no app settings yet, unreadable, or a platform we do not know
    return None


def config_paths():
    paths = ["/etc/watchtower-warden.conf",
             str(Path.home() / ".config/watchtower-warden/warden.conf")]
    # Leave enrollment's legacy token path intact. Generated installation config
    # sets paths only and MUST NOT shadow the live STATION_TOKEN line.
    extra = os.environ.get("WT_WARDEN_CONFIG_FILE")
    if extra:
        if not Path(extra).is_absolute():
            raise ValueError("WT_WARDEN_CONFIG_FILE must be absolute")
        paths.append(extra)
    return paths


def load_config():
    cfg = dict(DEFAULTS)
    for p in config_paths():
        try:
            for line in Path(p).read_text(encoding="utf-8-sig").splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip()
        except OSError:
            pass
    for k in cfg:
        cfg[k] = os.environ.get("WT_WARDEN_" + k, cfg[k])
    global BACKEND_SOURCE
    if not cfg["BACKEND_URL"]:
        derived = app_saved_backend()
        cfg["BACKEND_URL"] = derived or ""
        BACKEND_SOURCE = "the app's saved server" if derived else "NOWHERE — unset"
    else:
        app_url = app_saved_backend()
        BACKEND_SOURCE = "warden.conf"
        if app_url and app_url.rstrip("/") != cfg["BACKEND_URL"].rstrip("/"):
            BACKEND_SOURCE = (f"warden.conf, but the APP is signed in to {app_url} — "
                              "heartbeats go to the first and the wall to the second")
    if not cfg["DATA_DIR"]:
        # Must equal Qt's AppDataLocation for the app (flightrec/, crash/ live there):
        # %APPDATA%/Cilex Vision/Watchtower on Windows, XDG data dir on Linux.
        cfg["DATA_DIR"] = str(Path(os.environ["APPDATA"]) / "Cilex Vision/Watchtower") if WIN \
            else str(Path.home() / "Library/Application Support/Cilex Vision/Watchtower") if DARWIN \
            else str(Path.home() / ".local/share/Cilex Vision/Watchtower")
    if not cfg["WARDEN_DIR"]:
        legacy = Path.home() / ".local/share/watchtower-warden"
        cfg["WARDEN_DIR"] = str(Path(os.environ["LOCALAPPDATA"]) / "watchtower-warden") if WIN \
            else str(legacy if legacy.exists() else Path.home() /
                     "Library/Application Support/CilexWatchtower/Warden") if DARWIN \
            else str(legacy)
    return cfg


BACKEND_SOURCE = ""
CFG = load_config()
W = Path(CFG["WARDEN_DIR"])
PENDING, SENT, QUAR, CONSOLE = W / "pending", W / "sent", W / "quarantine", W / "console"
DATA = Path(CFG["DATA_DIR"])
CRASH, FLTREC = DATA / "crash", DATA / "flightrec"


# ---------------------------------------------------------------- single instance
#
# ONE supervisor per machine, enforced by the OS rather than by hope.
#
# Two Wardens is not a tidiness problem. They both spawn a Watchtower (two walls on one
# iGPU), both read and — since the app can enrol a station — both WRITE the STATION_TOKEN
# line in warden.conf, and both beat for the same station. The operator put it plainly on
# 2026-09-21: "it contradicts the whole logic of having one parent process per Cilex
# Watchtower, but it also creates conflicting environment were one Cilex Warden may
# potentially go into a deadlock with another one." He had three live at once.
#
# How they multiply is a Windows packaging detail — PyInstaller onefile means stopping the
# scheduled task kills the bootloader while the real child keeps supervising, measured on
# wt-sm-vnutri-01 2026-08-07 (install-windows.ps1:148-154, which names this lock as the
# real fix and defers it here as shared code). But the lock does not care WHY a second one
# started; it refuses regardless, which is what makes it the right layer.
#
# An OS lock, not a PID file: the kernel drops it when the holder dies, however it dies —
# SIGKILL, power cut, a Stop-ScheduledTask that only reaches the bootloader. So there is no
# stale-lock case to reason about and no "is that PID still alive" guessing.
#
# The lock byte sits past any data so the PID at offset 0 stays readable by the loser: on
# Windows a locked region blocks reads too, and the loser's whole job is to name the winner.
_LOCK_FD = None
_LOCK_OFFSET = 1024


def acquire_single_instance():
    """Take the supervisor lock. None on success; the holder's pid (or '?') if refused."""
    global _LOCK_FD
    W.mkdir(parents=True, exist_ok=True)
    lock_name = "warden.lock"
    flags = os.O_RDWR | os.O_CREAT
    if DARWIN:
        darwin.private_directory(W)
        installation = CFG["INSTALLATION_ID"] or os.path.realpath(CFG["APP_CMD"])
        scope = f"{installation}|{os.getuid()}|{os.getsid(0)}"
        lock_name = "warden-" + hashlib.sha256(scope.encode()).hexdigest()[:24] + ".lock"
        flags |= os.O_NOFOLLOW
    fd = os.open(str(W / lock_name), flags, 0o600)
    if DARWIN:
        import stat
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
            os.close(fd)
            raise RuntimeError("Unsafe Warden lock ownership or permissions")
    try:
        if WIN:
            import msvcrt
            os.lseek(fd, _LOCK_OFFSET, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        try:
            os.lseek(fd, 0, os.SEEK_SET)
            held = os.read(fd, 32).decode("ascii", "replace").strip()
        except OSError:
            held = ""
        os.close(fd)
        return held or "?"
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, f"{os.getpid()}\n".encode())
    _LOCK_FD = fd                      # held for the life of the process, never closed
    return None


def write_state(rd, st):
    """Write a report's state.json ATOMICALLY.

    It used to be a plain write_text: truncate, then write. A process death between the two
    leaves a ZERO-BYTE state.json — and the scan loop below skipped an unreadable one with a
    bare `continue`, so that report became invisible and stayed invisible.

    Measured on this dev box 2026-09-21: three bundles from 2026-09-06, 4 MB each, all with
    0-byte state.json, all skipped silently for FIFTEEN DAYS while the station reported
    healthy. The interpreter died mid-write at 22:52 that evening ("Fatal Python error:
    _enter_buffered_busy ... at interpreter shutdown"), which is exactly the window.

    Tmp + os.replace: the rename is atomic, so a reader sees the old file or the new one,
    never a half-written one.
    """
    tmp = rd / "state.json.tmp"
    tmp.write_text(json.dumps(st), encoding="utf-8")
    os.replace(tmp, rd / "state.json")


_NATIVE_LOGGER = None


def log(msg):
    global _NATIVE_LOGGER
    if DARWIN and CFG["LOG_DIR"]:
        if _NATIVE_LOGGER is None:
            import logging
            from logging.handlers import RotatingFileHandler
            directory = Path(CFG["LOG_DIR"])
            darwin.private_directory(directory)
            logger = logging.getLogger("cilex-warden")
            logger.setLevel(logging.INFO)
            logger.propagate = False
            handler = RotatingFileHandler(directory / "warden-runtime.log", maxBytes=5 * 1024 * 1024,
                                          backupCount=3, encoding="utf-8")
            handler.setFormatter(logging.Formatter("[warden] %(asctime)s %(message)s"))
            logger.addHandler(handler)
            _NATIVE_LOGGER = logger
        _NATIVE_LOGGER.info(msg)
    else:
        print(f"[warden] {time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}", flush=True)


# A supervisor that declines to supervise must be the loudest line in its own log.
# Without a station token the heartbeat loop and the crash uploader below do NOTHING —
# and until 2026-09-19 they did it in complete silence: no log line, no warning, no
# visible state. Two machines were lost to that silence. The booth sat unheard from
# 2026-07-26 to 08-09, and CV's "box is off or unreachable" was truthful, not a display
# bug. The office wall then ran for days with no station row at all, and it took a
# database query to notice (cilex-pro-mobile letter, 2026-09-19).
# `warden status` has always printed token=MISSING; this puts the same fact where a
# person actually looks. Loud the first time, then hourly per caller.
_NO_TOKEN_SAID = {}


def warn_no_token(what):
    now = time.time()
    if now - _NO_TOKEN_SAID.get(what, 0.0) < 3600:
        return
    _NO_TOKEN_SAID[what] = now
    log(f"STATION_TOKEN missing — {what} DISABLED. This station is INVISIBLE to the fleet: "
        f"no heartbeats, no crash uploads, and no station row for it on the server. "
        f"Put a token in ~/.config/watchtower-warden/warden.conf (STATION_TOKEN=…) and restart.")


_NO_BACKEND_SAID = {}


def warn_no_backend(what):
    """Same contract as warn_no_token: loud once, then hourly, per caller.

    A station with no address is as invisible as one with no token, and until 2026-09-20 it
    was quieter about it — BACKEND_URL defaulted to a dead host, so Warden posted into a void
    and reported only a timeout. Empty is now the default, and empty says so.
    """
    now = time.time()
    if now - _NO_BACKEND_SAID.get(what, 0.0) < 3600:
        return
    _NO_BACKEND_SAID[what] = now
    log(f"BACKEND_URL unset — {what} DISABLED. This station is INVISIBLE to the fleet. "
        f"Warden takes the address from the app's saved server when BACKEND_URL is blank, "
        f"so this means the wall has never signed in on this box either. Sign in once, or "
        f"set BACKEND_URL= in ~/.config/watchtower-warden/warden.conf, and restart.")


def refresh_station_token():
    """Re-read STATION_TOKEN from the conf files, without restarting.

    The app self-provisions a station when this box has none (src/models/StationEnrolment.h):
    an admin signs in, Watchtower calls CV's POST /client/stations on that ordinary session,
    and writes the minted token into warden.conf. Warden must then start beating WITHOUT
    someone restarting the supervisor, or the enrolment would still need a human — which is
    the whole thing it removes. Cheap: two small files, once a heartbeat.

    Only STATION_TOKEN is re-read. Everything else stays as it was at start, because changing
    APP_CMD or DATA_DIR under a running supervisor is a different and much riskier idea.
    """
    before = CFG["STATION_TOKEN"]
    for p_ in config_paths():
        try:
            for line in Path(p_).read_text(encoding="utf-8-sig").splitlines():
                line = line.strip()
                if line.startswith("STATION_TOKEN="):
                    CFG["STATION_TOKEN"] = line.split("=", 1)[1].strip()
        except OSError:
            pass
    # A DIFFERENT token earns a fresh attempt. Without this the whole self-heal is a
    # silent half-fix: a station whose token was refused freezes uploads on the 401,
    # the app re-provisions, this function picks up the new credential — and uploads
    # stay frozen for ever, because nothing ever cleared the flag. Good token, still
    # mute. Cleared only on CHANGE, never per beat: a token that is genuinely bad must
    # not retry in a loop against the server that just refused it.
    if CFG["STATION_TOKEN"] and CFG["STATION_TOKEN"] != before:
        if UPLOAD_FROZEN.get("frozen"):
            log("station token changed — unfreezing uploads for a fresh attempt")
        UPLOAD_FROZEN["frozen"] = False
        UPLOAD_FROZEN["reason"] = None
    return CFG["STATION_TOKEN"]


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


# ---- station identity ----------------------------------------------------
# CV keys every station (quota, monitoring grace, crash history) on this hash.
# The two silent failure modes their letter warned about: an UNSTABLE source
# fragments a box's history; a NON-UNIQUE one (golden-image cloning) collapses
# several boxes into one station that looks supervised when its twins are dead.
# Formula per 2026-07-27-warden-dead-man-heartbeat.reply.md §3a, in CV's spec.

def _smbios_blank(u):
    """Vendor-blank SMBIOS UUIDs (real on cheap boards) carry no identity."""
    if not u:
        return True
    v = u.strip().upper()
    return ("FILLED" in v                                    # "To be filled by O.E.M."
            or v.replace("F", "").replace("-", "") == ""     # all-FF
            or v.replace("0", "").replace("-", "") == ""     # all-zero
            or v == "03000200-0400-0500-0006-000700080009")  # known vendor default


def _station_seed():
    """First-run UUID file — the belt-and-braces component. Regenerated only if
    missing, so a golden image captured BEFORE first run (the install rule)
    yields a fresh seed per box."""
    f = W / "station-seed"
    try:
        seed = f.read_text(encoding="utf-8-sig").strip()
        if seed:
            return seed
    except OSError:
        pass
    seed = str(uuid.uuid4())
    try:
        W.mkdir(parents=True, exist_ok=True)
        f.write_text(seed + "\n", encoding="utf-8")
    except OSError:
        return ""
    return seed


def identity_material(smbios, machine_guid, seed):
    """Pure — unit-testable on any OS. sha256('wt1|SMBIOS|GUID|seed')."""
    if _smbios_blank(smbios):
        smbios = ""
    return "sha256:" + hashlib.sha256(
        f"wt1|{smbios}|{machine_guid}|{seed}".encode()).hexdigest()


_MID_CACHE = None


def machine_id_hash():
    # Cached: on Windows the SMBIOS read shells out (~1 s) and this is called
    # from every heartbeat; identity is immutable for the process lifetime anyway.
    global _MID_CACHE
    if _MID_CACHE is not None:
        return _MID_CACHE
    if WIN:
        guid = ""
        try:
            import winreg
            k = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                               r"SOFTWARE\Microsoft\Cryptography", 0,
                               winreg.KEY_READ | winreg.KEY_WOW64_64KEY)
            guid = str(winreg.QueryValueEx(k, "MachineGuid")[0])
        except OSError:
            pass
        smbios = ""
        try:
            out = subprocess.run(
                ["powershell", "-NoProfile", "-Command",
                 "(Get-CimInstance Win32_ComputerSystemProduct).UUID"],
                capture_output=True, text=True, timeout=20)
            smbios = (out.stdout or "").strip()
        except (OSError, subprocess.TimeoutExpired):
            pass
        if _smbios_blank(smbios) and smbios:
            log(f"WARN: vendor-blank SMBIOS UUID '{smbios}' — identity rides "
                f"MachineGuid + station seed only (see reply letter §3a)")
        _MID_CACHE = identity_material(smbios, guid, _station_seed())
        return _MID_CACHE
    if DARWIN:
        identity_file = Path.home() / "Library/Application Support/CilexWatchtower/Identity/machine-key.json"
        _MID_CACHE = darwin.native_machine_key(identity_file, legacy_enrolled=bool(CFG["STATION_TOKEN"]))
        return _MID_CACHE
    for p in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        try:
            mid = Path(p).read_text(encoding="utf-8-sig").strip()
            _MID_CACHE = "sha256:" + hashlib.sha256(mid.encode()).hexdigest()
            return _MID_CACHE
        except OSError:
            continue
    return ""


def core_pattern_ok():
    """True when kernel cores will actually land in our crash dir. On stock
    Ubuntu, apport owns kernel.core_pattern (a `|pipe`), which silently makes
    core-writing a no-op for us — CV's reply6 spotted exactly that in the first
    five bundles. The gap must be self-announcing: annotated in every manifest
    (a core-less bundle then explains itself server-side) and alarmed once at
    startup. Fix on a box: sudo warden/setup-root.sh.
    Windows has no cores at all — always (False, "") per the contract letters
    (`cores_available:false`, empty pattern; minidump_written is the analogue).
    The WER belt-and-braces check lives in wer_localdumps_ok() instead."""
    if WIN or DARWIN:
        return False, ""
    try:
        pat = Path("/proc/sys/kernel/core_pattern").read_text(encoding="utf-8-sig").strip()
    except OSError:
        return False, ""
    return pat.startswith(str(CRASH)), pat


def wer_localdumps_ok():
    """Windows only: is the WER LocalDumps key armed for watchtower.exe? That's
    the filter-bypassing-crash net (fast-fail, /GS) the installer must set —
    same self-announcing rule as core_pattern on Linux."""
    if not WIN:
        return True
    try:
        import winreg
        winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                       r"SOFTWARE\Microsoft\Windows\Windows Error Reporting"
                       r"\LocalDumps\watchtower.exe", 0,
                       winreg.KEY_READ | winreg.KEY_WOW64_64KEY)
        return True
    except OSError:
        return False


def os_facts():
    ok, pat = core_pattern_ok()
    facts = {"host": socket.gethostname(), "machine_id_hash": machine_id_hash(),
             "os": "", "kernel": "", "display": os.environ.get(
                 "XDG_SESSION_TYPE", "wayland" if os.environ.get("WAYLAND_DISPLAY") else ""),
             "cores_available": ok, "core_pattern": pat[:120]}
    if WIN:
        facts["os"] = f"Windows {platform.release()}"
        facts["kernel"] = platform.version()
        facts["display"] = "windows"
        return facts
    if DARWIN:
        facts["os"] = "macOS " + platform.mac_ver()[0]
        facts["kernel"] = platform.release()
        facts["display"] = "aqua"
        return facts
    try:
        for line in Path("/etc/os-release").read_text(encoding="utf-8-sig").splitlines():
            if line.startswith("PRETTY_NAME="):
                facts["os"] = line.split("=", 1)[1].strip('"')
    except OSError:
        pass
    try:
        facts["kernel"] = os.uname().release
    except (OSError, AttributeError):
        facts["kernel"] = platform.release()
    return facts


# ------------------------------------------------------------------- uplink

# WHICH PATH THIS STATION TOOK TO THE BACKEND. cilex-pro-mobile asked for this
# (letter 2026-09-01 §1) and the server genuinely cannot supply it: every station
# arrives peered as 10.0.0.1 behind their docker bridge, so only we know.
#
# `via` is the field that matters, not the address. This fleet reaches CV over
# either the LAN or the tailnet and they perform very differently — the booth
# measured 53.7-56.0 Mbit/s over the LAN — yet nothing on any screen says which
# one a booth took. A slow station and a station on the wrong path look identical
# without it.
#
# Computed ONCE at first heartbeat and cached: mobile said "once at connect and
# again on change is plenty", and a per-beat DNS lookup on a supervisor is waste.
# Everything here is stdlib — warden.py must keep running on the stock
# interpreter, which is the whole reason the script route works under SAC.
UPLINK = {"cached": None}


def uplink_facts():
    """{local_addr, iface, vision_url, resolved_ip, via} — best effort, and
    HONESTLY NULL where it cannot be determined rather than guessed."""
    if UPLINK["cached"]:
        return UPLINK["cached"]
    url = CFG.get("BACKEND_URL", "")
    host, resolved, local, via = "", None, None, "unknown"
    try:
        rest = url.split("://", 1)[1] if "://" in url else url
        host = rest.split("/", 1)[0].split(":", 1)[0]
    except (IndexError, AttributeError):
        host = ""
    if host:
        try:
            resolved = socket.gethostbyname(host)
        except OSError:
            resolved = None
    # Source address the OS would pick for this destination. A UDP connect()
    # assigns a local endpoint without putting a packet on the wire, so this is
    # free and does not disturb the link we are trying to describe.
    if resolved:
        s = None
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.settimeout(0.5)
            s.connect((resolved, 9))
            local = s.getsockname()[0]
        except OSError:
            local = None
        finally:
            if s:
                s.close()
    # 100.64/10 is the CGNAT range Tailscale allocates from; anything else that
    # resolves is treated as the local network. "unknown" when we could not tell,
    # never a guess — a wrong path label is worse than an absent one.
    if resolved:
        try:
            first, second = (int(x) for x in resolved.split(".")[:2])
            via = "tailscale" if first == 100 and 64 <= second <= 127 else "lan"
        except (ValueError, IndexError):
            via = "unknown"
    UPLINK["cached"] = {"local_addr": local, "iface": None,
                        "vision_url": url, "resolved_ip": resolved, "via": via}
    return UPLINK["cached"]


# ---------------------------------------------------------------- collection

# Crash bundles ship logs to the backend. Scrub every credential shape that can
# appear in them, not only the cookie form (audit 2026-09-03, Low): bearer headers,
# bare JWTs, and rtsp://user:pass@ URLs under the direct transport.
SCRUB = re.compile(
    rb"(access_token=)[^\s;\"']+"
    rb"|(Bearer\s+)[A-Za-z0-9._~+/=-]+"
    rb"|(rtsp://)[^/\s@]+@"
    rb"|\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"
)


def scrubbed(path: Path, cap: int) -> bytes:
    data = path.read_bytes()
    if len(data) > cap:
        data = data[-cap:]                      # tails matter: the crash is at the end
    def _red(m):
        g = m.group(1) or m.group(2) or m.group(3)
        return (g + b"REDACTED" + (b"@" if m.group(3) else b"")) if g else b"REDACTED"
    return SCRUB.sub(_red, data)


def parse_marker(path: Path):
    """First line JSON header, rest raw backtrace (FlightRecorder CW-03)."""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
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
    (report_dir / "manifest.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")
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
    write_state(rd, {"phase": "manifest", "attempts": 0, "next_retry": 0})
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
      # Death timestamps, kept for 24 h so BOTH restarts_1h and restarts_24h can be
      # derived from one list (cilex-pro-mobile letter 2026-09-01, asked four times).
      # In memory only: a Warden restart resets it, so restarts_24h reads low until
      # 24 h of uptime. Mobile renders around that using warden_started_at, which we
      # already send — they explicitly did not ask for persistence.
      "deaths": [], "warden_started": time.time()}
CONTACT = {"last_ok": None, "unreachable_since": None, "said_at": 0.0}


def contact_ok():
    """Any 2xx from the backend (ingest ack or heartbeat). unreachable_since is
    cleared only AFTER it has ridden one successful heartbeat (see payload) —
    the retroactive marker CV asked for in the CW-13 letter §8: the first beat
    after a network gap must still carry when the gap began, so silence gets
    attributed to the network instead of a dead Warden."""
    CONTACT["last_ok"] = time.time()


def contact_failed(why=""):
    """Say it on the way DOWN, name WHERE and WHY, and keep saying it.

    The way-down line was added 2026-09-11, when a gap that never recovered wrote
    nothing at all. Two gaps remained and cilex-pro-mobile found them on 2026-09-19:
    the exception was bound and dropped (`except … as e` with no log), so the line
    said a beat failed but never which address or why; and it fired only on the
    TRANSITION, so a station unreachable since Tuesday showed a clean log today.
    A supervisor talking to nobody should be as loud as one that declines to talk.
    """
    now = time.time()
    first = CONTACT["unreachable_since"] is None
    if first:
        CONTACT["unreachable_since"] = now
    # First failure of a gap, then hourly for as long as it lasts.
    if first or now - CONTACT.get("said_at", 0.0) >= 3600:
        CONTACT["said_at"] = now
        since = "" if first else f" (since {iso(CONTACT['unreachable_since'])})"
        log(f"heartbeat: backend UNREACHABLE at {CFG['BACKEND_URL']}{since} — "
            f"beats are failing{': ' + why if why else ''}. Check BACKEND_URL in "
            f"~/.config/watchtower-warden/warden.conf; the recovery line will carry "
            f"this gap's start.")


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts)) if ts else None


# Whole-machine load for the beat (mobile Health tile ask, letter 2026-08-20).
# Additive fields, and None (JSON null) whenever unmeasured — absent is NEVER zero on
# this surface. Whole MACHINE, not the app process: a wedged GUI on a busy box must not
# read as calm. CPU is a delta across consecutive beats (first beat → null); memory is
# instantaneous. Stdlib only — the booth's frozen exe gains no dependencies.
HOSTLOAD = {"cpu_prev": None}


def host_load():
    cpu = mem = None
    try:
        if os.name == "nt":
            import ctypes
            import ctypes.wintypes as wt

            class MEMSTATEX(ctypes.Structure):
                _fields_ = [("dwLength", wt.DWORD), ("dwMemoryLoad", wt.DWORD),
                            ("ullTotalPhys", ctypes.c_uint64), ("ullAvailPhys", ctypes.c_uint64),
                            ("ullTotalPageFile", ctypes.c_uint64), ("ullAvailPageFile", ctypes.c_uint64),
                            ("ullTotalVirtual", ctypes.c_uint64), ("ullAvailVirtual", ctypes.c_uint64),
                            ("ullAvailExtendedVirtual", ctypes.c_uint64)]

            ms = MEMSTATEX()
            ms.dwLength = ctypes.sizeof(MEMSTATEX)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(ms)):
                mem = float(ms.dwMemoryLoad)            # OS-computed whole-machine percent
            idle, kern, user = wt.FILETIME(), wt.FILETIME(), wt.FILETIME()
            if ctypes.windll.kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kern), ctypes.byref(user)):
                def ft(x):
                    return (x.dwHighDateTime << 32) | x.dwLowDateTime
                i, t = ft(idle), ft(kern) + ft(user)     # kernel time INCLUDES idle on Windows
                prev = HOSTLOAD["cpu_prev"]
                HOSTLOAD["cpu_prev"] = (i, t)
                if prev and t > prev[1]:
                    di, dt = i - prev[0], t - prev[1]
                    cpu = round(max(0.0, min(100.0, 100.0 * (dt - di) / dt)), 1)
        elif DARWIN:
            cpu, mem, HOSTLOAD["cpu_prev"] = darwin.host_load(HOSTLOAD["cpu_prev"])
        else:
            with open("/proc/stat") as f:
                vals = [int(x) for x in f.readline().split()[1:8]]
            idle_all = vals[3] + vals[4]                 # idle + iowait
            total = sum(vals)
            prev = HOSTLOAD["cpu_prev"]
            HOSTLOAD["cpu_prev"] = (idle_all, total)
            if prev and total > prev[1]:
                di, dt = idle_all - prev[0], total - prev[1]
                cpu = round(max(0.0, min(100.0, 100.0 * (dt - di) / dt)), 1)
            tot = avail = None
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        tot = int(line.split()[1])
                    elif line.startswith("MemAvailable:"):
                        avail = int(line.split()[1])
                    if tot is not None and avail is not None:
                        break
            if tot and avail is not None:
                mem = round(100.0 * (tot - avail) / tot, 1)
    except Exception:
        cpu = cpu if isinstance(cpu, float) else None    # any failure → unmeasured, never zero
        mem = mem if isinstance(mem, float) else None
    return cpu, mem


_DEEPLINK_OK = {"checked": False, "ok": None}

def deeplink_ok():
    """Is a cilex:// handler registered for this user? Tri-state: True / False /
    None (unmeasured — tool missing, timeout, or platform quirk; absent != false).
    Checked once per warden lifetime (the app re-claims on every start anyway;
    this is the independent witness, not the fixer)."""
    if _DEEPLINK_OK["checked"]:
        return _DEEPLINK_OK["ok"]
    _DEEPLINK_OK["checked"] = True
    ok = None
    try:
        if WIN:
            import winreg
            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                                    r"Software\Classes\cilex\shell\open\command"):
                    ok = True
            except FileNotFoundError:
                ok = False
        elif sys.platform == "darwin":
            ls = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                  "LaunchServices.framework/Support/lsregister")
            if os.path.exists(ls):
                out = subprocess.run([ls, "-dump", "URLSchemeBinding"],
                                     capture_output=True, text=True, timeout=30)
                ok = ("cilex:" in out.stdout) if out.returncode == 0 else None
        else:
            out = subprocess.run(["xdg-mime", "query", "default",
                                  "x-scheme-handler/cilex"],
                                 capture_output=True, text=True, timeout=10)
            ok = bool(out.stdout.strip()) if out.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        ok = None
    _DEEPLINK_OK["ok"] = ok
    if ok is False:
        log("WARN deeplink_ok=false — cilex:// links will not open on this station "
            "(the app registers on start; a false here after an app start is a defect)")
    return ok


# ------------------------------------------------- Watchtower's own heartbeat
#
# Operator ask 2026-09-11: "Warden must not send heartbeats, it's Watchtower's job —
# but Warden should track IF Watchtower had sent one and WHEN, and report the last."
#
# Warden keeps its own station beat (that is the dead-man: silence from a BOX must
# stay distinguishable from a dead APP — remove it and 'box unplugged' and 'app
# crashed' become the same event). What it must not do is VOUCH for the app. So:
# the app's liveness is the app's OWN signal, observed here, never invented.
#
# That signal is the flight recorder. The app writes [MEMTEL] from its GUI thread
# every 30 s, so the file's mtime is Watchtower saying "my event loop is turning".
# It is the right proxy precisely because a FROZEN wall stops it while the process
# still exists — which `app_pid`/`app_state` alone can never catch, and which is the
# fleet page's own stated fear ("a freeze would be shown as a live picture").

APP_BEAT_STALE_S = 90          # 3 missed 30 s ticks; HANG_S (120) stays the harder verdict
_SUBSYS_NAME = re.compile(r"^[a-z0-9_-]{1,32}$")        # CV's grammar, letter 2026-08-10 reply
_DEGRADED = re.compile(
    r"\[WT-DEGRADED\]\s+subsystem=(\S+).*?\bstate=(FAULT|CLEARED)", re.I)
_DEGRADED_REASON = re.compile(r"\breason=(\S+)")
_DEGRADED_DETAIL = re.compile(r"\bdetail=(.*)$")
_LOGLINE_TS = re.compile(r"^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})")


def app_beat():
    """(epoch, age_s) of Watchtower's last self-declared tick, or (None, None)."""
    try:
        ts = (FLTREC / "watchtower.log").stat().st_mtime
        return ts, max(0.0, time.time() - ts)
    except OSError:
        return None, None


# Watchtower's own version, OBSERVED rather than asked for (Pro Mobile ask 2026-09-23,
# so the owner's Health tile can show which build each station is running — the same
# question `warden_version` already answers for the supervisor, and the reason a 1.4.2
# vs 1.4.3 difference cost an afternoon last week).
#
# NO NEW CHANNEL AND NO CLIENT CHANGE. FlightRecorder already prints a startup banner
# into the log Warden reads for app_beat():
#
#   === watchtower start v1.1.493 pid=3908557 build=e9bfda57 qt=6.12.0 os=... ===
#
# MATCHED ON PID, deliberately. The banner is the version of the process that wrote it,
# so requiring it to match the pid we are supervising makes this exact: we never report
# a version belonging to an earlier run. If the banner has rotated out of reach we
# return None rather than the newest one we can find — a wrong version is worse than
# none, and Pro Mobile draws nothing for null (a printed blank reads as a version with
# no name), while cilex-vision normalises blank to null on ingest.
#
# Cached per pid: a running process cannot change version, and a restart changes the
# pid, so the scan happens once per app start rather than once per beat.
_APP_BANNER = re.compile(r"=== watchtower start v(\S+) pid=(\d+) ")
_APP_VER = {"pid": None, "ver": None}
# How long a missing banner stays worth re-reading for. The banner is written at
# app startup, so anything beyond this is a build that does not emit one.
BANNER_GRACE_S = 120


def app_version():
    pid = HB.get("app_pid")
    if not pid:
        return None
    if _APP_VER["pid"] == pid:
        return _APP_VER["ver"]
    found = None
    # current log first, then rotations newest-first; the pid guard makes order safe
    for cand in [FLTREC / "watchtower.log"] + \
                sorted(FLTREC.glob("watchtower.log.*"),
                       key=lambda q: q.stat().st_mtime if q.exists() else 0, reverse=True):
        try:
            text = cand.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for m in _APP_BANNER.finditer(text):
            if int(m.group(2)) == pid:
                found = m.group(1)          # last match in file order = this run
        if found:
            break
    # CACHE THE HIT ALWAYS; CACHE THE MISS ONLY ONCE IT IS SETTLED.
    #
    # This cached unconditionally, and that was a NEGATIVE CACHE: one call before the
    # app had flushed its startup banner stored (pid, None), and every later call
    # short-circuited on the pid guard and returned None for the life of that process.
    # A single early read made the field permanently null.
    #
    # Found by the Windows station agent on wt-office-01 2026-09-23, and it is the
    # asymmetry that gave it away: two guard stations, identical Warden 1.4.8,
    # identical Windows, one reporting 1.1.548 and one null — because the booth's
    # Warden was started by hand and the office's by `schtasks /run` from a SYSTEM
    # job, which spawns and beats almost immediately. Same code, opposite outcome,
    # which is what a timing-dependent cache looks like. Reproduced here: with the
    # banner absent then present, the second call still returned None.
    #
    # WHY NOT SIMPLY `if found:`, which was their suggestion and also correct — a
    # station whose build genuinely predates the banner would then re-read the whole
    # flight-recorder log on EVERY beat, for ever. Their own box holds 5 MB of it.
    # A miss is only worth retrying while the banner could still be coming, and the
    # banner is written at startup, so `app_spawned` bounds it exactly.
    #
    # If Warden did not spawn the app it cannot judge its age, so it accepts the miss
    # rather than scanning for ever.
    spawned = HB.get("app_spawned")
    settled = spawned is None or (time.time() - spawned) > BANNER_GRACE_S
    if found or settled:
        _APP_VER.update(pid=pid, ver=found)
    return found


def _line_epoch(line):
    """Flight-recorder stamps are LOCAL time; the beat speaks UTC."""
    m = _LOGLINE_TS.match(line)
    if not m:
        return None
    try:
        return time.mktime(time.strptime(m.group(1) + " " + m.group(2),
                                         "%Y-%m-%d %H:%M:%S"))
    except (ValueError, OverflowError):
        return None


def app_declared_subsystems(tail_bytes=262144):
    """Subsystem verdicts the APP declared, newest-wins, read from the tail of the
    flight recorder. The app emits

        [WT-DEGRADED] subsystem=playback reason=auth state=FAULT detail=…
        [WT-DEGRADED] subsystem=playback state=CLEARED

    Lines carrying no `state=` (the refresh-and-retry breadcrumb) are ignored on
    purpose: they are progress, not a verdict."""
    out = {}
    try:
        p = FLTREC / "watchtower.log"
        with p.open("rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - tail_bytes))
            blob = fh.read().decode("utf-8", "replace")
    except OSError:
        return out
    for line in blob.splitlines():
        m = _DEGRADED.search(line)
        if not m:
            continue
        name = m.group(1).lower()
        if not _SUBSYS_NAME.match(name):
            continue                         # never let a client mint label cardinality
        entry = {"state": "ok" if m.group(2).upper() == "CLEARED" else "fault"}
        when = _line_epoch(line)
        if when:
            entry["since"] = iso(when)
        if entry["state"] != "ok":
            r = _DEGRADED_REASON.search(line)
            if r:
                entry["reason"] = r.group(1)[:32]
            d = _DEGRADED_DETAIL.search(line)
            if d and d.group(1).strip():
                entry["detail"] = d.group(1).strip()[:160]
        out[name] = entry                    # later line wins
    return out


def subsystems():
    """CV contract (letter 2026-08-10 reply): {name: {state, reason?, detail?,
    since?}}, `ok` is the ONLY healthy string, max 8 names. Never raises — a throw
    here would propagate out of payload() and kill the heartbeat thread silently,
    which is exactly how 1.3.1 lost the beat."""
    try:
        subs = app_declared_subsystems()

        ts, age = app_beat()
        state = HB.get("app_state")
        if state == "running" and age is not None and age <= APP_BEAT_STALE_S:
            wt = {"state": "ok", "detail": "last tick %ds ago" % int(age)}
        elif state == "running":
            wt = {"state": "fault", "reason": "no_beat",
                  "detail": ("no tick for %ds (process alive — a frozen wall looks "
                             "exactly like this)" % int(age)) if age is not None
                            else "no flight recorder yet"}
        else:
            wt = {"state": "fault", "reason": str(state or "unknown")[:32],
                  "detail": str(HB.get("app_state_reason") or "")[:160] or None}
        if ts:
            wt["since"] = iso(ts)            # WHEN Watchtower last beat — the operator's ask
        subs["watchtower"] = {k: v for k, v in wt.items() if v is not None}

        return dict(list(subs.items())[:8])  # contract cap
    except Exception as e:                   # noqa: BLE001 — must never kill the beat
        log(f"WARN subsystems() failed, beat continues without it: {e!r}")
        return {}


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
        HB["deaths"] = [t for t in HB["deaths"] if now - t < 86400]
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
            "app_version": app_version(),
            "app_uptime_s": int(now - HB["app_spawned"]) if HB["app_spawned"] else None,
            # restarts_1h keeps its EXACT former meaning — CV gates its storm verdict
            # on it at RESTART_STORM_1H = 12, so this is deliberately the same count
            # over the same window, just filtered out of the longer-lived list.
            "restarts_1h": sum(1 for t in HB["deaths"] if now - t < 3600),
            "restarts_24h": len(HB["deaths"]),
            "uplink": uplink_facts(),
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
        p["cpu_pct"], p["mem_pct"] = host_load()   # whole-machine; null when unmeasured
        p["deeplink_ok"] = deeplink_ok()            # tri-state; None = unmeasured
        # Watchtower's OWN beat, observed not invented (operator ask 2026-09-11).
        # Explicit top-level fields as well as the subsystem entry, because "when did
        # the app last check in" is a question the fleet row should answer directly
        # rather than by parsing a detail string.
        _abt, _abage = app_beat()
        p["app_last_beat_at"] = iso(_abt)
        p["app_beat_age_s"] = int(_abage) if _abage is not None else None
        p["subsystems"] = subsystems()              # CV letter 2026-08-10 reply; max 8
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
            contact_failed(f"{type(e).__name__}: {e}")
            return False

    def run(self):
        first = True
        while True:
            if not CFG["STATION_TOKEN"]:
                # The app may have just enrolled this station; pick the token up in place.
                if refresh_station_token():
                    log("STATION_TOKEN appeared — the app enrolled this station; beating now")
                else:
                    warn_no_token("heartbeats")
            elif not CFG["BACKEND_URL"]:
                warn_no_backend("heartbeats")
            else:
                ok = self.send()
                if first and ok:
                    log(f"heartbeat: first beat accepted (stale_after={self.stale_after}s) "
                        f"— station monitoring is now ARMED server-side, permanently")
                    first = False
            # Contract cadence 60 s; never slower than a third of the server's
            # stale window even if the server widens it.
            time.sleep(min(int(CFG["HEARTBEAT_S"]), max(20, int(self.stale_after / 3))))


UPLOAD_FROZEN = {"frozen": False, "reason": None}

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
        # Both call sites are the 401 arms, so a freeze IS a refused token today. Naming
        # the reason anyway: a later freeze for some other cause must not be readable as
        # "your credential is bad".
        UPLOAD_FROZEN["reason"] = "token_refused" if v else None

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
            contact_failed(f"{type(e).__name__}: {e}")
            return -1, {"error": str(e)}, {}

    def run(self):
        while True:
            time.sleep(3)
            if not CFG["STATION_TOKEN"]:
                warn_no_token("crash-bundle upload")
                continue
            if self.frozen:
                continue
            now = time.time()
            for rd in sorted(PENDING.iterdir()) if PENDING.exists() else []:
                st_file = rd / "state.json"
                try:
                    st = json.loads(st_file.read_text(encoding="utf-8-sig"))
                except (OSError, json.JSONDecodeError) as exc:
                    # A `continue` here is how three real bundles sat unsent for fifteen
                    # days. The state file only tracks attempts and the retry clock; the
                    # manifest and the bundle beside it are intact, and CV dedupes a
                    # re-upload (`dup=` in the PUT log). So REBUILD it and start again,
                    # loudly. Skipping was the one option that could never recover.
                    if not (rd / "manifest.json").exists():
                        continue          # not a report dir at all; leave it alone
                    log(f"report {rd.name}: state.json unreadable ({exc}) — rebuilding and "
                        f"retrying. The bundle is intact; this would otherwise never upload.")
                    st = {"phase": "manifest", "attempts": 0, "next_retry": 0}
                    write_state(rd, st)
                if st.get("next_retry", 0) > now:
                    continue
                self.advance(rd, st)
                break                     # one at a time, contract rate

    def backoff(self, rd, st, retry_after=None):
        st["attempts"] = st.get("attempts", 0) + 1
        delay = retry_after or min(60 * (2 ** min(st["attempts"], 6)), 3600)
        st["next_retry"] = time.time() + delay
        write_state(rd, st)

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
                write_state(rd, st)
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
                write_state(rd, st)
            elif code == 413:
                # Rebuild without the core (degenerate truncation), re-PUT the
                # manifest too — last-write-wins records the smaller artifact set.
                alarm("upload-413", f"{rid} over the size cap — repacking without core")
                self.strip_core(rd)
                st["phase"] = "manifest"
                st["attempts"] = 0
                write_state(rd, st)
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
        manifest = json.loads((rd / "manifest.json").read_text(encoding="utf-8-sig"))
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
        self.process_guard = None
        self.activity_clock = darwin.ActivityClock() if DARWIN else None

    def app_env(self):
        env = dict(os.environ)
        if DARWIN:
            for key in list(env):
                if key.startswith(("DYLD_", "LD_", "QT_", "QML_", "GST_", "PYTHON")):
                    env.pop(key)
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            contents = Path(CFG["APP_CMD"]).parent.parent
            plugins = contents / "PlugIns/gstreamer-1.0"
            scanner = contents / "Helpers/gst-plugin-scanner"
            if plugins.is_dir() and scanner.is_file():
                env["GST_PLUGIN_SYSTEM_PATH_1_0"] = str(plugins)
                env["GST_PLUGIN_PATH_1_0"] = ""
                env["GST_PLUGIN_SCANNER_1_0"] = str(scanner)
                cache = Path.home() / "Library/Caches/CilexWatchtower/GStreamer"
                cache.mkdir(parents=True, exist_ok=True, mode=0o700)
                registry_id = hashlib.sha256(CFG["INSTALLATION_ID"].encode()).hexdigest()[:24]
                env["GST_REGISTRY_1_0"] = str(cache / (registry_id + ".bin"))
            if (contents / "Helpers/ffmpeg").is_file():
                env["PATH"] = str(contents / "Helpers") + ":" + env["PATH"]
        for kv in CFG["APP_ENV"].split(","):
            if "=" in kv:
                k, v = kv.split("=", 1)
                env[k.strip()] = v.strip()
        # Supervision indicator (the title-bar eye): tells the app it is watched.
        # The app keeps it HONEST itself (parent-pid check) — this only arms it.
        env["WT_UNDER_WARDEN"] = "1"
        env["WT_WARDEN_VERSION"] = WARDEN_VERSION
        # The person standing at the wall is the one who can fix a missing token, so the
        # title-bar overlay states it (TitleBar.qml). Warden is the only process that knows.
        # PRESENCE IS NOT VALIDITY. This reported "set" for any non-empty string, so a
        # station holding a token the server REFUSES looked provisioned to the app — and
        # since enrolmentWanted() only fires on "missing", such a station could never
        # re-enrol itself. Measured on this box 2026-09-23: warden.conf holds a 48-char
        # token, `GET /labs/analyzers` with it returns 401, and client_stations shows the
        # row for cilex-vision-MS-7E06 with token_hash NULL. Permanently invisible to the
        # fleet, by a check that asked the wrong question. Same family as the export
        # comment that outlived its fact, and as `stream_type` read as a retention signal.
        #
        # Set at spawn, so a token refused mid-run shows on the NEXT app start. A refusal
        # is a persistent condition, so that is acceptable; it is not instantaneous.
        # The identity the SERVER already files this machine under. cilex-vision's
        # StationCreate says it plainly — "stable identity; defaults to host:<host>. Use
        # the manifest's machine_id_hash when you know it" — and enrolment did not know
        # it, so it sent host only and the endpoint defaulted to `host:<host>`.
        #
        # That is a duplicate waiting to happen, and it is REACHABLE: the trust-on-first-use
        # path keys a row on machine_id_hash VERBATIM (client_reports.py:311), so any
        # machine that uploaded a crash report before being provisioned already has a
        # `sha256:...` row. Re-enrolling it by host would add a second station for one
        # machine. Measured here: machine_id_hash() returns
        # sha256:27dd00... and client_stations.machine_key for this host is the same
        # string, byte for byte — so sending it upserts that row instead of forking it.
        env["WT_MACHINE_KEY"] = machine_id_hash() or ""
        env["WT_WARDEN_TOKEN"] = ("missing" if not CFG["STATION_TOKEN"]
                                  else "rejected" if UPLOAD_FROZEN.get("reason") == "token_refused"
                                  else "set")
        # The overlay's SERVER row is the APP's server (AuthController.baseUrl). Warden
        # may be posting somewhere else entirely — on WT-OFFICE-01 the app had .4 while
        # Warden still had the installer's .79 default, so the panel read like
        # confirmation while nothing was being delivered (cilex-pro-mobile, 2026-09-19).
        env["WT_WARDEN_BACKEND"] = CFG["BACKEND_URL"]
        return env

    def spawn(self):
        CONSOLE.mkdir(parents=True, exist_ok=True)
        for old in sorted(CONSOLE.glob("console-*.log"))[:-5]:
            old.unlink(missing_ok=True)
            if DARWIN:
                old.with_name(old.name + ".previous").unlink(missing_ok=True)
        out = CONSOLE / f"console-{int(time.time())}.log"
        # Windows/Linux retain their existing detached spawn behavior. Darwin
        # uses the gate below and inherits launchd's group/session for cleanup.
        kw = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if WIN \
             else {"start_new_session": True}
        self.console_path = out
        with out.open("ab" if DARWIN else "wb") as fh:       # Popen dups the fd; don't leak ours per spawn
            if DARWIN:
                if not self.process_guard:
                    raise RuntimeError("Darwin process guard is not running")
                self.activity_clock = darwin.ActivityClock()
                proc = self.process_guard.spawn(CFG["APP_CMD"], CFG["SPAWN_GATE"],
                    self.app_env(), fh, CFG["APP_WORKING_DIR"] or None)
            else:
                proc = subprocess.Popen(
                    [CFG["APP_CMD"]], env=self.app_env(),
                    stdout=fh, stderr=subprocess.STDOUT, **kw)
        log(f"spawned watchtower pid={proc.pid} console={out.name}")
        HB.update(app_state="running", app_state_reason=None,
                  app_pid=proc.pid, app_spawned=time.time())
        return proc, out

    def flightrec_age(self):
        if DARWIN:
            try:
                st = (FLTREC / "watchtower.log").stat()
                signature = (st.st_ino, st.st_size, st.st_mtime_ns)
            except OSError:
                signature = None
            return self.activity_clock.age(signature)
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
                proc.wait(timeout=1 if DARWIN else 10)
                if DARWIN:
                    # SIGTERM/maintenance may race the child's exit. Preserve
                    # explicit shutdown intent even when wait finishes before
                    # the next polling branch; do not mint a crash report.
                    if self.stopping:
                        return "stopped"
                    if self.maintenance_requested():
                        return "maintenance"
                return "died"
            except subprocess.TimeoutExpired:
                # Housekeeping while healthy: a loop must close on QUIET TIME, not
                # only on the next death — otherwise a crash hours later would fold
                # into a stale loop report instead of minting its own.
                self.loop_tick()
            if DARWIN:
                darwin.bound_log(self.console_path)
            if DARWIN and not self.process_guard.healthy():
                self.process_guard.cleanup()
                raise RuntimeError("Darwin process guard failed; Watchtower stopped before supervisor recovery")
            maintenance = self.maintenance_requested()
            if self.stopping or maintenance:
                proc.terminate()
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    proc.kill()
                if DARWIN:
                    self.process_guard.cleanup()
                return "maintenance" if maintenance and not self.stopping else "stopped"
            if hang_s > 0 and self.flightrec_age() > hang_s:
                if WIN:
                    # No SIGABRT delivery on Windows — the in-app watchdog
                    # (WT_WATCHDOG_S) is the marker-writing path there; the
                    # outer net just ends the frozen process.
                    alarm("hang", f"flightrec silent {int(self.flightrec_age())}s — "
                                  f"terminating pid={proc.pid}")
                    proc.kill()
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        pass
                    return "hung"
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
        # POSIX: a negative return code IS the signal. Windows: the code is the
        # NTSTATUS (signed 32-bit) — e.g. 0xC0000005 arrives as -1073741819; the
        # trigger becomes exception-c0000005 (stored + flagged as an unknown
        # trigger server-side, by design — same as sigkill was).
        sig = None
        exc = None
        if rc is not None and rc < 0:
            if WIN:
                exc = f"{rc & 0xFFFFFFFF:08x}"
            else:
                sig = -rc
        elif WIN and rc is not None and rc >= 0x40000000:
            exc = f"{rc & 0xFFFFFFFF:08x}"      # some launchers report unsigned NTSTATUS
        head = {"epoch": int(time.time()), "uptime_s": int(time.time() - spawn_ts),
                "signal": sig, "build": "unknown", "qt": ""}
        if exc:
            head["exception"] = "0x" + exc.upper()
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
        elif exc:
            trigger = "exception-" + exc      # e.g. exception-c0000005 (access violation)
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
            manifest = json.loads((rd / "manifest.json").read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError):
            return
        manifest["loop"] = {"deaths": self.loop_count,
                            "first": time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                                   time.gmtime(self.loop_first)),
                            "last_trigger": last_trigger}
        manifest["backtrace"] = head.get("backtrace", manifest.get("backtrace", ""))
        (rd / "manifest.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")
        if rd.parent == SENT:            # already uploaded once -> re-PUT the update
            rd.rename(PENDING / rd.name)
            rd = PENDING / rd.name
        st = {"phase": "manifest", "attempts": 0, "next_retry": 0}
        write_state(rd, st)

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
            if head.get("signal") is not None:
                trigger = TRIG.get(head.get("signal"), "signal-unknown")
            elif head.get("exception"):
                trigger = "exception-" + str(head["exception"]).replace("0x", "").lower()
            else:
                trigger = "signal-unknown"
            log(f"boot replay: marker {m.name} -> report {rid}")
            self.mint_replay(rid, trigger, head, m)

    def mint_replay(self, rid, trigger, head, marker):
        self.deaths = [t for t in self.deaths
                       if time.time() - t < int(CFG["LOOP_WINDOW_S"])] + [time.time()]
        collect(rid, trigger, head, None, marker,
                find_core(head.get("epoch", 0), head.get("pid")))

    def maintenance_requested(self):
        if not DARWIN or not CFG["MAINTENANCE_FILE"]:
            return False
        path = Path(CFG["MAINTENANCE_FILE"])
        try:
            import stat
            st = path.lstat()
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
                raise RuntimeError("Unsafe maintenance marker; refusing operation")
            return True
        except FileNotFoundError:
            return False

    def run(self):
        if DARWIN:
            if os.getuid() == 0:
                log("FATAL: GUI supervision must run as the intended desktop user, never root")
                return 2
            if CFG["LOG_DIR"]:
                for name in ("warden-launchd.log", "warden-launchd-error.log"):
                    darwin.bound_log(Path(CFG["LOG_DIR"]) / name)
            if not CFG["INSTALLATION_ID"] or not CFG["SPAWN_GATE"]:
                log("FATAL: Darwin requires INSTALLATION_ID and packaged SPAWN_GATE")
                return 2
            for key in ("APP_CMD", "SPAWN_GATE"):
                if not Path(CFG[key]).is_absolute() or not os.access(CFG[key], os.X_OK):
                    log(f"FATAL: {key} must be an absolute executable path")
                    return 2
            command = [sys.executable] if getattr(sys, "frozen", False) else [sys.executable, str(Path(__file__).resolve())]
            self.process_guard = darwin.ProcessGuard(command, W / "process-guard", CFG["INSTALLATION_ID"])
        try:
            return self._run_supervised()
        finally:
            if self.process_guard:
                pending_failure = sys.exc_info()[0] is not None
                try:
                    self.process_guard.close()
                except Exception as exc:
                    if not pending_failure:
                        raise
                    log(f"CLEANUP FAILURE (original failure retained): {type(exc).__name__}: {exc}")

    def _run_supervised(self):
        for d in (PENDING, SENT, QUAR, CONSOLE):
            d.mkdir(parents=True, exist_ok=True)
        if not CFG["APP_CMD"]:
            log("FATAL: APP_CMD not configured")
            return 2
        signal.signal(signal.SIGTERM, lambda *_: setattr(self, "stopping", True))
        signal.signal(signal.SIGINT, lambda *_: setattr(self, "stopping", True))
        if hasattr(signal, "SIGBREAK"):     # Windows: CTRL_BREAK is the deliverable stop
            signal.signal(signal.SIGBREAK, lambda *_: setattr(self, "stopping", True))
        if WIN:
            if not wer_localdumps_ok():
                alarm("no-wer", "WER LocalDumps key for watchtower.exe is missing — "
                                "filter-bypassing crashes (fast-fail, /GS) will leave no "
                                "dump. Fix: run warden/install-windows.ps1 as admin")
        elif DARWIN:
            log("Darwin diagnostics are system-managed; bundles include app markers and logs, no promised core dump")
        else:
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
            if self.maintenance_requested():
                HB.update(app_state="stopped_expected", app_state_reason="warden_stopping",
                          app_pid=None, app_spawned=None)
                time.sleep(0.5)
                continue
            spawn_ts = time.time()
            spawn_mono = time.monotonic()
            proc, console = self.spawn()
            why = self.watch(proc)
            if DARWIN:
                self.process_guard.cleanup()
            if why == "maintenance":
                log("maintenance marker present — GUI stopped; no failure report or restart")
                continue
            if why == "stopped":
                log("supervisor stopping (SIGTERM) — no report for a clean stop")
                break
            death_ts = time.time()
            trigger, head, marker = self.death_facts(proc, spawn_ts, why == "hung")
            alive_s = time.monotonic() - spawn_mono
            HB["deaths"].append(death_ts)
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
            t0 = time.monotonic()
            while time.monotonic() - t0 < delay and not self.stopping:
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
        manifest = json.loads(mf.read_text(encoding="utf-8-sig"))
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
          f"backend={CFG['BACKEND_URL'] or '(none)'} [{BACKEND_SOURCE}] "
          f"token={'set' if CFG['STATION_TOKEN'] else 'MISSING'}")
    # Watchtower's own last beat — answerable from ANY shell, without waiting for the
    # fleet page or asking the running supervisor (operator ask 2026-09-11).
    ts, age = app_beat()
    if ts is None:
        print("watchtower: NEVER — no flight recorder at "
              f"{FLTREC / 'watchtower.log'} (the app has not run, or DATA_DIR is wrong)")
    else:
        verdict = "ok" if age <= APP_BEAT_STALE_S else "STALE"
        print(f"watchtower: last beat {iso(ts)} ({int(age)}s ago) {verdict} "
              f"— stale above {APP_BEAT_STALE_S}s")
    for name, s in sorted(subsystems().items()):
        if name == "watchtower":
            continue
        print(f"subsystem {name}: {s.get('state')} {s.get('reason','')} "
              f"{s.get('since','')}".rstrip())


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "darwin-guard" and DARWIN and len(sys.argv) == 4:
        sys.exit(darwin.guard_main(sys.argv[2], sys.argv[3]))
    if cmd == "run":
        # Before anything else: one supervisor per machine. A second would spawn a second
        # wall and fight this one over warden.conf.
        holder = acquire_single_instance()
        if holder is not None:
            log(f"ANOTHER WARDEN IS ALREADY RUNNING (pid {holder}) — refusing to start a "
                f"second. Two supervisors would spawn two walls and both rewrite "
                f"STATION_TOKEN. Stop that process first if you meant to replace it.")
            sys.exit(3)
        # Say where the address came from, once, at the top of the log. Two places to
        # configure one server is how wt-office-01 stayed invisible for days while its
        # panel read like confirmation; whichever won, the log now names it.
        log(f"backend {CFG['BACKEND_URL'] or '(none)'} — from {BACKEND_SOURCE}")
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
