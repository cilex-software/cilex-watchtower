#include "FrameCache.h"

#include <QVideoSink>
#include <QVideoFrame>
#include <QImage>
#include <QBuffer>
#include <QColor>
#include <QDateTime>
#include <QDebug>

void FrameCache::attach(QObject *videoSink)
{
    auto *sink = qobject_cast<QVideoSink *>(videoSink);
    if (m_sink == sink)
        return;
    if (m_sink)
        disconnect(m_sink, nullptr, this, nullptr);
    m_sink = sink;
    clear();
    // DIRECT connection — run on the backend's delivery thread, inside the
    // emission, while the decoder still owns the frame's hw surface. Queued
    // delivery (AutoConnection) let session churn destroy the decoder between
    // emission and delivery; toImage() then dereferenced a freed
    // AVHWFramesContext → SIGSEGV (P0 2026-07-10, gdb-confirmed).
    if (m_sink)
        connect(m_sink, &QVideoSink::videoFrameChanged, this, &FrameCache::onFrame,
                Qt::DirectConnection);
}

bool FrameCache::captureCurrent()
{
    if (!m_sink)
        return false;
    const QVideoFrame f = m_sink->videoFrame();
    if (!f.isValid())
        return false;
    const int before = frames();
    captureFrame(f, true);
    return frames() > before || f.startTime() >= 0;
}

void FrameCache::clear()
{
    {
        QMutexLocker l(&m_mx);
        m_store.clear();
        m_bytes = 0;
        m_anchorPts = -1;
    }
    ++m_rev;
    emit changed();
}

void FrameCache::setCapturing(bool on)
{
    if (m_capturing.load(std::memory_order_relaxed) == on)
        return;
    m_capturing.store(on, std::memory_order_relaxed);
    emit changed();
}

void FrameCache::onFrame(const QVideoFrame &frame)
{
    if (!m_capturing.load(std::memory_order_relaxed))
        return;
    captureFrame(frame, true);                        // operator-side capture anchors eviction
}

void FrameCache::onHarvestFrame(const QVideoFrame &frame)
{
    if (!m_harvestCapturing.load(std::memory_order_relaxed))
        return;
    captureFrame(frame, false);                       // harvest never moves the anchor
}

// Runs on the media backend's frame-delivery thread (DirectConnection).
void FrameCache::captureFrame(const QVideoFrame &frame, bool moveAnchor)
{
    if (!frame.isValid())
        return;
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    if (nowMs < m_poisonUntilMs.load(std::memory_order_relaxed))
        return;                                       // decoder mid corrupt-packet storm — hands off
    const qint64 stUs = frame.startTime();
    if (stUs < 0)
        return;                                       // our own repaints carry PTS; raw invalids skipped
    const qint64 pts = stUs / 1000;
    {
        QMutexLocker l(&m_mx);
        if (m_store.contains(pts))
            return;
    }
    // GPU readback. A corrupt-packet frame whose VA surface fails to sync comes
    // back null here (Qt logs "Cannot map a video frame in ReadOnly mode!") —
    // drop it AND latch: the NEXT frame from the same storm can crash inside
    // Qt's converter (map falsely succeeds; see m_poisonUntilMs).
    const QImage img = frame.toImage();
    if (img.isNull()) {
        m_poisonUntilMs.store(nowMs + 3000, std::memory_order_relaxed);
        qWarning("[FrameCache] unmappable frame (pts %lld) — capture latched off 3s", (long long)pts);
        return;
    }
    QByteArray jpg;
    QBuffer buf(&jpg);
    buf.open(QIODevice::WriteOnly);
    if (!img.save(&buf, "JPG", 88))
        return;
    {
        QMutexLocker l(&m_mx);
        m_store.insert(pts, jpg);
        m_bytes += jpg.size();
        if (moveAnchor || m_anchorPts < 0)
            m_anchorPts = pts;
        evictIfNeededLocked();
    }
    ++m_rev;
    emit changed();
}

QVideoSink *FrameCache::harvestSink()
{
    if (!m_harvestSink) {
        m_harvestSink = new QVideoSink(this);
        connect(m_harvestSink, &QVideoSink::videoFrameChanged, this, &FrameCache::onHarvestFrame,
                Qt::DirectConnection);                // see attach() — same UAF rationale
    }
    return m_harvestSink;
}

void FrameCache::setHarvestCapturing(bool on)
{
    if (m_harvestCapturing.load(std::memory_order_relaxed) == on)
        return;
    m_harvestCapturing.store(on, std::memory_order_relaxed);
    emit changed();
}

void FrameCache::setAnchorPts(double ptsMs)
{
    QMutexLocker l(&m_mx);
    m_anchorPts = qint64(ptsMs);
}

void FrameCache::evictIfNeededLocked()
{
    // Drop whichever end is farther from the anchor — stepping is local, so the
    // far end is the least likely to be revisited.
    while (m_store.size() > kMaxFrames || m_bytes > kMaxBytes) {
        auto first = m_store.begin();
        auto last = std::prev(m_store.end());
        const bool dropFirst = m_anchorPts < 0
            || qAbs(first.key() - m_anchorPts) >= qAbs(last.key() - m_anchorPts);
        auto it = dropFirst ? first : last;
        m_bytes -= it.value().size();
        m_store.erase(it);
    }
}

double FrameCache::prevPts(double beforeMs) const
{
    QMutexLocker l(&m_mx);
    const qint64 key = qint64(beforeMs);
    auto it = m_store.lowerBound(key);                // first ≥ key
    if (it == m_store.begin())
        return -1;
    return double(std::prev(it).key());
}

double FrameCache::nextPts(double afterMs) const
{
    QMutexLocker l(&m_mx);
    auto it = m_store.upperBound(qint64(afterMs));    // first > afterMs
    return it == m_store.end() ? -1 : double(it.key());
}

double FrameCache::repaint(double ptsMs, double tolMs)
{
    if (!m_sink)
        return -1;
    qint64 best = -1;
    QByteArray jpg;
    {
        QMutexLocker l(&m_mx);
        if (m_store.isEmpty())
            return -1;
        auto it = m_store.lowerBound(qint64(ptsMs));
        qint64 bestD = qint64(tolMs) + 1;
        if (it != m_store.end() && qAbs(it.key() - qint64(ptsMs)) < bestD) {
            best = it.key(); bestD = qAbs(it.key() - qint64(ptsMs));
        }
        if (it != m_store.begin()) {
            auto p = std::prev(it);
            if (qAbs(p.key() - qint64(ptsMs)) < bestD)
                best = p.key();
        }
        if (best < 0)
            return -1;
        jpg = m_store.value(best);
        m_anchorPts = best;
    }
    QImage img = QImage::fromData(jpg, "JPG");
    if (img.isNull())
        return -1;
    QVideoFrame vf(img);
    if (!vf.isValid())
        return -1;
    vf.setStartTime(best * 1000);                     // restamp: FrameClock keeps tracking truthfully
    vf.setEndTime(best * 1000);
    m_sink->setVideoFrame(vf);
    return double(best);
}

QVariantList FrameCache::cachedAround(double centerMs, int back, int fwd) const
{
    QMutexLocker l(&m_mx);
    QVariantList out;
    auto it = m_store.upperBound(qint64(centerMs));   // first > center
    // walk down for the at/below-center side
    QVector<qint64> below;
    for (auto d = it; d != m_store.begin() && below.size() < back;) {
        --d;
        below.prepend(d.key());
    }
    for (qint64 k : below)
        out.append(double(k));
    for (auto u = it; u != m_store.end() && fwd > 0; ++u, --fwd)
        out.append(double(u.key()));
    return out;
}

QImage FrameCache::imageForPts(qint64 ptsMs) const
{
    QByteArray jpg;
    {
        QMutexLocker l(&m_mx);
        auto it = m_store.lowerBound(ptsMs - 5);
        if (it == m_store.end() || qAbs(it.key() - ptsMs) > 5)
            return QImage();
        jpg = it.value();
    }
    return QImage::fromData(jpg, "JPG");
}

QImage FrameCacheImageProvider::requestImage(const QString &id, QSize *size, const QSize &requested)
{
    const qint64 pts = id.split(QLatin1Char('?')).first().toLongLong();
    QImage img = m_cache->imageForPts(pts);
    if (img.isNull()) {
        img = QImage(160, 90, QImage::Format_RGB32);
        img.fill(QColor("#16140f"));
    }
    if (requested.isValid() && requested.width() > 0)
        img = img.scaled(requested, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    if (size)
        *size = img.size();
    return img;
}
