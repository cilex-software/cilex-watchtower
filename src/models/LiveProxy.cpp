#include "LiveProxy.h"

#include "AuthController.h"
#include "HlsProxy.h"

#include <QThread>
#include <QUrl>

LiveProxy::LiveProxy(QObject *parent)
    : QObject(parent)
{
    auto *auth = AuthController::instance();
    m_thread = new QThread(this);
    m_thread->setObjectName(QStringLiteral("live-proxy"));
    m_proxy = new HlsProxy;                    // no parent — lives on m_thread
    m_proxy->moveToThread(m_thread);
    connect(m_thread, &QThread::finished, m_proxy, &QObject::deleteLater);
    m_thread->start();
    QMetaObject::invokeMethod(m_proxy, "init", Qt::BlockingQueuedConnection);
    // Same wiring as PlaybackClient's proxy: follow the session's base URL and
    // token, including in-place refreshes (tokenChanged) — a stale cookie here
    // is a wall of 401s that looks like a video bug.
    auto resync = [this, auth]() {
        QMetaObject::invokeMethod(m_proxy, "setUpstream", Qt::QueuedConnection,
                                  Q_ARG(QString, auth->baseUrl()));
        QMetaObject::invokeMethod(m_proxy, "setAuthToken", Qt::QueuedConnection,
                                  Q_ARG(QString, auth->token()));
    };
    resync();
    connect(auth, &AuthController::baseUrlChanged, this, resync);
    connect(auth, &AuthController::tokenChanged, this, resync);
    connect(auth, &AuthController::authenticatedChanged, this, resync);
    qInfo("[LIVE-PROXY] listening on %s", qPrintable(m_proxy->localBase()));
}

LiveProxy::~LiveProxy()
{
    m_thread->quit();
    m_thread->wait(2000);
}

QString LiveProxy::liveUrlFor(const QString &rtspUrl) const
{
    if (rtspUrl.isEmpty() || m_proxy->port() == 0)
        return QString();
    const QString name = QUrl(rtspUrl).path().section(QLatin1Char('/'), -1);
    if (name.isEmpty())
        return QString();
    return m_proxy->localBase() + QStringLiteral("/live/stream.mp4?src=")
           + QString::fromUtf8(QUrl::toPercentEncoding(name));
}
