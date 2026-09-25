"""Labs worker — the half that claims, fetches, drives analysers, and submits.

SEAM (cilex-vision's, and it is the reason this file exists apart from the analysers):

    worker     owns claim, lease, fetch, idle-gating, retry, submit
    analyser   PURE:  (frames, segment metadata) -> observations
               no HTTP, no lease awareness, no knowledge that Labs exists

So everything here is plumbing, and every analyser in tools/labs/ stays testable
without a server. The HTTP layer sits behind `LabsClient` so this module's logic is
tested against a fake (tools/tests/labs-worker.py) without touching the live fleet.

CONTRACT — read from the RUNNING service's OpenAPI (1.0.57), 2026-09-25, not from source:

    POST /labs/scan/claim?analyzer=&limit=4          -> {units:[ScanUnit], queue_remaining}
    GET  /labs/scan/{a}/{cam}/{hour}/segments?stream_type=&limit=200 -> [Segment]
    GET  <Segment.fetch_url>                          -> segment bytes (lease re-checked)
    PUT  /labs/scan/{a}/{cam}/{hour}/results          <- {analyzer_version, segments_scanned,
                                                          observations, failed?, error?}
    auth: header `x-cilex-station-token`

ERROR CONTRACT — `retryable` verified ON THE WIRE on 1.0.57 with a present-but-bogus
token. NOTE the trap that made an earlier check blind: with NO token the auth
dependency raises a plain 401 "station token required" that never carries `code` or
`retryable` in any version; only a PRESENT token reaches the coded refusals. And
`POST /labs/scan/claim` validates its query BEFORE auth, so a 422 there is a bug in
this file, never an auth state.

LEASES ARE 20 MINUTES (labs.py LEASE_MINUTES). A unit not submitted inside that
window is swept back to the queue and another station may take it. Disabling an
analyser blocks NEW claims only -- work already leased keeps running until it
finishes or the lease lapses. That is a gap in the control surface, raised with
cilex-vision; this worker honours `analyzer_disabled` at the next claim.
"""
from __future__ import annotations

import http.client
import json
import os
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Iterable, Optional, Protocol

WORKER_VERSION = "worker-0.1"


# ----------------------------------------------------------------------------------
# Refusals and what to do about each one. Branch on the SLUG, never on the status:
# 409 alone means three different things here (disabled, held elsewhere, not open).
# ----------------------------------------------------------------------------------
class Action(Enum):
    STOP_ANALYSER = "stop_analyser"   # operator turned it off; do not claim again
    RECLAIM = "reclaim"               # lease lost; drop this unit, claim afresh
    RETRY_LATER = "retry_later"       # transient; back off and try the same thing
    SKIP_SEGMENT = "skip_segment"     # one segment is gone; the rest of the unit is fine
    FATAL = "fatal"                   # this station cannot work at all (bad token)
    BUG = "bug"                       # the request was malformed: this file is wrong


# Slug -> action. Anything absent falls through to `retryable`, then to FATAL: an
# UNRECOGNISED refusal must stop the worker rather than be guessed at, because a
# guessed retry on an unknown condition is how a worker hammers a service.
_BY_SLUG = {
    "analyzer_disabled": Action.STOP_ANALYSER,
    "scan_unit_held_by_another_station": Action.RECLAIM,
    "scan_unit_not_open": Action.RECLAIM,
    "scan_unit_not_claimed": Action.RECLAIM,
    "segment_outside_lease": Action.RECLAIM,     # the lease died mid-hour
    "segment_not_found": Action.SKIP_SEGMENT,
    "object_storage_unavailable": Action.RETRY_LATER,
    "station_token_not_recognised": Action.FATAL,
    "transport_error": Action.RETRY_LATER,       # no answer at all: a deploy, a blip
}


@dataclass
class Refusal(Exception):
    status: int
    detail: Optional[str]
    retryable: Optional[bool]
    message: str = ""

    def __str__(self) -> str:
        return f"{self.status} {self.detail or '?'}: {self.message}"


# ----------------------------------------------------------------------------------
# Transport failures: the connection itself, not the server's answer.
#
# FOUND 2026-09-26 by testing the fault the week's measurements predicted rather than
# the faults this file was designed around. Every deploy refuses connections for
# 8.8-17 s (measured by cilex-vision and the macOS agent), and until this change a
# refused or reset connection at ANY of the four calls -- claim, segments, fetch,
# submit -- escaped as a raw URLError / ConnectionResetError and CRASHED THE WORKER.
# 72 assertions had not caught it, because every fault they injected was the server
# answering with a refusal. None was the server not answering at all.
#
# Deliberately narrow. OSError is NOT caught wholesale: a PermissionError or a full
# disk while writing a temp segment is not a network blip, and retrying it would only
# hide it.
# ----------------------------------------------------------------------------------
def _is_transport(e: BaseException) -> bool:
    if isinstance(e, urllib.error.HTTPError):
        return False                      # that is the server ANSWERING; see _refusal_from
    return isinstance(e, (ConnectionError, TimeoutError, http.client.HTTPException,
                          urllib.error.URLError))


def _guard(fn, *a):
    """Call a client method; a transport failure becomes a retryable Refusal."""
    try:
        return fn(*a)
    except Refusal:
        raise
    except Exception as e:
        if _is_transport(e):
            raise Refusal(0, "transport_error", True,
                          f"{type(e).__name__}: {e}"[:200]) from None
        raise


# Backoff covering the longest measured deploy gap (~17 s): 1+2+4+8+16 = 31 s.
BACKOFF_S = (1, 2, 4, 8, 16)


def _retrying(fn, *a, sleep=time.sleep):
    """Retry a RETRY_LATER refusal across a deploy-sized gap; anything else re-raises."""
    for i in range(len(BACKOFF_S) + 1):
        try:
            return _guard(fn, *a)
        except Refusal as r:
            if action_for(r) is not Action.RETRY_LATER or i == len(BACKOFF_S):
                raise
            sleep(BACKOFF_S[i])


def action_for(r: Refusal) -> Action:
    if r.status == 422:
        return Action.BUG
    if r.detail in _BY_SLUG:
        return _BY_SLUG[r.detail]
    if r.retryable is True:
        return Action.RETRY_LATER
    return Action.FATAL


# ----------------------------------------------------------------------------------
# The HTTP surface, behind a protocol so the logic can be tested against a fake.
# ----------------------------------------------------------------------------------
@dataclass(frozen=True)
class ScanUnit:
    camera_id: str
    hour_start: str
    analyzer: str
    lease_expires_at: Optional[str]
    attempts: int


@dataclass(frozen=True)
class Segment:
    segment_id: str
    fetch_url: str
    start_time: Optional[str]
    end_time: Optional[str]
    duration_s: Optional[float]
    bytes: Optional[int]
    stream_type: Optional[str]
    width: Optional[int]
    height: Optional[int]
    codec: Optional[str]
    # Astronomy PER SEGMENT, classified at this segment's start_time (cilex-vision
    # 1.0.58, bf2ad7f). Per-segment rather than per-unit because at 60 N an hour
    # holding a solar event holds more than one answer: hiwatch-083bc1f79619 on
    # 2026-09-24 ran 176 segments `day`, 156 `dusk`, 13 `night` around one sunset.
    scene_light_astronomical: Optional[str] = None
    # THREE STATES, NOT TWO, and conflating them is the bug. The server sending
    # null means "no solar row for this site and date" -- NOT night. The server
    # NOT SENDING THE KEY means it predates 1.0.58 -- NOT null. Both leave the
    # analyser without an answer, but they are different facts about the world and
    # the row records which one it was.
    astro_key_present: bool = False


class LabsClient(Protocol):
    def claim(self, analyzer: str, limit: int) -> tuple[list[ScanUnit], int]: ...
    def segments(self, unit: ScanUnit, limit: int,
                 stream_type: Optional[str]) -> list[Segment]: ...
    def fetch(self, seg: Segment, dest_path: str) -> int: ...
    def submit(self, unit: ScanUnit, body: dict) -> None: ...


class HttpLabsClient:
    """Real client. stdlib only, so nothing new has to be installed on any station."""

    def __init__(self, base_url: str, token: str, timeout_s: float = 60.0):
        if not token:
            raise ValueError("no station token")
        self.base = base_url.rstrip("/")
        self._token = token          # never logged, never put in an exception
        self.timeout = timeout_s

    def _req(self, method: str, path: str, body: Optional[dict] = None,
             raw_to: Optional[str] = None):
        url = path if path.startswith("http") else self.base + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("x-cilex-station-token", self._token)
        if data is not None:
            req.add_header("content-type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                if raw_to is not None:
                    # STREAM to disk in chunks: a raw-bytes signature OOM-killed
                    # cilex-vision's container at ~450 MB/hour doubled by a join.
                    n = 0
                    with open(raw_to, "wb") as f:
                        while True:
                            c = resp.read(1 << 20)
                            if not c:
                                break
                            f.write(c)
                            n += len(c)
                    return n
                txt = resp.read().decode()
                return json.loads(txt) if txt else None
        except urllib.error.HTTPError as e:
            raise _refusal_from(e.code, e.read()) from None

    def claim(self, analyzer, limit):
        q = urllib.parse.urlencode({"analyzer": analyzer, "limit": limit})
        d = self._req("POST", f"/labs/scan/claim?{q}")
        units = [ScanUnit(u["camera_id"], u["hour_start"], u["analyzer"],
                          u.get("lease_expires_at"), int(u.get("attempts", 0)))
                 for u in d.get("units", [])]
        return units, int(d.get("queue_remaining", 0))

    def segments(self, unit, limit, stream_type):
        q = {"limit": limit}
        if stream_type:
            q["stream_type"] = stream_type
        d = self._req("GET", _unit_path(unit, "segments") + "?" + urllib.parse.urlencode(q))
        return [Segment(s["segment_id"], s["fetch_url"], s.get("start_time"),
                        s.get("end_time"), s.get("duration_s"), s.get("bytes"),
                        s.get("stream_type"), s.get("width"), s.get("height"),
                        s.get("codec"),
                        scene_light_astronomical=s.get("scene_light_astronomical"),
                        astro_key_present="scene_light_astronomical" in s)
                for s in (d or [])]

    def fetch(self, seg, dest_path):
        return self._req("GET", seg.fetch_url, raw_to=dest_path)

    def submit(self, unit, body):
        # ANY 2xx is success, and that includes 200 {"status": "already_recorded"}:
        # cilex-vision returns it for a unit already 'done' BEFORE touching anything
        # (routers/labs.py:1435-1439), deliberately "so the station stops retrying
        # rather than escalating". It is how a retry after a cut that DID commit heals.
        # Do not "tighten" this into checking status == "recorded": that would turn
        # the one idempotent path into a failure and restart the retries it exists to end.
        self._req("PUT", _unit_path(unit, "results"), body=body)


def _unit_path(u: ScanUnit, tail: str) -> str:
    q = urllib.parse.quote
    return f"/labs/scan/{q(u.analyzer, safe='')}/{q(u.camera_id, safe='')}/{q(u.hour_start, safe='')}/{tail}"


def _refusal_from(status: int, body: bytes) -> Refusal:
    try:
        d = json.loads(body.decode() or "{}")
    except Exception:
        d = {}
    det = d.get("detail")
    if not isinstance(det, str):     # FastAPI 422 puts a LIST here
        det = None
    return Refusal(status, det, d.get("retryable"), str(d.get("message", ""))[:200])


# ----------------------------------------------------------------------------------
# Analyser plugins: each adapts one pure analyser to the worker.
# ----------------------------------------------------------------------------------
class Plugin(Protocol):
    name: str
    version: str
    segment_limit: int
    keyframes_only: bool
    want_chroma: bool
    stateful: bool

    def new_state(self): ...
    def analyse(self, segs: list[tuple[Segment, list]], state, unit: ScanUnit,
                context: dict) -> list[dict]: ...


def _iso(v) -> Optional[str]:
    return v if isinstance(v, str) else None


# ----------------------------------------------------------------------------------
# The metrics rules the server enforces IN CODE, not in its schema.
#
# FOUND 2026-09-25, and it corrected a claim of mine: the smoke test reported "every
# body valid against the live ObservationIn, 0 violations", which was true against the
# OpenAPI schema and incomplete as a statement about the contract. cilex-vision's
# `_clean_metrics` (routers/labs.py) enforces these caps in Python, where the schema
# cannot show them. B1 truncated its notes at 400 characters; the server allows 120.
# A single zero-chroma frame at astronomical night produced a 141-character note, the
# server would refuse it with 422 metric_value_too_long, this worker (correctly)
# treats 422 as a bug and abandons the unit unfiled -- and the lapsed lease puts the
# same camera-hour back in the queue to fail the same way -- bounded at THREE attempts,
# not "forever" as this comment first said (see _file_failed for the correction), and
# then recorded as 'lease expired', which names the wrong cause.
#
# Mirrored here so a violation is a loud LOCAL error in the tests, never a 422 that
# loops in production. tools/tests/labs-worker.py pins these against cilex-vision's
# source when their checkout exists, so a change on their side breaks our build
# rather than our worker.
# ----------------------------------------------------------------------------------
MAX_METRIC_KEYS = 24
MAX_METRIC_KEY_LEN = 40
MAX_METRIC_STR_LEN = 120
_METRIC_KEY_OK = frozenset("abcdefghijklmnopqrstuvwxyz0123456789_")


class MetricsViolation(ValueError):
    pass


def check_metrics(m: Optional[dict]) -> None:
    """Raise MetricsViolation for anything the server's _clean_metrics would 422."""
    if m is None:
        return
    if not isinstance(m, dict):
        raise MetricsViolation("metrics must be an object")
    if len(m) > MAX_METRIC_KEYS:
        raise MetricsViolation(f"{len(m)} metric keys; the server allows {MAX_METRIC_KEYS}")
    for k, v in m.items():
        if not isinstance(k, str) or not k or len(k) > MAX_METRIC_KEY_LEN:
            raise MetricsViolation(f"metric key {k!r} is not 1-{MAX_METRIC_KEY_LEN} chars")
        if any(ch not in _METRIC_KEY_OK for ch in k):
            raise MetricsViolation(f"metric key {k!r} is not a lowercase slug")
        if isinstance(v, bool) or isinstance(v, (int, float)) or v is None:
            continue
        if isinstance(v, str):
            if len(v) > MAX_METRIC_STR_LEN:
                raise MetricsViolation(
                    f"metric {k!r} is {len(v)} chars; the server allows {MAX_METRIC_STR_LEN}")
            continue
        raise MetricsViolation(f"metric {k!r} is {type(v).__name__}, not a scalar")


def fit(text: str, limit: int = MAX_METRIC_STR_LEN) -> str:
    """Fit prose into a metric string WITHOUT pretending it was not cut."""
    return text if len(text) <= limit else text[: limit - 1] + "\u2026"


# ----------------------------------------------------------------------------------
# One unit, end to end.
# ----------------------------------------------------------------------------------
@dataclass
class UnitOutcome:
    unit: ScanUnit
    submitted: bool = False
    observations: int = 0
    segments_scanned: int = 0
    skipped_segments: int = 0
    action: Optional[Action] = None
    note: str = ""
    decoder_runs: int = 0


def run_unit(client: LabsClient, plugin, unit: ScanUnit, *,
             decode: Callable[[str, bool, bool], list],
             states: dict, context: Optional[dict] = None,
             tmpdir: Optional[str] = None,
             sleep: Callable[[float], None] = time.sleep) -> UnitOutcome:
    """Claimed unit -> list -> fetch -> decode -> analyse -> submit.

    Rules this enforces, each of which has cost somebody a run:
      * EMPTY IS A RESULT. Zero observations is submitted, never skipped: it is what
        lets the server say "checked and found nothing" rather than "nobody looked".
      * A lost lease abandons the unit WITHOUT submitting. Partial results for an
        hour this station no longer holds would be a lie about coverage.
      * Every temp file is removed in a finally, including on exception.
      * Stateful analysers keep ONE state per camera across segments and units;
        they reset only on a real discontinuity, which the analyser itself detects.
    """
    out = UnitOutcome(unit)
    ctx = dict(context or {})
    try:
        # The plugin's stream, not None: an unpinned request returns whatever the
        # server picks, and an analyser calibrated on one stream is not calibrated
        # on the other (B1's IR floor was measured on main; A4-A6's cost on sub).
        segs = _retrying(client.segments, unit, plugin.segment_limit,
                         getattr(plugin, "stream_type", None), sleep=sleep)
    except Refusal as r:
        out.action = action_for(r); out.note = str(r)
        return out

    if plugin.stateful:
        state = states.setdefault(unit.camera_id, plugin.new_state())
    else:
        state = None

    decoded: list[tuple[Segment, list]] = []
    for seg in segs:
        fd, path = tempfile.mkstemp(suffix=".ts", dir=tmpdir)
        os.close(fd)
        try:
            try:
                _retrying(client.fetch, seg, path, sleep=sleep)
            except Refusal as r:
                a = action_for(r)
                if a is Action.SKIP_SEGMENT:
                    out.skipped_segments += 1
                    continue
                out.action = a; out.note = f"fetch {seg.segment_id}: {r}"
                return out
            frames = decode(path, plugin.keyframes_only, plugin.want_chroma)
            out.decoder_runs += 1
            decoded.append((seg, frames))
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass

    out.segments_scanned = len(decoded)
    try:
        obs = plugin.analyse(decoded, state, unit, ctx)
    except Exception as e:                      # analyser crashed: report, do not hide
        # Through _file_failed like every other failure, so there is ONE place that
        # builds a failure body. This used to build its own -- two copies of the rule
        # "a failure report carries no observations", which is how rules drift.
        o = _file_failed(client, plugin, unit, out,
                         f"analyser_raised: {type(e).__name__}: {e}", Action.BUG)
        o.action = None if o.submitted else o.action   # a filed crash is not a stop signal
        return o

    body = {"analyzer_version": f"{plugin.version}+{WORKER_VERSION}",
            "segments_scanned": out.segments_scanned,
            "observations": obs}
    # Checked BEFORE submission. A violation is a bug in a plugin -- and it is FILED
    # as one, with its real reason, rather than raised out of the loop or left to
    # the lease. See _file_failed for why abandoning it would hide the cause.
    for ob in obs:
        try:
            check_metrics(ob.get("metrics"))
        except MetricsViolation as e:
            return _file_failed(client, plugin, unit, out,
                                f"metrics_violation: {e}", Action.BUG)
    try:
        # RETRYING A SUBMISSION IS SAFE ONLY BECAUSE IT IS THE SAME BODY. cilex-vision's
        # submit_results is not one transaction (routers/labs.py): a version-scoped
        # DELETE of the unit's rows (:1536), then per-observation inserts (:1558), then
        # the unit close (:1603). A connection cut between them leaves partial rows with
        # the unit still claimed. A re-submit heals it, because :1536 clears the partial
        # rows first -- but ONLY while analyzer_version is unchanged. So the retry sends
        # this exact `body`, never a rebuilt one, and never across a version change.
        _retrying(client.submit, unit, body, sleep=sleep)
    except Refusal as r:
        a = action_for(r)
        if a is Action.BUG:
            # The server refused the body as malformed. Retrying the same body is
            # pointless; abandoning it erases the reason. File it failed, once.
            return _file_failed(client, plugin, unit, out, f"submit_refused: {r}", a)
        out.action = a; out.note = f"submit: {r}"
        return out
    out.submitted = True
    out.observations = len(obs)
    return out


def _file_failed(client, plugin, unit, out, reason: str, action: "Action"):
    """File a unit as FAILED with its real reason, rather than abandon it.

    WHY, and it corrects a claim of mine. I had written that a unit whose submission
    the server refuses would "come back round the queue to fail identically, every 20
    minutes, forever". cilex-vision corrected it from their source, and I verified
    it (routers/labs.py): an abandoned lease is swept to state='failed' with
    error='lease expired' (:978); a failed unit is re-claimed only while
    attempts < 3 (:1038); and every re-claim sets error=NULL (:1072).

    So the loop is BOUNDED at three attempts -- "forever" was wrong. But the real
    harm is worse in a different way: the actual cause is never recorded anywhere.
    Three failures, then a permanent label naming the wrong one. Whoever later asks
    why that camera-hour was never analysed would be told the lease expired.

    So when this worker KNOWS why it cannot finish, it says so. The body is minimal
    -- no observations -- so it cannot itself trip the rule that stopped the first.
    ONE attempt: if this is refused too, nothing more is tried.

    AND IT MUST CARRY NO OBSERVATIONS -- the one line here that is load-bearing.
    cilex-vision's submit_results validates the observations BEFORE it reads
    `failed`: the count cap at routers/labs.py:1441, the per-observation loop ending
    in _clean_metrics at :1510, and only then `if body.failed:` at :1512. So a
    failure report that still carried the offending observations would be refused
    for the very reason it reports, fall back to the lease sweep, and end up
    labelled 'lease expired' -- the exact mislabel this function exists to prevent.
    They caught it; they will move the branch above those checks with the
    operator's go. Until then this list stays empty, and a test pins it.
    """
    body = {"analyzer_version": f"{plugin.version}+{WORKER_VERSION}",
            "segments_scanned": out.segments_scanned, "observations": [],
            "failed": True, "error": fit(reason, 500)}
    out.action = action
    out.note = reason
    try:
        client.submit(unit, body)
        out.submitted = True
    except Refusal as r:
        out.note = f"{reason}; filing it as failed was refused too: {r}"
    return out


# ----------------------------------------------------------------------------------
# The loop: claim a batch, run it, respect the gate and the refusals.
# ----------------------------------------------------------------------------------
@dataclass
class RunReport:
    claimed: int = 0
    submitted: int = 0
    abandoned: int = 0
    stopped_analysers: list = field(default_factory=list)
    fatal: Optional[str] = None
    # NOT the same as `fatal`, and the difference is what an operator would act on.
    # `fatal` means THIS STATION is broken (a bad token): retrying changes nothing.
    # `unreachable` means the server did not answer for longer than the backoff
    # covers: a deploy that ran long, an outage. The next pass may simply work.
    unreachable: Optional[str] = None
    outcomes: list = field(default_factory=list)


def run_once(client: LabsClient, plugins: Iterable, *, decode, states: dict,
             gate: Callable[[], bool] = lambda: True, claim_limit: int = 4,
             context_for: Callable[[ScanUnit], dict] = lambda u: {},
             sleep: Callable[[float], None] = time.sleep,
             max_retries: int = 5) -> RunReport:
    """One pass over the given analysers. The caller decides how often to call it.

    `gate` is checked before every CLAIM, never mid-unit: abandoning a leased unit
    because the guard came back to the desk wastes the lease and costs nothing
    saved -- the unit is already paid for. Idle gating belongs at the claim.
    """
    rep = RunReport()
    for plugin in plugins:
        if not gate():
            break
        units, tries = None, 0
        while units is None:
            try:
                units, _remaining = _guard(client.claim, plugin.name, claim_limit)
            except Refusal as r:
                a = action_for(r)
                if a is Action.STOP_ANALYSER:
                    rep.stopped_analysers.append(plugin.name); units = []
                elif a is Action.RETRY_LATER and tries < max_retries:
                    tries += 1; sleep(min(60.0, 2.0 ** tries))
                elif a is Action.FATAL:
                    rep.fatal = str(r); return rep
                elif a is Action.RETRY_LATER:
                    rep.unreachable = f"claim {plugin.name}: gave up after {tries} retries: {r}"
                    return rep
                else:
                    rep.fatal = f"claim {plugin.name}: {r} -> {a.value}"; return rep
        rep.claimed += len(units)
        for unit in units:
            o = run_unit(client, plugin, unit, decode=decode, states=states,
                         context=context_for(unit), sleep=sleep)
            rep.outcomes.append(o)
            if o.submitted:
                rep.submitted += 1
            else:
                rep.abandoned += 1
            if o.action is Action.FATAL:
                rep.fatal = o.note; return rep
            if o.action is Action.STOP_ANALYSER:
                rep.stopped_analysers.append(plugin.name); break
    return rep
