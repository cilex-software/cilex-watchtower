"""Each unit in a process of its own (worker-0.3.5).

WHY A PROCESS, NOT A THREAD. A thread cannot be stopped from outside, so an analyser that
hangs would keep its lane busy for good (and, while stations ran one unit at a time until
worker-0.3.8, every other lane with it). A process can be killed. It also gives each unit its own copy of what worker.py and the
analysers keep per PROCESS:
  * the revoked/held check the checkpoints ask (worker._abort_check), and the last warning
    a failed unit is filed with (worker._heard, a handler on the ROOT logger) -- in one
    process two units would read each other's;
  * the decoders a Stop kills: vitals.kill_children(pid=<the unit's process>) finds only
    THAT unit's ffmpeg, so taking one unit back no longer kills another lane's decoders;
  * OpenCV's thread setting (plugins.pin_opencv_threads), set in each unit process.

MEASURED on the pilot box, 2026-09-29 (Python 3.12, spawn): starting a unit process and
importing the worker and its analysers takes 0.12-0.29 s and 56 MB when the BLAS/OpenMP
pools are held to one thread, and 2.3-3.2 CPU-s without that cap -- so every unit process
gets OMP/OPENBLAS/MKL/NUMEXPR_NUM_THREADS=1 unless the station already sets them.

WHAT IT COSTS: a unit starts with fresh analyser state. Two analysers keep state between
units: camera_health keeps its per-camera baseline on disk (load_state/save_state, as
before), and blob_geometry kept its model in memory for the NEXT hour of the same camera.
Claims go newest-first, so that carry rarely applied; a fresh model costs its warm-up
(measured 2026-09-27: 1 row in minute 0).

THE PROTOCOL, two one-way pipes:
  unit -> worker: ("progress",) at most every PROGRESS_EVERY_S, from each checkpoint;
                  ("log", level, logger, text) for each WARNING or worse, which the worker
                  logs where its own lines go (a spawned process on Windows does not inherit
                  the worker's redirected stderr, CreateProcess with bInheritHandles=False,
                  so its own stderr would reach a hidden console, not worker.log);
                  ("done", UnitOutcome); ("crash", traceback) before an unexpected exception.
  worker -> unit: ("abort", why) -- the server took the unit back, or a hold appeared, or
                  it stopped making progress. The unit records WHY first and answers
                  ("ack",); only then are its decoders killed (or after ACK_WAIT_S without
                  an answer). The order matters: a killed decoder makes the analyser fail,
                  and worker._file_failed records the unit REVOKED instead of filing that
                  failure only if it already knows why -- killed first, the unit could be
                  filed failed and spend one of its three attempts on the Stop's doing.
If the worker dies, the unit process sees its pipe close: it drops the unit, kills its
own decoders, and exits.
"""
from __future__ import annotations

import contextlib
import importlib
import logging
import multiprocessing as mp
import os
import shutil
import sys
import tempfile
import threading
import time
import types
from dataclasses import dataclass, field
from multiprocessing.connection import wait as mp_wait
from typing import Callable, Optional

import worker as W

log = logging.getLogger("labs.unit")

PROGRESS_EVERY_S = 2.0      # a unit says it is alive this often, at most (from its checkpoints)
WATCH_S = 0.5               # the worker looks at each unit this often
STALL_S = 600.0             # no checkpoint for ten minutes: the unit is stuck. A segment takes seconds.
GRACE_S = 30.0              # a unit told to stop that has not stopped by then is killed
ACK_WAIT_S = 2.0            # its decoders are killed when it acknowledges the stop, or after this
ORPHAN_EXIT_S = 30.0        # a unit whose worker died exits this long after dropping its work
THREAD_CAPS = ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS")


def _ref(spec_ref: str):
    mod, _, name = spec_ref.partition(":")
    return getattr(importlib.import_module(mod), name)


def http_client(spec: dict):
    """The unit's own connection to cilex-vision, with the station's token (never logged)."""
    return W.HttpLabsClient(spec["api"], spec["token"])


def production_spec(api: str, token: str) -> dict:
    return {"api": api, "token": token, "client": "unit_proc:http_client",
            "plugin": "run_worker:make_plugin", "decode": "run_worker:decode",
            "station_check": "run_worker:decoder_start_fault", "pin_opencv": True}


# ---------------------------------------------------------------------------------------------
# The unit's side
# ---------------------------------------------------------------------------------------------
def child_main(inbox, outbox, spec: dict, analyzer: str, unit: W.ScanUnit, context: dict,
               tmpdir: str) -> None:
    for k in THREAD_CAPS:                     # before numpy is imported (below, by the plugins)
        os.environ.setdefault(k, "1")
    send_lock = threading.Lock()
    state = {"why": None, "ping": 0.0}

    def send(msg) -> bool:
        with send_lock:
            try:
                outbox.send(msg)
                return True
            except (OSError, EOFError, ValueError):
                return False

    class _Forward(logging.Handler):
        def emit(self, record):
            try:
                send(("log", record.levelno, record.name, record.getMessage()))
            except Exception:
                pass

    root = logging.getLogger()
    root.setLevel(logging.WARNING)
    root.addHandler(_Forward(logging.WARNING))

    def orphaned() -> None:
        # The worker is gone: nothing this unit finds can be handed to it. Stop the decoders
        # now, let the checkpoints drop the unit, and never outlive the worker for long.
        state["why"] = state["why"] or "the worker process ended"
        try:
            import vitals as V
            V.kill_children(os.getpid())
        except Exception:
            pass
        t = threading.Timer(ORPHAN_EXIT_S, lambda: os._exit(3))
        t.daemon = True
        t.start()

    def listen() -> None:
        try:
            while True:
                msg = inbox.recv()
                if isinstance(msg, tuple) and msg and msg[0] == "abort":
                    state["why"] = state["why"] or str(msg[1])     # FIRST: then the kill may come
                    send(("ack",))
        except (EOFError, OSError):
            if not state.get("done"):
                orphaned()

    threading.Thread(target=listen, daemon=True, name="labs-unit-inbox").start()

    def abort_check() -> Optional[str]:
        now = time.monotonic()
        if now - state["ping"] >= PROGRESS_EVERY_S:
            state["ping"] = now
            send(("progress",))
        return state["why"]

    try:
        if spec.get("pin_opencv"):
            import plugins as P
            P.pin_opencv_threads()
        W.STATION_CHECK = _ref(spec["station_check"]) if spec.get("station_check") else None
        client = _ref(spec["client"])(spec)
        plugin = _ref(spec["plugin"])(analyzer)
        decode = _ref(spec["decode"])
        o = W.run_unit(client, plugin, unit, decode=decode, states={}, context=context,
                       tmpdir=tmpdir, abort_check=abort_check)
        state["done"] = True
        send(("done", o))
    except BaseException as e:
        state["done"] = True
        import traceback
        send(("crash", f"{type(e).__name__}: {e}"[:300], traceback.format_exc()[-2000:]))
        raise


# ---------------------------------------------------------------------------------------------
# The worker's side
# ---------------------------------------------------------------------------------------------
_MAIN_LOCK = threading.Lock()


@contextlib.contextmanager
def _no_main():
    """Spawn re-runs the parent's __main__ in the child (multiprocessing.spawn
    get_preparation_data: `init_main_from_path`). Here that would be run_worker.py -- or the
    WHOLE test suite, when the tests start units. The unit needs neither: it imports what it
    uses. So the child is given an empty __main__ for the moment the process starts -- under a
    lock: two lanes starting units at once would each save the other's stand-in as "the real
    one", and the worker would be left without its __main__."""
    with _MAIN_LOCK:
        main = sys.modules.get("__main__")
        sys.modules["__main__"] = types.ModuleType("__main__")
        try:
            yield
        finally:
            if main is not None:
                sys.modules["__main__"] = main


@dataclass
class _Child:
    unit: W.ScanUnit
    proc: object
    recv: object
    send: object
    progress: float
    abort_why: Optional[str] = None
    abort_at: float = 0.0
    stalled: bool = False
    acked: bool = False
    killed: bool = False
    killed_proc: bool = False
    send_lock: threading.Lock = field(default_factory=threading.Lock)


def _key(u: W.ScanUnit):
    h = W._hour(u.hour_start)
    return (u.analyzer, u.camera_id, h if h is not None else u.hour_start)


def _say_killed(unit: W.ScanUnit, why: str, n) -> None:
    log.warning("labs: %s decoder process(es) stopped for %s %s %s (%s)",
                "an unknown number of (this station cannot list them)" if n is None else n,
                unit.analyzer, unit.camera_id, unit.hour_start, why)


class ProcessRunner:
    """Runs each unit in its own process. run() blocks its caller (a lane's thread) until the
    unit is done, dropped or killed, and always returns a UnitOutcome."""

    single_slot = False

    def __init__(self, spec: dict, *, abort_reason: Callable[[W.ScanUnit], Optional[str]] = lambda u: None,
                 kill: Optional[Callable[[int], Optional[int]]] = None,
                 say_killed: Callable[[W.ScanUnit, str, Optional[int]], None] = _say_killed,
                 file_failed: Optional[Callable[[W.ScanUnit, object, str], W.UnitOutcome]] = None,
                 stall_s: float = STALL_S, grace_s: float = GRACE_S, watch_s: float = WATCH_S,
                 clock: Callable[[], float] = time.monotonic):
        self.spec, self.abort_reason, self.file_failed = spec, abort_reason, file_failed
        if kill is None:
            import vitals as V
            kill = V.kill_children
        self.kill, self.say_killed = kill, say_killed
        self.stall_s, self.grace_s, self.watch_s, self.clock = stall_s, grace_s, watch_s, clock
        self.ctx = mp.get_context("spawn")    # the same on every platform; never fork a threaded worker
        self._lock = threading.Lock()
        self._children: dict = {}

    def run(self, unit: W.ScanUnit, plugin, context: Optional[dict] = None) -> W.UnitOutcome:
        name = getattr(plugin, "name", None) or unit.analyzer
        tmp = tempfile.mkdtemp(prefix="wt-labs-unit-")
        up_recv, up_send = self.ctx.Pipe(duplex=False)        # unit -> worker
        down_recv, down_send = self.ctx.Pipe(duplex=False)    # worker -> unit
        proc = self.ctx.Process(target=child_main, name=f"labs-unit-{name}", daemon=True,
                                args=(down_recv, up_send, self.spec, name, unit, context or {}, tmp))
        try:
            with _no_main():
                proc.start()
        except Exception as e:
            for x in (up_recv, up_send, down_recv, down_send):
                x.close()
            shutil.rmtree(tmp, ignore_errors=True)
            o = W.UnitOutcome(unit, note=W.fit(f"its process could not be started: {type(e).__name__}: {e}", 200))
            o.stalled = True
            return self._file(unit, plugin, o, f"station_fault: the unit's process could not be started "
                                               f"({type(e).__name__}: {e}) -- not the footage")
        # Only the child holds these ends now: when it exits, its pipe reads as closed.
        up_send.close()
        down_recv.close()
        c = _Child(unit=unit, proc=proc, recv=up_recv, send=down_send, progress=self.clock())
        k = _key(unit)
        with self._lock:
            self._children[k] = c
        try:
            return self._settle(c, plugin, self._watch(c))
        finally:
            with self._lock:
                if self._children.get(k) is c:
                    del self._children[k]
            if proc.is_alive():
                self._kill(c)
            proc.join(5)
            for x in (up_recv, down_send):
                with contextlib.suppress(Exception):
                    x.close()
            shutil.rmtree(tmp, ignore_errors=True)

    def _watch(self, c: _Child) -> W.UnitOutcome:
        crash = None
        while True:
            ready = mp_wait([c.recv, c.proc.sentinel], timeout=self.watch_s)
            closed = False
            if c.recv in ready:
                try:
                    msg = c.recv.recv()
                except (EOFError, OSError):
                    msg, closed = None, True
                if msg is not None:
                    kind = msg[0] if isinstance(msg, tuple) and msg else None
                    if kind == "progress":
                        c.progress = self.clock()
                    elif kind == "ack":
                        c.acked = True
                        self._kill_decoders(c)
                    elif kind == "done":
                        o = msg[1]
                        c.proc.join(10)
                        return o
                    elif kind == "log" and len(msg) >= 4:
                        logging.getLogger(str(msg[2])).log(int(msg[1]), "[%s %s %s] %s", c.unit.analyzer,
                                                           c.unit.camera_id, c.unit.hour_start, msg[3])
                    elif kind == "crash":
                        crash = msg[1]
                        if len(msg) >= 3:
                            log.warning("labs: %s %s %s crashed in its process:\n%s", c.unit.analyzer,
                                        c.unit.camera_id, c.unit.hour_start, msg[2])
                    continue
            if closed or not c.proc.is_alive():
                c.proc.join(5)
                # It may have sent its result and exited in the same instant: what is still in
                # the pipe is read before it is called gone without one.
                while not closed:
                    try:
                        if not c.recv.poll(0):
                            break
                        msg = c.recv.recv()
                    except (EOFError, OSError):
                        break
                    if isinstance(msg, tuple) and msg and msg[0] == "done":
                        return msg[1]
                    if isinstance(msg, tuple) and msg and msg[0] == "crash":
                        crash = msg[1]
                return self._dropped(c, f"its process ended without a result (exit {c.proc.exitcode})"
                                        + (f": {crash}" if crash else ""))
            now = self.clock()
            if c.abort_why is None:
                why = None
                with contextlib.suppress(Exception):
                    why = self.abort_reason(c.unit)
                if why:
                    self.abort(c.unit, why)
                elif now - c.progress >= self.stall_s:
                    self.abort(c.unit, f"it made no progress for {int(self.stall_s)} s", stalled=True)
            elif not c.killed and now - c.abort_at >= ACK_WAIT_S:
                self._kill_decoders(c)        # it did not answer: stop its decoders anyway
            elif now - c.abort_at >= self.grace_s:
                self._kill(c)
                c.proc.join(5)
                return self._dropped(c, f"{c.abort_why} -- it did not stop within {int(self.grace_s)} s, "
                                        "so its process was killed")

    def _settle(self, c: _Child, plugin, o: W.UnitOutcome) -> W.UnitOutcome:
        """A unit this worker had to drop is FILED as failed, with why (cilex-vision,
        2026-09-29): left to lapse, its lease held the hour for up to 20 min and the ledger
        read "lease expired". A unit the SERVER took back, or a hold, is never filed: that
        stop is not the hour's doing."""
        if o.submitted:
            return o
        if c.stalled:
            # Stopped for making no progress: ours, not the server's -- even when the unit
            # answered the stop itself and came back "revoked".
            o.stalled = True
            if o.action is W.Action.REVOKED:
                o.action = None
            mins = self.stall_s / 60.0
            dur = f"{mins:g} min" if mins >= 1 else f"{self.stall_s:g} s"
            return self._file(c.unit, plugin, o, f"stalled: no checkpoint for {dur}, "
                                                 + ("its process was killed" if c.killed_proc else "stopped"))
        if o.stalled and o.action is None and c.abort_why is None:
            return self._file(c.unit, plugin, o, f"unit_process_died: {o.note}")
        return o

    def _file(self, unit: W.ScanUnit, plugin, o: W.UnitOutcome, reason: str) -> W.UnitOutcome:
        if self.file_failed is None:
            return o
        try:
            f = self.file_failed(unit, plugin, reason)
        except Exception as e:                # filing is best effort; the lease still lapses
            log.warning("labs: could not file %s %s %s as failed: %r", unit.analyzer, unit.camera_id,
                        unit.hour_start, e)
            return o
        f.stalled = True                      # its lane rests either way
        f.timings = o.timings or f.timings
        return f

    def _dropped(self, c: _Child, note: str) -> W.UnitOutcome:
        o = W.UnitOutcome(c.unit, note=W.fit(note, 200))
        if c.stalled:
            o.stalled = True                  # its lane rests; nothing is filed against the footage
        elif c.abort_why is not None:
            o.action = W.Action.REVOKED       # it was taken back; it simply did not stop in time
        else:
            o.stalled = True                  # it died on its own: the lane rests
        return o

    def _kill(self, c: _Child) -> None:
        n = None
        with contextlib.suppress(Exception):
            n = self.kill(c.proc.pid)         # its decoders first: they would outlive it
        with contextlib.suppress(Exception):
            c.proc.kill()
            c.killed_proc = True
        return n

    def abort(self, unit: W.ScanUnit, why: str, stalled: bool = False) -> bool:
        """Drop this unit now: tell it why, then (once it has the reason) kill ITS decoders.
        Other units are untouched. Called from the reporter's thread or the unit's watcher."""
        with self._lock:
            c = self._children.get(_key(unit))
            if c is None or c.abort_why is not None:
                return False
            c.abort_why, c.abort_at, c.stalled = why, self.clock(), stalled
        with c.send_lock:
            with contextlib.suppress(Exception):
                c.send.send(("abort", why))
        return True

    def _kill_decoders(self, c: _Child) -> None:
        with self._lock:
            if c.killed or c.abort_why is None:
                return
            c.killed = True
        n = None
        with contextlib.suppress(Exception):
            n = self.kill(c.proc.pid)
        self.say_killed(c.unit, c.abort_why, n)

    def abort_all(self, why: str) -> None:
        with self._lock:
            units = [c.unit for c in self._children.values()]
        for u in units:
            self.abort(u, why)

    def running(self) -> list:
        with self._lock:
            return [c.unit for c in self._children.values()]

    def unit_pids(self) -> list:
        """(analyser, pid) of every unit process now: what fill measures a unit's memory by."""
        with self._lock:
            return [(c.unit.analyzer, c.proc.pid) for c in self._children.values() if c.proc.pid]
