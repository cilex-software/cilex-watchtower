"""B8 audio_energy: loudness, transients and spectral balance of the recorded sound.

FIRST, WHETHER THERE IS ANY SOUND. Measured with ffprobe on 8 cameras
(docs/findings/2026-09-26-labs-audio_energy.md): the continuous recorder keeps
the camera's audio, transcoded G.711 to AAC 32k (recorder-service main.py:286-288),
and hiwatch-04eecdd44de8 carries AAC 8 kHz mono in 57 of 57 main segments. The
motion recorder strips it (recorder-service motion/prebuffer.py:119, `-an`), so
a motion-recorded camera has NO audio whatever its audio setting; the sub
stream had none either. The analyser therefore has to say "no audio" loudly
and never let it read as a quiet hour.

WHAT EACH OUTPUT CLAIMS. Per 10 s window of one camera-hour (epoch aligned):

    rms_mean_dbfs   10 log10 of the mean square over the window (ffmpeg
                    volumedetect's convention: a full-scale sine is -3.01).
    rms_p95_dbfs    p95 of the 32 ms frame levels. "How loud it usually got."
    rms_max_dbfs    the loudest 32 ms frame.
    onset_count     transients: the 32 ms level rose >= 12 dB within 64 ms, to
                    >= 6 dB above the run's background (see detect_onsets).
    onset_max_db    the strongest such rise, dB. Omitted when there is none.
    onset_peak_offset_s  seconds from window start to that onset; good to
                    about +0.12 s through the real codec chain (measured).
    flux_max_db     max band-mean spectral flux (third-octave, 62.5-3800 Hz).
                    Reported, NOT used to pick onsets (a measured choice).
    band_low/mid/high_frac  share of the window's energy below 300 Hz,
                    300-3000 Hz, above 3000 Hz. On an 8 kHz source "high" can
                    only hold 3000-4000 Hz. Omitted for digital silence.
    silent          p95 < -70 dBFS: below G.711's first quantisation step, so
                    no live microphone signal.
    floor_dbfs      the run's background (p10 of its live frames).

A segment with no audio stream produces one row with no_audio=true and a
reason (no_audio_stream, private_data_stream, no_audio_packets, no_pmt), and
nothing that could pass for a level. A track that is present but digitally
silent for the whole run is reported the same way (silent_track).

MEASURED (labs_run.sh, same footage, findings doc has the commands):
  * synthetic sounds muxed into COPIES of real segments through the recorder's
    own flags: 5 of 6 intended onsets found, 0 false onsets, 0 fires at
    segment joints; the miss rose 10.4 dB before the codec, under the line.
    Tone bands land 0.9994-0.9998 in the right band.
  * real audio, 28.5 minutes of hiwatch-04eecdd44de8: 157 quiet windows, the
    largest 64 ms rise in any of them 11.23 dB (p95 7.98), hence the 12 dB
    line. The thin margin and the single camera are the known weakness.
  * cost: 4.05-6.20 CPU-s per camera-hour (6 runs, self + ffmpeg children),
    but the footage fetched is the whole MAIN stream, 192-337 MB per camera
    hour, for an audio track of about 13 MB (ESTIMATE from its bitrate).

THE DECODE SHAPE: one long-lived software ffmpeg per contiguous run of
audio-bearing segments (normally one per unit), TS bytes streamed to it on
stdin as chunks, never buffered. No -hwaccel. Each segment's audio is anchored
to that segment's own start_time, so an error in one start cannot drift.
"""
from __future__ import annotations

import json
import logging
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator, Sequence

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------
#: Decode target. The recorded tracks are 8 kHz (measured); decoding to 16 kHz
#: keeps one code path for a future wideband camera. Nothing above the SOURCE
#: Nyquist exists in the samples, which is why `source_rate_hz` is reported.
SAMPLE_RATE = 16000
#: 32 ms analysis frames, 16 ms hop.
FRAME = 512
HOP = 256
#: Report window, aligned to wall-clock multiples of itself (epoch based), so a
#: re-scan of the same hour produces the same windows whatever segment it
#: started from. 10 s keeps a fully busy hour at 360 rows, under the 500 cap.
WINDOW_S = 10.0
#: Band edges for the energy fractions. `high` runs to the decode Nyquist; on
#: an 8 kHz source it therefore holds only 3000-4000 Hz.
LOW_HZ = (20.0, 300.0)
MID_HZ = (300.0, 3000.0)
HIGH_FROM_HZ = 3000.0
#: Levels are clamped here. 16-bit PCM quantisation noise sits near -101 dBFS.
DBFS_FLOOR = -100.0
#: p95 of the 32 ms frame levels below this = no live signal. G.711 mu-law's
#: smallest non-zero step decodes to 8/32768 (-72.2 dBFS), so an idle or muted
#: G.711 input cannot rise above about -72 dBFS; a live microphone does.
SILENT_DBFS = -70.0
#: Band levels feeding the spectral flux are clamped here, so an empty band
#: (an AAC spectral hole, digital silence) cannot manufacture a rise.
FLUX_FLOOR_DBFS = -90.0
#: Spectral-flux bands cover 62.5-3800 Hz on EVERY source: the telephony band
#: that any camera codec carries. Fixed so that flux values are comparable
#: across cameras with different sample rates.
FLUX_LOW_HZ = 62.5
FLUX_HIGH_HZ = 3800.0
#: Spectral flux compares each frame with the frame two hops back: frames
#: overlap by half, so lag 2 is the nearest frame sharing no samples with it.
FLUX_LAG = 2
#: ONSETS ARE PICKED ON THE BROADBAND LEVEL RISE over this many hops (64 ms),
#: not on the band-mean spectral flux. Measured choice, see detect_onsets.
RISE_LAG = 4
#: An onset: the 32 ms level rose at least this much within 64 ms. MEASURED
#: floor: the largest rise in any of 157 quiet 10 s windows was 11.23 dB
#: (p95 of window maxima 7.98), so 12 dB is the first whole number above it.
ONSET_MIN_DB = 12.0
#: ...and ended at least this far above the run's background level, so a
#: level recovering from a dip (or the decoder's fade-in) is not an onset.
ONSET_ABOVE_FLOOR_DB = 6.0
ONSET_PEAK_HALF_S = 0.048
ONSET_MIN_GAP_S = 0.1
#: No onset is taken this early in a decoder run. MEASURED: every decode
#: fades in from about -68 dBFS over its first ~80 ms (5 frames).
STARTUP_S = 0.1
#: The background level of a run: this percentile of its frame levels.
FLOOR_PERCENTILE = 10.0
#: Consecutive segments further apart than this start a new decoder run, so
#: audio from either side of a recording gap is never spliced into one
#: signal (the splice itself would read as a transient).
MAX_SEAM_S = 1.5
#: Recorded start times overlap the previous segment by up to ~0.93 s
#: (measured); larger overlaps are treated as a discontinuity too.
MAX_OVERLAP_S = 2.0
#: labs_observation_groups.ck_labs_observation_groups_max_span (migration
#: 0089): no observation may span more than this, or it cannot be grouped.
MAX_SPAN_S = 300.0
#: routers/labs.py MAX_OBSERVATIONS_PER_UNIT.
MAX_OBSERVATIONS = 500
#: Read size for file inputs, and how much of a segment may be read looking
#: for its PAT/PMT before giving up.
CHUNK = 256 * 1024
PROBE_BYTES = 1024 * 1024
#: Decoded-versus-expected tolerance before a run is declared broken.
DECODE_TOLERANCE_S = 0.5

TS_PACKET = 188

# ---------------------------------------------------------------------------
# MPEG-TS: which streams a segment carries, and how many AAC samples
# ---------------------------------------------------------------------------
#: PMT stream_type values that are audio by themselves.
AUDIO_STREAM_TYPES = {
    0x03: "mp1", 0x04: "mp2", 0x0F: "aac_adts", 0x11: "aac_latm",
    0x1C: "mpeg4_audio", 0x81: "ac3", 0x87: "eac3",
}
#: stream_type 0x06 (PES private data) is audio only with one of these
#: descriptors. WITHOUT one it is what ffmpeg writes for G.711 in MPEG-TS
#: ("muxed as a private data stream"): the recorder did exactly that until
#: 3fd8237, and ffmpeg reads it back as `bin_data`, not as audio.
_AUDIO_DESCRIPTOR_TAGS = {0x6A: "ac3", 0x7A: "eac3", 0x7B: "dts", 0x7C: "aac"}
_REGISTRATION_AUDIO = {b"Opus": "opus", b"AC-3": "ac3", b"EAC3": "eac3",
                       b"DTS1": "dts", b"DTS2": "dts", b"DTS3": "dts"}
_ADTS_RATES = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
               16000, 12000, 11025, 8000, 7350)


@dataclass(frozen=True)
class TsLayout:
    """What a segment's PMT declares. `reason` is set exactly when there is no
    decodable audio stream, and says which of the known cases it is."""

    stream_types: tuple[int, ...]
    audio_pid: int | None
    audio_kind: str | None
    reason: str | None


def _payload(pkt: bytes) -> bytes | None:
    afc = (pkt[3] >> 4) & 0x3
    if not afc & 0x1:
        return None                      # adaptation field only
    off = 4
    if afc & 0x2:
        off += 1 + pkt[4]
    if off >= TS_PACKET:
        return None
    return pkt[off:]


def _section(pkt: bytes) -> bytes | None:
    """The PSI section starting in this packet (PUSI packets only)."""
    if not pkt[1] & 0x40:
        return None
    pl = _payload(pkt)
    if pl is None or len(pl) < 1:
        return None
    ptr = pl[0]
    return pl[1 + ptr:]


def parse_pat(pkt: bytes) -> list[int]:
    """PMT PIDs listed in a PAT packet (program 0, the NIT, is skipped)."""
    sec = _section(pkt)
    if sec is None or len(sec) < 8 or sec[0] != 0x00:
        return []
    sec_len = ((sec[1] & 0x0F) << 8) | sec[2]
    end = min(len(sec), 3 + sec_len - 4)
    out = []
    for j in range(8, end - 3, 4):
        prog = (sec[j] << 8) | sec[j + 1]
        pid = ((sec[j + 2] & 0x1F) << 8) | sec[j + 3]
        if prog != 0:
            out.append(pid)
    return out


def parse_pmt(pkt: bytes) -> list[tuple[int, int, bytes]] | None:
    """(stream_type, elementary PID, ES descriptors) for each stream in a PMT
    packet, or None when the packet does not hold a PMT section."""
    sec = _section(pkt)
    if sec is None or len(sec) < 12 or sec[0] != 0x02:
        return None
    sec_len = ((sec[1] & 0x0F) << 8) | sec[2]
    end = min(len(sec), 3 + sec_len - 4)
    pil = ((sec[10] & 0x0F) << 8) | sec[11]
    j = 12 + pil
    out = []
    while j + 5 <= end:
        st = sec[j]
        pid = ((sec[j + 1] & 0x1F) << 8) | sec[j + 2]
        esl = ((sec[j + 3] & 0x0F) << 8) | sec[j + 4]
        out.append((st, pid, bytes(sec[j + 5:j + 5 + esl])))
        j += 5 + esl
    return out


def _descriptor_audio_kind(desc: bytes) -> str | None:
    j = 0
    while j + 2 <= len(desc):
        tag, ln = desc[j], desc[j + 1]
        body = desc[j + 2:j + 2 + ln]
        if tag in _AUDIO_DESCRIPTOR_TAGS:
            return _AUDIO_DESCRIPTOR_TAGS[tag]
        if tag == 0x05 and body[:4] in _REGISTRATION_AUDIO:
            return _REGISTRATION_AUDIO[body[:4]]
        j += 2 + ln
    return None


def classify_pmt(streams: Sequence[tuple[int, int, bytes]]) -> TsLayout:
    """Pick the audio stream (AAC ADTS preferred), or name why there is none."""
    types = tuple(st for st, _pid, _d in streams)
    best: tuple[int, str] | None = None
    private = False
    for st, pid, desc in streams:
        kind = AUDIO_STREAM_TYPES.get(st)
        if kind is None and st == 0x06:
            kind = _descriptor_audio_kind(desc)
            if kind is None:
                private = True
        if kind is not None and (best is None or kind == "aac_adts" and best[1] != "aac_adts"):
            best = (pid, kind)
    if best is not None:
        return TsLayout(types, best[0], best[1], None)
    return TsLayout(types, None, None,
                    "private_data_stream" if private else "no_audio_stream")


class TsAudioScanner:
    """One segment's TS bytes in, its layout and AAC sample count out.

    Pure bookkeeping over bytes that are being streamed to the decoder anyway:
    it never buffers the segment, only the audio PID's elementary stream, and
    only until each ADTS frame is complete.

    WHY COUNT FRAMES AT ALL: to place each segment's audio at that segment's
    own start_time. Measured on 10 consecutive real segments: the decoded audio
    is 299.52 s, the summed `duration_s` 299.995 s and the wall span 299.015 s
    (one recorded seam is -0.926 s). Mapping a whole hour linearly from its
    first start would drift by seconds; anchoring per segment cannot drift.
    """

    def __init__(self) -> None:
        self._carry = b""
        self._pmt_pids: set[int] = set()
        self.layout: TsLayout | None = None
        self.bytes_seen = 0
        self.aac_frames = 0
        self.source_samples = 0          # at the SOURCE rate
        self.source_rate: int | None = None
        self.channels: int | None = None
        self.rate_changed = False
        self._es = bytearray()

    # -- public ------------------------------------------------------------
    def feed(self, chunk: bytes) -> None:
        self.bytes_seen += len(chunk)
        buf = self._carry + bytes(chunk) if self._carry else bytes(chunk)
        pos = 0
        n = len(buf)
        while n - pos >= TS_PACKET:
            if buf[pos] != 0x47:
                pos = self._resync(buf, pos)
                continue
            k = (n - pos) // TS_PACKET
            block = np.frombuffer(buf, dtype=np.uint8, count=k * TS_PACKET,
                                  offset=pos).reshape(k, TS_PACKET)
            bad = np.flatnonzero(block[:, 0] != 0x47)
            good = int(bad[0]) if bad.size else k
            if good:
                self._packets(buf, pos, block[:good])
            pos += good * TS_PACKET
        self._carry = buf[pos:]

    @property
    def expected_samples_out(self) -> int | None:
        """AAC samples converted to SAMPLE_RATE, or None if not countable."""
        if self.layout is None or self.layout.audio_kind != "aac_adts" or not self.source_rate:
            return None
        return int(round(self.source_samples * SAMPLE_RATE / self.source_rate))

    # -- internals ---------------------------------------------------------
    @staticmethod
    def _resync(buf: bytes, pos: int) -> int:
        """Next offset where two sync bytes line up a packet apart."""
        j, n = pos + 1, len(buf)
        while True:
            j = buf.find(b"\x47", j)
            if j < 0:
                return n
            if j + TS_PACKET >= n or buf[j + TS_PACKET] == 0x47:
                return j
            j += 1

    def _packets(self, buf: bytes, pos: int, block: np.ndarray) -> None:
        pid = ((block[:, 1].astype(np.int32) & 0x1F) << 8) | block[:, 2]
        first = 0
        if self.layout is None:
            # PAT and PMT open every ffmpeg-muxed segment (measured: packets
            # 1 and 2 of a real one), so this loop is a few iterations long.
            for i in range(len(block)):
                p = int(pid[i])
                if p == 0:
                    pkt = buf[pos + i * TS_PACKET:pos + (i + 1) * TS_PACKET]
                    self._pmt_pids.update(parse_pat(pkt))
                elif p in self._pmt_pids:
                    pkt = buf[pos + i * TS_PACKET:pos + (i + 1) * TS_PACKET]
                    streams = parse_pmt(pkt)
                    if streams is not None:
                        self.layout = classify_pmt(streams)
                        first = i + 1
                        break
            else:
                return
        self._audio(buf, pos, pid, np.arange(first, len(block)))

    def _audio(self, buf: bytes, pos: int, pid: np.ndarray, rows: np.ndarray) -> None:
        lay = self.layout
        if lay is None or lay.audio_pid is None or lay.audio_kind != "aac_adts" or rows.size == 0:
            return
        for i in rows[pid[rows] == lay.audio_pid]:
            pkt = buf[pos + int(i) * TS_PACKET:pos + (int(i) + 1) * TS_PACKET]
            pl = _payload(pkt)
            if pl is None:
                continue
            if pkt[1] & 0x40:            # PES start: skip the PES header
                if len(pl) < 9 or pl[:3] != b"\x00\x00\x01":
                    continue
                pl = pl[9 + pl[8]:]
            self._es += pl
        self._adts()

    def _adts(self) -> None:
        es = self._es
        i, n = 0, len(es)
        while n - i >= 7:
            if es[i] != 0xFF or (es[i + 1] & 0xF6) != 0xF0:
                j = es.find(b"\xff", i + 1)
                i = n if j < 0 else j
                continue
            flen = ((es[i + 3] & 0x03) << 11) | (es[i + 4] << 3) | (es[i + 5] >> 5)
            if flen < 7:
                i += 1
                continue
            if n - i < flen:
                break
            sfi = (es[i + 2] >> 2) & 0x0F
            rate = _ADTS_RATES[sfi] if sfi < len(_ADTS_RATES) else None
            if rate is not None:
                if self.source_rate is None:
                    self.source_rate = rate
                    self.channels = ((es[i + 2] & 0x01) << 2) | (es[i + 3] >> 6)
                elif rate != self.source_rate:
                    self.rate_changed = True
            self.aac_frames += 1
            self.source_samples += 1024 * ((es[i + 6] & 0x03) + 1)
            i += flen
        del es[:i]


# ---------------------------------------------------------------------------
# DSP: per-frame features, pure and streamable
# ---------------------------------------------------------------------------
def _bin_freqs() -> np.ndarray:
    return np.fft.rfftfreq(FRAME, d=1.0 / SAMPLE_RATE)


def _band3_starts() -> np.ndarray:
    """First FFT bin of low, mid and high (by bin centre). The bands are
    contiguous, so they are summed with np.add.reduceat, which never calls
    BLAS: a matrix product here would hand the work to a multithreaded BLAS
    whose idle threads spin. MEASURED with reduceat, 3 runs each over the same
    54 real segments: 4.36-6.20 CPU-s per camera-hour with default threading,
    4.05-5.08 with OPENBLAS_NUM_THREADS=1 (overlapping ranges; pinning is not
    needed)."""
    f = _bin_freqs()
    return np.array([int(np.argmax(f >= LOW_HZ[0])), int(np.argmax(f >= MID_HZ[0])),
                     int(np.argmax(f >= HIGH_FROM_HZ))])


def flux_band_edges() -> list[tuple[int, int]]:
    """Third-octave bands over FLUX_LOW_HZ..FLUX_HIGH_HZ, each >= 2 FFT bins
    wide (a one-bin band's level jitters by ~5.6 dB on steady noise)."""
    df = SAMPLE_RATE / FRAME
    lo = int(round(FLUX_LOW_HZ / df))
    hi = int(FLUX_HIGH_HZ // df)
    edges = [lo]
    while edges[-1] < hi:
        nxt = max(edges[-1] + 2, int(round(edges[-1] * 2 ** (1 / 3))))
        edges.append(min(nxt, hi))
    return [(a, b) for a, b in zip(edges[:-1], edges[1:]) if b > a]


_HANN = np.hanning(FRAME + 2)[1:-1].astype(np.float64)   # symmetric, no zero ends
#: |X|^2 -> share of the frame's mean-square power, so band sums are dBFS.
_PSCALE = np.full(FRAME // 2 + 1, 2.0)
_PSCALE[0] = _PSCALE[-1] = 1.0
_PSCALE /= float(np.sum(_HANN ** 2)) * FRAME
_B3_STARTS = _band3_starts()
_FLUX_STARTS = np.array([a for a, _b in flux_band_edges()])
_FLUX_END = flux_band_edges()[-1][1]


@dataclass
class FrameFeatures:
    """Per 16 ms hop. `power` is linear mean-square (dBFS = 10 log10)."""

    power: np.ndarray        # (n,) float64
    level_db: np.ndarray     # (n,) float32, clamped at DBFS_FLOOR
    band3: np.ndarray        # (n, 3) float64: low, mid, high power
    flux: np.ndarray         # (n,) float32, dB

    def __len__(self) -> int:
        return int(self.power.size)


class FeatureExtractor:
    """Push PCM of any chunking, get the same frames as one-shot extraction.

    Carries the unfinished frame and the band levels FLUX_LAG frames back
    across pushes, which is what makes a segment joint (or a pipe read
    boundary) invisible to the numbers: tested by pushing the same signal in
    random chunk sizes.
    """

    def __init__(self) -> None:
        self._buf = np.zeros(0, dtype=np.float32)
        self._prev_lf: np.ndarray | None = None
        self._parts: list[tuple[np.ndarray, ...]] = []
        self.samples = 0

    def push(self, pcm: np.ndarray) -> None:
        pcm = np.asarray(pcm, dtype=np.float32).ravel()
        self.samples += pcm.size
        buf = np.concatenate([self._buf, pcm]) if self._buf.size else pcm
        if buf.size < FRAME:
            self._buf = buf.copy()
            return
        n = (buf.size - FRAME) // HOP + 1
        frames = sliding_window_view(buf, FRAME)[::HOP][:n].astype(np.float64)
        self._buf = buf[n * HOP:].copy()
        power = np.mean(frames * frames, axis=1)
        level = (10.0 * np.log10(np.maximum(power, 10 ** (DBFS_FLOOR / 10)))).astype(np.float32)
        spec = np.fft.rfft(frames * _HANN, axis=1)
        p = (spec.real ** 2 + spec.imag ** 2) * _PSCALE
        band3 = np.add.reduceat(p, _B3_STARTS, axis=1)
        fl = np.add.reduceat(p[:, :_FLUX_END], _FLUX_STARTS, axis=1)
        lf = 10.0 * np.log10(np.maximum(fl, 10 ** (FLUX_FLOOR_DBFS / 10)))
        if self._prev_lf is None:
            ref = np.vstack([np.repeat(lf[:1], FLUX_LAG, axis=0), lf])
        else:
            ref = np.vstack([self._prev_lf, lf])
        rise = ref[FLUX_LAG:] - ref[:-FLUX_LAG]
        flux = np.mean(np.maximum(rise, 0.0), axis=1).astype(np.float32)
        self._prev_lf = ref[-FLUX_LAG:].copy()
        self._parts.append((power, level, band3, flux))

    def finish(self) -> FrameFeatures:
        if not self._parts:
            return FrameFeatures(np.zeros(0), np.zeros(0, np.float32),
                                 np.zeros((0, 3)), np.zeros(0, np.float32))
        cols = list(zip(*self._parts))
        return FrameFeatures(np.concatenate(cols[0]), np.concatenate(cols[1]),
                             np.concatenate(cols[2]), np.concatenate(cols[3]))


def frame_features(pcm: np.ndarray) -> FrameFeatures:
    """One-shot extraction; identical to streaming (see FeatureExtractor)."""
    fx = FeatureExtractor()
    fx.push(pcm)
    return fx.finish()


def level_rise(level_db: np.ndarray, lag: int = RISE_LAG) -> np.ndarray:
    """How far the 32 ms level rose against the frame `lag` hops earlier, in
    dB, rectified. Zero for the first `lag` frames: nothing to compare with."""
    lv = np.asarray(level_db, dtype=np.float64)
    r = np.zeros_like(lv)
    if lv.size > lag:
        r[lag:] = np.maximum(lv[lag:] - lv[:-lag], 0.0)
    return r


def background_dbfs(level_db: np.ndarray) -> float:
    """The run's background: FLOOR_PERCENTILE of its LIVE frames.

    Live only, because digital silence is not a background. Over all frames, a
    run that is 12.5% digital silence has its 10th percentile at the -100 dBFS
    clamp, the onset gate collapses to SILENT_DBFS, and a microphone going
    live would be counted as a sound. A run with no live frame reports the
    clamp itself."""
    lv = np.asarray(level_db, dtype=np.float64)
    live = lv[lv >= SILENT_DBFS]
    return float(np.percentile(live, FLOOR_PERCENTILE)) if live.size else DBFS_FLOOR


def detect_onsets(level_db: np.ndarray, *, floor_dbfs: float,
                  min_db: float | None = None,
                  above_floor_db: float | None = None,
                  skip_frames: int | None = None) -> tuple[np.ndarray, np.ndarray]:
    """Transient onsets: (frame indices, strengths in dB).

    PICKED ON THE BROADBAND LEVEL RISE, NOT ON THE BAND-MEAN SPECTRAL FLUX,
    and that is a measured choice (docs/findings/2026-09-26-labs-audio_energy.md).
    Over 157 quiet 10 s windows of real audio and synthetic bursts mixed into
    real floor audio, the band-mean spectral flux scored a sharp low-band
    burst 15 dB above the floor at 9.25 dB and a high-band one at 6.07 dB,
    against 5.97 dB for the quietest-possible bar (the largest value in any
    quiet window): it averages a thud with the 11 of 15 bands the thud did not
    touch. The level rise over 64 ms scored the same bursts 15.2 and 15.5 dB
    against a quiet maximum of 11.23 dB, and within 0.6 dB of each other
    across low, mid, high and broadband bursts. The spectral flux is still
    measured and reported (`flux_max_db`); it just does not pick onsets.

    A frame is an onset when its rise R is
      * the strict maximum within +-48 ms,
      * at least `min_db`,
      * in a frame at least `above_floor_db` above the run's background and
        above SILENT_DBFS (a level recovering from a dip is not an onset),
      * not in the first STARTUP_S of the decoder run (the decoder fades in),
    and at least 100 ms after the previous accepted onset (the stronger wins).
    The strength is R itself: dB of rise within 64 ms.
    """
    # Resolved at CALL time, so the module constants are the one place to tune.
    min_db = ONSET_MIN_DB if min_db is None else min_db
    above_floor_db = ONSET_ABOVE_FLOOR_DB if above_floor_db is None else above_floor_db
    lv = np.asarray(level_db, dtype=np.float64)
    n = lv.size
    if n == 0:
        return np.zeros(0, dtype=np.int64), np.zeros(0)
    hop_s = HOP / SAMPLE_RATE
    half = max(1, int(round(ONSET_PEAK_HALF_S / hop_s)))
    skip = int(round(STARTUP_S / hop_s)) if skip_frames is None else skip_frames
    r = level_rise(lv)
    pad = np.pad(r, (half, half), constant_values=-np.inf)
    win = sliding_window_view(pad, 2 * half + 1)
    left = win[:, :half].max(axis=1)
    gate = max(SILENT_DBFS, floor_dbfs + above_floor_db)
    ok = (r >= win.max(axis=1)) & (r > left) & (r >= min_db) & (lv >= gate)
    ok[:skip] = False
    keep_i: list[int] = []
    keep_s: list[float] = []
    for i in np.flatnonzero(ok):
        # Compared in SECONDS: rounding the gap to whole hops (6.25 -> 6) let
        # two onsets 96 ms apart both through a documented 100 ms rule.
        if keep_i and (i - keep_i[-1]) * hop_s < ONSET_MIN_GAP_S - 1e-9:
            if r[i] > keep_s[-1]:
                keep_i[-1], keep_s[-1] = int(i), float(r[i])
            continue
        keep_i.append(int(i))
        keep_s.append(float(r[i]))
    return np.asarray(keep_i, dtype=np.int64), np.asarray(keep_s)


def anchor_times(sample_idx: np.ndarray, seg_starts: Sequence[float],
                 seg_samples: Sequence[int], sr: int = SAMPLE_RATE) -> tuple[np.ndarray, np.ndarray]:
    """Map decoded-sample indices to epoch seconds, segment by segment.

    Returns (times, segment index). Segment k owns samples [cum_k, cum_k+1)
    and its time is its own start plus the offset into it, so an error in one
    segment's recorded start never propagates to the next.
    """
    s = np.asarray(sample_idx, dtype=np.float64)
    cum = np.concatenate([[0], np.cumsum(np.asarray(seg_samples, dtype=np.int64))])
    k = np.clip(np.searchsorted(cum, s, side="right") - 1, 0, len(seg_starts) - 1)
    return np.asarray(seg_starts, dtype=np.float64)[k] + (s - cum[k]) / sr, k


# ---------------------------------------------------------------------------
# results
# ---------------------------------------------------------------------------
def _db(x: float) -> float:
    return float(10.0 * np.log10(max(x, 10 ** (DBFS_FLOOR / 10))))


@dataclass(frozen=True)
class WindowStats:
    """One report window of one decoder run. Frozen: a measurement."""

    start: datetime
    end: datetime
    audio_s: float
    rms_mean_dbfs: float
    rms_p95_dbfs: float
    rms_max_dbfs: float
    onset_count: int
    onset_max_db: float | None
    onset_peak_offset_s: float | None
    flux_max_db: float
    band_low_frac: float | None
    band_mid_frac: float | None
    band_high_frac: float | None
    silent: bool
    floor_dbfs: float
    source_rate_hz: int | None
    segment_id: str | None = None
    run: int = 0

    def as_metrics(self) -> dict[str, Any]:
        """The Labs `metrics` payload. Undefined values are OMITTED, not null
        (the labs_framediff convention): no onset has no strength, and a
        window with no energy has no spectral balance."""
        m: dict[str, Any] = {
            "rms_mean_dbfs": round(self.rms_mean_dbfs, 2),
            "rms_p95_dbfs": round(self.rms_p95_dbfs, 2),
            "rms_max_dbfs": round(self.rms_max_dbfs, 2),
            "onset_count": int(self.onset_count),
            "flux_max_db": round(self.flux_max_db, 2),
            "silent": bool(self.silent),
            "floor_dbfs": round(self.floor_dbfs, 2),
            "audio_s": round(self.audio_s, 3),
        }
        if self.onset_max_db is not None:
            m["onset_max_db"] = round(self.onset_max_db, 2)
            m["onset_peak_offset_s"] = round(self.onset_peak_offset_s, 3)
        if self.band_low_frac is not None:
            m["band_low_frac"] = round(self.band_low_frac, 4)
            m["band_mid_frac"] = round(self.band_mid_frac, 4)
            m["band_high_frac"] = round(self.band_high_frac, 4)
        if self.source_rate_hz:
            m["source_rate_hz"] = int(self.source_rate_hz)
        if self.segment_id:
            m["segment_id"] = str(self.segment_id)[:120]
        return m


@dataclass(frozen=True)
class NoAudio:
    """A stretch of footage the analyser could not listen to, and why."""

    start: datetime
    end: datetime
    reason: str
    segments: int
    seconds: float

    def as_metrics(self) -> dict[str, Any]:
        """The reason and how much, and NOTHING that could pass for a level."""
        return {"no_audio": True, "no_audio_reason": self.reason,
                "no_audio_segments": int(self.segments),
                "no_audio_s": round(self.seconds, 2)}


@dataclass
class RunReport:
    """Diagnostics of one decoder run; not sent, but logged and measured."""

    segments: int
    source_rate_hz: int | None
    audio_kind: str | None
    samples_decoded: int
    samples_expected: int
    returncode: int | None
    stderr: str
    error: str | None
    silent: bool = False

    @property
    def ok(self) -> bool:
        return self.error is None


@dataclass
class UnitResult:
    windows: list[WindowStats]
    no_audio: list[NoAudio]
    runs: list[RunReport]
    segments_total: int
    segments_with_audio: int
    bytes_in: int = 0
    #: Every onset as (time, strength dB), for audit and validation. NOT sent:
    #: the wire carries the per-window count and the strongest.
    onsets: list[tuple[datetime, float]] = field(default_factory=list)

    @property
    def decode_errors(self) -> list[str]:
        return [r.error for r in self.runs if r.error]


class AudioDecodeError(RuntimeError):
    """The audio existed but could not be decoded completely. Raised rather
    than reported as silence: an hour we failed to hear is not a quiet hour."""


# ---------------------------------------------------------------------------
# the decoder: ONE long-lived software ffmpeg per run
# ---------------------------------------------------------------------------
@dataclass
class DecodeReport:
    returncode: int | None
    samples: int
    stderr: str
    error: str | None


class FfmpegPcmDecoder:
    """TS bytes in on stdin, mono float32 PCM out on stdout, into `on_pcm`.

    Software decode only, no `-hwaccel` (AAC has none anyway, and the shared
    iGPU rule is absolute), one thread for the decoder and for the filter
    graph. Two drain threads (stdout, stderr) so a full pipe can never stall
    the writer: an unread PIPE is how a stream wedges.
    """

    READ = 64 * 1024

    def __init__(self, on_pcm: Callable[[np.ndarray], None], *, ffmpeg: str = "ffmpeg",
                 sample_rate: int = SAMPLE_RATE, timeout_s: float = 300.0) -> None:
        self.cmd = [
            ffmpeg, "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-threads", "1", "-filter_threads", "1",
            # Video packets are dropped in the demuxer, never reassembled or
            # probed. MEASURED: identical samples; the CPU saving is within
            # noise (3 A/B pairs on 10 real segments, 0.193-0.325 s with it,
            # 0.184-0.338 s without). Kept because it cannot cost anything.
            "-discard:v", "all",
            "-i", "pipe:0",
            "-map", "0:a:0", "-vn", "-sn", "-dn",
            "-ac", "1", "-ar", str(sample_rate),
            "-f", "f32le", "pipe:1",
        ]
        self._on_pcm = on_pcm
        self._timeout_s = timeout_s
        self.samples = 0
        self._err_head = bytearray()
        self._reader_error: str | None = None
        self.proc = subprocess.Popen(self.cmd, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self._rt = threading.Thread(target=self._read, daemon=True)
        self._et = threading.Thread(target=self._drain_err, daemon=True)
        self._rt.start()
        self._et.start()

    def _read(self) -> None:
        carry = b""
        out = self.proc.stdout
        while True:
            try:
                buf = out.read(self.READ)
            except (OSError, ValueError):
                break
            if not buf:
                break
            if carry:
                buf, carry = carry + buf, b""
            n = len(buf) - len(buf) % 4
            if n < len(buf):
                carry = buf[n:]
            if not n:
                continue
            self.samples += n // 4
            if self._reader_error is None:
                try:
                    self._on_pcm(np.frombuffer(buf[:n], dtype="<f4"))
                except Exception as e:  # noqa: BLE001 - keep draining, report later
                    self._reader_error = f"{type(e).__name__}: {e}"

    def _drain_err(self) -> None:
        err = self.proc.stderr
        while True:
            try:
                b = err.read(4096)
            except (OSError, ValueError):
                break
            if not b:
                break
            if len(self._err_head) < 4096:
                self._err_head += b[:4096 - len(self._err_head)]

    def write(self, chunk: bytes) -> bool:
        try:
            self.proc.stdin.write(chunk)
            return True
        except (BrokenPipeError, OSError, ValueError):
            return False

    def close(self) -> DecodeReport:
        try:
            self.proc.stdin.close()
        except (OSError, ValueError):
            pass
        self._rt.join(timeout=self._timeout_s)
        try:
            rc = self.proc.wait(timeout=self._timeout_s)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            rc = self.proc.wait()
        self._et.join(timeout=5.0)
        for s in (self.proc.stdout, self.proc.stderr):
            try:
                s.close()
            except (OSError, ValueError):
                pass
        err = self._err_head.decode("utf-8", "replace").strip()
        if err:
            logger.debug("ffmpeg: %s", err[:500])
        return DecodeReport(rc, self.samples, err[:500], self._reader_error)


DecoderFactory = Callable[[Callable[[np.ndarray], None]], Any]


# ---------------------------------------------------------------------------
# the session: segments in (time order), windows and no-audio stretches out
# ---------------------------------------------------------------------------
def _epoch(t: datetime | str) -> float:
    if isinstance(t, str):
        t = datetime.fromisoformat(t.replace("Z", "+00:00"))
    if t.tzinfo is None:
        # A naive stamp is a wire fault, not local time (same rule as the
        # Watchtower plugins): refuse to guess its zone.
        raise ValueError(f"segment start has no UTC offset: {t!r}")
    return t.timestamp()


def _dt(epoch: float) -> datetime:
    return datetime.fromtimestamp(epoch, tz=timezone.utc)


@dataclass
class SegmentIn:
    """One recorded segment. `data` is the TS as bytes, a file path, or an
    iterable of chunks; an iterable is consumed once and never buffered."""

    start: datetime | str
    duration_s: float
    data: bytes | bytearray | str | Path | Iterable[bytes]
    segment_id: str | None = None


def _chunks(data: Any) -> Iterator[bytes]:
    if isinstance(data, (bytes, bytearray, memoryview)):
        mv = memoryview(data)
        for i in range(0, len(mv), CHUNK):
            yield bytes(mv[i:i + CHUNK])
        return
    if isinstance(data, (str, Path)):
        with open(data, "rb") as f:
            while True:
                b = f.read(CHUNK)
                if not b:
                    return
                yield b
    yield from data


@dataclass
class _Seg:
    start: float
    duration_s: float
    segment_id: str | None
    samples: int = 0          # at SAMPLE_RATE: counted, else from duration


class _Run:
    def __init__(self, idx: int, factory: DecoderFactory, kind: str | None) -> None:
        self.idx = idx
        self.kind = kind
        self.fx = FeatureExtractor()
        self.decoder = factory(self.fx.push)
        self.segs: list[_Seg] = []
        self.source_rate: int | None = None
        self.broken: str | None = None
        self.counted = True       # every segment's samples came from ADTS

    @property
    def end(self) -> float | None:
        if not self.segs:
            return None
        s = self.segs[-1]
        return s.start + s.duration_s

    def continues(self, start: float, kind: str | None) -> bool:
        """Whether a segment starting at `start` belongs to this run."""
        if self.broken or kind != self.kind:
            return False
        end = self.end
        return end is None or (start - end <= MAX_SEAM_S and end - start <= MAX_OVERLAP_S)


class AudioEnergySession:
    """Feed a camera-hour's segments in time order; `finish()` scores it.

    One decoder process per contiguous run of audio-bearing segments, so in
    the normal case ONE per unit, however many segments it holds. A new run
    starts only at a segment with no audio, a gap over MAX_SEAM_S, or a change
    of audio format.
    """

    def __init__(self, *, window_s: float = WINDOW_S, ffmpeg: str = "ffmpeg",
                 decoder_factory: DecoderFactory | None = None) -> None:
        self.window_s = float(window_s)
        self._factory = decoder_factory or (lambda cb: FfmpegPcmDecoder(cb, ffmpeg=ffmpeg))
        self._run: _Run | None = None
        self._done: list[_Run] = []
        self._no_audio: list[tuple[float, float, str]] = []
        self._segments = 0
        self._with_audio = 0
        self._onsets: list[tuple[datetime, float]] = []
        self.bytes_in = 0

    # -- feeding -------------------------------------------------------------
    def add_segment(self, seg: SegmentIn) -> None:
        start = _epoch(seg.start)
        dur = float(seg.duration_s or 0.0)
        self._segments += 1
        it = iter(_chunks(seg.data))
        sc = TsAudioScanner()
        head: list[bytes] = []
        try:
            for chunk in it:
                head.append(chunk)
                sc.feed(chunk)
                if sc.layout is not None or sc.bytes_seen >= PROBE_BYTES:
                    break
            self.bytes_in += sc.bytes_seen
            lay = sc.layout
            if lay is None or lay.reason is not None:
                self._close_run()
                self._no_audio.append((start, start + dur, lay.reason if lay else "no_pmt"))
                return
            run = self._run
            if run is None or not run.continues(start, lay.audio_kind):
                self._close_run()
                run = self._run = _Run(len(self._done), self._factory, lay.audio_kind)
            ok = all(run.decoder.write(c) for c in head)
            for chunk in it:
                if not ok:
                    break
                self.bytes_in += len(chunk)
                sc.feed(chunk)
                ok = run.decoder.write(chunk)
            if not ok:
                run.broken = "decoder_exited_early"
        finally:
            close = getattr(it, "close", None)
            if close is not None:
                close()
        exp = sc.expected_samples_out
        if lay.audio_kind == "aac_adts" and sc.aac_frames == 0:
            # Declared in the PMT, absent from the packets: nothing to decode.
            self._no_audio.append((start, start + dur, "no_audio_packets"))
            return
        if exp is None:
            run.counted = False
            exp = int(round(dur * SAMPLE_RATE))
        elif dur <= 0.0:
            # No catalogued duration: the counted audio is the next best
            # length, and without one every following segment would look like
            # it starts after a gap and get a decoder of its own.
            dur = exp / SAMPLE_RATE
        if run.source_rate is None:
            run.source_rate = sc.source_rate
        elif sc.source_rate and sc.source_rate != run.source_rate:
            sc.rate_changed = True
        run.segs.append(_Seg(start, dur, seg.segment_id, exp))
        self._with_audio += 1

    def _close_run(self) -> None:
        if self._run is not None:
            self._done.append(self._run)
            self._run = None

    def abort(self) -> None:
        """Close and wait for every decoder started so far; results dropped."""
        self._close_run()
        for run in self._done:
            try:
                run.decoder.close()
            except Exception:  # noqa: BLE001 - best effort on the error path
                logger.debug("decoder close failed during abort", exc_info=True)
        self._done = []

    # -- scoring ---------------------------------------------------------------
    def finish(self) -> UnitResult:
        self._close_run()
        windows: list[WindowStats] = []
        reports: list[RunReport] = []
        for run in self._done:
            rep = run.decoder.close()
            feats = run.fx.finish()
            expected = sum(s.samples for s in run.segs)
            err = run.broken or rep.error
            tol = DECODE_TOLERANCE_S * SAMPLE_RATE
            if not run.counted:
                tol = max(tol, 0.02 * expected)
            if err is None and run.segs and rep.samples < expected - tol:
                err = (f"decoded {rep.samples / SAMPLE_RATE:.2f} s of "
                       f"{expected / SAMPLE_RATE:.2f} s expected (rc={rep.returncode})")
            rr = RunReport(len(run.segs), run.source_rate, run.kind, rep.samples,
                           expected, rep.returncode, rep.stderr, err)
            reports.append(rr)
            if not run.segs:
                continue
            ws = self._windows(run, feats)
            rr.silent = bool(ws) and all(w.silent for w in ws)
            windows.extend(ws)
        windows.sort(key=lambda w: (w.start, w.run))
        return UnitResult(windows, self._merge_no_audio(), reports,
                          self._segments, self._with_audio, self.bytes_in,
                          sorted(self._onsets))

    def _windows(self, run: _Run, f: FrameFeatures) -> list[WindowStats]:
        n = len(f)
        if n == 0:
            return []
        seg_starts = [s.start for s in run.segs]
        seg_samples = [s.samples for s in run.segs]
        centre = np.arange(n, dtype=np.float64) * HOP + FRAME / 2
        t, k = anchor_times(centre, seg_starts, seg_samples)
        floor = background_dbfs(f.level_db)
        on_i, on_s = detect_onsets(f.level_db, floor_dbfs=floor)
        # An onset is placed at the centre of the first frame that holds it:
        # a sharp sound enters a 32 ms frame in its second half, so on clean
        # PCM the centre is within +16 ms of it (tests). THROUGH THE REAL CODEC
        # CHAIN (G.711, recorder AAC 32k, TS segments) the reported times were
        # MEASURED 60-119 ms late on 5 synthetic onsets, so onset_peak_offset_s is
        # good to about +0.12 s, not to one hop.
        on_t, on_k = anchor_times(on_i * HOP + FRAME / 2, seg_starts, seg_samples)
        self._onsets.extend((_dt(float(a)), float(b)) for a, b in zip(on_t, on_s))
        skip = int(round(STARTUP_S * SAMPLE_RATE / HOP))
        flux = f.flux.astype(np.float64).copy()
        flux[:skip] = 0.0          # the fade-in, again
        half = FRAME / 2 / SAMPLE_RATE
        w = self.window_s
        bins = np.floor(t / w).astype(np.int64)
        on_bin = np.floor(on_t / w).astype(np.int64) if on_i.size else np.zeros(0, np.int64)
        order = np.argsort(bins, kind="stable")
        cuts = np.flatnonzero(np.diff(bins[order])) + 1
        out: list[WindowStats] = []
        for sel in np.split(order, cuts):
            b = int(bins[sel[0]])
            lv = f.level_db[sel]
            pw = f.power[sel]
            b3 = f.band3[sel].sum(axis=0)
            tot = float(b3.sum())
            start = max(b * w, float(t[sel].min()) - half)
            end = min((b + 1) * w, float(t[sel].max()) + half)
            m = on_bin == b
            cnt = int(np.count_nonzero(m))
            if cnt:
                j = int(np.argmax(np.where(m, on_s, -np.inf)))
                omax, peak_t, sid_k = float(on_s[j]), float(on_t[j]), int(on_k[j])
            else:
                omax, peak_t, sid_k = None, None, int(k[sel[0]])
            p95 = float(np.percentile(lv, 95))
            fr = (b3 / tot) if tot > 1e-12 else (None, None, None)
            out.append(WindowStats(
                start=_dt(start), end=_dt(max(end, start)),
                audio_s=sel.size * HOP / SAMPLE_RATE,
                rms_mean_dbfs=_db(float(np.mean(pw))),
                rms_p95_dbfs=p95, rms_max_dbfs=float(lv.max()),
                onset_count=cnt, onset_max_db=omax,
                onset_peak_offset_s=(max(0.0, peak_t - start)) if peak_t is not None else None,
                flux_max_db=float(flux[sel].max()),
                band_low_frac=None if fr[0] is None else float(fr[0]),
                band_mid_frac=None if fr[1] is None else float(fr[1]),
                band_high_frac=None if fr[2] is None else float(fr[2]),
                silent=p95 < SILENT_DBFS, floor_dbfs=floor,
                source_rate_hz=run.source_rate,
                segment_id=run.segs[sid_k].segment_id, run=run.idx))
        return out

    def _merge_no_audio(self) -> list[NoAudio]:
        out: list[NoAudio] = []
        for s, e, why in sorted(self._no_audio):
            if out and out[-1].reason == why and s - out[-1].end.timestamp() <= MAX_SEAM_S:
                last = out[-1]
                out[-1] = NoAudio(last.start, _dt(max(e, last.end.timestamp())), why,
                                  last.segments + 1, last.seconds + (e - s))
            else:
                out.append(NoAudio(_dt(s), _dt(e), why, 1, e - s))
        return out


def analyse_segments(segments: Iterable[SegmentIn], **kw: Any) -> UnitResult:
    """The whole analyser for one unit: segments in time order, result out.

    If the input fails part-way (a fetch, a size mismatch), every decoder
    already started is closed and waited for before the error propagates: a
    failed unit must not leave an ffmpeg behind."""
    sess = AudioEnergySession(**kw)
    try:
        for s in segments:
            sess.add_segment(s)
    except BaseException:
        sess.abort()
        raise
    return sess.finish()


def _field(seg: Any, name: str) -> Any:
    return seg.get(name) if isinstance(seg, dict) else getattr(seg, name, None)


def segments_from_raw(chunks: Iterable[bytes], segs: Sequence[Any]) -> Iterator[SegmentIn]:
    """Split ONE flat byte stream back into its segments, by catalogue size.

    For the Watchtower worker's raw path (`wants_raw`), which streams every
    fetched segment's bytes, in order, as one iterable of chunks. This
    analyser needs the boundaries (each segment is anchored to its own
    start_time, and each one may or may not carry audio), and the catalogue's
    `bytes` gives them: MEASURED equal to the fetched file size on 116 of 116
    segments. Each segment's reader is bounded to its size, and whatever the
    consumer leaves unread (a video-only segment is abandoned after its PMT)
    is drained before the next begins, so the split never drifts.

    A mismatch is an error, never a guess: a missing size, a stream that ends
    early, or bytes left over after the last segment all raise ValueError,
    because a mis-split would put sound at the wrong wall-clock time.
    `segs` are the worker's Segment objects or dicts (start_time,
    duration_s, bytes, segment_id)."""
    it = iter(chunks)
    carry = b""
    left = 0

    def pull() -> bytes:
        for c in it:
            if c:
                return bytes(c)
        return b""

    def reader(sid: Any) -> Iterator[bytes]:
        nonlocal carry, left
        while left > 0:
            if not carry:
                carry = pull()
                if not carry:
                    raise ValueError(f"raw stream ended {left} bytes short of segment {sid}")
            b, carry = carry[:left], carry[left:]
            left -= len(b)
            yield b

    prev = None
    for s in segs:
        for _ in reader(prev):
            pass
        sid, size = _field(s, "segment_id"), _field(s, "bytes")
        if not isinstance(size, int) or size <= 0:
            raise ValueError(f"segment {sid} has no catalogued size; cannot split a flat stream")
        left, prev = size, sid
        yield SegmentIn(_field(s, "start_time"), _field(s, "duration_s"), reader(sid),
                        str(sid) if sid is not None else None)
    for _ in reader(prev):
        pass
    if carry or pull():
        raise ValueError("raw stream is longer than the segments' catalogued sizes")


def analyse_raw_unit(chunks: Iterable[bytes], segs: Sequence[Any], *,
                     emit: str = "events") -> list[dict[str, Any]]:
    """The whole plugin body for the worker's raw path: flat chunks and the
    unit's segments in, ObservationIn dicts out. Raises on a decode failure or
    a mis-sized stream, so the worker files the unit failed with its reason."""
    return observations_for_unit(analyse_segments(segments_from_raw(chunks, segs)), emit=emit)


# ---------------------------------------------------------------------------
# the wire: ObservationIn dicts for one unit
# ---------------------------------------------------------------------------
def _iso(t: datetime) -> str:
    return t.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _row(start: datetime, end: datetime, metrics: dict[str, Any]) -> dict[str, Any]:
    if (end - start).total_seconds() > MAX_SPAN_S:
        end = _dt(start.timestamp() + MAX_SPAN_S)
    return {"start_time": _iso(start), "end_time": _iso(end), "metrics": metrics}


def observations_for_unit(result: UnitResult, *, emit: str = "events") -> list[dict[str, Any]]:
    """ObservationIn dicts for one camera-hour. Sends only start/end/metrics:
    sound measures no shape, no class, no box and no scene light.

    emit="events" (the default, and the one the renderer needs): a window is
    sent only when it holds at least one onset. An hour with live audio and no
    onset therefore submits NOTHING, which is exactly what lets the server say
    "checked and not found: an audio event" (routers/labs.py, observations_found
    = 0). emit="all" sends every window; it is for research, and it silences
    that negative for good, because every hour with audio then has rows.

    A stretch with no audio stream, or whose track carried no live signal,
    becomes ONE row with the reason and nothing else, span capped at MAX_SPAN_S.
    It is sent so the hour is never recorded as examined-and-quiet when it was
    not examined at all.
    """
    if emit not in ("events", "all"):
        raise ValueError(f"emit must be 'events' or 'all', not {emit!r}")
    if result.decode_errors:
        raise AudioDecodeError("; ".join(result.decode_errors))
    rows: list[tuple[float, dict[str, Any]]] = []
    for na in result.no_audio:
        rows.append((0.0, _row(na.start, na.end, na.as_metrics())))
    silent_runs = {i for i, r in enumerate(result.runs) if r.silent}
    for i in sorted(silent_runs):
        ws = [w for w in result.windows if w.run == i]
        s, e = ws[0].start, ws[-1].end
        rows.append((0.0, _row(s, e, NoAudio(s, e, "silent_track", result.runs[i].segments,
                                                 sum(w.audio_s for w in ws)).as_metrics())))
    for w in result.windows:
        if w.run in silent_runs:
            continue
        if emit == "all" or (w.onset_count > 0 and not w.silent):
            rows.append((w.onset_max_db or 0.0, _row(w.start, w.end, w.as_metrics())))
    if len(rows) > MAX_OBSERVATIONS:
        # No-audio rows first (key 0 but they are few), then the strongest.
        fixed = [r for r in rows if "no_audio" in r[1]["metrics"]]
        rest = sorted((r for r in rows if "no_audio" not in r[1]["metrics"]),
                      key=lambda r: -r[0])[:MAX_OBSERVATIONS - len(fixed)]
        rows = fixed + rest
    return [r for _k, r in sorted(rows, key=lambda r: r[1]["start_time"])]


# ---------------------------------------------------------------------------
# CLI: reproduce the validation and the cost measurement
# ---------------------------------------------------------------------------
def _cpu() -> tuple[float, float]:
    """(self, children) CPU seconds, user plus system. Children are the ffmpeg
    decoders, counted once each has been waited for (every run is closed and
    waited in finish(), before the second reading).

    `resource` is imported HERE, not at module top: it is Unix-only, and the
    Watchtower worker imports this module on Windows stations too, where a
    top-level import broke the whole plugin registry (2026-09-26). Only this
    command-line cost measurement needs it; the analysis never does."""
    import resource
    a = resource.getrusage(resource.RUSAGE_SELF)
    b = resource.getrusage(resource.RUSAGE_CHILDREN)
    return a.ru_utime + a.ru_stime, b.ru_utime + b.ru_stime


def _main(argv: Sequence[str]) -> int:
    """labs_audio_energy.py [--window-s S] [--emit events|all] MANIFEST.json...

    Each manifest is a labs_fetch.py segments.json (path, start_time,
    duration_s, segment_id). All manifests together are one unit, fed in
    start_time order. Prints one JSON object: windows, observations,
    no-audio stretches, runs, and the cost (CPU of this process AND its ffmpeg
    children, via getrusage).
    """
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("manifests", nargs="+")
    ap.add_argument("--window-s", type=float, default=WINDOW_S)
    ap.add_argument("--emit", default="events", choices=["events", "all"])
    a = ap.parse_args(argv)
    segs = []
    for m in a.manifests:
        for r in json.load(open(m)):
            segs.append(r)
    segs.sort(key=lambda r: r["start_time"])
    (u0, s0), wall0 = _cpu(), time.monotonic()
    res = analyse_segments(
        (SegmentIn(r["start_time"], r["duration_s"], r["path"], r.get("segment_id")) for r in segs),
        window_s=a.window_s)
    try:
        obs = observations_for_unit(res, emit=a.emit)
    except AudioDecodeError as e:
        obs = [{"error": str(e)}]
    (u1, s1), wall = _cpu(), time.monotonic() - wall0
    cpu_self, cpu_ffmpeg = u1 - u0, s1 - s0
    cpu = cpu_self + cpu_ffmpeg
    footage_s = sum(float(r["duration_s"]) for r in segs)
    import resource  # Unix-only; see _cpu()
    rss_self = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
    rss_child = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024
    print(json.dumps({
        "segments": res.segments_total, "segments_with_audio": res.segments_with_audio,
        "max_rss_mb_self": round(rss_self, 1), "max_rss_mb_ffmpeg": round(rss_child, 1),
        "footage_s": round(footage_s, 3), "bytes_in": res.bytes_in,
        "cpu_s": round(cpu, 3), "cpu_self_s": round(cpu_self, 3),
        "cpu_ffmpeg_s": round(cpu_ffmpeg, 3), "wall_s": round(wall, 3),
        "cpu_s_per_camera_hour": round(cpu / footage_s * 3600, 2) if footage_s else None,
        "bytes_per_camera_hour": round(res.bytes_in / footage_s * 3600) if footage_s else None,
        "runs": [r.__dict__ for r in res.runs],
        "no_audio": [dict(na.as_metrics(), start=_iso(na.start), end=_iso(na.end)) for na in res.no_audio],
        "windows": [dict(w.as_metrics(), start=_iso(w.start), end=_iso(w.end), run=w.run) for w in res.windows],
        "observations": obs,
    }, default=str))
    return 0


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    sys.exit(_main(sys.argv[1:]))
