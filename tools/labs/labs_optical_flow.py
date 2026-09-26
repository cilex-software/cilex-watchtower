"""B5 optical_flow: which way things moved, how fast, and whether as one body.

WHAT ONE BURST CLAIMS, and each number is one claim (metrics keys):

    dir_deg, dir_label  The MODE of the moving pixels' directions, in IMAGE
                        terms: 0 = right, 90 = up the frame, counter-clockwise;
                        the 8-way label is its 45-degree sector. Not a compass
                        bearing: the analyser does not know where the camera
                        faces.
    dir_share           Share of moving pixels inside that sector. 1.0 is one
                        direction; 0.125 is uniform.
    speed_fw_s          Median speed of the moving pixels in FRAME WIDTHS per
                        second, so main (2560 px) and sub (640 px) agree.
    speed_p90_fw_s      Its 90th percentile.
    coherence           Mean, over pairs, of |sum of unit vectors| / count: a
                        rigid body is ~1, a group walking apart is ~0.
    coherence_net       The same over the whole burst at once: a group all
                        going one way stays high, back-and-forth goes to 0.
    moving_frac         Steady moving pixels / all pixels examined.
    clutter_frac        Moving pixels that were NOT steady (see below): foliage,
                        insects at a lamp, IR speckle. Reported, never used for
                        direction or speed.
    steady_share        steady / all moving samples.
    min_speed_fw_s      The floor (0.5 px per pair): slower is invisible.
    speed_ceiling_fw_s  Above roughly this, speeds read LOW.

It claims no class, no count, no box and no scene light: flow sees that pixels
moved, not what moved, and the moving region pooled over ten seconds is a
path, not an object.

THE DECODE. Keyframes are ~4 s apart (GOP ~60 at 15 fps), far too far apart
for flow. So each sampled segment yields one BURST: its first 10 s, decoded by
ONE software ffmpeg (`-threads 1`, never `-hwaccel`: the shared iGPU wedges
at ~16 VA-API contexts created at once), resampled to 5 fps and scaled to
320 px wide with the aspect kept (sub streams on this fleet are 16:9 AND 4:3).
The burst is the analysis window: the answer needs consecutive frames, and ten
seconds of them fit inside one 30 s segment, so one decoder per burst is one
decoder per window. Input is a path, bytes, or an iterable of chunks streamed
into stdin; the scorer holds one previous frame and never a flow field.

WHAT THE ANSWER NEEDS, measured against an independent reference (sparse KLT
tracks at 640 px over every source frame, 1 s windows, 4 sub segments of a
busy entrance): at 5 fps and 320 px all 45 reference-moving windows were
detected, 3 of 50 reference-still ones flagged, direction error median 3 deg
(84% in the same 8-way sector), speed ratio median 1.11. 160 px widened the
direction tail (p90 62 deg against 49); 640 px narrowed it (25 deg) at 4.3x
the per-pair CPU (44.7 ms against 10.4). 3 fps scored like 5 fps on this data
but would drop the speed ceiling to 0.075 fw/s, inside fast walking. Sub
agrees with main (22 aligned bursts: moving on both or neither in all 22;
speed ratio median 1.02, direction error median 0.5 deg) at about 0.4x the
CPU, so the sub stream is the one to analyse.

THREE THINGS THAT WERE NOT SAFE TO ASSUME, now measured:

  * PER PAIR, clutter IS an object. The first revision called every IR burst
    of camera 10.8 "moving" (21 of 21 after the colour-to-IR switch, 12 of 12
    at 02:00) and the hydrangea at 1.1 by day: rigid, coherent, compact blobs,
    each pair of frames indistinguishable from a walker. Blob size does not
    separate them (largest component 253 px on IR clutter, 340 on walkers).
    What separates them is where they GO: over the burst a walker pushes a
    patch of the image one way, a swinging bush and an insect at a lamp go
    back and forth. So statistics are pooled per cell (a tenth of the width),
    and only STEADY cells (|sum v| / sum |v| >= 0.5, active in >= 3 pairs)
    feed direction, speed and coherence. Steady share measured 0.91-1.00 on
    object bursts and 0.00-0.22 on clutter; a burst needs >= 0.4. After it:
    night_ir 0 of 12 bursts moving, dusk_switch 0 of 30 (both were all or
    nearly all "moving" before). The price, also measured: a burst where
    clutter outweighs a real object is dropped (a walker right at the door
    beside the bush read steady_share 0.25). And the pairs around an exposure
    switch leak past the global test, so they are quarantined with it
    (QUARANTINE_PAIRS).
  * Farneback's spread halo is not motion. Its window smears an object's flow
    onto the static background around it at smaller magnitude, which doubled
    the moving area and pulled median speed 8% low on a synthetic block. A
    pixel counts only if warping by its flow explains the change better than
    no motion (`residual_gate`).
  * FAST MOTION READS LOW. Exact to 8 px per pair on fine texture (12 and 16
    on coarser); a 16 px per pair block read 5.7. At 5 fps and 320 px that is
    0.125 fw/s, which walkers never reach and a car near the camera does (the
    reference read one at 0.28-0.31 fw/s; this read 0.16-0.20). Published as
    `speed_ceiling_fw_s` rather than hidden.

Cost and the headline validation are in
docs/findings/2026-09-26-labs-optical_flow.md.
"""
from __future__ import annotations

import logging
import math
import os
import subprocess
import threading
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable, Iterator

import numpy as np

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# the decode: a short burst of CONSECUTIVE frames, not keyframes
# ---------------------------------------------------------------------------
#: Frames per second handed to the flow. The source is 15 fps.
DEFAULT_FPS = 5.0
#: Width the frames are scaled to, aspect ratio PRESERVED (see decode_burst).
DEFAULT_WIDTH = 320
#: Seconds of footage per burst, taken from the START of a segment.
DEFAULT_BURST_S = 10.0

# ---------------------------------------------------------------------------
# what counts as moving
# ---------------------------------------------------------------------------
#: Flow magnitude, in pixels per frame pair AT THE ANALYSIS SCALE, below which a
#: pixel is not moving.
MOVE_THRESHOLD_PX = 0.5
#: Pixels this close to the frame edge are never counted.
BORDER_PX = 8
#: The motion-compensated residual test (residual_gate).
RESIDUAL_MARGIN = 2.0
RESIDUAL_BOX = 3
#: A pair counts as ACTIVE when at least this many pixels moved in it.
MIN_PAIR_PIXELS = 20
#: A burst reports direction, speed and coherence only above this support...
MIN_MOVING_SAMPLES = 100
#: ...and only when motion was present in at least this many pairs.
MIN_ACTIVE_PAIRS = 3
#: A pair where this much of the frame moved INCOHERENTLY is a global
#: disturbance (lights, exposure, IR switch), not an object.
GLOBAL_FRAC = 0.2
GLOBAL_COHERENCE = 0.5
#: A pair where this much of the frame moved, however coherently, is the
#: camera moving or the whole image changing.
SHAKE_FRAC = 0.6

# ---------------------------------------------------------------------------
# steady against clutter: per-CELL temporal consistency over the burst
# ---------------------------------------------------------------------------
#: Cell side as a fraction of the frame width: 32 px at 320, so the grid is the
#: same 10 x 6 cells at any analysis width.
CELL_FRAC = 0.1
#: A cell is ACTIVE in a pair when at least this many of its pixels moved.
CELL_PAIR_SAMPLES = 5
#: A cell is judged only with at least this much evidence...
CELL_MIN_SAMPLES = 10
CELL_MIN_PAIRS = 3
#: ...and is STEADY when |sum of its flow vectors| / sum of their lengths over
#: the burst reaches this. Something translating through the cell scores near
#: 1; foliage swinging back and forth, insects at a lamp and IR speckle score
#: near 0 (count-weighted cell medians measured 0.02-0.31 on 8 clutter bursts,
#: 0.49-0.97 on 6 object bursts, 32 px cells).
CELL_CONSISTENCY = 0.5
#: A burst reports a direction only when at least this share of its moving
#: samples lies in steady cells. Measured on the same 14 bursts: objects
#: 0.91-1.00, clutter 0.00-0.22.
STEADY_SHARE_MIN = 0.4
#: Displacement per pair that Farneback here still reads correctly. Measured on
#: a synthetic block at 320x180: exact to 8 px/pair on fine texture, to 12 px
#: on medium and 16 px on coarse; beyond that it reads LOW (a 20 px/pair fine
#: block read 5.0 and lost its direction). A larger window made it worse.
SPEED_CEILING_PX = 8.0
#: Pairs either side of a GLOBAL pair that are dropped too. A colour-to-IR
#: switch on camera 10.8 took ~1 s: global pairs at 6.4, 6.6, 7.0 and 7.2 s,
#: and between and after them pairs that moved 2-7% of the frame at coherence
#: 0.25-0.52, under the global test (measured, dusk_switch). Before this, the
#: burst holding the switch reported a direction. 2 pairs = 0.4 s at 5 fps.
QUARANTINE_PAIRS = 2

#: cv2.OPTFLOW_FARNEBACK_GAUSSIAN, written as its value so the module imports
#: without OpenCV (the pure parts are usable and testable on their own). A
#: test pins it to cv2's constant.
_FARNEBACK_GAUSSIAN = 256
#: Farneback parameters: OpenCV's sample values with a GAUSSIAN window instead
#: of the box. Measured on a 40 px textured block at 320x180: the box window
#: reads 0.94-0.96 of the true displacement from 1 to 8 px per pair, the
#: Gaussian 0.99-1.00, for 9.6 ms per pair against 8.2. `levels` above 3 is a
#: no-op here: OpenCV stops building the pyramid below 32 px, and a 180 px
#: tall frame reaches that after three levels (levels=5 measured identical).
FARNEBACK = dict(pyr_scale=0.5, levels=3, winsize=15, iterations=3,
                 poly_n=5, poly_sigma=1.2, flags=_FARNEBACK_GAUSSIAN)

_SPEED_BIN_PX = 0.02
_SPEED_NBINS = 4000          # 80 px per pair; beyond that is the overflow bin

#: 8-way labels in IMAGE terms, counter-clockwise from "right".
DIR_LABELS = ("right", "up_right", "up", "up_left",
              "left", "down_left", "down", "down_right")

#: Kept in step with routers/labs.py SCENE_LIGHT (migration 0084).
SCENE_LIGHT = ("day", "dusk", "night", "ir", "unknown")


class DecodeError(RuntimeError):
    """The decoder produced nothing, or had to be killed."""


def direction_label(deg: float) -> str:
    """0 = right, 90 = up (image up, not north), counter-clockwise."""
    return DIR_LABELS[int(((deg % 360.0) + 22.5) // 45.0) % 8]


# ---------------------------------------------------------------------------
# the result
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class BurstFlow:
    """One burst's motion. Frozen: this is a measurement.

    Every direction, speed and coherence figure comes from STEADY cells only
    (see CELL_CONSISTENCY); `clutter_frac` is what moved and was left out.
    """

    frames: int
    pairs: int
    fps: float
    width: int
    height: int
    threshold_px: float
    #: Steady moving pixels / usable pixels (pairs x pixels, global pairs out).
    moving_frac: float
    moving_frac_peak: float
    active_pairs: int
    global_pairs: int
    #: Moving samples in steady cells: what every statistic below rests on.
    moving_samples: int
    floor_px: float
    #: Pairs next to a global pair, dropped with it (QUARANTINE_PAIRS).
    quarantined_pairs: int = 0
    #: Moving pixels in NON-steady cells / usable pixels. Foliage, insects at
    #: a lamp, IR speckle. Reported so a quiet-looking burst with a busy tree
    #: is visibly different from a still one.
    clutter_frac: float = 0.0
    #: Steady samples / all moving samples; None when nothing moved at all.
    steady_share: float | None = None
    dir_deg: float | None = None
    dir_share: float | None = None
    speed_fw_s: float | None = None
    speed_p90_fw_s: float | None = None
    coherence: float | None = None
    coherence_net: float | None = None

    @property
    def span_s(self) -> float:
        """Seconds of footage the frames stand for (each frame is 1/fps)."""
        return self.frames / self.fps if self.fps else 0.0

    @property
    def dir_label(self) -> str | None:
        return None if self.dir_deg is None else direction_label(self.dir_deg)

    @property
    def min_speed_fw_s(self) -> float:
        """The threshold in physical units: slower than this is invisible."""
        return self.threshold_px * self.fps / self.width if self.width else 0.0

    @property
    def speed_ceiling_fw_s(self) -> float:
        """Above roughly this, speeds read LOW (SPEED_CEILING_PX). A speed or
        p90 near it is a lower bound, not a measurement."""
        return SPEED_CEILING_PX * self.fps / self.width if self.width else 0.0

    @property
    def floor_fw_s(self) -> float:
        return self.floor_px * self.fps / self.width if self.width else 0.0

    @property
    def moving(self) -> bool:
        """True when the burst carries a defined direction and speed."""
        return self.dir_deg is not None

    def as_metrics(self) -> dict:
        """The `metrics` payload: scalars only, lowercase slug keys, <= 24."""
        m = {
            "fps": round(self.fps, 3),
            "width": self.width,
            "pairs": self.pairs,
            "span_s": round(self.span_s, 2),
            "min_speed_fw_s": round(self.min_speed_fw_s, 5),
            "speed_ceiling_fw_s": round(self.speed_ceiling_fw_s, 4),
            "moving_frac": round(self.moving_frac, 5),
            "moving_frac_peak": round(self.moving_frac_peak, 4),
            "clutter_frac": round(self.clutter_frac, 5),
            "active_s": round(self.active_pairs / self.fps, 2) if self.fps else 0.0,
            "global_pairs": self.global_pairs,
            "quarantined_pairs": self.quarantined_pairs,
            "floor_fw_s": round(self.floor_fw_s, 5),
        }
        if self.steady_share is not None:
            m["steady_share"] = round(self.steady_share, 3)
        if self.moving:
            m.update(
                dir_deg=round(self.dir_deg, 1),
                dir_label=self.dir_label,
                dir_share=round(self.dir_share, 3),
                speed_fw_s=round(self.speed_fw_s, 4),
                speed_p90_fw_s=round(self.speed_p90_fw_s, 4),
                coherence=round(self.coherence, 3),
                coherence_net=round(self.coherence_net, 3),
            )
        return m


# ---------------------------------------------------------------------------
# accumulation: per cell and per pair, pooled over a burst, no flow field kept
# ---------------------------------------------------------------------------
class FlowAccumulator:
    """Pools a burst's flow per CELL in bounded memory.

    Holds, per cell of a fixed grid (CELL_FRAC of the width), a direction
    histogram (360 bins), a speed histogram (4001 bins), the vector and length
    sums, and, per pair, three numbers per cell. Never a flow field: a 10 s
    burst at 5 fps is 49 fields of 460 KB. At 320 px the grid is 10 x 6 cells
    and the histograms total 2.1 MB whatever the burst length; the per-pair
    part grows by 1.2 KB a pair.

    WHY PER CELL: which cells count is decided only when the burst is over
    (`finish`), because steadiness is a property of the whole burst. Keeping
    the statistics per cell is what lets that decision be made after one
    streaming pass.
    """

    def __init__(self, threshold_px: float = MOVE_THRESHOLD_PX,
                 cell_px: int | None = None):
        self.threshold_px = float(threshold_px)
        self.cell_px = cell_px
        self.pairs = 0
        self.global_pairs = 0
        self.pixels = 0
        self.floors: list[float] = []
        self.shape: tuple[int, int] | None = None
        self.ncell = 0
        self._cid: np.ndarray | None = None
        # per cell, over the burst
        self.c_n: np.ndarray | None = None
        self.c_k: np.ndarray | None = None
        self.c_vx: np.ndarray | None = None
        self.c_vy: np.ndarray | None = None
        self.c_len: np.ndarray | None = None
        self.c_dir: np.ndarray | None = None
        self.c_speed: np.ndarray | None = None
        # per non-global pair with motion, per cell
        self.p_n: list[np.ndarray] = []
        self.p_ux: list[np.ndarray] = []
        self.p_uy: list[np.ndarray] = []
        # a pair's contribution waits QUARANTINE_PAIRS pairs before it counts
        self._pending: list[tuple] = []
        self._globals: list[int] = []

    def _grid(self, h: int, w: int) -> None:
        if self.shape is not None:
            if self.shape != (h, w):
                raise ValueError(f"flow shape changed from {self.shape} to {(h, w)}")
            return
        c = int(self.cell_px or max(4, round(CELL_FRAC * w)))
        self.cell_px = c
        nx, ny = -(-w // c), -(-h // c)
        self.shape, self.ncell = (h, w), nx * ny
        yy, xx = np.mgrid[0:h, 0:w]
        self._cid = ((yy // c) * nx + xx // c).astype(np.int64)
        n = self.ncell
        self.c_n = np.zeros(n, np.int64)
        self.c_k = np.zeros(n, np.int64)
        self.c_vx = np.zeros(n)
        self.c_vy = np.zeros(n)
        self.c_len = np.zeros(n)
        self.c_dir = np.zeros((n, 360), np.int64)
        self.c_speed = np.zeros((n, _SPEED_NBINS + 1), np.int64)

    def add(self, flow: np.ndarray, keep: np.ndarray | None = None) -> None:
        """Fold one pair's flow field (H, W, 2) in. `keep` narrows "moving"."""
        h, w = flow.shape[:2]
        self._grid(h, w)
        fx = flow[..., 0]
        fy = flow[..., 1]
        mag = np.sqrt(fx * fx + fy * fy)
        self.pairs += 1
        self.pixels += mag.size
        self.floors.append(float(np.median(mag)))
        m = mag > self.threshold_px
        if keep is not None:
            m &= keep
        n = int(np.count_nonzero(m))
        if n == 0:
            return
        mm = mag[m]
        vx = fx[m]
        vy = -fy[m]                 # image y points DOWN; up must be +90 deg
        ux = vx / mm
        uy = vy / mm
        frac = n / mag.size
        idx = self.pairs - 1
        if frac > SHAKE_FRAC or (frac > GLOBAL_FRAC
                                 and math.hypot(float(ux.sum()), float(uy.sum())) / n
                                 < GLOBAL_COHERENCE):
            # Not object motion. Counted, excluded from every statistic, and
            # so are the QUARANTINE_PAIRS pairs either side of it.
            self.global_pairs += 1
            self._globals.append(idx)
            self._pending = [e for e in self._pending
                             if e[0] < idx - QUARANTINE_PAIRS]
            self._commit(idx)
            return
        self._pending.append((idx, self._cid[m], vx, vy, mm, ux, uy))
        self._commit(idx)

    def _commit(self, now: int | None) -> None:
        """Fold in pending pairs no global pair can reach any more. `now`
        None means the burst is over: everything left is committed."""
        keep = []
        last_g = self._globals[-1] if self._globals else None
        for e in self._pending:
            if now is not None and e[0] > now - QUARANTINE_PAIRS:
                keep.append(e)
            elif last_g is None or abs(e[0] - last_g) > QUARANTINE_PAIRS:
                self._fold(*e[1:])
        self._pending = keep

    def _fold(self, cid, vx, vy, mm, ux, uy) -> None:
        nc = self.ncell
        cn = np.bincount(cid, minlength=nc)
        self.c_n += cn
        self.c_k += cn >= CELL_PAIR_SAMPLES
        self.c_vx += np.bincount(cid, vx, nc)
        self.c_vy += np.bincount(cid, vy, nc)
        self.c_len += np.bincount(cid, mm, nc)
        ang = (np.degrees(np.arctan2(uy, ux)) % 360.0).astype(np.int64) % 360
        self.c_dir += np.bincount(cid * 360 + ang, minlength=nc * 360).reshape(nc, 360)
        sb = np.minimum((mm / _SPEED_BIN_PX).astype(np.int64), _SPEED_NBINS)
        self.c_speed += np.bincount(cid * (_SPEED_NBINS + 1) + sb,
                                    minlength=nc * (_SPEED_NBINS + 1)
                                    ).reshape(nc, _SPEED_NBINS + 1)
        self.p_n.append(cn.astype(np.int32))
        self.p_ux.append(np.bincount(cid, ux, nc))
        self.p_uy.append(np.bincount(cid, uy, nc))

    @property
    def quarantined_pairs(self) -> int:
        """Non-global pairs within QUARANTINE_PAIRS of a global one."""
        g = set(self._globals)
        return sum(1 for i in range(self.pairs) if i not in g
                   and any(abs(i - j) <= QUARANTINE_PAIRS for j in g))

    def steady_cells(self) -> np.ndarray:
        """Boolean per cell: enough evidence, and moving one way over the burst."""
        if self.c_n is None:
            return np.zeros(0, bool)
        cons = np.zeros(self.ncell)
        ok = self.c_len > 0
        cons[ok] = np.hypot(self.c_vx[ok], self.c_vy[ok]) / self.c_len[ok]
        return ((self.c_n >= CELL_MIN_SAMPLES) & (self.c_k >= CELL_MIN_PAIRS)
                & (cons >= CELL_CONSISTENCY))


def _dominant_direction(hist: np.ndarray) -> tuple[float, float]:
    """The MODE of the direction histogram, refined; and its share.

    A mode, not a mean: two groups walking in opposite directions have a mean
    direction nobody moved in. The peak is found on a lightly smoothed circular
    histogram and refined by the circular mean of +-30 deg around it. The share
    is the fraction of moving pixels within +-22.5 deg of the answer, i.e.
    inside its own 8-way sector: 1.0 is one direction, 0.125 is uniform.
    """
    total = float(hist.sum())
    k = np.array([1, 2, 3, 2, 1], dtype=np.float64)
    ext = np.concatenate([hist[-2:], hist, hist[:2]]).astype(np.float64)
    sm = np.convolve(ext, k, mode="valid")
    peak = int(np.argmax(sm))
    idx = np.arange(peak - 30, peak + 31) % 360
    w = hist[idx].astype(np.float64)
    ang = np.radians(idx + 0.5)
    deg = math.degrees(math.atan2(float((w * np.sin(ang)).sum()),
                                  float((w * np.cos(ang)).sum()))) % 360.0
    diff = (np.arange(360) + 0.5 - deg + 180.0) % 360.0 - 180.0
    share = float(hist[np.abs(diff) <= 22.5].sum()) / total if total else 0.0
    return deg, share


def _hist_quantile(hist: np.ndarray, q: float) -> float:
    c = np.cumsum(hist)
    i = int(np.searchsorted(c, q * c[-1]))
    return (min(i, _SPEED_NBINS) + 0.5) * _SPEED_BIN_PX


def finish(acc: FlowAccumulator, *, fps: float, width: int, height: int,
           frames: int) -> BurstFlow | None:
    """Reduce an accumulator to a BurstFlow. None when there was no pair."""
    if acc.pairs < 1:
        return None
    acc._commit(None)
    quarantined = acc.quarantined_pairs
    per_pair = acc.pixels / acc.pairs
    usable = per_pair * (acc.pairs - acc.global_pairs - quarantined)
    steady = acc.steady_cells()
    total = int(acc.c_n.sum()) if acc.c_n is not None else 0
    moving = int(acc.c_n[steady].sum()) if total else 0
    if acc.p_n:
        pn = np.stack(acc.p_n)[:, steady].sum(axis=1)
        pux = np.stack(acc.p_ux)[:, steady].sum(axis=1)
        puy = np.stack(acc.p_uy)[:, steady].sum(axis=1)
    else:
        pn = pux = puy = np.zeros(0)
    active = int(np.count_nonzero(pn >= MIN_PAIR_PIXELS))
    base = dict(frames=frames, pairs=acc.pairs, fps=float(fps), width=int(width),
                height=int(height), threshold_px=acc.threshold_px,
                moving_frac=(moving / usable) if usable else 0.0,
                moving_frac_peak=(float(pn.max()) / per_pair) if len(pn) else 0.0,
                active_pairs=active, global_pairs=acc.global_pairs,
                quarantined_pairs=quarantined,
                moving_samples=moving, floor_px=float(np.median(acc.floors)),
                clutter_frac=((total - moving) / usable) if usable else 0.0,
                steady_share=(moving / total) if total else None)
    if (moving < MIN_MOVING_SAMPLES or active < MIN_ACTIVE_PAIRS
            or moving / total < STEADY_SHARE_MIN):
        return BurstFlow(**base)
    deg, share = _dominant_direction(acc.c_dir[steady].sum(axis=0))
    speed = acc.c_speed[steady].sum(axis=0)
    k = fps / float(width)
    return BurstFlow(
        **base, dir_deg=deg, dir_share=share,
        speed_fw_s=_hist_quantile(speed, 0.5) * k,
        speed_p90_fw_s=_hist_quantile(speed, 0.9) * k,
        coherence=float(np.hypot(pux, puy).sum()) / moving,
        coherence_net=math.hypot(float(pux.sum()), float(puy.sum())) / moving,
    )


# ---------------------------------------------------------------------------
# flow and the moving-pixel gate
# ---------------------------------------------------------------------------
def flow_pair(prev: np.ndarray, cur: np.ndarray,
              params: dict | None = None) -> np.ndarray:
    """Dense Farneback flow from `prev` to `cur`, (H, W, 2) float32, px/pair."""
    import cv2
    p = FARNEBACK if params is None else params
    return cv2.calcOpticalFlowFarneback(
        prev, cur, None, p["pyr_scale"], p["levels"], p["winsize"],
        p["iterations"], p["poly_n"], p["poly_sigma"], p["flags"])


_GRID: dict = {}


def residual_gate(prev: np.ndarray, cur: np.ndarray, flow: np.ndarray,
                  margin: float = RESIDUAL_MARGIN,
                  box: int = RESIDUAL_BOX) -> np.ndarray:
    """True where warping by the flow explains the change better than no motion.

    |cur(x + v) - prev(x)| must be smaller than |cur(x) - prev(x)| by `margin`
    grey levels (both box-averaged). A pixel of static background next to a
    moving object gets a smoothed share of the object's flow from Farneback's
    window; warping it by that flow makes the match WORSE, so it is dropped.
    """
    import cv2
    h, w = prev.shape
    g = _GRID.get((h, w))
    if g is None:
        g = np.meshgrid(np.arange(w, dtype=np.float32),
                        np.arange(h, dtype=np.float32))
        _GRID.clear()
        _GRID[(h, w)] = g
    a = prev.astype(np.float32)
    b = cur.astype(np.float32)
    warped = cv2.remap(b, g[0] + flow[..., 0], g[1] + flow[..., 1],
                       cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    r_static = cv2.blur(cv2.absdiff(b, a), (box, box))
    r_comp = cv2.blur(cv2.absdiff(warped, a), (box, box))
    return (r_static - r_comp) > margin


def pair_into(acc: FlowAccumulator, prev: np.ndarray, cur: np.ndarray, *,
              params: dict | None = None, gate: str = "residual",
              border: int = BORDER_PX) -> None:
    """Flow for one pair, gated and border-cropped, folded into `acc`."""
    flow = flow_pair(prev, cur, params)
    keep = residual_gate(prev, cur, flow) if gate == "residual" else None
    if border:
        flow = flow[border:-border, border:-border]
        keep = None if keep is None else keep[border:-border, border:-border]
    acc.add(flow, keep)


def score_frames(frames: Iterable[np.ndarray], *, fps: float,
                 threshold_px: float = MOVE_THRESHOLD_PX,
                 params: dict | None = None, gate: str = "residual",
                 border: int = BORDER_PX) -> BurstFlow | None:
    """Score consecutive greyscale frames taken `1/fps` apart. None if < 2.

    Streams: only the previous frame is held, so a burst of any length costs
    the same memory (plus 1.2 KB of per-cell bookkeeping a pair).

    The cell side is CELL_FRAC of the FULL frame width (32 px at 320), fixed
    from the first frame, so the grid is the same at every analysis width.
    """
    acc: FlowAccumulator | None = None
    prev = None
    n = 0
    shape = (0, 0)
    for f in frames:
        n += 1
        shape = f.shape
        if acc is None:
            acc = FlowAccumulator(threshold_px,
                                  cell_px=max(4, round(CELL_FRAC * shape[1])))
        if prev is not None:
            pair_into(acc, prev, f, params=params, gate=gate, border=border)
        prev = f
    if n < 2:
        return None
    return finish(acc, fps=fps, width=shape[1], height=shape[0], frames=n)


# ---------------------------------------------------------------------------
# the decoder
# ---------------------------------------------------------------------------
def _read_exact(stream, n: int) -> bytes:
    chunks, want = [], n
    while want > 0:
        c = stream.read(want)
        if not c:
            break
        chunks.append(c)
        want -= len(c)
    return b"".join(chunks)


def _read_line(stream, limit: int = 256) -> bytes:
    out = bytearray()
    while len(out) < limit:
        c = stream.read(1)
        if not c:
            break
        out += c
        if c == b"\n":
            break
    return bytes(out)


def decode_burst(source, *, burst_s: float = DEFAULT_BURST_S,
                 fps: float = DEFAULT_FPS, width: int = DEFAULT_WIDTH,
                 start_s: float = 0.0, ffmpeg: str = "ffmpeg",
                 timeout_s: float = 120.0) -> Iterator[np.ndarray]:
    """Greyscale frames of one burst from ONE software decoder.

    `source` is a file path, raw MPEG-TS bytes, or an iterable of byte chunks
    (streamed into the decoder's stdin by a thread, never joined in memory).
    """
    if fps <= 0 or burst_s <= 0:
        raise ValueError("fps and burst_s must be positive")
    if width < 32 or width % 2:
        raise ValueError("width must be an even number >= 32")
    is_path = isinstance(source, (str, os.PathLike))
    cmd = [ffmpeg, "-hide_banner", "-nostats", "-loglevel", "error",
           "-threads", "1", "-fflags", "+discardcorrupt",
           "-i", os.fspath(source) if is_path else "pipe:0",
           "-an", "-sn", "-dn"]
    if start_s > 0:
        # OUTPUT-side, i.e. decode and discard. Input-side seeking on these
        # segments with -t and the fps filter returned 0 frames at 5.4 s and
        # 8.4 s and 7 of 8 at 11.4 s on one sub segment (measured); output-side
        # returned 8 of 8 every time. It costs the decode of what is skipped,
        # which is why production bursts start at 0.
        cmd += ["-ss", f"{start_s:.3f}"]
    cmd += ["-t", f"{burst_s:.3f}",
            "-vf", f"fps={fps:g},scale={int(width)}:-2:flags=area,format=gray",
            "-fps_mode", "passthrough", "-f", "yuv4mpegpipe", "pipe:1"]
    proc = subprocess.Popen(cmd, stdin=None if is_path else subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    err_tail = bytearray()

    def _drain_stderr() -> None:
        try:
            for line in iter(proc.stderr.readline, b""):
                err_tail.extend(line)
                if len(err_tail) > 4096:
                    del err_tail[:-4096]
        except (OSError, ValueError):
            pass

    def _feed() -> None:
        try:
            if isinstance(source, (bytes, bytearray, memoryview)):
                proc.stdin.write(source)
            else:
                for chunk in source:
                    proc.stdin.write(chunk)
        except (BrokenPipeError, OSError, ValueError):
            pass            # decoder stopped reading: -t reached, or it died
        finally:
            try:
                proc.stdin.close()
            except OSError:
                pass

    threads = [threading.Thread(target=_drain_stderr, daemon=True)]
    if not is_path:
        threads.append(threading.Thread(target=_feed, daemon=True))
    for t in threads:
        t.start()
    killed = threading.Event()

    def _kill() -> None:
        killed.set()
        proc.kill()

    timer = threading.Timer(timeout_s, _kill)
    timer.daemon = True
    timer.start()
    n = 0
    try:
        header = _read_line(proc.stdout)
        if header.startswith(b"YUV4MPEG2"):
            toks = header.split()
            w = int(next(t[1:] for t in toks if t.startswith(b"W")))
            h = int(next(t[1:] for t in toks if t.startswith(b"H")))
            size = w * h
            while True:
                line = _read_line(proc.stdout)
                if not line.startswith(b"FRAME"):
                    break
                buf = _read_exact(proc.stdout, size)
                if len(buf) < size:
                    break
                n += 1
                yield np.frombuffer(buf, dtype=np.uint8).reshape(h, w)
    finally:
        timer.cancel()
        try:
            proc.stdout.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        for t in threads:
            t.join(timeout=2.0)
        try:
            proc.stderr.close()
        except OSError:
            pass
    tail = bytes(err_tail).decode("utf-8", "replace")[-400:]
    if killed.is_set():
        raise DecodeError(f"decoder killed after {timeout_s:.0f} s ({n} frames)")
    if n == 0:
        raise DecodeError(f"decoder produced no frames (exit {proc.returncode})"
                          + (f": {tail}" if tail else ""))
    if tail:
        logger.debug("ffmpeg: %s", tail)


def analyse_burst(source, *, burst_s: float = DEFAULT_BURST_S,
                  fps: float = DEFAULT_FPS, width: int = DEFAULT_WIDTH,
                  threshold_px: float = MOVE_THRESHOLD_PX,
                  params: dict | None = None, gate: str = "residual",
                  border: int = BORDER_PX, **kw) -> BurstFlow | None:
    """Decode one burst and score it. The whole analyser for one segment."""
    return score_frames(
        decode_burst(source, burst_s=burst_s, fps=fps, width=width, **kw),
        fps=fps, threshold_px=threshold_px, params=params, gate=gate,
        border=border)


# ---------------------------------------------------------------------------
# the wire
# ---------------------------------------------------------------------------
def _iso(t: datetime) -> str:
    return t.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def to_observation(result: BurstFlow | None, *, start_time: datetime,
                   offset_s: float = 0.0, segment_id: str | None = None,
                   stream_type: str | None = None,
                   scene_light: str | None = None) -> dict | None:
    """One ObservationIn dict for a burst that moved; None for one that did not.

    `start_time` is the SEGMENT's start (timezone-aware); the burst covers
    [start + offset_s, start + offset_s + span_s).
    """
    if result is None or not result.moving:
        return None
    if start_time.tzinfo is None:
        raise ValueError("start_time has no offset; refusing to guess its zone")
    if scene_light is not None and scene_light not in SCENE_LIGHT:
        raise ValueError(f"unknown scene_light {scene_light!r}")
    t0 = start_time + timedelta(seconds=float(offset_s))
    t1 = t0 + timedelta(seconds=result.span_s)
    m = result.as_metrics()
    if segment_id is not None:
        m["segment_id"] = str(segment_id)
    if stream_type is not None:
        m["stream_type"] = str(stream_type)
    obs = {"start_time": _iso(t0), "end_time": _iso(t1), "metrics": m}
    if scene_light is not None:
        obs["scene_light"] = scene_light
    return obs
