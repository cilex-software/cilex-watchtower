"""This station's vitals for POST /labs/station/report (cilex-vision's Labs control
plane, 2026-09-28): the whole machine's CPU and memory, and the Labs worker's own --
the worker process PLUS its ffmpeg children, which is where the decoding happens.

Contract (cilex-vision CONTRACT.md, "Station side"):
  cpu_pct         whole machine, % of ALL cores (0-100), since the previous sample
  labs_cpu_pct    the worker + its children, also % of the whole machine
  labs_rss_bytes  the worker + its children
  cores, mem_total_bytes, mem_used_bytes

Measured, never guessed: a figure this station cannot measure is None (sent as null), not
0 and not a partial sum. Sources, best first:
  * psutil when importable (Linux, macOS, Windows) -- whole process tree;
  * Linux without psutil: /proc -- whole process tree;
  * Windows without psutil: machine CPU and memory through ctypes; the process tree
    cannot be walked, so labs_* are None rather than an undercount of the worker alone.
The first sample has no "previous", so both percentages are None on it.
"""
from __future__ import annotations

import os
import re
import signal
import sys
import time
from dataclasses import dataclass
from typing import Optional

try:                                   # optional: stdlib-only stations still report
    import psutil                      # type: ignore
except Exception:                      # pragma: no cover - depends on the station
    psutil = None


@dataclass
class _Machine:
    cores: Optional[int]
    mem_total: Optional[int]
    mem_used: Optional[int]
    busy: Optional[float]              # CPU time spent working, any unit, all cores
    total: Optional[float]             # CPU time elapsed, same unit, all cores


@dataclass
class _Tree:
    cpu_s: float                       # the worker + its children, cumulative CPU seconds
    rss: int


# ---------------------------------------------------------------- the machine
def _machine_psutil() -> _Machine:
    t = psutil.cpu_times()
    idle = t.idle + getattr(t, "iowait", 0.0)
    total = sum(getattr(t, f) for f in t._fields if f not in ("guest", "guest_nice"))
    vm = psutil.virtual_memory()
    return _Machine(psutil.cpu_count(logical=True), int(vm.total), int(vm.total - vm.available),
                    total - idle, total)


def _machine_proc() -> _Machine:
    with open("/proc/stat", encoding="ascii") as f:
        parts = f.readline().split()
    # cpu user nice system idle iowait irq softirq steal [guest guest_nice]: guest time is
    # already counted inside user/nice, so only the first eight are summed.
    v = [float(x) for x in parts[1:9]]
    total, idle = sum(v), v[3] + v[4]
    mem = {}
    with open("/proc/meminfo", encoding="ascii") as f:
        for line in f:
            k, _, rest = line.partition(":")
            mem[k] = int(rest.split()[0]) * 1024
    tot, avail = mem.get("MemTotal"), mem.get("MemAvailable")
    return _Machine(os.cpu_count(), tot, (tot - avail) if tot is not None and avail is not None else None,
                    total - idle, total)


def _machine_windows() -> _Machine:    # pragma: no cover - Windows only
    import ctypes
    from ctypes import wintypes

    class FILETIME(ctypes.Structure):
        _fields_ = [("lo", wintypes.DWORD), ("hi", wintypes.DWORD)]

    class MEMSTAT(ctypes.Structure):
        _fields_ = [("dwLength", wintypes.DWORD), ("dwMemoryLoad", wintypes.DWORD),
                    ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]

    k32 = ctypes.windll.kernel32
    idle, kern, user = FILETIME(), FILETIME(), FILETIME()
    busy = total = None
    if k32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kern), ctypes.byref(user)):
        f = lambda x: (x.hi << 32 | x.lo) / 1e7
        total = f(kern) + f(user)              # kernel time INCLUDES idle on Windows
        busy = total - f(idle)
    ms = MEMSTAT()
    ms.dwLength = ctypes.sizeof(MEMSTAT)
    tot = used = None
    if k32.GlobalMemoryStatusEx(ctypes.byref(ms)):
        tot, used = int(ms.ullTotalPhys), int(ms.ullTotalPhys - ms.ullAvailPhys)
    return _Machine(os.cpu_count(), tot, used, busy, total)


def machine() -> _Machine:
    if psutil is not None:
        return _machine_psutil()
    if sys.platform.startswith("linux"):
        return _machine_proc()
    if os.name == "nt":                            # pragma: no cover
        return _machine_windows()
    return _Machine(os.cpu_count(), None, None, None, None)


# ---------------------------------------------------------------- the worker's tree
def _tree_psutil(pid: int) -> Optional[_Tree]:
    try:
        p = psutil.Process(pid)
        ct = p.cpu_times()
        # Children that have EXITED and been waited for are in children_user/system;
        # the ones still running are summed below. Together: the tree's whole history.
        cpu = ct.user + ct.system + ct.children_user + ct.children_system
        rss = p.memory_info().rss
        for c in p.children(recursive=True):
            try:
                cc = c.cpu_times()
                cpu += cc.user + cc.system
                rss += c.memory_info().rss
            except psutil.Error:
                continue                           # it exited between the two calls
        return _Tree(cpu, int(rss))
    except psutil.Error:
        return None


def _proc_stat(pid: int) -> Optional[list]:
    try:
        with open(f"/proc/{pid}/stat", encoding="ascii", errors="replace") as f:
            s = f.read()
    except OSError:
        return None
    # The command name is in parentheses and may itself contain spaces or ")".
    return s[s.rfind(")") + 2:].split()


def _children_proc(pid: int) -> list:
    """Every descendant of pid, by walking /proc for parent ids."""
    parent = {}
    for d in os.listdir("/proc"):
        if d.isdigit():
            st = _proc_stat(int(d))
            if st is not None:
                parent[int(d)] = int(st[1])
    out, frontier = [], [pid]
    while frontier:
        p = frontier.pop()
        kids = [c for c, pp in parent.items() if pp == p]
        out += kids
        frontier += kids
    return out


def _tree_proc(pid: int) -> Optional[_Tree]:
    tick = float(os.sysconf("SC_CLK_TCK"))
    page = os.sysconf("SC_PAGE_SIZE")
    st = _proc_stat(pid)
    if st is None:
        return None
    # After the ")" : state(0) ppid(1) ... utime(11) stime(12) cutime(13) cstime(14) ... rss(21)
    cpu = (int(st[11]) + int(st[12]) + int(st[13]) + int(st[14])) / tick
    rss = int(st[21]) * page
    for c in _children_proc(pid):
        cs = _proc_stat(c)
        if cs is not None:
            cpu += (int(cs[11]) + int(cs[12])) / tick
            rss += int(cs[21]) * page
    return _Tree(cpu, rss)


def tree(pid: Optional[int] = None) -> Optional[_Tree]:
    pid = pid or os.getpid()
    if psutil is not None:
        return _tree_psutil(pid)
    if sys.platform.startswith("linux"):
        return _tree_proc(pid)
    return None                                    # Windows without psutil: cannot walk it


#: What kill_children may kill: the worker's DECODERS, by name, and nothing else. It used to
#: kill every descendant. On Windows a console process owns its conhost.exe as a CHILD, so a
#: Stop on the office killed the worker's own console host (worker-0.3.2, 2026-09-29 02:13:36
#: MSK, measured by the Windows agent). After that every ffmpeg it started died at DLL init
#: (exit 0xC0000142), and about 25 units were filed failed.
_DECODER_NAME = re.compile(r"^(ffmpeg|ffprobe)[\w.-]*$", re.IGNORECASE)


def is_decoder(name: Optional[str]) -> bool:
    """ffmpeg / ffprobe, with or without .exe, and builds named after them (ffmpeg-v1144.exe)."""
    return bool(name) and bool(_DECODER_NAME.match(name.strip()))


def _proc_name(pid: int) -> str:
    try:
        with open(f"/proc/{pid}/comm", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def kill_children(pid: Optional[int] = None, procs=None) -> Optional[int]:
    """Kill the worker's DECODERS (is_decoder) -- never anything else it owns, above all not
    a console host -- and say how many. None when this station cannot find them (Windows
    without psutil): the unit then drops at its next checkpoint instead of at once.
    `procs` (tests): psutil-like objects with .name() and .kill(), in place of the tree."""
    pid = pid or os.getpid()
    if procs is not None or psutil is not None:
        n = 0
        if procs is None:
            try:
                procs = psutil.Process(pid).children(recursive=True)
            except psutil.Error:
                return 0
        for c in procs:
            try:
                if not is_decoder(c.name()):
                    continue
                c.kill()
                n += 1
            except Exception:           # psutil.Error: it exited, or cannot be touched
                pass
        return n
    if sys.platform.startswith("linux"):
        n = 0
        for c in _children_proc(pid):
            if not is_decoder(_proc_name(c)):
                continue
            try:
                os.kill(c, signal.SIGKILL)
                n += 1
            except OSError:
                pass
        return n
    return None


# ---------------------------------------------------------------- the report's numbers
class Vitals:
    """Samples for the report. Percentages are over the interval since the previous
    sample, so the first one carries None for both."""

    def __init__(self, pid: Optional[int] = None, clock=time.monotonic):
        self.pid = pid or os.getpid()
        self.clock = clock
        self._prev = None                          # (wall, machine, tree)

    def sample(self) -> dict:
        now = self.clock()
        try:
            m = machine()
        except Exception:
            m = _Machine(os.cpu_count(), None, None, None, None)
        try:
            t = tree(self.pid)
        except Exception:
            t = None
        cpu_pct = labs_pct = None
        if self._prev is not None:
            pw, pm, pt = self._prev
            if m.total is not None and pm.total is not None and m.total > pm.total:
                cpu_pct = round(max(0.0, min(100.0, 100.0 * (m.busy - pm.busy) / (m.total - pm.total))), 1)
            dt = now - pw
            if t is not None and pt is not None and dt > 0 and m.cores:
                labs_pct = round(max(0.0, min(100.0, 100.0 * (t.cpu_s - pt.cpu_s) / (dt * m.cores))), 1)
        self._prev = (now, m, t)
        return {"cores": m.cores, "mem_total_bytes": m.mem_total, "mem_used_bytes": m.mem_used,
                "cpu_pct": cpu_pct, "labs_cpu_pct": labs_pct,
                "labs_rss_bytes": t.rss if t is not None else None}


def source() -> str:
    """Which measurement path this station uses, for the log and the status file."""
    if psutil is not None:
        return f"psutil {getattr(psutil, '__version__', '?')}"
    if sys.platform.startswith("linux"):
        return "/proc"
    if os.name == "nt":
        return "ctypes (machine only; no psutil, so the worker's own figures are unknown)"
    return "none"
