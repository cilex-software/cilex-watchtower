#pragma once

#include <QQuickAsyncImageProvider>
#include <QQuickImageResponse>
#include <QQuickTextureFactory>
#include <QImage>
#include <QPointer>
#include <QString>

class AuthController;
class QNetworkReply;

// Async image provider for AUTHENTICATED backend images. Qt's Image loader can't
// attach the session cookie, so this fetches via the shared AuthController NAM.
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
    CvImageResponse(AuthController *auth, const QString &path)
        : m_auth(auth), m_path(path) {}
    ~CvImageResponse() override;

    QQuickTextureFactory *textureFactory() const override
    { return QQuickTextureFactory::textureFactoryForImage(m_image); }
    QString errorString() const override { return m_error; }
    void cancel() override;

public slots:
    void start();                       // runs on the GUI thread (NAM's thread)

private:
    AuthController *m_auth = nullptr;
    QString m_path;
    QString m_error;
    QImage m_image;
    QPointer<QNetworkReply> m_reply;
};

class CvImageProvider : public QQuickAsyncImageProvider
{
public:
    explicit CvImageProvider(AuthController *auth) : m_auth(auth) {}
    QQuickImageResponse *requestImageResponse(const QString &id, const QSize &requestedSize) override;

private:
    AuthController *m_auth;
};
