#pragma once

#include <QObject>
#include <QMap>
#include <QByteArray>
#include <QMutex>
#include <QImage>
#include <QQuickImageProvider>
#include <QVariantList>

class QVideoSink;
class QVideoFrame;

// Bounded decoded-frame cache for instant hot backward stepping
// (docs/plans/2026-07-08-frame-step-plan.md P2) and the frame-by-frame
// filmstrip's thumbnails (frameMode). P1 measured that a seek in either
// direction into the zone the decoder recently stepped through renders the
// zone's HEAD frame instead of the target, so seek-based hot back-steps cost
// seconds. This is the industry answer (mpv reverse_queue / US7190883 LRU
// frame cache): keep the recently DISPLAYED frames and repaint back-steps from
// memory, no demuxer involved.
//
// Capture is gated (capturing=false by default) — the stepper enables it only
// while a step operation runs, so normal 20fps playback never pays the
// GPU-readback + JPEG cost. Frames store JPEG-compressed (~0.3-0.6 MB each at
// 1440p vs 14.7 MB raw), keyed by PTS ms; repaint() reconstructs a QVideoFrame
// (with its PTS restamped, so FrameClock keeps tracking truthfully) and sets it
// on the sink. Eviction: size- and count-capped, dropping the entry farthest
// from the last repaint/insert point (the operator steps locally).
//
// The store is mutex-guarded: FrameCacheImageProvider serves thumbnails from
// Quick's image-loader threads while the GUI thread inserts/evicts.
class FrameCache : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int frames READ frames NOTIFY changed)
    Q_PROPERTY(bool capturing READ capturing WRITE setCapturing NOTIFY changed)
    Q_PROPERTY(double bytesMB READ bytesMB NOTIFY changed)
    // Bumped on every insert/clear — QML image URLs append it as a cache-buster
    // and the filmstrip rebuilds its slot model on it.
    Q_PROPERTY(int rev READ rev NOTIFY changed)
public:
    explicit FrameCache(QObject *parent = nullptr) : QObject(parent) {}

    Q_INVOKABLE void attach(QObject *videoSink);      // capture tap + repaint target
    Q_INVOKABLE void clear();

    int frames() const { QMutexLocker l(&m_mx); return m_store.size(); }
    bool capturing() const { return m_capturing; }
    void setCapturing(bool on);
    double bytesMB() const { QMutexLocker l(&m_mx); return double(m_bytes) / (1024.0 * 1024.0); }
    int rev() const { return m_rev; }

    // Nearest cached PTS strictly before/after the given ms; -1 when none.
    Q_INVOKABLE double prevPts(double beforeMs) const;
    Q_INVOKABLE double nextPts(double afterMs) const;
    // Repaint the cached frame nearest ptsMs (within tolMs) onto the sink.
    // Returns the repainted PTS, or -1 if no frame qualified.
    Q_INVOKABLE double repaint(double ptsMs, double tolMs);

    // Cached PTS values around a center: up to `back` keys at/below centerMs
    // (nearest ones) and `fwd` keys above it, ascending. Feeds the filmstrip's
    // slot model.
    Q_INVOKABLE QVariantList cachedAround(double centerMs, int back, int fwd) const;

    // Decoded image for an exactly-cached PTS (±5 ms); null when absent.
    // Called from Quick's image-loader threads via FrameCacheImageProvider.
    QImage imageForPts(qint64 ptsMs) const;

signals:
    void changed();

private:
    void onFrame(const QVideoFrame &frame);
    void evictIfNeededLocked();

    QVideoSink *m_sink = nullptr;
    bool m_capturing = false;
    mutable QMutex m_mx;
    QMap<qint64, QByteArray> m_store;                 // ptsMs → JPEG
    qint64 m_bytes = 0;
    qint64 m_anchorPts = -1;                          // eviction reference (last insert/repaint)
    int m_rev = 0;
    static constexpr int kMaxFrames = 96;             // ~4.8 s @ 20 fps
    static constexpr qint64 kMaxBytes = 56LL * 1024 * 1024;
};

// image://fcache/<ptsMs>?r=<rev> — thumbnails for the frame-by-frame filmstrip,
// straight from the cache's JPEGs (the ?r= part is only a cache-buster).
class FrameCacheImageProvider : public QQuickImageProvider
{
public:
    explicit FrameCacheImageProvider(FrameCache *cache)
        : QQuickImageProvider(QQuickImageProvider::Image), m_cache(cache) {}
    QImage requestImage(const QString &id, QSize *size, const QSize &requested) override;

private:
    FrameCache *m_cache;
};
