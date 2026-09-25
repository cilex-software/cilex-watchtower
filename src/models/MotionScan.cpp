#include "MotionScan.h"
#include "MetalCacheProbe.h"

#include <QVideoSink>
#include <QVideoFrame>
#include <QImage>
#include <QDebug>

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <QDateTime>

MotionScan::MotionScan(QObject *parent)
    : QObject(parent)
{
    m_trace = qEnvironmentVariableIsSet("WT_TRACE");
    m_forceNoPts = qEnvironmentVariableIsSet("WT_MSCAN_NOPTS");
    m_forceImg = qEnvironmentVariableIsSet("WT_MSCAN_FORCEIMG");
    m_blindMs = qEnvironmentVariableIntValue("WT_MSCAN_BLINDMS");
    m_prev.resize(kGW * kGH);
    m_cur.resize(kGW * kGH);
    m_chPrev.resize(kGW * kGH);
    m_chCur.resize(kGW * kGH);
}

void MotionScan::attach(QObject *videoSink)
{
    auto *sink = qobject_cast<QVideoSink *>(videoSink);
    if (m_sink == sink)
        return;
    if (m_sink)
        disconnect(m_sink, nullptr, this, nullptr);
    m_sink = sink;
    MetalCacheProbe::noteSink("MotionScan", m_sink);
    reset();
    if (m_sink) {
        connect(m_sink, &QVideoSink::videoFrameChanged, this, &MotionScan::onFrame);
        qInfo("[MSCAN] attached sink=%p", (void *)m_sink);
    }
}

void MotionScan::notePosition(double posMs)
{
    m_notedPosMs = posMs;
    m_noteWallMs = QDateTime::currentMSecsSinceEpoch();
}

void MotionScan::reset()
{
    m_prevPtsMs = -1;
    m_noteWallMs = -1;
    m_scannedSpanMs = 0;
    m_resetWallMs = QDateTime::currentMSecsSinceEpoch();
    m_prevWallMs = -1;
    m_notedPosMs = -1;
    m_lastMotionPtsMs = -1;
    m_latestPtsMs = -1;
    m_recentN = 0; m_recentI = 0;
    m_earliestPtsMs = -1;
    m_firstMotionPtsMs = -1;
    m_candPtsMs = -1;
    m_consec = 0;
    m_framesScanned = 0;
    m_lastImgMs = 0;
    m_firstSampleWallMs = -1;
    m_lastMoveWallMs = -1;
    m_rideWallMs = -1;
    memset(m_hits, 0, sizeof(m_hits));
    m_centN = 0; m_centI = 0;
    m_saidSmall = false;
    m_saidFlowing = false;
    m_dimW = -1; m_dimH = -1;
    m_bucketCellsMax = 0; m_bucketDriftMax = 0;
    if (m_trace)
        qInfo("[MSCAN] reset");
    emit firstMotionChanged();
    emit frameScanned();
}

void MotionScan::onFrame(const QVideoFrame &frame)
{
    // Per-SESSION geometry log. This was once-per-PROCESS (a function-local static that
    // reset() never touched), which made it useless as evidence: it reported the first frame
    // the process ever decoded, and every later open — attach()+reset(), EvHeroPlayer.qml:554
    // and :639 — silently reused that stale line. It cost us a wrong premise in
    // docs/letters/2026-08-26-review-playlist-variant-order.md, where a latched 2560x1440 was
    // read as proof that Linux was served 1440p while the Mac got 640x360; CV's session rows
    // showed the run in question had ZERO 1440p fragments. An instrument that reports once per
    // process cannot answer a question asked per session.
    if (!m_saidFlowing) {
        m_saidFlowing = true;
        qInfo("[MSCAN] frames flowing: valid=%d fmt=%d %dx%d", int(frame.isValid()),
              int(frame.pixelFormat()), frame.width(), frame.height());
    }
    if (!frame.isValid())
        return;
    // A review session is stitched PER FRAGMENT and can mix renditions inside one clip (CV,
    // 2026-08-26: one session on this camera measured 1440p x2 + 640x360 x1, because the
    // main-stream retention edge fell mid-window). A rendition change rescales every luma-grid
    // score, so scores either side of it are not comparable and a band measured across it is
    // measuring two different cameras. Say so when it happens instead of averaging through it.
    if (frame.width() != m_dimW || frame.height() != m_dimH) {
        if (m_dimW > 0)
            qInfo("[MSCAN] frame size CHANGED mid-session: %dx%d -> %dx%d (fmt=%d) — scores across this boundary are not comparable",
                  m_dimW, m_dimH, frame.width(), frame.height(), int(frame.pixelFormat()));
        else
            // Always on the first VALID frame, never folded into the line above: that one fires
            // on the first frame of ANY validity (liveness), and a session whose opening frames
            // are invalid would otherwise report "-1x-1" and never say what it actually decoded
            // — measured on the +15s extension open, 2026-08-26 09:10:09.
            qInfo("[MSCAN] frame geometry: %dx%d fmt=%d", frame.width(), frame.height(),
                  int(frame.pixelFormat()));
        m_dimW = frame.width();
        m_dimH = frame.height();
    }
    const qint64 wallNow = QDateTime::currentMSecsSinceEpoch();
    // TEST ONLY (WT_MSCAN_BLINDMS=N): simulate a sampling-dead stretch during [2s, 2s+N]
    // after the FIRST SAMPLED frame — the Mac 08-25 shape (readback alive at the head, a
    // hole, alive again) — with the position feed kept running, so the coverage-hole gate
    // is exercisable on Linux. Anchoring to the first sample (not reset) keeps the alive
    // head inside the media, which is what makes the earliest-guard pass and the span
    // gate the deciding one.
    if (m_blindMs > 0 && m_firstSampleWallMs >= 0) {
        const qint64 age = wallNow - m_firstSampleWallMs;
        if (age >= 2000 && age < 2000 + m_blindMs) { emit frameScanned(); return; }
    }
    const qint64 stUs = (m_forceNoPts || m_ptsUntrusted) ? -1 : frame.startTime();
    double ptsMs;
    bool timeFromPts;                              // which clock labels THIS frame
    if (stUs >= 0) { ptsMs = double(stUs) / 1000.0; timeFromPts = true; }
    else           { ptsMs = m_notedPosMs;          timeFromPts = false; }
    const bool noteFresh = m_noteWallMs >= 0 && (wallNow - m_noteWallMs) <= 400 && m_notedPosMs >= 0;
    // A backend stamping PTS on a DIFFERENT clock than the player position (absolute
    // stream time, per-segment resets) would poison the compact mapping every downstream
    // consumer assumes — when they disagree wildly, the position is the safer clock.
    if (timeFromPts && noteFresh && std::abs(ptsMs - m_notedPosMs) > 5000.0) {
        if (!m_saidPtsDiverge) {
            m_saidPtsDiverge = true;
            qInfo("[MSCAN] backend PTS diverges from player position (pts=%.0f pos=%.0f) — position-timing from here on",
                  ptsMs, m_notedPosMs);
        }
        m_ptsUntrusted = true;                     // once caught lying, never trusted again —
                                                   // a stale-note frame must not sneak a poisoned
                                                   // PTS past the clamp (operator's Mac: one leak
                                                   // inflated coverage and froze the band's end)
        ptsMs = m_notedPosMs;
        timeFromPts = false;
    }
    // No-PTS fallback: the player's noted position stands in for the frame time, and the
    // ARRIVAL wall clock provides contiguity (steady ~66ms cadence during 1x playback;
    // seeks/stalls open a gap and rebaseline). macOS's darwin backend stamps nothing.
    if (!timeFromPts) {
        if (!m_saidNoPts && ptsMs >= 0) {
            m_saidNoPts = true;
            qInfo("[MSCAN] no PTS from backend — timing via player position");
        }
        // The note IS this frame's clock — a stale one mislabels the frame with an old
        // value (the Mac band locked mid-clip off exactly that, 08-25). Unlabelable
        // frames are skipped, but the emit keeps the QML feed refreshing for the next.
        if (!noteFresh) { emit frameScanned(); return; }
    }
    // Label-jump rebaseline: >3s of label movement between adjacent frames without an
    // app-side reset is a clock glitch, not playback (AVFoundation re-bases currentTime
    // while settling an over-served playlist — operator's Mac: 4.6s → 21.9s mid-play; TS
    // discontinuities jump raw PTS the same way). The frame must not advance coverage,
    // pair for scoring, or feed the noise ring — the next frame continues from this base.
    if (m_prevPtsMs >= 0 && ptsMs >= 0 && std::abs(ptsMs - m_prevPtsMs) > 3000.0) {
        if (++m_jumpNotes <= 3)
            qInfo("[MSCAN] time label jumped %.0f -> %.0f — rebaselined", m_prevPtsMs, ptsMs);
        m_prevPtsMs = ptsMs;
        m_prevWallMs = wallNow;
        m_consec = 0; m_candPtsMs = -1; m_lastMoveWallMs = -1;
        emit frameScanned();
        return;
    }

    // Map on THIS thread, downsample, unmap — nothing frame-shaped leaves the handler.
    bool sampled = false;
    QVideoFrame f(frame);                          // shallow copy so we can map const input
    if (!m_forceImg && f.map(QVideoFrame::ReadOnly)) {
        const int W = f.width(), H = f.height();
        const uchar *bits = f.bits(0);
        const int stride = f.bytesPerLine(0);
        // Plane 0 is luma for every YUV format our decoders emit; for packed RGB it is the
        // interleaved pixel bytes — still a stable per-cell brightness proxy for DIFFING.
        if (bits && W >= kGW && H >= kGH) {
            for (int gy = 0; gy < kGH; ++gy) {
                const int y = (gy * H) / kGH + H / (2 * kGH);
                const uchar *row = bits + qint64(y) * stride;
                for (int gx = 0; gx < kGW; ++gx) {
                    const int x = (gx * W) / kGW + W / (2 * kGW);
                    m_cur[gy * kGW + gx] = row[x];
                }
            }
            sampled = true;
        }
        f.unmap();
    }
    if (!sampled) {
        // GPU-backed frames (macOS AVFoundation / IOSurface) can refuse CPU map(). The
        // scanner used to go INERT here — so on the operator's Mac the yellow band stayed
        // at the camera's stamp and the end-of-clip extension never had evidence (08-25).
        // toImage() reads the texture back instead; costlier, so throttle near 10 Hz —
        // the 500 ms wall-clock contiguity gate tolerates the skipped frames between.
        if (++m_mapFails == 1)
            qInfo("[MSCAN] frame map failed (hw surface) — switching to toImage readback");
        if (wallNow - m_lastImgMs < 66)
            { emit frameScanned(); return; }       // throttled, not scanned — keep the feed alive
        const QImage img = frame.toImage();
        if (img.isNull() || img.width() < kGW || img.height() < kGH) {
            if (!m_saidImgFail) {
                m_saidImgFail = true;
                qInfo("[MSCAN] toImage readback failed too — scanner blind on this pipeline");
            }
            emit frameScanned();
            return;
        }
        m_lastImgMs = wallNow;
        const int W = img.width(), H = img.height();
        for (int gy = 0; gy < kGH; ++gy) {
            const int y = (gy * H) / kGH + H / (2 * kGH);
            for (int gx = 0; gx < kGW; ++gx) {
                const int x = (gx * W) / kGW + W / (2 * kGW);
                m_cur[gy * kGW + gx] = quint8(qGray(img.pixel(x, y)));
            }
        }
        sampled = true;
    }
    ++m_framesScanned;
    if (m_firstSampleWallMs < 0)
        m_firstSampleWallMs = wallNow;


    // Contiguity gate: only score against the immediately-preceding played frame.
    // PTS when the backend stamps frames; arrival wall-clock cadence when it doesn't
    // (position alone is too coarse over HLS to gate on).
    const bool contiguous = timeFromPts
        ? (m_prevPtsMs >= 0 && ptsMs >= 0
           && ptsMs > m_prevPtsMs && (ptsMs - m_prevPtsMs) <= kMaxGapMs)
        : (m_prevWallMs > 0 && ptsMs >= 0
           && (wallNow - m_prevWallMs) > 0 && double(wallNow - m_prevWallMs) <= kMaxGapMs);
    // Coverage (earliest/latest) advances only with the seed frame or CONTIGUOUS frames —
    // an unconditional update let one glitch-labeled frame claim the whole tail as scanned
    // (operator's Mac 08-25: premature verdict froze the band's end at the camera stamp).
    if (ptsMs >= 0 && (m_latestPtsMs < 0 || contiguous)) {
        if (m_earliestPtsMs < 0 || ptsMs < m_earliestPtsMs) m_earliestPtsMs = ptsMs;
        if (ptsMs > m_latestPtsMs) m_latestPtsMs = ptsMs;
    }
    if (contiguous)
        m_scannedSpanMs += timeFromPts ? (ptsMs - m_prevPtsMs) : double(wallNow - m_prevWallMs);
    m_prevWallMs = wallNow;
    if (contiguous) {
        int changed = 0;
        int nAct = 0; long sx = 0, sy = 0; int minx = 99, maxx = -1, miny = 99, maxy = -1;
        for (int i = 0; i < kGW * kGH; ++i) {
            const bool ch = std::abs(int(m_cur[i]) - int(m_prev[i])) > kDiffThresh;
            if (ch) ++changed;
            quint8 &h = m_hits[i];
            h = ch ? quint8(h < 5 ? h + 1 : 5) : quint8(h ? h - 1 : 0);
            if (h >= 3) {
                ++nAct;
                const int gx = i % kGW, gy = i / kGW;
                sx += gx; sy += gy;
                if (gx < minx) minx = gx; if (gx > maxx) maxx = gx;
                if (gy < miny) miny = gy; if (gy > maxy) maxy = gy;
            }
        }
        // Compact persistent cluster? Track its centroid; NET drift over ~1.5-2.5s is the
        // walker/wind separator (a gusting bush oscillates around its anchor: net ~0).
        bool smallMoving = false;
        double drift = 0;
        if (nAct >= 1 && nAct <= 8 && (maxx - minx) <= 3 && (maxy - miny) <= 3) {
            const double cx = double(sx) / nAct, cy = double(sy) / nAct;
            for (int k = 0; k < m_centN; ++k) {
                const qint64 age = wallNow - m_cent[k].w;
                if (age >= 1500 && age <= 2500) {
                    const double dx = cx - m_cent[k].x, dy = cy - m_cent[k].y;
                    const double d = std::sqrt(dx * dx + dy * dy);
                    if (d > drift) drift = d;
                }
            }
            m_cent[m_centI] = { wallNow, cx, cy };
            m_centI = (m_centI + 1) % 24; if (m_centN < 24) ++m_centN;
            smallMoving = drift >= 1.2;
        }
        if (nAct > m_bucketCellsMax) m_bucketCellsMax = nAct;
        if (drift > m_bucketDriftMax) m_bucketDriftMax = drift;
        const double score = double(changed) / double(kGW * kGH);
        // Scene noise floor: median of the trailing ring (single-frame GOP spikes can't move a median).
        double floorv = 0;
        if (m_recentN >= 8) {
            double tmp[32]; int n = m_recentN;
            for (int i = 0; i < n; ++i) tmp[i] = m_recent[i];
            std::sort(tmp, tmp + n);
            floorv = tmp[n / 2];
        }
        m_recent[m_recentI] = score; m_recentI = (m_recentI + 1) % 32;
        if (m_recentN < 32) ++m_recentN;
        // Movement = absolute floor OR many multiples of this scene's own noise floor
        // (adaptive path needs a real floor history and a nontrivial absolute minimum).
        const bool moving = (score >= kCellFrac)
                            || (m_recentN >= 8 && floorv > 0.0001 && score >= 6.0 * floorv && score >= 0.008);
        // Score telemetry, ALWAYS ON since 08-25: one line per ~2s of playback. The Mac
        // rounds burned on guessing what the scanner saw end with this — the rolling
        // run log now carries the actual score stream of every clip played.
        {
            if (score > m_bucketMax) m_bucketMax = score;
            if (ptsMs - m_bucketT0 >= 2000) {
                qInfo("[MSCAN] scores pts=%.0f..%.0f max=%.4f floor=%.4f cells=%d drift=%.1f",
                      m_bucketT0, ptsMs, m_bucketMax, floorv, m_bucketCellsMax, m_bucketDriftMax);
                m_bucketT0 = ptsMs; m_bucketMax = 0;
                m_bucketCellsMax = 0; m_bucketDriftMax = 0;
            }
        }
        if (moving) {
            const bool chained = m_lastMoveWallMs > 0 && double(wallNow - m_lastMoveWallMs) <= kChainMs;
            if (!chained) { m_consec = 0; m_candPtsMs = m_prevPtsMs; }   // new chain starts here
            m_lastMoveWallMs = wallNow;
            if (++m_consec >= kConsecNeed) {
                if (m_firstMotionPtsMs < 0) {
                    m_firstMotionPtsMs = m_candPtsMs;
                    qInfo("[MSCAN] first motion pts=%.0fms score=%.3f floor=%.4f", m_firstMotionPtsMs, score, floorv);
                    emit firstMotionChanged();
                }
                if (ptsMs > m_lastMotionPtsMs)
                    m_lastMotionPtsMs = ptsMs;     // rolls forward with every sustained-motion frame
            }
        } else if (m_lastMoveWallMs > 0 && double(wallNow - m_lastMoveWallMs) > kChainMs) {
            m_consec = 0;                          // chain expired quietly — not one skipped sample
            m_candPtsMs = -1;
            m_lastMoveWallMs = -1;
        }
        // Post-lock tail ride: a distant mover at readback cadence crosses the gate only
        // sporadically, so the tight sustain chain misses the tail and the end-of-clip
        // extension starves (measured 08-25: tail buckets max 0.014-0.061, zero sustained).
        // PAIRS of crossings within 2 s ride lastMotion forward instead. A GOP I-frame
        // pulse is one crossing every ~4 s — it can never pair — and a clip that never
        // produced a sustained LOCK can't ride at all: false extensions stay impossible.
        // Post-lock ride: paired above-gate crossings within 2s advance lastMotion. This
        // is what carries every real extension on the CRF-18 encode (measured 02:05: with
        // it removed, the operator's clip went final at 16.9s and the walker was cut at
        // 25s again — the sustained chain alone cannot hold even the NEAR person on the
        // softened diffs). KNOWN ISSUE, deliberate trade: on 1440p road-facing scenes,
        // distant traffic crosses the gate as flashes all night and can walk the chain to
        // the 85s cap (bounded by the cap + the finality rule when the scene quiets); the
        // operator's Mac (360p served) never sees the road and behaves correctly —
        // verified in their 00:41 run. Daylight fix on file: a speed-bounded cluster gate
        // designed against the cells/drift telemetry every log now carries. GOP pulses
        // still cannot pair (one frame per ~2.5-4s).
        if (moving && m_firstMotionPtsMs >= 0) {
            if (m_rideWallMs > 0 && double(wallNow - m_rideWallMs) <= 2000.0 && ptsMs > m_lastMotionPtsMs)
                m_lastMotionPtsMs = ptsMs;
            m_rideWallMs = wallNow;
        }
        // Small-mover cluster (compact + persistent + drifting): TELEMETRY ONLY — as a
        // ride source it tracked road traffic to the cap (drift 14.6 sweeps, 1.4 cruise;
        // 08-26 01:59). The bucket lines carry cells/drift for the daylight gate design.
        if (smallMoving && m_firstMotionPtsMs >= 0 && !m_saidSmall) {
            m_saidSmall = true;
            qInfo("[MSCAN] small-mover candidate (cells=%d drift=%.1f) — telemetry only", nAct, drift);
        }
    } else if (!contiguous) {
        m_consec = 0;
        m_candPtsMs = -1;
        m_lastMoveWallMs = -1;
        memset(m_hits, 0, sizeof(m_hits));         // streaks are pairwise state: void across a gap
        m_centN = 0; m_centI = 0;
        m_chPrev.fill(0);
    }

    m_prev = m_cur;
    m_prevPtsMs = ptsMs;
    emit frameScanned();
}
