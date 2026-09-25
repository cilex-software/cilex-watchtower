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

import b1_illumination as b1
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
