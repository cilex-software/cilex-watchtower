#include "LiveProxy.h"

#include "AuthController.h"
#include "HlsProxy.h"

#include <QThread>
#include <QUrl>
#include <QUrlQuery>
#include <QRegularExpression>
#include <QTcpSocket>
#include <QTimer>

LiveProxy *LiveProxy::s_instance = nullptr;

LiveProxy::LiveProxy(QObject *parent)
    : QObject(parent)
{
    s_instance = this;
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
    // HLS, not fMP4: the only live-over-HTTP format every Qt media backend in the
    // fleet plays — macOS's AVFoundation backend cannot play a progressive fMP4 at
    // all (see HlsProxy::serveRequest), and HLS is also what Cilex Pro Mobile uses.
    return m_proxy->localBase() + QStringLiteral("/live/stream.m3u8?src=")
           + QString::fromUtf8(QUrl::toPercentEncoding(name));
}

QString LiveProxy::liveUrlForUpstream(const QString &hlsUrl) const
{
    if (hlsUrl.isEmpty() || m_proxy->port() == 0)
        return QString();
    const QUrl u(hlsUrl);
    if (!u.path().endsWith(QLatin1String("/streams/live/stream.m3u8")))
        return QString();
    const QString src = QUrlQuery(u).queryItemValue(QStringLiteral("src"));
    static const QRegularExpression ok(QStringLiteral("^[A-Za-z0-9_.-]{1,128}$"));
    if (!ok.match(src).hasMatch())
        return QString();
    return m_proxy->localBase() + QStringLiteral("/live/stream.m3u8?src=") + src;
}

void LiveProxy::setRtspProbe(int v)
{
    if (m_rtspProbe == v)
        return;
    m_rtspProbe = v;
    emit rtspProbeChanged();
}

void LiveProxy::probeRtspHost(const QString &rtspUrl)
{
    const QUrl u(rtspUrl);
    if (u.host().isEmpty())
        return;
    const int port = u.port(8554);
    const QString key = u.host() + QLatin1Char(':') + QString::number(port);
    if (m_probeInFlight || key == m_probedHostPort)
        return;                                  // answered, or answering
    m_probedHostPort = key;
    m_probeInFlight = true;
    setRtspProbe(-1);                            // unknown while we ask

    auto *sock = new QTcpSocket(this);
    auto *timer = new QTimer(this);
    timer->setSingleShot(true);
    auto finish = [this, sock, timer](int result) {
        if (!m_probeInFlight)
            return;
        m_probeInFlight = false;
        timer->stop();
        sock->abort();
        sock->deleteLater();
        timer->deleteLater();
        qInfo("[RTSP-PROBE] %s -> %s", qPrintable(m_probedHostPort),
              result == 1 ? "reachable" : "UNREACHABLE (live falls back to HTTP)");
        setRtspProbe(result);
    };
    connect(sock, &QTcpSocket::connected, this, [finish]() { finish(1); });
    connect(sock, &QTcpSocket::errorOccurred, this, [finish](QAbstractSocket::SocketError) { finish(0); });
    connect(timer, &QTimer::timeout, this, [finish]() { finish(0); });
    timer->start(3000);                          // a reachable port answers in ms; 3 s is generous
    sock->connectToHost(u.host(), quint16(port));
}
