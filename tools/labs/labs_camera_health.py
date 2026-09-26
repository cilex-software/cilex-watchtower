"""B2 camera_health: a FAULT detector, not content metadata.

One scored WINDOW (several segments of one camera, ideally spread across an
hour) becomes one observation with five tri-state booleans and the score
behind each. None means "this window could not answer", never "healthy".
Validation numbers, cost and the plugin spec are in
docs/findings/2026-09-26-labs-camera_health.md; the scripts that produced them
are under cv-ops/labs-work/camera_health/ and ran through labs_run.sh.

WHAT EACH OUTPUT CLAIMS
    obscured        at least MIN_RUN (2) consecutive keyframes had half or more
                    of the picture featureless (40 tiles of the 8x8-block-mean
                    image, tile std < 2.0). Score: flat_frac, obscured_frac.
                    Healthy max flat_frac 0.15 over 62 windows; staged covers
                    read 0.5 (half), 0.75 (80%), 1.0 (full, and full grey with
                    noise). A single covered keyframe is a passer-by, not a fault.
    defocused       the edge width (range / peak Sobel per 32x32 block, 25th
                    percentile of strong-edge blocks) is wider than this
                    camera's own reference by 1/0.8: sharp_ratio < 0.8. The
                    reference is the STATE (median of up to 12 recent healthy
                    windows, kept apart for IR and colour) and, failing that,
                    the window's own sharpest segment. Healthy min 0.901;
                    staged gblur sigma 8 read 0.523..0.666. NOT detected at
                    sigma 4 (0.849..0.976) or 2: the floor sits between sigma 4
                    and 8 on 2560-wide main, set by the 640x360 working frame.
    moved           phase correlation of Sobel-magnitude views (320x180) moved
                    by >= 1.5% of the width, with response >= 0.15. Reference:
                    the state's view (a persistent move shows in no single
                    window) and the window's first segment. Reported ONCE, at
                    the transition: the state's view is refreshed every window.
                    Healthy max 0.0005; staged 5% read 0.050..0.0505, 2% read
                    0.019 (flagged), 1% read 0.0096 (measured, not flagged).
    frozen          the picture stopped changing, told apart from a still scene
                    by SENSOR NOISE: either 2+ keyframes share bit-identical
                    textured 40x40 tiles (>= 5% of them) with another keyframe,
                    or 2 consecutive keyframe pairs changed less than 0.25
                    levels (median tile). Every live capture carries fresh
                    noise: healthy ident_frac 0.0 and change_min >= 1.222,
                    including a still indoor night camera. Staged freeze read
                    ident_frac 1.0 and change 0.0; with a ticking clock burned
                    in, ident_frac 0.09..0.556.
    lights_changed  the light regime changed: an IR transition (chroma energy
                    <= 0.1 is IR; measured 0.000 on IR keyframes, >= 1.627 on
                    colour ones), in the window or against the state's last
                    regime (<= 2 h earlier, forward in time only), or a
                    frame-wide luma step >= 20 levels between keyframes <= 60 s
                    apart. step_after/step_at bracket the change. Real dusk
                    switch (labs-samples/dusk_switch): bracket 16:48:20.997Z to
                    16:48:24.994Z. Real dawn switch, spread hour: 03:15:41.9Z
                    to 03:30:16Z. Real dusk switch BETWEEN spread hours: found
                    only through the state, 16:45:44.9Z to 17:00:20Z.

KEYFRAMES ONLY, AND IT IS REQUIRED, NOT MERELY CHEAPER. MEASURED (allframes.py,
3 live segments): decoding every frame made `frozen` true on all three,
because skip-coded P-frames reproduce textured tiles bit for bit (391..413 of
419 consecutive pairs). Keyframes are intra-coded from fresh sensor data: 0/6
pairs on each. A wrapper that feeds non-keyframes breaks `frozen`.

GATING. A covered lens is black, flat, noiseless and chromaless, so without
gating one cover would also read frozen, IR-switched and defocused. Every
other fault is judged only on unobscured keyframes, and a window with none
answers None for them. The state never learns from a faulty window.

DECODE SHAPE. One long-lived software decoder per window (no -hwaccel: the
shared iGPU wedges on decoder creation rate), -skip_frame nokey, -threads 1,
640x360 point-sampled (flags=neighbor, bit-identical to decimate() on
full-resolution luma, so a wrapper handing over the worker's full-res frames
gets the same numbers). Segments stream into stdin; keyframes are attributed
to segments from the TS random_access_indicator as the bytes go by.
"""
from __future__ import annotations

import base64
import hashlib
import logging
import math
import subprocess
import threading
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable, Iterator, Sequence

import numpy as np

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Geometry of the working frame
# ---------------------------------------------------------------------------
WORK_W, WORK_H = 640, 360       # point-sampled working frame (ffmpeg flags=neighbor)
VIEW_W, VIEW_H = 320, 180       # 2x2 block mean: the phase-correlation view
FLAT_W, FLAT_H = 80, 45         # 8x8 block mean: where "no structure" is judged
FLAT_COLS, FLAT_ROWS = 8, 5     # 40 tiles of 10x9 on the 80x45 image
PAIR_TILE = 40                  # 16x9 tiles of 40x40 on the working frame

# ---------------------------------------------------------------------------
# Thresholds. Each one is justified, with the measurement, in the docstring.
# ---------------------------------------------------------------------------
FLAT_TILE_STD = 2.0             # a 10x9 tile of the 80x45 image with less spread is featureless
OBSCURED_FLAT_FRAC = 0.5        # at least half the frame featureless
MIN_RUN = 2                     # a state must hold on 2 consecutive keyframes to count
TEXTURED_RANGE = 8              # a 40x40 tile spanning fewer levels is not evidence either way
FROZEN_IDENT_MIN = 0.05         # share of textured tiles with a bit-identical twin
FROZEN_CHANGE_MAX = 0.25        # median-tile |diff| that only an unchanged picture reaches
FROZEN_MIN_PAIRS = 2
EDGE_BLOCK = 32                 # 32x32 blocks of the working frame (11x20 of them)
EDGE_MIN_RANGE = 64.0           # a block spanning fewer luma levels holds no usable edge
EDGE_MIN_BLOCKS = 8             # fewer strong-edge blocks than this: focus not assessable
EDGE_PCT = 25                   # the sharpest quarter of the edges decides
DEFOCUS_RATIO = 0.8             # reference edge width / current edge width below this
BASELINE_MIN = 2
BASELINE_MAX = 12
MOVE_FRAC = 0.015               # view shift, as a fraction of the width
MOVE_RESP_MIN = 0.15            # phase-correlation response a shift must reach to count
IR_CHROMA_MAX = 0.1             # chroma energy of a greyscale (IR) frame; measured 0.000
LUMA_STEP_MIN = 20.0            # frame-wide luma step, levels
LUMA_STEP_AGREE = 0.75          # share of tiles that must move the same way
LUMA_STEP_MAX_GAP_S = 60.0      # a luma step counts only between keyframes this close
LIGHT_CARRY_MAX_S = 7200.0      # the IR regime carried in state is trusted this long


# ---------------------------------------------------------------------------
# Small numpy building blocks
# ---------------------------------------------------------------------------
def _neighbor_index(src: int, dst: int) -> np.ndarray:
    return np.floor((np.arange(dst) + 0.5) * (src / dst)).astype(np.intp)


def decimate(luma: np.ndarray, width: int = WORK_W, height: int = WORK_H) -> np.ndarray:
    """Point-sample `luma` to the working size, exactly as ffmpeg `flags=neighbor`."""
    a = np.asarray(luma)
    if a.ndim != 2:
        raise ValueError(f"luma must be 2-D, got shape {a.shape}")
    h, w = a.shape
    if (w, h) == (width, height):
        return a if a.dtype == np.uint8 else a.astype(np.uint8)
    out = a[np.ix_(_neighbor_index(h, height), _neighbor_index(w, width))]
    return out if out.dtype == np.uint8 else out.astype(np.uint8)


def _block_mean(a: np.ndarray, f: int) -> np.ndarray:
    h, w = a.shape
    return a[: h - h % f, : w - w % f].reshape(h // f, f, w // f, f).mean(axis=(1, 3))


def _sobel_mag(a: np.ndarray) -> np.ndarray:
    gx = (a[:-2, 2:] + 2.0 * a[1:-1, 2:] + a[2:, 2:]
          - a[:-2, :-2] - 2.0 * a[1:-1, :-2] - a[2:, :-2])
    gy = (a[2:, :-2] + 2.0 * a[2:, 1:-1] + a[2:, 2:]
          - a[:-2, :-2] - 2.0 * a[:-2, 1:-1] - a[:-2, 2:])
    return np.hypot(gx, gy) / 8.0


def chroma_energy_of(uv: np.ndarray) -> float:
    """B1's scalar: mean|U-128| + mean|V-128|, over both planes read as one."""
    return float(np.abs(uv.astype(np.int16) - 128).mean()) * 2.0


# ---------------------------------------------------------------------------
# Per-keyframe measurements
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class FrameStats:
    """One keyframe, reduced to what the window needs. Nothing here needs a baseline."""
    luma: float
    chroma: float | None
    flat_frac: float
    edge: float | None
    tile_luma: tuple = field(default=(), compare=False, repr=False)

    @property
    def ir(self) -> bool | None:
        return None if self.chroma is None else self.chroma <= IR_CHROMA_MAX

    @property
    def obscured(self) -> bool:
        return self.flat_frac >= OBSCURED_FLAT_FRAC


def edge_width(b: np.ndarray) -> float | None:
    """Typical width, in working-frame pixels, of the sharpest edges in a frame.

    Per 32x32 block holding a strong edge (luma range >= EDGE_MIN_RANGE):
    range / peak Sobel gradient, which for a step blurred by a Gaussian of
    sigma s is about 2.5 s. The EDGE_PCT percentile over those blocks is the
    frame's figure: focus is decided by the best edges it can still draw.

    WHY NOT A LAPLACIAN RATIO, which this used first: a real defocus blurs the
    scene in front of the sensor and the sensor then adds FRESH noise, which
    the fine-scale Laplacian mistakes for detail. On a synthetic scene blurred
    and then given noise of sigma 2 the Laplacian ratio ROSE 1.79x; this
    estimate fell to 0.36x, because a peak gradient over a 32x32 block is set
    by the edge, not the noise.
    """
    B = EDGE_BLOCK
    g = _sobel_mag(b)
    H, W = (g.shape[0] // B) * B, (g.shape[1] // B) * B
    gmax = g[:H, :W].reshape(H // B, B, W // B, B).max(axis=(1, 3))
    lb = b[1:H + 1, 1:W + 1].reshape(H // B, B, W // B, B)
    rng = lb.max(axis=(1, 3)) - lb.min(axis=(1, 3))
    strong = rng >= EDGE_MIN_RANGE
    if int(strong.sum()) < EDGE_MIN_BLOCKS:
        return None
    return float(np.percentile(rng[strong] / np.maximum(gmax[strong], 1e-3), EDGE_PCT))


def frame_stats(base: np.ndarray, chroma: float | None = None) -> FrameStats:
    """Per-keyframe measurements on the 640x360 working frame."""
    b = base.astype(np.float32)
    flat = _block_mean(b, 8)[:FLAT_H, :FLAT_W]
    th, tw = FLAT_H // FLAT_ROWS, FLAT_W // FLAT_COLS
    tiles = flat.reshape(FLAT_ROWS, th, FLAT_COLS, tw)
    return FrameStats(
        luma=float(b.mean()),
        chroma=None if chroma is None else float(chroma),
        flat_frac=float((tiles.std(axis=(1, 3)) < FLAT_TILE_STD).mean()),
        edge=edge_width(b),
        tile_luma=tuple(float(x) for x in tiles.mean(axis=(1, 3)).ravel()),
    )


def pair_change(prev: np.ndarray, cur: np.ndarray) -> float:
    """Median over 40x40 tiles of the mean |difference|: how much a picture changed.

    The median, not the mean, so a clock overlay or one passing object cannot
    carry the statistic.
    """
    d = np.abs(cur.astype(np.int16) - prev.astype(np.int16)).astype(np.float32)
    h, w = d.shape
    t = PAIR_TILE
    tiles = d[: h - h % t, : w - w % t].reshape(h // t, t, w // t, t).mean(axis=(1, 3))
    return float(np.median(tiles))


def tile_digests(base: np.ndarray) -> tuple[int, list[tuple[int, bytes]]]:
    """(textured tile count, [(tile index, digest)]) for the 40x40 tiles of a frame.

    A textured tile (spanning TEXTURED_RANGE levels or more) that is BIT-IDENTICAL
    to the same tile of another keyframe cannot come from a camera that is still
    capturing: every capture carries fresh sensor noise.
    """
    t = PAIR_TILE
    h, w = base.shape
    tl = np.ascontiguousarray(base[: h - h % t, : w - w % t]).reshape(
        h // t, t, w // t, t).transpose(0, 2, 1, 3).reshape(-1, t * t)
    rng = tl.max(axis=1).astype(np.int16) - tl.min(axis=1).astype(np.int16)
    idx = np.nonzero(rng >= TEXTURED_RANGE)[0]
    return len(idx), [(int(k), hashlib.blake2b(tl[k].tobytes(), digest_size=16).digest())
                      for k in idx]


# ---------------------------------------------------------------------------
# View and phase correlation
# ---------------------------------------------------------------------------
_HANN: dict[tuple[int, int], np.ndarray] = {}


def _hann(h: int, w: int) -> np.ndarray:
    k = (h, w)
    if k not in _HANN:
        _HANN[k] = np.outer(np.hanning(h), np.hanning(w)).astype(np.float32)
    return _HANN[k]


def make_view(half_luma: np.ndarray) -> np.ndarray:
    g = np.log1p(_sobel_mag(np.asarray(half_luma, dtype=np.float32)))
    return (g - g.mean()).astype(np.float32)


@dataclass(frozen=True)
class Shift:
    """Displacement of one view's content relative to another, in view pixels."""
    dx: float
    dy: float
    response: float
    width: int = VIEW_W

    @property
    def frac(self) -> float:
        """Shift magnitude as a fraction of the view width."""
        return math.hypot(self.dx, self.dy) / float(self.width)


def phase_shift(a: np.ndarray, b: np.ndarray) -> Shift:
    """How far the content of `b` sits from the content of `a`, in view pixels."""
    h, w = a.shape
    win = _hann(h, w)
    fa = np.fft.rfft2(a * win)
    fb = np.fft.rfft2(b * win)
    r = fb * np.conj(fa)
    r /= np.abs(r) + 1e-9
    c = np.fft.irfft2(r, s=(h, w))
    iy, ix = np.unravel_index(int(np.argmax(c)), c.shape)
    ys = [(iy + k) % h for k in (-2, -1, 0, 1, 2)]
    xs = [(ix + k) % w for k in (-2, -1, 0, 1, 2)]
    patch = c[np.ix_(ys, xs)]
    resp = float(patch.sum())
    pos = np.clip(patch, 0, None)
    tot = float(pos.sum())
    if tot > 0:
        oy = float((pos.sum(axis=1) * np.arange(-2, 3)).sum() / tot)
        ox = float((pos.sum(axis=0) * np.arange(-2, 3)).sum() / tot)
    else:
        oy = ox = 0.0
    dy = iy + oy
    dx = ix + ox
    if dy > h / 2:
        dy -= h
    if dx > w / 2:
        dx -= w
    return Shift(dx=float(dx), dy=float(dy), response=resp, width=int(w))


# ---------------------------------------------------------------------------
# The window
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Keyframe:
    """One decoded keyframe as a caller hands it over.

    `luma` is the Y plane at ANY resolution (full-res off the Watchtower frame
    source, or already 640x360 off `decode_keyframes`); it is point-sampled to
    the working size here, bit-identically to ffmpeg `flags=neighbor`.
    `chroma` is B1's chroma_energy (mean|U-128| + mean|V-128|) or None when the
    decoder did not deliver chroma. `t` is seconds since ITS segment started.

    KEYFRAMES ONLY. P-frames repeat tiles bit for bit on a live camera and
    make every window read `frozen` (measured on 3/3 live segments; see the
    module docstring). A wrapper must decode with keyframes_only=True.
    """
    luma: np.ndarray
    chroma: float | None = None
    t: float | None = None


def _longest_run(flags: Sequence[bool | None]) -> int:
    best = cur = 0
    for f in flags:
        cur = cur + 1 if f else 0
        best = max(best, cur)
    return best


def luma_step(tile_lumas: Sequence[Sequence[float]]) -> tuple[float, int | None]:
    """The largest FRAME-WIDE persistent step in a series of per-tile luma means.

    Returns (step, index of the first keyframe after it). A step counts only if
    at least LUMA_STEP_AGREE of the tiles moved the same way, and its size is the
    (1 - LUMA_STEP_AGREE) quantile of their movement: a light switching affects
    the whole picture, a lorry parking or a hand over half the lens does not.
    Both sides need MIN_RUN keyframes, so one flash is not a step.

    The window scorer calls this once per RUN of keyframes whose gaps are all
    at most LUMA_STEP_MAX_GAP_S, never across a longer gap, because across a
    15-minute gap a STEP and a gradual dusk look the same. MEASURED:
    spread-sampled hour 16 of hiwatch-04eecdd45e2d dimmed 112 -> 108 -> 98 -> 82
    over four segments 15 min apart and, scored as one series, read as a
    23.14-level step at 16:30:19, while the camera's real light change (IR at
    16:48) happened in the next hour.
    """
    x = np.asarray(tile_lumas, dtype=np.float64)
    n = len(x)
    best, at = 0.0, None
    for k in range(MIN_RUN, n - MIN_RUN + 1):
        d = np.median(x[k:], axis=0) - np.median(x[:k], axis=0)
        sign = 1.0 if np.median(d) >= 0 else -1.0
        agree = float(np.mean(d * sign > 0))
        if agree < LUMA_STEP_AGREE:
            continue
        size = float(np.quantile(np.abs(d) * (d * sign > 0), 1.0 - LUMA_STEP_AGREE))
        if size > best:
            best, at = size, k
    return best, at


@dataclass(frozen=True)
class WindowHealth:
    """One scored window. Frozen: it is a measurement.

    Every boolean is tri-state on purpose. None means THIS WINDOW COULD NOT
    ANSWER (too few keyframes, the lens was covered so focus is meaningless,
    no baseline yet), which is a different fact from False, and storing False
    for it would turn "not checked" into "checked and healthy".
    """
    obscured: bool | None
    obscured_frac: float
    flat_frac: float
    defocused: bool | None
    edge_px: float | None
    edge_ref: float | None
    sharp_ratio: float | None
    sharp_ref_kind: str | None
    moved: bool | None
    shift_frac: float | None
    shift_resp: float | None
    move_ref_kind: str | None
    move_ref_at: datetime | None
    frozen: bool | None
    change_min: float | None
    ident_frac: float | None
    frozen_pairs: int
    pairs: int
    lights_changed: bool | None
    ir_transitions: int
    luma_step: float | None
    step_at: datetime | None
    ir: bool | None
    keyframes: int
    segments: int
    seen_s: float | None
    baseline_n: int
    start: datetime | None = None
    end: datetime | None = None
    attributed: bool = True
    #: The last keyframe of the OLD light regime: the change happened after
    #: step_after and at or before step_at. From the previous window's state
    #: when the change fell between two windows.
    step_after: datetime | None = None
    #: True when the light change was found against the state, not inside the window.
    step_carried: bool = False
    # Not serialised: what the baseline learns from this window.
    regime_edge: dict = field(default_factory=dict, compare=False, repr=False)
    ref_half: np.ndarray | None = field(default=None, compare=False, repr=False)
    ref_half_at: datetime | None = field(default=None, compare=False, repr=False)
    ir_last: bool | None = field(default=None, compare=False, repr=False)
    ir_last_at: datetime | None = field(default=None, compare=False, repr=False)

    @property
    def faults(self) -> list[str]:
        return [k for k in ("obscured", "defocused", "moved", "frozen", "lights_changed")
                if getattr(self, k) is True]

    def as_metrics(self) -> dict:
        """The `metrics` payload: at most 23 scalar keys, builtins only.

        20 keys always, plus step_at/step_after and moved_since when they
        apply. That leaves ONE of the server's 24 for the wrapper. `faults` (a
        comma list of the true booleans) and `edge_ref` were dropped to make
        that room: both are derivable from keys that remain.
        """
        def f(v, nd=3):
            if v is None:
                return None
            v = float(v)
            return None if not math.isfinite(v) else round(v, nd)

        def b(v):
            return None if v is None else bool(v)

        m = {
            "obscured": b(self.obscured),
            "obscured_frac": f(self.obscured_frac),
            "flat_frac": f(self.flat_frac),
            "defocused": b(self.defocused),
            "edge_px": f(self.edge_px),
            "sharp_ratio": f(self.sharp_ratio),
            "moved": b(self.moved),
            "shift_frac": f(self.shift_frac, 4),
            "shift_resp": f(self.shift_resp),
            "frozen": b(self.frozen),
            "change_min": f(self.change_min),
            "ident_frac": f(self.ident_frac),
            "lights_changed": b(self.lights_changed),
            "ir_transitions": int(self.ir_transitions),
            "luma_step": f(self.luma_step, 2),
            "ir": b(self.ir),
            "keyframes": int(self.keyframes),
            "seen_s": f(self.seen_s, 1),
            "baseline_n": int(self.baseline_n),
            "ref": _ref_label(self.sharp_ref_kind, self.move_ref_kind),
        }
        if self.step_at is not None:
            m["step_at"] = _iso(self.step_at)
            if self.step_after is not None:
                m["step_after"] = _iso(self.step_after)
        if self.moved is not None and self.move_ref_at is not None:
            m["moved_since"] = _iso(self.move_ref_at)
        return m

    def as_observation(self, scene_light: str | None = None) -> dict:
        """One ObservationIn dict (routers/labs.py, extra=forbid)."""
        if self.start is None or self.end is None:
            raise ValueError("window has no start/end; pass segment starts to the scorer")
        obs = {"start_time": _iso(self.start), "end_time": _iso(self.end),
               "metrics": self.as_metrics()}
        light = "ir" if self.ir else scene_light
        if light is not None:
            obs["scene_light"] = light
        return obs


def _ref_label(sharp_kind: str | None, move_kind: str | None) -> str:
    kinds = {k for k in (sharp_kind, move_kind) if k}
    if not kinds:
        return "none"
    return "baseline" if kinds == {"baseline"} else ("window" if kinds == {"window"} else "both")


def _iso(t: datetime) -> str:
    if t.tzinfo is None:
        raise ValueError(f"naive datetime {t!r}: refusing to guess its zone")
    return t.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


@dataclass
class Baseline:
    """Per-camera memory carried between windows: the plugin is STATEFUL.

    edge       regime ('colour' | 'ir' | 'unknown') -> the median edge width of
               the most recent healthy windows, newest last, at most
               BASELINE_MAX. Healthy = not obscured, not frozen, not defocused:
               a fault must never become the yardstick it is measured against.
    view_half  the 320x180 median luma of the most recent unobscured segment,
               and `view_at` when it was taken. Updated EVERY window, moved or
               not, so `moved` reports a transition ("the view changed since
               view_at") once, rather than forever after a deliberate re-aim.
    last_ir    the IR state (True/False) of the newest keyframe that had chroma,
               and `last_ir_at` its time. Only ever moves FORWARD in time. A
               window whose first keyframe is in the other regime, at most
               LIGHT_CARRY_MAX_S later, reports lights_changed. MEASURED why:
               with 4 segments spread over an hour the real dusk switch of
               hiwatch-04eecdd45e2d (16:48Z) fell between hour 16's last sample
               (16:45:17, colour) and hour 17's first (17:00:20, IR), and
               neither window alone could see it.
    """
    edge: dict = field(default_factory=dict)
    view_half: np.ndarray | None = None
    view_at: datetime | None = None
    windows: int = 0
    last_ir: bool | None = None
    last_ir_at: datetime | None = None

    def edge_ref(self, regime: str) -> tuple[float | None, int]:
        hist = self.edge.get(regime) or []
        if len(hist) < BASELINE_MIN:
            return None, len(hist)
        return float(np.median(hist)), len(hist)

    def update(self, h: WindowHealth | None) -> None:
        if h is None:
            return
        self.windows += 1
        healthy = not (h.obscured or h.frozen or h.defocused)
        if healthy:
            for regime, v in h.regime_edge.items():
                hist = self.edge.setdefault(regime, [])
                hist.append(float(v))
                del hist[:-BASELINE_MAX]
        if h.ref_half is not None:
            self.view_half = h.ref_half
            self.view_at = h.ref_half_at
        if (h.ir_last is not None and h.ir_last_at is not None
                and (self.last_ir_at is None or h.ir_last_at > self.last_ir_at)):
            self.last_ir, self.last_ir_at = h.ir_last, h.ir_last_at

    def to_dict(self) -> dict:
        """JSON-safe, so a worker can persist it between runs (~77 KB)."""
        return {
            "v": 2,
            "last_ir": self.last_ir,
            "last_ir_at": _iso(self.last_ir_at) if self.last_ir_at is not None else None,
            "edge": {k: [round(float(x), 5) for x in v] for k, v in self.edge.items()},
            "view_half": (base64.b64encode(np.ascontiguousarray(self.view_half, dtype=np.uint8).tobytes()).decode()
                          if self.view_half is not None else None),
            "view_shape": list(self.view_half.shape) if self.view_half is not None else None,
            "view_at": _iso(self.view_at) if self.view_at is not None else None,
            "windows": int(self.windows),
        }

    @classmethod
    def from_dict(cls, d: dict | None) -> "Baseline":
        if not d:
            return cls()
        if d.get("v") not in (1, 2):          # v1 had no last_ir; it reads as unknown
            raise ValueError(f"unknown baseline version {d.get('v')!r}")
        half = None
        if d.get("view_half"):
            half = np.frombuffer(base64.b64decode(d["view_half"]), dtype=np.uint8).reshape(d["view_shape"]).copy()

        def ts(v):
            return datetime.fromisoformat(v.replace("Z", "+00:00")) if v else None

        last_ir = d.get("last_ir")
        return cls(edge={k: list(v) for k, v in (d.get("edge") or {}).items()},
                   view_half=half, view_at=ts(d.get("view_at")), windows=int(d.get("windows") or 0),
                   last_ir=None if last_ir is None else bool(last_ir),
                   last_ir_at=ts(d.get("last_ir_at")))


class WindowScorer:
    """Accumulates one window keyframe by keyframe; holds no full frames.

    Memory: one 640x360 working frame (for the next pair) plus one 320x180
    frame per keyframe of the CURRENT segment (for its median view), whatever
    the window length.
    """

    def __init__(self, baseline: Baseline | None = None) -> None:
        self.baseline = baseline
        self.stats: list[FrameStats] = []
        self.seg_of: list[int] = []
        self.times: list[datetime | None] = []
        self.pair_rows: list[tuple[float, bool]] = []
        self.seg_start: list[datetime | None] = []
        self.seg_end: list[datetime | None] = []
        self.seg_half: list[np.ndarray | None] = []
        self._cur_halves: list[np.ndarray] = []
        self._prev: np.ndarray | None = None
        self._prev_obscured = True
        self._twins: dict[tuple[int, bytes], list[int]] = {}
        self._textured: list[int] = []
        self.attributed = True

    # -- feeding -----------------------------------------------------------
    def start_segment(self, start: datetime | None = None,
                      duration_s: float | None = None) -> None:
        self._close_segment()
        self.seg_start.append(start)
        self.seg_end.append(start + timedelta(seconds=float(duration_s))
                            if (start is not None and duration_s) else start)

    def add(self, kf: Keyframe) -> FrameStats:
        if not self.seg_start:
            self.start_segment()
        base = decimate(kf.luma)
        st = frame_stats(base, kf.chroma)
        seg = len(self.seg_start) - 1
        start = self.seg_start[seg]
        t = (start + timedelta(seconds=float(kf.t))) if (start is not None and kf.t is not None) else None
        if self._prev is not None:
            ok = not (self._prev_obscured or st.obscured)
            self.pair_rows.append((pair_change(self._prev, base), ok))
        self._prev, self._prev_obscured = base, st.obscured
        n_tex, digests = tile_digests(base)
        i = len(self.stats)
        self._textured.append(n_tex)
        for key in digests:
            self._twins.setdefault(key, []).append(i)
        self.stats.append(st)
        self.seg_of.append(seg)
        self.times.append(t)
        if not st.obscured:
            self._cur_halves.append(_block_mean(base.astype(np.float32), 2).astype(np.uint8))
        return st

    def _close_segment(self) -> None:
        if len(self.seg_half) < len(self.seg_start):
            self.seg_half.append(np.median(np.stack(self._cur_halves), axis=0).astype(np.uint8)
                                 if self._cur_halves else None)
        self._cur_halves = []

    # -- scoring -----------------------------------------------------------
    def result(self) -> WindowHealth | None:
        self._close_segment()
        n = len(self.stats)
        if n == 0:
            return None
        st = self.stats
        base = self.baseline

        # obscured -----------------------------------------------------------
        obsc = [s.obscured for s in st]
        obscured = None if n < MIN_RUN else _longest_run(obsc) >= MIN_RUN
        clear = [i for i in range(n) if not obsc[i]]

        # frozen ---------------------------------------------------------------
        # Evidence 1, decisive: textured tiles with a bit-identical twin in
        # another keyframe. Evidence 2: consecutive pictures that did not change
        # at all. Both only between keyframes that are not obscured, so a black
        # lens cap reads obscured, never frozen.
        twin_hits = [0] * n
        for frames in self._twins.values():
            if len(set(frames)) > 1:
                for i in set(frames):
                    twin_hits[i] += 1
        shares = [twin_hits[i] / self._textured[i] if self._textured[i] else 0.0
                  for i in range(n)]
        ident_frac = max(shares) if n >= 2 else None
        ident_frames = sum(1 for i in range(n) if shares[i] >= FROZEN_IDENT_MIN and not obsc[i])
        ok_pairs = [(c, ok) for c, ok in self.pair_rows if ok]
        like = [ok and c < FROZEN_CHANGE_MAX for c, ok in self.pair_rows]
        frozen_pairs = sum(1 for c, ok in ok_pairs if c < FROZEN_CHANGE_MAX)
        change_min = min((c for c, _ in ok_pairs), default=None)
        if len(clear) < 2:
            frozen = None
        else:
            frozen = (ident_frames >= 2
                      or _longest_run(like) >= FROZEN_MIN_PAIRS)

        # regimes ------------------------------------------------------------
        def regime(s: FrameStats) -> str:
            return "unknown" if s.ir is None else ("ir" if s.ir else "colour")

        chroma_known = [st[i] for i in clear if st[i].chroma is not None]
        ir_all = (None if len(chroma_known) < MIN_RUN
                  else all(s.ir for s in chroma_known))

        # defocused ------------------------------------------------------------
        # Edge width per regime (IR and colour are different optics and noise),
        # against this camera's own history when the state has it, and against
        # the window's own sharpest segment of the same regime otherwise.
        # sharp_ratio = reference width / current width: 1.0 unchanged, lower
        # is blurrier.
        regime_edge: dict[str, float] = {}
        for r in ("colour", "ir", "unknown"):
            v = [st[i].edge for i in clear if regime(st[i]) == r and st[i].edge is not None]
            if v:
                regime_edge[r] = float(np.median(v))
        edges = [st[i].edge for i in clear if st[i].edge is not None]
        edge_px = float(np.median(edges)) if edges else None
        edge_ref = sharp_ratio = None
        sharp_kind = None
        defocused = None
        baseline_n = 0
        if base is not None and regime_edge:
            ratios = []
            for r, v in regime_edge.items():
                ref, k = base.edge_ref(r)
                baseline_n = max(baseline_n, k)
                if ref:
                    ratios.append((ref / v, ref))
            if ratios:
                sharp_ratio, edge_ref = min(ratios)
                sharp_kind = "baseline"
        seg_edge: dict[tuple[str, int], list[float]] = {}
        for i in clear:
            if st[i].edge is not None:
                seg_edge.setdefault((regime(st[i]), self.seg_of[i]), []).append(st[i].edge)
        win_ratio = None
        for r in {k[0] for k in seg_edge}:
            meds = [float(np.median(v)) for (rr, _), v in seg_edge.items() if rr == r]
            if len(meds) >= 2:
                q = min(meds) / max(meds)
                win_ratio = q if win_ratio is None else min(win_ratio, q)
        if sharp_ratio is not None or win_ratio is not None:
            low = [q for q in (sharp_ratio, win_ratio) if q is not None]
            defocused = min(low) < DEFOCUS_RATIO
            if sharp_ratio is None:
                sharp_ratio, sharp_kind = win_ratio, "window"
            elif win_ratio is not None and win_ratio < DEFOCUS_RATIO <= sharp_ratio:
                sharp_ratio, sharp_kind = win_ratio, "window"

        # moved ----------------------------------------------------------------
        views = [(k, make_view(h)) for k, h in enumerate(self.seg_half) if h is not None]
        confident: list[tuple[Shift, str]] = []
        if len(views) >= 2:
            v0 = views[0][1]
            for _, v in views[1:]:
                s = phase_shift(v0, v)
                if s.response >= MOVE_RESP_MIN:
                    confident.append((s, "window"))
        move_ref_at = None
        if base is not None and base.view_half is not None and views:
            # the segment closest in time to the reference
            pick = views[0]
            if base.view_at is not None:
                timed = [(abs((self.seg_start[k] - base.view_at).total_seconds()), (k, v))
                         for k, v in views if self.seg_start[k] is not None]
                if timed:
                    pick = min(timed, key=lambda x: x[0])[1]
            s = phase_shift(make_view(base.view_half), pick[1])
            if s.response >= MOVE_RESP_MIN:
                confident.append((s, "baseline"))
                move_ref_at = base.view_at
        if confident:
            top, kind = max(confident, key=lambda x: x[0].frac)
            moved = top.frac >= MOVE_FRAC
            shift_frac, shift_resp = top.frac, top.response
            move_kind = kind
            if kind != "baseline":
                move_ref_at = self.seg_start[views[0][0]] if views else None
        else:
            moved = shift_frac = shift_resp = move_kind = None

        # lights_changed ------------------------------------------------------
        # Over UNOBSCURED keyframes only: a lens cap is black and black has no
        # chroma, so counting it would report every cover as the IR switching on.
        seq = [(i, st[i].ir) for i in clear if st[i].ir is not None]
        ir_transitions = sum(1 for (_, a), (_, b) in zip(seq, seq[1:]) if a != b)

        # The IR regime at the end of the previous window, from the state. Used
        # only going forward in time and only across a bounded gap, so a worker
        # that scores hours out of order loses this evidence rather than
        # inventing a change.
        carried = False
        if (base is not None and base.last_ir is not None and base.last_ir_at is not None
                and seq and self.times[seq[0][0]] is not None):
            gap = (self.times[seq[0][0]] - base.last_ir_at).total_seconds()
            if 0 < gap <= LIGHT_CARRY_MAX_S and seq[0][1] != base.last_ir:
                carried = True
                ir_transitions += 1

        # A luma STEP is looked for only inside runs of keyframes that are close
        # in time (see luma_step): that is what proves it abrupt.
        def _near(j: int) -> bool:
            a, b = self.times[clear[j - 1]], self.times[clear[j]]
            if a is not None and b is not None:
                return 0.0 <= (b - a).total_seconds() <= LUMA_STEP_MAX_GAP_S
            return self.seg_of[clear[j - 1]] == self.seg_of[clear[j]]

        runs: list[list[int]] = []            # positions into `clear`
        for j in range(len(clear)):
            if j == 0 or not _near(j):
                runs.append([])
            runs[-1].append(j)
        steppable = [r for r in runs if len(r) >= 2 * MIN_RUN]
        step, at = 0.0, None                  # `at` is a position into `clear`
        for r in steppable:
            s, k = luma_step([st[clear[j]].tile_luma for j in r])
            if k is not None and s > step:
                step, at = s, r[k]
        luma_ok = step >= LUMA_STEP_MIN
        if carried:
            lights = True
        else:
            lights = None if len(clear) < 2 else (ir_transitions > 0 or luma_ok)
        step_at = step_after = None
        if carried:
            step_at, step_after = self.times[seq[0][0]], base.last_ir_at
        elif ir_transitions > 0:
            for (i0, a), (i1, b) in zip(seq, seq[1:]):
                if a != b:
                    step_at, step_after = self.times[i1], self.times[i0]
                    break
        elif luma_ok and at is not None:
            step_at, step_after = self.times[clear[at]], self.times[clear[at - 1]]
        ir_last = ir_last_at = None
        for i, v in reversed(seq):
            if self.times[i] is not None:
                ir_last, ir_last_at = v, self.times[i]
                break

        # what the baseline learns --------------------------------------------
        ref_half = ref_at = None
        for k in range(len(self.seg_half) - 1, -1, -1):
            if self.seg_half[k] is not None:
                ref_half, ref_at = self.seg_half[k], self.seg_start[k]
                break

        starts = [t for t in self.seg_start if t is not None]
        ends = [t for t in self.seg_end if t is not None]
        return WindowHealth(
            obscured=obscured, obscured_frac=sum(obsc) / n,
            flat_frac=float(np.median([s.flat_frac for s in st])),
            defocused=None if (obscured and not clear) else defocused,
            edge_px=edge_px, edge_ref=edge_ref, sharp_ratio=sharp_ratio, sharp_ref_kind=sharp_kind,
            moved=moved, shift_frac=shift_frac, shift_resp=shift_resp,
            move_ref_kind=move_kind, move_ref_at=move_ref_at,
            frozen=frozen, change_min=change_min, ident_frac=ident_frac,
            frozen_pairs=frozen_pairs,
            pairs=len(ok_pairs),
            lights_changed=lights, ir_transitions=ir_transitions,
            luma_step=step if steppable else None, step_at=step_at,
            ir=ir_all, keyframes=n, segments=len(self.seg_start),
            seen_s=(sum((e - b).total_seconds() for b, e in zip(self.seg_start, self.seg_end)
                        if b is not None and e is not None) or None),
            baseline_n=baseline_n,
            start=min(starts) if starts else None, end=max(ends) if ends else None,
            attributed=self.attributed,
            step_after=step_after, step_carried=carried,
            regime_edge=regime_edge, ref_half=ref_half, ref_half_at=ref_at,
            ir_last=ir_last, ir_last_at=ir_last_at,
        )


def score_window(segments: Sequence[Sequence[Keyframe]], *,
                 starts: Sequence[datetime | None] | None = None,
                 durations: Sequence[float | None] | None = None,
                 baseline: Baseline | None = None,
                 update_baseline: bool = True) -> WindowHealth | None:
    """Score already-decoded keyframes, grouped by segment.

    Pure apart from `baseline`, which it reads and (unless update_baseline is
    False) then teaches: that is the plugin state, and the only thing a caller
    must carry from one window of a camera to the next.
    """
    sc = WindowScorer(baseline)
    for k, frames in enumerate(segments):
        sc.start_segment(starts[k] if starts else None, durations[k] if durations else None)
        for kf in frames:
            sc.add(kf)
    h = sc.result()
    if update_baseline and baseline is not None:
        baseline.update(h)
    return h


# ---------------------------------------------------------------------------
# Decode: ONE long-lived software decoder per window
# ---------------------------------------------------------------------------
class _TsKeyframes:
    """Keyframe offsets per segment, read off the TS bytes as they stream by.

    One decoder for a whole window means rawvideo frames arrive with no record
    of which segment they came from. The MPEG-TS random_access_indicator marks
    each keyframe's first packet, and its PES header carries the PTS, so the
    feeder can build the attribution table from bytes it is writing anyway.
    """

    def __init__(self) -> None:
        self.flat: list[tuple[int, float | None]] = []
        self.counts: list[int] = []
        self._rem = b""
        self._first: float | None = None

    def start_segment(self) -> None:
        self.counts.append(0)
        self._rem = b""
        self._first = None

    def feed(self, data: bytes) -> None:
        buf = self._rem + bytes(data)
        n = len(buf) // 188
        self._rem = buf[n * 188:]
        if n == 0:
            return
        a = np.frombuffer(buf[: n * 188], dtype=np.uint8).reshape(n, 188)
        start = (a[:, 0] == 0x47) & ((a[:, 1] & 0x40) != 0)
        for i in np.nonzero(start)[0]:
            row = a[i]
            afc = (row[3] >> 4) & 0x3
            if afc == 0x2:
                continue
            has_af = afc == 0x3
            o = 5 + int(row[4]) if has_af else 4
            if o + 14 > 188:
                continue
            p = row[o:o + 14]
            if not (p[0] == 0 and p[1] == 0 and p[2] == 1 and 0xE0 <= p[3] <= 0xEF):
                continue
            pts = None
            if p[7] & 0x80:
                pts = (((int(p[9]) >> 1) & 0x07) << 30 | int(p[10]) << 22
                       | (int(p[11]) >> 1) << 15 | int(p[12]) << 7 | (int(p[13]) >> 1)) / 90000.0
            if self._first is None and pts is not None:
                self._first = pts
            rai = has_af and row[4] > 0 and (row[5] & 0x40)
            if rai:
                off = None
                if pts is not None and self._first is not None:
                    off = (pts - self._first) % (2 ** 33 / 90000.0)
                self.flat.append((len(self.counts) - 1, off))
                self.counts[-1] += 1


@dataclass(frozen=True)
class DecodedKeyframe:
    base: np.ndarray
    chroma: float
    index: int
    segment: int | None
    t: float | None


def decode_keyframes(segments: Iterable[Iterable[bytes] | bytes], *,
                     width: int = WORK_W, height: int = WORK_H,
                     ffmpeg: str = "ffmpeg", timeout_s: float = 300.0,
                     table: _TsKeyframes | None = None) -> Iterator[DecodedKeyframe]:
    """Keyframes of several segments through ONE software decoder."""
    cmd = [ffmpeg, "-hide_banner", "-nostats", "-loglevel", "error",
           "-threads", "1", "-skip_frame", "nokey", "-fflags", "+discardcorrupt",
           "-i", "pipe:0", "-an", "-fps_mode", "passthrough",
           "-vf", f"scale={width}:{height}:flags=neighbor,format=pix_fmts=yuvj420p|yuv420p",
           "-f", "rawvideo", "pipe:1"]
    ybytes = width * height
    fbytes = ybytes * 3 // 2
    tab = table if table is not None else _TsKeyframes()
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)

    def _feed() -> None:
        try:
            for seg in segments:
                tab.start_segment()
                chunks = [seg] if isinstance(seg, (bytes, bytearray, memoryview)) else seg
                for chunk in chunks:
                    tab.feed(chunk)          # parse BEFORE write: the table
                    proc.stdin.write(chunk)  # always leads the decoder
        except (BrokenPipeError, OSError):
            pass
        finally:
            try:
                proc.stdin.close()
            except OSError:
                pass

    feeder = threading.Thread(target=_feed, daemon=True)
    feeder.start()
    idx = 0
    try:
        while True:
            buf = proc.stdout.read(fbytes)
            if not buf or len(buf) < fbytes:
                break
            y = np.frombuffer(buf, dtype=np.uint8, count=ybytes).reshape(height, width)
            uv = np.frombuffer(buf, dtype=np.uint8, offset=ybytes)
            seg, t = tab.flat[idx] if idx < len(tab.flat) else (None, None)
            yield DecodedKeyframe(y, chroma_energy_of(uv), idx, seg, t)
            idx += 1
    finally:
        try:
            proc.stdout.close()
        except OSError:
            pass
        feeder.join(timeout=5.0)
        try:
            proc.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            proc.kill()
        err = b""
        try:
            err = proc.stderr.read() or b""
        except (OSError, ValueError):
            pass
        finally:
            try:
                proc.stderr.close()
            except OSError:
                pass
        if err:
            logger.debug("ffmpeg: %s", err.decode("utf-8", "replace")[:500])


@dataclass(frozen=True)
class SegmentSource:
    """One segment of a window: its bytes (or an iterable of chunks) and when it began."""
    data: Any
    start: datetime | None = None
    duration_s: float | None = None


def analyse(segments: Sequence[SegmentSource], *, baseline: Baseline | None = None,
            update_baseline: bool = True, **kw) -> WindowHealth | None:
    """Decode and score one window. The whole analyser, for a list of TS segments."""
    sc = WindowScorer(baseline)
    tab = _TsKeyframes()
    opened = -1
    n = 0
    for kf in decode_keyframes((s.data for s in segments), table=tab, **kw):
        seg = kf.segment if kf.segment is not None else max(opened, 0)
        while opened < seg:
            opened += 1
            src = segments[opened] if opened < len(segments) else SegmentSource(b"")
            sc.start_segment(src.start, src.duration_s)
        sc.add(Keyframe(kf.base, kf.chroma, kf.t))
        n += 1
    sc.attributed = (n == len(tab.flat))
    h = sc.result()
    if h is not None and not h.attributed:
        logger.warning("camera_health: %d keyframes decoded, %d flagged in the TS; "
                       "segment attribution is approximate", n, len(tab.flat))
    if update_baseline and baseline is not None:
        baseline.update(h)
    return h
