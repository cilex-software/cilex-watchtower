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
from dataclasses import dataclass, field, asdict, replace
from datetime import datetime
from typing import Iterable, Iterator, Sequence

import numpy as np
import cv2

# One version string per behavioural change. It names the object_count reading on
# purpose: a stored number whose semantics are only in a letter is a number whose
# semantics are lost. 1.1.0 (2026-09-27): a recurring source is folded -- see
# Config's "recurring sources" and _Recurrence -- with its parameters in the string.
# 1.2.0 (2026-09-29): one row per PASSAGE, and a row budget per unit -- see Config's
# "passages" and "row budget", _Passages and _within_budget.
ANALYSER_VERSION = ("wt-shape-1.2.0+objcount=per_frame+recur=r0.05k3m600a2s60"
                    "+pass=g2.5d3n0.06k1.5s240+budget=450")

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

    # --- recurring sources (1.1.0, 2026-09-27) --------------------------------
    # UNLIKE EVERYTHING ABOVE, THESE WERE FITTED TO DATA -- to ONE camera-hour, so
    # they are provisional until re-checked on a second camera. The first live unit
    # (hiwatch-083bc1df39d1, 2026-09-26 22:00Z) filed 312 rows, and the Linux box
    # measured 182 of its 196 shape_indeterminate rows sitting on ONE out-of-focus
    # streak near the lens, lit by a street lamp: box centres sd x 0.008, y 0.020,
    # detected intermittently (gaps median 11.0 s, p75 25.5 s). A size or fill floor
    # is the wrong fix: on the booth's own footage 2 of 2 small hollow rows were two
    # distant PEOPLE. Recurrence at one spot is what separates the two.
    # And it is a correctness issue, not only a flood: a unit over 500 rows is
    # refused whole (worker MAX_OBSERVATIONS_PER_UNIT), so one lens artefact on a
    # GOP-15 camera (~3,600 keyframes an hour) could lose the camera-hour.
    recur_radius: float = 0.05      # same spot: box centres within this, frame fractions
    recur_area_ratio: float = 2.0   # ...and areas within this factor of each other
    recur_min_prior: int = 3        # K: prior detections at the spot that make it recurring
    recur_window_s: float = 600.0   # M: the look-back, and the most one row folds
    # ...and those prior detections must reach back at least this far. Without it,
    # the booth's 720p GOP-15 capture folded TWO PEOPLE walking slowly along a path:
    # keyframes 1 s apart caught them 4 times within 64 px, which is "K hits at one
    # spot" but is a passer-by, not a source. Seen, not inferred: the crop was
    # checked. A spot is recurring only once it has kept firing for a minute.
    recur_min_span_s: float = 60.0

    # --- passages (1.2.0, 2026-09-29) -------------------------------------------------
    # One row per PASSAGE: consecutive keyframe detections of one moving blob become
    # ONE row with its span, instead of a row per keyframe. Why, both measured:
    #   * the operator opened a "Wide" finding, 5 Улица 7 2026-09-29 15:57:58, read
    #     "car, truck, bus", and found a crow. It had filed 19 rows in 19 s, one per
    #     1 s keyframe, relabelled compact / wide / tall / indeterminate / multi as its
    #     outline changed, each 0.05-0.08 % of the picture (labs_observations, and the
    #     frames with the boxes drawn on them);
    #   * busy hours passed the server's 500-row cap and were lost WHOLE:
    #     hiwatch-083bc17adca6 12:00Z, 525 then 530 rows, failed twice (the Windows
    #     agent; cilex-vision's letter of the same day).
    # Linked: at most passage_gap_steps frame steps apart (the step is MEASURED per
    # segment; passage_gap_default_s when it is not), and the next box centre within
    # passage_near_min or passage_near_k times the larger box side, whichever is more,
    # for each second between them. A passage longer than passage_max_span_s files as
    # consecutive rows: a row longer than 300 s can never join an event group (worker
    # GROUP_MAX_SPAN_S). A recurring SOURCE is still folded first (above); only what the
    # fold files as its own detections is linked here.
    passage_gap_steps: float = 2.5
    passage_gap_default_s: float = 3.0
    passage_near_min: float = 0.06
    passage_near_k: float = 1.5
    passage_max_span_s: float = 240.0
    # --- row budget (1.2.0) ------------------------------------------------------------
    # However busy the hour, a unit files at most this many rows: the server refuses a
    # unit over 500 (the worker's MAX_OBSERVATIONS_PER_UNIT) and the hour is lost whole.
    # Past it, rows merge per shape class per time bin -- 60 s first, coarser until they
    # fit -- each merged row counting what it stands for (recur_count, rows_merged).
    row_budget: int = 450
    budget_bins_s: tuple = (60.0, 120.0, 300.0, 600.0, 1200.0, 3600.0)


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
    # Seconds from the start of the window, NON-DECREASING. Three cameras open every
    # segment with two key packets one PTS tick (11 us) apart; frame_source keeps
    # both, each at its own time, and an identical-PTS pair would share one.
    t_offset_s: float
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
    # OPT-IN, default None. The U and V PLANES themselves, each (h/2, w/2) uint8,
    # for colour_histogram (B7, cilex-vision f7ecd57), which needs per-pixel chroma
    # under a motion mask and cannot work from B1's single scalar. Requested with
    # frame_source's `want_planes`, separate from `want_chroma` on purpose: B1 keeps
    # paying for one float per frame rather than for two retained planes it never
    # reads. In the SOURCE's colour range, never converted — see frame_source.
    u: np.ndarray | None = None
    v: np.ndarray | None = None


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

    # Recurrence, set by analyse_window on every row it files (None when it could
    # not place the row on a clock). See _Recurrence for the exact meanings:
    #   recur_hits     detections at this spot in the window BEFORE this row's hit
    #   recur_count    detections this row stands for: 1, or a folded source's tally
    #   recur_window_s the look-back / fold window M, in seconds
    #   recur_folded   True when this row stands for a recurring source's detections
    recur_hits: int | None = None
    recur_count: int | None = None
    recur_window_s: float | None = None
    recur_folded: bool | None = None

    # A PASSAGE (1.2.0): set on a row that stands for consecutive detections of one blob.
    # The row is timed at the FIRST detection (segment_id, frame_index, t_offset_s) and
    # lasts span_s; the bbox and the measurements beside it are those of the LARGEST
    # detection, bbox_at_s after the start; path_* are the box centres at the first and
    # last detection; shape_votes the classes its keyframes were given, most first. Its
    # shape_class is the most frequent of them. recur_count counts its detections.
    span_s: float | None = None
    bbox_at_s: float | None = None
    path_x0: float | None = None
    path_y0: float | None = None
    path_x1: float | None = None
    path_y1: float | None = None
    shape_votes: str | None = None
    # Set on a row that merges several rows because the unit reached row_budget (1.2.0).
    coarse_bin_s: float | None = None
    rows_merged: int | None = None

    # Which of the fields above ObservationIn actually has a column for. The rest
    # are MEASUREMENTS and belong in the `metrics` jsonb, not at the top level.
    # Stated here so a submitter does not have to rediscover it by reading the
    # server's schema — the Linux worker had to write that discovery out as a
    # comment in plugins.py, which is a sign it belonged next to the data.
    API_COLUMNS = frozenset({
        "bbox_x", "bbox_y", "bbox_w", "bbox_h",
        "object_count", "shape_class", "shape_confidence",
    })

    def measurements(self) -> dict:
        """Every set field as a plain dict, Nones dropped.

        NOT A WIRE PAYLOAD, despite what this used to be called. It is missing
        `start_time` and `end_time`, which ObservationIn REQUIRES and which only the
        caller can supply (they are the segment's start plus `t_offset_s`; this
        module reads a segment's start_time only to put a unit's detections on one
        clock for recurrence, never to time a row). It also
        carries `segment_id`, `frame_index`, `t_offset_s`, `aspect`, `area_frac`,
        `fill_ratio`, `area_stability` and `motion_coherence`, none of which are
        columns — see API_COLUMNS.

        Submitting this dict as-is was SILENT DATA LOSS against cilex-vision 1.0.57:
        ObservationIn set no `extra` policy, so Pydantic's default dropped the
        unknown keys without error and five shape measurements vanished on arrival.
        From 1.0.58 (bf2ad7f) both ObservationIn and ResultsIn are extra="forbid",
        so the same dict 422s instead — louder, and better, but only louder.

        Note those 422s are FastAPI validation errors, not CodedErrors: no `code`,
        no `retryable`. Anything branching on `retryable` will find it absent.

        The mapping — anchor the timestamps, split on API_COLUMNS, put the rest in
        `metrics` — lives in the worker (tools/labs/plugins.py), which is the half
        that is allowed to know Labs exists.
        """
        d = asdict(self)
        return {k: v for k, v in d.items() if v is not None}

    #: Deprecated name. Kept because the Linux worker calls it and renaming across
    #: boxes mid-flight is how two agents break one file. New callers: use
    #: measurements(), whose name does not claim to be something it is not.
    as_payload = measurements


@dataclass
class WindowStats:
    """What happened, for the worker to log and for cost accounting."""

    frames_seen: int = 0
    frames_scored: int = 0
    frames_warmup: int = 0
    observations: int = 0          # rows FILED with this segment (after folding)
    folded: int = 0                # detections here that another row stands for
    budget_bin_s: float | None = None  # the bin rows were merged into to stay in budget (1.2.0)
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


def _epoch(s: str | None) -> float | None:
    """A segment's ISO start_time as seconds, or None. Only ever DIFFERENCED, so a
    naive timestamp (read as local time) is as good as an aware one within a unit."""
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


@dataclass
class _Bucket:
    first: Observation      # the first hit: its row carries this hit's own segment and time
    t0: float               # that hit, on the unit's clock
    cx: float
    cy: float
    area: float
    prior: int              # detections at the spot in the window before the first hit
    n: int = 1              # detections this bucket stands for, the first included


class _Recurrence:
    """Fold a RECURRING SOURCE into at most one row per fold window. One per UNIT.

    A detection is at the SAME SPOT as another when their box centres are within
    recur_radius (frame fractions) and their areas within recur_area_ratio. Then:

      * recur_hits = detections at this spot in the recur_window_s BEFORE this one.
      * Fewer than recur_min_prior (K), or K or more that do not yet reach back
        recur_min_span_s: the detection is FILED as its own row, with recur_count 1
        and recur_folded False. So a new source's first minute -- and anything that
        moves, or merely lingers, as the two slow walkers on the booth's capture did
        -- always files with exact timing (cilex-vision's first condition).
      * K or more reaching back a minute: the spot is a recurring source. The
        detection opens a bucket (or
        joins the open one at this spot), and the bucket files ONE row: the FIRST
        hit's own row, carrying recur_count = every detection it stands for,
        recur_folded True. A bucket closes when a detection arrives recur_window_s
        or more after its first hit, or at the end of the unit.

    EXACT ACCOUNTING: every detection is either its own row or counted in exactly one
    bucket, so the recur_count of a unit's rows sums to its detections.
    PER UNIT, NOTHING CARRIED (the Linux box's first condition): the worker keeps a
    camera's state across units, claims newest-first, and would otherwise carry an
    open fold backwards in time; every row must also start inside its unit's hour.
    DETERMINISTIC: lists in arrival order, no wall clock, no set iteration.
    Bounded PER SOURCE -- its first minute's detections, then one row per window,
    plus one -- not in the number of sources.
    """

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._hist: list[tuple[float, float, float, float]] = []  # (t, cx, cy, area)
        self._open: list[_Bucket] = []
        self.folded = 0

    def _same_spot(self, cx: float, cy: float, a: float,
                   cx2: float, cy2: float, a2: float) -> bool:
        c = self.cfg
        if (cx - cx2) ** 2 + (cy - cy2) ** 2 > c.recur_radius ** 2:
            return False
        lo, hi = (a, a2) if a <= a2 else (a2, a)
        return lo > 0 and hi / lo <= c.recur_area_ratio

    def _close(self, b: _Bucket) -> Observation:
        return replace(b.first, recur_hits=b.prior, recur_count=b.n,
                       recur_window_s=self.cfg.recur_window_s, recur_folded=True)

    def offer(self, ob: Observation, t: float) -> list[Observation]:
        """The rows to file because of this detection: none, itself, or a bucket it closed."""
        c = self.cfg
        m = c.recur_window_s
        cx, cy, a = ob.bbox_x + ob.bbox_w / 2.0, ob.bbox_y + ob.bbox_h / 2.0, ob.area_frac
        self._hist = [h for h in self._hist if 0.0 <= t - h[0] < m]
        hits = [h[0] for h in self._hist if self._same_spot(cx, cy, a, h[1], h[2], h[3])]
        prior = len(hits)
        recurring = prior >= c.recur_min_prior and t - min(hits) >= c.recur_min_span_s
        self._hist.append((t, cx, cy, a))
        out: list[Observation] = []
        b = next((b for b in self._open if self._same_spot(cx, cy, a, b.cx, b.cy, b.area)), None)
        if b is not None:
            if t - b.t0 < m:
                b.n += 1
                self.folded += 1
                return out
            self._open.remove(b)
            out.append(self._close(b))
        if recurring:
            self._open.append(_Bucket(ob, t, cx, cy, a, prior))
        else:
            out.append(replace(ob, recur_hits=prior, recur_count=1, recur_window_s=m,
                               recur_folded=False))
        return out

    def close_all(self) -> list[Observation]:
        out = [self._close(b) for b in self._open]
        self._open = []
        return out


def _centre(ob: Observation) -> tuple[float, float]:
    return ob.bbox_x + ob.bbox_w / 2.0, ob.bbox_y + ob.bbox_h / 2.0


def _votes(members: Sequence[Observation]) -> list[tuple[str, int]]:
    """Each class's detections, most first; ties in the registry's own order. A member
    that is itself a passage brings its own votes (a merged row, at the budget)."""
    n: dict[str, int] = {}
    for ob in members:
        if ob.shape_votes:
            for part in ob.shape_votes.split(","):
                c, _, k = part.partition(":")
                n[c] = n.get(c, 0) + int(k or 0)
        else:
            n[ob.shape_class] = n.get(ob.shape_class, 0) + (ob.recur_count or 1)
    order = {c: i for i, c in enumerate(SHAPE_CLASSES)}
    return sorted(n.items(), key=lambda kv: (-kv[1], order.get(kv[0], len(order))))


def _merge(members: Sequence[Observation], times: Sequence[float], cfg: Config,
           shape_class: str | None = None, **extra) -> Observation:
    """ONE row for several: timed at the first, measured at the largest, counting all."""
    if len(members) == 1 and not extra:
        return members[0]
    first = members[0]
    ends = [t + (ob.span_s or 0.0) for ob, t in zip(members, times)]
    i_big = max(range(len(members)), key=lambda i: (members[i].area_frac, -i))
    big = members[i_big]
    votes = _votes(members)
    cls = shape_class or votes[0][0]
    confs = [ob.shape_confidence for ob in members if ob.shape_class == cls] or [big.shape_confidence]
    x0, y0 = (first.path_x0, first.path_y0) if first.path_x0 is not None else _centre(first)
    i_last = max(range(len(members)), key=lambda i: (ends[i], i))
    last = members[i_last]
    x1, y1 = (last.path_x1, last.path_y1) if last.path_x1 is not None else _centre(last)
    areas = [ob.area_frac for ob in members]
    return replace(
        big,
        segment_id=first.segment_id, frame_index=first.frame_index, t_offset_s=first.t_offset_s,
        object_count=max(ob.object_count for ob in members),
        shape_class=cls, shape_confidence=round(sum(confs) / len(confs), 4),
        area_stability=_stability(areas) if len(members) >= 3 else big.area_stability,
        recur_hits=first.recur_hits,
        recur_count=sum(ob.recur_count or 1 for ob in members),
        recur_window_s=first.recur_window_s,
        recur_folded=first.recur_folded,
        span_s=round(min(max(ends) - times[0], cfg.passage_max_span_s), 3),
        bbox_at_s=round(times[i_big] - times[0], 3),
        path_x0=round(x0, 4), path_y0=round(y0, 4), path_x1=round(x1, 4), path_y1=round(y1, 4),
        shape_votes=",".join(f"{c}:{k}" for c, k in votes),
        **extra,
    )


@dataclass
class _Passage:
    members: list
    times: list


class _Passages:
    """Link consecutive detections of one moving blob into ONE row (1.2.0). One per UNIT.

    A detection continues the open passage whose last detection is nearest, if that one
    is at most the gap back (passage_gap_steps frame steps) and its box centre within
    `near` for each second between them; otherwise it opens a passage. Several may be
    open at once: a keyframe carries only its DOMINANT blob, so two things in view take
    turns being filed. A passage closes when nothing continues it within the gap, when
    it would pass passage_max_span_s, or at the end of the unit.

    EXACT ACCOUNTING, as the fold's: every detection is in exactly one row, and a row's
    recur_count counts them. DETERMINISTIC: lists in arrival order, no wall clock."""

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.step: float | None = None
        self._open: list[_Passage] = []

    def gap_s(self) -> float:
        c = self.cfg
        return c.passage_gap_steps * self.step if self.step else c.passage_gap_default_s

    def _near(self, a: Observation, b: Observation, dt: float) -> float:
        c = self.cfg
        side = max(a.bbox_w, a.bbox_h, b.bbox_w, b.bbox_h)
        return max(c.passage_near_min, c.passage_near_k * side) * max(1.0, dt)

    def _close(self, p: _Passage) -> tuple[Observation, float]:
        return _merge(p.members, p.times, self.cfg), p.times[0]

    def offer(self, ob: Observation, t: float) -> list[tuple[Observation, float]]:
        out: list[tuple[Observation, float]] = []
        gap = self.gap_s()
        still = []
        for p in self._open:
            (still if t - p.times[-1] <= gap else out).append(p)
        out = [self._close(p) for p in out]
        self._open = still
        cx, cy = _centre(ob)
        best, best_d = None, None
        for p in self._open:
            last = p.members[-1]
            dt = t - p.times[-1]
            lx, ly = _centre(last)
            d = math.hypot(cx - lx, cy - ly)
            if d <= self._near(last, ob, dt) and (best_d is None or d < best_d):
                best, best_d = p, d
        if best is not None and t - best.times[0] <= self.cfg.passage_max_span_s:
            best.members.append(ob)
            best.times.append(t)
            return out
        if best is not None:
            self._open.remove(best)
            out.append(self._close(best))
        self._open.append(_Passage([ob], [t]))
        return out

    def close_all(self) -> list[tuple[Observation, float]]:
        out = [self._close(p) for p in self._open]
        self._open = []
        return out


def _within_budget(rows: list[tuple[Observation, float | None]], cfg: Config
                   ) -> tuple[list[Observation], float | None]:
    """At most cfg.row_budget rows, however busy the hour (1.2.0).

    Over it, rows merge per (time bin, folded or not, shape class): 60 s bins first,
    coarser until they fit. The largest bin, an hour, leaves at most 2 x 6 rows, so the
    budget always holds. A folded source is never merged with passages: the findings
    rule counts the one and not the other. Rows with no clock merge per class."""
    if len(rows) <= cfg.row_budget:
        return [r for r, _ in rows], None
    for b in cfg.budget_bins_s:
        groups: dict = {}
        for ob, t in rows:
            key = (None if t is None else math.floor(t / b), bool(ob.recur_folded), ob.shape_class)
            groups.setdefault(key, []).append((ob, t))
        if len(groups) <= cfg.row_budget or b == cfg.budget_bins_s[-1]:
            out = []
            for key, grp in groups.items():
                grp.sort(key=lambda r: (r[1] if r[1] is not None else 0.0))
                obs = [ob for ob, _ in grp]
                ts = [t if t is not None else 0.0 for _, t in grp]
                out.append(_merge(obs, ts, cfg, shape_class=key[2],
                                  coarse_bin_s=b, rows_merged=len(obs)))
            return out, b
    return [r for r, _ in rows], None          # unreachable: the last bin always returns


def analyse_window(
    stream: Iterable[tuple[SegmentMeta, Iterable[Frame]]],
    state: AnalyserState | None = None,
    cfg: Config | None = None,
) -> Iterator[tuple[SegmentMeta, list[Observation], WindowStats]]:
    """Consecutive segments of one camera -- ONE UNIT -- through one model.

    Yields exactly once per segment, in order, as the worker's adapter expects. The
    background model is the caller's `state` and carries on; recurrence (see
    _Recurrence) and passages (see _Passages) are per call, so they never outlive the
    unit.

    EVERY ROW RIDES THE LAST YIELD (1.2.0). A passage can run across segments, and the
    row budget can only be kept once the whole unit is known, so the rows are held
    until the unit ends -- rows, never frames: a few hundred small records at most.
    Each row names its own segment_id and t_offset_s (its first detection's), and the
    adapter times it by its own segment. Rows are placed on the clock of each segment's
    start_time; a segment without one is filed unfolded and unlinked, its recurrence
    fields left unset.
    """
    st = state or AnalyserState(cfg)
    c = cfg or st.cfg
    rec = _Recurrence(c)
    pas = _Passages(c)
    base_of: dict[str, float] = {}
    done: list[tuple[Observation, float | None]] = []

    def when(r: Observation) -> float | None:
        b = base_of.get(r.segment_id)
        return None if b is None else b + r.t_offset_s

    held: tuple[SegmentMeta, WindowStats] | None = None
    for meta, frames in stream:
        obs, stats = analyse_segment(frames, meta, st, cfg)
        if stats.frame_step_s:
            pas.step = stats.frame_step_s
        base = _epoch(meta.start_time)
        if base is None:
            if obs:
                stats.notes.append("no start_time: recurrence not measured, rows filed unfolded")
            done.extend((ob, None) for ob in obs)
        else:
            base_of[meta.segment_id] = base
            before = rec.folded
            for ob in obs:
                for r in rec.offer(ob, base + ob.t_offset_s):
                    t = when(r)
                    if r.recur_folded or t is None:
                        done.append((r, t))
                    else:
                        done.extend(pas.offer(r, t))
            stats.folded = rec.folded - before
        stats.observations = 0
        if held is not None:
            yield held[0], [], held[1]
        held = (meta, stats)
    if held is None:
        return
    for r in rec.close_all():
        done.append((r, when(r)))
    done.extend(pas.close_all())
    rows, bin_s = _within_budget(done, c)
    meta, stats = held
    stats.observations = len(rows)
    if bin_s is not None:
        stats.budget_bin_s = bin_s
        stats.notes.append(f"row budget: {len(done)} rows > {c.row_budget}; merged per {int(bin_s)} s "
                           f"and shape class into {len(rows)}")
    yield meta, rows, stats
