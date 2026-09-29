"""V1 object_profile: the colours of each passage's OWN pixels, and a thumbnail of its best view.

cilex-vision's task spec V1 (docs/letters/2026-09-29-vehicle-search-without-ai-task-specs-cilex-vision.md).
NO AI: background subtraction, morphology and fixed colour rules. Nothing is learned from other
footage; the only statistics are of the passage's own crop and its own camera's recent frames.

ONE ROW PER PASSAGE, the same passages A4-A6 Object shapes finds: this module does not find
things, it is an OBSERVER handed to `shape_observations.analyse_window`, which calls it on every
frame the background model sees and on every detection. For each detection it keeps a View:

  * the crop around the detection's DOMINANT blob, with a margin (the thumbnail);
  * that blob's OWN mask -- its connected component, not the frame's pooled mask. Colour's module
    doc says why pooling fails (labs_colour_histogram.py:48-54): every miss read "black", because
    tyres, dark trousers and shadows outvoted the thing;
  * the running MEDIAN background under the crop, over the last `ring` frames the model saw;
  * the frame's scene chroma (the IR gate) and the background's lit chroma (the light-cast gate).

A passage keeps only its LARGEST detection's view (shape_observations._Passages), the row's
`bbox_at_s`. That is the best view: nearest, most pixels.

THE COLOUR OF A VIEW (`colour_of`), in order:
  1. The mask goes to chroma resolution. 4:2:0 has one U/V sample per 2x2 luma block; a sample
     counts when at least `mask_min_cover` of its block is in the blob. Then it is ERODED 3x3
     (Colour's erode_px), because the ring at the edge mixes the thing with what is behind it.
  2. SHADOWS AND HIGHLIGHTS OUT, by Colour's own rule (labs_colour_histogram.illumination_change,
     thresholds unchanged): a pixel within illum_chroma_max of the background's chroma, at
     0.35-1.25x its luma, is the background re-lit, not the thing.
  3. BANDS OUT: the top `top_band` and the bottom `bottom_band` of what is left, by its height
     (roof glass and reflections; wheels and road). The spec leaves their sizes to the trial.
  4. GATES, Colour's, thresholds unchanged. A guessed colour is worse than none:
       ir              the frame's scene chroma <= ir_chroma_max (the IR-cut filter is closed);
       no_body_pixels  nothing left after steps 1-3;
       too_small       fewer body pixels than min_region_frac of the frame, counted at chroma
                       resolution (the same fraction of the picture as Colour's 144 px at 320x180);
       light_cast      the median background's lit chroma >= cast_chroma_min (street light) --
                       ONLY when the sky is dusk or night (the segment's scene_light_astronomical,
                       the server's labs_scene_light_at). By day on these cameras Colour's measure
                       reads over its cut on 78 % of passages -- lawn, brick, autumn trees, not
                       street light -- and Colour's own module gates the same footage. An UNKNOWN
                       sky keeps Colour's gate as it is. (The operator's call, 2026-09-29 22:10.)
  5. NAMES by Colour's `classify`, thresholds unchanged, then ONE rule of this module's own
     (proposal B, the operator's call): a pixel classify names BLUE whose HSV saturation is under
     `blue_sat_floor` (0.20) is achromatic, named by Colour's own luma cuts (white >= white_y,
     black < grey_black_y, else silver). White paint seen from above reflects the sky: measured,
     bright white cars' "blue" pixels sit at median saturation 0.18-0.19, navy jackets' at
     0.53-0.62. Colour's module stays byte-identical; its own analyser does not change.
     colour_1 is the named colour with the largest share of the counted pixels if it reaches
     min_share (0.30, the taxonomy's rule), else "unknown".
     colour_2 is OFF (`second_share` None): a pixel-share second colour was right 9 times in 103
     in the V1 trial. Research may pass a share to see it; a row never carries it.

THE TRIAL THAT SET THESE: docs/letters/2026-09-29-vehicle-search-without-ai-task-specs.reply-
cilex-watchtower-linux.md (read-only, 104 camera-hours, blind by eye) and cilex-vision's reply2.

THE THUMBNAIL (`thumbnail`): the crop with its margin, BT.709 full range to RGB (Colour's own
conversion), longest side at most 320 px, JPEG at the highest quality from a fixed ladder that
fits 32 KB.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import cv2
import numpy as np

import labs_colour_histogram as C

ANALYZER = "object_profile"
#: Bump on any change that moves a number.
VERSION = "op-2"

GATE_IR = "ir"
GATE_CAST = "light_cast"
GATE_TOO_SMALL = "too_small"
GATE_NO_BODY = "no_body_pixels"
UNKNOWN = C.UNKNOWN


@dataclass(frozen=True)
class Config:
    """Everything that decides a crop, a background, a colour or a thumbnail."""

    #: Colour's configuration, used UNCHANGED: classify, illumination_change and the gates.
    colour: C.Config = C.DEFAULT
    #: Crop margin each side, as a fraction of the blob's box (and at least margin_min_px).
    margin: float = 0.15
    margin_min_px: int = 4
    #: Frames in the running median background, and the fewest it needs to be believed. Colour
    #: takes the median over its window of four segments; this is the last `ring` frames the
    #: model saw -- keyframes, 1 s apart on the 720p sub cameras measured (3,608 an hour), up to
    #: 4 s on a GOP-60 stream -- so the thing's own past is not in it.
    ring: int = 24
    ring_min: int = 6
    #: The light-cast gate reads the background at 1/cast_scale of chroma resolution, and at
    #: most once per cast_every new frames: street light does not change per keyframe.
    cast_scale: int = 4
    cast_every: int = 4
    #: A chroma sample is the blob's when at least this share of its 2x2 luma block is.
    mask_min_cover: float = 0.5
    #: Bands left out, as fractions of the remaining body's height (step 3). Trial-set.
    top_band: float = 0.20
    bottom_band: float = 0.20
    #: The second colour's least share (step 5). None = OFF, the operator's call: a pixel-share
    #: second colour was right 9 times in 103 (V1 trial). Research passes a number to see it.
    second_share: float | None = None
    #: Proposal B (step 5): classify's "blue" under this HSV saturation is achromatic. None = off.
    blue_sat_floor: float | None = 0.20
    #: Thumbnail limits (the server's): longest side, bytes; and the JPEG quality ladder.
    thumb_side: int = 320
    thumb_bytes: int = 32 * 1024
    thumb_quality: tuple[int, ...] = (88, 80, 72, 64, 56, 48, 40)


DEFAULT = Config()


@dataclass
class View:
    """What one detection's frame showed of its dominant blob. Coordinates in luma pixels."""

    segment_id: str
    t_offset_s: float            # from its own segment's start, as Observation.t_offset_s
    frame_w: int
    frame_h: int
    x0: int                      # the crop, margin included; all four even
    y0: int
    x1: int
    y1: int
    bx: int                      # the blob's own box
    by: int
    bw: int
    bh: int
    y: np.ndarray = field(repr=False)        # (y1-y0, x1-x0) uint8
    u: np.ndarray = field(repr=False)        # ((y1-y0)/2, (x1-x0)/2) uint8
    v: np.ndarray = field(repr=False)
    mask: np.ndarray = field(repr=False)     # (y1-y0, x1-x0) bool: the blob's component
    bg: np.ndarray | None = field(repr=False)  # (h/2, w/2, 3) float32 median background, or None
    bg_frames: int = 0
    scene_chroma: float = 0.0
    bg_chroma: float | None = None
    bg_luma: float | None = None             # mean luma of the median background, whole frame
    full_range: bool = True


class Observer:
    """Handed to shape_observations.analyse_window(observer=...). ONE per unit (camera-hour or a
    run of them): it keeps the camera's recent frames. Frames must carry the U and V planes
    (frame_source want_planes=True)."""

    def __init__(self, cfg: Config = DEFAULT, full_range: bool = True):
        self.cfg = cfg
        self.full_range = full_range
        self._shape: tuple[int, int] | None = None
        self._ring: np.ndarray | None = None      # (ring, h/2, w/2, 3) uint8: Y (area), U, V
        self._small: np.ndarray | None = None     # the same at 1/cast_scale
        self._n = 0                               # frames written since the last reset
        self._cast_at = -1
        self._cast: float | None = None
        self._luma: float | None = None
        self.frames = 0
        self.views = 0
        self.resets = 0

    def frame(self, fr: Any) -> None:
        if fr.u is None or fr.v is None:
            raise ValueError("object_profile needs the U and V planes: decode with want_planes=True")
        h, w = fr.luma.shape
        h2, w2 = fr.u.shape
        if (h2 * 2, w2 * 2) != (h, w) or fr.v.shape != fr.u.shape:
            raise ValueError(f"planes {fr.u.shape}/{fr.v.shape} are not 4:2:0 of {w}x{h}")
        c = self.cfg
        if self._shape != (h, w):
            if self._shape is not None:
                self.resets += 1
            self._shape = (h, w)
            self._ring = np.empty((c.ring, h2, w2, 3), np.uint8)
            self._small = np.empty((c.ring, max(1, h2 // c.cast_scale), max(1, w2 // c.cast_scale), 3),
                                   np.uint8)
            self._n, self._cast_at, self._cast, self._luma = 0, -1, None, None
        slot = self._n % c.ring
        r = self._ring[slot]
        r[..., 0] = cv2.resize(fr.luma, (w2, h2), interpolation=cv2.INTER_AREA)
        r[..., 1] = fr.u
        r[..., 2] = fr.v
        hs, ws = self._small.shape[1:3]
        self._small[slot] = cv2.resize(r, (ws, hs), interpolation=cv2.INTER_AREA)
        self._n += 1
        self.frames += 1

    def _scene_bg(self) -> tuple[float | None, float | None]:
        """(bg_chroma, bg_luma) of the whole frame's median background: Colour's light-cast
        measure, and how bright the scene is."""
        c = self.cfg
        n = min(self._n, c.ring)
        if n < c.ring_min:
            return None, None
        if self._cast_at >= 0 and self._n - self._cast_at < c.cast_every:
            return self._cast, self._luma
        bg = np.median(self._small[:n], axis=0)
        lit = bg[..., 0] > c.colour.cast_min_y
        self._cast = (float(np.median(C.chroma(bg[..., 1][lit], bg[..., 2][lit])))
                      if lit.any() else None)
        self._luma = float(bg[..., 0].mean())
        self._cast_at = self._n
        return self._cast, self._luma

    def detection(self, fr: Any, meta: Any, labels: np.ndarray, comp: int,
                  box: tuple[int, int, int, int]) -> View:
        c = self.cfg
        x, y, bw, bh = box
        h, w = fr.luma.shape
        mx = max(c.margin_min_px, int(round(c.margin * bw)))
        my = max(c.margin_min_px, int(round(c.margin * bh)))
        x0, y0 = max(0, x - mx) & ~1, max(0, y - my) & ~1
        x1, y1 = min(w, x + bw + mx), min(h, y + bh + my)
        x1, y1 = min(w, x1 + (x1 & 1)), min(h, y1 + (y1 & 1))
        n = min(self._n, c.ring)
        bg = None
        if n >= c.ring_min:
            bg = np.median(self._ring[:n, y0 // 2:y1 // 2, x0 // 2:x1 // 2], axis=0).astype(np.float32)
        self.views += 1
        bg_chroma, bg_luma = self._scene_bg()
        return View(
            segment_id=meta.segment_id, t_offset_s=float(fr.t_offset_s), frame_w=w, frame_h=h,
            x0=x0, y0=y0, x1=x1, y1=y1, bx=x, by=y, bw=bw, bh=bh,
            y=fr.luma[y0:y1, x0:x1].copy(),
            u=fr.u[y0 // 2:y1 // 2, x0 // 2:x1 // 2].copy(),
            v=fr.v[y0 // 2:y1 // 2, x0 // 2:x1 // 2].copy(),
            mask=labels[y0:y1, x0:x1] == comp,
            bg=bg, bg_frames=n, scene_chroma=C.scene_chroma(fr.u, fr.v),
            bg_chroma=bg_chroma, bg_luma=bg_luma, full_range=self.full_range)


_SKY_CAST = ("dusk", "night")
_BLUE, _WHITE, _BLACK, _SILVER = (C.NAMES.index(k) for k in ("blue", "white", "black", "silver"))
_UNSET = object()


def colour_of(v: View, cfg: Config = DEFAULT, *, sky: str | None = None,
              top_band: float | None = None, bottom_band: float | None = None,
              second_share: Any = _UNSET, size_gate: bool = True, cast_gate: bool = True) -> dict:
    """The colour of one view, or the gate that refused it, with the evidence either way.

    `sky` is the view's segment's scene_light_astronomical ("day", "dusk", "night"; None when the
    server has none): the light-cast gate applies at dusk and night, and when the sky is unknown.
    `second_share` overrides the config's (None = off). `size_gate` and `cast_gate` exist to
    MEASURE those gates (a trial names what they refused); a row that is sent never turns them off."""
    c, cc = cfg, cfg.colour
    tb = c.top_band if top_band is None else top_band
    bb = c.bottom_band if bottom_band is None else bottom_band
    s2 = c.second_share if second_share is _UNSET else second_share
    out: dict[str, Any] = {"scene_chroma": round(v.scene_chroma, 2), "bg_frames": v.bg_frames}
    if v.bg_chroma is not None:
        out["bg_chroma"] = round(v.bg_chroma, 2)
    if v.bg_luma is not None:
        out["bg_luma"] = round(v.bg_luma, 1)
    if v.scene_chroma <= cc.ir_chroma_max:
        return {**out, "colour_gate": GATE_IR, "body_px": 0}
    h2, w2 = v.u.shape
    m = v.mask.reshape(h2, 2, w2, 2).mean(axis=(1, 3)) >= c.mask_min_cover
    out["blob_px"] = int(m.sum())
    if cc.erode_px >= 2:
        m = cv2.erode(m.astype(np.uint8), np.ones((cc.erode_px, cc.erode_px), np.uint8)).astype(bool)
    out["eroded_px"] = int(m.sum())
    yh = cv2.resize(v.y, (w2, h2), interpolation=cv2.INTER_AREA).astype(np.float32)
    u = v.u.astype(np.float32)
    vv = v.v.astype(np.float32)
    body = m
    if v.bg is not None:
        ill = C.illumination_change(yh, u, vv, v.bg[..., 0], v.bg[..., 1], v.bg[..., 2], cc) & m
        body = m & ~ill
        out["illum_px"] = int(ill.sum())
    rows = np.flatnonzero(body.any(axis=1))
    before_bands = int(body.sum())
    if rows.size:
        r0, r1 = int(rows[0]), int(rows[-1])
        hgt = r1 - r0 + 1
        body = body.copy()
        body[:r0 + int(round(tb * hgt))] = False
        body[r1 - int(round(bb * hgt)) + 1:] = False
    body_px = int(body.sum())
    out["band_px"] = before_bands - body_px
    out["body_px"] = body_px
    if body_px == 0:
        return {**out, "colour_gate": GATE_NO_BODY}
    if size_gate and body_px < cc.min_region_frac * (v.frame_w // 2) * (v.frame_h // 2):
        return {**out, "colour_gate": GATE_TOO_SMALL}
    yb, ub, vb = yh[body], u[body], vv[body]
    names = C.classify(yb, ub, vb, cc, v.full_range)
    if c.blue_sat_floor is not None:
        # Proposal B: classify's "blue" at low saturation is bright paint reflecting the sky.
        _, sat, _ = C.rgb_to_hsv(C.ycbcr_to_rgb(yb, ub, vb, v.full_range))
        low = (names == _BLUE) & (sat < c.blue_sat_floor)
        out["blue_renamed_px"] = int(low.sum())
        if low.any():
            y_eff = yb if v.full_range else (yb - 16.0) * (255.0 / 219.0)
            names = names.copy()
            names[low & (y_eff >= cc.white_y)] = _WHITE
            names[low & (y_eff < cc.grey_black_y)] = _BLACK
            names[low & (y_eff >= cc.grey_black_y) & (y_eff < cc.white_y)] = _SILVER
    counts = np.bincount(names, minlength=len(C.NAMES)).astype(np.float64)
    shares = counts / counts.sum()
    out["shares"] = {C.NAMES[i]: round(float(shares[i]), 4) for i in range(len(C.NAMES)) if shares[i] > 0}
    out["achromatic_share"] = round(float(sum(shares[C.NAMES.index(k)] for k in ("white", "black", "silver"))), 4)
    out["other_share"] = round(float(shares[C.NAMES.index(C.OTHER)]), 4)
    out["chroma_mean"] = round(float(C.chroma(ub, vb).mean()), 2)
    out["luma_mean"] = round(float(yb.mean()), 2)
    if (cast_gate and (sky is None or sky in _SKY_CAST)
            and v.bg_chroma is not None and v.bg_chroma >= cc.cast_chroma_min):
        return {**out, "colour_gate": GATE_CAST}
    named = np.argsort(-shares[:len(C.COLOURS)], kind="stable")
    top, second = int(named[0]), int(named[1])
    if shares[top] >= cc.min_share:
        out["colour_1"], out["colour_1_share"] = C.COLOURS[top], round(float(shares[top]), 4)
        if s2 is not None and shares[second] > 0 and shares[second] >= s2:
            out["colour_2"], out["colour_2_share"] = C.COLOURS[second], round(float(shares[second]), 4)
    else:
        out["colour_1"], out["colour_1_share"] = UNKNOWN, round(float(shares[top]), 4)
    return out


def thumbnail(v: View, cfg: Config = DEFAULT) -> bytes:
    """The crop as a JPEG: longest side <= thumb_side, at most thumb_bytes."""
    h, w = v.y.shape
    u = cv2.resize(v.u, (w, h), interpolation=cv2.INTER_LINEAR)
    vv = cv2.resize(v.v, (w, h), interpolation=cv2.INTER_LINEAR)
    rgb = np.rint(C.ycbcr_to_rgb(v.y, u, vv, v.full_range)).astype(np.uint8)
    img = np.ascontiguousarray(rgb[..., ::-1])
    scale = cfg.thumb_side / max(h, w)
    while True:
        if scale < 1.0:
            size = (max(1, int(round(w * scale))), max(1, int(round(h * scale))))
            im = cv2.resize(img, size, interpolation=cv2.INTER_AREA)
        else:
            im = img
        for q in cfg.thumb_quality:
            ok, buf = cv2.imencode(".jpg", im, [cv2.IMWRITE_JPEG_QUALITY, q])
            if ok and buf.size <= cfg.thumb_bytes:
                return buf.tobytes()
        scale = min(scale, 1.0) * 0.8


def thumb_key(start_ms: int, taken: set[str]) -> str:
    """A key the server accepts ([a-z0-9-]{1,40}), unique within the unit: the row's start in ms
    from the hour's start, and a suffix in the rare case two rows start in the same ms."""
    key = f"t{int(start_ms):07d}"
    k, i = key, 2
    while k in taken:
        k, i = f"{key}-{i}", i + 1
    taken.add(k)
    return k
