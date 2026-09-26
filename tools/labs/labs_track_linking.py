"""B6 track_linking: foreground blobs into tracks, tracks into EPISODES.

An episode is one thing that entered, stayed and left. One observation per
episode, and each field is one claim:

    start_time, end_time   the first and last instant the thing was SEEN
                           (sampled at ~5 fps), on the segments' wall clock.
    object_count           1: one tracked region. A group walking shoulder to
                           shoulder is one region and one episode.
    bbox_x..h              the union of every box the episode occupied,
                           normalised 0..1. Where it went, not how big it was.
    metrics                dwell_s; entry_edge and exit_edge (left, right, top,
                           bottom, or inside when it appeared or vanished away
                           from every edge; null when the footage began or
                           ended while it was being tracked, with open_start /
                           open_end true); a PATH SUMMARY: entry_x/entry_y,
                           exit_x/exit_y, net_disp, path_len, straightness,
                           mean_speed, heading (8-way, image terms), points;
                           the path itself as 24 equal-time points in a 48
                           character string (`path`, decoded by
                           decode_path); and how it was measured: tracks,
                           max_gap_s, area_frac_median, aspect, frame_step_s.
                           22 keys at most (the contract allows 24).

WHAT IT IS BUILT ON. labs_foreground_mask (B3) makes the blobs; this module
never edits it. B3's own window scoring primes its model on the window, which
is right for window statistics and wrong here: priming shows the model the
whole window first, so anything that stood still for part of it is already
background and a stop splits an episode. So B3 runs in STREAM mode here (one
model for the whole hour), with its first 60 s fed once in reverse before the
start (`with_preroll`) because a young model flags foliage it has not seen move
(measured at 3 fps: the first 2 minutes of the day hour held 26 episodes
without the preroll and 13 with it, against 0-27 per 2 minutes after).

FIVE FPS, NOT KEYFRAMES. Keyframes are 3.3-4 s apart on this fleet; a walker
crosses the frame in 3-4 keyframes and nothing can be linked. Every 3rd frame
of sub (15 fps, measured) is ~5 fps. Against a 15 fps run of the same two
10-minute spans, 5 fps reproduced 41 of 56 episodes of 3 s or more, 3 fps 37
and 1.5 fps 36, and on this box 5 fps cost no measurably more than 3 fps
(findings doc). Decoding is software only (no -hwaccel: the shared iGPU wedges
on VA-API context creation), -threads 1, ONE ffmpeg for the whole input, fed
an iterable of chunks; every frame is decoded either way, only every 3rd is
scaled and modelled.

SEGMENT JOINTS ARE NOT CONTINUOUS, AND THIS MODULE DOES NOT PRETEND THEY ARE.
Every segment's PTS restarts at 1.4 s. ffmpeg's default MPEG-TS handling
re-bases each reset so time runs on smoothly, which also ERASES a missing
segment: segments 0 and 2 fed together decoded as 63.4 s of continuous time
with no step over 0.2 s (measured). So the decoder runs with -copyts, every
decoded frame's PTS is read (showinfo before the frame selection), each reset
starts the next segment, and a frame's time is its own segment's start_time
plus its offset in that segment (`SegmentClock`). A hole between segments is
then a real step in time; a step over Config.hole_s ends every track and
flags the episodes it cut as open. start_time carries no fraction of a second
on this fleet (120 of 120 rows in the day hour), and 58 of its 119 joints
begin 0.02-0.83 s before the previous segment's end, so a segment that would
start before its predecessor's last frame is moved later instead (at most
0.93 s in every sample measured). If the PTS pieces and the segments cannot be matched one to
one, analyse() raises TimelineError rather than place frames on the wrong
segment.

LINKING. Blobs stacked vertically in one frame are merged first (a standing
person comes out of MOG2 as head, torso and legs). Tracks: greedy one-to-one
association on distance to the constant-velocity prediction, gated by
0.03 + 0.1 x dt + 0.5 x size (frame widths; 1.0 x dt for a track's first step,
which has no velocity yet); unmatched blobs touching a matched
one are its fragments; a track unmatched for 1.5 s ends. Episodes: a track
that starts within 4 s of another ending AWAY from an edge, near where that
one was heading, continues its episode (an occluder, a dropout). Something
that left by an edge has left. Episodes under 4 points or 1 s are dropped.

WHAT WAS MEASURED (docs/findings/2026-09-26-labs-track_linking.md):
  * cost 37.6-42.5 CPU-s per camera-hour (3 runs, median 39.0; busy day sub
    hour, 640x360, getrusage self + children, cv2.setNumThreads(1)); 219.9
    with OpenCV's default thread pool (1 run). 82.4 MB of sub for that hour.
    CALL cv2.setNumThreads(1) IN THE WORKER: this module does not change
    process-wide state behind the caller's back.
  * the busy entrance hour: 197 episodes; dwell p10/p50/p90/max 1.6 / 6.4 /
    21.8 / 62.6 s. In three hand-labelled 2-minute windows each of the 10
    clearly visible passages was ONE episode end to end, including a man who
    left the door, rode a bicycle, sat on the bench and rode off (62.6 s);
    far-path pedestrians too small to label were not scored. The same
    windows held 29 other episodes.
  * a random 12 of the 197, rendered and inspected: 5 real (3 whole
    passages, 2 partial), 7 artifacts, all at two fixed places (a glass door,
    sunlit steps). 4 minutes of IR night: 18 short episodes, every one
    touching the same edge at both ends; two rendered (from a 3 fps run)
    showed no object. A BLOB IS NOT AN OBJECT, and an episode is a blob's
    history. No object_class, confidence, shape_class or scene_light is set.

WHAT IT CANNOT SEE. A thing that stops for longer than about 10 s is absorbed
by the background model (synthetic walk-stop-walk through link_frames, at 3
and at 5 fps alike: stops of 0-10 s stayed one episode, 15 s and more split
into an arrival that exits "inside" and a departure that enters "inside" at
the same spot). In the first minute of the input, which the preroll teaches
the model, 10 s already splits. Anything seen for under a second is dropped
(min_dwell_s).
"""
from __future__ import annotations

import logging
import math
import queue
import re
import subprocess
import threading
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable, Iterator, Sequence

import numpy as np

import labs_foreground_mask as fm

logger = logging.getLogger(__name__)

ANALYZER = "track_linking"
VERSION = "b6-1"

#: The edges an episode can enter or leave by. "inside" means it appeared or
#: vanished away from every edge (a doorway, an occluder, or something that
#: stopped and was absorbed by the background model).
EDGES = ("left", "right", "top", "bottom", "inside")

#: 8-way heading of the NET displacement, in IMAGE terms: N is toward the top
#: of the frame, E toward the right. Not compass north.
HEADINGS = ("E", "NE", "N", "NW", "W", "SW", "S", "SE")

#: The server's per-unit ceiling (routers/labs.py MAX_OBSERVATIONS_PER_UNIT).
MAX_OBSERVATIONS = 500

#: Alphabet for the encoded path: base64url order, one character per coordinate.
PATH_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"


@dataclass(frozen=True)
class Config:
    """Every constant that decides a link, in one place. Distances are in FRAME
    WIDTHS (isotropic: y is measured in the same pixels as x), times in seconds."""

    #: Keep every Nth decoded frame. Sub is 15 fps on this fleet (measured), so
    #: 3 gives ~5 fps (findings doc, "sampling": 5 fps agreed best with 15 fps
    #: and gives a car crossing the frame in 1 s six points instead of four).
    every_nth: int = 3
    #: A frame-to-frame step longer than this is a HOLE in the footage (a missing
    #: segment, a decoder that dropped a stretch): every track ends there and no
    #: episode is linked across it. Episodes cut by it are flagged open.
    hole_s: float = 2.0
    #: A track that has not been matched for this long ends.
    coast_s: float = 1.5
    #: Association gate: radius = gate_base + gate_speed * dt + gate_size * size.
    #: gate_speed is the unpredicted part of the motion: the prediction already
    #: carries the track's velocity. A track with ONE point has no velocity
    #: yet, so its first step gets gate_speed_new instead; without it a car
    #: crossing the frame in 1.5 s (0.54 frame widths/s) was lost entirely
    #: (synthetic, pinned by test_a_fast_car_is_one_episode).
    gate_base: float = 0.03
    gate_speed: float = 0.1
    gate_speed_new: float = 1.0
    gate_size: float = 0.5
    #: A velocity estimate is clipped to this (frame widths per second).
    max_speed: float = 1.5
    #: Two detections whose areas differ by more than this factor never match.
    max_area_ratio: float = 8.0
    #: An unmatched blob whose box, grown by this margin, touches the box a
    #: track matched in the same frame is a FRAGMENT of that track's object.
    fragment_margin: float = 0.01
    #: Before association, blobs STACKED vertically in one frame are merged into
    #: one detection: their x-ranges overlap by at least stack_overlap of the
    #: narrower box, and the vertical gap between the boxes is at most
    #: stack_gap times the taller box's height. That is how a standing person
    #: comes out of MOG2 (head, torso and legs as separate blobs once the
    #: middle is partly absorbed); two people side by side are NOT merged.
    stack_overlap: float = 0.5
    stack_gap: float = 0.5
    #: Episode linking: a track that starts within link_gap_s of another track
    #: ending away from an edge, within link_base + link_speed * gap + size,
    #: continues that episode.
    link_gap_s: float = 4.0
    link_base: float = 0.03
    link_speed: float = 0.03
    #: The link predicts where the lost thing went at its last velocity, for at
    #: most this long (a walker does not keep walking straight through a door).
    link_predict_s: float = 2.0
    #: A box within this fraction of an edge touches it.
    edge_margin: float = 0.02
    #: An episode with fewer observed points or a shorter span is not reported.
    min_points: int = 4
    min_dwell_s: float = 1.0
    #: Points in the encoded path string (two characters each).
    path_points: int = 24
    #: The background model under the blobs: B3's Config with a 10 s warm-up.
    #: Used in STREAM mode (prime=False), not B3's primed mode: priming shows
    #: the model the whole window first, so anything that stood still for part
    #: of it is background before it is scored, and a stop splits an episode.
    #: Measured on a synthetic walk-stop-walk (findings doc, "stays"): primed,
    #: a 10 s stop split the episode in two; streamed on a matured model, a
    #: stopped thing stayed foreground 9.5 s at history_s 100 (31.9 s at 300,
    #: 64.9 s at 600), so stops up to about 0.1 x history_s stay one episode.
    mask: fm.Config = replace(fm.DEFAULT, warmup_s=10.0)
    prime: bool = False
    #: A young stream model flags foliage and light it has not yet seen vary.
    #: Before the first real frame, the first `preroll_s` of footage is fed to
    #: the model once in REVERSE, at synthetic times just before the start, and
    #: never scored or linked: B3's priming, applied only where the model is
    #: young. 0 disables it.
    preroll_s: float = 60.0


DEFAULT = Config()


# ---------------------------------------------------------------------------
# timeline: raw per-segment PTS to seconds from the window origin
# ---------------------------------------------------------------------------
class TimelineError(RuntimeError):
    """The decoded frames cannot be placed on the segments' wall clock."""


def _when(seg: Any, key: str) -> datetime | None:
    v = seg.get(key) if isinstance(seg, dict) else getattr(seg, key, None)
    if v is None or isinstance(v, datetime):
        if isinstance(v, datetime) and v.tzinfo is None:
            raise ValueError(f"{key} is a naive datetime: refusing to guess its zone")
        return v
    t = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    if t.tzinfo is None:
        raise ValueError(f"{key} has no offset: {v!r}")
    return t


def _duration(seg: Any) -> float | None:
    v = seg.get("duration_s") if isinstance(seg, dict) else getattr(seg, "duration_s", None)
    if v is not None:
        return float(v)
    st, en = _when(seg, "start_time"), _when(seg, "end_time")
    return (en - st).total_seconds() if (st and en) else None


class SegmentClock:
    """Places each decoded frame on the WALL CLOCK of the segment it came from.

    WHY NOT THE DECODER'S TIMELINE. Every segment's PTS restarts at 1.4 s
    (measured on this fleet), and ffmpeg's default MPEG-TS handling re-bases a
    jump that large so time runs on smoothly. That also erases a MISSING
    segment: fed segments 0 and 2 of three, the default timeline ran a
    continuous 63.4 s with no step over 0.2 s, hiding a 28 s hole (measured;
    findings doc). A tracker trusting it would link a person to whoever stood
    there half a minute later.

    So the decoder runs with -copyts, each PTS reset marks the next segment,
    and a frame's time is that segment's start_time plus its offset from the
    segment's first decoded frame. A hole between segments is then a real step
    in time, and the tracker ends every track across it.

    A step back of more than `reset_s` is a reset. Refuses rather than
    guesses: more PTS pieces than segments, or a piece running more than
    `slack_s` past its segment's duration (a reset that was never seen),
    raises TimelineError, and so does analyse() when fewer pieces than
    segments decoded (a segment with no decodable frame, or one shorter than
    reset_s, which cannot be told from its neighbour).
    """

    def __init__(self, starts_s: Sequence[float], durations_s: Sequence[float | None],
                 *, reset_s: float = 1.0, slack_s: float = 3.0):
        if not starts_s:
            raise ValueError("no segments to place frames on")
        self.starts = [float(s) for s in starts_s]
        self.durations = list(durations_s)
        self.reset_s = reset_s
        self.slack_s = slack_s
        self.k = -1
        self.p0: float | None = None
        self.base = 0.0
        self.prev_pts: float | None = None
        self.last_t: float | None = None
        self.last_step: float | None = None
        #: joints where the next segment's start_time fell BEFORE the previous
        #: segment's last frame, so the whole segment was moved later by
        #: `shift_max_s` at most. start_time carries no fraction of a second on
        #: this fleet (measured: 58 of 119 joints in a day hour lie 0.02-0.83 s
        #: early), so the stored start can be up to a second off.
        self.shifts = 0
        self.shift_max_s = 0.0
        #: frames whose PTS did not advance within a segment, nudged by 1 ms.
        self.folds = 0

    def place(self, pts: float) -> float:
        if self.prev_pts is None or pts < self.prev_pts - self.reset_s:
            self.k += 1
            if self.k >= len(self.starts):
                raise TimelineError(
                    f"PTS reset #{self.k} but only {len(self.starts)} segments were supplied")
            self.p0 = pts
            self.base = self.starts[self.k]
            if self.last_t is not None:
                # One frame step after the previous frame, never more than
                # 0.5 s: a stretch of dropped frames must not push the whole
                # next segment later.
                floor = self.last_t + min(self.last_step or 1.0 / 15.0, 0.5)
                if self.base < floor - 1e-6:
                    self.shifts += 1
                    self.shift_max_s = max(self.shift_max_s, floor - self.base)
                    self.base = floor
            self.prev_pts = pts
            t = self.base
        else:
            off = pts - self.p0
            dur = self.durations[self.k]
            if dur is not None and off > dur + self.slack_s:
                raise TimelineError(
                    f"segment {self.k}: frame {off:.1f} s in, but the segment lasts {dur:.1f} s;"
                    " a PTS reset was missed, so frames cannot be placed")
            t = self.base + off
            if self.last_t is not None and t <= self.last_t:
                t = self.last_t + 1e-3
                self.folds += 1
            elif self.last_t is not None:
                self.last_step = t - self.last_t
            self.prev_pts = pts
        self.last_t = t
        return t

    @property
    def pieces(self) -> int:
        return self.k + 1


def segment_origin(segments: Sequence[Any]) -> tuple[datetime, list[float], list[float | None]]:
    """(origin, starts_s, durations_s) for a window's segments, in the order fed."""
    starts = [_when(s, "start_time") for s in segments]
    if any(s is None for s in starts):
        raise ValueError("every segment needs a start_time to place its frames")
    origin = starts[0]
    return (origin, [(s - origin).total_seconds() for s in starts],
            [_duration(s) for s in segments])


# ---------------------------------------------------------------------------
# decode: ONE long-lived software decoder, per-segment wall clock
# ---------------------------------------------------------------------------
_SHOWINFO = re.compile(r"\bn:\s*(\d+)\s+pts:\s*[-0-9]+\s+pts_time:\s*([-+0-9.eE]+)")


def decode_placed(source: Iterable[bytes] | bytes, clock: SegmentClock, *,
                  every_nth: int = DEFAULT.every_nth, width: int = fm.DEFAULT.work_width,
                  ffmpeg: str = "ffmpeg", timeout_s: float = 600.0
                  ) -> Iterator[tuple[float, np.ndarray]]:
    """Yield (t_s, luma) with t_s on the segments' wall clock (see SegmentClock).

    One software ffmpeg (-threads 1, no -hwaccel: the shared iGPU wedges on
    VA-API context creation) fed an iterable of chunks. Every decoded frame's
    PTS is read from a showinfo placed BEFORE the frame selection, so segment
    joints are found at full frame rate and a segment's first frame anchors its
    clock exactly; only every Nth frame is scaled and piped out.
    """
    n_keep = max(1, int(every_nth))
    vf = ["showinfo=checksum=0"]
    if n_keep > 1:
        vf.append(f"select=not(mod(n\\,{n_keep}))")
    vf += [f"scale={int(width)}:-2:flags=area", "format=gray"]
    cmd = [ffmpeg, "-hide_banner", "-nostats", "-loglevel", "info",
           "-threads", "1", "-filter_threads", "1", "-copyts",
           "-fflags", "+discardcorrupt", "-i", "pipe:0", "-map", "0:v:0",
           "-an", "-sn", "-dn", "-fps_mode", "passthrough", "-vf", ",".join(vf),
           "-c:v", "pgm", "-f", "image2pipe", "pipe:1"]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    pts_q: "queue.Queue[tuple[int, float] | None]" = queue.Queue()
    errors: list[str] = []
    feed_errors: list[BaseException] = []

    def _feed() -> None:
        chunks = [source] if isinstance(source, (bytes, bytearray, memoryview)) else source
        try:
            for chunk in chunks:
                try:
                    proc.stdin.write(chunk)
                except (BrokenPipeError, OSError):
                    return
        except BaseException as e:          # the SOURCE failed mid-window
            feed_errors.append(e)
        finally:
            try:
                proc.stdin.close()
            except OSError:
                pass

    def _drain() -> None:
        for raw_line in iter(proc.stderr.readline, b""):
            line = raw_line.decode("utf-8", "replace")
            m = _SHOWINFO.search(line) if "showinfo" in line else None
            if m:
                try:
                    pts_q.put((int(m.group(1)), float(m.group(2))))
                except ValueError:
                    pass
            elif "rror" in line:
                errors.append(line.strip())
                del errors[:-20]
        pts_q.put(None)

    feeder = threading.Thread(target=_feed, daemon=True)
    drainer = threading.Thread(target=_drain, daemon=True)
    feeder.start()
    drainer.start()
    produced = 0
    want = 0                     # decoded index of the next output frame
    placed: dict[int, float] = {}
    done_pts = False
    try:
        while True:
            head = [proc.stdout.readline() for _ in range(3)]
            if not head[0]:
                break
            if head[0].strip() != b"P5":
                raise RuntimeError(f"unexpected decoder output {head[0][:16]!r}")
            w, h = (int(v) for v in head[1].split())
            buf = proc.stdout.read(w * h)
            if len(buf) < w * h:
                break
            # Advance the clock over EVERY decoded frame up to this one.
            while want not in placed and not done_pts:
                try:
                    item = pts_q.get(timeout=30.0)
                except queue.Empty:
                    raise RuntimeError("decoder produced a frame with no showinfo line")
                if item is None:
                    done_pts = True
                    break
                n, pts = item
                placed[n] = clock.place(pts)
                for old in [k for k in placed if k < want]:
                    del placed[old]
            if want not in placed:
                raise RuntimeError(f"no timestamp for decoded frame {want}")
            t = placed.pop(want)
            produced += 1
            want += n_keep
            yield t, np.frombuffer(buf, dtype=np.uint8).reshape(h, w)
        # Drain the rest so the clock sees every reset (piece count is checked).
        while not done_pts:
            try:
                item = pts_q.get(timeout=30.0)
            except queue.Empty:
                break
            if item is None:
                break
            clock.place(item[1])
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


# ---------------------------------------------------------------------------
# tracks and episodes
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Point:
    """One observation of a tracked thing. Normalised 0..1 like the Labs bbox."""

    t: float
    cx: float
    cy: float
    x: float
    y: float
    w: float
    h: float
    area_frac: float


@dataclass
class _Track:
    id: int
    points: list[Point]
    aspect: float                   # frame height / width, for isotropic distance
    vx: float = 0.0                 # frame widths per second
    vy: float = 0.0
    episode: "_Episode | None" = None
    #: lost (unmatched past coast_s), cut (model rebuilt), end (hole or end of input)
    end_reason: str | None = None

    @property
    def last(self) -> Point:
        return self.points[-1]

    def size(self) -> float:
        p = self.last
        return max(p.w, p.h * self.aspect)


@dataclass
class _Episode:
    id: int
    tracks: list[_Track] = field(default_factory=list)
    open_start: bool = False
    open_end: bool = False


def _edge(p: Point, margin: float) -> str:
    """Which frame edge a box touches, or 'inside'. Several touched: the one
    the box reaches furthest into (smallest clearance)."""
    gaps = {"left": p.x, "right": 1.0 - (p.x + p.w), "top": p.y, "bottom": 1.0 - (p.y + p.h)}
    touching = {k: v for k, v in gaps.items() if v <= margin}
    if not touching:
        return "inside"
    return min(touching.items(), key=lambda kv: (kv[1], EDGES.index(kv[0])))[0]


def _dist(ax: float, ay: float, bx: float, by: float, aspect: float) -> float:
    """Distance in frame widths between two normalised points."""
    return math.hypot(ax - bx, (ay - by) * aspect)


def _overlap(a: tuple[float, float, float, float], b: tuple[float, float, float, float],
             m: float) -> bool:
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return (ax - m < bx + bw and bx - m < ax + aw and ay - m < by + bh and by - m < ay + ah)


def _union(ps: Sequence[Point] | Sequence[tuple[float, float, float, float]]
           ) -> tuple[float, float, float, float]:
    boxes = [(p.x, p.y, p.w, p.h) if isinstance(p, Point) else p for p in ps]
    x0 = min(b[0] for b in boxes)
    y0 = min(b[1] for b in boxes)
    x1 = max(b[0] + b[2] for b in boxes)
    y1 = max(b[1] + b[3] for b in boxes)
    return x0, y0, x1 - x0, y1 - y0


def merge_stacked(dets: Sequence[Point], overlap: float, gap: float) -> tuple[list[Point], int]:
    """Merge vertically stacked detections of one frame (see Config.stack_*).

    Returns the merged detections (area-weighted centroid, union box, summed
    area) and how many merges happened. Union-find, so a head, torso and legs
    chain into one detection.
    """
    n = len(dets)
    parent = list(range(n))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    merges = 0
    for i in range(n):
        a = dets[i]
        for j in range(i + 1, n):
            b = dets[j]
            ov = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
            if ov < overlap * min(a.w, b.w):
                continue
            vgap = max(a.y, b.y) - min(a.y + a.h, b.y + b.h)
            if vgap <= gap * max(a.h, b.h):
                ri, rj = find(i), find(j)
                if ri != rj:
                    parent[rj] = ri
                    merges += 1
    if merges == 0:
        return list(dets), 0
    groups: dict[int, list[Point]] = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(dets[i])
    return [_combine(g) for g in groups.values()], merges


def _combine(parts: Sequence[Point]) -> Point:
    if len(parts) == 1:
        return parts[0]
    area = sum(q.area_frac for q in parts)
    cx = sum(q.cx * q.area_frac for q in parts) / area
    cy = sum(q.cy * q.area_frac for q in parts) / area
    return Point(parts[0].t, cx, cy, *_union(parts), area)


@dataclass(frozen=True)
class Episode:
    """Something entered, stayed, left. Frozen: this is a measurement."""

    #: seconds from the window origin (the first segment's start_time)
    t_start: float
    t_end: float
    points: tuple[Point, ...]
    tracks: int
    entry_edge: str | None
    exit_edge: str | None
    open_start: bool
    open_end: bool
    aspect: float
    frame_step_s: float | None

    # --- derived ------------------------------------------------------------
    @property
    def dwell_s(self) -> float:
        return self.t_end - self.t_start

    @property
    def bbox(self) -> tuple[float, float, float, float]:
        x, y, w, h = _union(self.points)
        x, y = min(max(x, 0.0), 1.0), min(max(y, 0.0), 1.0)
        w = min(max(w, 1e-6), 1.0 - x) if x < 1.0 else 1e-6
        h = min(max(h, 1e-6), 1.0 - y) if y < 1.0 else 1e-6
        return x, y, max(w, 1e-6), max(h, 1e-6)

    @property
    def path_len(self) -> float:
        a = self.aspect
        return float(sum(_dist(p.cx, p.cy, q.cx, q.cy, a)
                         for p, q in zip(self.points, self.points[1:])))

    @property
    def net_disp(self) -> float:
        p, q = self.points[0], self.points[-1]
        return _dist(p.cx, p.cy, q.cx, q.cy, self.aspect)

    @property
    def straightness(self) -> float | None:
        pl = self.path_len
        return (self.net_disp / pl) if pl > 1e-9 else None

    @property
    def mean_speed(self) -> float | None:
        return (self.path_len / self.dwell_s) if self.dwell_s > 1e-9 else None

    @property
    def heading(self) -> str | None:
        p, q = self.points[0], self.points[-1]
        dx, dy = q.cx - p.cx, (q.cy - p.cy) * self.aspect
        if math.hypot(dx, dy) < 1e-6:
            return None
        ang = math.degrees(math.atan2(-dy, dx)) % 360.0     # image y grows down
        return HEADINGS[int(((ang + 22.5) % 360.0) // 45.0)]

    @property
    def max_gap_s(self) -> float:
        ts = [p.t for p in self.points]
        return max((b - a for a, b in zip(ts, ts[1:])), default=0.0)

    def path_string(self, n: int = DEFAULT.path_points) -> str:
        """The trajectory as `n` points at EQUAL TIME steps, 2 characters each.

        Each coordinate is quantised to 64 levels of its axis (x of the width,
        y of the height, like the bbox) and written as one PATH_ALPHABET
        character: decode with (index + 0.5) / 64. Equal time, not equal arc
        length, so a pause shows as repeated points. An episode with fewer
        observed points than `n` is written at its own points.
        """
        ts = np.array([p.t for p in self.points])
        xs = np.array([p.cx for p in self.points])
        ys = np.array([p.cy for p in self.points])
        if len(ts) > n:
            grid = np.linspace(ts[0], ts[-1], n)
            xs, ys = np.interp(grid, ts, xs), np.interp(grid, ts, ys)
        out = []
        for x, y in zip(xs, ys):
            out.append(PATH_ALPHABET[min(63, max(0, int(x * 64)))])
            out.append(PATH_ALPHABET[min(63, max(0, int(y * 64)))])
        return "".join(out)

    def path_step_s(self, n: int = DEFAULT.path_points) -> float | None:
        """Seconds between consecutive `path` points (None: the points are the
        observed ones, at the frame step)."""
        if len(self.points) > n:
            return self.dwell_s / (n - 1)
        return None

    def as_metrics(self, config: Config | None = None) -> dict:
        """The `metrics` payload: scalars only, slug keys, at most 24 keys."""
        cfg = config or DEFAULT
        p, q = self.points[0], self.points[-1]
        a = self.aspect
        area = float(np.median([pt.area_frac for pt in self.points]))
        m: dict[str, Any] = {
            "dwell_s": round(self.dwell_s, 2),
            "entry_edge": self.entry_edge,
            "exit_edge": self.exit_edge,
            "entry_x": round(p.cx, 4), "entry_y": round(p.cy, 4),
            "exit_x": round(q.cx, 4), "exit_y": round(q.cy, 4),
            "net_disp": round(self.net_disp, 4),
            "path_len": round(self.path_len, 4),
            "points": len(self.points),
            "tracks": self.tracks,
            "max_gap_s": round(self.max_gap_s, 2),
            "area_frac_median": round(area, 6),
            "open_start": self.open_start,
            "open_end": self.open_end,
            "aspect": round(a, 4),
            "path": self.path_string(cfg.path_points),
        }
        # Absent rather than invented when undefined: a thing that never moved
        # has no heading and no straightness, and a zero would be a claim.
        if self.straightness is not None:
            m["straightness"] = round(self.straightness, 3)
        if self.mean_speed is not None:
            m["mean_speed"] = round(self.mean_speed, 4)
        if self.heading is not None:
            m["heading"] = self.heading
        step = self.path_step_s(cfg.path_points)
        if step is not None:
            m["path_step_s"] = round(step, 3)
        if self.frame_step_s is not None:
            m["frame_step_s"] = round(self.frame_step_s, 3)
        return m

    def as_observation(self, origin: datetime, config: Config | None = None) -> dict:
        """A complete ObservationIn dict. `origin` is the window's first segment
        start_time (aware). Never sets object_class, confidence or shape_class:
        a track of foreground blobs measures where changed pixels went, not
        what they are."""
        if origin.tzinfo is None:
            raise ValueError("naive origin: refusing to guess its zone")
        st = origin + timedelta(seconds=self.t_start)
        en = origin + timedelta(seconds=self.t_end)
        x, y, w, h = self.bbox
        return {"start_time": _iso(st), "end_time": _iso(en), "object_count": 1,
                "bbox_x": round(x, 6), "bbox_y": round(y, 6),
                "bbox_w": round(max(w, 1e-6), 6), "bbox_h": round(max(h, 1e-6), 6),
                "metrics": self.as_metrics(config)}


def decode_path(path: str) -> list[tuple[float, float]]:
    """The inverse of Episode.path_string: [(x, y)] normalised 0..1, at the
    centre of each 1/64 cell."""
    if len(path) % 2:
        raise ValueError("a path string has an even number of characters")
    idx = [PATH_ALPHABET.index(c) for c in path]
    return [((idx[i] + 0.5) / 64.0, (idx[i + 1] + 0.5) / 64.0) for i in range(0, len(idx), 2)]


def _iso(t: datetime) -> str:
    return t.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


@dataclass
class LinkStats:
    """What the linker saw: for the caller's logs and the findings, never sent."""

    frames: int = 0
    scored_frames: int = 0
    skipped_frames: int = 0         # warm-up or global-change frames: blobs unused
    holes: int = 0                  # steps longer than Config.hole_s
    run_changes: int = 0            # background model rebuilt (fm MaskFrame.run)
    tracks: int = 0
    episodes: int = 0
    dropped_short: int = 0          # below min_points or min_dwell_s
    stacked_merged: int = 0
    fragments_merged: int = 0
    late_links: int = 0             # a new track joined a just-lost one's episode
    frame_step_s: float | None = None


class Linker:
    """Online: feed MaskFrames in time order, then finish() for the Episodes.

    Holds only the active tracks and the episodes that could still be
    continued, so an hour streams through it in bounded memory.

    Time must be TRUE wall-clock seconds from one origin (decode_placed gives
    that). The linker never assumes two frames are adjacent: every gate is
    scaled by the real step, a step longer than Config.hole_s ends every track,
    and a change of background model (MaskFrame.run) ends every track too,
    because the blobs on either side of it come from different models.
    """

    def __init__(self, config: Config | None = None):
        self.cfg = config or DEFAULT
        self.stats = LinkStats()
        self._active: list[_Track] = []
        self._pending: list[_Episode] = []      # last track ended; may be continued
        self._done: list[Episode] = []
        self._next_track = 0
        self._next_ep = 0
        self._last_t: float | None = None
        self._stretch_t0: float | None = None   # first scored frame since start or hole
        self._run: int | None = None
        self._steps: list[float] = []
        self._aspect: float = 9.0 / 16.0

    # --- public -------------------------------------------------------------
    def feed(self, mf: Any) -> None:
        """One fm.MaskFrame (or anything with t_s, run, scored, blobs, width, height)."""
        cfg = self.cfg
        t = mf.t_s
        if t is None:
            raise ValueError("track linking needs a timestamp on every frame")
        if self._last_t is not None and t < self._last_t - 1e-6:
            raise ValueError(f"time ran backwards: {t:.3f} after {self._last_t:.3f}")
        self.stats.frames += 1
        self._aspect = mf.height / float(mf.width)
        if self._last_t is not None:
            dt = t - self._last_t
            if dt > cfg.hole_s:
                self.stats.holes += 1
                self._close_stretch()
            elif self._run is not None and mf.run != self._run:
                self.stats.run_changes += 1
                for tr in self._active:
                    self._end_track(tr, "cut")
                self._active = []
                self._steps.append(dt)
            else:
                self._steps.append(dt)
        self._run = mf.run
        self._last_t = t
        self._expire(t)
        if not mf.scored:
            self.stats.skipped_frames += 1
            return
        self.stats.scored_frames += 1
        if self._stretch_t0 is None:
            self._stretch_t0 = t
        dets = [Point(t, b.cx / b.frame_w, b.cy / b.frame_h, *b.bbox, b.area_frac)
                for b in mf.blobs]
        dets, merged = merge_stacked(dets, cfg.stack_overlap, cfg.stack_gap)
        self.stats.stacked_merged += merged
        self._associate(t, dets)

    def finish(self) -> list[Episode]:
        """End everything still open and return every episode, in start order."""
        self._close_stretch()
        step = float(np.median(self._steps)) if self._steps else None
        self.stats.frame_step_s = step
        eps = sorted(self._done, key=lambda e: (e.t_start, e.t_end))
        eps = [replace(e, frame_step_s=step) for e in eps]
        self.stats.episodes = len(eps)
        return eps

    # --- association --------------------------------------------------------
    def _associate(self, t: float, dets: list[Point]) -> None:
        cfg, a = self.cfg, self._aspect
        pairs: list[tuple[float, int, int]] = []
        for i, tr in enumerate(self._active):
            lp = tr.last
            dt = t - lp.t
            px, py = lp.cx + tr.vx * dt, lp.cy + tr.vy * dt / a
            speed = cfg.gate_speed_new if len(tr.points) == 1 else cfg.gate_speed
            gate = cfg.gate_base + speed * dt + cfg.gate_size * tr.size()
            for j, d in enumerate(dets):
                r = max(d.area_frac, 1e-9) / max(lp.area_frac, 1e-9)
                if r > cfg.max_area_ratio or r < 1.0 / cfg.max_area_ratio:
                    continue
                dist = _dist(px, py, d.cx, d.cy, a)
                if dist <= gate:
                    pairs.append((dist / gate, i, j))
        pairs.sort()
        used_t: set[int] = set()
        used_d: set[int] = set()
        matched: dict[int, list[int]] = {}
        for _, i, j in pairs:                    # greedy, cheapest first
            if i in used_t or j in used_d:
                continue
            used_t.add(i)
            used_d.add(j)
            matched[i] = [j]
        # Fragments: an unmatched blob touching a matched blob's box is part of
        # the same object (a body cut by a railing, a person and their shadow).
        for j, d in enumerate(dets):
            if j in used_d:
                continue
            box = (d.x, d.y, d.w, d.h)
            for i, js in matched.items():
                if any(_overlap(box, (dets[k].x, dets[k].y, dets[k].w, dets[k].h),
                                cfg.fragment_margin) for k in js):
                    js.append(j)
                    used_d.add(j)
                    self.stats.fragments_merged += 1
                    break
        for i, js in matched.items():
            self._extend(self._active[i], [dets[j] for j in js])
        for j, d in enumerate(dets):
            if j not in used_d:
                self._start(d)

    def _extend(self, tr: _Track, parts: list[Point]) -> None:
        cfg, a = self.cfg, self._aspect
        p = _combine(parts)
        lp = tr.last
        dt = p.t - lp.t
        if dt > 0:
            vx = (p.cx - lp.cx) / dt
            vy = (p.cy - lp.cy) * a / dt
            if len(tr.points) == 1:
                tr.vx, tr.vy = vx, vy
            else:
                tr.vx, tr.vy = 0.5 * tr.vx + 0.5 * vx, 0.5 * tr.vy + 0.5 * vy
            sp = math.hypot(tr.vx, tr.vy)
            if sp > cfg.max_speed:
                tr.vx, tr.vy = tr.vx * cfg.max_speed / sp, tr.vy * cfg.max_speed / sp
        tr.points.append(p)

    def _reach(self, last: _Track, d: Point) -> tuple[float, float]:
        """(distance, reach) from where `last` was heading to `d`, frame widths."""
        cfg, a = self.cfg, self._aspect
        lp = last.last
        gap = max(0.0, d.t - lp.t)
        pg = min(gap, cfg.link_predict_s)
        reach = cfg.link_base + cfg.link_speed * gap + cfg.gate_size * last.size()
        return _dist(lp.cx + last.vx * pg, lp.cy + last.vy * pg / a, d.cx, d.cy, a), reach

    def _linkable(self, last: _Track, d: Point) -> float | None:
        """Cost of continuing `last`'s episode with a track starting at `d`, or None."""
        cfg = self.cfg
        gap = d.t - last.last.t
        if gap <= 0 or gap > cfg.link_gap_s:
            return None
        # A thing that left by an EDGE left; only a disappearance mid-frame, or
        # a cut by a model rebuild, can be continued.
        if last.end_reason != "cut" and _edge(last.last, cfg.edge_margin) != "inside":
            return None
        dist, reach = self._reach(last, d)
        return dist / reach if dist <= reach else None

    def _start(self, d: Point) -> None:
        tr = _Track(self._next_track, [d], self._aspect)
        self._next_track += 1
        self.stats.tracks += 1
        best: tuple[float, _Episode] | None = None
        for ep in self._pending:
            cost = self._linkable(ep.tracks[-1], d)
            if cost is not None and (best is None or cost < best[0]):
                best = (cost, ep)
        if best is not None:
            ep = best[1]
            self._pending.remove(ep)
        else:
            ep = _Episode(self._next_ep)
            self._next_ep += 1
            # Seen from the first moments of the footage: it may have entered
            # before the footage began, so its entry is not claimed.
            if self._stretch_t0 is not None and d.t - self._stretch_t0 <= self.cfg.coast_s:
                ep.open_start = True
        tr.episode = ep
        ep.tracks.append(tr)
        self._active.append(tr)

    # --- ending -------------------------------------------------------------
    def _expire(self, t: float) -> None:
        keep = []
        for tr in self._active:
            if t - tr.last.t > self.cfg.coast_s:
                self._end_track(tr, "lost")
            else:
                keep.append(tr)
        self._active = keep
        still = []
        for ep in self._pending:
            if t - ep.tracks[-1].last.t > self.cfg.link_gap_s:
                self._finalise(ep)
            else:
                still.append(ep)
        self._pending = still

    def _end_track(self, tr: _Track, reason: str) -> None:
        tr.end_reason = reason
        ep = tr.episode
        if reason == "lost" and self._late_link(tr):
            return
        if ep is not None and ep not in self._pending:
            self._pending.append(ep)

    def _late_link(self, lost: _Track) -> bool:
        """A track that began while `lost` was still coasting, near where it was
        going, and is the only track of a new episode, is its continuation: the
        thing jumped further than the gate between two frames (a merge with
        another blob, a split at an occluder) rather than leaving."""
        best: tuple[float, _Track] | None = None
        for tr in self._active:
            ep = tr.episode
            if tr is lost or ep is None or len(ep.tracks) != 1 or ep is lost.episode:
                continue
            cost = self._linkable(lost, tr.points[0])
            if cost is not None and (best is None or cost < best[0]):
                best = (cost, tr)
        if best is None:
            return False
        tr = best[1]
        ep = lost.episode
        ep.tracks.append(tr)
        tr.episode = ep
        self.stats.late_links += 1
        return True

    def _close_stretch(self) -> None:
        """The footage stops (a hole or the end): end everything, and flag every
        episode still being tracked as open, because its exit was not seen."""
        for tr in self._active:
            tr.end_reason = "end"
            if tr.episode is not None:
                tr.episode.open_end = True
                if tr.episode not in self._pending:
                    self._pending.append(tr.episode)
        self._active = []
        for ep in self._pending:
            self._finalise(ep)
        self._pending = []
        self._stretch_t0 = None

    def _finalise(self, ep: _Episode) -> None:
        cfg = self.cfg
        pts = sorted((p for tr in ep.tracks for p in tr.points), key=lambda p: p.t)
        if len(pts) < cfg.min_points or pts[-1].t - pts[0].t < cfg.min_dwell_s:
            self.stats.dropped_short += 1
            return
        self._done.append(Episode(
            t_start=pts[0].t, t_end=pts[-1].t, points=tuple(pts), tracks=len(ep.tracks),
            entry_edge=None if ep.open_start else _edge(pts[0], cfg.edge_margin),
            exit_edge=None if ep.open_end else _edge(pts[-1], cfg.edge_margin),
            open_start=ep.open_start, open_end=ep.open_end, aspect=self._aspect,
            frame_step_s=None))


def link(mask_frames: Iterable[Any], config: Config | None = None
         ) -> tuple[list[Episode], LinkStats]:
    """Episodes from a stream of MaskFrames (fm.iter_masks output)."""
    lk = Linker(config)
    for mf in mask_frames:
        lk.feed(mf)
    return lk.finish(), lk.stats


@dataclass(frozen=True)
class _Frame:
    """A frame in the shape fm.iter_masks accepts (.luma, .t_offset_s) that
    says whether it is preroll. iter_masks hands it back as MaskFrame.item."""

    luma: np.ndarray
    t_offset_s: float
    preroll: bool = False


def with_preroll(frames: Iterable[tuple[float, np.ndarray]], preroll_s: float
                 ) -> Iterator[_Frame]:
    """(t_s, luma) frames, preceded by their own first `preroll_s` in reverse.

    The reversed copies carry times mirrored to BEFORE the first real frame
    (t0 - step - (t - t0)), so time never runs backwards and there is no gap
    for the model to treat as a new scene. Buffers at most preroll_s of
    frames (about 17 MB at 5 fps and 320x180).
    """
    it = iter(frames)
    head: list[tuple[float, np.ndarray]] = []
    if preroll_s > 0:
        for t, luma in it:
            head.append((t, luma))
            if t - head[0][0] >= preroll_s:
                break
    if len(head) >= 2:
        t0 = head[0][0]
        step = max(1e-3, float(np.median(np.diff([t for t, _ in head]))))
        for t, luma in reversed(head):
            yield _Frame(luma, t0 - step - (t - t0), True)
    for t, luma in head:
        yield _Frame(luma, t)
    for t, luma in it:
        yield _Frame(luma, t)


# ---------------------------------------------------------------------------
# the whole analyser, and its wire format
# ---------------------------------------------------------------------------
@dataclass
class Result:
    """One analyse() call: the episodes and everything needed to place them."""

    origin: datetime                 # the first segment's start_time
    episodes: list[Episode]
    stats: LinkStats
    segments: int
    clock_shifts: int
    clock_shift_max_s: float


def analyse(source: Iterable[bytes] | bytes, segments: Sequence[Any], *,
            config: Config | None = None, ffmpeg: str = "ffmpeg",
            timeout_s: float = 600.0) -> Result:
    """Decode consecutive segments of ONE camera and link their blobs into episodes.

    `source`: the segments' MPEG-TS bytes, streamed as chunks, in `segments`
    order. `segments`: their catalogue rows (dicts or objects with start_time,
    and duration_s or end_time), in the same order. Gaps between segments are
    allowed and are handled as holes, which is why the rows are needed at all.

    Raises TimelineError if the decoded frames cannot be matched to the
    segments one-to-one (a segment that decoded to nothing, a PTS that never
    reset): placing frames on the wrong segment would move every episode in
    time, silently.
    """
    cfg = config or DEFAULT
    origin, starts, durs = segment_origin(segments)
    clock = SegmentClock(starts, durs)
    frames = decode_placed(source, clock, every_nth=cfg.every_nth,
                           width=cfg.mask.work_width, ffmpeg=ffmpeg, timeout_s=timeout_s)
    eps, stats = link_frames(frames, cfg)
    if clock.pieces != len(starts):
        raise TimelineError(f"{clock.pieces} PTS pieces decoded for {len(starts)} segments; "
                            "frames cannot be placed on their segments")
    return Result(origin=origin, episodes=eps, stats=stats, segments=len(starts),
                  clock_shifts=clock.shifts, clock_shift_max_s=clock.shift_max_s)


def link_frames(frames: Iterable[tuple[float, np.ndarray]], config: Config | None = None
                ) -> tuple[list[Episode], LinkStats]:
    """The analyser without the decoder: (t_s, luma) frames in, episodes out.

    `t_s` must be true seconds from one origin, per segment (decode_placed
    gives that; Watchtower's per-segment frames need segment start - window
    start added, see fm._check_forward). Luma of any size; it is downscaled to
    the mask's working width. Preroll, stream-mode masks, linking.
    """
    cfg = config or DEFAULT
    lk = Linker(cfg)
    for mf in fm.iter_masks(with_preroll(frames, cfg.preroll_s), config=cfg.mask,
                            prime=cfg.prime):
        if not getattr(mf.item, "preroll", False):
            lk.feed(mf)
    return lk.finish(), lk.stats


def to_observations(result: Result, *, hour_start: datetime | None = None,
                    hour_end: datetime | None = None, limit: int = MAX_OBSERVATIONS,
                    config: Config | None = None) -> tuple[list[dict], dict]:
    """ObservationIn dicts for a unit, and a report of what was left out.

    The server refuses a whole submission if one observation STARTS outside the
    claimed hour, so episodes starting outside [hour_start, hour_end) are
    dropped here and counted (the last segment of an hour runs past its end).
    More than `limit` episodes: the ones with the most observed points are
    kept, and every kept row carries `capped_from` (the count before the cap),
    so the truncation is visible in the data rather than silent.
    """
    cfg = config or DEFAULT
    eps = list(result.episodes)
    outside = 0
    if hour_start is not None or hour_end is not None:
        keep = []
        for e in eps:
            st = result.origin + timedelta(seconds=e.t_start)
            if (hour_start is not None and st < hour_start) or \
                    (hour_end is not None and st >= hour_end):
                outside += 1
            else:
                keep.append(e)
        eps = keep
    capped_from = None
    if len(eps) > limit:
        capped_from = len(eps)
        eps = sorted(sorted(eps, key=lambda e: (-len(e.points), e.t_start))[:limit],
                     key=lambda e: (e.t_start, e.t_end))
    rows = []
    for e in eps:
        row = e.as_observation(result.origin, cfg)
        if capped_from is not None:
            row["metrics"]["capped_from"] = capped_from
        rows.append(row)
    return rows, {"episodes": len(result.episodes), "outside_hour": outside,
                  "capped_from": capped_from, "submitted": len(rows)}
