"""Windows only: the Labs tree's CPU priority class and its power-throttling QoS, set per station.

Why (the office, 2026-09-30, measured by the Windows agent). wt-office-01 is an i5-14400 (6
P-cores, 4 E-cores). With fill at 16 units, every Labs process ran on the 4 E-cores (78-100 %
busy) while the P-cores' second threads sat at 0-9 %, and 720p units overran their leases.
It was NOT the priority class: moved from Idle to Normal at 09:39, the units stayed on the
E-cores. Windows' default QoS for these windowless processes (power throttling left at the
system's default) kept them there. So the two settings are separate knobs:

  WT_LABS_PRIORITY=idle|belownormal|normal   the priority class (SetPriorityClass)
  WT_LABS_HIGHQOS=1                          opt out of execution-speed throttling
                                             (SetProcessInformation, ProcessPowerThrottling,
                                             ControlMask=EXECUTION_SPEED, StateMask=0)

Both are applied by the worker to itself at start, and by every unit process to itself at its
start (unit_proc.child_main) -- whether Windows passes throttling state to a child is not
known here, so nothing relies on it. With HIGHQOS a unit also opts out its decoders, a few
seconds after each starts (DecoderSweep): they are spawned in nine places, by every analyser.

Unset, nothing changes. On other systems they are ignored with a note: Linux stations set
their priority in the service unit (Nice=19, idle CPU and IO scheduling).
"""
from __future__ import annotations

import logging
import os
import sys
import threading
from typing import Callable, Iterable, Optional

log = logging.getLogger("labs.qos")

PRIORITY_CLASSES = {"idle": 0x00000040, "belownormal": 0x00004000, "normal": 0x00000020}
PROCESS_POWER_THROTTLING = 4                 # PROCESS_INFORMATION_CLASS.ProcessPowerThrottling
POWER_THROTTLING_VERSION = 1                 # PROCESS_POWER_THROTTLING_CURRENT_VERSION
THROTTLING_EXECUTION_SPEED = 0x1             # PROCESS_POWER_THROTTLING_EXECUTION_SPEED
PROCESS_SET_INFORMATION = 0x0200
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
SWEEP_EVERY_S = 2.0


def wanted_priority(env=None) -> Optional[str]:
    """The priority class asked for, or None (unset, or a word this worker does not know --
    said once by apply_to_self, never guessed at)."""
    v = (env if env is not None else os.environ).get("WT_LABS_PRIORITY", "").strip().lower()
    return v if v in PRIORITY_CLASSES else None


def wanted_high_qos(env=None) -> bool:
    v = (env if env is not None else os.environ).get("WT_LABS_HIGHQOS", "").strip().lower()
    return v in ("1", "true", "yes", "on")


def _k32():
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.GetCurrentProcess.restype = wintypes.HANDLE
    k32.SetPriorityClass.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    k32.SetPriorityClass.restype = wintypes.BOOL
    k32.GetPriorityClass.argtypes = [wintypes.HANDLE]
    k32.GetPriorityClass.restype = wintypes.DWORD
    k32.SetProcessInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    k32.SetProcessInformation.restype = wintypes.BOOL
    k32.GetProcessInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    k32.GetProcessInformation.restype = wintypes.BOOL
    k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    k32.OpenProcess.restype = wintypes.HANDLE
    k32.CloseHandle.argtypes = [wintypes.HANDLE]
    k32.CloseHandle.restype = wintypes.BOOL
    return k32


def _state():
    import ctypes
    from ctypes import wintypes

    class PROCESS_POWER_THROTTLING_STATE(ctypes.Structure):
        _fields_ = [("Version", wintypes.ULONG), ("ControlMask", wintypes.ULONG), ("StateMask", wintypes.ULONG)]
    return PROCESS_POWER_THROTTLING_STATE


def set_priority(name: str, handle=None) -> Optional[str]:
    """Set this process's (or `handle`'s) priority class. None when done, else why not."""
    if os.name != "nt":
        return "not Windows"
    import ctypes
    k32 = _k32()
    h = handle if handle is not None else k32.GetCurrentProcess()
    if not k32.SetPriorityClass(h, PRIORITY_CLASSES[name]):
        return f"SetPriorityClass failed ({ctypes.get_last_error()})"
    return None


def set_high_qos(handle=None) -> Optional[str]:
    """Opt this process (or `handle`) out of execution-speed throttling. None when done."""
    if os.name != "nt":
        return "not Windows"
    import ctypes
    k32 = _k32()
    h = handle if handle is not None else k32.GetCurrentProcess()
    st = _state()(POWER_THROTTLING_VERSION, THROTTLING_EXECUTION_SPEED, 0)
    if not k32.SetProcessInformation(h, PROCESS_POWER_THROTTLING, ctypes.byref(st), ctypes.sizeof(st)):
        return f"SetProcessInformation failed ({ctypes.get_last_error()})"
    return None


def read_qos(handle=None):
    """(ControlMask, StateMask) of this process or `handle`, or None where it cannot be read."""
    if os.name != "nt":
        return None
    import ctypes
    k32 = _k32()
    h = handle if handle is not None else k32.GetCurrentProcess()
    st = _state()(POWER_THROTTLING_VERSION, 0, 0)
    if not k32.GetProcessInformation(h, PROCESS_POWER_THROTTLING, ctypes.byref(st), ctypes.sizeof(st)):
        return None
    return int(st.ControlMask), int(st.StateMask)


def read_priority(handle=None) -> Optional[int]:
    if os.name != "nt":
        return None
    k32 = _k32()
    v = k32.GetPriorityClass(handle if handle is not None else k32.GetCurrentProcess())
    return int(v) or None


def apply_to_pid(pid: int, priority: Optional[str], high_qos: bool) -> Optional[str]:
    """Another process by pid (a decoder): open it, set what is asked, close it."""
    if os.name != "nt":
        return "not Windows"
    k32 = _k32()
    h = k32.OpenProcess(PROCESS_SET_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
    if not h:
        return "it could not be opened (ended, or not ours)"
    try:
        errs = [e for e in ((set_priority(priority, h) if priority else None),
                            (set_high_qos(h) if high_qos else None)) if e]
        return "; ".join(errs) or None
    finally:
        k32.CloseHandle(h)


def apply_to_self(env=None, who: str = "the worker") -> list:
    """What WT_LABS_PRIORITY / WT_LABS_HIGHQOS ask, applied to this process; one note per
    setting, for the log and the status file. Never raises: a setting that cannot be applied
    is said, and the worker runs as it was."""
    env = env if env is not None else os.environ
    notes = []
    raw = env.get("WT_LABS_PRIORITY", "").strip()
    pr = wanted_priority(env)
    if raw and pr is None:
        notes.append(f"WT_LABS_PRIORITY={raw!r} is not idle, belownormal or normal: ignored")
    hq = wanted_high_qos(env)
    if (pr or hq) and os.name != "nt":
        notes.append("WT_LABS_PRIORITY / WT_LABS_HIGHQOS are for Windows stations: ignored here "
                     "(a Linux station sets its priority in the service unit)")
        return notes
    try:
        if pr:
            e = set_priority(pr)
            notes.append(f"{who}: priority {pr}" + (f" NOT set: {e}" if e else ""))
        if hq:
            e = set_high_qos()
            notes.append(f"{who}: execution-speed throttling off (HighQoS)" + (f" NOT set: {e}" if e else ""))
    except Exception as e:                   # ctypes on an old Windows without the call
        notes.append(f"{who}: could not set its priority or QoS: {type(e).__name__}: {e}")
    return notes


class DecoderSweep:
    """In a unit process: every SWEEP_EVERY_S, the settings for each child (its decoders)
    that has not had them yet. Children are listed with psutil; without it a unit cannot list
    them (Windows has no /proc), and says so once."""

    def __init__(self, priority: Optional[str], high_qos: bool, *,
                 children: Optional[Callable[[], Iterable[int]]] = None,
                 apply: Callable[[int, Optional[str], bool], Optional[str]] = apply_to_pid,
                 every_s: float = SWEEP_EVERY_S):
        self.priority, self.high_qos, self.apply, self.every_s = priority, high_qos, apply, every_s
        self.children = children or self._psutil_children
        self.done: set = set()
        self.said = False
        self._stop = threading.Event()

    @staticmethod
    def _psutil_children():
        import psutil                         # present on the office; see the class doc
        return [c.pid for c in psutil.Process().children(recursive=True)]

    def once(self) -> None:
        try:
            pids = list(self.children())
        except Exception as e:
            if not self.said:
                self.said = True
                log.warning("labs: this unit cannot list its decoders to set their QoS: %s: %s",
                            type(e).__name__, e)
            return
        for pid in pids:
            if pid in self.done:
                continue
            self.done.add(pid)                # once per decoder, whatever the answer
            err = self.apply(pid, self.priority, self.high_qos)
            if err and err != "it could not be opened (ended, or not ours)" and not self.said:
                self.said = True
                log.warning("labs: a decoder's QoS could not be set: %s", err)

    def start(self) -> "DecoderSweep":
        def run():
            while not self._stop.wait(self.every_s):
                self.once()
        threading.Thread(target=run, name="labs-qos-sweep", daemon=True).start()
        return self

    def stop(self) -> None:
        self._stop.set()
