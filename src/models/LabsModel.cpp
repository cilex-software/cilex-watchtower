#include "LabsModel.h"
#include "AuthController.h"
#include "LabsStation.h"
#include "ServerMessage.h"

#include <QDateTime>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QUrlQuery>

namespace {
// cilex-vision's registered vocabulary (migration 0083), used ONLY to find one analyser
// that is switched on when there is no earlier answer to start from. The rows on screen
// always come from the server's own list.
const QStringList kKnownSlugs = {
    QStringLiteral("illumination"), QStringLiteral("frame_difference"),
    QStringLiteral("camera_health"), QStringLiteral("foreground_mask"),
    QStringLiteral("blob_geometry"), QStringLiteral("colour_histogram"),
    QStringLiteral("optical_flow"), QStringLiteral("track_linking"),
    QStringLiteral("perceptual_hash"), QStringLiteral("audio_energy"),
    QStringLiteral("image_embedding"),
};

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
            m_errorCode.clear();
            m_errorText.clear();
            emit changed();
        } else if (m_refreshWanted) {
            // The screen asked before the saved session finished restoring (caught by
            // a WT_SECTION=labs boot screenshot that sat on "Asking the server…"). Ask
            // now, rather than leaving it to the 30 s timer.
            refresh();
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
    // /labs/scan/status is NOT cheap: each call scans ~40 days of video_segments.
    // Measured 2026-09-26 on the pilot: 2.37 s for illumination, 4.52 s for
    // frame_difference -- and a full refresh is one call plus one per analyser that is
    // switched on. So at most once a minute, unless the caller needs a fresh answer.
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (!force && m_loaded && m_errorCode.isEmpty() && now - m_lastAskMs < 60000)
        return;
    if (m_loading && !force)
        return;
    m_lastAskMs = now;
    m_refreshWanted = false;
    ++m_generation;
    m_loading = true;
    emit changed();
    // The previous answer's switched-on analysers first: the likeliest to answer.
    m_candidates = m_lastEnabled;
    for (const QString &s : kKnownSlugs)
        if (!m_candidates.contains(s))
            m_candidates << s;
    fetchSeed(0);
}

void LabsModel::fetchSeed(int i)
{
    if (i >= m_candidates.size()) {
        // Every analyser answered "disabled" (409) or "unknown" (404). The server's
        // status route only describes an analyser that is switched on, so there is no
        // budget to show -- say exactly that, and list what was asked, all off.
        m_rows.clear();
        for (const QString &s : m_candidates) {
            QVariantMap r;
            r[QStringLiteral("slug")] = s;
            r[QStringLiteral("enabled")] = false;
            m_rows.append(r);
        }
        m_enabledCount = 0;
        m_projected = QVariant();
        m_lastEnabled.clear();
        fail(QStringLiteral("none_enabled"), QString());
        m_loaded = true;
        emit changed();
        return;
    }
    const QString slug = m_candidates.at(i);
    if (!validSlug(slug)) { fetchSeed(i + 1); return; }
    QUrl url(m_baseUrl + QStringLiteral("/labs/scan/status"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("analyzer"), slug);
    url.setQuery(q);
    const int gen = m_generation;
    QNetworkReply *reply = m_nam->get(QNetworkRequest(url));
    connect(reply, &QNetworkReply::finished, this, [this, reply, i, gen]() {
        reply->deleteLater();
        if (gen != m_generation)
            return;
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray body = reply->readAll();
        if (code == 409 || code == 404) {   // analyzer_disabled / unknown_analyzer: next one
            fetchSeed(i + 1);
            return;
        }
        if (code == 401)
            AuthController::instance()->noteUnauthorized();
        if (code != 200) {
            fail(code == 0 ? QStringLiteral("unreachable") : QStringLiteral("refused"),
                 code == 0 ? reply->errorString() : wt::serverMessage(body));
            return;
        }
        m_seed = QJsonDocument::fromJson(body).object();
        m_detail.clear();
        const QStringList on = wtlabs::enabledSlugs(m_seed);
        const QString seedSlug = m_seed.value(QStringLiteral("analyzer")).toString();
        m_pending = 0;
        for (const QString &s : on)
            if (s != seedSlug && validSlug(s))
                ++m_pending;
        if (m_pending == 0) {
            finish();
            return;
        }
        for (const QString &s : on)
            if (s != seedSlug && validSlug(s))
                fetchDetail(s);
    });
}

void LabsModel::fetchDetail(const QString &slug)
{
    QUrl url(m_baseUrl + QStringLiteral("/labs/scan/status"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("analyzer"), slug);
    url.setQuery(q);
    const int gen = m_generation;
    QNetworkReply *reply = m_nam->get(QNetworkRequest(url));
    connect(reply, &QNetworkReply::finished, this, [this, reply, slug, gen]() {
        reply->deleteLater();
        if (gen != m_generation)
            return;
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        // A detail that fails leaves that one analyser's coverage unknown; it does not
        // throw away what the other answers said.
        if (code == 200)
            m_detail.insert(slug, QJsonDocument::fromJson(reply->readAll()).object());
        if (--m_pending == 0)
            finish();
    });
}

void LabsModel::finish()
{
    m_rows = wtlabs::mergeStatus(m_seed, m_detail);
    m_lastEnabled = wtlabs::enabledSlugs(m_seed);
    m_enabledCount = m_lastEnabled.size();
    m_projected = wtlabs::numOrNull(m_seed.value(QStringLiteral("projected_cpu_hours_per_day_enabled")));
    m_generatedAt = m_seed.value(QStringLiteral("generated_at")).toString();
    m_errorCode.clear();
    m_errorText.clear();
    m_loaded = true;
    m_loading = false;
    emit changed();
}

void LabsModel::fail(const QString &code, const QString &text)
{
    // The rows are NOT cleared: the last answer stays on screen, with its time, under a
    // banner that says the server is not answering now (Stability beats flicker).
    m_errorCode = code;
    m_errorText = text;
    m_loading = false;
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
        if (code == 403)
            m_changeError = QStringLiteral("admin_only");
        else if (code != 200)
            m_changeError = code == 0 ? reply->errorString()
                                      : QStringLiteral("HTTP %1 %2").arg(code).arg(wt::serverMessage(b));
        emit changed();
        refresh(true);   // show what the server now says, not what we asked for
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
    m[QStringLiteral("dir")] = dir;
    if (m != m_station) {
        m_station = m;
        emit stationChanged();
    }
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
