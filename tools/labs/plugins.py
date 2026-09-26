"""Adapters from the pure analysers in tools/labs/ to the worker.

Each plugin tells the worker how to feed its analyser (how many segments, which
stream, whether it needs chroma, whether it carries state) and translates the
analyser's output into the API's ObservationIn. The TRANSLATION is the worker's
job by design: analysers are pure and know only offsets within a segment, so
anchoring to wall-clock time needs the segment's start_time, which only the worker
has.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Optional

import hashlib

import b1_illumination as b1
import frame_source as fs
import labs_framediff as fdiff
import labs_audio_energy as ae
import labs_optical_flow as oflow
import labs_perceptual_hash as ph
import worker as W
import shape_observations as so

# ObservationIn's typed columns, read from the running service's OpenAPI (1.0.57).
# Anything an analyser produces outside this set goes into `metrics` -- see below.
TYPED = {"start_time", "end_time", "shape_class", "shape_confidence", "object_class",
         "confidence", "object_count", "bbox_x", "bbox_y", "bbox_w", "bbox_h",
         "scene_light", "metrics"}


def _parse(ts: Optional[str]) -> Optional[datetime]:
    if not ts:
        return None
    t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    # A naive stamp is a wire fault, not local time. Refuse to guess its zone:
    # this repo has already shipped one silent 3-hour shift from exactly that.
    if t.tzinfo is None:
        raise ValueError(f"segment start_time has no offset: {ts!r}")
    return t


def _iso(t: datetime) -> str:
    return t.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


_FFMPEG: Optional[str] = None


def ffmpeg_exe() -> str:
    """The ffmpeg that RUNS, found once and named explicitly to every analyser that
    decodes for itself. Each of them defaults to a bare `ffmpeg`, and on the booth
    there is none on PATH: three ffmpeg.exe on disk, one of which works, and only
    frame_source's own search finds it. The Windows agent measured every unit of
    frame_difference, optical_flow and perceptual_hash failing FileNotFoundError
    there (2026-09-26). Named per call rather than by editing PATH, so the plugins
    behave the same under run_worker, the smoke harness and the tests.

    Raises RuntimeError when there is none. run_worker asks BEFORE claiming: a
    station fault must not spend three attempts on each of the fleet's camera-hours."""
    global _FFMPEG
    if _FFMPEG is None:
        _FFMPEG = fs.find_ffmpeg()
    return _FFMPEG


# ----------------------------------------------------------------------------------
class IlluminationPlugin:
    """B1. Stateless; two segments per hour answer it (cost is per-FRAME, so the
    lever is frames decoded, and illumination needs every hour but not all of one).

    ASTRONOMY IS NOT AVAILABLE TO A STATION. No endpoint exposes sun times and
    ScanUnit carries no light field (checked against the running OpenAPI,
    2026-09-25). So unless the worker's context supplies one, `astronomical` is
    None and the analyser returns `ir` when the pixels prove it and `unknown`
    otherwise -- honest, with chroma and luma always carried in `metrics` so the
    server can resolve day/dusk/night from its own site_solar_times. Computing an
    ephemeris HERE would re-implement cilex-vision's, including the two bugs they
    hit in theirs (inverted hour angle; midnight sun read backwards).
    """
    name = "illumination"
    version = "b1-1"
    segment_limit = 2
    keyframes_only = True
    want_chroma = True
    stateful = False
    # Pinned, because the calibration is stream-specific: the IR floor of 4.0930 was
    # measured on MAIN in passthrough space, and nothing has measured it on sub.
    stream_type = "main"

    def new_state(self):
        return None

    def analyse(self, segs, state, unit, context):
        out = []
        for seg, frames in segs:
            stats = b1.from_shared_frames(frames)
            # Per-segment astronomy from the server (1.0.58+). A context value is
            # only a fallback for tests and for an old server; the segment wins.
            if seg.astro_key_present:
                astro, source = seg.scene_light_astronomical, (
                    "server" if seg.scene_light_astronomical is not None else "no_solar_row")
            else:
                astro, source = context.get("astronomical"), (
                    "context" if context.get("astronomical") else "server_predates_1_0_58")
            meta = b1.SegmentMeta(unit.camera_id, astro, seg.bytes, seg.duration_s)
            o = b1.analyse(stats, meta)
            st, en = _parse(seg.start_time), _parse(seg.end_time)
            if st is None:
                continue          # cannot place it in time; never invent a stamp
            m = dict(o.metrics)
            if o.notes:
                # W.fit, not a slice: the server's cap is 120 (see worker.check_metrics)
                # and this used to cut at 400, which could produce a 141-char note.
                m["notes"] = W.fit("; ".join(o.notes))
            m["segment_id"] = seg.segment_id
            # ALWAYS record what the sky was, even when the row says `ir`. That is what
            # keeps the disagreement recoverable per row: IR-cut closed in astronomical
            # daylight is the case B1 exists to find, and a row reading only `ir`
            # could not show it. (cilex-vision's suggestion; adopted verbatim.)
            m["astro"] = astro
            m["astro_source"] = source
            out.append({"start_time": _iso(st), "end_time": _iso(en or st),
                        "scene_light": o.scene_light, "metrics": m})
        return out


# ----------------------------------------------------------------------------------
class ShapePlugin:
    """A4-A6 (the Windows agent's analyser). Stateful: ONE background model per
    camera carried across segments, because a model cannot converge inside one
    30 s segment (they measured 0 observations from a single segment, 1,103 from
    10 minutes through one model). Keyframe-only is not an optimisation here:
    1,036 CPU-s/camera-hour at full rate against 18.3 at keyframes, 57x.

    Stream `sub`: their cost figures were measured on -sub, and it is ~10x smaller
    to fetch than main.
    """
    name = "blob_geometry"
    version = "shape-1"
    segment_limit = 200            # the API's own default ceiling for one hour
    keyframes_only = True
    want_chroma = False
    stateful = True
    stream_type = "sub"

    def __init__(self, cfg: Optional["so.Config"] = None):
        self.cfg = cfg

    def new_state(self):
        return so.AnalyserState(self.cfg)

    def analyse(self, segs, state, unit, context):
        out = []
        stream = []
        for seg, frames in segs:
            meta = so.SegmentMeta.from_api({
                "segment_id": seg.segment_id, "camera_id": unit.camera_id,
                "start_time": seg.start_time, "duration_s": seg.duration_s,
                "stream_type": seg.stream_type, "width": seg.width,
                "height": seg.height, "codec": seg.codec})
            stream.append((meta, frames, seg))
        for (meta, obs, stats), (_, _, seg) in zip(
                so.analyse_window(((m, f) for m, f, _ in stream), state, self.cfg),
                stream):
            base = _parse(seg.start_time)
            if base is None:
                continue
            for ob in obs:
                p = ob.as_payload()
                t = base + timedelta(seconds=float(p.get("t_offset_s") or 0.0))
                row = {"start_time": _iso(t), "end_time": _iso(t)}
                extra = {}
                for k, v in p.items():
                    if k in TYPED:
                        row[k] = v
                    else:
                        # WHY THIS IS NOT JUST as_payload(): the API has no column for
                        # aspect, area_frac, fill_ratio, area_stability or
                        # motion_coherence, and ObservationIn sets no `extra` policy,
                        # so Pydantic's default IGNORES unknown keys without error.
                        # Sent as-is they would vanish on arrival. `metrics` is the
                        # jsonb column that exists for exactly this.
                        extra[k] = v
                if extra:
                    row["metrics"] = extra
                out.append(row)
        return out


# ----------------------------------------------------------------------------------
class FrameDifferencePlugin:
    """A1/A2 (cilex-vision's analyser, vendored byte-identical as labs_framediff.py and
    pinned to their source by tools/tests/labs-worker.py). Answers how violent the most
    violent moment was (`peak`) and how long activity lasted (`sustained`), from
    keyframe differencing. Proven against a labelled control.

    IT DECODES FOR ITSELF, and must: its threshold (2.0) was calibrated on its own
    `scale=W:96,format=gray` decoder. The shared decoder's native-resolution luma gave
    deltas 4.98x larger on the same footage (measured 2026-09-26). See worker._run_raw.

    A WINDOW, NOT A SEGMENT: one 30 s segment yields ~8 keyframes, so per-segment
    `sustained` can only be 0..7. The server returns `window` CONSECUTIVE main segments
    around `window_at` (a6671c5). window=4 is ~2 minutes, ~1/30 of the 96.8
    CPU-s/camera-hour and ~600 MB of main that a full hour would cost.
    """
    name = "frame_difference"
    version = "fd-1"
    stream_type = "main"             # the threshold was calibrated on main
    keyframes_only = True
    want_chroma = False
    stateful = False
    wants_raw = True
    window = 4
    segment_limit = window           # unused when `window` is set; the server refuses both

    def new_state(self):
        return None

    @staticmethod
    def window_at(unit) -> float:
        """Where in the hour to look, DETERMINISTIC from the hour.

        Deterministic is what makes a retry safe: a re-submission after a dropped
        connection must describe the SAME two minutes, because cilex-vision's
        version-scoped DELETE replaces the unit's rows with whatever arrives. A random
        position would quietly swap one window's scores for another's. A hash (not
        Python's hash(), which is salted per process) gives a different minute each
        hour and the same one on every retry.
        """
        h = hashlib.sha256(str(unit.hour_start).encode()).digest()
        return int.from_bytes(h[:4], "big") / 2**32

    @staticmethod
    def supported_by(openapi: dict) -> "Optional[str]":
        """None if the server can serve a window; otherwise why not."""
        try:
            for path, ops in openapi["paths"].items():
                if path.endswith("/segments") and "/labs/scan/" in path:
                    names = {p["name"] for p in ops.get("get", {}).get("parameters", [])}
                    return None if {"window", "window_at"} <= names else \
                        "server predates `window` on list_segments (cilex-vision a6671c5)"
        except Exception:
            pass
        return "could not read list_segments from the server's OpenAPI"

    def analyse_raw(self, chunks, segs, unit):
        if not segs:
            return []            # no footage in the window: a real answer, not a failure
        span = sum(float(s.duration_s or 0.0) for s in segs)
        # ALWAYS pass span_s: `sustained` counts keyframe intervals (~4 s here), so only
        # `sustained_s` is comparable across cameras.
        scores = fdiff.analyse(chunks, span_s=span if span > 0 else None, ffmpeg=ffmpeg_exe())
        if scores is None:
            return None          # segments existed but nothing decoded: cannot measure
        st, en = _parse(segs[0].start_time), _parse(segs[-1].end_time)
        if st is None:
            return None
        # One observation per window. No object class, count or bbox: this analyser
        # observes an ACTIVITY LEVEL, not an object. Metrics passed through UNCHANGED.
        return [{"start_time": _iso(st), "end_time": _iso(en or st),
                 "metrics": scores.as_metrics()}]


# ----------------------------------------------------------------------------------
class AudioEnergyPlugin:
    """B8 (cilex-vision, vendored byte-identical as labs_audio_energy.py). Loudness,
    sharp onsets and band energy, where the footage carries audio.

    RAW, and it needs EVERY segment of the hour: the analyser splits the concatenated
    stream back into segments by each one's catalogued `bytes`, so the worker checks
    every fetched file against that size before feeding it (splits_by_bytes).

    [] IS A RESULT -- "checked, no audio event" -- and is filed as such. A stretch with
    no audio track comes back as a `no_audio` row, not as []. Decode errors raise and
    are filed as failures with their cause, never as an empty submission.

    SCOPE IS NOT A PLUGIN DECISION, and it matters: only continuous cameras carry audio
    in the footage, because the motion recorder strips it
    (recorder-service/motion/prebuffer.py:119, `-map 0:v:0 -an`). On every other camera
    this fetches a whole main hour -- 192-337 MB -- to answer `no_audio`. That is set by
    the analyser's scope in the register, which is the operator's.
    """
    name = "audio_energy"
    version = "b8-1"
    stream_type = "main"             # sub has no audio (measured by cilex-vision)
    segment_limit = 200              # an hour is ~120 x 30 s; it needs every one
    keyframes_only = True            # unused on the raw path
    want_chroma = False
    stateful = False
    wants_raw = True
    splits_by_bytes = True

    def new_state(self):
        return None

    def analyse_raw(self, chunks, segs, unit):
        # hour_start, exactly: the server refuses the WHOLE unit (422
        # observation_outside_claimed_hour, not retryable) if one row starts at or
        # after the hour's end, and an hour's last segment runs a few seconds past it.
        # The module clamps that tail into the hour's last window (cilex-vision
        # 21258fd); given the claimed hour it does not have to derive it.
        return ae.analyse_raw_unit(chunks, segs, hour_start=_parse(unit.hour_start),
                                   ffmpeg=ffmpeg_exe())


# ----------------------------------------------------------------------------------
class OpticalFlowPlugin:
    """cilex-vision's optical_flow, vendored byte-identical. Which way things move, how
    fast, and whether they move as one body.

    EACH SEGMENT IS ITS OWN BURST (10 s at 5 fps, 320 px), decoded by the analyser's
    own software ffmpeg -- a burst never crosses a segment, so the list is a SPREAD
    `limit`, not a consecutive window, and a missing segment is simply skipped.
    It decodes all frames, not keyframes: motion between frames is the measurement.

    A burst that fails to decode is SKIPPED, never reported as "still": a decode
    failure is not evidence that nothing moved. A burst where nothing steady moved
    returns None and files nothing, so [] for a unit means "checked, nothing moved"
    -- which is exactly why [] must never be returned when NOTHING decoded. That
    used to happen: 1 MB of junk and a real quiet capture filed identical bodies
    (measured by the Windows agent, 2026-09-26). If no burst could be looked at, the
    last DecodeError is raised, so the unit is filed failed in ffmpeg's own words.

    segment_limit=30 is the budget knob: one burst per 2 min, ~19 CPU-s/camera-hour.
    Every segment (120) is ~78; one per hour ~0.7. Setting it is the operator's.
    """
    name = "optical_flow"
    version = "1"
    stream_type = "sub"              # equal to main at ~0.4x the CPU (cilex-vision)
    segment_limit = 30
    keyframes_only = False
    want_chroma = False
    stateful = False
    wants_raw_per_segment = True

    def new_state(self):
        return None

    def analyse_raw_segments(self, fetched, unit):
        try:
            import cv2
            cv2.setNumThreads(1)     # per cilex-vision: one thread, beside a live wall
        except Exception:
            pass
        out, looked, last_err = [], 0, None
        self.last_undecodable = 0
        for seg, path in fetched:
            # A DATETIME, not the string. to_observation is typed `start_time: datetime`
            # and reads .tzinfo; handed the wire string it raised AttributeError on
            # every segment -- which is not the DecodeError caught below, so every unit
            # would have been filed as failed. Caught by reading the signature before
            # the first real run, not after.
            st = _parse(seg.start_time)
            if st is None:
                continue
            try:
                r = oflow.analyse_burst(path, ffmpeg=ffmpeg_exe())
            except oflow.DecodeError as e:
                self.last_undecodable += 1
                last_err = e
                continue             # not "still": we could not look at THIS burst
            looked += 1
            ob = oflow.to_observation(r, start_time=st,
                                      segment_id=seg.segment_id, stream_type="sub")
            if ob is not None:
                out.append(ob)
        if fetched and not looked:
            if last_err is not None:
                raise last_err
            raise ValueError("no fetched segment had a start_time; nothing was looked at")
        return out


# ----------------------------------------------------------------------------------
class PerceptualHashPlugin:
    """cilex-vision's perceptual_hash, vendored byte-identical. A 64-bit fingerprint per
    keyframe and runs of no change, so repeats and dead-still hours can be found.

    IT DECODES FOR ITSELF, for TIMING, measured 2026-09-26. The spec's recipe fed it
    the shared decoder's timestamps, which assume keyframes arrive at a constant
    interval. On sub they do not: extra IDRs make gaps as short as 0.05 s on busy
    footage. Against ffprobe's true PTS the constant-step times were wrong by a median
    0.36-0.43 s and up to 1.33 s on the busy segments -- and 0.07 s on a quiet one. So
    the error lands exactly where this analyser's 1-second spacing rule operates, and
    only on the footage where it matters. The spec also says "prefer true PTS"; its own
    decoder reads it, and analyse() maps each keyframe back to its segment from the
    segment start times. So: the raw stream plus those starts, and no shared frames.

    Frozen feed = identical_count > 0, NOT distance 0: a featureless frame reads as
    maximal change. That is the analyser's rule; the worker passes rows through.
    """
    name = "perceptual_hash"
    version = "phash-1"
    stream_type = "sub"
    segment_limit = 12
    keyframes_only = True
    want_chroma = False
    stateful = False
    wants_raw = True

    def new_state(self):
        return None

    def analyse_raw(self, chunks, segs, unit):
        if not segs:
            return []
        starts = []
        for sg in segs:
            t = _parse(sg.start_time)
            if t is None:
                # Every segment's bytes are in the stream, so one we cannot place in time
                # cannot simply be left out: the keyframes after it would be attributed
                # to the wrong segment. Refuse, with the cause.
                raise ValueError(f"segment {sg.segment_id} has no start_time; "
                                 "cannot attribute keyframes in a concatenated stream")
            starts.append(t.timestamp())
        hs = _parse(unit.hour_start)
        obs = ph.analyse(chunks, starts, hour_start_s=hs.timestamp() if hs else None,
                         per_keyframe=False, ffmpeg=ffmpeg_exe())
        for o in obs:
            o.setdefault("metrics", {})["stream"] = "sub"
        return obs
