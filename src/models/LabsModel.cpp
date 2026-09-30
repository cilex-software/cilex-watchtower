#include "LabsModel.h"
#include "AuthController.h"
#include "LabsStation.h"
#include "LabsStatsData.h"
#include "ServerMessage.h"

#include <QDateTime>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>

namespace {
// A slug is spliced into a request path that carries the operator's session. It comes
// from the server, but it is still checked to be exactly a slug and nothing else.
bool validSlug(const QString &s)
{
    static const QRegularExpression re(QStringLiteral("^[a-z0-9_]{1,64}$"));
    return re.match(s).hasMatch();
}
}   // namespace

LabsModel::LabsModel(QObject *parent)
    : QObject(parent)
{
    auto *auth = AuthController::instance();
    m_nam = auth->nam();
    m_baseUrl = auth->baseUrl();
    connect(auth, &AuthController::baseUrlChanged, this, [this, auth]() { m_baseUrl = auth->baseUrl(); });
    connect(auth, &AuthController::identityChanged, this, &LabsModel::changed);
    connect(auth, &AuthController::authenticatedChanged, this, [this, auth]() {
        if (!auth->authenticated()) {       // signed out: forget what the server said
            m_loaded = false;
            m_rows.clear();
            m_stats.clear();
            m_statsState.clear();
            m_statsError.clear();
            m_errorCode.clear();
            m_errorText.clear();
            m_lastAskMs = 0;
            recount();
            emit changed();
        } else if (m_refreshWanted) {
            // The screen asked before the saved session finished restoring (caught by a
            // WT_SECTION=labs boot screenshot that sat on "Asking the server…").
            refresh(true);
        }
    });
    refreshStation();
}

bool LabsModel::canEdit() const
{
    return AuthController::instance()->isAdmin();
}

void LabsModel::refresh(bool force)
{
    if (qEnvironmentVariableIsSet("WT_DEMO"))
        return;
    if (!AuthController::instance()->authenticated()) {
        m_refreshWanted = true;              // not signed in yet: ask once we are
        return;
    }
    if (m_loading)
        return;                              // ONE request at a time, never overlapping
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (!force && m_loaded && m_errorCode.isEmpty() && now - m_lastAskMs < kFloorMs)
        return;                              // see the class comment: this call is not cheap
    m_refreshWanted = false;
    m_lastAskMs = now;
    m_loading = true;
    emit changed();

    QNetworkReply *reply = m_nam->get(QNetworkRequest(QUrl(m_baseUrl + QStringLiteral("/labs/pipeline"))));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray body = reply->readAll();
        if (code == 401)
            AuthController::instance()->noteUnauthorized();
        if (code != 200)
            m_loading = false;
        if (code == 403) {
            fail(QStringLiteral("admin_only"), wt::serverMessage(body));
            return;
        }
        if (code != 200) {
            fail(code == 0 ? QStringLiteral("unreachable") : QStringLiteral("refused"),
                 code == 0 ? reply->errorString() : wt::serverMessage(body));
            return;
        }
        const QJsonObject o = QJsonDocument::fromJson(body).object();
        m_rows = wtlabs::mergePipeline(o);
        m_generatedAt = o.value(QStringLiteral("generated_at")).toString();
        m_errorCode.clear();
        m_errorText.clear();
        m_loaded = true;
        recount();
        emit changed();
        fetchStats(o);                       // still "loading": one request at a time
    });
}

// GET /labs/stats, right after the pipeline and only then: the same 30-minute floor, the
// same Refresh, never a second request in parallel. Switching the period on screen asks
// nothing: every window arrives in this one answer.
void LabsModel::fetchStats(const QJsonObject &pipeline)
{
    QNetworkReply *reply = m_nam->get(QNetworkRequest(QUrl(m_baseUrl + QStringLiteral("/labs/stats"))));
    connect(reply, &QNetworkReply::finished, this, [this, reply, pipeline]() {
        reply->deleteLater();
        m_loading = false;
        int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        QByteArray body = reply->readAll();
        if (code == 401)
            AuthController::instance()->noteUnauthorized();
        // WT_LABS_STATS_FILE=<json>, for REVIEW SCREENSHOTS only: the answer is read from that
        // file instead, to show a part of the view whose server half is not deployed yet (BY
        // CAMERA, 2026-09-30). Read-only, like WT_LABS_VIEW; unset, nothing changes.
        const QString reviewFile = qEnvironmentVariable("WT_LABS_STATS_FILE");
        if (!reviewFile.isEmpty()) {
            QFile f(reviewFile);
            if (f.open(QIODevice::ReadOnly)) {
                body = f.readAll();
                code = 200;
            }
        }
        const QVariantMap parsed = code == 200 ? wtlabs::parseStats(QJsonDocument::fromJson(body).object())
                                               : QVariantMap();
        if (code == 200 && !parsed.value(QStringLiteral("windows")).toMap().isEmpty()) {
            m_stats = parsed;
            m_statsState = QStringLiteral("server");
            m_statsError.clear();
        } else if (code == 404 || m_statsState != QStringLiteral("server")) {
            // No /labs/stats on this server (404), or it failed before it ever answered:
            // "all" from the pipeline just read, the periods waiting for the server.
            m_stats = wtlabs::statsFromPipeline(m_rows, pipeline, QDateTime::currentDateTimeUtc());
            m_statsState = QStringLiteral("pipeline");
            m_statsError = code == 404 ? QString()
                         : code == 200 ? tr("the server's statistics could not be read")
                         : code == 0 ? reply->errorString()
                                     : QStringLiteral("HTTP %1 %2").arg(code).arg(wt::serverMessage(body));
        } else {
            // It answered before and fails now: its last answer stays, with its time and
            // the reason (Stability beats flicker).
            m_statsError = code == 0 ? reply->errorString()
                                     : QStringLiteral("HTTP %1 %2").arg(code).arg(wt::serverMessage(body));
        }
        emit changed();
    });
}

QVariantList LabsModel::barWidths(const QVariantList &values, double width, double minPx) const
{
    return wtlabs::barWidthsVariant(values, width, minPx);
}

void LabsModel::recount()
{
    const wtlabs::Load l = wtlabs::projectedLoad(m_rows);
    m_enabledCount = l.enabled;
    m_projected = l.cpuHoursPerDay;
    m_projectedIsFloor = l.unmeasured;
}

void LabsModel::fail(const QString &code, const QString &text)
{
    // The rows are NOT cleared: the last answer stays on screen, with its time, under a
    // banner that says the server is not answering now (Stability beats flicker).
    m_errorCode = code;
    m_errorText = text;
    emit changed();
}

void LabsModel::setAnalyzerEnabled(const QString &slug, bool on)
{
    m_changeError.clear();
    if (!canEdit()) {
        // The server would refuse it anyway (require_role admin). Never a silent no-op.
        m_changeError = QStringLiteral("admin_only");
        emit changed();
        return;
    }
    if (!validSlug(slug) || !m_busySlug.isEmpty())
        return;
    m_busySlug = slug;
    emit changed();
    QNetworkRequest req(QUrl(m_baseUrl + QStringLiteral("/labs/analyzers/") + slug));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    const QByteArray body = QJsonDocument(QJsonObject{{QStringLiteral("enabled"), on}})
                                .toJson(QJsonDocument::Compact);
    QNetworkReply *reply = m_nam->sendCustomRequest(req, QByteArrayLiteral("PATCH"), body);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray b = reply->readAll();
        m_busySlug.clear();
        if (code == 401)
            AuthController::instance()->noteUnauthorized();
        if (code == 200) {
            // The server's own answer for that one analyser: the row shows what the
            // server now says, not what was asked, and nothing else is re-fetched.
            wtlabs::applyPatch(m_rows, QJsonDocument::fromJson(b).object());
            recount();
        } else if (code == 403) {
            m_changeError = QStringLiteral("admin_only");
        } else {
            m_changeError = code == 0 ? reply->errorString()
                                      : QStringLiteral("HTTP %1 %2").arg(code).arg(wt::serverMessage(b));
        }
        emit changed();
    });
}

void LabsModel::refreshStation()
{
    const QString dir = wtlabs::stateDir();
    const wtlabs::Control c = wtlabs::readControl(dir);
    const wtlabs::Station s = wtlabs::readStation(dir, QDateTime::currentDateTimeUtc());
    QVariantMap m;
    m[QStringLiteral("view")] = s.view;
    m[QStringLiteral("state")] = s.state;
    m[QStringLiteral("present")] = s.present;
    m[QStringLiteral("stale")] = s.stale;
    m[QStringLiteral("ageS")] = s.ageS;
    m[QStringLiteral("note")] = s.note;
    m[QStringLiteral("current")] = s.current;
    m[QStringLiteral("updatedAt")] = s.updatedAt;
    m[QStringLiteral("startedAt")] = s.startedAt;
    m[QStringLiteral("host")] = s.host;
    m[QStringLiteral("workerVersion")] = s.workerVersion;
    m[QStringLiteral("serverVersion")] = s.serverVersion;
    m[QStringLiteral("lastUnit")] = s.lastUnit;
    m[QStringLiteral("totals")] = s.totals;
    m[QStringLiteral("runs")] = s.runs;
    m[QStringLiteral("registered")] = s.registered;
    m[QStringLiteral("skipped")] = s.skipped;
    m[QStringLiteral("paused")] = c.paused;
    m[QStringLiteral("controlWhy")] = c.why;
    m[QStringLiteral("cameraHealth")] = c.cameraHealth;
    m[QStringLiteral("governed")] = s.governed && !s.stale;
    m[QStringLiteral("switchable")] = s.switchable;
    m[QStringLiteral("serverMode")] = s.serverMode;
    m[QStringLiteral("serverLevel")] = s.serverLevel;
    m[QStringLiteral("serverAt")] = s.serverAt;
    m[QStringLiteral("lanes")] = s.lanes;
    // The hold as the control file says NOW (the worker's copy can be a heartbeat old).
    m[QStringLiteral("hold")] = c.hold;
    m[QStringLiteral("dir")] = dir;
    if (m != m_station) {
        m_station = m;
        emit stationChanged();
    }
}

void LabsModel::setStationRunning(bool run)
{
    const bool governed = m_station.value(QStringLiteral("governed")).toBool();
    const QString host = m_station.value(QStringLiteral("host")).toString();
    if (!governed || host.isEmpty()) {
        setStationPaused(!run);          // no control plane yet: the local flag governs
        return;
    }
    if (m_stationBusy)
        return;                          // one change at a time, never overlapping
    m_stationBusy = true;
    m_stationError.clear();
    emit stationChanged();
    QNetworkRequest req(QUrl(m_baseUrl + QStringLiteral("/labs/control")));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    const QByteArray body = QJsonDocument(QJsonObject{
        {QStringLiteral("station"), host},
        {QStringLiteral("action"), run ? QStringLiteral("start") : QStringLiteral("pause")}}).toJson(QJsonDocument::Compact);
    QNetworkReply *reply = m_nam->post(req, body);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        m_stationBusy = false;
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray b = reply->readAll();
        if (code == 401)
            AuthController::instance()->noteUnauthorized();
        if (code == 200)
            m_stationError.clear();      // the worker hears it within a report (~2 s)
        else if (code == 403)
            m_stationError = tr("only an administrator can start or pause scanning");
        else
            m_stationError = code == 0 ? reply->errorString()
                                       : QStringLiteral("HTTP %1 %2").arg(code).arg(wt::serverMessage(b));
        refreshStation();
        emit stationChanged();
    });
}

void LabsModel::releaseHold()
{
    QString err;
    const QString who = AuthController::instance()->username();
    if (!wtlabs::clearHold(wtlabs::stateDir(),
                           QStringLiteral("watchtower app") + (who.isEmpty() ? QString() : QStringLiteral(" (%1)").arg(who)),
                           &err))
        m_stationError = err;
    else
        m_stationError.clear();
    refreshStation();
    emit stationChanged();
}

void LabsModel::setStationPaused(bool paused)
{
    QString err;
    const QString who = AuthController::instance()->username();
    if (!wtlabs::writeControl(wtlabs::stateDir(), paused,
                              QStringLiteral("watchtower app") + (who.isEmpty() ? QString() : QStringLiteral(" (%1)").arg(who)),
                              &err))
        m_stationError = err;
    else
        m_stationError.clear();
    refreshStation();
    emit stationChanged();
}
