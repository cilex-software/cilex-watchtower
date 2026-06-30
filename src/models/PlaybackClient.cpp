#include "PlaybackClient.h"
#include "HlsProxy.h"
#include <QThread>
#include "AuthController.h"
#include "ClipTranscoder.h"

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

    // The HLS proxy runs on its OWN thread so it keeps serving the player's segment reads even while the GUI
    // thread is blocked — e.g. inside QMediaPlayer teardown on the wall↔Live transition, where a GUI-thread
    // proxy deadlocked (stop() waits for the demuxer, the demuxer waits for a segment, the proxy can't serve
    // it). It has its own NAM, so we hand it the upstream URL + the session token over queued calls.
    m_proxyThread = new QThread(this);
    m_proxyThread->setObjectName(QStringLiteral("hls-proxy"));
    m_proxy = new HlsProxy;                   // no parent — lives on m_proxyThread
    m_proxy->moveToThread(m_proxyThread);
    connect(m_proxyThread, &QThread::finished, m_proxy, &QObject::deleteLater);
    m_proxyThread->start();
    QMetaObject::invokeMethod(m_proxy, "init", Qt::BlockingQueuedConnection);   // NAM + listen, on the proxy thread
    QMetaObject::invokeMethod(m_proxy, "setUpstream", Qt::QueuedConnection, Q_ARG(QString, m_baseUrl));
    QMetaObject::invokeMethod(m_proxy, "setAuthToken", Qt::QueuedConnection, Q_ARG(QString, auth->token()));

    connect(auth, &AuthController::baseUrlChanged, this, [this, auth]() {
        m_baseUrl = auth->baseUrl();
        QMetaObject::invokeMethod(m_proxy, "setUpstream", Qt::QueuedConnection, Q_ARG(QString, m_baseUrl));
        QMetaObject::invokeMethod(m_proxy, "setAuthToken", Qt::QueuedConnection, Q_ARG(QString, auth->token()));
    });
    connect(auth, &AuthController::authenticatedChanged, this, [this, auth]() {
        if (auth->authenticated()) {          // (re)login — refresh the proxy's cookie
            QMetaObject::invokeMethod(m_proxy, "setAuthToken", Qt::QueuedConnection, Q_ARG(QString, auth->token()));
        } else {                              // signed out — drop resolved state
            m_loggedIn = false;
            m_loggingIn = false;
            emit loggedInChanged();
        }
    });
}

PlaybackClient::~PlaybackClient()
{
    if (m_proxyThread) {
        m_proxyThread->quit();
        m_proxyThread->wait(3000);            // m_proxy is deleteLater'd on the thread's finished signal
    }
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

    requestSession(cameraId, wallStartIso, wallEndIso, hevcCapable, 0);
}

void PlaybackClient::requestSession(const QString &cameraId, const QString &wallStartIso,
                                    const QString &wallEndIso, bool hevcCapable, int attempt)
{
    setStatus(attempt == 0 ? QStringLiteral("Opening session…") : QStringLiteral("Reconnecting…"));
    QNetworkRequest req{QUrl(m_baseUrl + "/review/sessions")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonObject body{{"camera_id", cameraId},
                     {"wall_start", wallStartIso},
                     {"wall_end", wallEndIso},
                     {"hevc_capable", hevcCapable}};
    // Ask 1 (Cilex Vision route B): request the continuous-timeline manifest so mid-session seeks land
    // without a re-open. Validated (Qt harness: direct seeks land 81% on continuous vs 0% on legacy), so the
    // client now defaults to "continuous"; WT_SEEK_MODE=legacy forces the old per-fragment-discontinuity path.
    QString seekMode = qEnvironmentVariable("WT_SEEK_MODE");
    if (seekMode.isEmpty()) seekMode = QStringLiteral("continuous");
    body["seek_mode"] = seekMode;
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, cameraId, wallStartIso, wallEndIso, hevcCapable, attempt]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray raw = reply->readAll();
        if (code != 200) {
            // code 0 = no HTTP response (transport failure: timeout / unreachable /
            // reset). Usually transient — retry a couple of times with a short
            // backoff before surfacing the failure (a plain HTTP POST, no pipeline
            // teardown involved, so retrying here is safe).
            if (code == 0 && attempt < 2) {
                QTimer::singleShot(500, this, [this, cameraId, wallStartIso, wallEndIso, hevcCapable, attempt]() {
                    requestSession(cameraId, wallStartIso, wallEndIso, hevcCapable, attempt + 1);
                });
                return;
            }
            const QString detail = QJsonDocument::fromJson(raw).object().value("detail").toString();
            const QString msg = !detail.isEmpty() ? detail
                        : code == 0 ? QStringLiteral("Couldn't reach the recording backend (%1).").arg(reply->errorString())
                        : QStringLiteral("Session error (%1).").arg(code);
            emit sessionFailed(msg);
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
        meta["seek_mode"] = man.value("seek_mode").toString();   // "continuous" ⇒ client may seek directly within a run
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
                                       const QString &wallEndIso, int cols, int rows,
                                       const QString &replaces, int prewarmAt)
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
                [this, cameraIds, wallStartIso, wallEndIso, cols, rows, replaces, prewarmAt]() {
                    openMosaicSession(cameraIds, wallStartIso, wallEndIso, cols, rows, replaces, prewarmAt);
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
    if (!replaces.isEmpty())                 // B2a: reap the prior session on open
        body.insert("replaces", replaces);
    if (prewarmAt >= 0)                       // B3: warm around this fragment on create
        body.insert("prewarm_at", prewarmAt);
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

void PlaybackClient::disposeMosaicSession(const QString &sessionId)
{
    if (sessionId.isEmpty() || !m_loggedIn)
        return;
    QNetworkRequest req{QUrl(m_baseUrl + "/review/mosaic-sessions/" + sessionId)};
    QNetworkReply *reply = m_nam->deleteResource(req);
    connect(reply, &QNetworkReply::finished, reply, &QNetworkReply::deleteLater);   // fire-and-forget
}

void PlaybackClient::prewarmMosaic(const QString &sessionId, int atFrag, int ahead)
{
    if (sessionId.isEmpty() || atFrag < 0 || !m_loggedIn)
        return;
    QNetworkRequest req{QUrl(m_baseUrl + "/review/mosaic-sessions/" + sessionId + "/prewarm")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonObject body{{"at_frag", atFrag}};
    if (ahead > 0)
        body.insert("ahead", ahead);
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, reply, &QNetworkReply::deleteLater);   // fire-and-forget (202)
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

void PlaybackClient::fetchTimeline(const QString &cameraId, const QString &startIso,
                                   const QString &endIso, int buckets)
{
    if (cameraId.isEmpty() || startIso.isEmpty() || endIso.isEmpty())
        return;
    if (!m_loggedIn) {
        if (!AuthController::instance()->authenticated())
            return;
        ensureReady();
        connect(this, &PlaybackClient::camerasResolved, this,
                [this, cameraId, startIso, endIso, buckets]() {
                    fetchTimeline(cameraId, startIso, endIso, buckets);
                }, Qt::SingleShotConnection);
        return;
    }
    QUrl url(m_baseUrl + "/events/timeline");
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("start"), startIso);
    q.addQueryItem(QStringLiteral("end"), endIso);
    q.addQueryItem(QStringLiteral("camera_ids"), cameraId);
    if (buckets > 0)
        q.addQueryItem(QStringLiteral("buckets"), QString::number(buckets));
    url.setQuery(q);
    QNetworkReply *reply = m_nam->get(QNetworkRequest{url});
    connect(reply, &QNetworkReply::finished, this, [this, reply, cameraId]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401)
            AuthController::instance()->noteUnauthorized();
        if (code != 200) {
            emit timelineReady(cameraId, QStringLiteral("error"), {});
            return;
        }
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const QString mode = obj.value("mode").toString();
        QVariantList blocks;
        for (const auto &bv : obj.value("cameras").toObject().value(cameraId).toArray())
            blocks.append(bv.toObject().toVariantMap());
        emit timelineReady(cameraId, mode, blocks);
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
                                  const QString &purpose, bool hevcCapable,
                                  const QVariantMap &post)
{
    m_lastExport = { cameraId, wallStartIso, wallEndIso, mode, destPath, groupId, purpose, post, true };
    QNetworkRequest req{QUrl(m_baseUrl + "/review/exports")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonObject body{{"camera_id", cameraId}, {"wall_start", wallStartIso},
                     {"wall_end", wallEndIso}, {"mode", mode}, {"hevc_capable", hevcCapable}};
    if (!groupId.isEmpty()) body.insert("group_id", groupId);
    if (!purpose.isEmpty()) body.insert("purpose", purpose);
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, destPath, post]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        // 422 = High requested over a span that has aged to the standard sub (the
        // grey-out/confirm race). Surface the backend's explanation; the operator
        // can re-export at Standard quality.
        if (code == 422) {
            const QString detail = obj.value("detail").toString();
            emit exportFailed(QString(), detail.isEmpty()
                ? QStringLiteral("High-quality export needs the high-res original, which has aged to standard storage for part of this selection. Export at Standard quality instead.")
                : detail);
            return;
        }
        const QString jobId = obj.value("job_id").toString();
        if (jobId.isEmpty()) {
            emit exportFailed(QString(), "Export request rejected.");
            return;
        }
        m_exportDest.insert(jobId, destPath);
        if (!post.isEmpty()) m_exportPost.insert(jobId, post);   // client compression/overlays
        emit exportStarted(jobId);
        QTimer::singleShot(1500, this, [this, jobId]() { pollExport(jobId); });
    });
}

void PlaybackClient::retryLastExportAsHigh()
{
    if (!m_lastExport.valid)
        return;
    const LastExport e = m_lastExport;   // copy — createExport overwrites m_lastExport
    createExport(e.cameraId, e.wallStart, e.wallEnd, e.mode, e.destPath, e.groupId, e.purpose,
                 /*hevcCapable=*/true, e.post);
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
            // Client-side post-processing (compression ladder / overlay burn-in): the
            // downloaded clip becomes the transcode source; the final lands back at
            // destPath. cilex-vision's export is clean footage (no overlays) — exactly
            // the source we want.
            if (m_exportPost.contains(jobId)) {
                const QVariantMap post = m_exportPost.take(jobId);
                const QString srcTmp = destPath + QStringLiteral(".src.mp4");
                QFile::remove(srcTmp);
                if (QFile::rename(destPath, srcTmp)) {
                    emit exportProgress(jobId, QStringLiteral("compressing"));
                    runPostProcess(jobId, srcTmp, destPath, post);
                    return;
                }
                // couldn't stage the source → fall through, deliver the original as-is
            }
            emit exportSaved(jobId, destPath);
        } else {
            QFile::remove(destPath);   // don't leave a partial/empty file behind
            emit exportFailed(jobId, reply->error() == QNetworkReply::NoError
                                         ? QStringLiteral("Downloaded clip was empty.")
                                         : reply->errorString());
        }
    });
}

void PlaybackClient::runPostProcess(const QString &jobId, const QString &srcPath,
                                    const QString &dstPath, const QVariantMap &post)
{
    auto *tc = new ClipTranscoder(this);
    connect(tc, &ClipTranscoder::progress, this, [this, jobId](int pct) {
        emit exportProgress(jobId, QStringLiteral("compressing %1%").arg(pct));
    });
    connect(tc, &ClipTranscoder::finished, this, [this, jobId, srcPath, tc](const QString &out) {
        QFile::remove(srcPath);
        tc->deleteLater();
        emit exportSaved(jobId, out);
    });
    connect(tc, &ClipTranscoder::failed, this, [this, jobId, srcPath, dstPath, tc](const QString &err) {
        // Keep the operator's footage: restore the un-transcoded original at dstPath,
        // and report the compression failure honestly.
        QFile::remove(dstPath);
        QFile::rename(srcPath, dstPath);
        tc->deleteLater();
        emit exportFailed(jobId, QStringLiteral("Couldn't compress the clip (%1) — kept the original-quality export.").arg(err));
    });
    tc->start(srcPath, dstPath, post.value(QStringLiteral("height")).toInt(),
              post.value(QStringLiteral("name")).toBool(),
              post.value(QStringLiteral("timestamp")).toBool(),
              post.value(QStringLiteral("label")).toString(),
              post.value(QStringLiteral("startEpochMs")).toLongLong(),
              post.value(QStringLiteral("durationMs")).toLongLong());
}
