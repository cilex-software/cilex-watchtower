#include "MotionScan.h"

#include <QVideoSink>
#include <QVideoFrame>
#include <QDebug>

#include <cmath>
#include <cstdlib>
#include <QDateTime>

MotionScan::MotionScan(QObject *parent)
    : QObject(parent)
{
    m_trace = qEnvironmentVariableIsSet("WT_TRACE");
    m_forceNoPts = qEnvironmentVariableIsSet("WT_MSCAN_NOPTS");
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
    reset();
    if (m_sink) {
        connect(m_sink, &QVideoSink::videoFrameChanged, this, &MotionScan::onFrame);
        qInfo("[MSCAN] attached sink=%p", (void *)m_sink);
    }
}

void MotionScan::reset()
{
    m_prevPtsMs = -1;
    m_prevWallMs = -1;
    m_notedPosMs = -1;
    m_earliestPtsMs = -1;
    m_firstMotionPtsMs = -1;
    m_candPtsMs = -1;
    m_consec = 0;
    if (m_trace)
        qInfo("[MSCAN] reset");
    emit firstMotionChanged();
    emit frameScanned();
}

void MotionScan::onFrame(const QVideoFrame &frame)
{
    static int s_seen = 0;
    if (++s_seen == 1)
        qInfo("[MSCAN] frames flowing: valid=%d fmt=%d %dx%d", int(frame.isValid()),
              int(frame.pixelFormat()), frame.width(), frame.height());
    if (!frame.isValid())
        return;
    const qint64 stUs = m_forceNoPts ? -1 : frame.startTime();
    const bool havePts = stUs >= 0;
    // No-PTS fallback: the player's noted position stands in for the frame time, and the
    // ARRIVAL wall clock provides contiguity (steady ~66ms cadence during 1x playback;
    // seeks/stalls open a gap and rebaseline). macOS's darwin backend stamps nothing.
    const double ptsMs = havePts ? double(stUs) / 1000.0 : m_notedPosMs;
    const qint64 wallNow = QDateTime::currentMSecsSinceEpoch();
    if (!havePts && !m_saidNoPts && ptsMs >= 0) {
        m_saidNoPts = true;
        qInfo("[MSCAN] no PTS from backend — timing via player position");
    }

    // Map on THIS thread, downsample, unmap — nothing frame-shaped leaves the handler.
    QVideoFrame f(frame);                          // shallow copy so we can map const input
    if (!f.map(QVideoFrame::ReadOnly)) {
        if (++m_mapFails == 1)
            qInfo("[MSCAN] frame map failed (hw surface?) — scanner inert on this pipeline");
        return;
    }
    const int W = f.width(), H = f.height();
    const uchar *bits = f.bits(0);
    const int stride = f.bytesPerLine(0);
    if (!bits || W < kGW || H < kGH) { f.unmap(); return; }
    // Plane 0 is luma for every YUV format our decoders emit; for packed RGB it is the
    // interleaved pixel bytes — still a stable per-cell brightness proxy for DIFFING.
    for (int gy = 0; gy < kGH; ++gy) {
        const int y = (gy * H) / kGH + H / (2 * kGH);
        const uchar *row = bits + qint64(y) * stride;
        for (int gx = 0; gx < kGW; ++gx) {
            const int x = (gx * W) / kGW + W / (2 * kGW);
            m_cur[gy * kGW + gx] = row[x];
        }
    }
    f.unmap();

    if (ptsMs >= 0 && (m_earliestPtsMs < 0 || ptsMs < m_earliestPtsMs))
        m_earliestPtsMs = ptsMs;

    // Contiguity gate: only score against the immediately-preceding played frame.
    // PTS when the backend stamps frames; arrival wall-clock cadence when it doesn't
    // (position alone is too coarse over HLS to gate on).
    const bool contiguous = havePts
        ? (m_prevPtsMs >= 0 && ptsMs >= 0
           && ptsMs > m_prevPtsMs && (ptsMs - m_prevPtsMs) <= kMaxGapMs)
        : (m_prevWallMs > 0 && ptsMs >= 0
           && (wallNow - m_prevWallMs) > 0 && double(wallNow - m_prevWallMs) <= kMaxGapMs);
    m_prevWallMs = wallNow;
    if (contiguous && m_firstMotionPtsMs < 0) {
        int changed = 0;
        for (int i = 0; i < kGW * kGH; ++i)
            if (std::abs(int(m_cur[i]) - int(m_prev[i])) > kDiffThresh)
                ++changed;
        const double score = double(changed) / double(kGW * kGH);
        if (m_trace) {                                  // score telemetry: max per ~2s bucket
            if (score > m_bucketMax) m_bucketMax = score;
            if (ptsMs - m_bucketT0 >= 2000) {
                qInfo("[MSCAN] scores pts=%.0f..%.0f max=%.4f", m_bucketT0, ptsMs, m_bucketMax);
                m_bucketT0 = ptsMs; m_bucketMax = 0;
            }
        }
        if (score >= kCellFrac) {
            if (m_consec == 0)
                m_candPtsMs = m_prevPtsMs;         // motion began between prev and this frame
            if (++m_consec >= kConsecNeed) {
                m_firstMotionPtsMs = m_candPtsMs;
                qInfo("[MSCAN] first motion pts=%.0fms score=%.3f", m_firstMotionPtsMs, score);
                emit firstMotionChanged();
            }
        } else {
            m_consec = 0;
            m_candPtsMs = -1;
        }
    } else if (!contiguous) {
        m_consec = 0;
        m_candPtsMs = -1;
        m_chPrev.fill(0);
    }

    m_prev = m_cur;
    m_prevPtsMs = ptsMs;
    emit frameScanned();
}
