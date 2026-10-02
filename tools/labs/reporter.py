"""This station's side of cilex-vision's Labs control plane (deployed 2026-09-28).

Every ~2 s the worker reports itself -- its state, the units it holds (one per lane at
first, more with fill), the machine's and its own CPU and memory -- and the reply is the
server's orders: the station's mode, each analyser lane's mode, and the units it has taken
back (CONTRACT.md, "Station side"), plus any renewed lease deadlines.

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
from datetime import datetime
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


def _aware_stamp(value) -> Optional[datetime]:
    """A server timestamp must name its offset; never guess this machine's timezone."""
    if not isinstance(value, str):
        return None
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return stamp if stamp.tzinfo is not None else None


class Reporter:
    def __init__(self, client, *, vitals=None, worker_version: str = W.WORKER_VERSION,
                 control: Callable[[], dict] = S.read_control,
                 on_abort: Optional[Callable[[W.ScanUnit, str], None]] = None,
                 on_change: Optional[Callable[[dict], None]] = None,
                 clock: Callable[[], float] = time.monotonic,
                 log: Optional[logging.Logger] = None):
        self.client, self.vitals = client, vitals
        self.worker_version = worker_version
        self.control, self.on_abort, self.on_change = control, on_abort, on_change
        self.clock = clock
        self.log = log or logging.getLogger("labs.report")
        self._lock = threading.Lock()
        self._state = "idle"                  # the loop's own word when holding nothing
        self._holding: dict = {}              # key -> ScanUnit: every lane's units in hand
        self._renewals: dict = {}             # key -> (server expiry, request monotonic time, lease seconds)
        self._hold: Optional[dict] = None
        self._orders: Optional[dict] = None
        self._orders_at: Optional[float] = None
        self._legacy: Optional[bool] = None   # None: not asked yet; True: no endpoint (404)
        self._every = 2.0
        self._revoked: set = set()
        self._aborted: set = set()            # the units in hand this has already acted on
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
        """ONE unit in hand, or none (worker.run_once: the one-off --live run)."""
        with self._lock:
            holding = {} if unit is None else {_key(unit.analyzer, unit.camera_id, unit.hour_start): unit}
            self._renewals = {k: v for k, v in self._renewals.items()
                              if k in holding and self._holding.get(k) is holding[k]}
            self._holding = holding
            self._aborted &= set(self._holding)

    def add_holding(self, unit: W.ScanUnit) -> None:
        """A lane has a unit in hand (lanes.Scheduler): it joins the report's `holding` list."""
        with self._lock:
            k = _key(unit.analyzer, unit.camera_id, unit.hour_start)
            if self._holding.get(k) is not unit:
                self._renewals.pop(k, None)
            self._holding[k] = unit

    def remove_holding(self, unit: W.ScanUnit) -> None:
        with self._lock:
            k = _key(unit.analyzer, unit.camera_id, unit.hour_start)
            if self._holding.get(k) is not unit:
                return
            self._holding.pop(k, None)
            self._renewals.pop(k, None)
            self._aborted.discard(k)

    def holding(self) -> list:
        with self._lock:
            return list(self._holding.values())

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

    def lease(self, unit: W.ScanUnit) -> Optional[tuple[float, float]]:
        """Latest renewal as (monotonic start, lease seconds), for this claim only.

        An empty later report does not withdraw a renewal: the server lists only leases
        extended by THAT report (CV's 2026-09-30 contract). The deadline keeps ageing
        even when reports fail or orders go stale. Revocation and a local hold still win.
        """
        with self._lock:
            k = _key(unit.analyzer, unit.camera_id, unit.hour_start)
            if self._holding.get(k) is not unit or self._hold or k in self._revoked or k in self._aborted:
                return None
            rec = self._renewals.get(k)
            return (rec[1], rec[2]) if rec else None

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
            sent = dict(self._holding)
            units, hold = list(sent.values()), (dict(self._hold) if self._hold else None)
            state = "paused" if hold else ("running" if units else self._state)
        # `slots` is null: since worker-0.3.8 there is no station-wide cap -- every connected
        # lane runs its unit at once (the operator's rule). The server takes null (0..64 or null).
        body = {"worker_version": self.worker_version, "state": state, "slots": None,
                "holding": [{"analyzer": u.analyzer, "camera_id": u.camera_id, "hour_start": u.hour_start}
                            for u in units]}
        if self.vitals is not None:
            try:
                body.update(self.vitals.sample())
            except Exception as e:
                self.log.warning("labs vitals: %s: %s", type(e).__name__, e)
        if hold:
            body["hold"] = hold
        started = self.clock()
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
            self._read_leases(reply, sent, started)
        self._last_error = ""
        self._last_ok_iso = S.now_iso()
        self._next = now + self._every
        self._act_on_hand()
        self._publish()
        return True

    def _read_leases(self, reply: dict, sent: dict, started: float) -> None:
        """Called under _lock. Publish immutable samples; only the scheduler changes its
        own lease state. A response in flight cannot renew a replacement claim for the
        same camera-hour: it must still be the exact ScanUnit that this request reported.
        """
        generated = _aware_stamp(reply.get("generated_at"))
        leases = reply.get("leases")
        if generated is None or not isinstance(leases, list) or self._hold:
            return
        for row in leases:
            if not isinstance(row, dict):
                continue
            ids = [row.get(n) for n in ("analyzer", "camera_id", "hour_start")]
            if not all(isinstance(v, str) and v for v in ids) or _aware_stamp(ids[2]) is None:
                continue
            k = _key(*ids)
            unit = sent.get(k)
            if unit is None or self._holding.get(k) is not unit or k in self._revoked or k in self._aborted:
                continue
            expires = _aware_stamp(row.get("lease_expires_at"))
            old = self._renewals.get(k)
            previous = old[0] if old else _aware_stamp(unit.lease_expires_at)
            if expires is None or expires <= generated or (previous is not None and expires <= previous):
                continue
            # Compare SERVER timestamps, then use only the monotonic clock. CV's
            # generated_at precedes the renewal query (labs.py, read 2026-10-02).
            # Anchor at REQUEST start so time spent waiting for the reply is consumed,
            # not added to the lease. Repeated deadlines never reset its age, including
            # the server's two-hour ceiling. No extension is invented on an old server.
            self._renewals[k] = (expires, started, (expires - generated).total_seconds())

    def _act_on_hand(self) -> None:
        """Each unit in hand that the server took back -- or every one, under a hold -- is
        dropped ONCE. Each on its own: a Stop on one lane's unit leaves the others running."""
        todo = []
        with self._lock:
            for k, unit in self._holding.items():
                why = ("taken back by the server" if k in self._revoked
                       else f"held on this station: {self._hold.get('why')}" if self._hold else None)
                if why is None or k in self._aborted:
                    continue
                self._aborted.add(k)
                todo.append((unit, why))
        for unit, why in todo:
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
