#!/usr/bin/env python3
"""Decode segments to luma frames for the A4-A6 analyser.

NOT part of the pure analyser. `shape_observations.analyse_segment` takes frames and
knows nothing about where they came from; this is one way to produce them, used for
development and measurement on this booth. A worker may use it or decode its own way.

EVERY DECODER RULE HERE CAME FROM A MEASUREMENT, NOT A PREFERENCE:

* **Software only. No `-hwaccel`, ever.** The stations' shared Intel iGPU wedges for
  ~20 s, sometimes with an OOM kill, at ~16 concurrent VA-API contexts, and it is a
  CREATION-RATE failure rather than a steady-state one. cilex-vision's own note is
  the one to remember: adding `-hwaccel vaapi` to "optimise" this converts a
  harmless pattern into exactly that failure, and it looks like a win on a dev box
  with no wall running.

* **`-threads 1`.** Measured on this booth: 2.88 CPU-s single-threaded against 4.36
  with `-threads auto` for identical work — 52% more CPU to buy 1.4x less wall time.
  On a station sharing a CPU with a guard wall that is the wrong trade twice over.

* **One long-lived decoder over many segments, not one per segment.** Safe for the
  algorithm too: cilex-vision measured that concatenated MPEG-TS joints do not fake
  motion (joint deltas 0.740 against 0.766 within-segment, 0.97x, crossing
  threshold LESS often, frame counts matching exactly). `iter_concat` is the shape
  to prefer.

* **Take the Y plane off a native yuv420p frame. Never ask swscale for `gray`.**
  Measured here, n=9, ranges non-overlapping: decode alone 17.5 CPU-s/camera-hour,
  delivering yuv420p 31.3, delivering bgr24 54.6, and `-vf format=gray` 47.0. The
  intuitive luma optimisation is a 1.72x PESSIMISATION against bgr24 and a 1.5x one
  against just slicing plane 0 — swscale has SIMD for yuv420p->bgr24 and appears to
  fall back to generic C for gray.

* **`-fflags +discardcorrupt`** kept, per cilex-vision.

THREE THINGS NOT ASSUMED, because cilex-vision measured 461,000 segments and warned
that each costs an hour if you get it wrong:
  1. The main stream is **HEVC**, not h264. A decoder built only for h264 fails on
     the stream most analysers want. Nothing here names a codec.
  2. "sub" is not one resolution — 1280x720 and 640x360 in their census, and this
     booth also measured 640x480 on 4 of 24 cameras. Frame size is read from the
     decoder, never hard-coded, never taken from metadata.
  3. **4-second segments exist** (motion-triggered). Anything deriving a rate from
     an assumed 30 s is wrong on those.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from typing import Iterator, Sequence

import numpy as np

from shape_observations import Frame

# ffmpeg is not in the current dist -- `windeployqt` never shipped a CLI and the
# fetch 404s. The v1.1.44 install tree carries a complete build; C:\wt\pb-app and
# C:\wt\pb2 have an ffmpeg.exe that exits 0xC0000135 for want of avcodec-63.
_FFMPEG_CANDIDATES = (
    os.path.join(
        os.environ.get("LOCALAPPDATA", ""),
        "Programs",
        "Cilex Watchtower.v1144",
        "ffmpeg.exe",
    ),
    "ffmpeg",
)


def find_ffmpeg() -> str:
    """Locate a WORKING ffmpeg, not merely a present one.

    The distinction is not pedantic: this booth has three ffmpeg.exe on disk and one
    of them runs. A stale-installer incident here was caused by exactly this shape
    of check -- `pkg-config` existed, could not execute, and every step downstream
    reported success while rebuilding nothing.
    """
    for cand in _FFMPEG_CANDIDATES:
        exe = cand if os.path.isabs(cand) else shutil.which(cand)
        if not exe or not os.path.exists(exe):
            continue
        try:
            p = subprocess.run(
                [exe, "-hide_banner", "-version"],
                capture_output=True,
                timeout=20,
            )
            if p.returncode == 0:
                return exe
        except (OSError, subprocess.SubprocessError):
            continue
    raise RuntimeError(
        "no working ffmpeg found. Tried: " + ", ".join(_FFMPEG_CANDIDATES)
    )


@dataclass(frozen=True)
class Probe:
    width: int
    height: int
    codec: str | None
    fps: float | None
    keyframe_gop: int | None = None  # frames between I-frames, measured
    pix_fmt: str | None = None

    @property
    def y_bytes(self) -> int:
        return self.width * self.height

    @property
    def frame_bytes(self) -> int:
        # yuv420p: Y plus two quarter-size chroma planes
        return self.width * self.height * 3 // 2


_STREAM_RE = re.compile(
    r"Stream #\d+:\d+.*?:\s*Video:\s*(?P<codec>[\w]+).*?(?P<w>\d{2,5})x(?P<h>\d{2,5})",
    re.S,
)
_FPS_RE = re.compile(r"(?P<fps>\d+(?:\.\d+)?)\s+fps")
_PIXFMT_RE = re.compile(r"\b(?P<pf>yuvj?4[0-4][0-4]p(?:\d{1,2}(?:le|be)?)?)\b")

# Layouts whose plane 0 is a full-resolution 8-bit luma plane followed by two
# quarter-size chroma planes -- i.e. w*h*3//2 per frame, Y first. Requesting a
# conversion when the source is ALREADY one of these adds a swscale pass for
# nothing, which is the same class of hidden cost as asking for `gray`.
# yuvj420p is full-range yuv420p and has an identical byte layout.
_PASSTHROUGH_420 = {"yuv420p", "yuvj420p"}


def probe(path: str, ffmpeg: str | None = None, measure_gop: bool = False) -> Probe:
    """Read real dimensions, codec and rate out of the bytes.

    Metadata is not consulted: `width`, `height` and `codec` are nullable on the
    Labs list endpoint (2 of 461,000 rows came back codec="unknown"), and metadata
    can disagree with the file in any case.
    """
    ff = ffmpeg or find_ffmpeg()
    p = subprocess.run(
        [ff, "-hide_banner", "-i", path], capture_output=True, timeout=120
    )
    err = p.stderr.decode("utf-8", "replace")
    m = _STREAM_RE.search(err)
    if not m:
        raise RuntimeError(f"could not read a video stream from {path}")
    w, h = int(m.group("w")), int(m.group("h"))
    codec = m.group("codec") or None
    if codec in ("unknown", ""):
        codec = None
    fm = _FPS_RE.search(err)
    fps = float(fm.group("fps")) if fm else None
    pm = _PIXFMT_RE.search(m.group(0))
    pix_fmt = pm.group("pf") if pm else None

    gop = None
    if measure_gop:
        total = _count_frames(ff, path, keyframes_only=False)
        keys = _count_frames(ff, path, keyframes_only=True)
        if keys > 0 and total > 0:
            gop = max(1, int(round(total / keys)))
    return Probe(
        width=w, height=h, codec=codec, fps=fps, keyframe_gop=gop, pix_fmt=pix_fmt
    )


def _count_frames(ff: str, path: str, keyframes_only: bool) -> int:
    args = [ff, "-hide_banner", "-threads", "1", "-fflags", "+discardcorrupt"]
    if keyframes_only:
        args += ["-skip_frame", "nokey"]
    args += ["-i", path, "-an", "-f", "null", "-"]
    p = subprocess.run(args, capture_output=True, timeout=600)
    hits = re.findall(rb"frame=\s*(\d+)", p.stderr)
    return int(hits[-1]) if hits else 0


def _decode_args(
    ff: str,
    inputs: Sequence[str],
    keyframes_only: bool,
    concat_list: str | None,
    pix_fmt: str | None = None,
) -> list[str]:
    args = [
        ff,
        "-hide_banner",
        "-nostats",
        "-loglevel",
        "error",
        "-threads",
        "1",  # measured: cheaper AND kinder than -threads auto
        "-fflags",
        "+discardcorrupt",
    ]
    if keyframes_only:
        args += ["-skip_frame", "nokey"]
    if concat_list:
        args += ["-f", "concat", "-safe", "0", "-i", concat_list]
    else:
        args += ["-i", inputs[0]]
    args += ["-an"]
    # `-vsync 0` was REMOVED in this ffmpeg (N-126168): it exits "Unrecognized
    # option 'vsync'" before producing a single frame. `-fps_mode passthrough` is
    # the replacement, and passthrough is what we want -- no duplication, no
    # dropping, so the frame count is the real one.
    args += ["-fps_mode", "passthrough"]
    # Only convert if the source is NOT already a Y-first 4:2:0 8-bit layout.
    # These cameras deliver yuvj420p; forcing "yuv420p" on that buys a full-frame
    # swscale range conversion and changes nothing structural for a luma-only
    # background model.
    if pix_fmt not in _PASSTHROUGH_420:
        args += ["-pix_fmt", "yuv420p"]
    args += ["-f", "rawvideo", "-"]
    return args


def iter_frames(
    path: str,
    *,
    ffmpeg: str | None = None,
    keyframes_only: bool = False,
    pr: Probe | None = None,
    t0: float = 0.0,
    step_s: float | None = None,
) -> Iterator[Frame]:
    """Yield luma Frames from one segment through one decoder process.

    ON TIMESTAMPS. `t_offset_s` is derived from a measured constant step rather than
    per-frame PTS, because reading PTS means parsing `showinfo` off stderr while
    draining rawvideo off stdout, and getting that wrong deadlocks. That is sound on
    this fleet and its soundness was measured, not assumed: I-frame intervals are
    exactly fixed -- 59 of 59 gaps identical across two cameras, GOP 50 on 12 of 24
    sampled and GOP 15 on 9, at 15.1 fps throughout. On variable-rate input this
    would drift, and an analyser that needs true PTS should pass `step_s` or read
    them itself.
    """
    ff = ffmpeg or find_ffmpeg()
    pr = pr or probe(path, ff, measure_gop=keyframes_only)

    if step_s is None:
        if pr.fps and pr.fps > 0:
            step_s = 1.0 / pr.fps
            if keyframes_only:
                step_s *= float(pr.keyframe_gop or 1)
        else:
            step_s = None  # analyser will fall back to a frame count, and say so

    yield from _stream(ff, [path], None, pr, keyframes_only, t0, step_s)


def iter_concat(
    paths: Sequence[str],
    list_path: str,
    *,
    ffmpeg: str | None = None,
    keyframes_only: bool = False,
    pr: Probe | None = None,
    step_s: float | None = None,
) -> Iterator[Frame]:
    """Yield frames for MANY segments through ONE decoder process.

    This is the shape to prefer: it is what "one long-lived decoder" means in
    practice, and cilex-vision measured that the segment joints do not fake motion.

    `list_path` must be written by the caller and must live on an ASCII-only path.
    ffmpeg's concat demuxer could not read a list file containing this booth's
    Cyrillic profile directory under any PowerShell 5.1 encoding -- that cost a run,
    and it is why this takes the path rather than choosing one.
    """
    ff = ffmpeg or find_ffmpeg()
    pr = pr or probe(paths[0], ff, measure_gop=keyframes_only)
    if step_s is None and pr.fps and pr.fps > 0:
        step_s = 1.0 / pr.fps
        if keyframes_only:
            step_s *= float(pr.keyframe_gop or 1)

    with open(list_path, "w", encoding="ascii", errors="strict") as fh:
        for p in paths:
            fh.write("file '" + p.replace("\\", "/") + "'\n")

    yield from _stream(ff, paths, list_path, pr, keyframes_only, 0.0, step_s)


def _stream(
    ff: str,
    inputs: Sequence[str],
    concat_list: str | None,
    pr: Probe,
    keyframes_only: bool,
    t0: float,
    step_s: float | None,
) -> Iterator[Frame]:
    args = _decode_args(ff, inputs, keyframes_only, concat_list, pr.pix_fmt)
    ybytes, fbytes = pr.y_bytes, pr.frame_bytes
    proc = subprocess.Popen(
        args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        bufsize=fbytes * 2,
    )
    idx = 0
    try:
        assert proc.stdout is not None
        while True:
            # read() on a pipe can return short; loop until the frame is whole or
            # the stream ends, or every frame after the first short read is garbage.
            chunks, want = [], fbytes
            while want > 0:
                c = proc.stdout.read(want)
                if not c:
                    break
                chunks.append(c)
                want -= len(c)
            if want > 0:
                break  # partial or no frame: end of stream
            buf = b"".join(chunks) if len(chunks) > 1 else chunks[0]
            # Slice plane 0. No conversion, no copy beyond the reshape view's own.
            luma = np.frombuffer(buf[:ybytes], dtype=np.uint8).reshape(
                pr.height, pr.width
            )
            yield Frame(
                index=idx,
                t_offset_s=t0 + (idx * step_s if step_s else float(idx)),
                luma=luma,
            )
            idx += 1
    finally:
        if proc.stdout:
            proc.stdout.close()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        err = b""
        if proc.stderr:
            try:
                err = proc.stderr.read() or b""
            except (OSError, ValueError):
                pass
            proc.stderr.close()
        # A frame source that silently yields NOTHING is the shape of failure that
        # already cost this booth a stale installer: pkg-config existed, could not
        # execute, and every step downstream reported success while rebuilding
        # nothing. Refuse to be quiet about it.
        if idx == 0:
            raise RuntimeError(
                "decoder produced no frames"
                + (f" (exit {proc.returncode}): " + err.decode("utf-8", "replace")[:400]
                   if err or proc.returncode else "")
            )
