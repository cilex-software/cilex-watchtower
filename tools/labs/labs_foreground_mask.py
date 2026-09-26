"""B3 foreground_mask: background subtraction over a WINDOW of consecutive frames.

One observation per window of four consecutive segments. Each field is one claim:

    object_count   blobs in the PEAK frame: the scored frame with the largest
                   foreground fraction. A per-frame count of connected
                   foreground regions after cleanup, the definition
                   Watchtower's A5 already uses (shape_observations.py,
                   "object_count ... in the frame the bbox came from").
    bbox_x..h      the largest blob of that SAME frame, normalised 0..1. Both
                   typed fields describe one instant on purpose. Absent when no
                   scored frame held any foreground; object_count is then 0:
                   "looked, found none", which is a result.
    metrics        fg_frac_mean / fg_frac_p95 / fg_frac_max: foreground area as a
                   FRACTION of the frame over the scored frames. fg_frame_frac:
                   share of scored frames with any blob. blobs_max /
                   blobs_median. noise_frac: median RAW MOG2 fraction before
                   cleanup, the noise tell. peak_t_s. And how many frames were
                   used and why the others were not.

A BLOB IS NOT AN OBJECT. It is a region of pixels that CHANGED against the last
~100 s: a person, a car, and equally a person's shadow, a door swinging open,
bright specks close to an IR lens, a lawn edge the sun just reached (each of
these seen in the sample masks). On the busy entrance window the frame with the
most blobs under a 3x3 opening alone (9) held two men going through a door, the
door itself swinging open, and fragments of each; adding the 5x5 closing, that
window's per-frame maximum is 4. So object_class, confidence, shape_class and
scene_light are never set here.

SAMPLED INSTANTS, NOT A RECORDING. On the keyframe path the window is looked at
every 3.3-4 s. Anything that crosses the frame between two keyframes is not in
the mask. Measured with the exploration harness (explore.py + compare.py, open
only, unprimed): of the keyframe intervals in which a 15 fps model saw any
blob, the keyframe model saw one at the interval's keyframe in 62% (32 of 52)
on the three daytime main samples and 66% (47 of 71) on their sub streams. The
window STATISTICS hold up, the event count and the peak do not (findings doc,
"keyframes").

FOUR THINGS WERE MEASURED BEFORE THE DESIGN WAS FIXED
(docs/findings/2026-09-26-labs-foreground_mask.md has every table and command):

  * PRIME, DO NOT WARM UP. A fresh MOG2 returns its whole first frame as
    foreground, and then for tens of keyframes flags lighting and foliage it
    has not yet seen vary: against a model running since before the window, a
    cold one added 0.26-0.47% of the frame of extra foreground in keyframes
    2-15 on the busy day camera (main and sub, primetest2.py). Running the
    window once BACKWARDS first (`prime`) cut that to 0.03-0.11% and scores
    every frame, instead of throwing the first half-minute away.
  * FOUR CONSECUTIVE SEGMENTS. Priming on one segment (8 keyframes) teaches
    the model the objects too: averaged over the window it missed 0.52% of
    the frame that the reference saw and counted 0.85 fewer blobs per frame.
    On 3-4 segments (22-30 keyframes) that is 0.11% and within 0.13 blobs.
    Hence Config.min_frames = 12 and plan_windows(run=4).
  * THE NOISE FLOOR IS FAR BELOW THE MODEL'S. framediff's fixed threshold sits
    below the noise on 16% of segments; MOG2 keeps a variance per pixel and
    learns it from the window during priming. At 320 px (area-downscaled, 64
    sensor pixels per mask pixel on main) the per-pixel temporal sigma of 10
    night windows is median 0.67-1.86, p90 1.2-4.0 grey levels; synthetic
    spatially correlated noise yields its first false blob between sigma 9
    and 12 (three draws; pinned by the tests). The
    raw fraction is still reported (noise_frac) so a window nearing that
    ceiling is visible rather than silently noisy.
  * LIGHTS CHANGING IS NOT FOREGROUND. The one real colour-to-IR switch in the
    samples produced no global-change frame and no switch-sized blob on the
    primed keyframe path: the model had seen both states. A frame whose raw
    foreground passes 50% is still excluded and counted
    (global_change_frames), for the switch that lands at a window's edge.

A THING THAT STOPS DISAPPEARS. MOG2 makes a pixel background once it holds a
value for about (1 - backgroundRatio) of its memory; with 100 s of memory a
parked car is absorbed within seconds of stopping, and priming applies that to
the whole window, so something standing still for a fifth of the window is
never foreground at all (pinned by a test). B3 sees what MOVES. Dwell belongs
to track_linking.

THE DECODE SHAPE is labs_framediff's and for the same reasons: software decode
only (no -hwaccel: the shared iGPU wedges on VA-API context creation), ONE
long-lived ffmpeg per window fed an iterable of chunks (MPEG-TS concatenates;
segment joints do not fake motion, register section 1.7), -threads 1,
-skip_frame nokey. Frames are scaled to 320 px IN the decoder and come out as
PGM, which carries its own size, so no resolution is assumed.

USE THE SUB STREAM. The mask is computed at 320 px either way, so main's
resolution is thrown away before MOG2 sees it, while its HEVC decode is the
whole cost. Measured: one real busy sub hour (640x360, 30 windows) cost 11.7
CPU-s and 82.4 MB; a main window costs 1.1-2.9 CPU-s (median of 3 runs, 11
sample windows) and 11-28 MB, and an hour has 30 of them. Window statistics on sub keyframes track main's (findings doc).

THE SHARED EXPORT is iter_masks(). colour_histogram and track_linking build on
it rather than on the window scores:

    for mf in iter_masks(frames):          # frames: luma, BGR, (t_s, array),
        mf.item                            #   or objects with .luma/.t_offset_s;
        mf.mask, mf.labels                 #   item is handed back unchanged
        for b in mf.blobs:                 # largest first
            b.bbox, b.centroid, b.area_frac          # normalised
            b.x, b.y, b.w, b.h, b.cx, b.cy, b.area    # mask pixels
            pixels = mf.labels == b.label
        mf.run, mf.scored, mf.t_s

Masks are at the working size (MaskFrame.width x height); resize with
INTER_NEAREST to pair with a frame of another size. Do not link blobs across a
change of `run`: the model was rebuilt there.
"""
from __future__ import annotations

import logging
import math
import queue
import re
import subprocess
import threading
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Iterable, Iterator, Sequence

import numpy as np
import cv2

logger = logging.getLogger(__name__)

#: The registry slug and this module's behavioural version. Bump VERSION on any
#: change that moves a number: a stored metric whose meaning changed silently is
#: a metric nobody can compare with its own history.
ANALYZER = "foreground_mask"
VERSION = "b3-1"


@dataclass(frozen=True)
class Config:
    """Every constant that decides a pixel's fate, in one place."""

    #: Masks are computed at this width (height follows the aspect ratio, rounded
    #: to even). Fixed so that the blob-area floor and the 3x3 cleanup mean the
    #: same thing on main (2560x1440), sub 1280x720, sub 640x360 and sub 640x480.
    work_width: int = 320
    #: MOG2 memory in SECONDS. MOG2 counts history in FRAMES, and this fleet's
    #: frame step on the keyframe path is 4.0 s on main and 3.3 s or 1.0 s on
    #: sub, so a frame count is a different wall-clock memory per camera. Derived
    #: per window from the measured step. 100 s is the figure the register's
    #: convergence study used (25 keyframes on main) and Watchtower's A4-A6 uses.
    history_s: float = 100.0
    history_frames_min: int = 12
    history_frames_max: int = 2000
    #: MOG2 squared-Mahalanobis threshold (16 = 4 sigma of the per-pixel model).
    var_threshold: float = 16.0
    #: A blob smaller than this fraction of the frame is not reported. Watchtower's
    #: shape_observations Config uses the same 0.0005; at 320x180 it is 28.8 px.
    min_blob_area_frac: float = 0.0005
    #: Opening kernel (px, ellipse) that removes speckle before labelling.
    open_px: int = 3
    #: Closing kernel (px, ellipse) applied after the opening, so one person's
    #: body, legs and attached shadow label as one blob rather than several.
    #: 0 disables it (Watchtower's shape_observations opens only).
    close_px: int = 5
    #: A frame whose RAW foreground exceeds this fraction is a scene-level change
    #: (lights switched, IR cut toggled, camera moved), not objects. It is
    #: excluded from every statistic and counted instead.
    global_change_frac: float = 0.5
    #: A window with fewer usable frames than this returns no scores.
    min_frames: int = 12
    #: A jump in time larger than this between two consecutive frames starts a
    #: new model: two moments that are not adjacent are a scene change, not
    #: motion. Consecutive segments join with +0.02..+0.08 s seams (measured by
    #: labs_fetch), so 30 s means at least one segment is missing.
    max_gap_s: float = 30.0
    #: Stream mode only (prime=False): frames are not scored until the model has
    #: seen this many seconds, and never the first frame.
    warmup_s: float = 30.0
    #: Prime mode buffers at most this many downscaled frames (57.6 KB each at
    #: 320x180, so ~35 MB). A longer input is cut into consecutive runs of this
    #: many frames, each primed on itself (a new `run`).
    prime_max_frames: int = 600
    #: Used when no timestamps and no frame_step_s are supplied: the MEASURED main
    #: keyframe interval (median 3.997 s on all 42 30-second sample main segments).
    default_frame_step_s: float = 4.0
    #: A step shorter than this is a DUPLICATE, not a frame interval. Three
    #: cameras open every -sub segment with two keyframes one 90 kHz tick
    #: (11 us) apart (measured by the Watchtower Windows agent, 2026-09-26), and
    #: taken as a step it clamped MOG2 history to history_frames_max. No camera
    #: here runs faster than 30 fps (33 ms), so 10 ms cannot cut a real one.
    min_frame_step_s: float = 0.01
    #: Stream mode sets MOG2 history from the MEDIAN of a model's first this-many
    #: real steps, not from its second frame alone: an every-Nth selection that
    #: counts the duplicate starts one interval short (2 frames, not 3).
    history_steps: int = 5


DEFAULT = Config()


# ---------------------------------------------------------------------------
# per-frame output: the export colour_histogram and track_linking build on
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Blob:
    """One connected foreground region after cleanup.

    Pixel fields are in MASK coordinates (the working resolution, see
    MaskFrame.width/height). The normalised fields are what the Labs contract
    stores: 0..1 of the frame, w and h strictly > 0.
    """

    label: int              # value of this blob's pixels in MaskFrame.labels
    x: int
    y: int
    w: int
    h: int
    area: int               # foreground pixels in the blob, not bbox area
    cx: float               # centroid, mask pixels
    cy: float
    frame_w: int
    frame_h: int

    @property
    def bbox(self) -> tuple[float, float, float, float]:
        """(x, y, w, h) normalised to 0..1, w and h > 0 by construction."""
        W, H = float(self.frame_w), float(self.frame_h)
        return (self.x / W, self.y / H, self.w / W, self.h / H)

    @property
    def centroid(self) -> tuple[float, float]:
        return (self.cx / self.frame_w, self.cy / self.frame_h)

    @property
    def area_frac(self) -> float:
        return self.area / float(self.frame_w * self.frame_h)


@dataclass(frozen=True)
class MaskFrame:
    """One input frame's foreground, in input order.

    `item` is exactly what the caller passed for this frame, so a consumer that
    fed colour frames (colour_histogram) or frame objects carrying ids gets its
    own data back beside the mask. `luma` is the downscaled plane MOG2 saw.
    """

    index: int
    t_s: float | None
    item: Any
    luma: np.ndarray            # uint8 (height, width), what MOG2 saw
    mask: np.ndarray            # bool (height, width): union of `blobs`
    labels: np.ndarray          # int32 (height, width): 0 background, else Blob.label
    blobs: tuple[Blob, ...]     # largest first
    raw_frac: float             # MOG2 output before cleanup: the noise tell
    fg_frac: float              # area of `blobs` / frame area
    #: False while a stream-mode model is warming up, and for every frame of a
    #: primed run too short to prime on (fewer than config.min_frames frames).
    warm: bool
    global_change: bool         # scene-level change; not objects
    #: Which model produced this frame. It changes only when the model had to be
    #: rebuilt: the frame size changed, time jumped by more than max_gap_s, a
    #: prime-mode run reached prime_max_frames, or a stream-mode global change.
    #: A consumer linking blobs across frames must not link across it.
    run: int = 0
    primed: bool = False        # produced by a model primed on its own run

    @property
    def width(self) -> int:
        return int(self.mask.shape[1])

    @property
    def height(self) -> int:
        return int(self.mask.shape[0])

    @property
    def scored(self) -> bool:
        """Whether window statistics may use this frame."""
        return self.warm and not self.global_change


# ---------------------------------------------------------------------------
# input normalisation
# ---------------------------------------------------------------------------
def _unpack(item: Any) -> tuple[float | None, np.ndarray]:
    """(t_s or None, 2-D uint8 plane) from any accepted frame shape.

    Accepted: a 2-D uint8 array (luma); an (H, W, 3) uint8 BGR array; a
    `(t_s, array)` pair; or an object with `.luma` and optional `.t_offset_s`
    (Watchtower's shape_observations.Frame). Anything else is a caller bug and
    raises rather than being skipped: a frame silently dropped here would read
    downstream as a quiet scene.
    """
    t: Any = None
    img: Any = item
    if isinstance(item, tuple) and len(item) == 2 and isinstance(item[1], np.ndarray):
        t, img = item
    elif hasattr(item, "luma"):
        img = item.luma
        t = getattr(item, "t_offset_s", None)
    if not isinstance(img, np.ndarray):
        raise ValueError(f"frame is {type(img).__name__}, not a numpy array")
    if img.dtype != np.uint8:
        raise ValueError(f"frame dtype is {img.dtype}, expected uint8")
    if img.ndim == 3 and img.shape[2] == 3:
        img = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    elif img.ndim == 3 and img.shape[2] == 1:
        img = img[:, :, 0]
    elif img.ndim != 2:
        raise ValueError(f"frame shape {img.shape} is neither (H, W) nor (H, W, 3)")
    if img.shape[0] < 8 or img.shape[1] < 8:
        raise ValueError(f"frame {img.shape[1]}x{img.shape[0]} is too small to model")
    return (None if t is None else float(t)), img


def working_size(width: int, height: int, work_width: int = DEFAULT.work_width) -> tuple[int, int]:
    """(w, h) the mask is computed at. Never upscales; height stays even."""
    if width <= work_width:
        return int(width), int(height)
    h = int(round(height * work_width / float(width) / 2.0)) * 2
    return int(work_width), max(2, h)


def _downscale(img: np.ndarray, size: tuple[int, int]) -> np.ndarray:
    if img.shape[1] == size[0] and img.shape[0] == size[1]:
        # A copy, because prime mode keeps it until the window is scored and a
        # caller that reuses one buffer per frame would otherwise rewrite it.
        return np.array(img, dtype=np.uint8, order="C", copy=True)
    # INTER_AREA averages every source pixel, which is also the cheapest noise
    # suppression there is: 2560 -> 320 averages 64 sensor pixels per mask pixel.
    return cv2.resize(img, size, interpolation=cv2.INTER_AREA)


def _median_step(ts: Sequence[float | None]) -> float | None:
    vals = [t for t in ts if t is not None]
    d = [b - a for a, b in zip(vals, vals[1:]) if b > a]
    return float(np.median(d)) if d else None


def _check_forward(t: float | None, prev_t: float | None, index: int) -> None:
    """Refuse time that runs backwards.

    The likeliest cause is a caller passing SEGMENT-relative offsets (Watchtower's
    per-segment iter_frames starts every segment at t0=0.0). Accepted silently,
    each joint would read as a step back, the history and gap logic would ignore
    it, and peak_t_s would name an instant in the wrong segment. Offsets must be
    from the WINDOW start: (segment start - window start) + offset in segment.
    """
    if t is not None and prev_t is not None and t < prev_t - 1e-6:
        raise ValueError(f"frame {index}: t_s {t:.3f} is before the previous frame's "
                         f"{prev_t:.3f}; pass offsets from the WINDOW start, not the segment's")


def history_frames(step_s: float | None, config: Config = DEFAULT) -> int:
    """MOG2 history in FRAMES for a wall-clock memory of config.history_s."""
    step = (step_s if step_s and step_s >= config.min_frame_step_s
            else config.default_frame_step_s)
    n = int(round(config.history_s / step))
    return max(config.history_frames_min, min(config.history_frames_max, n))


# ---------------------------------------------------------------------------
# the model
# ---------------------------------------------------------------------------
class _Model:
    """One MOG2 plus the cleanup that turns its output into blobs."""

    def __init__(self, cfg: Config, size: tuple[int, int], step_s: float | None):
        self.cfg = cfg
        self.size = size
        self.history = history_frames(step_s, cfg)
        self.bs = cv2.createBackgroundSubtractorMOG2(
            history=self.history, varThreshold=cfg.var_threshold, detectShadows=False)
        self.kernel = (cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (cfg.open_px, cfg.open_px))
                       if cfg.open_px >= 2 else None)
        self.close_kernel = (cv2.getStructuringElement(cv2.MORPH_ELLIPSE,
                                                       (cfg.close_px, cfg.close_px))
                             if cfg.close_px >= 2 else None)
        w, h = size
        self.min_area = max(9.0, cfg.min_blob_area_frac * w * h)

    def prime(self, lumas: Sequence[np.ndarray]) -> None:
        """Teach the model the window before scoring it: one pass in REVERSE.

        A fresh MOG2 flags its whole first frame, and for the next half-minute
        or so flags lighting and foliage it has not yet seen vary. Running the
        window backwards first gives the model the window's own variability,
        and ends that pass on the frames the scoring pass starts with.
        """
        for luma in reversed(lumas):
            self.bs.apply(luma)

    def apply(self, luma: np.ndarray) -> tuple[float, np.ndarray, np.ndarray, list[Blob]]:
        raw = self.bs.apply(luma)
        fg = (raw > 127).astype(np.uint8)        # detectShadows=False: 0 or 255
        raw_frac = float(np.count_nonzero(fg)) / fg.size
        if self.kernel is not None:
            fg = cv2.morphologyEx(fg, cv2.MORPH_OPEN, self.kernel)
        if self.close_kernel is not None:
            fg = cv2.morphologyEx(fg, cv2.MORPH_CLOSE, self.close_kernel)
        n, labels, stats, cents = cv2.connectedComponentsWithStats(fg, connectivity=8)
        w, h = self.size
        blobs: list[Blob] = []
        keep = np.zeros(n, dtype=bool)
        for i in range(1, n):
            area = int(stats[i, cv2.CC_STAT_AREA])
            if area < self.min_area:
                continue
            keep[i] = True
            blobs.append(Blob(
                label=i, x=int(stats[i, cv2.CC_STAT_LEFT]), y=int(stats[i, cv2.CC_STAT_TOP]),
                w=int(stats[i, cv2.CC_STAT_WIDTH]), h=int(stats[i, cv2.CC_STAT_HEIGHT]),
                area=area, cx=float(cents[i][0]), cy=float(cents[i][1]),
                frame_w=w, frame_h=h))
        mask = keep[labels]
        labels = np.where(mask, labels, 0).astype(np.int32)
        blobs.sort(key=lambda b: (-b.area, b.label))
        return raw_frac, mask, labels, blobs


def _mask_frame(model: _Model, index: int, t: float | None, item: Any, luma: np.ndarray,
                warm: bool, run: int, primed: bool = False) -> MaskFrame:
    raw_frac, mask, labels, blobs = model.apply(luma)
    fg = sum(b.area for b in blobs) / float(luma.size)
    return MaskFrame(index=index, t_s=t, item=item, luma=luma, mask=mask, labels=labels,
                     blobs=tuple(blobs), raw_frac=raw_frac, fg_frac=fg, warm=warm,
                     global_change=raw_frac >= model.cfg.global_change_frac, run=run,
                     primed=primed)


# ---------------------------------------------------------------------------
# iter_masks: THE shared export
# ---------------------------------------------------------------------------
def iter_masks(frames: Iterable[Any], *, config: Config | None = None,
               frame_step_s: float | None = None, prime: bool = True) -> Iterator[MaskFrame]:
    """Yield one MaskFrame per input frame, in input order.

    `frames`: consecutive frames of ONE camera. Each item may be a 2-D uint8
    luma array, an (H, W, 3) uint8 BGR array, a `(t_s, array)` pair, or an
    object with `.luma` and `.t_offset_s` (Watchtower's Frame). Frames wider
    than config.work_width are downscaled (INTER_AREA) before modelling, so
    pass native frames or pre-scaled ones; the mask is at the working size.

    `t_s` should be seconds from a common origin (the window start). Without
    timestamps, pass `frame_step_s`; with neither, the MEASURED main keyframe
    step (config.default_frame_step_s) sets MOG2's history.

    prime=True (default, and what window scoring uses): frames are buffered
    (downscaled; at most config.prime_max_frames per model) so the model can
    see the window once in reverse before scoring it. Every frame is then
    scored, unless its run held fewer than config.min_frames frames to prime
    on, in which case the whole run comes back warm=False.

    prime=False: one streaming pass, nothing buffered. The first frame and
    every frame within config.warmup_s of the model's start come back with
    warm=False, and a global change rebuilds the model (a new `run`).

    Either way a change of frame size, or a jump in time wider than
    config.max_gap_s, starts a new model and a new `run`.
    """
    cfg = config or DEFAULT
    if prime:
        yield from _iter_primed(frames, cfg, frame_step_s)
    else:
        yield from _iter_stream(frames, cfg, frame_step_s)


def _iter_primed(frames: Iterable[Any], cfg: Config,
                 frame_step_s: float | None) -> Iterator[MaskFrame]:
    buf: list[tuple[int, float | None, Any, np.ndarray]] = []
    size: tuple[int, int] | None = None
    run = 0
    last_t: float | None = None       # survives a flush, so a step back at a run edge is caught

    def flush() -> Iterator[MaskFrame]:
        step = frame_step_s or _median_step([b[1] for b in buf])
        model = _Model(cfg, size, step)
        model.prime([b[3] for b in buf])
        # Primed on too few frames the model has learned the objects as well as
        # the scene (measured: one segment, 8 keyframes, missed 0.52% of the
        # frame against a long-running model). Such frames are not scored.
        warm = len(buf) >= cfg.min_frames
        for index, t, item, luma in buf:
            yield _mask_frame(model, index, t, item, luma, warm, run, primed=True)

    for index, item in enumerate(frames):
        t, img = _unpack(item)
        if t is None and frame_step_s:
            t = index * frame_step_s
        wsize = working_size(img.shape[1], img.shape[0], cfg.work_width)
        prev_t = buf[-1][1] if buf else last_t
        _check_forward(t, prev_t, index)
        if t is not None:
            last_t = t
        gap = t is not None and prev_t is not None and (t - prev_t) > cfg.max_gap_s
        if buf and (wsize != size or len(buf) >= cfg.prime_max_frames or gap):
            yield from flush()
            buf = []
            run += 1
        size = wsize
        buf.append((index, t, item, _downscale(img, wsize)))
    if buf:
        yield from flush()


def _iter_stream(frames: Iterable[Any], cfg: Config,
                 frame_step_s: float | None) -> Iterator[MaskFrame]:
    model: _Model | None = None
    run = -1
    since = 0                      # frames applied to the current model
    t_start: float | None = None
    prev_t: float | None = None
    steps: list[float] = []        # the current model's first real frame steps

    def real(step: float | None) -> bool:
        return step is not None and step >= cfg.min_frame_step_s

    for index, item in enumerate(frames):
        t, img = _unpack(item)
        if t is None and frame_step_s:
            t = index * frame_step_s
        _check_forward(t, prev_t, index)
        wsize = working_size(img.shape[1], img.shape[0], cfg.work_width)
        luma = _downscale(img, wsize)
        step = frame_step_s or ((t - prev_t) if (t is not None and prev_t is not None
                                                 and t > prev_t) else None)
        gap = t is not None and prev_t is not None and (t - prev_t) > cfg.max_gap_s
        if gap:
            step = frame_step_s          # a gap is not a frame step
        if model is None or model.size != wsize or gap:
            model, run, since, t_start = _Model(cfg, wsize, step), run + 1, 0, t
            steps = [step] if (not frame_step_s and real(step)) else []
        elif not frame_step_s and real(step) and len(steps) < cfg.history_steps:
            # Set the history in wall-clock terms as soon as a REAL step is
            # known, and refine it to the median of the first few. Not simply
            # the second frame: a keyframe pair made that step 11 us, which
            # clamped history to history_frames_max, about 1.8 h of memory where
            # 100 s was meant (Watchtower Windows, 2026-09-26).
            steps.append(step)
            model.history = history_frames(float(np.median(steps)), cfg)
            model.bs.setHistory(model.history)
        if since == 0:
            warm = False
        elif t is not None and t_start is not None:
            warm = (t - t_start) >= cfg.warmup_s
        else:
            need = math.ceil(cfg.warmup_s / (frame_step_s or cfg.default_frame_step_s))
            warm = since >= need
        mf = _mask_frame(model, index, t, item, luma, warm, run)
        since += 1
        prev_t = t
        yield mf
        if mf.global_change and since > 1:
            # A scene-level change: the model now describes a scene that no
            # longer exists. Rebuild it from this frame; warm-up restarts.
            model = _Model(cfg, wsize, step)
            model.bs.apply(luma)
            run, since, t_start = run + 1, 1, t
            steps = [step] if (not frame_step_s and real(step)) else []


# ---------------------------------------------------------------------------
# window scores: what one Labs observation carries
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class WindowScores:
    """One window's foreground, reduced. Frozen: these are a measurement."""

    #: frames the statistics came from, and why the others were left out
    frames: int
    frames_seen: int
    warmup_frames: int
    global_change_frames: int
    #: foreground area as a FRACTION of the frame (0..1), over scored frames
    fg_frac_mean: float
    fg_frac_p95: float
    fg_frac_max: float
    #: share of scored frames with at least one blob
    fg_frame_frac: float
    #: blobs per scored frame, after cleanup and the area floor
    blobs_max: int
    blobs_median: float
    #: the PEAK frame is the scored frame with the largest foreground fraction
    #: (earliest on a tie). object_count is its blob count; bbox is its largest
    #: blob. Both describe the same instant on purpose. 0 and None when no
    #: scored frame had any foreground: "looked, found none".
    object_count: int
    bbox: tuple[float, float, float, float] | None
    largest_blob_frac: float | None
    peak_t_s: float | None
    #: the largest single blob in ANY scored frame. Equal to largest_blob_frac
    #: when the biggest thing was in the peak frame (10 of 11 sample windows
    #: with foreground); larger when a busier frame of smaller blobs won the peak.
    blob_frac_max: float | None
    #: median RAW MOG2 fraction before cleanup. The noise tell: a window whose
    #: mask is clean only because the opening ate a snowstorm of speckle is
    #: visible here instead of looking identical to a still scene.
    noise_frac: float
    frame_step_s: float | None
    history_frames: int
    mask_w: int
    mask_h: int
    model_resets: int
    primed: bool
    span_s: float | None = None

    def as_metrics(self) -> dict:
        """The `metrics` payload: scalars only, slug keys, well under 24 keys."""
        m: dict[str, Any] = {
            "fg_frac_mean": round(self.fg_frac_mean, 6),
            "fg_frac_p95": round(self.fg_frac_p95, 6),
            "fg_frac_max": round(self.fg_frac_max, 6),
            "fg_frame_frac": round(self.fg_frame_frac, 4),
            "blobs_max": self.blobs_max,
            "blobs_median": round(self.blobs_median, 2),
            "noise_frac": round(self.noise_frac, 6),
            "frames": self.frames,
            "frames_seen": self.frames_seen,
            "global_change_frames": self.global_change_frames,
            "warmup_frames": self.warmup_frames,
            "history_frames": self.history_frames,
            "mask_w": self.mask_w,
            "mask_h": self.mask_h,
            "model_resets": self.model_resets,
            "primed": self.primed,
        }
        # Absent rather than null or zero when not measured: an absent key means
        # nobody computed it, which is exactly the truth.
        if self.largest_blob_frac is not None:
            m["largest_blob_frac"] = round(self.largest_blob_frac, 6)
        if self.blob_frac_max is not None:
            m["blob_frac_max"] = round(self.blob_frac_max, 6)
        if self.peak_t_s is not None:
            m["peak_t_s"] = round(self.peak_t_s, 3)
        if self.frame_step_s is not None:
            m["frame_step_s"] = round(self.frame_step_s, 3)
        if self.span_s is not None:
            m["span_s"] = round(self.span_s, 2)
        return m

    def as_observation(self, start_time: str | datetime, end_time: str | datetime) -> dict:
        """A complete ObservationIn dict for this window.

        start_time/end_time are the window's first segment start and last
        segment end (ISO strings with an offset, or aware datetimes); only the
        worker knows them. Never sets object_class, confidence or shape_class:
        a foreground mask measures pixels that changed, not what they are.
        """
        def _iso(v: str | datetime) -> str:
            if isinstance(v, datetime):
                if v.tzinfo is None:
                    raise ValueError("naive datetime: refusing to guess its zone")
                return v.isoformat()
            return str(v)

        obs: dict[str, Any] = {"start_time": _iso(start_time), "end_time": _iso(end_time),
                               "object_count": int(self.object_count),
                               "metrics": self.as_metrics()}
        if self.bbox is not None:
            x, y, w, h = self.bbox
            obs.update(bbox_x=round(x, 6), bbox_y=round(y, 6),
                       bbox_w=round(max(w, 1e-6), 6), bbox_h=round(max(h, 1e-6), 6))
        return obs


def score_window(mask_frames: Iterable[MaskFrame], *, span_s: float | None = None,
                 config: Config | None = None) -> WindowScores | None:
    """Reduce a window's MaskFrames to one WindowScores. None if too few frames.

    None, not zeros, when fewer than config.min_frames were scorable: "the
    window was too short to model" and "nothing moved" are different facts, and
    a zero would make them indistinguishable once stored.

    Consumes a generator without holding masks: only per-frame scalars and the
    current peak frame's blobs are kept.
    """
    cfg = config or DEFAULT
    fg: list[float] = []
    nb: list[int] = []
    raw: list[float] = []
    ts: list[float | None] = []
    seen = warmup = gchange = 0
    primed = False
    runs: set[int] = set()
    peak: MaskFrame | None = None
    biggest = 0.0
    size = (0, 0)
    for mf in mask_frames:
        seen += 1
        primed = primed or mf.primed
        runs.add(mf.run)
        ts.append(mf.t_s)
        size = (mf.width, mf.height)
        if not mf.warm:
            warmup += 1
            continue
        if mf.global_change:
            gchange += 1
            continue
        fg.append(mf.fg_frac)
        nb.append(len(mf.blobs))
        raw.append(mf.raw_frac)
        if mf.blobs and (peak is None or mf.fg_frac > peak.fg_frac):
            peak = mf
        if mf.blobs:
            biggest = max(biggest, mf.blobs[0].area_frac)
    if not fg or len(fg) < cfg.min_frames:
        return None
    step = _median_step(ts)
    arr = np.asarray(fg, dtype=np.float64)
    top = peak.blobs[0] if peak is not None else None
    return WindowScores(
        frames=len(fg), frames_seen=seen, warmup_frames=warmup,
        global_change_frames=gchange,
        fg_frac_mean=float(arr.mean()), fg_frac_p95=float(np.percentile(arr, 95)),
        fg_frac_max=float(arr.max()),
        fg_frame_frac=float(np.count_nonzero(np.asarray(nb)) / len(nb)),
        blobs_max=int(max(nb)), blobs_median=float(np.median(nb)),
        object_count=len(peak.blobs) if peak is not None else 0,
        bbox=top.bbox if top is not None else None,
        largest_blob_frac=top.area_frac if top is not None else None,
        peak_t_s=peak.t_s if peak is not None else None,
        blob_frac_max=biggest if peak is not None else None,
        noise_frac=float(np.median(raw)),
        frame_step_s=step, history_frames=history_frames(step, cfg),
        mask_w=size[0], mask_h=size[1], model_resets=max(0, len(runs) - 1),
        primed=primed, span_s=span_s,
    )


# ---------------------------------------------------------------------------
# decode: ONE long-lived software decoder per window
# ---------------------------------------------------------------------------
_SHOWINFO_N = re.compile(r"\bn:\s*(\d+)\b")
_SHOWINFO_PTS = re.compile(r"\bpts_time:\s*([-+0-9.eE]+)")


def decode_luma(source: Iterable[bytes] | bytes, *, keyframes_only: bool = True,
                width: int = DEFAULT.work_width, every_nth: int = 1,
                ffmpeg: str = "ffmpeg", timeout_s: float = 300.0
                ) -> Iterator[tuple[float | None, np.ndarray]]:
    """Yield (t_s, luma) for a window of MPEG-TS, from ONE software decoder.

    `source` is raw MPEG-TS bytes or an iterable of chunks (stream each
    segment's bytes in, in order; MPEG-TS concatenates). Nothing is buffered
    beyond one chunk and one frame.

    Scaled to `width` in the decoder (area filter, aspect kept) so full-size
    frames never cross the pipe. Output is PGM, which carries its own size, so
    no resolution is assumed: sub is 640x360, 640x480 or 1280x720 on this
    fleet and main is 2560x1440 or 1920x1080.

    `t_s` comes from showinfo's pts_time, relative to the first frame, and is
    None if it cannot be parsed. Every segment's PTS restarts at 1.4 s
    (measured); ffmpeg re-bases 30 s joints itself, and a residual backwards
    step (4 s motion segments) is folded forward here so t_s never decreases.

    keyframes_only uses `-skip_frame nokey`. every_nth > 1 keeps every Nth
    DECODED frame (all frames are still decoded). No -hwaccel, deliberately:
    the shared iGPU wedges on VA-API context creation (labs_framediff).
    """
    vf = []
    if every_nth > 1:
        vf.append(f"select=not(mod(n\\,{int(every_nth)}))")
    vf += [f"scale={int(width)}:-2:flags=area", "format=gray", "showinfo"]
    cmd = [ffmpeg, "-hide_banner", "-nostats", "-loglevel", "info",
           "-threads", "1", "-filter_threads", "1"]
    if keyframes_only:
        cmd += ["-skip_frame", "nokey"]
    cmd += ["-fflags", "+discardcorrupt", "-i", "pipe:0", "-map", "0:v:0",
            "-an", "-sn", "-dn", "-fps_mode", "passthrough", "-vf", ",".join(vf),
            "-c:v", "pgm", "-f", "image2pipe", "pipe:1"]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    pts_q: "queue.Queue[float | None]" = queue.Queue()
    errors: list[str] = []
    feed_errors: list[BaseException] = []

    def _feed() -> None:
        chunks = [source] if isinstance(source, (bytes, bytearray, memoryview)) else source
        try:
            for chunk in chunks:
                try:
                    proc.stdin.write(chunk)
                except (BrokenPipeError, OSError):
                    return      # the decoder exited; the stdout loop reports it
        except BaseException as e:      # the SOURCE failed: a fetch died mid-window
            feed_errors.append(e)
        finally:
            try:
                proc.stdin.close()
            except OSError:
                pass

    def _drain() -> None:
        # Drained on its own thread: -loglevel info writes one showinfo line per
        # frame, and a full stderr pipe would stall ffmpeg and deadlock stdout.
        for raw_line in iter(proc.stderr.readline, b""):
            line = raw_line.decode("utf-8", "replace")
            if "showinfo" in line and _SHOWINFO_N.search(line):
                m = _SHOWINFO_PTS.search(line)
                try:
                    pts_q.put(float(m.group(1)) if m else None)
                except ValueError:
                    pts_q.put(None)
            elif "rror" in line:
                errors.append(line.strip())
                del errors[:-20]

    feeder = threading.Thread(target=_feed, daemon=True)
    drainer = threading.Thread(target=_drain, daemon=True)
    feeder.start()
    drainer.start()
    produced = 0
    timing = True
    pts0: float | None = None
    offset = 0.0
    last_t: float | None = None
    last_step: float | None = None
    try:
        while True:
            head = [proc.stdout.readline() for _ in range(3)]   # P5 / W H / maxval
            if not head[0]:
                break
            if head[0].strip() != b"P5":
                raise RuntimeError(f"unexpected decoder output {head[0][:16]!r}")
            w, h = (int(v) for v in head[1].split())
            buf = proc.stdout.read(w * h)
            if len(buf) < w * h:
                break
            t: float | None = None
            if timing:
                try:
                    pts = pts_q.get(timeout=10.0)
                except queue.Empty:
                    pts, timing = None, False
                if pts is not None:
                    if pts0 is None:
                        pts0 = pts
                    t = pts - pts0 + offset
                    if last_t is not None and t < last_t:
                        step = last_step or DEFAULT.default_frame_step_s
                        offset += (last_t - t) + step
                        t = last_t + step
                    if last_t is not None and t > last_t:
                        last_step = t - last_t
                    last_t = t
            produced += 1
            yield t, np.frombuffer(buf, dtype=np.uint8).reshape(h, w)
    finally:
        try:
            proc.stdout.close()
        except OSError:
            pass
        feeder.join(timeout=1.0)
        try:
            proc.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        drainer.join(timeout=1.0)
        try:
            proc.stderr.close()
        except OSError:
            pass
    if feed_errors:
        # A window cut short by its source must not be scored as if complete:
        # the frames it did yield would read as a shorter, quieter window.
        raise RuntimeError("the window's source failed mid-stream") from feed_errors[0]
    if produced == 0 and proc.returncode not in (0, None):
        # A decoder that failed must not read as an empty, quiet window.
        raise RuntimeError(f"decoder exited {proc.returncode} with no frames: "
                           + " | ".join(errors[-3:])[:400])
    if errors:
        logger.debug("ffmpeg: %s", " | ".join(errors[-5:])[:500])


def analyse(source: Iterable[bytes] | bytes, *, span_s: float | None = None,
            keyframes_only: bool = True, every_nth: int = 1, prime: bool = True,
            config: Config | None = None, ffmpeg: str = "ffmpeg",
            timeout_s: float = 300.0) -> WindowScores | None:
    """Decode one window of consecutive segments and score it. The whole analyser.

    `source`: the window's MPEG-TS, streamed as chunks, segments in order.
    `span_s`: the sum of the segments' duration_s (recorded in the metrics).
    """
    cfg = config or DEFAULT
    frames = decode_luma(source, keyframes_only=keyframes_only, width=cfg.work_width,
                         every_nth=every_nth, ffmpeg=ffmpeg, timeout_s=timeout_s)
    return score_window(iter_masks(frames, config=cfg, prime=prime), span_s=span_s,
                        config=cfg)


# ---------------------------------------------------------------------------
# which segments make a window
# ---------------------------------------------------------------------------
def _when(seg: Any, key: str) -> datetime | None:
    v = seg.get(key) if isinstance(seg, dict) else getattr(seg, key, None)
    if v is None or isinstance(v, datetime):
        return v
    t = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    if t.tzinfo is None:
        raise ValueError(f"{key} has no offset: {v!r}")
    return t


def consecutive_runs(segments: Sequence[Any], *, max_gap_s: float = 1.5) -> list[list[Any]]:
    """Split time-ordered segments into maximal runs with no joint wider than max_gap_s.

    1.5 s is labs_fetch's threshold; measured seams between consecutive 30 s
    segments are +0.02..+0.08 s. A window must never span a gap: the model would
    compare two moments that are not adjacent, which is a scene change.
    Segments without a start_time are dropped.
    """
    runs: list[list[Any]] = []
    prev_end: datetime | None = None
    for seg in sorted((s for s in segments if _when(s, "start_time") is not None),
                      key=lambda s: _when(s, "start_time")):
        st, en = _when(seg, "start_time"), _when(seg, "end_time")
        if runs and prev_end is not None and (st - prev_end).total_seconds() <= max_gap_s:
            runs[-1].append(seg)
        else:
            runs.append([seg])
        prev_end = en
    return runs


def plan_windows(segments: Sequence[Any], *, run: int = 4, count: int | None = None,
                 max_gap_s: float = 1.5) -> list[list[Any]]:
    """Windows of exactly `run` consecutive segments.

    count=None: every non-overlapping window, in time order (for a worker that
    already holds the segments). count=N: N of those windows spread evenly over
    the listing (for choosing what to FETCH out of an hour's listing).
    """
    wins: list[list[Any]] = []
    for r in consecutive_runs(segments, max_gap_s=max_gap_s):
        for i in range(0, len(r) - run + 1, run):
            wins.append(r[i:i + run])
    if count is None or count >= len(wins):
        return wins
    if count <= 0:
        return []
    picks = np.linspace(0, len(wins) - 1, count)
    return [wins[int(round(p))] for p in picks]
