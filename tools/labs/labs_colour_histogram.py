"""B7 colour_histogram: the dominant colour of what MOVED in a window, or an honest refusal.

One observation per window of four consecutive segments (the same windows as B3
foreground_mask, whose masks this module uses; it does not re-implement them).
Every claim lives in `metrics`, because ObservationIn has no colour column:

    colour           the canonical colour (ColorValue in services/db/models.py,
                     docs/taxonomy.md section 2.1) holding the largest share of
                     the window's moving pixels. "unknown" when no named colour
                     reaches MIN_SHARE (0.30, the taxonomy's own fallback rule).
                     ABSENT when the window is gated: absent means "not
                     computed", which taxonomy section 2.3 distinguishes from
                     "unknown".
    colour_share     that colour's share of the counted moving pixels (0..1).
    runner_up(_share) the second named colour and its share.
    chroma_mean      mean chroma of the counted moving pixels, sqrt(Cb'^2 + Cr'^2)
                     in full-range 8-bit units (0 is grey; ~181 is the maximum).
    gate             why no colour was given: "ir", "no_motion",
                     "region_too_small" or "light_cast". Absent when a colour
                     was given.
    plus the evidence for the gates (scene_chroma, bg_chroma, ir_frames,
    region_px) and the model parameters, so a stored row can be re-judged.

A COLOUR HERE IS THE COLOUR OF CHANGED PIXELS, not of an object. The region is
B3's foreground (people, cars, and also doors, lawn edges the sun reached,
background pulled in by the closing), then:

  * ERODED by one pixel (3x3), because the boundary ring at 320 px mixes the
    object with what is behind it.
  * minus ILLUMINATION CHANGE: a moving pixel whose chroma is within
    `illum_chroma_max` of the window's median background at that pixel, and whose
    luma is 0.35..1.25x the background's, is a shadow or a highlight on the
    background, not a thing. MEASURED on the busy day hour (f007 sub, the 20
    windows with more than 1,000 counted pixels): 22-52% of the eroded moving
    pixels are removed; a black car's shadow on the paving was most of its blob
    (viewed). THE COST: an object with the same chroma as what is behind it and
    a similar brightness (grey trousers on grey paving, viewed) is removed too.

Pixels are named (`classify`): darker than `black_y`, or grey and darker than
`grey_black_y`, is black; chroma below `achromatic_c` is white or silver by luma
(grey has no ColorValue, so grey is silver); otherwise the HSV hue picks red,
orange, yellow, green or blue, and warm hues that are dark or unsaturated are
brown. Purple and magenta hues (255-335 degrees) have no canonical name and
count as "other": they dilute the named shares rather than being forced into
one. The thresholds were set before the spot checks and NOT tuned on them
(lowering the black thresholds was tried and did not help; findings doc).

WHAT IT GETS RIGHT AND WRONG, MEASURED by viewing 13 windows of the day hour:
the dominant colour matched my reading of the main mover(s) in 8 of 13, and my
colour was the dominant or the runner-up in 13 of 13. Every miss read "black":
a pixel histogram pools everything that moved, so tyres, dark trousers, the
dark underside of a white truck and a dark glass door swinging outvote a blue
jacket or a grey car. Read colour_share and runner_up together.

GATES. A guessed colour is worse than none, so:

  * IR. The IR-cut filter is mechanical: in IR there is no chroma at all. A
    frame whose scene chroma energy (mean|U-128| + mean|V-128| over the frame,
    B1's unit) is at most `ir_chroma_max` (1.0, B1's own cut) is IR and
    contributes nothing. MEASURED: IR frames in the samples read 0.00; the
    lowest colour frames were 1.61-1.65 (a steel lift interior by day, which is
    genuinely grey and is named, not gated); the IR hour's 1,046 scored frames
    all fell under the cut. A window with no colour frame, or whose only motion
    was in IR frames, is gated "ir". A window that switches part-way is scored
    on its colour frames only, and ir_frames says so.
  * LIGHT CAST. Street and indoor lighting can turn grey surfaces chromatic.
    MEASURED on the same pixels by day and at night (surfaces with chroma < 6 by
    day): on f007 and f1ab (outdoor, lit) 54-63% of them read chroma >= 10 at
    night, orange where lit and blue where not; indoor 44de8 at night 38%; 45e2d
    at dusk 52%. On f026 and 083b at night only 2.5-6%. So a blanket night rule
    is wrong both ways, and the gate is measured per window: the median chroma
    of the window's median background (lit pixels, Y > 40), `bg_chroma`. Casted
    windows read 9.5-12.8; every other window measured read 3.2-8.1 (day and
    night). Gate at 9.0. The margin is thin and rests on six cameras; a strongly
    coloured scene by day would be gated too (a wood-toned indoor hall read 13.6
    by day), which errs toward no colour. On the gated f1ab evening window the
    classifier called grey paving and white clothing "blue"; on the ungated
    f026 evening window a blue hoodie read blue and a black coat black (viewed).
  * TOO SMALL. Fewer counted pixels over the whole window than `min_region_frac`
    of one frame's area (144 px at 320x180): a colour from a few dozen pixels is
    noise and compression.

SAMPLED INSTANTS. Keyframes only (B3's measured choice): the window is seen
every 3.3-4 s. Shares are a rate over the frames seen, not a census of
everything that crossed.

THE DECODE SHAPE is B3's: ONE long-lived software ffmpeg per window fed an
iterable of chunks, -threads 1, -skip_frame nokey, no -hwaccel (the shared iGPU
wedges on VA-API context creation). Frames come out as Y4M 4:2:0 in the
stream's own range (yuvj420p, full range, on every stream probed), area-scaled
in the decoder to 320 px wide. MEASURED against a 640 px decode on the day hour
and 32 sample windows: the same colour or gate on 30 of 30 and 31 of 32 (the
one flip a near tie, 0.359 against 0.356), for 14.5-17.9 CPU-s per camera-hour
instead of 25.2. Y/U/V are the raw planes, so scene_chroma is B1's
chroma_energy on the same planes. Watchtower's frame_source today keeps only
that scalar, not the U and V planes this module needs (findings doc).
"""
from __future__ import annotations

import logging
import queue
import re
import subprocess
import threading
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Iterable, Iterator, Sequence

import cv2
import numpy as np

import labs_foreground_mask as fm

logger = logging.getLogger(__name__)

ANALYZER = "colour_histogram"
#: Bump on any change that moves a number (fm.VERSION is recorded beside it).
VERSION = "b7-1"

#: ColorValue in services/db/models.py minus UNKNOWN, in that enum's order. A
#: test pins this against the enum so the vocabularies cannot drift.
COLOURS: tuple[str, ...] = ("red", "blue", "white", "black", "silver", "green",
                            "yellow", "brown", "orange")
UNKNOWN = "unknown"
#: Pixels whose hue has no canonical name (purple, magenta, pink).
OTHER = "other"
NAMES: tuple[str, ...] = COLOURS + (OTHER,)
_IDX = {n: i for i, n in enumerate(NAMES)}
_ACHROMATIC = (_IDX["white"], _IDX["black"], _IDX["silver"])

GATE_IR = "ir"
GATE_NO_MOTION = "no_motion"
GATE_TOO_SMALL = "region_too_small"
GATE_CAST = "light_cast"


@dataclass(frozen=True)
class Config:
    """Every constant that decides a pixel's name or a window's gate."""

    #: A frame whose scene chroma energy (B1 units) is at or below this is IR.
    #: B1's own cut, in the same unit on the same planes (cilex-watchtower
    #: tools/labs/b1_illumination.py IR_CHROMA_MAX). Measured here: IR frames
    #: 0.00, the lowest colour frames 1.61-1.65 (a steel lift interior by day).
    ir_chroma_max: float = 1.0
    #: Window background median chroma at or above this gates "light_cast".
    #: Measured: casted 9.5-12.8, uncasted 3.2-8.1 (module docstring).
    cast_chroma_min: float = 9.0
    #: Background pixels darker than this are left out of bg_chroma (their
    #: chroma is noise and compression).
    cast_min_y: int = 40
    #: Counted moving pixels needed, as a fraction of ONE mask frame's area,
    #: summed over the window. 0.0025 at 320x180 is 144 px.
    min_region_frac: float = 0.0025
    #: The taxonomy's fallback rule: a colour below this share is "unknown".
    min_share: float = 0.30
    #: Erosion kernel (px, square) applied to B3's mask before counting. 0 = off.
    erode_px: int = 3
    #: Illumination change (shadow / highlight) test against the window's
    #: median background: luma ratio in [lo, hi] and chroma distance <= max.
    illum_ratio_lo: float = 0.35
    illum_ratio_hi: float = 1.25
    illum_chroma_max: float = 6.0
    #: Pixel naming.
    black_y: int = 45            # darker than this is black, whatever its chroma
    grey_black_y: int = 70       # an achromatic pixel darker than this is black
    white_y: int = 185           # an achromatic pixel at least this bright is white
    achromatic_c: float = 10.0   # chroma below this is achromatic
    #: At most this many frames are kept for the background median; beyond it
    #: every other frame is dropped (the stride doubles), bounding memory.
    bg_max_frames: int = 160
    #: B3's configuration, passed through to iter_masks.
    mask: fm.Config = fm.DEFAULT


DEFAULT = Config()


# ---------------------------------------------------------------------------
# frames
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class ColourFrame:
    """One frame as planar 4:2:0 YCbCr: the layout the cameras deliver.

    `luma` is (H, W) uint8; `u` (Cb) and `v` (Cr) are the chroma planes,
    normally (H/2, W/2). `t_offset_s` is seconds from the WINDOW start (B3
    refuses time that runs backwards). It has `.luma` and `.t_offset_s`, so
    labs_foreground_mask.iter_masks accepts it and hands it back as `item`.
    """

    t_offset_s: float | None
    luma: np.ndarray
    u: np.ndarray
    v: np.ndarray
    full_range: bool = True

    @classmethod
    def from_i420(cls, buf: bytes | memoryview | np.ndarray, width: int, height: int,
                  t_offset_s: float | None = None, full_range: bool = True) -> "ColourFrame":
        """From one raw yuv420p / yuvj420p frame (Y, then U, then V)."""
        a = np.frombuffer(buf, dtype=np.uint8) if not isinstance(buf, np.ndarray) else buf.ravel()
        ysz, cw, chh = width * height, width // 2, height // 2
        if a.size < ysz + 2 * cw * chh:
            raise ValueError(f"{a.size} bytes is short of one {width}x{height} 4:2:0 frame")
        return cls(t_offset_s, a[:ysz].reshape(height, width),
                   a[ysz:ysz + cw * chh].reshape(chh, cw),
                   a[ysz + cw * chh:ysz + 2 * cw * chh].reshape(chh, cw), full_range)


def as_colour_frame(item: Any) -> ColourFrame:
    """Normalise one input: a ColourFrame, a (t, y, u, v) tuple, or any object
    with .luma, .u, .v (and optional .t_offset_s, .full_range). Anything else
    raises: a frame without chroma cannot be named, and silently dropping it
    would read downstream as a quiet window."""
    if isinstance(item, ColourFrame):
        return item
    if isinstance(item, tuple) and len(item) == 4:
        t, y, u, v = item
        return ColourFrame(None if t is None else float(t), y, u, v)
    if all(hasattr(item, k) for k in ("luma", "u", "v")):
        t = getattr(item, "t_offset_s", None)
        return ColourFrame(None if t is None else float(t), item.luma, item.u, item.v,
                           bool(getattr(item, "full_range", True)))
    raise ValueError(f"{type(item).__name__} carries no chroma planes (need luma, u, v)")


def scene_chroma(u: np.ndarray, v: np.ndarray) -> float:
    """mean|U-128| + mean|V-128| over the frame: B1's chroma_energy on the same planes."""
    return float(np.abs(u.astype(np.int16) - 128).mean() + np.abs(v.astype(np.int16) - 128).mean())


def _to_size(p: np.ndarray, w: int, h: int) -> np.ndarray:
    if p.shape == (h, w):
        return p
    interp = cv2.INTER_AREA if p.shape[1] > w else cv2.INTER_LINEAR
    return cv2.resize(p, (w, h), interpolation=interp)


# ---------------------------------------------------------------------------
# naming pixels
# ---------------------------------------------------------------------------
_KR, _KB = 0.2126, 0.0722      # BT.709: what every probed stream is tagged


def ycbcr_to_rgb(y: Any, cb: Any, cr: Any, full_range: bool = True) -> np.ndarray:
    """BT.709 Y'CbCr to R'G'B' in 0..255, float32, shape (..., 3)."""
    y = np.asarray(y, np.float32)
    cb = np.asarray(cb, np.float32) - 128.0
    cr = np.asarray(cr, np.float32) - 128.0
    if not full_range:
        y = (y - 16.0) * (255.0 / 219.0)
        cb = cb * (255.0 / 224.0)
        cr = cr * (255.0 / 224.0)
    r = y + 2.0 * (1.0 - _KR) * cr
    b = y + 2.0 * (1.0 - _KB) * cb
    g = (y - _KR * r - _KB * b) / (1.0 - _KR - _KB)
    return np.clip(np.stack([r, g, b], -1), 0.0, 255.0)


def rgb_to_ycbcr(rgb: Any) -> np.ndarray:
    """Inverse of ycbcr_to_rgb (full range): for building test swatches."""
    rgb = np.asarray(rgb, np.float32)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    y = _KR * r + (1 - _KR - _KB) * g + _KB * b
    return np.stack([y, (b - y) / (2 * (1 - _KB)) + 128.0, (r - y) / (2 * (1 - _KR)) + 128.0], -1)


def rgb_to_hsv(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Hue in degrees 0..360, saturation 0..1, value 0..1."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx = np.max(rgb, -1)
    d = mx - np.min(rgb, -1)
    s = np.where(mx > 0, d / np.maximum(mx, 1e-6), 0.0)
    h = np.zeros_like(mx)
    nz = d > 1e-6
    rm = nz & (mx == r)
    gm = nz & (mx == g) & ~rm
    bm = nz & ~rm & ~gm
    h[rm] = (60.0 * ((g[rm] - b[rm]) / d[rm])) % 360.0
    h[gm] = 60.0 * ((b[gm] - r[gm]) / d[gm]) + 120.0
    h[bm] = 60.0 * ((r[bm] - g[bm]) / d[bm]) + 240.0
    return h, s, mx / 255.0


def chroma(cb: Any, cr: Any) -> np.ndarray:
    return np.hypot(np.asarray(cb, np.float32) - 128.0, np.asarray(cr, np.float32) - 128.0)


def classify(y: Any, cb: Any, cr: Any, config: Config = DEFAULT,
             full_range: bool = True) -> np.ndarray:
    """Name each pixel: an int8 index into NAMES (COLOURS, then OTHER)."""
    cfg = config
    y = np.asarray(y, np.float32)
    if not full_range:
        y_eff = (y - 16.0) * (255.0 / 219.0)
        c = chroma(cb, cr) * (255.0 / 224.0)
    else:
        y_eff, c = y, chroma(cb, cr)
    h, s, v = rgb_to_hsv(ycbcr_to_rgb(y, cb, cr, full_range))
    out = np.full(y.shape, _IDX[OTHER], np.int8)
    ach = c < cfg.achromatic_c
    out[ach] = _IDX["silver"]
    out[ach & (y_eff >= cfg.white_y)] = _IDX["white"]
    col = ~ach
    out[col & ((h < 12) | (h >= 335))] = _IDX["red"]
    out[col & (h >= 12) & (h < 40)] = _IDX["orange"]
    out[col & (h >= 40) & (h < 70)] = _IDX["yellow"]
    out[col & (h >= 70) & (h < 170)] = _IDX["green"]
    out[col & (h >= 170) & (h < 255)] = _IDX["blue"]
    # warm hues that are dark or washed out: brown, tan, beige (and skin)
    out[col & (h >= 8) & (h < 50) & ((v < 0.55) | (s < 0.45))] = _IDX["brown"]
    out[ach & (y_eff < cfg.grey_black_y)] = _IDX["black"]
    out[y_eff < cfg.black_y] = _IDX["black"]
    return out


def illumination_change(y: Any, cb: Any, cr: Any, yb: Any, cbb: Any, crb: Any,
                        config: Config = DEFAULT) -> np.ndarray:
    """True where a moving pixel is the background re-lit (shadow or highlight)."""
    y = np.asarray(y, np.float32)
    r = y / np.maximum(np.asarray(yb, np.float32), 1.0)
    d = np.hypot(np.asarray(cb, np.float32) - np.asarray(cbb, np.float32),
                 np.asarray(cr, np.float32) - np.asarray(crb, np.float32))
    return ((r >= config.illum_ratio_lo) & (r <= config.illum_ratio_hi)
            & (d <= config.illum_chroma_max))


# ---------------------------------------------------------------------------
# window scores
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class WindowColour:
    """One window's colour, reduced. Frozen: these are a measurement."""

    gate: str | None
    colour: str | None               # None iff gated
    colour_share: float | None
    runner_up: str | None
    runner_up_share: float | None
    achromatic_share: float | None   # white + black + silver
    other_share: float | None        # hues with no canonical name
    chroma_mean: float | None        # counted moving pixels
    luma_mean: float | None
    region_px: int                   # counted moving pixels (mask resolution)
    moving_px: int                   # B3 foreground pixels in colour frames
    illum_change_frac: float | None  # share of eroded moving px removed as shadow/highlight
    scene_chroma: float | None       # median over colour frames, B1 units
    bg_chroma: float | None          # median chroma of the lit median background
    frames: int                      # scored frames (B3's `scored`)
    colour_frames: int               # of which not IR
    ir_frames: int
    motion_frames: int               # colour frames with any B3 blob
    frame_step_s: float | None
    mask_w: int
    mask_h: int
    span_s: float | None = None

    def as_metrics(self) -> dict:
        """The metrics payload: scalars only, slug keys, at most 23 keys."""
        m: dict[str, Any] = {
            "region_px": self.region_px, "moving_px": self.moving_px,
            "frames": self.frames, "colour_frames": self.colour_frames,
            "ir_frames": self.ir_frames, "motion_frames": self.motion_frames,
            "mask_w": self.mask_w, "mask_h": self.mask_h,
        }
        if self.gate is not None:
            m["gate"] = self.gate
        if self.colour is not None:
            m["colour"] = self.colour
        # absent, not null, when not measured
        for k in ("colour_share", "runner_up_share", "achromatic_share", "other_share",
                  "illum_change_frac"):
            val = getattr(self, k)
            if val is not None:
                m[k] = round(val, 4)
        if self.runner_up is not None:
            m["runner_up"] = self.runner_up
        for k in ("chroma_mean", "luma_mean", "scene_chroma", "bg_chroma"):
            val = getattr(self, k)
            if val is not None:
                m[k] = round(val, 2)
        if self.frame_step_s is not None:
            m["frame_step_s"] = round(self.frame_step_s, 3)
        if self.span_s is not None:
            m["span_s"] = round(self.span_s, 2)
        return m

    def as_observation(self, start_time: str | datetime, end_time: str | datetime) -> dict:
        """A complete ObservationIn dict. Only start_time, end_time and metrics:
        a colour is not a class, a count, a shape or a light level."""
        def _iso(val: str | datetime) -> str:
            if isinstance(val, datetime):
                if val.tzinfo is None:
                    raise ValueError("naive datetime: refusing to guess its zone")
                return val.isoformat()
            return str(val)

        return {"start_time": _iso(start_time), "end_time": _iso(end_time),
                "metrics": self.as_metrics()}


def _median_step(ts: Sequence[float | None]) -> float | None:
    vals = [t for t in ts if t is not None]
    d = [b - a for a, b in zip(vals, vals[1:]) if b > a]
    return float(np.median(d)) if d else None


def score_window(frames: Iterable[Any], *, span_s: float | None = None,
                 config: Config | None = None) -> WindowColour | None:
    """Colour of one window of consecutive frames of ONE camera.

    `frames`: ColourFrames (or (t, y, u, v) tuples, or objects with .luma .u .v
    and .t_offset_s), t from the WINDOW start. Returns None when B3 scored
    fewer than its min_frames: "too short to model" is not "nothing moved".
    """
    cfg = config or DEFAULT
    kernel = (np.ones((cfg.erode_px, cfg.erode_px), np.uint8) if cfg.erode_px >= 2 else None)
    frames_scored = colour_frames = ir_frames = motion_frames = 0
    ts: list[float | None] = []
    ce_colour: list[float] = []
    bg_stack: list[np.ndarray] = []
    stride, n_colour_seen = 1, 0
    # moving pixels, kept compactly: (bg slot index is resolved after the loop)
    mov_yuv: list[np.ndarray] = []
    mov_idx: list[np.ndarray] = []
    moving_px = 0
    size = (0, 0)
    full_range = True
    ir_motion = False      # did anything move in the IR frames?
    for mf in fm.iter_masks((as_colour_frame(f) for f in frames), config=cfg.mask):
        cf: ColourFrame = mf.item
        W, H = mf.width, mf.height
        size = (W, H)
        ts.append(mf.t_s)
        ce = scene_chroma(cf.u, cf.v)
        is_ir = ce <= cfg.ir_chroma_max
        if not is_ir:
            if n_colour_seen % stride == 0:
                u = _to_size(cf.u, W, H)
                v = _to_size(cf.v, W, H)
                bg_stack.append(np.stack([mf.luma, u, v], -1))
                if len(bg_stack) > cfg.bg_max_frames:
                    bg_stack = bg_stack[::2]
                    stride *= 2
            n_colour_seen += 1
        if not mf.scored:
            continue
        frames_scored += 1
        if is_ir:
            ir_frames += 1
            ir_motion = ir_motion or bool(mf.blobs)
            continue
        colour_frames += 1
        ce_colour.append(ce)
        if not mf.blobs:
            continue
        motion_frames += 1
        m = mf.mask
        moving_px += int(np.count_nonzero(m))
        if kernel is not None:
            m = cv2.erode(m.astype(np.uint8), kernel).astype(bool)
        idx = np.flatnonzero(m.ravel())
        if idx.size == 0:
            continue
        u = _to_size(cf.u, W, H).ravel()[idx]
        v = _to_size(cf.v, W, H).ravel()[idx]
        mov_yuv.append(np.stack([mf.luma.ravel()[idx], u, v], -1))
        mov_idx.append(idx)
        full_range = cf.full_range
    if frames_scored < cfg.mask.min_frames:
        return None
    W, H = size
    common = dict(frames=frames_scored, colour_frames=colour_frames, ir_frames=ir_frames,
                  motion_frames=motion_frames, frame_step_s=_median_step(ts),
                  mask_w=W, mask_h=H, span_s=span_s, moving_px=moving_px)
    empty = dict(colour=None, colour_share=None, runner_up=None, runner_up_share=None,
                 achromatic_share=None, other_share=None, chroma_mean=None, luma_mean=None)
    if colour_frames == 0:
        return WindowColour(gate=GATE_IR, region_px=0, illum_change_frac=None,
                            scene_chroma=None, bg_chroma=None, **empty, **common)
    bg = np.median(np.stack(bg_stack), axis=0).reshape(-1, 3).astype(np.float32)
    lit = bg[:, 0] > cfg.cast_min_y
    bg_chroma = float(np.median(chroma(bg[lit, 1], bg[lit, 2]))) if lit.any() else None
    scene = float(np.median(ce_colour))
    if not mov_yuv:
        # Something moved, but only while the camera was in IR: that is "ir",
        # not "nothing moved".
        return WindowColour(gate=GATE_IR if ir_motion else GATE_NO_MOTION, region_px=0,
                            illum_change_frac=None,
                            scene_chroma=scene, bg_chroma=bg_chroma, **empty, **common)
    pix = np.concatenate(mov_yuv).astype(np.float32)
    at = bg[np.concatenate(mov_idx)]
    ill = illumination_change(pix[:, 0], pix[:, 1], pix[:, 2], at[:, 0], at[:, 1], at[:, 2], cfg)
    keep = pix[~ill]
    illum_frac = float(ill.mean())
    region_px = int(keep.shape[0])
    stats = dict(scene_chroma=scene, bg_chroma=bg_chroma, illum_change_frac=illum_frac,
                 region_px=region_px)
    if region_px < cfg.min_region_frac * W * H or region_px == 0:
        return WindowColour(gate=GATE_TOO_SMALL, **empty, **stats, **common)
    cls = classify(keep[:, 0], keep[:, 1], keep[:, 2], cfg, full_range)
    counts = np.bincount(cls, minlength=len(NAMES)).astype(np.float64)
    shares = counts / counts.sum()
    named = np.argsort(-shares[:len(COLOURS)], kind="stable")
    top, second = int(named[0]), int(named[1])
    measured = dict(
        colour_share=float(shares[top]),
        runner_up=COLOURS[second] if shares[second] > 0 else None,
        runner_up_share=float(shares[second]) if shares[second] > 0 else None,
        achromatic_share=float(sum(shares[i] for i in _ACHROMATIC)),
        other_share=float(shares[_IDX[OTHER]]),
        chroma_mean=float(chroma(keep[:, 1], keep[:, 2]).mean()),
        luma_mean=float(keep[:, 0].mean()),
    )
    if bg_chroma is not None and bg_chroma >= cfg.cast_chroma_min:
        # Not named, and no share of an unnamed colour either: a share without its
        # name is half a guess. The chroma, luma and achromatic/other shares stay
        # so the gate can be re-judged.
        measured.update(colour_share=None, runner_up=None, runner_up_share=None)
        return WindowColour(gate=GATE_CAST, colour=None, **measured, **stats, **common)
    colour = COLOURS[top] if shares[top] >= cfg.min_share else UNKNOWN
    return WindowColour(gate=None, colour=colour, **measured, **stats, **common)


# ---------------------------------------------------------------------------
# decode: ONE long-lived software decoder per window
# ---------------------------------------------------------------------------
_SHOWINFO_N = re.compile(r"\bn:\s*(\d+)\b")
_SHOWINFO_PTS = re.compile(r"\bpts_time:\s*([-+0-9.eE]+)")


def decode_yuv(source: Iterable[bytes] | bytes, *, keyframes_only: bool = True,
               width: int = 320, ffmpeg: str = "ffmpeg", timeout_s: float = 300.0
               ) -> Iterator[ColourFrame]:
    """Yield ColourFrames for a window of MPEG-TS from ONE software decoder.

    `source`: raw MPEG-TS bytes or an iterable of chunks, segments in order
    (MPEG-TS concatenates). Nothing is buffered beyond one chunk and one frame.
    Output is Y4M, which carries its size and range, so no resolution is
    assumed. Frames wider than `width` are area-scaled in the decoder. 320
    (the default) matches B3's mask width; 640 keeps 640x360 sub native, which
    is what a worker holding native frames sees, and measured the same answers
    at 1.4-1.7x the CPU (module docstring). `t_offset_s` is from showinfo pts, relative to the first
    frame, folded forward so it never decreases (labs_foreground_mask).
    No -hwaccel, deliberately.
    """
    vf = [f"scale='min({int(width)},iw)':-2:flags=area", "showinfo"]
    cmd = [ffmpeg, "-hide_banner", "-nostats", "-loglevel", "info",
           "-threads", "1", "-filter_threads", "1"]
    if keyframes_only:
        cmd += ["-skip_frame", "nokey"]
    cmd += ["-fflags", "+discardcorrupt", "-i", "pipe:0", "-map", "0:v:0",
            "-an", "-sn", "-dn", "-fps_mode", "passthrough", "-vf", ",".join(vf),
            "-f", "yuv4mpegpipe", "-strict", "-1", "pipe:1"]
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
        except BaseException as e:      # the SOURCE failed mid-window
            feed_errors.append(e)
        finally:
            try:
                proc.stdin.close()
            except OSError:
                pass

    def _drain() -> None:
        # one showinfo line per frame: a full stderr pipe would stall ffmpeg
        for raw_line in iter(proc.stderr.readline, b""):
            line = raw_line.decode("utf-8", "replace")
            if "showinfo" in line and _SHOWINFO_N.search(line):
                mt = _SHOWINFO_PTS.search(line)
                try:
                    pts_q.put(float(mt.group(1)) if mt else None)
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
    pts0: float | None = None
    offset = 0.0
    last_t: float | None = None
    last_step: float | None = None
    timing = True
    try:
        header = proc.stdout.readline()
        if header:
            tags = header.split()
            if not tags or tags[0] != b"YUV4MPEG2":
                raise RuntimeError(f"unexpected decoder output {header[:16]!r}")
            w = h = 0
            cs = b"420jpeg"
            full = False
            for tg in tags[1:]:
                if tg[:1] == b"W":
                    w = int(tg[1:])
                elif tg[:1] == b"H":
                    h = int(tg[1:])
                elif tg[:1] == b"C":
                    cs = tg[1:]
                elif tg == b"XCOLORRANGE=FULL":
                    full = True
            if not cs.startswith(b"420"):
                raise RuntimeError(f"expected 4:2:0, the decoder gave C{cs.decode()}")
            ysz, csz = w * h, (w // 2) * (h // 2)
            while True:
                if not proc.stdout.readline():          # b"FRAME\n"
                    break
                buf = proc.stdout.read(ysz + 2 * csz)
                if len(buf) < ysz + 2 * csz:
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
                            step = last_step or fm.DEFAULT.default_frame_step_s
                            offset += (last_t - t) + step
                            t = last_t + step
                        if last_t is not None and t > last_t:
                            last_step = t - last_t
                        last_t = t
                produced += 1
                yield ColourFrame.from_i420(buf, w, h, t, full)
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
        raise RuntimeError("the window's source failed mid-stream") from feed_errors[0]
    if produced == 0 and proc.returncode not in (0, None):
        raise RuntimeError(f"decoder exited {proc.returncode} with no frames: "
                           + " | ".join(errors[-3:])[:400])
    if errors:
        logger.debug("ffmpeg: %s", " | ".join(errors[-5:])[:500])


def analyse(source: Iterable[bytes] | bytes, *, span_s: float | None = None,
            keyframes_only: bool = True, config: Config | None = None, width: int = 320,
            ffmpeg: str = "ffmpeg", timeout_s: float = 300.0) -> WindowColour | None:
    """Decode one window of consecutive segments and score it. The whole analyser.

    `source`: the window's MPEG-TS as chunks, segments in order (plan the
    windows with labs_foreground_mask.plan_windows(segments, run=4)).
    `span_s`: the sum of the segments' duration_s (recorded in the metrics).
    """
    return score_window(decode_yuv(source, keyframes_only=keyframes_only, width=width,
                                   ffmpeg=ffmpeg, timeout_s=timeout_s),
                        span_s=span_s, config=config)


#: Window planning is B3's: 4 consecutive segments, never across a gap.
plan_windows = fm.plan_windows
