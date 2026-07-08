#include "FrameCache.h"

#include <QVideoSink>
#include <QVideoFrame>
#include <QImage>
#include <QBuffer>
#include <QColor>
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
    if (m_sink)
        connect(m_sink, &QVideoSink::videoFrameChanged, this, &FrameCache::onFrame);
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
    if (m_capturing == on)
        return;
    m_capturing = on;
    emit changed();
}

void FrameCache::onFrame(const QVideoFrame &frame)
{
    if (!m_capturing)
        return;
    const qint64 stUs = frame.startTime();
    if (stUs < 0)
        return;                                       // our own repaints carry PTS; raw invalids skipped
    const qint64 pts = stUs / 1000;
    {
        QMutexLocker l(&m_mx);
        if (m_store.contains(pts))
            return;
    }
    const QImage img = frame.toImage();               // GPU readback — capture is step-gated, never at play rate
    if (img.isNull())
        return;
    QByteArray jpg;
    QBuffer buf(&jpg);
    buf.open(QIODevice::WriteOnly);
    if (!img.save(&buf, "JPG", 88))
        return;
    {
        QMutexLocker l(&m_mx);
        m_store.insert(pts, jpg);
        m_bytes += jpg.size();
        m_anchorPts = pts;
        evictIfNeededLocked();
    }
    ++m_rev;
    emit changed();
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
