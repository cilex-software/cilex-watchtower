#include "LabsTimeline.h"
#include "AuthController.h"
#include "ServerMessage.h"

#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>

namespace {
// Three at a time: ten index scans are cheap, but this server is also the recording box, and
// a burst of ten on every window change is not needed to fill ten thin rows.
constexpr int kConcurrent = 3;
// A wheel zoom or a pan moves the window many times a second; ask once it settles.
constexpr int kDebounceMs = 350;

// Dev/verification: WT_LABS_LIMIT=<n> asks for n rows per analyser instead of the endpoint's
// 2,000, so a screenshot can show a CUT row ("n+", the not-loaded hatch) on real data. Inert
// unless set.
int pageLimit()
{
    const int v = qEnvironmentVariableIntValue("WT_LABS_LIMIT");
    return v > 0 ? std::min(v, wtlabs::kPageLimit) : wtlabs::kPageLimit;
}
}   // namespace

LabsTimeline::LabsTimeline(QObject *parent)
    : QObject(parent)
{
    auto *auth = AuthController::instance();
    m_nam = auth->nam();
    m_baseUrl = auth->baseUrl();
    connect(auth, &AuthController::baseUrlChanged, this, [this, auth]() {
        m_baseUrl = auth->baseUrl();
        clearAll();                    // another server: nothing on screen is about it
        schedule();
    });
    connect(auth, &AuthController::authenticatedChanged, this, [this, auth]() {
        if (!auth->authenticated())
            clearAll();
        else
            schedule();
    });
    m_debounce.setSingleShot(true);
    m_debounce.setInterval(kDebounceMs);
    connect(&m_debounce, &QTimer::timeout, this, &LabsTimeline::refetch);
    for (const QString &k : wtlabs::laneKeys())
        m_tracks.insert(k, Track{});
}

void LabsTimeline::setCameraId(const QString &v)
{
    if (v == m_cameraId)
        return;
    m_cameraId = v;
    // A REAL identity change: clear now, not when the next answer lands.
    clearAll();
    emit inputsChanged();
    schedule();
}

void LabsTimeline::setStartMs(double v)
{
    if (v == m_startMs)
        return;
    m_startMs = v;
    emit inputsChanged();
    schedule();
}

void LabsTimeline::setEndMs(double v)
{
    if (v == m_endMs)
        return;
    m_endMs = v;
    emit inputsChanged();
    schedule();
}

void LabsTimeline::setActive(bool v)
{
    if (v == m_active)
        return;
    m_active = v;
    emit inputsChanged();
    schedule();
}

void LabsTimeline::setLang(const QString &v)
{
    const QString l = v == QLatin1String("ru") ? QStringLiteral("ru") : QStringLiteral("en");
    if (l == m_lang)
        return;
    m_lang = l;
    emit inputsChanged();
    schedule();
}

void LabsTimeline::schedule()
{
    if (!m_active || m_cameraId.isEmpty() || !(m_endMs > m_startMs))
        return;
    m_debounce.start();
}

void LabsTimeline::clearAll()
{
    ++m_generation;                    // answers still in flight are now about something else
    m_queue.clear();
    for (auto it = m_tracks.begin(); it != m_tracks.end(); ++it)
        it.value() = Track{};
    m_index.clear();
    m_haveCamera.clear();
    m_haveLang.clear();
    m_haveStart = m_haveEnd = 0;
    m_loaded = false;
    m_errorCode.clear();
    m_errorText.clear();
    emit stateChanged();
    bump();
}

void LabsTimeline::refetch()
{
    if (!m_active || m_cameraId.isEmpty() || !(m_endMs > m_startMs))
        return;
    if (!AuthController::instance()->authenticated())
        return;
    const qint64 s = qint64(std::floor(m_startMs)), e = qint64(std::ceil(m_endMs));
    if (m_haveCamera == m_cameraId && m_haveLang == m_lang && qAbs(m_haveStart - s) < 1000
        && qAbs(m_haveEnd - e) < 1000 && m_failed == 0 && m_queue.isEmpty() && m_inFlight == 0)
        return;                        // the rows on screen already answer for this window
    ++m_generation;
    m_haveCamera = m_cameraId;
    m_haveLang = m_lang;
    m_haveStart = s;
    m_haveEnd = e;
    m_failed = 0;
    m_lastErrorCode.clear();
    m_lastErrorText.clear();
    m_queue = wtlabs::laneKeys();
    for (const QString &k : m_queue)
        m_tracks[k].state = QStringLiteral("loading");      // old markers stay until replaced
    emit stateChanged();
    pump();
}

void LabsTimeline::pump()
{
    while (m_inFlight < kConcurrent && !m_queue.isEmpty()) {
        const QString key = m_queue.takeFirst();
        const QUrl url = wtlabs::observationsUrl(m_baseUrl, m_haveCamera, qint64(m_haveStart), qint64(m_haveEnd),
                                                 key, m_haveLang, pageLimit());
        QNetworkReply *reply = m_nam->get(QNetworkRequest(url));
        ++m_inFlight;
        const int gen = m_generation;
        connect(reply, &QNetworkReply::finished, this, [this, reply, key, gen]() { onReply(reply, key, gen); });
    }
}

void LabsTimeline::onReply(QNetworkReply *reply, const QString &key, int generation)
{
    reply->deleteLater();
    --m_inFlight;
    if (generation != m_generation) {  // a newer window or another camera: not this answer's
        pump();
        emit stateChanged();
        return;
    }
    const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QByteArray body = reply->readAll();
    Track &t = m_tracks[key];
    if (code == 200) {
        const QJsonArray arr = QJsonDocument::fromJson(body).array();
        t.obs = wtlabs::parseObservations(arr);
        t.truncated = arr.size() >= pageLimit();
        // The endpoint answers NEWEST first: a cut answer is missing the OLDEST part of the
        // window, so everything before its oldest row is not loaded -- said, not implied.
        t.cutBeforeMs = (t.truncated && !t.obs.isEmpty()) ? t.obs.first().startMs : 0;
        t.state = QStringLiteral("ok");
        t.error.clear();
    } else {
        if (code == 401)
            AuthController::instance()->noteUnauthorized();
        const QJsonObject o = QJsonDocument::fromJson(body).object();
        const QString slug = o.value(QStringLiteral("code")).toString();
        m_lastErrorCode = code == 0 ? QStringLiteral("unreachable")
                        : code == 403 && slug == QLatin1String("camera_not_in_scope") ? QStringLiteral("not_in_scope")
                        : code == 403 ? QStringLiteral("admin_only")
                                      : QStringLiteral("refused");
        m_lastErrorText = code == 0 ? reply->errorString() : wt::serverMessage(body);
        t.obs.clear();                 // a failed row shows nothing, and says it failed
        t.truncated = false;
        t.cutBeforeMs = 0;
        t.state = QStringLiteral("error");
        t.error = m_lastErrorText;
        ++m_failed;
    }
    rebuildIndex();
    if (m_queue.isEmpty() && m_inFlight == 0) {
        m_loaded = true;
        const bool allFailed = m_failed == wtlabs::laneKeys().size();
        m_errorCode = allFailed ? m_lastErrorCode : QString();
        m_errorText = allFailed ? m_lastErrorText : QString();
    }
    emit stateChanged();
    bump();
    pump();
}

void LabsTimeline::rebuildIndex()
{
    m_index.clear();
    for (auto it = m_tracks.constBegin(); it != m_tracks.constEnd(); ++it)
        for (int i = 0; i < it.value().obs.size(); ++i)
            m_index.insert(it.value().obs[i].id, qMakePair(it.key(), i));
}

void LabsTimeline::bump()
{
    ++m_revision;
    emit revisionChanged();
}

QVariantList LabsTimeline::tracks() const
{
    QVariantList out;
    for (const QString &k : wtlabs::laneKeys()) {
        const Track &t = m_tracks.value(k);
        QVariantMap m;
        m[QStringLiteral("key")] = k;
        m[QStringLiteral("count")] = t.obs.size();
        m[QStringLiteral("truncated")] = t.truncated;
        m[QStringLiteral("cutBeforeMs")] = double(t.cutBeforeMs);
        m[QStringLiteral("state")] = t.state;
        m[QStringLiteral("error")] = t.error;
        out << m;
    }
    return out;
}

int LabsTimeline::total() const
{
    int n = 0;
    for (const Track &t : m_tracks)
        n += t.obs.size();
    return n;
}

const QVector<wtlabs::Obs> &LabsTimeline::rows(const QString &key) const
{
    static const QVector<wtlabs::Obs> none;
    auto it = m_tracks.constFind(key);
    return it == m_tracks.constEnd() ? none : it.value().obs;
}

qint64 LabsTimeline::cutBeforeMs(const QString &key) const
{
    return m_tracks.value(key).cutBeforeMs;
}

bool LabsTimeline::locate(const QString &id, QString *key, int *index) const
{
    auto it = m_index.constFind(id);
    if (it == m_index.constEnd())
        return false;
    if (key)
        *key = it.value().first;
    if (index)
        *index = it.value().second;
    return true;
}

QVariantMap LabsTimeline::observation(const QString &id) const
{
    QString key;
    int i = -1;
    if (!locate(id, &key, &i))
        return {};
    const wtlabs::Obs &o = m_tracks.value(key).obs.at(i);
    QVariantMap m = o.row;
    m[QStringLiteral("startMs")] = double(o.startMs);
    m[QStringLiteral("endMs")] = double(o.endMs);
    return m;
}

QString LabsTimeline::firstIdOf(const QString &key, double fromMs, double toMs) const
{
    for (const wtlabs::Obs &o : m_tracks.value(key).obs)
        if (o.startMs >= fromMs && o.startMs <= toMs)
            return o.id;
    return {};
}
