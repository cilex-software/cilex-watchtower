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
import logging
import os
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Callable, Iterable, Optional, Protocol

# 0.2 (2026-09-26): keyframe times are each key packet's own PTS (frame_source 4f94847),
# no longer a per-segment constant step that was up to 2.5 s off. Every row says which.
# 0.3 (2026-09-28): the station side of cilex-vision's Labs control plane.
# 0.3.1 (2026-09-28): foreground_mask and colour_histogram no longer fail an hour whose
# segment joins run back by the catalogue's whole-second rounding (plugins.JOIN_SLACK_S).
# 0.3.2 (2026-09-28): a lease-lost refusal of a unit the server has already named revoked is
# recorded "revoked", not "abandoned" (_taken_back); a Stop's kill logs how many decoders.
# 0.3.3 (2026-09-29): a Stop kills DECODERS only -- never the console host (vitals.is_decoder);
# a station that cannot start its decoder files the unit under that cause and stops claiming.
# 0.3.4 (2026-09-29): rows starting outside the claimed hour are dropped before submitting,
# every analyser (_within_hour) -- one used to sink a whole blob_geometry unit with a 422.
# 0.3.5 (2026-09-29): each analyser is a LANE of its own (lanes.py), and each unit runs in a
# process of its own (unit_proc.py): a busy, refused or stuck analyser no longer holds up the
# others (the operator's requirement, via cilex-vision's letter of the same day).
# 0.3.6 (2026-09-29): a unit dropped for making no progress, or whose process died, is FILED
# failed with why (cilex-vision); blob_geometry files one row per passage, within a row budget.
WORKER_VERSION = "worker-0.3.7"


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
    # cilex-vision's Labs control plane (2026-09-28 deploy; CONTRACT.md "Changed responses"):
    REVOKED = "revoked"               # the server took the unit back (Stop, or its lease went
                                      # elsewhere) -- or this station holds Labs off: drop it,
                                      # submit NOTHING, not a failure
    NOT_RUNNING = "not_running"       # this analyser's lane is paused/stopped: skip it this pass
    SERVER_BUSY = "server_busy"       # the claim's scan timed out server-side: end the pass
    NOT_REPORTING = "not_reporting"   # the server has no report from us in 30 s: report, retry


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
    "labs_lane_not_running": Action.NOT_RUNNING,
    "labs_worker_not_reporting": Action.NOT_REPORTING,
    # Retryable, but NOT retried in place: the claim that timed out at 30 s would time out
    # again, and a server at its limit should get at most one claim a minute per station.
    "labs_busy": Action.SERVER_BUSY,
    "scan_unit_revoked": Action.REVOKED,
    # The thumbnail PUT (object_profile, cilex-vision reply4): each is a malformed request
    # from THIS worker, not a transient -- filed failed with its cause, never retried.
    "bad_thumb_key": Action.BUG,
    "thumb_too_large": Action.BUG,
    "thumb_not_jpeg": Action.BUG,
    "thumbs_not_accepted": Action.BUG,
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


def _uncoded_server_error(r: Refusal) -> bool:
    """A 5xx that carries no code at all, e.g. Starlette's plain "Internal Server Error".

    Not an unknown REFUSAL (a coded slug this file has not met is still FATAL, never
    guessed at): the server did not get as far as refusing anything."""
    return r.status >= 500 and r.detail is None and r.retryable is None


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
    def segments(self, unit: ScanUnit, limit: int, stream_type: Optional[str],
                 window: Optional[int] = None,
                 window_at: Optional[float] = None) -> list[Segment]: ...
    def fetch(self, seg: Segment, dest_path: str) -> int: ...
    def submit(self, unit: ScanUnit, body: dict) -> None: ...
    # Only for a plugin that files thumbnails (object_profile): PUT one JPEG under the lease.
    def put_thumb(self, unit: ScanUnit, key: str, jpeg: bytes) -> Optional[dict]: ...


class HttpLabsClient:
    """Real client. stdlib only, so nothing new has to be installed on any station."""

    def __init__(self, base_url: str, token: str, timeout_s: float = 60.0):
        if not token:
            raise ValueError("no station token")
        self.base = base_url.rstrip("/")
        self._token = token          # never logged, never put in an exception
        self.timeout = timeout_s

    def _req(self, method: str, path: str, body: Optional[dict] = None,
             raw_to: Optional[str] = None, raw_body: Optional[bytes] = None,
             content_type: Optional[str] = None):
        url = path if path.startswith("http") else self.base + path
        data = raw_body if raw_body is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("x-cilex-station-token", self._token)
        if data is not None:
            req.add_header("content-type", content_type or "application/json")
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
        # null since the 2026-09-28 deploy: the count is best-effort and can no longer fail a
        # claim after its lease was written. int(None) used to crash every claim here.
        q = d.get("queue_remaining")
        return units, (int(q) if isinstance(q, (int, float)) and not isinstance(q, bool) else None)

    def report(self, body):
        """POST /labs/station/report: this station's state and vitals; the reply is the
        server's orders (station mode, lane modes, units taken back). 404 = a server
        from before the control plane."""
        return self._req("POST", "/labs/station/report", body=body)

    def segments(self, unit, limit, stream_type, window=None, window_at=None):
        # `window` asks for CONSECUTIVE segments around `window_at` (0..1 of the hour)
        # instead of the first `limit`. cilex-vision refuses window with limit, and
        # window without stream_type (a6671c5), so the two shapes never mix here.
        if window is not None:
            if not stream_type:
                raise ValueError("window requires stream_type (server: window_without_stream_type)")
            q = {"window": window, "stream_type": stream_type}
            if window_at is not None:
                q["window_at"] = f"{window_at:.6f}"
        else:
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

    def put_thumb(self, unit, key, jpeg):
        # cilex-vision reply4: image/jpeg, at most 32,768 bytes, key [a-z0-9-]{1,40}, only
        # while this station holds the unit; idempotent ("stored" / "unchanged").
        return self._req("PUT", _unit_path(unit, "thumbs/" + urllib.parse.quote(key, safe="")),
                         raw_body=jpeg, content_type="image/jpeg")

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
    # cilex-vision's CodedError carries `code` too; a site whose legacy `detail` was a
    # sentence gains `code` beside it, so the slug is `code` when `detail` is not one.
    code = d.get("code")
    if isinstance(code, str) and code and (det is None or " " in det):
        det = code
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

    # OPTIONAL. A stateful plugin whose state is a picture of the recent past (a
    # background model) sets `state_is_recent_past = True`: the worker then carries it
    # only into the camera's NEXT hour and starts fresh otherwise (see _run_unit).
    # camera_health does not: its Baseline is taught forward-only by the plugin itself.


# Where _run_unit notes, per (analyser, camera), the one hour a carried state is for.
# Kept in the caller's `states` under a key no (analyser, camera) pair can take.
_NEXT_HOUR = ("next_hour",)
_ONE_HOUR = timedelta(hours=1)


def _hour(s) -> Optional[datetime]:
    """A unit's hour_start as an aware datetime; None if it does not parse, and then
    nothing is carried -- fresh is the safe side."""
    if not isinstance(s, str):
        return None
    try:
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


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
# Rows per unit. cilex-vision submit_results refuses more at routers/labs.py:1441
# (MAX_OBSERVATIONS_PER_UNIT, :130) -- and it checks this BEFORE it reads `failed`,
# so over-cap rows would sink even a failure report. perceptual_hash and
# audio_energy both approach it by design.
MAX_OBSERVATIONS_PER_UNIT = 500
# The longest span one event group may have (cilex-vision routers/labs.py:194, default
# 300, env-overridable there; CHECK ck_labs_observation_groups_max_span in migration
# 0089). A ROW longer than this can never join a group, and per cilex-vision /labs/regroup
# then retries it forever. Not enforced here for every analyser -- camera_health's rows
# span their sampled hour by design of that module (cilex-vision's open item) -- but
# blob_geometry's adapter keeps its rows to points in time (plugins.ShapePlugin).
GROUP_MAX_SPAN_S = 300.0
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
    undecodable_segments: int = 0
    # True when what reached the server was a FAILURE report (_file_failed), so a
    # count of "submitted" cannot pass a failed unit off as a finished one.
    filed_failed: bool = False
    # Set when the unit failed because THIS STATION cannot start its decoder (STATION_CHECK):
    # the failure is filed under that cause, and the pass ends as fatal -- no more claims.
    station_fault: Optional[str] = None
    # Rows dropped before submitting because they start outside the claimed hour (_within_hour).
    rows_outside_hour: int = 0
    # Thumbnails PUT before the results that name them (object_profile).
    thumbs_uploaded: int = 0
    # True when the unit was DROPPED because it stopped making progress, or because the
    # worker could not run it at all (worker-0.3.5, lanes.py): its lane rests, the others go on.
    stalled: bool = False
    # Where a unit's wall time went, by phase (list, fetch, decode, analyse, submit,
    # total). The first live unit took 45.6 s wall for ~15 CPU-s, and nothing said why.
    timings: dict = field(default_factory=dict)


# Phase clock: perf_counter, not monotonic. On Windows _now() is GetTickCount64
# at 15.6 ms resolution (time.get_clock_info, measured on the booth 2026-09-27), so every
# phase time on a Windows station came out in 15.6 ms steps -- two 30 ms sleeps measured
# 31-62 ms, which failed a test there. perf_counter is QueryPerformanceCounter (1e-7 s) on
# Windows and the same CLOCK_MONOTONIC as before on Linux.
_now = time.perf_counter


def _add(out: "UnitOutcome", phase: str, since: float) -> None:
    out.timings[phase] = round(out.timings.get(phase, 0.0) + _now() - since, 3)


class _LastWarning(logging.Handler):
    """Keeps the last WARNING-or-worse line logged while a unit runs, so a unit filed
    as failed names its cause. Without it, `no_keyframes_decoded` read the same for a
    decoder that rejected its own command line and for a stream of junk bytes (the
    Windows agent measured both, 2026-09-26); the difference was only in a log line
    nobody reads. The analysers now log that line at WARNING (cilex-vision 3505b6b)."""

    def __init__(self):
        super().__init__(logging.WARNING)
        self.last: Optional[str] = None

    def emit(self, record):
        try:
            self.last = record.getMessage()
        except Exception:
            pass


_heard: Optional[_LastWarning] = None

# The unit in hand can be TAKEN BACK while it runs: the server revoked it (a Stop, or its
# lease went to another station -- cilex-vision lists both in the report's `revoked`), or
# this computer holds Labs off (the wall's safety check). Set by run_unit for the unit's
# duration; asked at every checkpoint -- each segment, and before anything is submitted.
# The reporter also kills the unit's decoders, so a checkpoint comes within a segment.
_abort_check: Optional[Callable[[], Optional[str]]] = None

# Can THIS STATION start its decoder at all? None when it can, else why not. Set by the loop
# (run_worker.decoder_start_fault); asked before any unit is filed as failed. WHY: on the
# office (2026-09-29 02:14-02:25 MSK) every ffmpeg died at DLL init after the worker's own
# console host was killed, and about 25 units were filed failed as if their footage were bad
# (Windows agent). A station that cannot start ffmpeg must say so, and stop claiming.
STATION_CHECK: Optional[Callable[[], Optional[str]]] = None


def _abort_reason() -> Optional[str]:
    try:
        return _abort_check() if _abort_check is not None else None
    except Exception:
        return None


def _checkpoint() -> None:
    why = _abort_reason()
    if why:
        raise _Abandon(Action.REVOKED, why)


def _taken_back(a: "Action", note: str) -> "tuple[Action, str]":
    """A refusal that ends the unit, read against what this station ALREADY knows.

    If a report reply has already named this unit revoked (or a hold is on), that is what
    happened; the refusal is the server saying it again to a request that was in flight
    when we heard. Measured on the pilot, 2026-09-28 (cilex-vision's second live test): the
    report named the unit at 22:52:39.014 MSK, the segment fetch already in flight came
    back 403 segment_outside_lease at 22:52:40.127, and the unit was recorded "abandoned"
    -- true to that refusal, false to what had happened. Only a lease-lost refusal
    (RECLAIM) is re-read: a station fault, a transient or a malformed request stays exactly
    what it is."""
    why = _abort_reason()
    if why and a is Action.RECLAIM:
        return Action.REVOKED, f"{why} -- {note}"
    return a, note


class _Abandon(BaseException):
    """The unit must be dropped WITHOUT submitting (lease lost, station refused) --
    raised out of the streaming decoder, through the analyser, to _run_unit.
    BaseException, not Exception, so no analyser's `except Exception` can swallow it
    and go on to report an hour this station no longer holds."""

    def __init__(self, action: "Action", note: str):
        super().__init__(note)
        self.action, self.note = action, note


class _StationFault(BaseException):
    """A fault of THIS STATION met while fetching (a local disk error, say), carried
    out of the streaming decoder past the analyser and re-raised as itself. Caught
    as an analyser crash it would be filed against the unit -- one of its three
    attempts spent on a problem that is not the footage's."""

    def __init__(self, exc: BaseException):
        super().__init__(repr(exc))
        self.exc = exc


def run_unit(client: LabsClient, plugin, unit: ScanUnit, *,
             decode: Callable[[str, bool, bool], list],
             states: dict, context: Optional[dict] = None,
             tmpdir: Optional[str] = None,
             sleep: Callable[[float], None] = time.sleep,
             abort_check: Optional[Callable[[], Optional[str]]] = None) -> UnitOutcome:
    """Claimed unit -> list -> fetch -> decode -> analyse -> submit.

    Rules this enforces, each of which has cost somebody a run:
      * EMPTY IS A RESULT. Zero observations is submitted, never skipped: it is what
        lets the server say "checked and found nothing" rather than "nobody looked".
      * ...AND ONLY WHEN SOMETHING WAS LOOKED AT. If segments were listed and not one
        could be fetched and decoded, [] would claim "looked, found nothing" with no
        grounds. That is filed as a failure, with its cause.
      * A segment that cannot be decoded is skipped, like a missing one, never raised
        out of the loop: one corrupt segment used to crash the whole worker, leaving
        every claimed unit to expire as 'lease expired'.
      * A lost lease abandons the unit WITHOUT submitting. Partial results for an
        hour this station no longer holds would be a lie about coverage.
      * Every temp file is removed in a finally, including on exception.
      * Stateful analysers keep ONE state per camera across segments and units;
        they reset only on a real discontinuity, which the analyser itself detects.
    """
    global _heard, _abort_check
    heard, prev = _LastWarning(), _heard
    prev_abort = _abort_check
    root = logging.getLogger()
    root.addHandler(heard)
    _heard = heard
    _abort_check = abort_check
    t0 = _now()
    try:
        o = _run_unit(client, plugin, unit, decode, states, context, tmpdir, sleep)
        _add(o, "total_s", t0)
        return o
    finally:
        _heard = prev
        _abort_check = prev_abort
        root.removeHandler(heard)


def _run_unit(client, plugin, unit, decode, states, context, tmpdir, sleep):
    out = UnitOutcome(unit)
    ctx = dict(context or {})
    t = _now()
    try:
        # The plugin's stream, not None: an unpinned request returns whatever the
        # server picks, and an analyser calibrated on one stream is not calibrated
        # on the other (B1's IR floor was measured on main; A4-A6's cost on sub).
        win = getattr(plugin, "window", None)
        segs = _retrying(client.segments, unit, plugin.segment_limit,
                         getattr(plugin, "stream_type", None), win,
                         plugin.window_at(unit) if win else None, sleep=sleep)
    except Refusal as r:
        out.action, out.note = _taken_back(action_for(r), str(r))
        return out
    finally:
        _add(out, "list_s", t)

    if plugin.stateful:
        # Keyed by ANALYSER and camera. It used to be the camera alone, so with two
        # stateful analysers in one run (blob_geometry and camera_health) the second
        # would have been handed the first one's state object.
        key = (plugin.name, unit.camera_id)
        state = states.get(key)
        recent_past = getattr(plugin, "state_is_recent_past", False)
        h = _hour(unit.hour_start)
        if state is not None and recent_past and (h is None or states.get(_NEXT_HOUR + key) != h):
            # A picture of the RECENT PAST (blob_geometry's background model) is true
            # only for the hour that follows it. Claims go newest-first, so a camera's
            # next unit is usually the hour BEFORE: carried, a model that learned the
            # end of 04:00Z met the start of 03:00Z. Measured 2026-09-27 on
            # hiwatch-083bc1df39d1, first 10 min of 03:00Z (dawn): the carried model
            # filed 10 rows in minute 0, where a fresh model files 0 and the contiguous
            # one (learned at the end of 02:00Z) 1, and 0 rows in minutes 3-6, where
            # both file 12. At night (22:00Z): 52 rows carried, 53 fresh, 54 contiguous.
            # Starting fresh costs the warm-up: 1 row in minute 0 on both hours.
            state = None
        if state is None:
            # A plugin that PERSISTS its state (camera_health's per-camera Baseline)
            # picks up where the last run left off, instead of relearning every camera
            # after each restart.
            load = getattr(plugin, "load_state", None)
            state = load(unit.camera_id) if load is not None else None
            if state is None:
                state = plugin.new_state()
            states[key] = state
        if recent_past:
            # Set before the run, so a unit that dies half-way still counts as seen:
            # its model then holds part of this hour, which only the next hour may use.
            # A retry of THIS hour is not that hour, so it starts fresh.
            states[_NEXT_HOUR + key] = h + _ONE_HOUR if h is not None else None
    else:
        state = None

    win = getattr(plugin, "window", None)
    if win is not None and len(segs) > win:
        # The server returned more than the window asked for, so it IGNORED the
        # parameter -- a server that predates a6671c5. FastAPI drops an unknown
        # query param without error, so this is the only place it shows. Scoring
        # 200 segments as though they were a 4-segment window would be a wrong
        # answer that looked right. The runner checks for window support before it
        # claims anything; this is the belt to that braces.
        return _file_failed(client, plugin, unit, out,
                            f"server_ignored_window: asked {win}, got {len(segs)}",
                            Action.BUG)

    if getattr(plugin, "wants_raw_per_segment", False):
        return _run_raw_per_segment(client, plugin, unit, segs, out, tmpdir, sleep)
    if getattr(plugin, "wants_raw", False):
        return _run_raw(client, plugin, unit, segs, out, tmpdir, sleep)

    # STREAMED, one segment at a time: fetched, decoded, handed over, released. This
    # used to decode the WHOLE unit into a list before the analyser saw a frame.
    # Measured 2026-09-26 on one real 30 s -sub segment of hiwatch-083bc14effdc
    # (1280x720, GOP 15): 30 keyframes, 27.65 MB of luma, 41.47 MB with U/V planes. An
    # hour is ~120 segments, so blob_geometry would have held ~3.3 GB there, and
    # colour_histogram ~5 GB (arithmetic, not measured), in one process on the pilot host.
    planes = {"want_planes": True} if getattr(plugin, "want_planes", False) else {}
    last_err: Optional[BaseException] = None

    def as_decoded():
        nonlocal last_err
        for seg in segs:
            _checkpoint()
            fd, path = tempfile.mkstemp(suffix=".ts", dir=tmpdir)
            os.close(fd)
            try:
                t = _now()
                try:
                    _retrying(client.fetch, seg, path, sleep=sleep)
                except Refusal as r:
                    a = action_for(r)
                    if a is Action.SKIP_SEGMENT:
                        out.skipped_segments += 1
                        continue
                    raise _Abandon(*_taken_back(a, f"fetch {seg.segment_id}: {r}"))
                except Exception as e:
                    raise _StationFault(e)
                finally:
                    _add(out, "fetch_s", t)
                out.decoder_runs += 1
                t = _now()
                try:
                    frames = decode(path, plugin.keyframes_only, plugin.want_chroma, **planes)
                except Exception as e:
                    # frame_source RAISES on a segment it cannot read or decode (and
                    # must: a decoder that silently yields nothing is the failure it was
                    # written to refuse). Uncaught, that one segment took down run_once
                    # and every unit still leased. Skipped like a missing segment
                    # instead; counted, and named if nothing in the unit could be seen.
                    out.undecodable_segments += 1
                    last_err = e
                    continue
                finally:
                    _add(out, "decode_s", t)
            finally:
                try:
                    os.unlink(path)
                except OSError:
                    pass
            _checkpoint()                    # never hand a taken-back unit's frames over
            out.segments_scanned += 1
            yield seg, frames

    stream = as_decoded()
    pulled = lambda: out.timings.get("fetch_s", 0.0) + out.timings.get("decode_s", 0.0)
    p0, t = pulled(), _now()
    try:
        try:
            obs = plugin.analyse(stream, state, unit, ctx)
            # An analyser that stopped early still leaves the rest of the hour to be
            # accounted for, so "nothing was looked at" is judged on all of it.
            for _ in stream:
                pass
        finally:
            stream.close()
            # Streamed, so fetch and decode happen INSIDE the analyser's call; its
            # own time is what is left once theirs is taken out.
            out.timings["analyse_s"] = round(_now() - t - (pulled() - p0), 3)
    except _Abandon as a:
        out.action, out.note = a.action, a.note
        return out
    except _StationFault as f:
        raise f.exc
    except Exception as e:                      # analyser crashed: report, do not hide
        # Through _file_failed like every other failure, so there is ONE place that
        # builds a failure body. This used to build its own -- two copies of the rule
        # "a failure report carries no observations", which is how rules drift.
        o = _file_failed(client, plugin, unit, out,
                         f"analyser_raised: {type(e).__name__}: {e}", Action.BUG)
        o.action = None if o.submitted else o.action   # a filed crash is not a stop signal
        return o

    if segs and not out.segments_scanned:
        return _file_failed(client, plugin, unit, out,
                            _nothing_looked_at(segs, out, last_err), Action.BUG)
    save = getattr(plugin, "save_state", None)
    if state is not None and save is not None:
        try:
            save(unit.camera_id, state)
        except Exception as e:
            # The result is still true; only the memory it taught is lost. Say so,
            # and submit: throwing away a measured hour would not bring the state back.
            out.note = f"state not saved: {type(e).__name__}: {e}"

    # Every path -- frames, one raw stream, raw per segment -- submits through _finish,
    # so the row cap, the metrics caps, the identical-body retry and the
    # file-it-with-its-cause rule exist in exactly one place. This path used to carry
    # its own copy; two copies of one rule is how they drift.
    return _finish(client, plugin, unit, out, obs, sleep, thumbs=ctx.get("thumbs"))


def _run_raw(client, plugin, unit, segs, out, tmpdir, sleep):
    """For an analyser that decodes FOR ITSELF from raw bytes (frame_difference).

    WHY IT CANNOT SHARE THE DECODE PASS the other plugins use, measured 2026-09-26:
    frame_difference's threshold (2.0) was calibrated on its own decoder, which does
    `scale=W:96,format=gray`. The shared decoder hands over native-resolution luma.
    On the same four consecutive main segments the shared frames gave a median delta
    of 1.950 against the calibrated decoder's 0.391 -- 4.98x larger. Both happened to
    score sustained=0 there, because that footage is quiet and 1.95 sat just under
    2.0; on busier footage the shared frames would cross the threshold almost every
    interval. So the bytes go to ITS decoder, untouched.

    STREAMED, never buffered: cilex-vision's analyse() taking raw bytes OOM-killed
    their container at ~450 MB/hour doubled by a join. Each segment is read back in
    1 MiB chunks, in order, into the analyser's one long-lived ffmpeg.
    """
    paths, kept, fetched = [], [], []
    try:
        for seg in segs:
            why = _abort_reason()
            if why:
                out.action, out.note = Action.REVOKED, why
                return out
            fd, path = tempfile.mkstemp(suffix=".ts", dir=tmpdir)
            os.close(fd)
            paths.append(path)
            t = _now()
            try:
                _retrying(client.fetch, seg, path, sleep=sleep)
            except Refusal as r:
                a = action_for(r)
                if a is Action.SKIP_SEGMENT and getattr(plugin, "tolerates_holes", False):
                    # track_linking ends its tracks at a gap and flags the cut episodes
                    # open, so a missing segment is dropped from BOTH the stream and
                    # the list handed over -- in step, or its clock refuses the unit.
                    out.skipped_segments += 1
                    continue
                if a is Action.SKIP_SEGMENT:
                    # A raw plugin reads ONE concatenated stream, so a missing segment
                    # is a hole in it, not a skippable item: frame_difference would
                    # score across a gap it cannot see, and audio_energy splits the
                    # stream by each segment's size, so everything after the gap
                    # would be attributed to the wrong segment.
                    return _file_failed(client, plugin, unit, out,
                                        f"stream_has_a_hole: {seg.segment_id} not found", a)
                out.action, out.note = _taken_back(a, f"fetch {seg.segment_id}: {r}")
                return out
            finally:
                _add(out, "fetch_s", t)
            kept.append(seg)
            fetched.append(path)
        if segs and not kept:
            return _file_failed(client, plugin, unit, out,
                                _nothing_looked_at(segs, out, None), Action.BUG)
        if getattr(plugin, "splits_by_bytes", False):
            # The analyser splits the flat stream back into segments using each
            # Segment's catalogued `bytes`. Its own check (labs_audio_energy
            # segments_from_raw) only catches a TOTAL mismatch -- two sizes wrong in
            # compensating directions would misattribute one segment's audio to
            # another with no error. Checking each file makes that impossible.
            for seg, p_ in zip(kept, fetched):
                got = os.path.getsize(p_)
                if seg.bytes is not None and got != seg.bytes:
                    return _file_failed(client, plugin, unit, out,
                                        f"fetched_size_mismatch: {seg.segment_id} "
                                        f"catalogued {seg.bytes}, fetched {got}", Action.BUG)
        out.segments_scanned = len(kept)
        out.decoder_runs = 1 if kept else 0
        why = _abort_reason()
        if why:
            out.action, out.note = Action.REVOKED, why
            return out

        def chunks():
            for p_ in fetched:
                with open(p_, "rb") as f:
                    while True:
                        c = f.read(1 << 20)
                        if not c:
                            break
                        yield c
        t = _now()
        try:
            obs = plugin.analyse_raw(chunks(), kept, unit)
        except Exception as e:
            return _file_failed(client, plugin, unit, out,
                                f"analyser_raised: {type(e).__name__}: {e}", Action.BUG)
        finally:
            _add(out, "analyse_s", t)       # the analyser's OWN decode is in here
    finally:
        for p_ in paths:
            try:
                os.unlink(p_)
            except OSError:
                pass

    if obs is None:
        # None means the analyser could not MEASURE (no keyframes decoded). Filing an
        # empty list would say "looked and found nothing" -- a claim about the scene
        # this worker has no grounds for. So it is a failure, with its cause.
        return _file_failed(client, plugin, unit, out, "no_keyframes_decoded", Action.BUG)
    return _finish(client, plugin, unit, out, obs, sleep)


def _run_raw_per_segment(client, plugin, unit, segs, out, tmpdir, sleep):
    """For an analyser that decodes EACH SEGMENT on its own (optical_flow).

    Different from _run_raw in the one way that matters: segments are INDEPENDENT
    here -- a burst never crosses a segment -- so a missing segment is SKIPPED, not a
    hole. In a concatenated stream a gap corrupts everything after it; here it costs
    exactly that one segment. The plugin is handed each file's path in order.
    """
    fetched = []
    try:
        for seg in segs:
            why = _abort_reason()
            if why:
                out.action, out.note = Action.REVOKED, why
                return out
            fd, path = tempfile.mkstemp(suffix=".ts", dir=tmpdir)
            os.close(fd)
            t = _now()
            try:
                _retrying(client.fetch, seg, path, sleep=sleep)
            except Refusal as r:
                _add(out, "fetch_s", t)
                try:
                    os.unlink(path)
                except OSError:
                    pass
                a = action_for(r)
                if a is Action.SKIP_SEGMENT:
                    out.skipped_segments += 1
                    continue
                out.action, out.note = _taken_back(a, f"fetch {seg.segment_id}: {r}")
                return out
            _add(out, "fetch_s", t)
            fetched.append((seg, path))
        if segs and not fetched:
            return _file_failed(client, plugin, unit, out,
                                _nothing_looked_at(segs, out, None), Action.BUG)
        out.segments_scanned = len(fetched)
        out.decoder_runs = len(fetched)
        why = _abort_reason()
        if why:
            out.action, out.note = Action.REVOKED, why
            return out
        t = _now()
        try:
            obs = plugin.analyse_raw_segments(fetched, unit)
        except Exception as e:
            return _file_failed(client, plugin, unit, out,
                                f"analyser_raised: {type(e).__name__}: {e}", Action.BUG)
        finally:
            # A plugin that skips bursts it could not decode says how many, so the
            # outcome can report a partial unit as partial.
            out.undecodable_segments += int(getattr(plugin, "last_undecodable", 0) or 0)
            _add(out, "analyse_s", t)
    finally:
        for _, p_ in fetched:
            try:
                os.unlink(p_)
            except OSError:
                pass
    return _finish(client, plugin, unit, out, obs, sleep)


def _within_hour(obs, unit):
    """(rows starting inside the claimed hour [hour_start, hour_start + 1 h), how many did not).
    A row whose start cannot be read is kept: the server judges it, not this guess."""
    hs = _hour(unit.hour_start)
    if hs is None:
        return obs, 0
    he = hs + timedelta(hours=1)
    kept, dropped = [], 0
    for ob in obs:
        st = _hour(ob.get("start_time")) if isinstance(ob, dict) else None
        if st is not None and not (hs <= st < he):
            dropped += 1
            continue
        kept.append(ob)
    return kept, dropped


def _finish(client, plugin, unit, out, obs, sleep, thumbs: Optional[dict] = None):
    """Check and submit a unit's observations. The ONE place a result is submitted
    for the raw paths, so the rules below cannot drift between copies: the row cap and
    the metrics caps are checked BEFORE submitting (the server checks both before it
    reads `failed`, so a violation would sink even a failure report), the retry
    resends the identical body, and a refusal is filed with its real cause."""
    why = _abort_reason()
    if why:                                   # taken back: its rows are no longer this
        out.action, out.note = Action.REVOKED, why   # station's to file (CONTRACT: "do NOT submit")
        return out
    # EVERY ROW MUST START INSIDE THE CLAIMED HOUR. The server refuses the WHOLE submission
    # (422 observation_outside_claimed_hour, not retryable) for one that does not, and the
    # unit is lost with it. Measured 2026-09-28/29 by the Windows agent: 16 blob_geometry
    # units refused, some to their third attempt. An hour's last segment runs up to ~30 s
    # past the hour, and a shape seen in that tail was timed there. Such rows are DROPPED
    # here, for every analyser, and counted -- never moved: a clamped row would name a
    # moment at which it was not seen.
    obs, outside = _within_hour(obs, unit)
    if outside:
        out.rows_outside_hour = outside
        logging.getLogger("labs.worker").warning(
            "labs: %s %s %s: %d row(s) outside the claimed hour dropped before submitting",
            unit.analyzer, unit.camera_id, unit.hour_start, outside)
    if len(obs) > MAX_OBSERVATIONS_PER_UNIT:
        return _file_failed(client, plugin, unit, out,
                            f"too_many_observations: {len(obs)} > {MAX_OBSERVATIONS_PER_UNIT}",
                            Action.BUG)
    for ob in obs:
        try:
            check_metrics(ob.get("metrics"))
        except MetricsViolation as e:
            return _file_failed(client, plugin, unit, out, f"metrics_violation: {e}", Action.BUG)
    if thumbs is not None:
        # THUMBNAILS FIRST, then the results that name them (cilex-vision reply4): the server
        # keeps only the thumbnails a row names, so the other order would file rows pointing at
        # nothing. Only the rows that survived the checks above are served -- a row dropped for
        # starting outside the hour takes its thumbnail with it.
        named = sorted({(ob.get("metrics") or {}).get("thumb") for ob in obs} - {None})
        missing = [k for k in named if k not in thumbs]
        if missing:
            return _file_failed(client, plugin, unit, out,
                                f"thumb_missing: {len(missing)} row(s) name a thumbnail never made, e.g. {missing[0]}",
                                Action.BUG)
        t = _now()
        try:
            for key in named:
                why = _abort_reason()
                if why:                          # taken back between two uploads: stop here
                    out.action, out.note = Action.REVOKED, why
                    return out
                try:
                    _retrying(client.put_thumb, unit, key, thumbs[key], sleep=sleep)
                except Refusal as r:
                    a = action_for(r)
                    if a is Action.BUG:
                        return _file_failed(client, plugin, unit, out, f"thumb_refused: {key}: {r}", a)
                    out.action, out.note = _taken_back(a, f"thumb {key}: {r}")
                    return out
                out.thumbs_uploaded += 1
        finally:
            _add(out, "thumbs_s", t)
    body = {"analyzer_version": f"{plugin.version}+{WORKER_VERSION}",
            "segments_scanned": out.segments_scanned, "observations": obs}
    try:
        # RETRYING A SUBMISSION IS SAFE ONLY BECAUSE IT IS THE SAME BODY. cilex-vision's
        # submit_results is not one transaction (routers/labs.py): a version-scoped
        # DELETE of the unit's rows (:1536), then per-observation inserts (:1558), then
        # the unit close (:1603). A cut between them leaves partial rows with the unit
        # still claimed; a re-submit heals it because :1536 clears them first -- but
        # ONLY while analyzer_version is unchanged. So this exact `body` is resent.
        t = _now()
        try:
            _retrying(client.submit, unit, body, sleep=sleep)
        finally:
            _add(out, "submit_s", t)
    except Refusal as r:
        a = action_for(r)
        if a is Action.BUG:
            return _file_failed(client, plugin, unit, out, f"submit_refused: {r}", a)
        out.action, out.note = _taken_back(a, f"submit: {r}")
        return out
    out.submitted = True
    out.observations = len(obs)
    if out.rows_outside_hour:
        out.note = f"{out.rows_outside_hour} row(s) outside the claimed hour dropped (the last segment's tail)"
    return out


def _nothing_looked_at(segs, out, last_err) -> str:
    """Why a unit whose hour HAD footage produced no evidence at all."""
    why = (f"nothing_looked_at: {len(segs)} listed, {out.skipped_segments} gone, "
           f"{out.undecodable_segments} undecodable")
    if last_err is not None:
        why += f"; last: {type(last_err).__name__}: {last_err}"
    return why


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
    why = _abort_reason()
    if why:
        # Taken back mid-unit. Whatever failed next -- above all the decoder the reporter
        # killed -- is the stop's doing, not the footage's: filing it would spend one of
        # the unit's three attempts on a lie.
        out.action, out.note = Action.REVOKED, f"{why} (not filed: {reason})"[:500]
        return out
    heard = _heard.last if _heard is not None else None
    if heard and heard not in reason:
        reason = f"{reason} | last warning: {heard}"
    # Before blaming the footage, ask whether this station can start its decoder at all. If
    # not, the failure is filed under THAT cause -- the attempt was spent at the claim either
    # way, and a lapsed lease would be labelled "lease expired", which says even less -- and
    # the pass ends as fatal (run_once), so no further unit is claimed and failed the same way.
    try:
        fault = STATION_CHECK() if STATION_CHECK is not None else None
    except Exception as e:                       # the check itself must never file a unit
        fault = f"the decoder check itself failed: {type(e).__name__}: {e}"
    if fault:
        out.station_fault = fault
        reason = f"station_fault: {fault} -- not the footage (the unit's own error: {reason})"
    body = {"analyzer_version": f"{plugin.version}+{WORKER_VERSION}",
            "segments_scanned": out.segments_scanned, "observations": [],
            "failed": True, "error": fit(reason, 500)}
    out.action = action
    out.note = reason
    t = _now()
    try:
        client.submit(unit, body)
        out.submitted = True
        out.filed_failed = True
    except Refusal as r:
        out.note = f"{reason}; filing it as failed was refused too: {r}"
    finally:
        _add(out, "submit_s", t)
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
    # The server ANSWERED but could not serve the claim now: 503 labs_busy (its claim scan
    # timed out) or a 5xx with no code (the server failing, not refusing). Kept apart from
    # `unreachable` because the Labs screen shows it: "cannot reach the server" is not true
    # of a server that has just replied. Same wait (the next pass, a minute on).
    busy: Optional[str] = None
    outcomes: list = field(default_factory=list)
    # The control plane (2026-09-28): lanes the server says are not running, a claim refused
    # because this station's reports are not arriving, and units taken back mid-run.
    not_running: list = field(default_factory=list)
    not_reporting: bool = False
    revoked: int = 0


def run_once(client: LabsClient, plugins: Iterable, *, decode, states: dict,
             gate: Callable[[], bool] = lambda: True, claim_limit: int = 4,
             context_for: Callable[[ScanUnit], dict] = lambda u: {},
             sleep: Callable[[float], None] = time.sleep,
             max_retries: int = 5,
             holding: Callable[[Optional[ScanUnit]], None] = lambda u: None,
             revoked: Callable[[ScanUnit], Optional[str]] = lambda u: None) -> RunReport:
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
                elif a is Action.NOT_RUNNING:
                    rep.not_running.append(plugin.name); units = []
                elif a is Action.SERVER_BUSY:
                    rep.busy = f"claim {plugin.name}: the server is busy ({r}) -- trying again in a minute"
                    return rep
                elif a is Action.NOT_REPORTING:
                    rep.not_reporting = True
                    rep.unreachable = f"claim {plugin.name}: the server has no recent report from this station ({r})"
                    return rep
                elif a is Action.RETRY_LATER and tries < max_retries:
                    tries += 1; sleep(min(60.0, 2.0 ** tries))
                elif _uncoded_server_error(r):
                    # A 5xx with NO code is the server failing, not refusing. At claim it is
                    # cilex-vision's claim query running over its 30 s database timeout
                    # (CV, 2026-09-28: 3 of 20 claims that night). FATAL sat each station
                    # out for FATAL_S = 10 min per hit; the next pass one minute on
                    # (UNREACHABLE_S) usually just works. Not retried here, so a server at
                    # its limit gets one claim a minute. A timeout can land after the lease
                    # is written, and that unit is swept as "lease expired" whichever wait
                    # follows, so the shorter wait orphans nothing more.
                    rep.busy = (f"claim {plugin.name}: the server answered HTTP {r.status} "
                                "with no code (not a refusal) -- trying again in a minute")
                    return rep
                elif a is Action.FATAL:
                    rep.fatal = str(r); return rep
                elif a is Action.RETRY_LATER:
                    rep.unreachable = f"claim {plugin.name}: gave up after {tries} retries: {r}"
                    return rep
                else:
                    rep.fatal = f"claim {plugin.name}: {r} -> {a.value}"; return rep
        rep.claimed += len(units)
        for unit in units:
            holding(unit)
            try:
                o = run_unit(client, plugin, unit, decode=decode, states=states,
                             context=context_for(unit), sleep=sleep,
                             abort_check=lambda u=unit: revoked(u))
            finally:
                holding(None)
            rep.outcomes.append(o)
            if o.submitted:
                rep.submitted += 1
            else:
                rep.abandoned += 1
            if o.action is Action.REVOKED:
                rep.revoked += 1
            if o.action is Action.FATAL:
                rep.fatal = o.note; return rep
            if o.station_fault:
                rep.fatal = f"this station cannot start its decoder: {o.station_fault}"
                return rep
            if o.action is Action.STOP_ANALYSER:
                rep.stopped_analysers.append(plugin.name); break
    return rep
