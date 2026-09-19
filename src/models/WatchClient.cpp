#include "WatchClient.h"
#include "ServerMessage.h"
#include "StationNam.h"
#include "AuthController.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSysInfo>
#include <QTimer>

WatchClient::WatchClient(QObject *parent) : QObject(parent)
{
    // PRIVATE pool: the boot storm (roster + events + coverage on the shared
    // NAM) queued our first requests past their transfer timeout — same
    // starvation CvImageProvider solved in July. The Watch's traffic is a
    // handful of requests an hour; auth rides the per-request Cookie header.
    m_nam = new StationNam(this);
    // Keep the chip truthful across handovers/auto-close without a click:
    // a slow poll is plenty (the chip is the only writer on this station).
    auto *t = new QTimer(this);
    t->setInterval(5 * 60 * 1000);
    connect(t, &QTimer::timeout, this, [this]() { if (m_available) refreshWatch(); });
    t->start();
    connect(AuthController::instance(), &AuthController::authenticatedChanged,
            this, [this]() { if (AuthController::instance()->authenticated()) start(); });
}

static QNetworkRequest req(const QString &path, int timeoutMs = 8000)
{
    QNetworkRequest r{QUrl(AuthController::instance()->baseUrl() + path)};
    r.setRawHeader("Cookie", "access_token=" + AuthController::instance()->token().toUtf8());
    r.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    r.setTransferTimeout(timeoutMs);
    return r;
}

void WatchClient::start()
{
    if (!AuthController::instance()->authenticated())
        return;
    resolveStation();
}

void WatchClient::resolveStation()
{
    QNetworkReply *reply = m_nam->get(req(QStringLiteral("/client/stations")));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) {
            // A dead session is not a transient — retrying it with backoff just
            // hides the chip for longer (measured after CV's 2026-09-03 key
            // rotation: The Watch went quiet with no 401 path at all). Hand it
            // to the auth controller, which re-logs-in once and fires
            // authenticatedChanged, on which start() re-runs.
            qInfo("[WATCH] 401 on station registry — requesting re-auth");
            AuthController::instance()->noteUnauthorized();
            return;
        }
        if (code != 200) {
            // Boot saturates the shared NAM's 6-per-host pool and the transfer
            // timeout counts queue time — transient, so retry with backoff
            // before concluding anything about the backend.
            if (++m_resolveTries < 4) {
                qInfo("[WATCH] station registry HTTP %d (%s) — retry %d/3 in %ds",
                      code, qPrintable(reply->errorString()), m_resolveTries, 5 * m_resolveTries);
                QTimer::singleShot(5000 * m_resolveTries, this, &WatchClient::resolveStation);
            } else {
                qInfo("[WATCH] station registry unreachable after retries — chip hidden");
            }
            return;
        }
        const QString host = QSysInfo::machineHostName();
        const auto arr = QJsonDocument::fromJson(reply->readAll())
                             .object().value(QStringLiteral("stations")).toArray();
        for (const auto &v : arr) {
            const QJsonObject o = v.toObject();
            if (o.value(QStringLiteral("host")).toString() == host) {
                m_stationId = o.value(QStringLiteral("station_id")).toString();
                break;
            }
        }
        if (m_stationId.isEmpty()) {
            qInfo("[WATCH] no station row matches host '%s' — check-in hidden",
                  qPrintable(host));
            return;
        }
        qInfo("[WATCH] station resolved: %s", qPrintable(m_stationId));
        probeGuards();
    });
}

void WatchClient::probeGuards()
{
    QNetworkReply *reply = m_nam->get(req(QStringLiteral("/guards")));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 200) {
            m_available = true;
            m_roster.clear();
            for (const auto &v : QJsonDocument::fromJson(reply->readAll()).array()) {
                const QJsonObject o = v.toObject();
                if (o.value(QStringLiteral("active")).toBool(true))
                    m_roster.append(o.toVariantMap());
            }
            qInfo("[WATCH] available; roster=%lld", (long long)m_roster.size());
            emit rosterChanged();
            emit stateChanged();
            refreshWatch();
        } else if (code == 404 || code == 405 || code == 501) {
            qInfo("[WATCH] backend predates The Watch (HTTP %d) — hidden", code);
        }
        m_probed = true;
    });
}

void WatchClient::fetchGuards()
{
    if (m_available) probeGuards();              // same call refreshes the roster
}

void WatchClient::refreshWatch()
{
    if (m_stationId.isEmpty()) return;
    QNetworkReply *reply = m_nam->get(req("/stations/" + m_stationId + "/watch"));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200)
            return;
        const QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
        m_guardId = o.value(QStringLiteral("guard_id")).toString();
        m_guardName = o.value(QStringLiteral("display_name")).toString();
        m_shiftId = o.value(QStringLiteral("shift_id")).toString();
        m_startedAt = o.value(QStringLiteral("started_at")).toString();
        emit stateChanged();
        if (!m_guardId.isEmpty())
            fetchWatchstate();
        else {
            m_watchstate.clear();
            emit watchstateChanged();
        }
    });
}

void WatchClient::fetchWatchstate()
{
    if (m_guardId.isEmpty()) return;
    QNetworkReply *reply = m_nam->get(req("/guards/" + m_guardId + "/watchstate"));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200)
            return;
        const QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
        m_watchstate = o.toVariantMap();
        emit watchstateChanged();
        // Unlock toasts fire ONLY from unlocked_since — closed-shift truth by
        // contract; a running shift is a projection and never celebrates.
        for (const auto &v : o.value(QStringLiteral("unlocked_since")).toArray()) {
            const QJsonObject u = v.toObject();
            emit unlocked(u.value(QStringLiteral("family")).toString(),
                          u.value(QStringLiteral("tier")).toString());
        }
    });
}

void WatchClient::checkin(const QString &guardId)
{
    if (m_stationId.isEmpty() || guardId.isEmpty()) return;
    const QByteArray body =
        QJsonDocument(QJsonObject{{QStringLiteral("station_id"), m_stationId}})
            .toJson(QJsonDocument::Compact);
    // Measured 2026-08-04: the pilot's checkin took 22.1 s server-side (flagged
    // to CV). Tolerate slow writes, and reconcile afterwards either way — a
    // request that dies on the wire may still have committed server-side.
    QNetworkReply *reply = m_nam->post(req("/guards/" + guardId + "/checkin", 35000), body);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
        if (code == 200) {
            qInfo("[WATCH] checkin ok shift=%s resumed=%s",
                  qPrintable(o.value(QStringLiteral("shift_id")).toString()),
                  o.value(QStringLiteral("resumed")).toBool() ? "true" : "false");
            refreshWatch();
        } else {
            QString why = wt::serverMessage(o);      // `message ?? detail` (ServerMessage.h)
            if (why.isEmpty())
                why = QStringLiteral("HTTP %1").arg(code);
            qWarning("[WATCH] checkin FAILED: %s", qPrintable(why));
            emit opFailed(why);
            QTimer::singleShot(5000, this, &WatchClient::refreshWatch);   // reconcile late commits
        }
    });
}

void WatchClient::checkout()
{
    if (m_guardId.isEmpty()) return;
    QNetworkReply *reply = m_nam->post(req("/guards/" + m_guardId + "/checkout", 35000),
                                       QByteArrayLiteral("{}"));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 200) {
            qInfo("[WATCH] checkout ok");
            refreshWatch();
        } else {
            const QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
            QString why = wt::serverMessage(o);      // `message ?? detail` (ServerMessage.h)
            if (why.isEmpty())
                why = QStringLiteral("HTTP %1").arg(code);
            qWarning("[WATCH] checkout FAILED: %s", qPrintable(why));
            emit opFailed(why);
            QTimer::singleShot(5000, this, &WatchClient::refreshWatch);   // reconcile late commits
        }
    });
}
