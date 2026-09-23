"""B1 illumination analyser — the PURE half of the Labs worker.

SEAM (cilex-vision's formulation, and it is better than the one I proposed):

    worker     owns claim, lease, fetch, idle-gating, retry, submit
    analyser   PURE:  (frames, segment metadata) -> observation
               no HTTP, no lease awareness, no knowledge that Labs exists

So this module imports nothing but the standard library and numpy, makes no network
call, and can be tested without a server.

WHAT IT DOES AND WHY IT IS NOT WHAT THE BRIEF ASKED FOR
=======================================================
The brief asked for day/dusk/night/ir from "mean luminance plus colour-saturation
collapse". A controlled trial on 55 street-facing cameras, 4 time slots, 12,320
frames, scored against OPERATOR-SUPPLIED labels, killed the first half of that:

    ASTRONOMY sunrise/sunset table    100.0 %    night recall 100.0 %
    bytes, per-camera normalised       82.4 %                  70.9 %
    pixel MEAN LUMINANCE, as briefed   63.0 %                  18.2 %

The majority-class baseline is 66.7 %, so mean luminance is WORSE THAN ALWAYS
ANSWERING "DAY". Auto-exposure is why: measured against real labels, full sunshine
reads 108.3 and midnight reads 104.5 -- 3.6 % between the brightest and darkest
moments of the day. McNemar: astronomy beats luma 61/0, p = 8.7e-19.

So this analyser does NOT infer day/night. The ephemeris states it; the worker passes
it in. Pixels are spent only on what astronomy cannot know.

  docs/perf/2026-09-24-b1-controlled-trial-bytes-vs-pixels.md
  docs/perf/2026-09-24-b1-phase1-what-actually-separates-day-from-night.md

THE ONE THRESHOLD, AND WHY IT IS A MARGIN RATHER THAN A TUNED CONSTANT
=====================================================================
A2 shipped `median_delta > 2.0`, tuned on night footage, and it sits below the noise
floor on 16 % of daytime segments. The lesson taken: a constant is only safe where the
populations it separates do not touch.

Measured over all 220 camera-slot rows of the trial, chroma_mean is:

    IR rows          0.0000, 0.0000          (exactly zero -- the IR-cut filter is a
    everything else  4.2944 .. 21.96          mechanical swing; closed, there is NO
                                              chroma in the frame to recover)

A 4.29-wide empty gap. Any cut inside it returns identical answers, so IR_CHROMA_MAX
is not fitted and moving it does nothing until it leaves the gap. That is the property
A2's 2.0 did not have.
"""
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Iterable, Optional
import numpy as np

# Vocabulary is fixed by cilex-vision's migration 0084 CHECK constraint and re-checked
# in the endpoint; anything else is 422 unknown_scene_light. Never invent a value here.
SCENE_LIGHT = ("day", "dusk", "night", "ir", "unknown")

# See the module docstring: the empty gap runs 0.0 .. 4.29 over 220 measured rows.
IR_CHROMA_MAX = 1.0

# A frame whose chroma planes are absent or unreadable is not evidence of IR.
MIN_FRAMES_FOR_IR = 2


@dataclass(frozen=True)
class FrameStats:
    """One decoded frame, reduced. The worker produces these; this module never decodes."""
    luma_mean: float
    chroma_energy: float          # mean(|U-128|) + mean(|V-128|); 0.0 == greyscale


@dataclass(frozen=True)
class SegmentMeta:
    camera_id: str
    # The astronomical answer for this window, from site_solar_times. The worker looks
    # it up; the analyser does not know what a sunrise is. None means the worker could
    # not resolve it, which becomes `unknown` rather than a guess.
    astronomical: Optional[str] = None
    bytes_total: Optional[int] = None
    duration_s: Optional[float] = None


@dataclass
class Observation:
    scene_light: str
    metrics: dict = field(default_factory=dict)
    notes: list = field(default_factory=list)

    def as_dict(self) -> dict:
        d = asdict(self)
        assert d["scene_light"] in SCENE_LIGHT, d["scene_light"]
        return d


def analyse(frames: Iterable[FrameStats], meta: SegmentMeta) -> Observation:
    """(frames, segment metadata) -> observation. Pure: no IO, no clock, no network."""
    fs = list(frames)
    notes: list[str] = []

    if not fs:
        return Observation("unknown", {"n_frames": 0},
                           ["no frames decoded; not a claim about the scene"])

    luma = np.array([f.luma_mean for f in fs], dtype=float)
    chroma = np.array([f.chroma_energy for f in fs], dtype=float)

    metrics = {
        "n_frames": len(fs),
        "luma_mean": float(luma.mean()),
        "luma_sd": float(luma.std()),
        "chroma_mean": float(chroma.mean()),
        "chroma_sd": float(chroma.std()),
        "chroma_max": float(chroma.max()),
    }
    if meta.bytes_total and meta.duration_s:
        # Carried as DATA, not as a decision. It beat pixels for day/night (82.4 % vs
        # 63.0 %) and lost to astronomy 29/0, so it has no vote here -- but within
        # astronomical darkness it is the only signal that distinguishes a floodlit
        # forecourt from a dark alley, which astronomy cannot do and luma cannot either.
        # UNVALIDATED for that purpose: there is no ground truth yet for which cameras
        # are artificially lit, so no verdict is emitted from it.
        metrics["byte_rate_mbps"] = meta.bytes_total * 8 / meta.duration_s / 1e6

    # --- the one pixel decision: is the IR-cut filter closed? -----------------
    # Astronomy cannot answer this. It is a CAMERA decision, made by the camera's own
    # light sensor, and cameras on the same wall disagree with each other about it.
    ir = bool(chroma.max() <= IR_CHROMA_MAX) and len(fs) >= MIN_FRAMES_FOR_IR
    metrics["ir"] = ir
    if chroma.max() <= IR_CHROMA_MAX and len(fs) < MIN_FRAMES_FOR_IR:
        notes.append(f"chroma is zero but only {len(fs)} frame(s); not calling IR")

    if ir:
        # IR overrides the astronomical answer deliberately: the fact worth recording
        # is that the camera IS in night mode, whatever the sky is doing. A camera in
        # IR at noon is a fault, and it must be visible as one rather than smoothed
        # into `day`.
        if meta.astronomical in ("day", "dusk"):
            notes.append(f"IR while astronomically {meta.astronomical} — "
                         "stuck filter, heavy shade, or an indoor camera")
        return Observation("ir", metrics, notes)

    if meta.astronomical in ("day", "dusk", "night"):
        # Astronomy states it; this module does not second-guess it. Measured: 100 %
        # against operator labels, and right on every row the pixel methods got wrong.
        if meta.astronomical == "night":
            notes.append("astronomically dark and NOT in IR — colour night vision, "
                         "or the scene is artificially lit")
        return Observation(meta.astronomical, metrics, notes)

    return Observation("unknown", metrics,
                       notes + ["no astronomical answer supplied for this window"])
