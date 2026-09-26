"""B9 perceptual hash: a 64-bit DCT fingerprint per keyframe, the Hamming distance
to the previous keyframe, and a per-window summary built for the register's two
uses: collapsing "nothing changed for six hours" into a few rows, and finding
the same scene again across hours.

Every number below was MEASURED on 2026-09-26 over the Labs sample set plus
three fetched sub-stream hours (one indoor still night, one IR rooftop night,
one busy daytime entrance); method and tables are in
docs/findings/2026-09-26-labs-perceptual_hash.md. Anything not measured says so.

WHAT IT COMPUTES, and each output is one claim:

    hash          per keyframe, 16 lowercase hex. "The coarse (8x8 lowest
                  frequencies of a 32x32 greyscale) layout of light in this frame."
    dist_prev     Hamming distance to the previous kept keyframe, 0..64, always
                  EVEN (see `hash_from_coeffs`). "How much that layout moved."
    rep_hash      per window, the medoid keyframe's hash. "What this window
                  usually looked like." Compared across windows and hours by the
                  server. In the two still night hours consecutive windows'
                  representatives differed by 0 (117 of 119 steps) or 2; one
                  camera in one lighting regime read 0-4 between main and sub;
                  different cameras never came closer than 24 (208 window
                  representatives, 6 cameras).
    odd_hash      the keyframe least like rep_hash, and its distance. "The most
                  unusual moment", e.g. a moth in front of an IR lamp read 12.
    nochange_*    intervals with dist <= NOCHANGE_THRESHOLD, their count, and the
                  longest run in intervals and in seconds.
    identical_count  intervals whose 32x32 reduced frames are BITWISE equal. The
                  frozen-feed signature, and not the same thing as distance 0.

    Every scored window becomes one observation (`observations`). Per-keyframe
    rows (hash, dist_prev) are OPT-IN (`keyframe_observations`,
    `all_observations(per_keyframe=True)`) because a whole hour of them would
    exceed the server's 500-row ceiling; at `limit=12` they fit.

WHAT IT CANNOT CLAIM:

  * That no person passed. At 32x32 a person is a few cells: a person close to
    the door read 4 and 6, a car leaving read 24 (busy day hour, checked frame
    by frame). No-change here means "the whole-frame layout did not move beyond
    the noise floor", never "nothing happened". Motion is A1/A2's question.
  * Anything about light LEVEL. A positive gain and offset moves no bit (pinned
    in the tests). The colour-to-IR switch IS seen, 16 bits on main on the
    exact keyframe where saturation fell from 10.04 to 0.011 (16:48:24.99) and
    12 bits on sub at the next sub keyframe (16:48:25.34), because the IR lamp
    changes where the light falls. Light is B1's question.
  * Anything on a featureless frame. With no structure the bits are set by
    noise and consecutive hashes differ by ~32: a covered lens reads as MAXIMAL
    change. `ac_scale_min` exists so that case is visible. Real footage ran
    39.8 to 103.5 (3,823 hashed keyframes); flat frames with sensor-level noise
    stay under 1.0 (synthetic, pinned in the tests). No real covered-lens
    footage was available, so no cut-off is claimed between the two.
  * Any class, shape, box or scene light. None is sent.

THE THRESHOLD, CALIBRATED on the recommended stream (sub). NOCHANGE_THRESHOLD =
4 is the smallest value that left both full still night hours unbroken:
1,069 of 1,071 intervals at 0 indoors (the other 2 at 2), and 554 / 488 / 36 at
0 / 2 / 4 on the IR rooftop, whose only two larger distances were a moth,
verified by eye. At 2 the IR hour would break 36 times. The cost is by day,
where 4 is also what a person near the camera produced: the busy hour had
834 / 185 / 57 intervals at 0 / 2 / 4 and 56 above (4.9%). `le2_count` is
stored so a day-only threshold of 2 (once B1 labels the regime) can be applied
to history without a re-scan. Dusk under IR is the weak spot: four 6s in 98
intervals, every one an empty rooftop with small bright blobs (insects near the
IR lamp, by their look) moving between the two frames, all four inspected.

DISTANCE 0 IS NOT FROZEN. Live still scenes gave 0 on almost every interval
but a bitwise-identical reduced frame on none (0 of 3,806 intervals across the
whole sample set), because a live sensor never repeats 1,024 exact area means.
A frozen loop gave 0 on every interval: 9 of 9 identical when the camera's own
GOP was repeated, 6 of 8 and 4 of 7 when one still was re-encoded by x264 and
x265 (the encoder settles after 2-3 I-frames).

THE DECODE SHAPE follows labs_framediff: ONE long-lived software decoder per
batch (`-threads 1`, never `-hwaccel`), segments streamed in as chunks, keyframes
only. What is new here is TIME: every segment's PTS restart at 1.4 s (measured
on both streams), so `-copyts` keeps each segment's own clock and a timestamp
that does not advance marks the next segment. Main and sub then place the same
events at the same wall-clock seconds (09:02:03.93 on main, 09:02:04.44 on sub).

COST, median of 5 runs, getrusage SELF+CHILDREN around the analysis, sub
640x360, for the indoor / IR / day hours: 0.42 / 0.41 / 0.67 CPU-s per
camera-hour for 3.9 / 4.6 / 8.4 MB at the server's evenly spread `limit=12`;
3.8 / 3.7 / 6.0 CPU-s for 38.9 / 46.9 / 82.4 MB for every segment of the hour.
75-83% of it is the decoder (the ffmpeg child).
"""
from __future__ import annotations

import collections
import logging
import queue
import re
import subprocess
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable, Iterator, Sequence

import numpy as np

logger = logging.getLogger(__name__)

#: Side of the greyscale image the DCT runs on, and of the low-frequency block
#: kept from it. 32 and 8 are the classic pHash sizes.
REDUCED_SIDE = 32
HASH_SIDE = 8

#: DCT coefficients are rounded to this many decimals (the reduced image is in
#: luma levels, 0..255) before the median comparison. See `dct_low`.
COEFF_DECIMALS = 6

#: The no-change threshold, in bits. CALIBRATED; see the module docstring.
NOCHANGE_THRESHOLD = 4

#: Keyframes closer than this to the previous KEPT keyframe are skipped.
MIN_SPACING_S = 1.0

#: A larger step between consecutive keyframes breaks the chain.
MAX_GAP_S = 10.0

#: Longest window one observation summarises.
WINDOW_S = 60.0

#: Names the hash definition. Two hashes are comparable only when this matches.
ALGO = "dct32_8x8_med63_v1"


# ---------------------------------------------------------------------------
# the hash
# ---------------------------------------------------------------------------
def dct_matrix(n: int) -> np.ndarray:
    """Orthonormal DCT-II basis, one frequency per row: X = M @ x."""
    k = np.arange(n, dtype=np.float64)[:, None]
    i = np.arange(n, dtype=np.float64)[None, :]
    m = np.sqrt(2.0 / n) * np.cos(np.pi * (2.0 * i + 1.0) * k / (2.0 * n))
    m[0, :] = np.sqrt(1.0 / n)
    return m


#: Only the 8 lowest-frequency rows are ever used, so only they are kept:
#: M8 @ X @ M8.T is exactly the top-left 8x8 of the full 32x32 2-D DCT.
_DCT_LOW = np.ascontiguousarray(dct_matrix(REDUCED_SIDE)[:HASH_SIDE])


def _axis_sums(a: np.ndarray, n: int, axis: int) -> np.ndarray:
    """Exact area sums along one axis into `n` bins, in units of 1/n pixel.

    Bin k covers [k*L/n, (k+1)*L/n) source pixels. Multiplying by n makes every
    boundary an integer, so the fractional overlaps are integer weights and the
    whole reduction is exact integer arithmetic: no rounding, no summation-order
    dependence, the same answer on every machine.
    """
    length = a.shape[axis]
    if length % n == 0:
        shp = list(a.shape)
        shp[axis:axis + 1] = [n, length // n]
        return a.reshape(shp).sum(axis=axis + 1, dtype=np.int64) * n
    c = np.cumsum(a, axis=axis, dtype=np.int64)
    zshape = list(c.shape)
    zshape[axis] = 1
    c = np.concatenate([np.zeros(zshape, dtype=np.int64), c], axis=axis)
    q, r = np.divmod(np.arange(n + 1, dtype=np.int64) * length, n)
    rshape = [1] * a.ndim
    rshape[axis] = n + 1
    edge = np.take(a, np.minimum(q, length - 1), axis=axis).astype(np.int64)
    return np.diff(n * np.take(c, q, axis=axis) + r.reshape(rshape) * edge, axis=axis)


def reduce_area(luma: np.ndarray, side: int = REDUCED_SIDE) -> np.ndarray:
    """Area-average a luma plane of ANY size to side x side, exactly.

    This is the canonical input of the hash, and it is defined on the plane the
    Watchtower worker already holds (the full-resolution Y plane), so a station
    and this module hash the same numbers. Equal to OpenCV's INTER_AREA
    (pinned in the tests against cv2 as an independent implementation).
    """
    y = np.asarray(luma)
    if y.ndim != 2:
        raise ValueError(f"expected a 2-D luma plane, got shape {y.shape}")
    h, w = y.shape
    if h < side or w < side:
        raise ValueError(f"frame {w}x{h} is smaller than {side}x{side}")
    # Integral axis first: the fractional one then runs on a 32-wide strip.
    if h % side and not w % side:
        s = _axis_sums(_axis_sums(y, side, 1), side, 0)
    else:
        s = _axis_sums(_axis_sums(y, side, 0), side, 1)
    return s.astype(np.float64) / float(h * w)


def dct_low(reduced: np.ndarray) -> np.ndarray:
    """Top-left 8x8 of the orthonormal 2-D DCT-II, in matrix form.

    Rounded to COEFF_DECIMALS so that floating-point summation-order
    differences between BLAS builds cannot flip a bit. Only a coefficient
    within ~1e-9 of a rounding boundary could still differ, and the tests pin
    the case that matters (a flat frame, whose AC coefficients are all
    mathematically zero, hashes to exactly 0x8000000000000000).
    """
    d = _DCT_LOW @ np.asarray(reduced, dtype=np.float64) @ _DCT_LOW.T
    return np.round(d, COEFF_DECIMALS) + 0.0      # + 0.0 turns -0.0 into 0.0


def hash_from_coeffs(coeffs: np.ndarray) -> int:
    """64 bits, row-major over the 8x8 block, DC first as the most significant.

    bit = coefficient > median of the 63 AC coefficients (the 64 without DC).
    Two consequences, both pinned in the tests:
      * the DC bit is 1 for every frame that is not pure black, so it carries
        almost no information;
      * exactly 31 AC coefficients lie above their own median, so every hash of
        a textured frame has 32 bits set, and the distance between two such
        hashes is always EVEN. A distance of 2 is one coefficient swapping
        sides of the median with another.
    """
    flat = np.asarray(coeffs, dtype=np.float64).ravel()
    bits = flat > np.median(flat[1:])
    h = 0
    for b in bits:
        h = (h << 1) | int(b)
    return h


def ac_scale(coeffs: np.ndarray) -> float:
    """Median absolute deviation of the 63 AC coefficients, in luma levels.

    How much structure the bits rest on. A featureless frame (lens covered,
    fog, a blown-out sensor) has AC coefficients at the noise level, and its
    bits are then set by noise: consecutive hashes differ by ~32 bits although
    nothing changed. That failure is invisible in a distance; this makes it
    visible.
    """
    ac = np.asarray(coeffs, dtype=np.float64).ravel()[1:]
    return float(np.median(np.abs(ac - np.median(ac))))


def phash(luma: np.ndarray) -> int:
    """The 64-bit hash of one luma plane."""
    return hash_from_coeffs(dct_low(reduce_area(luma)))


def to_hex(h: int) -> str:
    """16 lowercase hex characters, zero-padded."""
    return f"{h & 0xFFFFFFFFFFFFFFFF:016x}"


def from_hex(s: str) -> int:
    if len(s) != 16:
        raise ValueError(f"a hash is 16 hex characters, got {len(s)}")
    return int(s, 16)


def hamming(a: int, b: int) -> int:
    return int((a ^ b).bit_count())


# ---------------------------------------------------------------------------
# the chain: one record per kept keyframe
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Keyframe:
    """One hashed keyframe. Frozen: a measurement."""

    #: Seconds on the caller's clock (epoch seconds for real footage), or None
    #: when the caller cannot place the frame in time.
    t_s: float | None
    hash: int
    #: Hamming distance to the previous KEPT keyframe. None at the start of a
    #: chain: the first keyframe, or the first after a gap, has no predecessor,
    #: and 0 would claim "no change" where nothing was compared.
    dist_prev: int | None
    #: Seconds since that keyframe, when both times are known.
    dt_prev: float | None
    ac_scale: float
    #: The 32x32 reduced image is bitwise identical to the previous keyframe's.
    #: Distance 0 does not mean frozen: a live still scene gives 0 too. This
    #: does, because a live sensor never repeats 1,024 exact area means.
    identical_prev: bool
    width: int
    height: int

    @property
    def hex(self) -> str:
        return to_hex(self.hash)


def chain(items: Iterable[tuple], *,
          min_spacing_s: float = MIN_SPACING_S,
          max_gap_s: float = MAX_GAP_S) -> list[Keyframe]:
    """Hash keyframes in order and link each to the previous kept one.

    `items` yields (t_s, luma) or (t_s, luma, segment). Memory is one reduced
    32x32 image, not the frames: pass a generator and the frames are released
    as they are hashed.

    A keyframe less than `min_spacing_s` after the previous kept one is
    skipped before hashing (a cadence artefact, not a scene sample). When a
    segment key is given the rule acts only INSIDE a segment, where PTS
    offsets are exact. Across a joint the times rest on the catalogue's
    start_time, stored to the whole second for continuous recording, and
    measured joint intervals ran as short as 1.124 s on a 3.3 s cadence: the
    rule must not be able to drop a real first keyframe there.

    A step backwards in time or longer than `max_gap_s` starts a new chain.
    With t_s None the chain is index-ordered and neither rule applies.
    """
    out: list[Keyframe] = []
    prev_t: float | None = None
    prev_h: int | None = None
    prev_red: np.ndarray | None = None
    prev_seg = None
    for item in items:
        t, luma = item[0], item[1]
        seg = item[2] if len(item) > 2 else None
        if (t is not None and prev_t is not None and prev_t <= t
                and t - prev_t < min_spacing_s
                and (seg is None or seg == prev_seg)):
            continue
        red = reduce_area(luma)
        co = dct_low(red)
        h = hash_from_coeffs(co)
        timed = t is not None and prev_t is not None
        broken = prev_h is None or (timed and (t < prev_t or t - prev_t > max_gap_s))
        out.append(Keyframe(
            t_s=t,
            hash=h,
            dist_prev=None if broken else hamming(h, prev_h),
            dt_prev=None if (broken or not timed) else t - prev_t,
            ac_scale=ac_scale(co),
            identical_prev=(not broken) and bool(np.array_equal(red, prev_red)),
            width=int(luma.shape[1]),
            height=int(luma.shape[0]),
        ))
        prev_t, prev_h, prev_red, prev_seg = t, h, red, seg
    return out


# ---------------------------------------------------------------------------
# windows
# ---------------------------------------------------------------------------
def medoid_index(hashes: Sequence[int]) -> int:
    """Index of the hash with the smallest total distance to the others.

    Earliest wins a tie, so the choice is deterministic.
    """
    if not hashes:
        raise ValueError("no hashes")
    best, best_i = None, 0
    for i, a in enumerate(hashes):
        s = sum(hamming(a, b) for b in hashes)
        if best is None or s < best:
            best, best_i = s, i
    return best_i


@dataclass(frozen=True)
class WindowScores:
    """One window's summary. Each field is one claim; see `as_metrics`."""

    start_s: float | None
    end_s: float | None
    keyframes: int
    intervals: int
    dist_min: int | None
    dist_median: float | None
    dist_max: int | None
    peak_offset_s: float | None
    threshold: int
    nochange_count: int
    nochange_longest: int
    nochange_longest_s: float | None
    zero_count: int
    le2_count: int
    identical_count: int
    rep_hash: int
    rep_offset_s: float | None
    odd_hash: int
    odd_dist: int
    odd_offset_s: float | None
    ac_scale_min: float
    src: str

    def as_metrics(self) -> dict:
        """The `metrics` payload: scalars only, at most 21 keys, slug keys.

        Undefined values are OMITTED, not sent as null: no intervals means no
        distance statistics, and no clock means no seconds. The contract reads
        an absent key as "not computed", which is exactly true.
        """
        m: dict = {
            "algo": ALGO,
            "src": self.src,
            "rep_hash": to_hex(self.rep_hash),
            "odd_hash": to_hex(self.odd_hash),
            "odd_dist": self.odd_dist,
            "keyframes": self.keyframes,
            "intervals": self.intervals,
            "nochange_threshold": self.threshold,
            "nochange_count": self.nochange_count,
            "nochange_longest": self.nochange_longest,
            "zero_count": self.zero_count,
            "le2_count": self.le2_count,
            "identical_count": self.identical_count,
            "ac_scale_min": round(self.ac_scale_min, 2),
        }
        if self.intervals:
            m["dist_min"] = self.dist_min
            m["dist_median"] = self.dist_median
            m["dist_max"] = self.dist_max
        for k in ("rep_offset_s", "odd_offset_s", "peak_offset_s",
                  "nochange_longest_s"):
            v = getattr(self, k)
            if v is not None:
                m[k] = round(v, 2)
        return m


def score_window(kfs: Sequence[Keyframe], *,
                 threshold: int = NOCHANGE_THRESHOLD) -> WindowScores | None:
    """Summarise consecutive keyframes. None for an empty window.

    An interval belongs to the window holding its LATER keyframe, so the first
    keyframe's link back into the previous window is counted here and no
    interval is counted twice or lost.
    """
    if not kfs:
        return None
    t0 = kfs[0].t_s

    def off(k: Keyframe) -> float | None:
        return None if (k.t_s is None or t0 is None) else k.t_s - t0

    hashes = [k.hash for k in kfs]
    rep_i = medoid_index(hashes)
    to_rep = [hamming(h, hashes[rep_i]) for h in hashes]
    odd_i = max(range(len(kfs)), key=lambda i: (to_rep[i], -i))

    dists = [k.dist_prev for k in kfs if k.dist_prev is not None]
    peak_i = None
    for i, k in enumerate(kfs):
        if k.dist_prev is not None and (peak_i is None or k.dist_prev > kfs[peak_i].dist_prev):
            peak_i = i

    # Runs of consecutive no-change intervals. A chain break or a change ends
    # a run; seconds are summed only when every step in the run has a time.
    longest = run = 0
    longest_s: float | None = None
    run_s: float | None = 0.0
    timed = all(k.dt_prev is not None for k in kfs if k.dist_prev is not None)
    for k in kfs:
        if k.dist_prev is not None and k.dist_prev <= threshold:
            run += 1
            run_s = (run_s + k.dt_prev) if (timed and run_s is not None) else None
            longest = max(longest, run)
            if run_s is not None:
                longest_s = run_s if longest_s is None else max(longest_s, run_s)
        else:
            run, run_s = 0, 0.0
    if timed and longest_s is None:
        longest_s = 0.0

    sizes = {(k.width, k.height) for k in kfs}
    src = f"{kfs[0].width}x{kfs[0].height}" if len(sizes) == 1 else "mixed"
    return WindowScores(
        start_s=t0,
        end_s=kfs[-1].t_s,
        keyframes=len(kfs),
        intervals=len(dists),
        dist_min=min(dists) if dists else None,
        dist_median=float(np.median(dists)) if dists else None,
        dist_max=max(dists) if dists else None,
        peak_offset_s=off(kfs[peak_i]) if peak_i is not None else None,
        threshold=threshold,
        nochange_count=sum(1 for d in dists if d <= threshold),
        nochange_longest=longest,
        nochange_longest_s=longest_s if timed else None,
        zero_count=sum(1 for d in dists if d == 0),
        le2_count=sum(1 for d in dists if d <= 2),
        identical_count=sum(1 for k in kfs if k.identical_prev),
        rep_hash=hashes[rep_i],
        rep_offset_s=off(kfs[rep_i]),
        odd_hash=hashes[odd_i],
        odd_dist=to_rep[odd_i],
        odd_offset_s=off(kfs[odd_i]),
        ac_scale_min=min(k.ac_scale for k in kfs),
        src=src,
    )


def split_windows(kfs: Sequence[Keyframe], *, window_s: float = WINDOW_S,
                  hour_end_s: float | None = None) -> list[list[Keyframe]]:
    """Cut a keyframe sequence into windows.

    Each chain (a run with no break) is split into ceil(span / window_s)
    windows of equal duration, so a lone 30 s segment is one window and a
    continuous hour is ~60. With `hour_end_s`, a window that would START at or
    after the end of the claimed hour is merged into the one before it: the
    server refuses an observation whose start lies outside the hour, and the
    last segment of an hour legitimately runs a few seconds past it.
    """
    chains: list[list[Keyframe]] = []
    for k in kfs:
        if not chains or k.dist_prev is None:
            chains.append([k])
        else:
            chains[-1].append(k)
    out: list[list[Keyframe]] = []
    for c in chains:
        t0, t1 = c[0].t_s, c[-1].t_s
        if t0 is None or t1 is None or window_s <= 0:
            out.append(list(c))
            continue
        n = max(1, int(np.ceil((t1 - t0) / window_s - 1e-9)))
        width = (t1 - t0) / n if n > 1 else float("inf")
        pieces: list[list[Keyframe]] = [[] for _ in range(n)]
        for k in c:
            i = min(n - 1, int((k.t_s - t0) // width)) if n > 1 else 0
            pieces[i].append(k)
        out.extend(p for p in pieces if p)
    if hour_end_s is not None:
        merged: list[list[Keyframe]] = []
        for w in out:
            if merged and w[0].t_s is not None and w[0].t_s >= hour_end_s:
                merged[-1].extend(w)
            else:
                merged.append(w)
        out = merged
    return out


def _iso(t: float) -> str:
    return (datetime.fromtimestamp(t, tz=timezone.utc)
            .isoformat(timespec="milliseconds").replace("+00:00", "Z"))


def observations(kfs: Sequence[Keyframe], *, hour_start_s: float | None = None,
                 window_s: float = WINDOW_S,
                 threshold: int = NOCHANGE_THRESHOLD) -> list[dict]:
    """ObservationIn dicts, one per window. `t_s` must be epoch seconds.

    Carries no object_class, shape_class, bbox or scene_light: a whole-frame
    fingerprint measures none of them. A window whose keyframes have no time
    is dropped rather than given an invented stamp.
    """
    hour_end = None if hour_start_s is None else hour_start_s + 3600.0
    out = []
    for w in split_windows(kfs, window_s=window_s, hour_end_s=hour_end):
        s = score_window(w, threshold=threshold)
        if s is None or s.start_s is None or s.end_s is None:
            continue
        out.append({"start_time": _iso(s.start_s), "end_time": _iso(s.end_s),
                    "metrics": s.as_metrics()})
    return out


#: The server's per-unit ceiling (routers/labs.py MAX_OBSERVATIONS_PER_UNIT).
#: Restated here so this module stays importable without the router; the tests
#: pin it against the real constant.
MAX_ROWS_PER_UNIT = 500


class TooManyRowsError(ValueError):
    """Per-keyframe rows plus window rows would exceed the per-unit ceiling.
    Refused rather than truncated: a silently shortened hour reads as a
    complete one."""


def keyframe_observations(kfs: Sequence[Keyframe], *,
                          hour_start_s: float | None = None) -> list[dict]:
    """OPT-IN: one ObservationIn dict per keyframe, start_time == end_time.

    metrics: `algo`, `hash` (16 hex), `ac_scale`, `identical_prev`, `src`, and
    `dist_prev` / `dt_prev` only when there was a predecessor (absent, never 0,
    at the start of a chain). A keyframe without a time is dropped rather than
    given an invented stamp. With `hour_start_s`, keyframes outside
    [hour_start, hour_start + 3600) are dropped too, because the server refuses
    them (observation_outside_claimed_hour); the window rows still count them.

    Budget: the sub stream kept 9.4 keyframes per ~30 s segment on the busy
    day hour (1,133 over 120 segments, measured after the 1 s spacing rule),
    so `limit=12` gives about 113 rows and a whole hour about 1,100, over the
    500 ceiling. `observations(per_keyframe=True)` refuses the latter.
    """
    lo = hour_start_s
    hi = None if hour_start_s is None else hour_start_s + 3600.0
    out = []
    for k in kfs:
        if k.t_s is None or (lo is not None and not lo <= k.t_s < hi):
            continue
        m: dict = {"algo": ALGO, "hash": k.hex, "ac_scale": round(k.ac_scale, 2),
                   "identical_prev": k.identical_prev, "src": f"{k.width}x{k.height}"}
        if k.dist_prev is not None:
            m["dist_prev"] = k.dist_prev
        if k.dt_prev is not None:
            m["dt_prev"] = round(k.dt_prev, 3)
        t = _iso(k.t_s)
        out.append({"start_time": t, "end_time": t, "metrics": m})
    return out


def all_observations(kfs: Sequence[Keyframe], *, hour_start_s: float | None = None,
                     window_s: float = WINDOW_S, threshold: int = NOCHANGE_THRESHOLD,
                     per_keyframe: bool = False,
                     max_rows: int = MAX_ROWS_PER_UNIT) -> list[dict]:
    """Window rows, plus per-keyframe rows when `per_keyframe` is set.

    A reader tells the two apart by key: a window row carries `rep_hash`, a
    keyframe row carries `hash`. Raises TooManyRowsError past `max_rows`.
    """
    out = observations(kfs, hour_start_s=hour_start_s, window_s=window_s,
                       threshold=threshold)
    if per_keyframe:
        out += keyframe_observations(kfs, hour_start_s=hour_start_s)
    if len(out) > max_rows:
        raise TooManyRowsError(
            f"{len(out)} rows exceed the per-unit ceiling of {max_rows}; "
            "sample fewer segments or drop per_keyframe")
    return out


# ---------------------------------------------------------------------------
# decoding: ONE long-lived software decoder per batch of segments
# ---------------------------------------------------------------------------
_SHOWINFO_RE = re.compile(
    r"\bn:\s*\d+\s+pts:\s*\S+\s+pts_time:(?P<pts>\S+).*?\bs:(?P<w>\d+)x(?P<h>\d+)")


def decode_luma_keyframes(source: Iterable[bytes] | bytes, *,
                          ffmpeg: str = "ffmpeg",
                          timeout_s: float = 600.0
                          ) -> Iterator[tuple[float | None, np.ndarray]]:
    """Yield (pts_s, luma) for every keyframe of concatenated MPEG-TS.

    `source` is bytes or an iterable of chunks, streamed into ONE ffmpeg on
    stdin. Software decode only, `-threads 1`, never `-hwaccel` (the shared
    iGPU wedges on VA-API context creation; see labs_framediff).

    The luma is the decoder's own Y plane (`extractplanes=y`): no swscale, no
    range conversion, the same bytes the Watchtower frame source slices out of
    yuvj420p. `format=gray` is a no-op on these 8-bit cameras and only
    converts a 10-bit source.

    PTS come from `showinfo` on stderr, drained by its own thread (an undrained
    stderr is the deadlock the Watchtower frame source warned about). `-copyts`
    keeps each segment's own timestamps: the recorder restarts them at every
    segment, and without it ffmpeg "repairs" the backwards step, which would
    also silently erase a real gap between segments. `to_wallclock` uses the
    restarts to put each keyframe back in its segment.
    """
    cmd = [
        ffmpeg, "-hide_banner", "-nostats", "-loglevel", "info",
        "-threads", "1", "-filter_threads", "1",
        "-skip_frame", "nokey",
        "-fflags", "+discardcorrupt",
        "-copyts",
        "-i", "pipe:0",
        "-an", "-sn", "-dn",
        "-fps_mode", "passthrough",
        "-vf", "extractplanes=y,format=gray,showinfo=checksum=0",
        "-threads", "1",
        "-f", "rawvideo", "pipe:1",
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    infos: queue.Queue = queue.Queue()
    tail: collections.deque = collections.deque(maxlen=8)

    def _feed() -> None:
        try:
            if isinstance(source, (bytes, bytearray)):
                proc.stdin.write(source)
            else:
                for chunk in source:
                    proc.stdin.write(chunk)
        except (BrokenPipeError, OSError):
            pass                     # decoder exited early; reported below
        finally:
            try:
                proc.stdin.close()
            except OSError:
                pass

    def _drain() -> None:
        try:
            for raw in proc.stderr:
                line = raw.decode("utf-8", "replace")
                m = _SHOWINFO_RE.search(line)
                if not m:
                    tail.append(line.rstrip())
                    continue
                try:
                    pts: float | None = float(m.group("pts"))
                except ValueError:
                    pts = None       # NOPTS: yielded, but cannot be placed
                infos.put((pts, int(m.group("w")), int(m.group("h"))))
        except (OSError, ValueError):
            pass
        finally:
            infos.put(None)

    feeder = threading.Thread(target=_feed, daemon=True)
    drainer = threading.Thread(target=_drain, daemon=True)
    feeder.start()
    drainer.start()
    try:
        while True:
            info = infos.get(timeout=timeout_s)
            if info is None:
                break
            pts, w, h = info
            want, parts = w * h, []
            while want > 0:
                c = proc.stdout.read(want)
                if not c:
                    break
                parts.append(c)
                want -= len(c)
            if want > 0:
                break
            buf = parts[0] if len(parts) == 1 else b"".join(parts)
            yield pts, np.frombuffer(buf, dtype=np.uint8).reshape(h, w)
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
        drainer.join(timeout=2.0)
        try:
            proc.stderr.close()
        except OSError:
            pass
        if proc.returncode:
            logger.debug("ffmpeg exit %s: %s", proc.returncode, " | ".join(tail))


class AttributionError(ValueError):
    """Keyframes could not be matched to the segments that were fed in."""


class NoKeyframesError(RuntimeError):
    """The decoder produced nothing. Never to be reported as a quiet hour:
    "nothing changed" and "nothing was decoded" are different facts, and the
    Labs contract submits an empty list only for the first."""


def to_wallclock(frames: Iterable[tuple[float | None, np.ndarray]],
                 segment_starts: Sequence[float], *,
                 seen: list | None = None
                 ) -> Iterator[tuple[float | None, np.ndarray, int]]:
    """Map (pts, luma) from `decode_luma_keyframes` to (epoch_s, luma, segment).

    A PTS that does not advance marks the first keyframe of the next segment
    (the recorder restarts timestamps per segment), and the keyframe's time is
    that segment's catalogue start_time plus its offset from the segment's
    first keyframe. So times are exact within a segment and as good as the
    catalogue across segments: whole seconds for continuous recording, which
    measured as joint intervals 1 to 2 s short of the cadence.

    `seen`, if given, receives the number of segments that produced
    keyframes, so a caller can refuse a batch where one segment produced
    none: every later keyframe would then sit one segment early.
    """
    seg, first, prev = -1, 0.0, None
    try:
        for pts, luma in frames:
            if pts is None:
                yield None, luma, max(seg, 0)
                continue
            if prev is None or pts <= prev:
                seg += 1
                if seg >= len(segment_starts):
                    raise AttributionError(
                        f"more timestamp restarts than the {len(segment_starts)} "
                        "segments fed in")
                first = pts
            prev = pts
            yield segment_starts[seg] + (pts - first), luma, seg
    finally:
        if seen is not None:
            seen.append(seg + 1)


def analyse_keyframes(source: Iterable[bytes] | bytes,
                      segment_starts: Sequence[float], *,
                      min_spacing_s: float = MIN_SPACING_S,
                      max_gap_s: float = MAX_GAP_S, **kw) -> list[Keyframe]:
    """Decode a batch of consecutive or sampled segments and hash it.

    Refuses rather than guesses: NoKeyframesError when nothing decoded, and
    AttributionError when the number of timestamp restarts does not match the
    number of segments (a segment that produced no keyframe would otherwise
    put every later keyframe one segment early, silently).
    """
    seen: list = []
    kfs = chain(to_wallclock(decode_luma_keyframes(source, **kw), segment_starts,
                             seen=seen),
                min_spacing_s=min_spacing_s, max_gap_s=max_gap_s)
    if not kfs:
        raise NoKeyframesError("the decoder produced no keyframes")
    if seen and seen[0] != len(segment_starts):
        raise AttributionError(
            f"{seen[0]} of {len(segment_starts)} segments produced keyframes")
    return kfs


def analyse(source: Iterable[bytes] | bytes, segment_starts: Sequence[float], *,
            hour_start_s: float | None = None, window_s: float = WINDOW_S,
            threshold: int = NOCHANGE_THRESHOLD, per_keyframe: bool = False,
            **kw) -> list[dict]:
    """The whole analyser for one camera-hour: TS in, ObservationIn dicts out."""
    return all_observations(analyse_keyframes(source, segment_starts, **kw),
                            hour_start_s=hour_start_s, window_s=window_s,
                            threshold=threshold, per_keyframe=per_keyframe)
