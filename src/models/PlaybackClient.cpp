#include "PlaybackClient.h"
#include "HlsProxy.h"
#include "AuthController.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QTimer>
#include <QUrl>

PlaybackClient::PlaybackClient(QObject *parent)
    : QObject(parent)
{
    auto *auth = AuthController::instance();
    m_nam = auth->nam();                      // shared, session-authenticated jar
    m_baseUrl = auth->baseUrl();

    m_proxy = new HlsProxy(m_nam, this);      // shares the authenticated cookie jar
    m_proxy->setUpstream(m_baseUrl);
    m_proxy->start();

    connect(auth, &AuthController::baseUrlChanged, this, [this, auth]() {
        m_baseUrl = auth->baseUrl();
        m_proxy->setUpstream(m_baseUrl);
    });
    connect(auth, &AuthController::authenticatedChanged, this, [this, auth]() {
        if (!auth->authenticated()) {         // signed out — drop resolved state
            m_loggedIn = false;
            m_loggingIn = false;
            emit loggedInChanged();
        }
    });
}

void PlaybackClient::setStatus(const QString &s)
{
    if (m_status == s)
        return;
    m_status = s;
    emit statusChanged();
}

void PlaybackClient::ensureReady()
{
    if (m_loggedIn || m_loggingIn)
        return;
    if (!AuthController::instance()->authenticated()) {
        setStatus(QStringLiteral("Not signed in"));
        return;
    }
    m_loggingIn = true;
    setStatus(QStringLiteral("Connecting to cilex-vision…"));
    fetchStreams();
}

void PlaybackClient::fetchStreams()
{
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/streams")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        m_loggingIn = false;
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) {
            AuthController::instance()->noteUnauthorized();
            setStatus(QStringLiteral("Not signed in"));
            return;
        }
        const auto arr = QJsonDocument::fromJson(reply->readAll())
                             .object().value("streams").toArray();
        m_ipToCamId.clear();
        m_macToCamId.clear();
        for (const auto &v : arr) {
            const auto o = v.toObject();
            const QString id = o.value("camera_id").toString();
            m_ipToCamId.insert(o.value("ip").toString(), id);
            // camera_id is "<slug>-<machex>"; index by the trailing hex too.
            const int dash = id.lastIndexOf('-');
            if (dash > 0)
                m_macToCamId.insert(id.mid(dash + 1), id);
        }
        m_loggedIn = true;                   // signed in + streams resolved = ready
        emit loggedInChanged();
        setStatus(QString());
        emit camerasResolved();
        flushPendingSessions();
    });
}

QString PlaybackClient::cameraIdForIp(const QString &ip) const
{
    return m_ipToCamId.value(ip);
}

QString PlaybackClient::cameraIdForMac(const QString &mac) const
{
    QString hex = mac.toLower();
    hex.remove(':').remove('-');
    if (m_macToCamId.contains(hex))
        return m_macToCamId.value(hex);
    return hex.isEmpty() ? QString() : QStringLiteral("hiwatch-") + hex;
}

void PlaybackClient::openSession(const QString &cameraId, const QString &wallStartIso,
                                 const QString &wallEndIso, bool hevcCapable)
{
    if (cameraId.isEmpty()) {
        emit sessionFailed("This camera is not known to the recording backend.");
        return;
    }
    if (!m_loggedIn) {
        if (!AuthController::instance()->authenticated()) {
            emit sessionFailed(QStringLiteral("Not signed in to the recording backend."));
            return;
        }
        // queue: resolve streams, then retry once ready.
        ensureReady();
        connect(this, &PlaybackClient::camerasResolved, this,
                [this, cameraId, wallStartIso, wallEndIso, hevcCapable]() {
                    openSession(cameraId, wallStartIso, wallEndIso, hevcCapable);
                }, Qt::SingleShotConnection);
        return;
    }

    setStatus("Opening session…");
    QNetworkRequest req{QUrl(m_baseUrl + "/review/sessions")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonObject body{{"camera_id", cameraId},
                     {"wall_start", wallStartIso},
                     {"wall_end", wallEndIso},
                     {"hevc_capable", hevcCapable}};
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray raw = reply->readAll();
        if (code != 200) {
            QString detail = QJsonDocument::fromJson(raw).object().value("detail").toString();
            emit sessionFailed(detail.isEmpty() ? QStringLiteral("Session error (%1)").arg(code)
                                                : detail);
            setStatus(QString());
            return;
        }
        const auto obj = QJsonDocument::fromJson(raw).object();
        const QString sid = obj.value("session_id").toString();
        const auto man = obj.value("manifest").toObject();
        const auto fragsArr = man.value("fragments").toArray();
        QVariantList frags;
        double compactDuration = 0.0;
        for (const auto &fv : fragsArr) {
            const auto fo = fv.toObject();
            frags.append(fo.toVariantMap());
            if (fo.value("availability").toString() == "ready")
                compactDuration = qMax(compactDuration, fo.value("compact_end").toDouble());
        }
        QVariantMap meta;
        meta["wall_start"] = man.value("wall_start").toString();
        meta["wall_end"] = man.value("wall_end").toString();
        meta["clipped_to_finalized"] = man.value("clipped_to_finalized").toBool();
        meta["live_gap_s"] = man.value("live_gap_s").toDouble();
        meta["events"] = man.value("events").toArray().toVariantList();
        setStatus(QString());
        emit sessionReady(sid, compactDuration, frags, meta);
    });
}

void PlaybackClient::flushPendingSessions() { /* queued via SingleShotConnection */ }

QString PlaybackClient::playlistUrl(const QString &sessionId) const
{
    return m_proxy->localBase() + "/review/sessions/" + sessionId + "/playlist.m3u8";
}

void PlaybackClient::createExport(const QString &cameraId, const QString &wallStartIso,
                                  const QString &wallEndIso, const QString &mode)
{
    QNetworkRequest req{QUrl(m_baseUrl + "/review/exports")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonObject body{{"camera_id", cameraId}, {"wall_start", wallStartIso},
                     {"wall_end", wallEndIso}, {"mode", mode}};
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const QString jobId = obj.value("job_id").toString();
        if (jobId.isEmpty()) {
            emit exportFailed(QString(), "Export request rejected.");
            return;
        }
        emit exportStarted(jobId);
        QTimer::singleShot(1500, this, [this, jobId]() { pollExport(jobId); });
    });
}

void PlaybackClient::pollExport(const QString &jobId)
{
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/review/exports/" + jobId)});
    connect(reply, &QNetworkReply::finished, this, [this, reply, jobId]() {
        reply->deleteLater();
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const QString state = obj.value("state").toString();
        emit exportProgress(jobId, state);
        if (state == "ready") {
            QString dl = obj.value("download_url").toString();
            dl.replace("/api/review/", "/review/");      // route via the local proxy
            emit exportReady(jobId, m_proxy->localBase() + dl);
        } else if (state == "failed" || state == "error") {
            emit exportFailed(jobId, obj.value("error_msg").toString());
        } else {
            QTimer::singleShot(2000, this, [this, jobId]() { pollExport(jobId); });
        }
    });
}
