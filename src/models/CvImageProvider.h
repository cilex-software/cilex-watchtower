#pragma once

#include <QQuickAsyncImageProvider>
#include <QQuickImageResponse>
#include <QQuickTextureFactory>
#include <QElapsedTimer>
#include <QImage>
#include <QPointer>
#include <QSize>
#include <QString>

class AuthController;
class QNetworkAccessManager;
class QNetworkReply;

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

private:
    void releaseSnapshotSlot();         // pass the governed-extractor slot to the next queued fetch
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
    bool m_gated = false;               // holds one of the 2 snapshot-extractor slots
    bool m_queued = false;              // waiting in the snapshot queue
    bool m_cancelled = false;
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
