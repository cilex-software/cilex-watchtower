"""One lane per analyser: each one claims and runs on its own (worker-0.3.5).

The operator's requirement, 2026-09-29, relayed by cilex-vision
(docs/letters/2026-09-29-each-analyser-runs-on-its-own-cilex-vision.md): "other analyser
must run in separate threads and if one analyser is stuck it should not affect others".
Up to worker-0.3.4 the station ran ONE pass over its analysers in alphabetical order
(run_worker.py:359 at 2fd1b54), and the first busy claim ended the pass for a minute
(:337-340, :345-348). After the v17 reconnect cilex-vision measured 11 claims in 8 minutes
from the stations, 10 of them audio_energy -- first in the alphabet -- and 9 timed out.

Now:
  * Each analyser is a LANE with its own claim, its own wait after a busy or refused
    claim, and its own unit. A lane that is refused, busy or stuck waits by itself; the
    others keep claiming.
  * The rules that are the STATION's stay in one place, decided here: the local hold, the
    server's orders (or the local flag on a server without them), and a station that cannot
    start its decoder or whose token is refused.
  * NO STATION-WIDE CAP (worker-0.3.8, the operator, 2026-09-29: "i define how many analysers
    run in parallel - that is defined by how many hoses are connected to the machine, each
    analyser inside Cilex Watchtower runs in a separate thread and is prioritised by the
    operating system"). Every connected, playing lane runs its own unit at the same time as
    the others, ONE PER LANE; to run fewer, the operator unplugs hoses. The protection is the
    operating system's priority -- the service runs at idle CPU and IO priority, and the
    unit processes and their decoders inherit it -- and the wall guard's hold. Until 0.3.8 a
    `slots` count (1 on every station) made the lanes take turns; the operator never asked
    for it. ONE EXCEPTION: the in-process runner (a station that cannot start unit
    processes) shares this process's per-unit state, so it still runs one unit at a time.
  * FILL, opt-in per station (worker-0.3.10; the operator, 2026-09-30, relayed by cilex-vision:
    "ok do office PC only to run analyser for vehicles but use full capacity of this PC to the
    limit"). With --fill or WT_LABS_FILL=1, a connected lane that is getting work takes ONE MORE
    unit, in an extra slot of its own, while this machine measures room for it:
      - at least one logical CPU idle over the last `fill_window_s`;
      - free memory for FILL_MEM_FACTOR of the largest unit of that analyser measured so far;
      - fewer claims and units in hand than logical CPUs. Units waiting on downloads leave the
        CPU idle, and would otherwise be added without end.
    No count is ours: the machine's own measurements decide. It adds at most one unit every
    `fill_every_s`, so each look sees the last one working. An extra slot goes when its claim
    finds nothing or is refused (the lane's waits stay with its first slot), when free memory no
    longer holds another unit, and on a hold, a pause, a server stop or a fatal pause. So after
    the wall guard's hold the station fills again from one unit per lane. Without the flag,
    nothing changes.
    LEASES (worker-0.3.11; the office, 2026-09-30 09:23: 16 at once, the server's serving rate
    the limit and not the machine, three units ran past their 20-min lease and were thrown away).
    Fill acts on the latest acknowledged lease while units are in flight:
      - while ANY unit in hand is past FILL_LEASE_SHARE of its lease, an extra slot whose unit
        ends does not claim again -- the width falls at once and the late units get the rest;
      - a unit that ends past that share caps its analyser at floor(N x share / used), N being
        its units in hand then (16 at 101 % -> 11), for one lease length; each lease length
        with no overrun after that allows one more (AIMD), instead of refilling at once.
    Since worker-0.3.13, a report's renewed deadline starts a new lease window. Its age
    is independent of the unit's total runtime. Older servers keep the claim's deadline.
  * Lanes start in queue order: a lane that has just had its turn queues behind the lanes
    that were waiting, and the first order is shuffled at every start, so no analyser is
    always first (the letter's point 4).
  * Every decision is made on ONE thread, by tick(). Claims and units run elsewhere, on
    an executor: threads in production, with each unit in a process of its own
    (unit_proc.ProcessRunner); in the tests the executor runs each one at once, on the
    same thread, which keeps them deterministic on a fake clock.
"""
from __future__ import annotations

import logging
import os
import random
import sys
import threading
import time
from collections import deque
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Callable, Optional

import station as S
import worker as W

log = logging.getLogger("labs.lanes")

# A claim refused RETRY_LATER is asked again after 2, 4, 8, 16 and 32 s -- by its lane
# alone, the other lanes going on meanwhile -- then waits the lane's `busy_s`.
MAX_CLAIM_RETRIES = 5
# The station check (can this station START its decoder?) runs before claims, at most
# this often: it is a real `ffmpeg -version`.
STATION_CHECK_EVERY_S = 60.0
# Fill: free memory must hold this many of the largest unit measured so far -- the next one,
# and room for the units in hand to grow, since a unit's memory grows as it runs.
FILL_MEM_FACTOR = 2.0
# Fill measures the units' own memory this often. Walking the process trees costs more than
# reading the machine's counters, which is done at every tick.
FILL_UNIT_SAMPLE_S = 5.0
# ...and keeps this much CPU history, enough for any window it is asked about.
FILL_KEEP_S = 300.0
# A unit's lease starts at its claim; reports may renew it (CV's 2026-09-30 contract).
# A unit whose lease runs out is thrown away and its hour is
# queued again. So fill adds nothing while a unit in hand has used more than this share of
# its lease, and gives back an extra slot whose unit used more. It is a margin of ours: the
# office's slowest Vehicles unit that night took 15.4 min of the 20.
FILL_LEASE_SHARE = 0.75
# cilex-vision refuses a report whose `holding` lists more units than this (routers/labs.py:3521,
# HTTP 422), and a station whose reports are refused gets no claims. Fill stays below it.
REPORT_HOLDING_MAX = 32


@dataclass
class Timing:
    """How long each kind of wait lasts."""
    poll_s: float = 1.0           # the tick while the server governs (its orders arrive every ~2 s)
    legacy_poll_s: float = 5.0    # ...and against a server without the control plane
    idle_s: float = 120.0         # a lane with nothing to claim looks again in two minutes
    busy_s: float = 60.0          # the server answered busy, or did not answer: this lane waits a minute
    fatal_s: float = 600.0        # the STATION cannot work (token refused, decoder will not start)
    not_reporting_s: float = 5.0  # the server has no recent report from us: report, ask again soon
    rest_s: float = 900.0         # a lane whose claim was refused in a way nobody expected, or whose
                                  # unit stopped making progress, rests this long
    fill_every_s: float = 30.0    # fill: at most one more unit this often, so each look sees the last
                                  # one past its start...
    fill_window_s: float = 15.0   # ...judged on the idle CPU of this much of the latest past


def unit_summary(o: W.UnitOutcome) -> dict:
    """One unit, as the Labs screen shows it."""
    outcome = (("failed" if o.filed_failed else "done") if o.submitted
               else "revoked" if o.action is W.Action.REVOKED else "abandoned")
    return {"analyzer": o.unit.analyzer, "camera_id": o.unit.camera_id,
            "hour_start": o.unit.hour_start, "outcome": outcome,
            "observations": o.observations, "segments": o.segments_scanned,
            "note": W.fit(o.note or "", 200), "seconds": o.timings.get("total_s"),
            "phases": {k: o.timings.get(k) for k in ("fetch_s", "decode_s", "analyse_s") if k in o.timings},
            "at": S.now_iso()}


class SyncExecutor:
    """Runs each claim or unit at once, on the calling thread. The tests' executor: with it
    the scheduler is deterministic, and a fake clock is the only clock."""

    def submit(self, fn, *a, **k) -> Future:
        f: Future = Future()
        try:
            f.set_result(fn(*a, **k))
        except BaseException as e:            # the scheduler reads it as the op's failure
            f.set_exception(e)
        return f

    def shutdown(self, wait: bool = True) -> None:
        pass


class InProcessRunner:
    """Runs a unit in THIS process, as worker-0.3.4 did. For the tests, and for a station
    that cannot start unit processes (--in-process). It shares worker.py's per-process
    state (`_abort_check`, `_heard`), so the scheduler runs ONE of its units at a time."""

    single_slot = True

    def __init__(self, client, *, decode, abort_reason: Callable[[W.ScanUnit], Optional[str]] = lambda u: None,
                 tmpdir: Optional[str] = None, sleep: Callable[[float], None] = time.sleep):
        self.client, self.decode, self.abort_reason = client, decode, abort_reason
        self.tmpdir, self.sleep = tmpdir, sleep
        self.states: dict = {}

    def run(self, unit: W.ScanUnit, plugin) -> W.UnitOutcome:
        return W.run_unit(self.client, plugin, unit, decode=self.decode, states=self.states,
                          tmpdir=self.tmpdir, sleep=self.sleep, abort_check=lambda: self.abort_reason(unit))

    def abort(self, unit: W.ScanUnit, why: str):
        return None            # its checkpoints ask abort_reason; nothing to kill from here

    def abort_all(self, why: str) -> None:
        pass


class MachineProbe:
    """What fill measures on this machine, through vitals.py:
      - the idle CPU over a recent window (psutil, /proc, or ctypes on Windows);
      - free memory;
      - the largest process tree one unit of each analyser has had: its process plus its
        decoders (psutil or /proc). Windows without psutil cannot walk a tree, so there fill
        never adds a unit, and says why."""

    def __init__(self, runner, *, machine=None, tree=None, can_walk: Optional[bool] = None):
        import vitals as V
        self.runner = runner
        self._machine = machine or V.machine
        self._tree = tree or V.tree
        self.can_walk = ((V.psutil is not None or sys.platform.startswith("linux"))
                         if can_walk is None else bool(can_walk))
        self.cores: Optional[int] = None
        self.free: Optional[int] = None           # bytes the OS calls available
        self._cpu: deque = deque()                # (t, busy, total), one per tick
        self._peak: dict = {}                     # analyser -> largest one-unit tree seen, bytes
        self._walked_at: Optional[float] = None
        self.error: Optional[str] = None          # the last thing it failed to measure

    def sample(self, now: float) -> None:
        """Called at every tick, on the scheduler's thread. A measurement that fails leaves that
        figure unknown -- so fill adds nothing -- and never stops the worker."""
        try:
            m = self._machine()
        except Exception as e:
            self._failed(f"this machine's CPU and memory: {type(e).__name__}: {e}")
            self.free = None
            self._cpu.clear()                     # no stale window either
        else:
            self.cores = m.cores
            self.free = (m.mem_total - m.mem_used) if m.mem_total is not None and m.mem_used is not None else None
            if m.busy is not None and m.total is not None:
                self._cpu.append((now, m.busy, m.total))
            while len(self._cpu) > 2 and now - self._cpu[0][0] > FILL_KEEP_S:
                self._cpu.popleft()
        if self.can_walk and (self._walked_at is None or now - self._walked_at >= FILL_UNIT_SAMPLE_S):
            self._walked_at = now
            try:
                pids = list(getattr(self.runner, "unit_pids", lambda: [])())
            except Exception as e:
                self._failed(f"the units' processes: {type(e).__name__}: {e}")
                pids = []
            for analyzer, pid in pids:
                try:
                    t = self._tree(pid)
                except Exception as e:
                    self._failed(f"a unit's memory: {type(e).__name__}: {e}")
                    continue
                if t is not None:                 # None: it ended between the list and the walk
                    self._peak[analyzer] = max(self._peak.get(analyzer, 0), int(t.rss))

    def _failed(self, why: str) -> None:
        if why != self.error:                     # said once, not at every tick
            self.error = why
            log.warning("labs: fill cannot measure %s", why)

    def idle_cores(self, now: float, window_s: float) -> Optional[float]:
        """Logical CPUs' worth left idle over the last `window_s`, or None until a whole
        window has been measured."""
        if not self.cores or len(self._cpu) < 2:
            return None
        old = None
        for s in self._cpu:
            if s[0] > now - window_s:
                break
            old = s
        if old is None:
            return None
        _, b1, n1 = self._cpu[-1]
        _, b0, n0 = old
        if n1 <= n0:
            return None
        return max(0.0, 1.0 - (b1 - b0) / (n1 - n0)) * self.cores

    def unit_bytes(self, analyzer: str) -> Optional[int]:
        return self._peak.get(analyzer) if self.can_walk else None


def _lease_s(unit: W.ScanUnit, wall: datetime) -> Optional[float]:
    """How long this unit's lease runs from `wall` (its claim), from the server's own
    lease_expires_at; None when the server named none or it cannot be read."""
    s = getattr(unit, "lease_expires_at", None)
    if not s:
        return None
    try:
        t = datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=timezone.utc)
    return (t - wall).total_seconds()


def _ukey(u: W.ScanUnit):
    return (u.analyzer, u.camera_id, u.hour_start)


def _mb(n) -> str:
    return "unknown" if n is None else f"{n / 2**20:.0f} MB"


class Lane:
    """One analyser: its own claim, its own waits, its own unit. Fill (opt-in) adds EXTRA
    lanes for an analyser that is getting work -- one more unit each, named `<analyser>+<n>`;
    an extra never waits (it goes instead), and the Labs screen shows only the first."""

    def __init__(self, name: str, analyzer: Optional[str] = None):
        self.name = name
        self.analyzer = analyzer or name          # what it claims for
        self.extra = self.analyzer != name        # made by fill
        self.retire = False                       # an extra to give back when its work in hand ends
        self.state = "waiting"
        self.note = ""
        self.until: Optional[float] = None        # no claim before this (its own wait)...
        self.until_iso: Optional[str] = None
        self.wake_sig = None                      # ...unless the server's lane modes change from this
        self.tries = 0                            # RETRY_LATER at claim, in a row
        self.op: Optional[Future] = None          # its claim or its unit, in flight
        self.op_kind: Optional[str] = None        # "claim" | "unit"
        self.unit: Optional[W.ScanUnit] = None
        self.backlog: list = []                   # units a claim returned beyond the first
        self.plugin = None
        self.started_seq = 0                      # when its unit started, in scheduler order


class Scheduler:
    """The station's coordinator: one lane per analyser, the station's rules in one place."""

    def __init__(self, client, supported: Callable[[], list], *, runner, hb, names: list,
                 control: Callable[[], dict] = S.read_control, reporter=None,
                 station_check: Optional[Callable[[], Optional[str]]] = None,
                 executor=None, clock: Callable[[], float] = time.monotonic,
                 sleep: Optional[Callable[[float], None]] = None, timing: Optional[Timing] = None,
                 order: Optional[list] = None, rng: Optional[random.Random] = None,
                 fill: Optional[MachineProbe] = None):
        self.client, self.supported, self.runner, self.hb = client, supported, runner, hb
        self.control, self.reporter, self.station_check = control, reporter, station_check
        # Every claim and unit in flight holds a thread. Fill can hold up to one per logical CPU
        # beyond the lanes' own, so the pool must never be what stops it.
        self.executor = executor or ThreadPoolExecutor(
            max_workers=max(2, 2 * len(names)) + ((os.cpu_count() or 1) if fill is not None else 0),
            thread_name_prefix="labs-lane")
        self.clock, self._sleep = clock, sleep
        self.t = timing or Timing()
        # A runner that shares this process's per-unit state runs one unit at a time; every
        # other runner runs one unit per connected lane, all at once (no station-wide cap).
        self._one_at_a_time = bool(getattr(runner, "single_slot", False))
        # FILL (opt-in; the module doc): None = one unit per connected lane.
        self.fill = None if self._one_at_a_time else fill
        if fill is not None and self.fill is None:
            log.warning("labs: fill is ignored: this station runs its units in this process, one at a time")
        self._fill_at = clock()                   # the last unit fill added, the start, or a stop
        self._fill_dry: dict = {}                 # analyser -> fill adds none before this
        self._fill_made: dict = {}                # analyser -> extra lanes made so far (their names)
        self._fill_code: Optional[str] = None     # why fill adds none now (the status file)
        self._leases: dict = {}                   # unit key -> (latest lease start, monotonic; lease seconds)
        self._fill_cap: dict = {}                 # analyser -> [safe width, until (this clock), lease s]
        self.lanes = {n: Lane(n) for n in names}
        first = list(order) if order else list(names)
        if not order:
            (rng or random.Random()).shuffle(first)
        self.queue = deque(self.lanes[n] for n in first if n in self.lanes)
        self.totals = {"claimed": 0, "done": 0, "failed": 0, "abandoned": 0, "revoked": 0}
        self._fatal_until: Optional[float] = None
        self._fatal_note = ""
        self._fault_at: Optional[float] = None
        self._fault: Optional[str] = None
        self._seq = 0
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._published: Optional[dict] = None

    # ---- the station's rules (the same as worker-0.3.4's, now in one place) ----------------
    def governed(self) -> bool:
        return self.reporter is not None and self.reporter.governed()

    def allowed(self, ctl: dict):
        """(may this station claim at all, the status file's state word, why not).

        WHO DECIDES (operator decisions 2026-09-28):
          * GOVERNED -- cilex-vision's control plane answers this station's reports: the
            server's station and lane modes decide. The local `paused` flag does not.
          * Otherwise (a server without the endpoint, or no reporter) the local flag decides.
          * A local HOLD -- the wall's safety check -- stops claiming in BOTH, beats a server
            Start, and the reporter drops the units in hand when it appears.
        """
        hold = ctl.get("hold")
        if hold:
            return False, "held", "held on this station: " + str(hold.get("why"))
        if self.governed():
            st = self.reporter.station()
            mode = st.get("mode") if st else None
            if mode == "running":
                return True, "running", ""
            if mode is None:
                return False, "waiting", "no fresh orders from the server (it has not answered a report for 30 s)"
            # Not "stopped": in the status file that word means the worker PROCESS ended
            # (Heartbeat.stop), and the Labs screen must not confuse the two.
            word = "stopped_by_server" if mode == "stopped" else mode
            parts = [{"all": "every workstation", "station": "this workstation"}.get(st.get("level"), "")]
            if st.get("at"):
                parts.append(f"since {st.get('at')}")
            elif mode == "stopped":
                parts.append("never started -- an administrator starts it from the Labs page")
            return False, word, ", ".join(x for x in parts if x) or f"{mode} by the server"
        if ctl["paused"]:
            return False, "paused", ctl["why"]
        return True, "running", ""

    def lane_ok(self, name: str, ctl: dict) -> bool:
        # camera_health runs only where this station opted in: exactly one station may run
        # it, and the server does not enforce that.
        if name == "camera_health" and not ctl["camera_health"]:
            return False
        return (not self.governed()) or self.reporter.lane_mode(name) == "running"

    def lanes_sig(self):
        return tuple(sorted((self.reporter.snapshot().get("lanes") or {}).items())) if self.governed() else ()

    # ---- the tick ------------------------------------------------------------------------------
    def tick(self) -> None:
        now = self.clock()
        for lane in list(self.lanes.values()):    # a copy: fill's extra lanes may go here
            if lane.op is not None and lane.op.done():
                self._finished(lane, now)
        if self.fill is not None:
            self.fill.sample(now)
        ctl = self.control()
        ok, word, note = self.allowed(ctl)
        # Kept current in every state: what this station COULD run is shown on the Labs
        # screen whether or not it is scanning (supported() rate-limits its own reads).
        plugins = self.supported()
        if not ok:
            self._fill_stop(now)
            self._say(word)
            self._publish(word, note, ctl=ctl)
            return
        if self._fatal_until is not None and now >= self._fatal_until:
            self._fatal_until, self._fatal_note = None, ""
        if self._fatal_until is not None:
            self._fill_stop(now)
            self._say("idle")
            self._publish("fatal", self._fatal_note, ctl=ctl)
            return
        by_name = {p.name: p for p in plugins}
        runs = []
        for lane in self.lanes.values():
            lane.plugin = by_name.get(lane.analyzer)
            if not lane.extra and lane.plugin is not None and self.lane_ok(lane.name, ctl):
                runs.append(lane.name)
        busy = sum(1 for x in self.lanes.values() if x.op is not None)
        # One per lane is the only bound (a lane with work in hand is skipped below).
        free = (1 - busy) if self._one_at_a_time else len(self.lanes)
        sig = None
        for lane in list(self.queue):
            if free <= 0:
                break
            if lane.op is not None:
                continue
            if lane.extra:
                # An extra lane claims again only while its analyser runs and the machine still
                # has room for the unit it would take; otherwise it goes.
                why = ("its analyser is not running here" if lane.analyzer not in runs
                       else self._room(now, lane.analyzer, adding=False)[1])
                if why:
                    self._retire(lane, why)
                    continue
            elif lane.name not in runs:
                continue
            if lane.until is not None and now < lane.until:
                if lane.wake_sig is None:
                    continue
                sig = self.lanes_sig() if sig is None else sig
                if sig == lane.wake_sig:
                    continue                  # an admin's Start on the lane ends its wait early
            fault = self._station_fault(now)
            if fault:
                self._set_fatal(now, f"this station cannot start its decoder: {fault}")
                break
            self._start_claim(lane)
            free -= 1
        if self.fill is not None and self._fatal_until is None:
            self._fill_step(now, runs)
        self._say("idle")
        self._publish(None, None, runs=runs, ctl=ctl)

    def run(self, until: Optional[Callable[[], bool]] = None, max_ticks: Optional[int] = None) -> dict:
        n = 0
        while not self._stop.is_set():
            self.tick()
            n += 1
            if (max_ticks is not None and n >= max_ticks) or (until is not None and until()):
                break
            self._wait(self._next_wait())
        return dict(self.totals)

    def stop(self, why: str = "the worker is stopping") -> None:
        self._stop.set()
        self._wake.set()
        try:
            self.runner.abort_all(why)
        except Exception as e:
            log.warning("labs: could not stop the units in hand: %s", e)
        try:
            self.executor.shutdown(wait=False)
        except Exception:
            pass

    def abort(self, unit: W.ScanUnit, why: str):
        """The reporter's on_abort: the server took this unit back, or a hold appeared."""
        return self.runner.abort(unit, why)

    # ---- claims and units ------------------------------------------------------------------------
    def _start_claim(self, lane: Lane) -> None:
        self.queue.remove(lane)
        lane.state, lane.note, lane.until, lane.until_iso, lane.wake_sig = "claiming", "", None, None, None
        lane.op_kind = "claim"
        lane.op = self.executor.submit(self._claim_one, lane.analyzer)
        lane.op.add_done_callback(lambda _f: self._wake.set())

    def _claim_one(self, name: str):
        try:
            units, _remaining = W._guard(self.client.claim, name, 1)
            return ("units", list(units))
        except W.Refusal as r:
            return ("refused", r)

    def _start_unit(self, lane: Lane, unit: W.ScanUnit) -> None:
        self._seq += 1
        lane.unit, lane.started_seq = unit, self._seq
        lane.state, lane.note = "running", ""
        lane.op_kind = "unit"
        lane.op = self.executor.submit(self.runner.run, unit, lane.plugin)
        lane.op.add_done_callback(lambda _f: self._wake.set())

    def _finished(self, lane: Lane, now: float) -> None:
        op, kind = lane.op, lane.op_kind
        lane.op, lane.op_kind = None, None
        try:
            res = op.result()
        except BaseException as e:            # a fault in this file or the runner: THIS lane rests
            res = ("error", e)
        if kind == "claim":
            self._claimed(lane, res, now)
        else:
            self._unit_done(lane, res, now)

    def _claimed(self, lane: Lane, res, now: float) -> None:
        what, val = res
        if what == "units" and val:
            lane.tries = 0
            self.totals["claimed"] += len(val)
            wall = datetime.now(timezone.utc)
            for u in val:                     # all of them are this station's now
                self._leases[_ukey(u)] = (now, _lease_s(u, wall))
                if self.reporter is not None:
                    self.reporter.add_holding(u)
            if lane.retire:                   # the station stopped claiming meanwhile
                for u in val:
                    self._let_go(u)
                self._retire(lane, "the station stopped claiming")
                return
            lane.backlog = list(val[1:])
            self._start_unit(lane, val[0])    # the lane keeps its turn for its unit
            return
        if lane.extra:
            self._extra_claim_ended(lane, what, val, now)
            return
        self.queue.append(lane)               # its turn is over: to the back
        name = lane.name
        if what == "units":
            lane.tries = 0
            self._rest(lane, now, "idle", "nothing to claim", self.t.idle_s, wake_on_lanes=True)
            return
        if what == "error":
            log.warning("labs: claim %s failed in this worker: %r", name, val)
            self._rest(lane, now, "error", f"claim {name}: {type(val).__name__}: {val}", self.t.rest_s)
            return
        r = val
        a = W.action_for(r)
        if a is W.Action.STOP_ANALYSER:
            self._rest(lane, now, "off", f"claim {name}: switched off on the server ({r})", self.t.idle_s,
                       wake_on_lanes=True)
        elif a is W.Action.NOT_RUNNING:
            self._rest(lane, now, "not_running", f"claim {name}: the server's lane is not running ({r})",
                       self.t.idle_s, wake_on_lanes=True)
        elif a is W.Action.SERVER_BUSY:
            # It answered: say so. "Cannot reach the server" would be false. THIS lane waits.
            self._rest(lane, now, "busy", f"claim {name}: the server is busy ({r}) -- trying again in a minute",
                       self.t.busy_s)
        elif a is W.Action.NOT_REPORTING:
            if self.reporter is not None:
                self.reporter.kick()
            self._rest(lane, now, "waiting", f"claim {name}: the server has no recent report from this station ({r})",
                       self.t.not_reporting_s)
        elif a is W.Action.RETRY_LATER and lane.tries < MAX_CLAIM_RETRIES:
            lane.tries += 1
            self._rest(lane, now, "retrying", f"claim {name}: {r} -- asking again (try {lane.tries} of "
                                              f"{MAX_CLAIM_RETRIES})", min(60.0, 2.0 ** lane.tries))
        elif W._uncoded_server_error(r):
            # A 5xx with NO code is the server failing, not refusing (its claim query over its
            # 30 s timeout, CV 2026-09-28). A minute, like busy -- never the ten of FATAL.
            self._rest(lane, now, "busy", f"claim {name}: the server answered HTTP {r.status} with no code "
                                          "(not a refusal) -- trying again in a minute", self.t.busy_s)
        elif a is W.Action.FATAL and (r.status == 401 or r.detail == "station_token_not_recognised"):
            self._set_fatal(now, str(r))      # the STATION's token: every lane waits
            self._rest(lane, now, "waiting", "the server refused this station's token", self.t.fatal_s)
        elif a is W.Action.RETRY_LATER:
            lane.tries = 0
            self._rest(lane, now, "unreachable", f"claim {name}: gave up after {MAX_CLAIM_RETRIES} retries: {r}",
                       self.t.busy_s)
        else:
            # A refusal nobody expected (an unknown slug is never guessed at). It stops THIS
            # lane for the station's fatal pause; the other lanes are not its business.
            self._rest(lane, now, "error", f"claim {name}: {r} -> {a.value}", self.t.fatal_s)

    def _unit_done(self, lane: Lane, res, now: float) -> None:
        unit = lane.unit
        lane.unit = None
        if isinstance(res, tuple) and res and res[0] == "error":
            e = res[1]
            log.warning("labs: %s %s %s could not be run: %r", unit.analyzer, unit.camera_id, unit.hour_start, e)
            o = W.UnitOutcome(unit, note=W.fit(f"the unit could not be run here: {type(e).__name__}: {e}", 200))
            o.stalled = True                  # the lane rests: a runner that fails once fails again
        else:
            o = res
        used = self._lease_used(unit, now)
        rec = self._leases.pop(_ukey(unit), None)
        if self.fill is not None and used is not None and used > FILL_LEASE_SHARE:
            self._fill_overran(lane, used, rec[1] if rec else None, now)
        if self.reporter is not None:
            self.reporter.remove_holding(unit)
            self.reporter.kick()              # CONTRACT: report right after a unit finishes
        summary = unit_summary(o)
        # One line per unit with its phases and how many of its analyser were in hand, so a
        # station's log shows where a unit's time went at 16 at once against 1 (the office,
        # 2026-09-30: 720p Vehicles units at 15-23 min, the machine and the server both idle).
        # Nothing else keeps them: the server's unit table has no timings.
        tm = o.timings or {}
        f = lambda k: ("%.0f s" % tm[k]) if isinstance(tm.get(k), (int, float)) else "-"
        n_at = 1 + sum(1 for x in self.lanes.values() if x is not lane and x.analyzer == lane.analyzer
                       and x.unit is not None)
        log.warning("labs: unit %s: %s %s %s in %s (fetch %s, decode %s, analyse %s), %d of it at once%s",
                    summary["outcome"], unit.analyzer, unit.camera_id, unit.hour_start, f("total_s"),
                    f("fetch_s"), f("decode_s"), f("analyse_s"), n_at,
                    "" if used is None else ", %.0f%% of its lease" % (100 * used))
        self.totals[summary["outcome"]] = self.totals.get(summary["outcome"], 0) + 1
        self.hb.update(last_unit=summary, totals=dict(self.totals))
        if lane.backlog and not (o.station_fault or o.action is W.Action.FATAL or lane.retire):
            nxt = lane.backlog.pop(0)         # already leased to this station: run it now
            self._start_unit(lane, nxt)
            return
        for u in lane.backlog:                # never started; the server takes them back
            self._let_go(u)
        lane.backlog = []
        if lane.extra:
            self._extra_unit_ended(lane, o, used, now)
            return
        self.queue.append(lane)
        if o.station_fault:
            self._set_fatal(now, f"this station cannot start its decoder: {o.station_fault}")
            lane.state, lane.note = "waiting", ""
        elif o.action is W.Action.FATAL:
            self._set_fatal(now, o.note)
            lane.state, lane.note = "waiting", ""
        elif o.action is W.Action.STOP_ANALYSER:
            self._rest(lane, now, "off", o.note, self.t.idle_s, wake_on_lanes=True)
        elif getattr(o, "stalled", False):
            self._rest(lane, now, "rest", f"its last unit was dropped: {o.note}", self.t.rest_s)
        else:
            lane.state, lane.note = "ready", ""

    # ---- fill (opt-in; the module doc) --------------------------------------------------------------
    def _fill_step(self, now: float, runs: list) -> None:
        """Add at most ONE unit to the station, at most every `fill_every_s`: to a connected lane
        with work in hand in every slot it has (so it is getting work), whose claims have not
        lately found nothing -- the one with the fewest slots first."""
        if now - self._fill_at < self.t.fill_every_s:
            return
        want = []
        for name in runs:
            slots = [x for x in self.lanes.values() if x.analyzer == name]
            if all(x.op is not None for x in slots) and now >= self._fill_dry.get(name, float("-inf")):
                want.append((len(slots), name))
        if not want:
            self._fill_note("no_work", "no connected lane has work in hand in every slot it has")
            return
        n, name = min(want)
        code, why = self._room(now, name, adding=True)
        if code:
            self._fill_note(code, why)
            return
        fault = self._station_fault(now)
        if fault:
            self._set_fatal(now, f"this station cannot start its decoder: {fault}")
            return
        p = self.fill
        log.warning("labs: fill: %s takes one more unit, %d at once: %.1f of %s logical CPUs idle over the "
                    "last %g s, free memory %s, its largest unit %s", name, n + 1,
                    p.idle_cores(now, self.t.fill_window_s) or 0.0, p.cores, self.t.fill_window_s,
                    _mb(p.free), _mb(p.unit_bytes(name)))
        self._fill_note(None, "")
        self._fill_made[name] = self._fill_made.get(name, 0) + 1
        lane = Lane(f"{name}+{self._fill_made[name]}", analyzer=name)
        lane.plugin = self.lanes[name].plugin
        self.lanes[lane.name] = lane
        self.queue.append(lane)
        self._fill_at = now
        self._start_claim(lane)

    def _room(self, now: float, analyzer: str, adding: bool):
        """(None, "") when this machine has room for one more claim of `analyzer`, else (a
        code for the status file, why not). `adding`: a unit fill would add, which must also
        find the CPU idle and no unit in hand near the end of its lease; without it, an extra
        lane about to claim again after its unit, which only needs the room to still be there."""
        p = self.fill
        cores = p.cores or os.cpu_count()
        if not cores:
            return "cpu", "this machine's number of logical CPUs is unknown"
        in_hand = (sum(1 for x in self.lanes.values() if x.op is not None)
                   + sum(len(x.backlog) for x in self.lanes.values()))
        if in_hand >= min(cores, REPORT_HOLDING_MAX):
            return "ceiling", (f"{in_hand} claims and units in hand, as many as this machine's {cores} logical CPUs"
                               if cores <= REPORT_HOLDING_MAX else
                               f"{in_hand} claims and units in hand, the most a report may list ({REPORT_HOLDING_MAX})")
        slots = sum(1 for x in self.lanes.values() if x.analyzer == analyzer)
        cap = self._fill_cap_of(analyzer, now)
        # An extra lane about to claim again counts itself among the slots; a unit fill would
        # add does not exist yet.
        if cap is not None and (slots >= cap if adding else slots > cap):
            return "lease_cap", (f"{cap} at once is {analyzer}'s safe width for now: a unit ran past "
                                 f"{FILL_LEASE_SHARE:.0%} of its lease with more at once")
        late = [s for s in (self._lease_used(u, now) for u in self._in_hand_units()) if s is not None
                and s > FILL_LEASE_SHARE]
        if late:
            return "lease", (f"{len(late)} unit(s) in hand past {FILL_LEASE_SHARE:.0%} of their lease "
                             f"(the furthest at {max(late):.0%}): fewer at once until they end")
        unit = p.unit_bytes(analyzer)
        if unit is None:
            if not p.can_walk:
                return "unmeasurable", "this station cannot measure a unit's memory (it has no psutil)"
            return "measuring", f"no {analyzer} unit has been measured yet"
        if p.free is None:
            return "memory", "this machine's free memory is unknown"
        if p.free < FILL_MEM_FACTOR * unit:
            return "memory", (f"free memory {_mb(p.free)} holds fewer than {FILL_MEM_FACTOR:g} of the largest "
                              f"{analyzer} unit ({_mb(unit)})")
        if not adding:
            return None, ""
        idle = p.idle_cores(now, self.t.fill_window_s)
        if idle is None:
            return "measuring", "the idle CPU is still being measured"
        if idle < 1.0:
            return "cpu", f"{idle:.1f} of {cores} logical CPUs idle over the last {self.t.fill_window_s:g} s"
        return None, ""

    def _fill_overran(self, lane: Lane, used: float, lease_s: Optional[float], now: float) -> None:
        """A unit of this analyser ended past FILL_LEASE_SHARE of its lease: cap the analyser at
        the width that share suggests, for one lease length (the module doc)."""
        if not (lease_s and lease_s > 0):
            return                            # a lease already over at its claim says nothing of width
        a = lane.analyzer
        n = 1 + sum(1 for x in self.lanes.values() if x is not lane and x.analyzer == a and x.unit is not None)
        cap = max(1, int(n * FILL_LEASE_SHARE / used))
        old = self._fill_cap.get(a)
        if old is not None:
            cap = min(cap, old[0])
        self._fill_cap[a] = [cap, now + lease_s, lease_s]
        log.warning("labs: fill: a %s unit used %.0f%% of its lease with %d at once: at most %d at once for "
                    "the next %.0f min", a, 100 * used, n, cap, lease_s / 60)

    def _fill_cap_of(self, analyzer: str, now: float) -> Optional[int]:
        """Its safe width now, or None. A whole lease length with no overrun allows one more; the
        cap goes once it reaches the machine's ceiling."""
        c = self._fill_cap.get(analyzer)
        if c is None:
            return None
        while now >= c[1]:
            c[0] += 1
            c[1] += c[2]
            ceiling = min(self.fill.cores or os.cpu_count() or 1, REPORT_HOLDING_MAX)
            if c[0] >= ceiling:
                del self._fill_cap[analyzer]
                log.warning("labs: fill: %s has run within its leases long enough: no cap now", analyzer)
                return None
            log.warning("labs: fill: %s may run %d at once now (a lease length with no unit past %.0f%%)",
                        analyzer, c[0], 100 * FILL_LEASE_SHARE)
        return c[0]

    def _fill_note(self, code: Optional[str], why: str) -> None:
        if code != self._fill_code:
            self._fill_code = code
            if code:
                log.warning("labs: fill adds no unit now: %s", why)

    def _fill_stop(self, now: float) -> None:
        """The station stopped claiming (a hold, a pause, a server stop, a fatal pause): every
        extra lane goes -- one with work in hand once that ends -- and fill starts again from one
        unit per lane, no sooner than `fill_every_s` after claiming resumes."""
        if self.fill is None:
            return
        self._fill_at = now
        self._fill_note("stopped", "the station is not claiming")
        for lane in list(self.lanes.values()):
            if lane.extra:
                if lane.op is None:
                    self._retire(lane, "the station stopped claiming")
                else:
                    lane.retire = True

    def _extra_claim_ended(self, lane: Lane, what, val, now: float) -> None:
        """An extra lane's claim brought no unit: it goes, and fill leaves its analyser alone
        for `idle_s`. Waiting, retrying and backing off stay with the lane's first."""
        if what == "units":
            why = "its claim found nothing"
        elif what == "error":
            log.warning("labs: claim %s failed in this worker: %r", lane.analyzer, val)
            why = f"its claim failed here: {type(val).__name__}: {val}"
        else:
            r, a = val, W.action_for(val)
            if a is W.Action.FATAL and (r.status == 401 or r.detail == "station_token_not_recognised"):
                self._set_fatal(now, str(r))  # the STATION's token: every lane waits
            elif a is W.Action.NOT_REPORTING and self.reporter is not None:
                self.reporter.kick()
            why = f"its claim was refused: {r}"
        self._fill_dry[lane.analyzer] = now + self.t.idle_s
        self._retire(lane, why)

    def _extra_unit_ended(self, lane: Lane, o: W.UnitOutcome, used: Optional[float], now: float) -> None:
        """An extra lane's unit ended: it claims again, unless the station stopped, the unit could
        not run, or it used so much of its lease that this many at once is too many."""
        if o.station_fault:
            self._set_fatal(now, f"this station cannot start its decoder: {o.station_fault}")
        elif o.action is W.Action.FATAL:
            self._set_fatal(now, o.note)
        why = ("the station stopped claiming" if lane.retire
               else "its unit could not run here" if (o.station_fault or o.action is W.Action.FATAL)
               else "its analyser was switched off on the server" if o.action is W.Action.STOP_ANALYSER
               else f"its unit was dropped: {o.note}" if getattr(o, "stalled", False)
               else f"its unit used {used:.0%} of its lease" if used is not None and used > FILL_LEASE_SHARE
               else "")
        if why:
            self._retire(lane, why)
            return
        self.queue.append(lane)
        lane.state, lane.note = "ready", ""

    def _retire(self, lane: Lane, why: str) -> None:
        """An extra lane goes -- never a lane's first: fill made it, fill takes it back."""
        if lane in self.queue:
            self.queue.remove(lane)
        self.lanes.pop(lane.name, None)
        left = sum(1 for x in self.lanes.values() if x.analyzer == lane.analyzer)
        log.warning("labs: fill: %s gives back an extra unit slot, %d left: %s", lane.analyzer, left, W.fit(why, 200))

    def _in_hand_units(self) -> list:
        return ([x.unit for x in self.lanes.values() if x.unit is not None]
                + [u for x in self.lanes.values() for u in x.backlog])

    def _lease_used(self, unit: W.ScanUnit, now: float) -> Optional[float]:
        """The share of its lease this unit has used, or None when the server named no lease."""
        key = _ukey(unit)
        rec = self._leases.get(key)
        if rec is not None and self.reporter is not None:
            renewed = self.reporter.lease(unit)
            if renewed is not None:
                # Also read before _unit_done computes its overrun cap: a report can
                # arrive on the very tick the unit finishes. The reporter never writes
                # this dict from its thread, and never re-anchors an unchanged expiry.
                self._leases[key] = rec = renewed
        if not rec or rec[1] is None:
            return None
        if rec[1] <= 0:
            return float("inf")               # it had run out when the claim came back
        return max(0.0, now - rec[0]) / rec[1]

    def _let_go(self, u: W.ScanUnit) -> None:
        """A unit claimed and never started: once no report lists it, the server takes it back."""
        self._leases.pop(_ukey(u), None)
        if self.reporter is not None:
            self.reporter.remove_holding(u)

    # ---- waits -------------------------------------------------------------------------------------
    def _rest(self, lane: Lane, now: float, state: str, note: str, seconds: float, wake_on_lanes: bool = False):
        lane.state, lane.note = state, W.fit(note, 300)
        lane.until = now + seconds
        lane.until_iso = (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat(timespec="seconds")
        lane.wake_sig = self.lanes_sig() if wake_on_lanes else None

    def _set_fatal(self, now: float, note: str) -> None:
        if self._fatal_until is None:
            log.warning("labs: this station stops claiming for %d s: %s", int(self.t.fatal_s), note)
        self._fatal_until, self._fatal_note = now + self.t.fatal_s, W.fit(note, 300)

    def _station_fault(self, now: float) -> Optional[str]:
        """A station that cannot START its decoder claims nothing: every unit it took would
        fail the same way and spend one of its three attempts (the office, 2026-09-29)."""
        if self.station_check is None:
            return None
        if self._fault_at is None or now - self._fault_at >= STATION_CHECK_EVERY_S or self._fault:
            self._fault, self._fault_at = self.station_check(), now
        return self._fault

    def _next_wait(self) -> float:
        now = self.clock()
        if any(x.op is not None and x.op.done() for x in self.lanes.values()):
            return 0.0
        t = self.t.poll_s if self.governed() else self.t.legacy_poll_s
        # Only a wait still in the FUTURE can shorten the sleep. A lane whose rest has already
        # run out and that the last tick did not claim is blocked by something else -- the
        # station is held or paused, the server has the lane stopped, the one-at-a-time runner
        # is busy -- so waking early for it achieves nothing: it is tried at the next poll
        # anyway. Counting it as 0 made run() spin: a held booth worker (worker-0.3.8) used
        # 9.58 CPU-s in 10 s, 96 % of a core, from the 00:11 hold on (the Windows agent,
        # 2026-09-30).
        for x in self.lanes.values():
            if x.op is None and x.until is not None and x.until > now:
                t = min(t, x.until - now)
        if self._fatal_until is not None and self._fatal_until > now:
            t = min(t, self._fatal_until - now)
        return t

    def _wait(self, seconds: float) -> None:
        if self._sleep is not None:           # a fake clock (tests)
            self._sleep(seconds)
            return
        self._wake.wait(seconds)
        self._wake.clear()

    # ---- what the Labs screen and the server are told ---------------------------------------------
    def _say(self, word: str) -> None:
        if self.reporter is not None:
            self.reporter.set_state({"held": "paused", "paused": "paused",
                                     "stopped_by_server": "stopped"}.get(word, "idle"))

    def _publish(self, word, note, runs=None, ctl=None) -> None:
        running = sorted((x for x in self.lanes.values() if x.unit is not None), key=lambda x: x.started_seq)
        firsts = [x for x in self.lanes.values() if not x.extra]     # the Labs screen's lanes
        if word is None:
            listed = [x for x in firsts if runs is None or x.name in runs]
            if self._fatal_until is not None:
                word, note = "fatal", self._fatal_note      # set during this very tick
            elif running:
                word, note = "running", ""
            elif any(x.state == "unreachable" for x in listed):
                word, note = "unreachable", next(x.note for x in listed if x.state == "unreachable")
            elif any(x.state == "busy" for x in listed):
                word, note = "busy", next(x.note for x in listed if x.state == "busy")
            else:
                word = "idle"
                note = ("nothing to claim for the analysers switched on" if runs
                        else "no analyser can run on this station right now")
        fields = {"state": word, "note": W.fit(note or "", 300),
                  # The Labs screen names ONE analyser (a string): the latest started; `units`
                  # lists every unit in hand: one per lane, more where fill added some.
                  "current": running[-1].analyzer if running else None,
                  "units": [{"analyzer": x.unit.analyzer, "camera_id": x.unit.camera_id,
                             "hour_start": x.unit.hour_start} for x in running],
                  "lane_states": {x.name: {"state": x.state, "note": x.note, "until": x.until_iso}
                                  for x in firsts}}
        if self.fill is not None:
            # Fill's slots per analyser (only where it added any), and why it adds none now.
            slots: dict = {}
            for x in self.lanes.values():
                slots[x.analyzer] = slots.get(x.analyzer, 0) + 1
            fields["fill"] = {"slots": {a: n for a, n in sorted(slots.items()) if n > 1},
                              "not_adding": self._fill_code}
        if runs is not None:
            fields["runs"] = runs
        if ctl is not None:
            fields["camera_health"] = ctl["camera_health"]
        if fields != self._published:         # the file is rewritten when what it says changes
            self._published = fields
            self.hb.update(**fields)
