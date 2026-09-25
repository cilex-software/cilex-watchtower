#!/usr/bin/env python3
"""A4/A5/A6 — bbox, object_count and shape_class from background subtraction.

THE SEAM. This module is the analyser half of LABS-8, and it is PURE in the sense
cilex-vision asked for on 2026-09-23: it knows nothing about HTTP, leases, claims,
retries or that a thing called Labs exists. It takes luma frames and segment
metadata and returns observations. The worker owns everything else.

    worker    claim, lease, fetch, idle-gating, retry, submit
    analyser  (frames, segment metadata) -> observations      <-- this file

WHICH ANALYSERS THIS FEEDS. Three registry slugs, read live from
`GET /labs/analyzers` on 2026-09-23, not assumed:

    foreground_mask  (B3)  "foreground area and blob count ... gives bbox and
                            object_count real values instead of nulls"   -> A4, A5
    blob_geometry    (B4)  "blob aspect ratio, size and size stability ...
                            reports geometry, never a species"           -> A6
    track_linking    (B6)  "blob association across frames ... turns
                            instantaneous detections into episodes"      -> NOT this file

Both B3 and B4 are `enabled: false` today; only `frame_difference` and
`illumination` are live. That gates when results can be FILED, not when this can be
written or tested, which is the point of the seam.

WHAT `object_count` MEANS HERE, AND WHY THAT IS NOT A GUESS. It is the number of
qualifying foreground blobs in the frame the bbox came from — an instantaneous
count. cilex-vision left the definition open and I asked rather than assumed; the
registry answers it. B6 exists to do "blob association across frames" and to turn
"instantaneous detections into episodes". If `object_count` meant distinct objects
across a segment, B6 would have nothing left to do. So the per-frame reading is
what the register implies, and `ANALYSER_VERSION` below states it in the string
itself so no later reader can mistake one for the other.

WHAT THIS DELIBERATELY NEVER SETS. `object_class` and its `confidence`. Those are
what a MODEL concludes, there is no model here, and a species is not a shape. The
registry's `suggests` mapping (blob_tall -> person) is advisory, lives server-side
and must not be used to fill a class field from geometry. cilex-vision made exactly
this error themselves with an `object_class="group"` on the boar payload and
retracted it; the omission below is that retraction honoured.

WHAT `shape_confidence` MEANS. Geometric unambiguity — how far the measurement sits
from the decision boundary that chose the class. It is REQUIRED by the API (422
`shape_without_confidence` otherwise). It is NOT the probability that any semantic
label is correct, and must never be read as P(person). A tall blob measured with
total certainty is still equally a person, a post or a tree trunk in wind — the
registry's own notes say so for every class.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field, asdict
from typing import Iterable, Iterator, Sequence

import numpy as np
import cv2

# One version string per behavioural change. It names the object_count reading on
# purpose: a stored number whose semantics are only in a letter is a number whose
# semantics are lost.
ANALYSER_VERSION = "wt-shape-1.0.0+objcount=per_frame"

# The six registered shape classes, verbatim from GET /labs/shape-classes
# (2026-09-23). Never invent a slug: an unregistered value is refused server-side.
SHAPE_CLASSES = (
    "blob_tall",
    "blob_wide",
    "blob_large",
    "blob_compact",
    "blob_multi",
    "shape_indeterminate",
)


@dataclass(frozen=True)
class Config:
    """Every threshold that decides a class, in one place, with its reasoning.

    These are geometric conventions, not tuned constants — nothing here was fitted
    to data, and none of them should be described as measured.
    """

    # --- foreground model ---------------------------------------------------
    # MOG2 counts `history` in FRAMES, not seconds. cilex-vision lost a run to
    # that, and it bites harder here than it did for them: this fleet's keyframe
    # interval is not uniform. Measured on 24 of 130 cameras from this booth
    # (docs/perf/2026-09-23-win-a4a6-decode-cost): GOP 50 -> 3.31 s on 12 cameras,
    # GOP 15 -> 0.99 s on 9, i.e. a 3.3x spread in frame rate on the keyframe path
    # alone. A single history constant tuned by wall-clock on one camera is wrong
    # by that factor on another, and it presents as "the model did not converge
    # here", which reads as wind or sun and is a config artefact.
    #
    # So history is DERIVED from the measured frame step, never set directly.
    history_seconds: float = 100.0  # cilex-vision measured convergence at ~100 s
    history_frames_min: int = 12
    history_frames_max: int = 2000
    var_threshold: float = 16.0
    detect_shadows: bool = False  # a shadow is not an object; and it costs time

    # --- what counts as a blob at all --------------------------------------
    # As a FRACTION of frame area, because this fleet's sub stream is 1280x720,
    # 640x360 and 640x480 (three values; cilex-vision's 461k-segment census lists
    # the first two). A pixel threshold means different things per camera, which is
    # the same reason bbox is normalised.
    min_blob_area_frac: float = 0.0005  # 461 px at 1280x720
    morph_open_px: int = 3  # kill single-pixel speckle before labelling

    # --- class boundaries ---------------------------------------------------
    # "Notably" greater, per the registry's wording for blob_tall/blob_wide.
    aspect_t: float = 1.4
    # "Occupies much of the frame" (blob_large). Deliberately high: the registry
    # warns this shares a signal with a lens obstruction and must not share a
    # conclusion, so it should fire rarely and mean it.
    large_area_frac: float = 0.20
    # "Low area, aspect near 1" (blob_compact).
    compact_max_area_frac: float = 0.02
    compact_min_fill: float = 0.45
    # blob_multi is "several blobs moving TOGETHER ... with correlated motion".
    # Several blobs alone is not enough — correlation has to be measured, and if it
    # cannot be, this class is not claimed.
    multi_min_blobs: int = 2
    multi_min_coherence: float = 0.6

    # --- confidence shaping -------------------------------------------------
    # A margin of this many multiplicative steps past the boundary saturates
    # confidence at conf_max. Chosen so a 3x-past-boundary measurement reads as
    # near-certain GEOMETRY, which is all confidence claims.
    conf_span: float = 3.0
    conf_min: float = 0.50
    conf_max: float = 0.95


@dataclass(frozen=True)
class SegmentMeta:
    """What the list endpoint returns, with the nullability it really has.

    cilex-vision measured 461,000 segments and warned about three things that cost
    an hour each if assumed away, all of which are honoured here:
      - `codec`, `width`, `height` are NULLABLE (2 rows came back codec="unknown")
      - "sub" is not one resolution; do not hard-code a frame size
      - 4-second segments exist (motion-triggered), alongside 30-second ones
    """

    segment_id: str = ""
    camera_id: str = ""
    duration_s: float | None = None
    width: int | None = None
    height: int | None = None
    codec: str | None = None
    stream_type: str | None = None
    start_time: str | None = None

    @classmethod
    def from_api(cls, d: dict) -> "SegmentMeta":
        """Build from the list endpoint's JSON, tolerating every documented null."""
        def _i(v):
            try:
                return int(v) if v is not None else None
            except (TypeError, ValueError):
                return None

        def _f(v):
            try:
                return float(v) if v is not None else None
            except (TypeError, ValueError):
                return None

        codec = d.get("codec")
        if codec == "unknown":       # a real value in the corpus, not a null
            codec = None
        return cls(
            segment_id=str(d.get("segment_id") or ""),
            camera_id=str(d.get("camera_id") or ""),
            duration_s=_f(d.get("duration_s")),
            width=_i(d.get("width")),
            height=_i(d.get("height")),
            codec=codec,
            stream_type=d.get("stream_type"),
            start_time=d.get("start_time"),
        )


@dataclass(frozen=True)
class Frame:
    """One decoded frame, luma only.

    `luma` is a 2-D uint8 array — the Y plane straight off a yuv420p frame, with no
    colour conversion. Measured on this booth (n=9, ranges non-overlapping):
    delivering yuv420p costs 31.3 CPU-s/camera-hour against 54.6 for bgr24, and
    asking swscale for `gray` costs 47.0 — so the obvious "MOG2 only needs luma,
    convert to gray" move is a 1.72x PESSIMISATION against simply taking plane 0.
    """

    index: int
    t_offset_s: float  # seconds from the start of the window, monotonic
    luma: np.ndarray
    # OPT-IN, default None. Added 2026-09-25 by the Linux box so B1 (illumination)
    # can share this decode pass instead of running a second one. ADDITIVE: A4-A6
    # never asks for it and pays nothing, and the cheap-decode property the
    # docstring above defends is untouched.
    # WHY IT IS FREE: the decoder already delivers yuv420p, so U and V are already
    # on the pipe and were simply discarded at `buf[:ybytes]`. B1 needs one scalar
    # from them -- mean|U-128| + mean|V-128| -- which is exactly 0.0 when the
    # IR-cut filter is closed (measured 0.0000 on IR rows against a 4.2944 floor
    # across 220 camera-slot rows). Carried as a float, not the planes, so nothing
    # is retained and no reshape or colour conversion happens.
    chroma_energy: float | None = None


@dataclass
class Observation:
    """One detected blob, in the shape the fields are stored in.

    Note what is absent: object_class and confidence. See the module docstring.
    """

    segment_id: str
    frame_index: int
    t_offset_s: float

    # A4 — normalised 0..1, w and h strictly > 0 (the API refuses otherwise)
    bbox_x: float
    bbox_y: float
    bbox_w: float
    bbox_h: float

    # A5 — blobs in THIS frame (see module docstring on why per-frame)
    object_count: int

    # A6 — a registered slug, plus the confidence the API requires beside it
    shape_class: str
    shape_confidence: float

    # The measurements the class was derived from. Kept so a reader can audit the
    # classification instead of trusting it, and because B4's own title asks for
    # "size stability".
    aspect: float = 0.0
    area_frac: float = 0.0
    fill_ratio: float = 0.0
    area_stability: float | None = None
    motion_coherence: float | None = None

    def as_payload(self) -> dict:
        """Dict for the worker to submit. Drops the None extras rather than
        sending nulls the server did not ask for."""
        d = asdict(self)
        return {k: v for k, v in d.items() if v is not None}


@dataclass
class WindowStats:
    """What happened, for the worker to log and for cost accounting."""

    frames_seen: int = 0
    frames_scored: int = 0
    frames_warmup: int = 0
    observations: int = 0
    model_resets: int = 0
    frame_step_s: float | None = None
    history_frames: int | None = None
    resolutions: list[tuple[int, int]] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


class AnalyserState:
    """The background model, carried ACROSS segments by the caller.

    WHY THIS IS CALLER-OWNED STATE AND NOT A LOCAL. A background model cannot
    converge inside one 30-second segment. cilex-vision measured convergence over
    an 8-minute window and matched models "by time (25 frames at keyframe rate,
    ~100 s)"; a 30 s segment does not contain 100 s. So a function that built a
    fresh model per segment would spend every segment in warm-up and emit noise —
    which is precisely the failure their §3 was worried about, arriving by a
    different route.

    They also measured that this is safe: concatenated MPEG-TS segment joints do
    NOT fake motion (joint deltas 0.740 against 0.766 within-segment, 0.97x,
    crossing threshold LESS often). So streaming many segments through one model is
    sound for the algorithm as well as for the iGPU.

    The model resets only on a REAL discontinuity — a frame size change or a
    different camera — because a model carried across either is a model describing
    a scene that no longer exists.
    """

    def __init__(self, cfg: Config | None = None):
        self.cfg = cfg or Config()
        self._bs = None
        self._shape: tuple[int, int] | None = None
        self._camera_id: str | None = None
        self._history_frames: int | None = None
        self._frame_step_s: float | None = None
        self._warm = 0
        # previous frame's blob centroids, for measuring motion coherence
        self._prev_centroids: np.ndarray | None = None
        # per-frame areas of the dominant blob, for size stability
        self._recent_areas: list[float] = []
        self.resets = 0

    # -- calibration ---------------------------------------------------------

    def calibrate(self, frame_step_s: float | None) -> int:
        """Derive MOG2 `history` in FRAMES from the measured frame step.

        This is the per-camera correction described in Config: the fleet's keyframe
        interval spans 3.3x, so the same wall-clock memory is a different frame
        count on different cameras.
        """
        cfg = self.cfg
        if not frame_step_s or frame_step_s <= 0:
            # No usable timestamps. Fall back to a frame count rather than
            # inventing a rate, and say so in the stats.
            frames = cfg.history_frames_min * 4
        else:
            frames = int(round(cfg.history_seconds / frame_step_s))
        frames = max(cfg.history_frames_min, min(cfg.history_frames_max, frames))
        self._frame_step_s = frame_step_s
        self._history_frames = frames
        return frames

    def _ensure(self, shape: tuple[int, int], camera_id: str) -> bool:
        """Create or reset the model. Returns True only for a genuine RESET.

        First creation is not a reset, and the distinction matters because
        `model_resets` is a health signal a worker will log: a reset mid-window
        means continuity was lost and the model has to converge again, while
        creating it on the first frame is just starting up. Reporting 1 on a
        healthy first segment would make the signal useless -- absent data
        rendering as a fault is the same error as rendering it as healthy.
        """
        first = self._bs is None
        reset = (
            first
            or self._shape != shape
            or (camera_id and self._camera_id and camera_id != self._camera_id)
        )
        if reset:
            cfg = self.cfg
            self._bs = cv2.createBackgroundSubtractorMOG2(
                history=self._history_frames or (cfg.history_frames_min * 4),
                varThreshold=cfg.var_threshold,
                detectShadows=cfg.detect_shadows,
            )
            self._shape = shape
            self._camera_id = camera_id or self._camera_id
            self._warm = 0
            self._prev_centroids = None
            self._recent_areas.clear()
            if not first:
                self.resets += 1
        return reset and not first

    @property
    def warm_frames(self) -> int:
        return self._warm

    @property
    def history_frames(self) -> int | None:
        return self._history_frames

    @property
    def is_warm(self) -> bool:
        """Has the model seen enough frames to be worth believing?

        Deliberately a fraction of history rather than all of it: MOG2 is usable
        well before its window is full, and requiring the full 100 s would discard
        the first three segments of every window.
        """
        need = max(self.cfg.history_frames_min, (self._history_frames or 0) // 4)
        return self._warm >= need


# ---------------------------------------------------------------------------
# geometry -> class
# ---------------------------------------------------------------------------


def _confidence(margin_ratio: float, cfg: Config) -> float:
    """Map a multiplicative margin past a boundary onto [conf_min, conf_max].

    margin_ratio == 1.0 means "exactly on the boundary" -> conf_min.
    margin_ratio >= conf_span means "well past it"      -> conf_max.
    Logarithmic because the boundaries are ratios, so a factor of two past 1.4
    should read the same as a factor of two past 0.7.
    """
    if margin_ratio <= 1.0:
        return cfg.conf_min
    span = math.log(max(cfg.conf_span, 1.0 + 1e-9))
    frac = min(1.0, math.log(margin_ratio) / span)
    return round(cfg.conf_min + frac * (cfg.conf_max - cfg.conf_min), 4)


def classify(
    aspect: float,
    area_frac: float,
    fill_ratio: float,
    n_blobs: int,
    coherence: float | None,
    cfg: Config,
) -> tuple[str, float]:
    """Pick one registered shape class from measured geometry.

    Order matters and is deliberate:
      1. blob_large first — "occupies much of the frame" is a statement about the
         frame, and it outranks the shape of whatever is filling it.
      2. blob_multi next, but ONLY with measured correlated motion.
      3. tall / wide on aspect.
      4. blob_compact for small and near-square.
      5. shape_indeterminate otherwise — an explicit finding, never a default.
    """
    if aspect <= 0 or area_frac <= 0:
        return "shape_indeterminate", cfg.conf_min

    if area_frac >= cfg.large_area_frac:
        return "blob_large", _confidence(area_frac / cfg.large_area_frac, cfg)

    if (
        n_blobs >= cfg.multi_min_blobs
        and coherence is not None
        and coherence >= cfg.multi_min_coherence
    ):
        return "blob_multi", _confidence(coherence / cfg.multi_min_coherence, cfg)

    if aspect >= cfg.aspect_t:
        return "blob_tall", _confidence(aspect / cfg.aspect_t, cfg)
    if aspect <= 1.0 / cfg.aspect_t:
        return "blob_wide", _confidence((1.0 / aspect) / cfg.aspect_t, cfg)

    if area_frac <= cfg.compact_max_area_frac and fill_ratio >= cfg.compact_min_fill:
        # Near-square AND small AND solid. Confidence rises as aspect approaches 1.
        squareness = min(aspect, 1.0 / aspect)  # in (1/aspect_t, 1]
        return "blob_compact", _confidence(squareness * cfg.aspect_t, cfg)

    # Measured, and geometry told us nothing. Confidence here expresses how firmly
    # nothing else applied: right at a boundary it is low, because the honest
    # reading is "this nearly WAS tall".
    dist = min(aspect / (1.0 / cfg.aspect_t), cfg.aspect_t / aspect)
    return "shape_indeterminate", _confidence(dist, cfg)


def _coherence(prev: np.ndarray | None, cur: np.ndarray) -> float | None:
    """How correlated is the motion of this frame's blobs?

    blob_multi is defined by the registry as "several foreground regions with
    CORRELATED motion" — the boar case. Several blobs on their own are not enough,
    so this measures it rather than assuming it.

    Each current blob is matched to its nearest previous centroid and the
    displacement vectors are compared: coherence is the magnitude of the mean unit
    vector, so 1.0 is everything moving the same way and ~0 is scatter. Returns
    None when it cannot be measured, and None never yields blob_multi.
    """
    if prev is None or len(prev) == 0 or len(cur) < 2:
        return None
    vecs = []
    for c in cur:
        d = prev - c
        j = int(np.argmin((d[:, 0] ** 2 + d[:, 1] ** 2)))
        v = c - prev[j]
        n = float(math.hypot(v[0], v[1]))
        if n > 0.5:  # ignore jitter below half a pixel
            vecs.append((v[0] / n, v[1] / n))
    if len(vecs) < 2:
        return None
    arr = np.asarray(vecs, dtype=np.float64)
    return float(min(1.0, math.hypot(*arr.mean(axis=0))))


def _stability(areas: Sequence[float]) -> float | None:
    """Size stability across recent frames, per B4's "size stability".

    1.0 is perfectly steady; falls towards 0 as area jumps about. Needs at least
    three samples to mean anything.
    """
    if len(areas) < 3:
        return None
    a = np.asarray(areas, dtype=np.float64)
    m = float(a.mean())
    if m <= 0:
        return None
    return round(float(max(0.0, 1.0 - (a.std() / m))), 4)


# ---------------------------------------------------------------------------
# the entry point
# ---------------------------------------------------------------------------


def analyse_segment(
    frames: Iterable[Frame],
    meta: SegmentMeta,
    state: AnalyserState,
    cfg: Config | None = None,
    frame_step_s: float | None = None,
) -> tuple[list[Observation], WindowStats]:
    """Turn luma frames into observations. No I/O of any kind.

    `state` carries the background model between calls and MUST be reused across
    consecutive segments of the same camera — see AnalyserState's docstring.

    Returns (observations, stats). An empty observation list is a real result
    meaning "looked, found nothing", which the worker must still submit: cilex-
    vision needs "it was quiet" to be distinguishable from "nobody looked".
    """
    cfg = cfg or state.cfg
    st = WindowStats()

    # STREAM, never materialise. A 5-minute 1280x720 window is ~4,500 frames of
    # ~0.9 MB of luma — about 4 GB resident if this called list(frames), on a box
    # whose whole job is a guard wall. The only buffering is a short prefix used to
    # estimate the frame step, and only when the caller did not supply one.
    it = iter(frames)
    prefix: list[Frame] = []
    if frame_step_s is None:
        # Frame step is MEASURED from timestamps, not derived from metadata:
        # duration_s / frame_count is wrong on the 4-second motion-triggered
        # segments and on any window sampled unevenly.
        for f in it:
            prefix.append(f)
            if len(prefix) >= 16:
                break
        ts = [f.t_offset_s for f in prefix if f.t_offset_s is not None]
        deltas = [b - a for a, b in zip(ts, ts[1:]) if b > a]
        frame_step_s = float(np.median(deltas)) if deltas else None
    st.frame_step_s = frame_step_s

    def _frames() -> Iterator[Frame]:
        for f in prefix:
            yield f
        for f in it:
            yield f

    if state.history_frames is None or state._frame_step_s != frame_step_s:
        state.calibrate(frame_step_s)
    st.history_frames = state.history_frames
    if frame_step_s is None:
        st.notes.append("no usable timestamps; history set by frame count")

    min_area_px_cache: dict[tuple[int, int], float] = {}
    kernel = cv2.getStructuringElement(
        cv2.MORPH_ELLIPSE, (cfg.morph_open_px, cfg.morph_open_px)
    )
    out: list[Observation] = []

    for fr in _frames():
        st.frames_seen += 1
        luma = fr.luma
        if luma is None or luma.ndim != 2 or luma.dtype != np.uint8:
            st.notes.append(f"frame {fr.index}: not a 2-D uint8 luma plane; skipped")
            continue
        h_px, w_px = luma.shape
        if h_px < 16 or w_px < 16:
            st.notes.append(f"frame {fr.index}: {w_px}x{h_px} too small; skipped")
            continue

        shape = (h_px, w_px)
        if state._shape is not None and shape != state._shape:
            st.notes.append(
                f"frame {fr.index}: resolution changed "
                f"{state._shape[1]}x{state._shape[0]} -> {w_px}x{h_px}; model reset"
            )
        if state._ensure(shape, meta.camera_id):
            st.model_resets += 1
        # NB: recorded as (width, height) -- test against the same order, or the
        # dedup silently never matches and this grows one entry per frame.
        if (w_px, h_px) not in st.resolutions:
            st.resolutions.append((w_px, h_px))

        # Dimensions come from the ARRAY, never from meta: meta.width/height are
        # nullable and, being metadata, can disagree with the bytes.
        frame_area = float(w_px * h_px)
        if shape not in min_area_px_cache:
            min_area_px_cache[shape] = max(
                9.0, cfg.min_blob_area_frac * frame_area
            )
        min_area_px = min_area_px_cache[shape]

        mask = state._bs.apply(luma)
        state._warm += 1

        if not state.is_warm:
            st.frames_warmup += 1
            continue

        binary = (mask > 127).astype(np.uint8)
        if cfg.morph_open_px >= 3:
            binary = cv2.morphologyEx(binary, cv2.MORPH_OPEN, kernel)

        n_lab, _, stats, centroids = cv2.connectedComponentsWithStats(binary, 8)
        keep = [
            i for i in range(1, n_lab) if float(stats[i, cv2.CC_STAT_AREA]) >= min_area_px
        ]
        st.frames_scored += 1

        if not keep:
            state._prev_centroids = None
            state._recent_areas.clear()
            continue

        cents = np.asarray([centroids[i] for i in keep], dtype=np.float64)
        coh = _coherence(state._prev_centroids, cents)
        state._prev_centroids = cents

        # The dominant blob carries the bbox. object_count reports how many there
        # were, so a single-bbox observation never implies a single object.
        dom = max(keep, key=lambda i: float(stats[i, cv2.CC_STAT_AREA]))
        x = int(stats[dom, cv2.CC_STAT_LEFT])
        y = int(stats[dom, cv2.CC_STAT_TOP])
        bw = int(stats[dom, cv2.CC_STAT_WIDTH])
        bh = int(stats[dom, cv2.CC_STAT_HEIGHT])
        area = float(stats[dom, cv2.CC_STAT_AREA])

        # w and h must be strictly > 0 after normalisation or the API refuses the
        # row. A 1-px box normalises to a positive but tiny number; clamp so
        # rounding at the far end can never produce a zero.
        if bw <= 0 or bh <= 0:
            continue
        nx = min(max(x / w_px, 0.0), 1.0)
        ny = min(max(y / h_px, 0.0), 1.0)
        nw = min(max(bw / w_px, 1e-6), 1.0 - nx if nx < 1.0 else 1e-6)
        nh = min(max(bh / h_px, 1e-6), 1.0 - ny if ny < 1.0 else 1e-6)
        if nw <= 0 or nh <= 0:
            continue

        aspect = bh / bw
        area_frac = area / frame_area
        fill = area / float(bw * bh)

        state._recent_areas.append(area)
        if len(state._recent_areas) > 12:
            state._recent_areas.pop(0)

        cls, conf = classify(aspect, area_frac, fill, len(keep), coh, cfg)
        out.append(
            Observation(
                segment_id=meta.segment_id,
                frame_index=fr.index,
                t_offset_s=round(float(fr.t_offset_s), 3),
                bbox_x=round(nx, 6),
                bbox_y=round(ny, 6),
                bbox_w=round(nw, 6),
                bbox_h=round(nh, 6),
                object_count=len(keep),
                shape_class=cls,
                shape_confidence=conf,
                aspect=round(aspect, 4),
                area_frac=round(area_frac, 6),
                fill_ratio=round(fill, 4),
                area_stability=_stability(state._recent_areas),
                motion_coherence=None if coh is None else round(coh, 4),
            )
        )

    if st.frames_seen == 0:
        st.notes.append("no frames")
    st.observations = len(out)
    return out, st


def analyse_window(
    stream: Iterable[tuple[SegmentMeta, Iterable[Frame]]],
    state: AnalyserState | None = None,
    cfg: Config | None = None,
) -> Iterator[tuple[SegmentMeta, list[Observation], WindowStats]]:
    """Convenience over consecutive segments of one camera, sharing one model.

    This is the shape a worker wants: it yields per segment, so results can be
    submitted as each hour's segments complete, while the background model keeps
    the continuity it needs across them.
    """
    st = state or AnalyserState(cfg)
    for meta, frames in stream:
        obs, stats = analyse_segment(frames, meta, st, cfg)
        yield meta, obs, stats
