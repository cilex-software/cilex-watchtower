"""The station side of Labs scanning: two small JSON files on THIS machine.

    control.json  written by the app (Labs screen) or the CLI; read by the worker.
    status.json   written by the worker; read by the app.

No new network surface, no new credential, and it works the same on Linux and
Windows. The app computes the SAME directory (src/models/LabsStation.h, stateDir()):
if the two rules ever differ, the app shows "not set up on this station" while the
worker runs unseen -- so change them together.

DEFAULT-DENY. Scanning spends this station's CPU and writes to the shared pilot, which
every agent and the operator see. So a missing, unreadable or incomplete control file
means PAUSED: scanning starts only when someone has said so, in the app or the CLI.
"""
from __future__ import annotations

import json
import os
import socket
import tempfile
import time
from datetime import datetime, timezone
from typing import Optional

CONTROL = "control.json"
STATUS = "status.json"

#: The worker rewrites status.json at least this often, from a heartbeat thread, so a
#: long unit (a whole hour of footage can take minutes) never looks like a dead worker.
HEARTBEAT_S = 30.0
#: The app calls the worker "not running" when status.json is older than this: four
#: missed heartbeats. Mirrored in LabsStation.h (kStaleAfterS).
STALE_AFTER_S = 120.0


def state_dir() -> str:
    """Where Labs keeps this station's state. Mirrored in LabsStation.h: keep in step."""
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    else:
        base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "watchtower-labs")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


#: WINDOWS REFUSES BOTH SIDES OF AN ATOMIC REPLACE FOR A MOMENT. os.replace fails while
#: another handle has the file open (no FILE_SHARE_DELETE -- neither Python's open nor
#: Qt's asks for it), and an open fails while the file is being replaced. Linux never
#: does either. Measured on the booth, 2026-09-27 (Windows agent): a writer and a reader
#: flat out for 5 s -- the writer failed 3,501 of 5,494 replaces and the reader 3,096 of
#: 38,163 opens; retrying on ONE side left the other failing (1,059 / 761); retrying on
#: BOTH, 20 x 5 ms, failed 0 and 0. LabsStation.h retries the same way. Only
#: PermissionError is retried: a missing file is a real state, a broken one is not
#: fixed by waiting.
RETRIES = 20
RETRY_S = 0.005


def _retrying(fn, *args):
    for attempt in range(RETRIES):
        try:
            return fn(*args)
        except PermissionError:
            if attempt == RETRIES - 1:
                raise
            time.sleep(RETRY_S)


def read_text(path: str) -> str:
    """The file's text. Retries the Windows mid-replace refusal; raises FileNotFoundError
    for a file that is not there, and PermissionError only if it never opens."""
    def once():
        with open(path, encoding="utf-8") as f:
            return f.read()
    return _retrying(once)


def read_json(path: str):
    """read_text, parsed. ValueError for a file that is not JSON."""
    return json.loads(read_text(path))


def _write_atomic(path: str, doc: dict) -> None:
    """Whole file or nothing: the reader never sees half a document."""
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=1)
        _retrying(os.replace, tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_control(directory: Optional[str] = None) -> dict:
    """{'paused': bool, 'camera_health': bool, 'why': str}. Never raises.

    Default-deny (see the module docstring): anything but an explicit
    `"paused": false` reads as paused, and `why` says which case it was, so the
    status file can tell the operator why nothing is being scanned."""
    p = os.path.join(directory or state_dir(), CONTROL)
    try:
        d = read_json(p)
    except FileNotFoundError:
        return {"paused": True, "camera_health": False, "why": "never started on this station", "hold": None}
    except Exception as e:
        return {"paused": True, "camera_health": False,
                "why": f"control file unreadable ({type(e).__name__})", "hold": None}
    hold = _hold_of(d) if isinstance(d, dict) else None
    if not isinstance(d, dict) or not isinstance(d.get("paused"), bool):
        return {"paused": True, "camera_health": False, "why": "control file has no paused flag", "hold": hold}
    return {"paused": d["paused"],
            # camera_health: EXACTLY ONE station may run it (cilex-vision's rule), so it
            # is opt-in per station, never on by default.
            "camera_health": d.get("camera_health") is True,
            "why": "paused" if d["paused"] else "",
            "hold": hold}


# ---------------------------------------------------------------- the local HOLD
# Operator decision 2026-09-28. Once cilex-vision's control plane governs (Start / Pause /
# Stop, answered to every report), the `paused` flag above no longer does -- one switch,
# the server's. The HOLD is the exception, kept on purpose: the wall's automatic safety
# check sets it the moment the guards' wall degrades, and it keeps Labs off on THIS
# computer even when the server says Start, across restarts, until it is released here.
# It is never hidden: the worker sends it with its reason in every report, so the admin
# page says why this station is not scanning. Guards never see any of it (Labs is a
# background, admins-only programme).
def _hold_of(d: dict) -> Optional[dict]:
    h = d.get("hold")
    if not isinstance(h, dict) or not isinstance(h.get("why"), str) or not h.get("why"):
        return None
    return {"by": str(h.get("by") or "?")[:40], "why": h["why"][:120], "at": str(h.get("at") or "")[:40]}


def write_hold(why: str, *, by: str = "cli", directory: Optional[str] = None) -> dict:
    """Hold Labs off on this computer, with the reason. Keeps the rest of the file."""
    return _edit_control(lambda doc: doc.update(
        {"hold": {"by": by[:40], "why": (why or "held")[:120], "at": now_iso()}}), by, directory)


def clear_hold(*, by: str = "cli", directory: Optional[str] = None) -> dict:
    """Release the hold. Keeps the rest of the file."""
    return _edit_control(lambda doc: doc.pop("hold", None), by, directory)


def _edit_control(change, by: str, directory: Optional[str]) -> dict:
    p = os.path.join(directory or state_dir(), CONTROL)
    try:
        doc = read_json(p)
        if not isinstance(doc, dict):
            doc = {}
    except (FileNotFoundError, ValueError):
        doc = {}
    # Anything else RAISES rather than writing a fresh document over a file that will
    # not open -- that would drop its camera_health opt-in (see write_control).
    change(doc)
    doc.update({"v": 1, "updated_at": now_iso(), "updated_by": by})
    doc.setdefault("paused", True)            # default-deny stays the default
    _write_atomic(p, doc)
    return doc


def write_control(paused: bool, *, camera_health: Optional[bool] = None,
                  by: str = "cli", directory: Optional[str] = None) -> dict:
    """Set the pause flag, keeping everything else in the file as it was."""
    dirp = directory or state_dir()
    p = os.path.join(dirp, CONTROL)
    try:
        doc = read_json(p)
        if not isinstance(doc, dict):
            doc = {}
    except (FileNotFoundError, ValueError):
        doc = {}          # nothing there, or nothing worth keeping: a fresh document
    # Any other failure RAISES. A file that exists but will not open still holds the
    # station's camera_health opt-in; writing a fresh document over it would drop that
    # opt-in silently. (It used to: `except Exception: doc = {}`.)
    doc.update({"v": 1, "paused": bool(paused), "updated_at": now_iso(), "updated_by": by})
    if camera_health is not None:
        doc["camera_health"] = bool(camera_health)
    _write_atomic(p, doc)
    return doc


def write_status(fields: dict, directory: Optional[str] = None) -> None:
    doc = {"v": 1, "updated_at": now_iso(), "pid": os.getpid(), "host": socket.gethostname()}
    doc.update(fields)
    _write_atomic(os.path.join(directory or state_dir(), STATUS), doc)
