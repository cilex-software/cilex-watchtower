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


def _write_atomic(path: str, doc: dict) -> None:
    """Whole file or nothing: the reader never sees half a document."""
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=1)
        os.replace(tmp, path)
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
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
    except FileNotFoundError:
        return {"paused": True, "camera_health": False, "why": "never started on this station"}
    except Exception as e:
        return {"paused": True, "camera_health": False,
                "why": f"control file unreadable ({type(e).__name__})"}
    if not isinstance(d, dict) or not isinstance(d.get("paused"), bool):
        return {"paused": True, "camera_health": False, "why": "control file has no paused flag"}
    return {"paused": d["paused"],
            # camera_health: EXACTLY ONE station may run it (cilex-vision's rule), so it
            # is opt-in per station, never on by default.
            "camera_health": d.get("camera_health") is True,
            "why": "paused" if d["paused"] else ""}


def write_control(paused: bool, *, camera_health: Optional[bool] = None,
                  by: str = "cli", directory: Optional[str] = None) -> dict:
    """Set the pause flag, keeping everything else in the file as it was."""
    dirp = directory or state_dir()
    p = os.path.join(dirp, CONTROL)
    try:
        with open(p, encoding="utf-8") as f:
            doc = json.load(f)
        if not isinstance(doc, dict):
            doc = {}
    except Exception:
        doc = {}
    doc.update({"v": 1, "paused": bool(paused), "updated_at": now_iso(), "updated_by": by})
    if camera_health is not None:
        doc["camera_health"] = bool(camera_health)
    _write_atomic(p, doc)
    return doc


def write_status(fields: dict, directory: Optional[str] = None) -> None:
    doc = {"v": 1, "updated_at": now_iso(), "pid": os.getpid(), "host": socket.gethostname()}
    doc.update(fields)
    _write_atomic(os.path.join(directory or state_dir(), STATUS), doc)
