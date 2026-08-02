#pragma once

#include <QQuickAsyncImageProvider>
#include <QQuickImageResponse>
#include <QQuickTextureFactory>
#include <QElapsedTimer>
#include <QImage>
#include <QPointer>
#include <QSize>
#include <QString>

#include <atomic>

class AuthController;
class QNetworkAccessManager;
class QNetworkReply;
struct SnapPool;                        // per-class client snapshot gate (CvImageProvider.cpp)

// Async image provider for AUTHENTICATED backend images. Qt's Image loader can't
// attach the session cookie, so this fetches with the cookie attached explicitly —
// on the provider's PRIVATE QNetworkAccessManager (own 6-connection pool):
// thumbnail bursts are the app's bulk HTTP traffic and on the shared AuthController
// NAM they starved the control plane (playback session POSTs, events list queries)
// behind Qt's 6-connections-per-host cap. See docs/perf/2026-07-02-playback-ttff-fix.md
// and …-events-nam-split.md.
// Usage from QML:  image://cvframe/events/<id>/snapshot  →  GET <baseUrl>/events/<id>/snapshot
// The `id` is the backend path (everything after the provider scheme).
//
// The QML pixmap loader calls requestImageResponse() on its own worker thread, so
// the response is moved to the GUI thread (where the NAM lives) and the whole
// network exchange runs there; the engine reads textureFactory() after finished()
// (a queued hand-off), so the QImage is safely published across threads.
class CvImageResponse : public QQuickImageResponse
{
    Q_OBJECT
public:
    CvImageResponse(AuthController *auth, QNetworkAccessManager *nam,
                    const QString &path, const QSize &reqSize)
        : m_auth(auth), m_nam(nam), m_path(path), m_reqSize(reqSize) {}
    ~CvImageResponse() override;

    QQuickTextureFactory *textureFactory() const override
    { return QQuickTextureFactory::textureFactoryForImage(m_image); }
    QString errorString() const override { return m_error; }
    void cancel() override;

public slots:
    void start();                       // runs on the GUI thread (NAM's thread)
    void cancelOnOwnThread();           // cancel(), hopped off the pixmap-reader thread

private:
    void releaseSnapshotSlot();         // pass the governed-extractor slot to the next queued fetch
    // EXACTLY-ONCE finished(). Qt deletes the response as soon as finished() reaches
    // the reader thread (`response->deleteLater()`, qquickpixmapcache.cpp:766, run
    // unconditionally — even for a job it has already cancelled). A SECOND emission is
    // therefore delivered to a sender Qt has already deleted, and that handler
    // dereferences it → the 2026-07-25 P0 SIGSEGV (reader thread, QObject::deleteLater,
    // 9.5 h uptime). Every exit path in this class goes through finish().
    void finish();
    friend class CvImageProvider;
    AuthController *m_auth = nullptr;
    QNetworkAccessManager *m_nam = nullptr;   // the provider's private NAM (GUI-thread affine)
    QString m_path;
    QString m_error;
    QImage m_image;
    QSize m_reqSize;                    // QML sourceSize → decode/cache at display size, not full sensor res
    QPointer<QNetworkReply> m_reply;
    QElapsedTimer m_timer;              // per-attempt fetch latency ([EVIMG] diagnostics)
    int m_attempt = 0;                  // 503 (governor shed) retries — honors Retry-After
    SnapPool *m_pool = nullptr;         // which client gate this /snapshot request belongs to
    bool m_gated = false;               // holds one of its pool's slots
    bool m_queued = false;              // waiting in its pool's queue
    bool m_finished = false;            // GUI thread only — finish() is never called elsewhere
    // Written by cancel() on the PIXMAP-READER thread, read on the GUI thread.
    std::atomic<bool> m_cancelled { false };
};

class CvImageProvider : public QQuickAsyncImageProvider
{
public:
    explicit CvImageProvider(AuthController *auth);
    ~CvImageProvider() override;
    QQuickImageResponse *requestImageResponse(const QString &id, const QSize &requestedSize) override;

private:
    AuthController *m_auth;
    QNetworkAccessManager *m_nam;       // private pool — see the class note above
};
