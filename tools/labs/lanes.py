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
    server's orders (or the local flag on a server without them), a station that cannot
    start its decoder or whose token is refused, and SLOTS -- how many claims and units
    may be in flight at once.
  * Slots go first come, first served. A lane that has just had its turn queues behind
    the lanes that were waiting, and the first order is shuffled at every start, so no
    analyser is always first (the letter's point 4).
  * Every decision is made on ONE thread, by tick(). Claims and units run elsewhere, on
    an executor: threads in production, with each unit in a process of its own
    (unit_proc.ProcessRunner); in the tests the executor runs each one at once, on the
    same thread, which keeps them deterministic on a fake clock.
"""
from __future__ import annotations

import logging
import random
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
# alone, which gives its slot back meanwhile -- then waits the lane's `busy_s`.
MAX_CLAIM_RETRIES = 5
# The station check (can this station START its decoder?) runs before claims, at most
# this often: it is a real `ffmpeg -version`.
STATION_CHECK_EVERY_S = 60.0


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


def unit_summary(o: W.UnitOutcome) -> dict:
    """One unit, as the Labs screen shows it."""
    outcome = (("failed" if o.filed_failed else "done") if o.submitted
               else "revoked" if o.action is W.Action.REVOKED else "abandoned")
    return {"analyzer": o.unit.analyzer, "camera_id": o.unit.camera_id,
            "hour_start": o.unit.hour_start, "outcome": outcome,
            "observations": o.observations, "segments": o.segments_scanned,
            "note": W.fit(o.note or "", 200), "seconds": o.timings.get("total_s"),
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
    state (`_abort_check`, `_heard`), so the scheduler gives it ONE slot, never more."""

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


class Lane:
    """One analyser: its own claim, its own waits, its own unit."""

    def __init__(self, name: str):
        self.name = name
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
                 station_check: Optional[Callable[[], Optional[str]]] = None, slots: int = 1,
                 executor=None, clock: Callable[[], float] = time.monotonic,
                 sleep: Optional[Callable[[float], None]] = None, timing: Optional[Timing] = None,
                 order: Optional[list] = None, rng: Optional[random.Random] = None):
        self.client, self.supported, self.runner, self.hb = client, supported, runner, hb
        self.control, self.reporter, self.station_check = control, reporter, station_check
        self.executor = executor or ThreadPoolExecutor(max_workers=max(2, 2 * len(names)),
                                                       thread_name_prefix="labs-lane")
        self.clock, self._sleep = clock, sleep
        self.t = timing or Timing()
        # A runner that shares this process's per-unit state runs one unit at a time.
        self.slots = 1 if getattr(runner, "single_slot", False) else max(1, int(slots))
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
        for lane in self.lanes.values():
            if lane.op is not None and lane.op.done():
                self._finished(lane, now)
        ctl = self.control()
        ok, word, note = self.allowed(ctl)
        # Kept current in every state: what this station COULD run is shown on the Labs
        # screen whether or not it is scanning (supported() rate-limits its own reads).
        plugins = self.supported()
        if not ok:
            self._say(word)
            self._publish(word, note, ctl=ctl)
            return
        if self._fatal_until is not None and now >= self._fatal_until:
            self._fatal_until, self._fatal_note = None, ""
        if self._fatal_until is not None:
            self._say("idle")
            self._publish("fatal", self._fatal_note, ctl=ctl)
            return
        by_name = {p.name: p for p in plugins}
        runs = []
        for lane in self.lanes.values():
            lane.plugin = by_name.get(lane.name)
            if lane.plugin is not None and self.lane_ok(lane.name, ctl):
                runs.append(lane.name)
        free = self.slots - sum(1 for x in self.lanes.values() if x.op is not None)
        sig = None
        for lane in list(self.queue):
            if free <= 0:
                break
            if lane.op is not None or lane.name not in runs:
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
        lane.op = self.executor.submit(self._claim_one, lane.name)
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
            if self.reporter is not None:
                for u in val:                 # all of them are this station's now
                    self.reporter.add_holding(u)
            lane.backlog = list(val[1:])
            self._start_unit(lane, val[0])    # the lane keeps its slot for its unit
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
        if self.reporter is not None:
            self.reporter.remove_holding(unit)
            self.reporter.kick()              # CONTRACT: report right after a unit finishes
        summary = unit_summary(o)
        self.totals[summary["outcome"]] = self.totals.get(summary["outcome"], 0) + 1
        self.hb.update(last_unit=summary, totals=dict(self.totals))
        if lane.backlog and not (o.station_fault or o.action is W.Action.FATAL):
            nxt = lane.backlog.pop(0)         # already leased to this station: run it now
            self._start_unit(lane, nxt)
            return
        for u in lane.backlog:                # never started; the server takes them back
            if self.reporter is not None:
                self.reporter.remove_holding(u)
        lane.backlog = []
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
        for x in self.lanes.values():
            if x.op is None and x.until is not None:
                t = min(t, max(0.0, x.until - now))
        if self._fatal_until is not None:
            t = min(t, max(0.0, self._fatal_until - now))
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
        if word is None:
            listed = [x for x in self.lanes.values() if runs is None or x.name in runs]
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
                  # The Labs screen names ONE analyser (a string); with one slot there is only one.
                  "current": running[-1].name if running else None,
                  "units": [{"analyzer": x.unit.analyzer, "camera_id": x.unit.camera_id,
                             "hour_start": x.unit.hour_start} for x in running],
                  "slots": self.slots,
                  "lane_states": {x.name: {"state": x.state, "note": x.note, "until": x.until_iso}
                                  for x in self.lanes.values()}}
        if runs is not None:
            fields["runs"] = runs
        if ctl is not None:
            fields["camera_health"] = ctl["camera_health"]
        if fields != self._published:         # the file is rewritten when what it says changes
            self._published = fields
            self.hb.update(**fields)
