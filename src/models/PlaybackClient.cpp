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
#include <QUrlQuery>
#include <QFile>
#include <QTimeZone>

// The operator's IANA timezone (e.g. "Europe/Moscow"). The coverage calendar
// buckets footage days with date(start_time AT TIME ZONE tz) on the backend, so
// we must send the operator's local tz or day-dots bucket in UTC and land on the
// wrong calendar day near midnight (pilot is UTC+3 — a 3h skew). Everything else
// in the UI already renders in system-local time, so the system tz is the
// operator's tz; fall back to UTC if the zone has no IANA id.
static QString operatorTz()
{
    const QByteArray id = QTimeZone::systemTimeZone().id();
    return id.isEmpty() ? QStringLiteral("UTC") : QString::fromUtf8(id);
}

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

void PlaybackClient::fetchCoverage(const QString &cameraId)
{
    if (cameraId.isEmpty())
        return;
    if (!m_loggedIn) {
        if (!AuthController::instance()->authenticated())
            return;
        ensureReady();
        connect(this, &PlaybackClient::camerasResolved, this,
                [this, cameraId]() { fetchCoverage(cameraId); },
                Qt::SingleShotConnection);
        return;
    }
    QUrl url(m_baseUrl + "/review/coverage");
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("camera_id"), cameraId);
    q.addQueryItem(QStringLiteral("tz"), operatorTz());
    url.setQuery(q);
    QNetworkReply *reply = m_nam->get(QNetworkRequest{url});
    connect(reply, &QNetworkReply::finished, this, [this, reply, cameraId]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code != 200) {
            // Endpoint not shipped yet (404) or error: honest pending state.
            emit coverageReady(cameraId, false, 0, {});
            return;
        }
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const int retentionDays = obj.value("retention_days").toInt();
        QVariantList days;
        for (const auto &dv : obj.value("days").toArray())
            days.append(dv.toObject().toVariantMap());
        emit coverageReady(cameraId, true, retentionDays, days);
    });
}

void PlaybackClient::openMosaicSession(const QStringList &cameraIds, const QString &wallStartIso,
                                       const QString &wallEndIso, int cols, int rows)
{
    if (cameraIds.isEmpty()) {
        emit mosaicSessionFailed(QStringLiteral("No cameras selected for the wall."), false);
        return;
    }
    if (!m_loggedIn) {
        if (!AuthController::instance()->authenticated()) {
            emit mosaicSessionFailed(QStringLiteral("Not signed in to the recording backend."), false);
            return;
        }
        ensureReady();
        connect(this, &PlaybackClient::camerasResolved, this,
                [this, cameraIds, wallStartIso, wallEndIso, cols, rows]() {
                    openMosaicSession(cameraIds, wallStartIso, wallEndIso, cols, rows);
                }, Qt::SingleShotConnection);
        return;
    }
    setStatus(QStringLiteral("Opening wall session…"));
    QNetworkRequest req{QUrl(m_baseUrl + "/review/mosaic-sessions")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonArray ids;
    for (const QString &id : cameraIds) ids.append(id);
    QJsonObject body{{"camera_ids", ids}, {"wall_start", wallStartIso}, {"wall_end", wallEndIso}};
    if (cols > 0 && rows > 0)
        body.insert("layout", QJsonObject{{"cols", cols}, {"rows", rows}});
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray raw = reply->readAll();
        setStatus(QString());
        if (code != 200) {
            // 404 = the mosaic endpoint isn't deployed yet → honest "pending"
            // (not an error). Any other code is a real failure to surface.
            const bool pending = (code == 404);
            QString detail = QJsonDocument::fromJson(raw).object().value("detail").toString();
            emit mosaicSessionFailed(
                pending ? QStringLiteral("backend compositing pending")
                        : (detail.isEmpty() ? QStringLiteral("Wall session error (%1).").arg(code) : detail),
                pending);
            return;
        }
        const auto obj = QJsonDocument::fromJson(raw).object();
        const QString sid = obj.value("session_id").toString();
        const auto grid = obj.value("grid").toObject().toVariantMap();
        QVariantList cells;
        for (const auto &cv : obj.value("cells").toArray())
            cells.append(cv.toObject().toVariantMap());
        const auto man = obj.value("manifest").toObject();
        QVariantList frags;
        double compactDuration = 0.0;
        for (const auto &fv : man.value("fragments").toArray()) {
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
        emit mosaicSessionReady(sid, grid, cells, compactDuration, frags, meta);
    });
}

void PlaybackClient::fetchCoverageUnion(const QStringList &cameraIds)
{
    if (cameraIds.isEmpty())
        return;
    if (!m_loggedIn) {
        if (!AuthController::instance()->authenticated()) {
            emit coverageUnionReady(false, 0, {});
            return;
        }
        ensureReady();
        connect(this, &PlaybackClient::camerasResolved, this,
                [this, cameraIds]() { fetchCoverageUnion(cameraIds); }, Qt::SingleShotConnection);
        return;
    }
    QUrl url(m_baseUrl + "/review/coverage");
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("camera_ids"), cameraIds.join(','));
    q.addQueryItem(QStringLiteral("tz"), operatorTz());
    url.setQuery(q);
    QNetworkReply *reply = m_nam->get(QNetworkRequest{url});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code != 200) {
            emit coverageUnionReady(false, 0, {});   // endpoint not shipped → honest pending
            return;
        }
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const int retentionDays = obj.value("retention_days").toInt();
        QVariantList unionDays;
        for (const auto &dv : obj.value("union").toArray())
            unionDays.append(dv.toString());
        emit coverageUnionReady(true, retentionDays, unionDays);
    });
}

void PlaybackClient::flushPendingSessions() { /* queued via SingleShotConnection */ }

QString PlaybackClient::playlistUrl(const QString &sessionId) const
{
    return m_proxy->localBase() + "/review/sessions/" + sessionId + "/playlist.m3u8";
}

QString PlaybackClient::mosaicPlaylistUrl(const QString &sessionId) const
{
    return m_proxy->localBase() + "/review/mosaic-sessions/" + sessionId + "/playlist.m3u8";
}

void PlaybackClient::createExport(const QString &cameraId, const QString &wallStartIso,
                                  const QString &wallEndIso, const QString &mode,
                                  const QString &destPath, const QString &groupId,
                                  const QString &purpose)
{
    QNetworkRequest req{QUrl(m_baseUrl + "/review/exports")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonObject body{{"camera_id", cameraId}, {"wall_start", wallStartIso},
                     {"wall_end", wallEndIso}, {"mode", mode}};
    if (!groupId.isEmpty()) body.insert("group_id", groupId);
    if (!purpose.isEmpty()) body.insert("purpose", purpose);
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, destPath]() {
        reply->deleteLater();
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const QString jobId = obj.value("job_id").toString();
        if (jobId.isEmpty()) {
            emit exportFailed(QString(), "Export request rejected.");
            return;
        }
        m_exportDest.insert(jobId, destPath);
        emit exportStarted(jobId);
        QTimer::singleShot(1500, this, [this, jobId]() { pollExport(jobId); });
    });
}

void PlaybackClient::createMosaicExport(const QString &sessionId, const QString &wallStartIso,
                                        const QString &wallEndIso, const QString &mode,
                                        const QString &destPath, const QString &groupId,
                                        const QString &purpose)
{
    QNetworkRequest req{QUrl(m_baseUrl + "/review/mosaic-sessions/" + sessionId + "/exports")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonObject body{{"wall_start", wallStartIso}, {"wall_end", wallEndIso}, {"mode", mode}};
    if (!groupId.isEmpty()) body.insert("group_id", groupId);
    if (!purpose.isEmpty()) body.insert("purpose", purpose);
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, destPath]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code != 200) {
            emit exportFailed(QString(), code == 404
                ? QStringLiteral("Combined-grid export isn't available yet (backend E2 pending).")
                : QStringLiteral("Combined-grid export rejected (%1).").arg(code));
            return;
        }
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const QString jobId = obj.value("job_id").toString();
        if (jobId.isEmpty()) { emit exportFailed(QString(), "Combined-grid export rejected."); return; }
        m_exportDest.insert(jobId, destPath);
        emit exportStarted(jobId);
        QTimer::singleShot(1500, this, [this, jobId]() { pollExport(jobId); });
    });
}

void PlaybackClient::fetchExports()
{
    if (!m_loggedIn) {
        if (!AuthController::instance()->authenticated()) { emit exportsListReady({}); return; }
        ensureReady();
        connect(this, &PlaybackClient::camerasResolved, this,
                [this]() { fetchExports(); }, Qt::SingleShotConnection);
        return;
    }
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/review/exports?limit=200")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code != 200) { emit exportsListReady({}); return; }   // endpoint absent / error → empty (honest)
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        QVariantList out;
        for (const auto &v : obj.value("exports").toArray()) {
            QVariantMap m = v.toObject().toVariantMap();
            // Route the token download through the local proxy (same as pollExport's
            // download), so "Open" works with the session.
            QString dl = m.value("download_url").toString();
            if (!dl.isEmpty()) {
                dl.replace("/api/review/", "/review/");
                m["downloadUrl"] = m_proxy->localBase() + dl;
            } else {
                m["downloadUrl"] = QString();
            }
            out.append(m);
        }
        emit exportsListReady(out);
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
            downloadExport(jobId, m_proxy->localBase() + dl, m_exportDest.value(jobId));
        } else if (state == "failed" || state == "error") {
            emit exportFailed(jobId, obj.value("error_msg").toString());
        } else {
            QTimer::singleShot(2000, this, [this, jobId]() { pollExport(jobId); });
        }
    });
}

void PlaybackClient::downloadExport(const QString &jobId, const QString &url,
                                    const QString &destPath)
{
    if (destPath.isEmpty()) {
        emit exportFailed(jobId, "No export destination set.");
        return;
    }
    auto *file = new QFile(destPath);
    if (!file->open(QIODevice::WriteOnly)) {
        file->deleteLater();
        emit exportFailed(jobId, "Cannot write to " + destPath);
        return;
    }
    QNetworkRequest req{QUrl(url)};
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    QNetworkReply *reply = m_nam->get(req);
    // Stream chunks straight to disk so a large clip never sits in memory.
    connect(reply, &QNetworkReply::readyRead, file, [reply, file]() { file->write(reply->readAll()); });
    connect(reply, &QNetworkReply::finished, this, [this, reply, file, jobId, destPath]() {
        reply->deleteLater();
        file->write(reply->readAll());
        file->flush();
        const qint64 sz = file->size();
        file->close();
        file->deleteLater();
        m_exportDest.remove(jobId);
        if (reply->error() == QNetworkReply::NoError && sz > 0) {
            emit exportSaved(jobId, destPath);
        } else {
            QFile::remove(destPath);   // don't leave a partial/empty file behind
            emit exportFailed(jobId, reply->error() == QNetworkReply::NoError
                                         ? QStringLiteral("Downloaded clip was empty.")
                                         : reply->errorString());
        }
    });
}
