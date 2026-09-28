"""This station's side of cilex-vision's Labs control plane (deployed 2026-09-28).

Every ~2 s the worker reports itself -- its state, the unit it holds, the machine's and
its own CPU and memory -- and the reply is the server's orders: the station's mode, each
analyser lane's mode, and the units it has taken back (CONTRACT.md, "Station side").

  * The SERVER is the switch (operator decision 2026-09-28): Start / Pause / Stop at four
    levels. The local control file's `paused` flag no longer governs once the server
    answers these reports; before that (a server without the endpoint: 404) it still does.
  * One local exception, also the operator's: the wall's safety check can HOLD Labs off on
    this computer (station.write_hold). The hold survives restarts, beats a server Start,
    and is sent in every report with its reason, so it is never a hidden switch. Guards
    never see it: Labs is a background, admins-only programme.
  * A unit the server takes back (a Stop, or its lease went elsewhere) -- or any unit in
    hand when a hold appears -- is dropped AT ONCE: this kills its decoders (on_abort) and
    the worker's checkpoints stop it within a segment, submitting nothing.
  * Orders older than 30 s are unknown, and unknown means claim nothing new: the server
    refuses claims from a station it has not heard from in 30 s anyway.
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Callable, Optional

import station as S
import worker as W

STALE_S = 30.0          # CV: 409 labs_worker_not_reporting after 30 s without a report
LEGACY_PROBE_S = 60.0   # a server without the endpoint is asked again this often
TICK_S = 1.0            # the local hold is looked at this often (the wall's guard writes it)
MIN_EVERY_S, MAX_EVERY_S = 1.0, 30.0


def _key(analyzer, camera_id, hour_start):
    h = W._hour(hour_start)
    return (analyzer, camera_id, h if h is not None else hour_start)


class Reporter:
    def __init__(self, client, *, vitals=None, worker_version: str = W.WORKER_VERSION,
                 slots: int = 1, control: Callable[[], dict] = S.read_control,
                 on_abort: Optional[Callable[[W.ScanUnit, str], None]] = None,
                 on_change: Optional[Callable[[dict], None]] = None,
                 clock: Callable[[], float] = time.monotonic,
                 log: Optional[logging.Logger] = None):
        self.client, self.vitals = client, vitals
        self.worker_version, self.slots = worker_version, slots
        self.control, self.on_abort, self.on_change = control, on_abort, on_change
        self.clock = clock
        self.log = log or logging.getLogger("labs.report")
        self._lock = threading.Lock()
        self._state = "idle"                  # the loop's own word when holding nothing
        self._holding: Optional[W.ScanUnit] = None
        self._hold: Optional[dict] = None
        self._orders: Optional[dict] = None
        self._orders_at: Optional[float] = None
        self._legacy: Optional[bool] = None   # None: not asked yet; True: no endpoint (404)
        self._every = 2.0
        self._revoked: set = set()
        self._aborted: Optional[tuple] = None # the unit in hand this has already acted on
        self._last_error = ""
        self._last_ok_iso: Optional[str] = None
        self._next = 0.0
        self._last_snapshot: Optional[dict] = None
        self._kick = threading.Event()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True, name="labs-reporter")

    # ---- the loop tells it ------------------------------------------------------------
    def set_state(self, state: str) -> None:
        with self._lock:
            self._state = state

    def set_holding(self, unit: Optional[W.ScanUnit]) -> None:
        with self._lock:
            self._holding = unit
            if unit is None:
                self._aborted = None

    def kick(self) -> None:
        """Report now: a unit just ended, or the server said it has not heard from us."""
        self._next = 0.0
        self._kick.set()

    # ---- the loop asks it -------------------------------------------------------------
    def governed(self) -> bool:
        """The server has the control plane: its orders, not the local flag, govern."""
        return self._legacy is False

    def fresh(self) -> bool:
        return self._orders_at is not None and (self.clock() - self._orders_at) <= STALE_S

    def station(self) -> Optional[dict]:
        with self._lock:
            return dict((self._orders or {}).get("station") or {}) if self.fresh() else None

    def station_mode(self) -> Optional[str]:
        st = self.station()
        return st.get("mode") if st else None

    def lane_mode(self, analyzer: str) -> Optional[str]:
        with self._lock:
            if not self.fresh():
                return None
            return ((self._orders or {}).get("lanes") or {}).get(analyzer)

    def hold(self) -> Optional[dict]:
        with self._lock:
            return dict(self._hold) if self._hold else None

    def abort_reason(self, unit: W.ScanUnit) -> Optional[str]:
        """Why the unit in hand must be dropped now, or None. The worker's checkpoints ask."""
        with self._lock:
            if _key(unit.analyzer, unit.camera_id, unit.hour_start) in self._revoked:
                return "taken back by the server (a Stop, or its lease went to another station)"
            if self._hold:
                return f"held on this station: {self._hold.get('why')}"
        return None

    def snapshot(self) -> dict:
        """What the local status file (and the Labs screen) should say about the server."""
        st = self.station() or {}
        with self._lock:
            lanes = dict(((self._orders or {}).get("lanes") or {})) if self.fresh() else {}
            return {"governed": self._legacy is False,
                    "server_mode": st.get("mode"), "server_level": st.get("level"), "server_at": st.get("at"),
                    "lanes": lanes, "report_ok_at": self._last_ok_iso,
                    "report_error": self._last_error or None, "hold": dict(self._hold) if self._hold else None}

    # ---- the thread ---------------------------------------------------------------------
    def start(self) -> "Reporter":
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()
        self._kick.set()
        if self._thread.is_alive():
            self._thread.join(timeout=10)

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.tick()
                if self.clock() >= self._next:
                    self.report_once()
            except Exception as e:            # a reporter that dies silently is the worst case
                self._last_error = f"reporter: {type(e).__name__}: {e}"[:200]
                self.log.warning("labs reporter: %s", self._last_error)
            wait = max(0.05, min(TICK_S, self._next - self.clock()))
            self._kick.wait(wait)
            self._kick.clear()

    def tick(self) -> None:
        """Look at the local hold; drop the unit in hand the moment one appears."""
        try:
            hold = (self.control() or {}).get("hold")
        except Exception:
            hold = None
        with self._lock:
            self._hold = hold if hold else None
        self._act_on_hand()
        self._publish()

    def report_once(self) -> bool:
        with self._lock:
            unit, hold = self._holding, (dict(self._hold) if self._hold else None)
            state = "paused" if hold else ("running" if unit is not None else self._state)
        body = {"worker_version": self.worker_version, "state": state, "slots": self.slots,
                "holding": ([{"analyzer": unit.analyzer, "camera_id": unit.camera_id,
                              "hour_start": unit.hour_start}] if unit is not None else [])}
        if self.vitals is not None:
            try:
                body.update(self.vitals.sample())
            except Exception as e:
                self.log.warning("labs vitals: %s: %s", type(e).__name__, e)
        if hold:
            body["hold"] = hold
        try:
            reply = W._guard(self.client.report, body)
        except W.Refusal as r:
            if r.status == 404:
                if self._legacy is not True:
                    self.log.info("labs: the server has no report endpoint yet; the local control file governs")
                self._legacy = True
                with self._lock:
                    self._orders, self._orders_at = None, None
            self._last_error = str(r)[:200]
            self._next = self.clock() + (LEGACY_PROBE_S if self._legacy else self._every)
            self._publish()
            return False
        now = self.clock()
        reply = reply if isinstance(reply, dict) else {}
        every = reply.get("report_every_s")
        if isinstance(every, (int, float)) and not isinstance(every, bool):
            self._every = min(MAX_EVERY_S, max(MIN_EVERY_S, float(every)))
        revoked = set()
        for r in reply.get("revoked") or []:
            if isinstance(r, dict):
                revoked.add(_key(r.get("analyzer"), r.get("camera_id"), r.get("hour_start")))
        with self._lock:
            if self._legacy is not False:
                self.log.info("labs: the server governs this station now (control plane answered)")
            self._legacy = False
            self._orders, self._orders_at = reply, now
            # The server lists only units in our holding, so older keys can go.
            self._revoked = revoked
        self._last_error = ""
        self._last_ok_iso = S.now_iso()
        self._next = now + self._every
        self._act_on_hand()
        self._publish()
        return True

    def _act_on_hand(self) -> None:
        with self._lock:
            unit = self._holding
            if unit is None:
                return
            k = _key(unit.analyzer, unit.camera_id, unit.hour_start)
            why = ("taken back by the server" if k in self._revoked
                   else f"held on this station: {self._hold.get('why')}" if self._hold else None)
            if why is None or self._aborted == k:
                return
            self._aborted = k
        self.log.warning("labs: dropping %s %s %s -- %s", unit.analyzer, unit.camera_id, unit.hour_start, why)
        if self.on_abort is not None:
            try:
                self.on_abort(unit, why)
            except Exception as e:
                self.log.warning("labs: could not stop the unit's decoders: %s", e)

    def _publish(self) -> None:
        if self.on_change is None:
            return
        snap = self.snapshot()
        # Compared WITHOUT the report time, which moves every 2 s: the status file is
        # rewritten when what it says changes, not on every heartbeat of the reports.
        key = {k: v for k, v in snap.items() if k != "report_ok_at"}
        if key != self._last_snapshot:
            self._last_snapshot = key
            try:
                self.on_change(snap)
            except Exception:
                pass
