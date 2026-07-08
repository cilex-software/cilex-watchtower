#include "FrameClock.h"

#include <QVideoSink>
#include <QVideoFrame>
#include <QDebug>

#include <algorithm>

void FrameClock::attach(QObject *videoSink)
{
    auto *sink = qobject_cast<QVideoSink *>(videoSink);
    if (m_sink == sink)
        return;
    if (m_sink)
        disconnect(m_sink, nullptr, this, nullptr);
    m_sink = sink;
    reset();
    if (m_sink)
        connect(m_sink, &QVideoSink::videoFrameChanged, this, &FrameClock::onFrame);
}

void FrameClock::reset()
{
    m_lastPtsMs = -1;
    m_frames = m_valid = m_invalid = 0;
    m_ring.clear();
}

void FrameClock::onFrame(const QVideoFrame &frame)
{
    ++m_frames;
    const qint64 stUs = frame.startTime();          // µs; -1 when the backend doesn't stamp it
    if (stUs >= 0) {
        ++m_valid;
        m_lastPtsMs = double(stUs) / 1000.0;
        // Ring stays PTS-sorted-enough for prevPtsMs: appends are monotonic during normal
        // play; a backward seek appends lower values — prevPtsMs scans, so order is free.
        m_ring.append(m_lastPtsMs);
        if (m_ring.size() > kRingMax)
            m_ring.remove(0, m_ring.size() - kRingMax);
    } else {
        ++m_invalid;
    }
    emit frameSeen();
}

double FrameClock::medianFrameDurMs() const
{
    if (m_ring.size() < 8)
        return -1;
    QVector<double> pts = m_ring;
    std::sort(pts.begin(), pts.end());
    QVector<double> d;
    d.reserve(pts.size());
    for (int i = 1; i < pts.size(); ++i) {
        const double dt = pts[i] - pts[i - 1];
        if (dt > 1.0 && dt < 2000.0)                // drop dup-PTS and seek-gap outliers
            d.append(dt);
    }
    if (d.isEmpty())
        return -1;
    std::sort(d.begin(), d.end());
    return d[d.size() / 2];
}

double FrameClock::prevPtsMs(double beforeMs) const
{
    double best = -1;
    for (double p : m_ring)
        if (p < beforeMs - 0.5 && p > best)
            best = p;
    return best;
}
