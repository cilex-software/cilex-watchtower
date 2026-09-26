"""A1/A2 — frame-difference PEAK, SUSTAINED, and the ratio.

The only approach in the enrichment register marked PROVEN, and until now the
only one with no code in the repository: it existed as an ad-hoc sweep during
one boar incident and as three numbers in a table. This is that algorithm,
written down.

WHAT IT COMPUTES, and each number is one claim:

    peak       max mean-absolute-difference between consecutive keyframes.
               "How violent was the most violent moment."
    sustained  how many consecutive-frame deltas exceeded DELTA_THRESHOLD.
               "How many keyframe intervals were busy."
    ratio      peak / sustained. High = one violent change (a vehicle
               crossing); low = many moderate ones (a group milling about).

THE DECODE SHAPE IS PART OF THE ALGORITHM, not an implementation detail. The
Watchtower Linux agent measured that the shared Intel iGPU wedges for ~20 s —
sometimes with an OOM kill — when about sixteen VA-API contexts are created at
once, and that it is a CREATION-RATE failure rather than a steady-state one. My
own reference sweep spawned one ffmpeg per 30-second segment: 120 decoder
creations per camera-hour, ~161,000 a day across the fleet. That was safe only
by accident, because it used plain software decode and created no VA-API
context at all.

So this module decodes with ONE long-lived process for a whole batch, and
software-only — no `-hwaccel`, whatever the CPU headroom says. Speeding this up
with VA-API would convert a harmless pattern into exactly the failure above,
and it would look like a win on a developer box with no video wall running.

MPEG-TS is byte-concatenable by design, which is what makes one decoder
possible: segments are streamed into a single ffmpeg on stdin rather than
opened one file at a time.

STREAM IT, DO NOT BUFFER IT. `analyse()` accepts raw bytes for convenience and
that is a trap at camera-hour scale: one hour of main is ~450 MB, and holding
the segments in a list and then joining them doubles it. Measured — the
container OOM-killed exactly that, which is how this note came to exist. Pass an
ITERABLE of chunks (a generator reading a spooled file, or each segment as it is
fetched); memory is then bounded by the chunk size rather than by the window
length, and the window can be as long as the analysis wants.

THREE THINGS THAT WERE NOT SAFE TO ASSUME, now measured (register §1.6/§1.7):

  * segment JOINTS DO NOT fake motion. Measured over 6 runs of 4 consecutive
    segments: joint deltas median 0.740 against 0.766 within a segment (0.97x),
    and they cross the threshold LESS often (5.6% vs 12.8%). Concatenation also
    loses no frames (30 vs 30). So the one-long-lived-decoder shape is safe for
    the algorithm as well as for the iGPU.
  * `sustained` is a count of KEYFRAME INTERVALS, not of seconds. Measured: 15
    fps, GOP ~60, so ~8 keyframes per 30 s segment and ONE segment caps
    `sustained` at 7. The register's documented 13 is unreachable from one
    segment. SCORE A WINDOW, NOT A SEGMENT, and pass `span_s` so `sustained_s`
    is comparable across cameras.
  * the threshold is BELOW the noise floor on 16% of segments (`median_delta`
    > 2.0 on 28 of 170; day-time p90 2.936). On those `sustained` counts
    everything. `median_delta` is returned so that is visible, and it is the
    concrete reason B1 `illumination` should land before this is trusted across
    the clock.

AND ONE NEGATIVE RESULT ABOUT THE RATIO. `peak` and `sustained` each separate
camera-VMD-positive from VMD-negative segments (3.59x and cleanly). The RATIO
does not: 1.29x, undefined on 54% of segments, and UNIMODAL over 170 real
segments with zero local maxima. It was called "the only validated
discriminator we have" on the strength of three clips. It is computed here
because it is cheap and stored history is what makes a later claim checkable —
not because it is believed.
"""
from __future__ import annotations

import logging
import subprocess
from dataclasses import dataclass
from typing import Iterable, Iterator, Sequence

import numpy as np

logger = logging.getLogger(__name__)

#: The A2 threshold, tuned on NIGHT footage during the boar incident. Kept as a
#: named constant rather than inlined because it is the single most
#: question-begging number here: the daytime noise floor is different, which is
#: exactly why `illumination` (B1) is meant to land before this is trusted
#: across the clock.
DELTA_THRESHOLD = 2.0

#: Width the frame is scaled to before differencing. 160 px is from the
#: original sweep. Small on purpose: it suppresses sensor noise, which is the
#: dominant signal in a dark scene, and makes the whole thing cheap.
SCALE_WIDTH = 160

#: Guard against a decoder that produces nothing — an all-zero delta series and
#: a genuinely still scene must not be reported the same way.
MIN_FRAMES = 3


@dataclass(frozen=True)
class Scores:
    """One segment's or one batch's scores. Frozen: these are a measurement."""

    peak: float
    sustained: int
    #: None when `sustained` is 0. NOT 0.0 and NOT infinity: a scene where
    #: nothing crossed the threshold has no peak-to-sustained ratio, and
    #: inventing one would put a made-up number into the corpus beside measured
    #: ones. The caller decides what to do with an absent ratio.
    ratio: float | None
    #: How many deltas the numbers came from. Without it `sustained=13` cannot
    #: be interpreted — 13 of 30 is a busy half-minute, 13 of 13 is a scene
    #: that never stopped moving and probably a mis-threshold.
    frames: int
    #: The delta floor actually seen. The noise floor was ~0.98 on the night
    #: footage this was tuned on; a median far above that means the threshold
    #: is wrong for this camera, and the caller can see that rather than
    #: silently getting sustained == frames.
    median_delta: float
    #: Seconds of activity, and the keyframe interval it was derived from.
    #: BOTH None unless the caller said how much wall-clock the frames covered.
    #:
    #: WHY THIS EXISTS: `sustained` is a count of KEYFRAME INTERVALS, and the
    #: register read it as "how many seconds were busy". Measured on this fleet
    #: those are not the same thing and not even close — 15 fps with a GOP of
    #: ~60 puts a keyframe every ~4 s, so a 30 s segment yields 8 keyframes and
    #: `sustained` cannot exceed 7. A camera with a different GOP produces a
    #: different `sustained` for identical motion, so the raw count is NOT
    #: comparable across cameras. Seconds are.
    sustained_s: float | None = None
    keyframe_interval_s: float | None = None

    def as_metrics(self) -> dict:
        """The `metrics` JSONB payload, matching the Labs contract.

        Scalars only, lowercase slug keys — `_clean_metrics` in routers/labs.py
        refuses anything else. `ratio` is omitted rather than sent as null when
        it is undefined: the contract says an absent field means nobody
        computed it, which is exactly true here.
        """
        d = {"peak": round(self.peak, 3), "sustained": self.sustained,
             "frames": self.frames, "median_delta": round(self.median_delta, 3)}
        if self.ratio is not None:
            d["ratio"] = round(self.ratio, 3)
        if self.sustained_s is not None:
            d["sustained_s"] = round(self.sustained_s, 2)
            d["keyframe_interval_s"] = round(self.keyframe_interval_s, 3)
        return d


def deltas_from_frames(frames: Iterable[np.ndarray]) -> list[float]:
    """Mean absolute difference between each consecutive pair of frames.

    Pure and separately testable: the decode is somebody else's problem, which
    is what lets the threshold study run over synthetic frames with a known
    answer before it runs over footage with an unknown one.
    """
    out: list[float] = []
    prev: np.ndarray | None = None
    for f in frames:
        cur = f.astype(np.int16)
        if prev is not None:
            out.append(float(np.mean(np.abs(cur - prev))))
        prev = cur
    return out


def score(deltas: Sequence[float], threshold: float = DELTA_THRESHOLD,
          span_s: float | None = None) -> Scores | None:
    """Reduce a delta series to A1/A2 and the ratio. None if too few frames.

    Returning None rather than zeros is deliberate: "the decoder gave us two
    frames" and "nothing moved" are different facts, and a zero would be
    indistinguishable from a quiet hour once it reached the database.
    """
    if len(deltas) < MIN_FRAMES - 1:
        return None
    arr = np.asarray(deltas, dtype=np.float64)
    sustained = int(np.count_nonzero(arr > threshold))
    peak = float(arr.max())
    interval = (span_s / len(deltas)) if (span_s and len(deltas)) else None
    return Scores(
        peak=peak,
        sustained=sustained,
        ratio=(peak / sustained) if sustained > 0 else None,
        frames=len(deltas) + 1,
        median_delta=float(np.median(arr)),
        sustained_s=(sustained * interval) if interval else None,
        keyframe_interval_s=interval,
    )


def decode_gray_keyframes(
    source: Iterable[bytes] | bytes,
    *,
    width: int = SCALE_WIDTH,
    height: int = 96,
    ffmpeg: str = "ffmpeg",
    timeout_s: float = 300.0,
) -> Iterator[np.ndarray]:
    """Keyframes only, greyscale, from ONE long-lived software decoder.

    `source` is raw MPEG-TS bytes, or an iterable of chunks — which is how the
    station worker will hold it, streaming each fetched segment into the same
    process rather than opening a decoder per segment.

    `-skip_frame nokey` is what makes this cheap: at a measured GOP of 15 it
    decodes roughly one frame a second instead of fifteen. No `-hwaccel` by
    deliberate omission; see the module docstring.

    A fixed output height is forced rather than using `-1`, because rawvideo
    has no framing and the reader must know the frame size in advance. 160x96
    is 5:3, close enough to both 16:9 and 4:3 that the squash is uniform and
    cancels in a difference.
    """
    cmd = [
        ffmpeg, "-hide_banner", "-loglevel", "error",
        "-skip_frame", "nokey",
        "-fflags", "+discardcorrupt",   # a corrupt joint must not become motion
        "-i", "pipe:0",
        # `-fps_mode passthrough`, not `-vsync 0`: the same meaning, but
        # current ffmpeg removed `-vsync` and exits before decoding
        # anything (a Watchtower booth, ffmpeg N-126168, 2026-09-26).
        "-fps_mode", "passthrough",
        "-vf", f"scale={width}:{height},format=gray",
        "-f", "rawvideo", "pipe:1",
    ]
    frame_bytes = width * height
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)

    import threading

    def _feed() -> None:
        try:
            if isinstance(source, (bytes, bytearray)):
                proc.stdin.write(source)
            else:
                for chunk in source:
                    proc.stdin.write(chunk)
        except (BrokenPipeError, OSError):
            pass            # decoder exited early; stdout loop reports it
        finally:
            try:
                proc.stdin.close()
            except OSError:
                pass

    # stderr is drained WHILE stdout is read, never after it: once a pipe
    # buffer of stderr sits unread, ffmpeg blocks and never finishes stdout,
    # and both sides then wait forever. `-loglevel error` keeps healthy footage
    # quiet, but a corrupt stream can log an error per macroblock. The
    # Watchtower Windows agent reproduced the hang with 200 KB of stderr
    # (2026-09-26). The first 4 KB are kept for the log line.
    err = bytearray()

    def _drain() -> None:
        try:
            for line in iter(proc.stderr.readline, b""):
                if len(err) < 4096:
                    err.extend(line[:4096 - len(err)])
        except (OSError, ValueError):
            pass

    feeder = threading.Thread(target=_feed, daemon=True)
    drainer = threading.Thread(target=_drain, daemon=True)
    feeder.start()
    drainer.start()
    frames = 0
    try:
        while True:
            buf = proc.stdout.read(frame_bytes)
            if not buf or len(buf) < frame_bytes:
                break
            frames += 1
            yield np.frombuffer(buf, dtype=np.uint8).reshape((height, width))
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
        text = bytes(err).decode("utf-8", "replace")[:500]
        if frames == 0 and proc.returncode not in (0, None):
            # A decoder that FAILED must not pass for footage with no
            # keyframes. The return value is unchanged (the caller still sees
            # no frames), but the reason is now visible: on a booth ffmpeg that
            # rejected `-vsync`, this decoder produced nothing and its only
            # trace was this line at debug level (2026-09-26).
            logger.warning("ffmpeg exited %s and decoded no frames: %s",
                           proc.returncode, text or "(no stderr)")
        elif text:
            logger.debug("ffmpeg: %s", text)


def analyse(source: Iterable[bytes] | bytes, *,
            threshold: float = DELTA_THRESHOLD,
            span_s: float | None = None, **kw) -> Scores | None:
    """Decode and score in one call. The whole analyser, for a batch of TS.

    `span_s` is the wall-clock the supplied footage covers — sum the
    `duration_s` of the segments fed in. Pass it: without it `sustained` is a
    count of keyframe intervals whose length varies per camera, and comparing
    two cameras on it is comparing different units.

    SCORE A WINDOW, NOT A SEGMENT. At the measured GOP one 30 s segment yields
    8 keyframes, so per-segment `sustained` can only take the values 0..7 —
    too coarse to separate anything. The register's own figures (7, 8, 13) are
    not reachable from a single segment and must have come from a longer
    window. Feed several minutes of consecutive segments into one call.
    """
    return score(deltas_from_frames(decode_gray_keyframes(source, **kw)),
                 threshold=threshold, span_s=span_s)
