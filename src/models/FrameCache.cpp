#include "FrameCache.h"

#include <QVideoSink>
#include <QVideoFrame>
#include <QImage>
#include <QBuffer>
#include <QColor>
#include <QDateTime>
#include <QDebug>
#include <QElapsedTimer>
#include <QThread>
#include <QThreadPool>

namespace {
// Strip thumbnail width (px). The strip's largest slot is ~171 px wide (height
// 96 × 16:9), so 256 keeps it crisp with headroom; WT_STRIP_THUMB_PX overrides
// for the A/B sweep.
const int s_thumbPx = []{
    const int v = qEnvironmentVariableIntValue("WT_STRIP_THUMB_PX");
    return v > 0 ? v : 256;
}();
// WT_CACHE_TIMING=1 → per-frame cost breakdown ([CACHETIME] lines) for the
// spec's Test 1 (toImage readback vs thumb encode vs full encode).
const bool s_cacheTiming = qEnvironmentVariableIsSet("WT_CACHE_TIMING");
// WT_NO_POISON_LATCH=1 disables the storm damper (diagnostic/soak use only —
// the damper is LOAD protection, never correctness; the pre-map guard below is
// the crash prevention). The destructive reproduction hook that used to live
// here (WT_POISON_REPRO) moved to the standalone harness:
// docs/qt-upstream/repro/ — release builds carry no intentional crash call.
const bool s_noLatch = qEnvironmentVariableIsSet("WT_NO_POISON_LATCH");
}

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
        m_fullStore.clear();
        m_fullBytes = 0;
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
    // PRE-MAP GUARD (root cause proven 2026-07-12; internal Qt patch series in
    // third_party/qt-patches/6.12/): Qt 6.12's QFFmpegVideoBuffer::map()
    // commits m_swFrame BEFORE av_hwframe_transfer_data(); on transfer failure
    // the blank frame is retained, and any LATER map of that same buffer skips
    // the transfer and reports a *successful* MapData (planeCount > 0, null
    // plane pointers). The production crashes were a SINGLE toImage() call
    // double-mapping internally: the texture path maps first (graceful
    // failure), the CPU-converter fallback maps second (fake success) and
    // walks the null planes. toImage() offers no safe probe, so map ourselves:
    //  - map() returns false → the transfer failed NOW (first map of this
    //    buffer): skip the frame.
    //  - map() returns true with any null plane pointer → an EARLIER map
    //    failed and this is the fake-success blank: skip — a toImage() here
    //    is the exact production SIGSEGV on unpatched Qt.
    // Every successful map is balanced with unmap(). On healthy frames the
    // extra map is ~free (the transfer runs once; toImage()'s own map reuses
    // the committed m_swFrame). The storm damper below is LOAD protection
    // during corrupt-packet bursts — elapsed time is not treated as
    // correctness or recovery; the guard re-probes every frame regardless.
    {
        QVideoFrame probe(frame);
        if (!probe.map(QVideoFrame::ReadOnly)) {
            qWarning("[FrameCache] hw transfer failed at first map (pts %lld) — frame skipped",
                     (long long)pts);
            if (!s_noLatch)
                m_poisonUntilMs.store(nowMs + 3000, std::memory_order_relaxed);
            return;
        }
        bool fakeSuccess = false;
        for (int pl = 0; pl < probe.planeCount(); ++pl) {
            if (probe.bits(pl) == nullptr) {
                fakeSuccess = true;
                break;
            }
        }
        probe.unmap();
        if (fakeSuccess) {
            qWarning("[FrameCache] poisoned buffer detected (fake-success map, pts %lld) — frame skipped",
                     (long long)pts);
            if (!s_noLatch)
                m_poisonUntilMs.store(nowMs + 3000, std::memory_order_relaxed);
            return;
        }
    }
    const QImage img = frame.toImage();
    if (img.isNull()) {
        qWarning("[FrameCache] toImage NULL (pts %lld) — skipped", (long long)pts);
        return;
    }
    QElapsedTimer tt;
    if (s_cacheTiming)
        tt.start();
    // THUMBNAIL TIER — the strip's critical path. A ~256 px encode is ~1-2
    // orders of magnitude cheaper than 1440p; strip_ms waits only on this.
    const QImage thumb = (img.width() > s_thumbPx)
        ? img.scaledToWidth(s_thumbPx, Qt::SmoothTransformation) : img;
    QByteArray tjpg;
    {
        QBuffer buf(&tjpg);
        buf.open(QIODevice::WriteOnly);
        if (!thumb.save(&buf, "JPG", 85))
            return;
    }
    const qint64 tThumb = s_cacheTiming ? tt.elapsed() : 0;
    {
        QMutexLocker l(&m_mx);
        if (m_store.contains(pts))
            return;                                   // raced with another tap
        m_store.insert(pts, tjpg);
        m_bytes += tjpg.size();
        if (moveAnchor || m_anchorPts < 0)
            m_anchorPts = pts;
        evictIfNeededLocked();
    }
    ++m_rev;
    emit changed();

    // FULL-RES TIER — off the critical path. The entry/operator frame
    // (moveAnchor) encodes synchronously so the big view is instantly crisp;
    // harvest frames defer to the pool. Only the QImage (a decoder-independent
    // CPU copy) crosses threads — NEVER the QVideoFrame (P0 UAF rule).
    if (moveAnchor) {
        QByteArray fjpg;
        QBuffer fbuf(&fjpg);
        fbuf.open(QIODevice::WriteOnly);
        if (img.save(&fbuf, "JPG", 88)) {
            QMutexLocker l(&m_mx);
            insertFullLocked(pts, fjpg);
        }
        if (s_cacheTiming)
            qInfo("[CACHETIME] pts=%lld toImage+thumb=%lldms full_sync=%lldms res=%dx%d",
                  (long long)pts, (long long)tThumb, (long long)(tt.elapsed() - tThumb),
                  img.width(), img.height());
    } else {
        const QImage fullCopy = img;                  // implicit-shared CPU buffer, thread-safe
        QThreadPool::globalInstance()->start([this, fullCopy, pts]() {
            QElapsedTimer ft;
            if (s_cacheTiming)
                ft.start();
            QByteArray fjpg;
            QBuffer fbuf(&fjpg);
            fbuf.open(QIODevice::WriteOnly);
            if (!fullCopy.save(&fbuf, "JPG", 88))
                return;
            {
                QMutexLocker l(&m_mx);
                if (!m_store.contains(pts))
                    return;                           // evicted/cleared meanwhile — don't resurrect
                insertFullLocked(pts, fjpg);
            }
            if (s_cacheTiming)
                qInfo("[CACHETIME] pts=%lld full_async=%lldms", (long long)pts, (long long)ft.elapsed());
            emit fullResReady(double(pts));
        });
        if (s_cacheTiming)
            qInfo("[CACHETIME] pts=%lld toImage+thumb=%lldms res=%dx%d",
                  (long long)pts, (long long)tThumb, img.width(), img.height());
    }
}

void FrameCache::insertFullLocked(qint64 pts, const QByteArray &jpg)
{
    if (m_fullStore.contains(pts))
        return;
    m_fullStore.insert(pts, jpg);
    m_fullBytes += jpg.size();
    evictFullLocked();
}

void FrameCache::evictFullLocked()
{
    while (m_fullStore.size() > kMaxFullFrames || m_fullBytes > kMaxFullBytes
           || m_bytes + m_fullBytes > kMaxBytes) {
        auto first = m_fullStore.begin();
        auto last = std::prev(m_fullStore.end());
        const bool dropFirst = m_anchorPts < 0
            || qAbs(first.key() - m_anchorPts) >= qAbs(last.key() - m_anchorPts);
        auto it = dropFirst ? first : last;
        m_fullBytes -= it.value().size();
        m_fullStore.erase(it);
    }
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
        // Full-res when the async encode has landed; the thumbnail otherwise
        // (one soft paint — fullResReady triggers the upgrade repaint).
        jpg = m_fullStore.contains(best) ? m_fullStore.value(best) : m_store.value(best);
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
