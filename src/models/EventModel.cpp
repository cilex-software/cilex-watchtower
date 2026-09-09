#include "EventModel.h"

// Server- and operator-authored strings render through QML Text, whose default
// AutoText promotes anything that looks like markup to StyledText — which parses
// <img src>. A camera name or a disposition note could then spoof the guard UI or
// make the station fetch an attacker URL (audit 2026-09-03, Medium 11). 643 Text
// blocks make per-element textFormat impractical, so markup is neutralised HERE,
// where the strings enter the model. Angle brackets become their entities: the
// text still reads correctly, it just can never be parsed as tags.
static QString plain(const QString &s)
{
    QString out = s;
    out.replace(QLatin1Char('<'), QStringLiteral("&lt;"));
    out.replace(QLatin1Char('>'), QStringLiteral("&gt;"));
    return out;
}

#include "MockData.h"
#include "AuthController.h"

#include <QElapsedTimer>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QJsonValue>
#include <QProcessEnvironment>
#include <QSettings>
#include <QDateTime>
#include <QUrl>
#include <QUrlQuery>
#include <QRegularExpression>
#include <QSet>
#include <QStringList>

namespace {
// Human description from cilex-vision's authoritative EventType vocab
// (entered_scene | exited_scene | stopped | loitering | motion_started |
// motion_ended). Unknown types are humanized (snake_case -> Sentence case) —
// we never invent a description. (offline/online are NOT events; they'd be a
// separate camera-status feed.)
QString descForType(const QString &type, qint64 durMs)
{
    Q_UNUSED(durMs);
    if (type == "entered_scene")  return QStringLiteral("Object entered scene");
    if (type == "exited_scene")   return QStringLiteral("Object exited scene");
    if (type == "stopped")        return QStringLiteral("Object stopped");
    if (type == "loitering")      return QStringLiteral("Loitering detected");
    if (type == "motion_started") return QStringLiteral("Motion started");
    if (type == "motion_ended")   return QStringLiteral("Motion ended");
    if (type.isEmpty()) return QStringLiteral("Event");
    QString s = type; s.replace('_', ' ');
    return s.left(1).toUpper() + s.mid(1);
}

// Event types hidden from the operator feed. motion_detected is the camera's VMD
// "incident" row: it always coincides with a motion_started (same recording_id),
// duplicates its timestamp, and the client never uses its clip_url (export and
// playback are timestamp-based). Operators only want the motion_started /
// motion_ended lifecycle, so we drop the redundant middle row. Safe because
// motion_started/_ended fire for every episode while motion_detected is a strict
// subset — hiding it can never drop a motion event.
// The feed is INCIDENT-centric everywhere since 2026-07-10 (CV spec + operator
// sync ask): the server-side exclude_types filter drops the motion lifecycle
// bookends (started/ended) and readiness warnings, leaving one deduped
// motion_detected row per incident (the one carrying the clip). Nothing is
// suppressed client-side anymore — motion_detected IS the content now.
static const char *kExcludeTypes = "motion_not_ready,motion_started,motion_ended";

bool isSuppressedType(const QString &)
{
    return false;
}

// [EVTIME] — WT_TRACE-gated latency/pool diagnostics for the events queries (the
// Events screens' "same fix" counterpart of the playback [PBTIME] logs; see
// docs/perf/2026-07-02-playback-ttff-fix.md).
const bool s_evTime = qEnvironmentVariableIsSet("WT_TRACE");

// Running requests the NAM has open to `host` — how full its 6-connection
// per-host pool is at dispatch time.
int runningTo(QNetworkAccessManager *nam, const QString &host)
{
    int n = 0;
    const auto replies = nam->findChildren<QNetworkReply *>();
    for (auto *r : replies)
        if (r->isRunning() && r->url().host() == host)
            ++n;
    return n;
}
}

EventModel::EventModel(QObject *parent)
    : QAbstractListModel(parent)
{
    auto *auth = AuthController::instance();
    m_nam = auth->nam();
    m_baseUrl = auth->baseUrl();
    connect(auth, &AuthController::baseUrlChanged, this,
            [this, auth]() { m_baseUrl = auth->baseUrl(); });

    if (qEnvironmentVariableIsSet("WT_DEMO")) {
        m_all = wt::mock::events();
        applyAcks();
        return;
    }

    // Live events from cilex-vision. Fetch once signed in; clear on sign-out so
    // we never show a previous operator's feed. The list stays empty (honest)
    // until the backend feed actually has events.
    connect(auth, &AuthController::authenticatedChanged, this, [this, auth]() {
        if (auth->authenticated()) {
            refresh();
            fetchOperators();
        } else {
            beginResetModel();
            m_all.clear();
            endResetModel();
            m_operators.clear();
            emit operatorsChanged();
            emit changed();
        }
    });
    if (auth->authenticated()) {
        refresh();
        fetchOperators();
    }
}

int EventModel::rowCount(const QModelIndex &parent) const
{
    if (parent.isValid())
        return 0;
    return int(m_all.size());
}

QVariant EventModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_all.size())
        return {};

    const wt::EventData &e = m_all.at(index.row());
    switch (role) {
    case IdRole:      return e.id;
    case TypeRole:    return e.type;
    case CamIdRole:   return e.camId;
    case CamNameRole: return e.camName;
    case GroupRole:   return e.group;
    case TimeRole:    return e.time;
    case DescRole:    return e.desc;
    case AckRole:     return e.ack;
    case AckByRole:   return e.ackBy;
    case AckTimeRole: return e.ackTime;
    default:          return {};
    }
}

QHash<int, QByteArray> EventModel::roleNames() const
{
    return {
        { IdRole,      "eventId" },
        { TypeRole,    "type" },
        { CamIdRole,   "camId" },
        { CamNameRole, "camName" },
        { GroupRole,   "group" },
        { TimeRole,    "time" },
        { DescRole,    "desc" },
        { AckRole,     "ack" },
        { AckByRole,   "ackBy" },
        { AckTimeRole, "ackTime" },
    };
}

int EventModel::unacknowledgedCount() const
{
    int n = 0;
    for (const wt::EventData &e : m_all)
        if (!e.ack)
            ++n;
    return n;
}

QStringList EventModel::recentCameraIds(qint64 windowMs) const
{
    const qint64 cutoff = QDateTime::currentDateTimeUtc().toMSecsSinceEpoch() - windowMs;
    QSet<QString> ids;
    for (const wt::EventData &e : m_all)
        if (e.tsMs >= cutoff && !e.camId.isEmpty())
            ids.insert(e.camId);
    return QStringList(ids.begin(), ids.end());
}

void EventModel::refresh()
{
    if (qEnvironmentVariableIsSet("WT_DEMO") || m_loading)
        return;
    if (!AuthController::instance()->authenticated())
        return;                            // not signed in — leave the list empty
    m_loading = true;
    emit changed();
    fetchPage(false);                      // re-run the current query from page 0
}

void EventModel::search(const QString &cameraId, const QString &startIso,
                        const QString &endIso)
{
    m_qCameraId = cameraId;
    m_qStart = startIso;
    m_qEnd = endIso;
    if (qEnvironmentVariableIsSet("WT_DEMO"))
        return;                            // demo feed is static
    if (!AuthController::instance()->authenticated())
        return;
    // Note: not guarded on m_loading — a newer query supersedes any in-flight one
    // via m_gen, so rapid filter changes always end on the latest result.
    m_loading = true;
    emit changed();
    fetchPage(false);
}

void EventModel::loadMore()
{
    if (qEnvironmentVariableIsSet("WT_DEMO") || m_loading)
        return;
    if (m_fetched >= m_serverTotal)   // nothing more to fetch (counts raw server rows)
        return;
    if (!AuthController::instance()->authenticated())
        return;
    m_loading = true;
    emit changed();
    fetchPage(true);
}

// One /events row (also the body returned by the action POSTs) → EventData. The
// full contract from cilex-vision's 2026-06-18 letter; design-only fields the
// backend doesn't emit stay empty (never invented).
wt::EventData EventModel::parseRow(const QJsonObject &o) const
{
    wt::EventData e;
    e.id = o.value("event_id").toString();
    e.type = o.value("event_type").toString().toLower();
    e.camId = o.value("camera_id").toString();
    e.camName = plain(o.value("camera_name").toString());
    if (e.camName.isEmpty()) e.camName = e.camId;
    e.group = plain(o.value("zone").toString());             // zone = camera group name
    const QDateTime dt = QDateTime::fromString(o.value("start_time").toString(), Qt::ISODate);
    e.time = dt.isValid() ? dt.toLocalTime().toString("HH:mm:ss") : o.value("start_time").toString();
    e.tsMs = dt.isValid() ? dt.toMSecsSinceEpoch() : 0;
    e.durationMs = o.value("duration_ms").toVariant().toLongLong();
    e.recordingId = o.value("metadata").toObject().value("recording_id").toString();
    // The episode JOIN key (CV bf49af6, letter 2026-08-20): present on started+ended for
    // ALL camera modes — recording_id is mode-dependent (continuous cameras honestly null)
    // and stays reserved for clip/still semantics, never grouping.
    e.rawMotionEventId = o.value("metadata").toObject().value("raw_motion_event_id").toString();
    e.desc = descForType(e.type, e.durationMs);
    // redesign contract
    e.severity = o.value("severity").toString();
    e.zoneRestricted = o.value("zone_restricted").toBool();
    e.triageState = o.value("triage_state").toString();
    e.disposition = o.value("disposition").toString();
    e.dispositionNote = plain(o.value("disposition_note").toString());
    e.assignedTo = plain(o.value("assigned_to").toString());
    e.assignedAt = o.value("assigned_at").toString();
    e.bookmarked = o.value("bookmarked").toBool();
    e.clipUrl = o.value("clip_url").toString();
    // ack derives from triage_state (anything past "new")
    e.ack = !e.triageState.isEmpty() && e.triageState != QLatin1String("new");
    e.ackBy = o.value("acknowledged_by").toString();
    const QDateTime adt = QDateTime::fromString(o.value("acknowledged_at").toString(), Qt::ISODate);
    e.ackTime = adt.isValid() ? adt.toLocalTime().toString("HH:mm") : QString();
    const QJsonValue det = o.value("detection");
    if (det.isObject()) {
        const QJsonObject d = det.toObject();
        e.detClass = d.value("class").toString();
        e.detConf = d.value("confidence").isDouble() ? d.value("confidence").toDouble() : -1.0;
        const QJsonArray bb = d.value("bbox").toArray();
        for (const QJsonValue &x : bb) e.detBbox.append(x.toDouble());
    }
    return e;
}

void EventModel::fetchPage(bool append)
{
    const int gen = ++m_gen;               // tag this request; newer ones supersede it
    QUrl url(m_baseUrl + "/events");
    QUrlQuery q;
    q.addQueryItem("limit", QString::number(m_pageSize));
    q.addQueryItem("offset", QString::number(append ? m_fetched : 0));
    q.addQueryItem("exclude_types", QLatin1String(kExcludeTypes));
    if (!m_qCameraId.isEmpty()) q.addQueryItem("camera_id", m_qCameraId);
    if (!m_qStart.isEmpty())    q.addQueryItem("start", m_qStart);
    if (!m_qEnd.isEmpty())      q.addQueryItem("end", m_qEnd);
    url.setQuery(q);
    QElapsedTimer evTimer;
    evTimer.start();
    if (s_evTime)
        qInfo("[EVTIME] events_dispatch inflight=%d", runningTo(m_nam, url.host()));
    QNetworkReply *reply = m_nam->get(QNetworkRequest{url});
    connect(reply, &QNetworkReply::finished, this, [this, reply, append, gen, evTimer]() {
        reply->deleteLater();
        const int code0 = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (s_evTime)
            qInfo("[EVTIME] events_http ms=%lld code=%d superseded=%d",
                  (long long)evTimer.elapsed(), code0, gen != m_gen ? 1 : 0);
        if (gen != m_gen)                  // a newer query started — drop this result
            return;
        const int code = code0;
        if (code == 401)
            AuthController::instance()->noteUnauthorized();
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const auto arr = obj.value("events").toArray();
        if (!append)
            m_fetched = 0;                 // fresh query — restart the server offset
        m_fetched += int(arr.size());      // raw rows consumed (drives the next page offset)
        QVector<wt::EventData> out;
        out.reserve(arr.size());
        bool motionAdvanced = false;
        for (const auto &v : arr) {
            const auto o = v.toObject();
            const QString t = o.value("event_type").toString().toLower();
            trackMotionRow(o, &motionAdvanced);
            if (isSuppressedType(t))
                continue;              // drop motion_detected — see isSuppressedType()
            out.push_back(parseRow(o));
        }
        if (motionAdvanced) { ++m_motionRev; emit motionRevChanged(); }
        // No applyAcks() on the live path: the backend's triage_state is now the
        // authoritative ack/disposition state (parseRow derives `ack` from it).
        if (append && !out.isEmpty()) {
            const int base = int(m_all.size());
            beginInsertRows(QModelIndex(), base, base + int(out.size()) - 1);
            m_all += out;
            endInsertRows();
        } else if (!append) {
            beginResetModel();
            m_all = out;
            endResetModel();
        }
        m_serverTotal = obj.value("total").toInt(int(m_all.size()));
        m_loading = false;
        emit changed();
    });
}

void EventModel::applyAcks()
{
    QSettings s;
    s.beginGroup("eventAcks");
    for (wt::EventData &e : m_all) {
        const QString v = s.value(e.id).toString();
        if (!v.isEmpty()) {
            const auto parts = v.split('|');
            e.ack = true;
            e.ackBy = parts.value(0);
            e.ackTime = parts.value(1);
        }
    }
    s.endGroup();
}

void EventModel::persistAck(const QString &id, const QString &by, const QString &time)
{
    QSettings s;
    s.beginGroup("eventAcks");
    s.setValue(id, by + "|" + time);
    s.endGroup();
}

void EventModel::acknowledge(int row, const QString &by)
{
    if (row < 0 || row >= m_all.size() || m_all[row].ack)
        return;
    const QString t = QDateTime::currentDateTime().toString("HH:mm");
    m_all[row].ack = true;
    m_all[row].ackBy = by;
    m_all[row].ackTime = t;
    persistAck(m_all[row].id, by, t);
    emit dataChanged(index(row), index(row), { AckRole, AckByRole, AckTimeRole });
    emit changed();
}

void EventModel::acknowledgeById(const QString &id)
{
    if (qEnvironmentVariableIsSet("WT_DEMO")) {            // mock: local-only ack
        for (int i = 0; i < m_all.size(); ++i)
            if (m_all[i].id == id) { acknowledge(i, AuthController::instance()->username()); return; }
        return;
    }
    postEventAction(id, QStringLiteral("acknowledge"), {});   // shared, server-persisted
}

void EventModel::setDisposition(const QString &id, const QString &disposition, const QString &note)
{
    if (qEnvironmentVariableIsSet("WT_DEMO")) {            // mock: local patch
        for (int i = 0; i < m_all.size(); ++i)
            if (m_all[i].id == id) {
                const bool dismiss = (disposition == "false_alarm" || disposition == "dismissed");
                m_all[i].triageState = dismiss ? "dismissed" : "resolved";
                m_all[i].disposition = disposition;
                m_all[i].dispositionNote = note;
                m_all[i].ack = true;
                emit dataChanged(index(i), index(i));
                emit changed();
                return;
            }
        return;
    }
    QJsonObject b;
    b["disposition"] = disposition;
    if (!note.isEmpty()) b["note"] = note;
    postEventAction(id, QStringLiteral("disposition"), b);
}

void EventModel::setBookmark(const QString &id, bool value)
{
    if (qEnvironmentVariableIsSet("WT_DEMO")) {            // mock: local toggle
        for (int i = 0; i < m_all.size(); ++i)
            if (m_all[i].id == id) { m_all[i].bookmarked = value; emit dataChanged(index(i), index(i)); emit changed(); return; }
        return;
    }
    QJsonObject b; b["value"] = value;
    postEventAction(id, QStringLiteral("bookmark"), b);
}

void EventModel::assignEvent(const QString &id, const QString &assignee)
{
    if (qEnvironmentVariableIsSet("WT_DEMO")) {            // mock: local patch
        for (int i = 0; i < m_all.size(); ++i)
            if (m_all[i].id == id) {
                m_all[i].assignedTo = assignee;
                if (!assignee.isEmpty()) m_all[i].triageState = "in_progress";
                emit dataChanged(index(i), index(i));
                emit changed();
                return;
            }
        return;
    }
    QJsonObject b;
    b.insert("assignee", assignee.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(assignee));
    postEventAction(id, QStringLiteral("assign"), b);
}

void EventModel::fetchOperators()
{
    if (qEnvironmentVariableIsSet("WT_DEMO")) return;
    if (!AuthController::instance()->authenticated()) return;
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/operators")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) { AuthController::instance()->noteUnauthorized(); return; }
        if (code < 200 || code >= 300) return;
        const QJsonArray arr = QJsonDocument::fromJson(reply->readAll()).object().value("operators").toArray();
        m_operators.clear();
        for (const QJsonValue &v : arr) m_operators.append(v.toObject().toVariantMap());
        emit operatorsChanged();
    });
}

// POST /events/{id}/{acknowledge|disposition|bookmark}; the endpoint returns the
// updated event row, which we parse and swap in place (so any client reflects the
// shared state). Leaves the row untouched on any non-2xx.
void EventModel::postEventAction(const QString &id, const QString &subpath, const QJsonObject &body)
{
    QNetworkRequest req{ QUrl(m_baseUrl + "/events/" + id + "/" + subpath) };
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) { AuthController::instance()->noteUnauthorized(); return; }
        if (code < 200 || code >= 300) return;
        const QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
        const wt::EventData e = parseRow(o);
        for (int i = 0; i < m_all.size(); ++i)
            if (m_all[i].id == e.id) {
                m_all[i] = e;
                emit dataChanged(index(i), index(i));
                emit changed();
                return;
            }
    });
}

// GET /events/{id} (CV reply 2026-08-21: exists at events.py:873, camera-filtered,
// feed-row shape). Our minted links carry the motion_detected row id — the same id
// the feed consumes — so no any-of-three translation is needed for our own links;
// foreign ids ride the server's resolve when CV's queued canonicalization deploys.
void EventModel::fetchOne(const QString &eventId)
{
    // The id arrives from a cilex:// link — attacker-shaped input. It is spliced
    // into a request path carrying the operator session, so it must be exactly a
    // UUID and nothing else (audit 2026-09-03, Low). Refuse honestly, never
    // garbage-request.
    static const QRegularExpression kUuid(
        QStringLiteral("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"));
    if (!kUuid.match(eventId).hasMatch()) {
        qWarning("[LINK] refused non-UUID event id (%d chars)", int(eventId.size()));
        emit oneFetchFailed(eventId, 400);
        return;
    }
    QNetworkRequest req{ QUrl(m_baseUrl + "/events/" + eventId) };
    QNetworkReply *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply, eventId]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) { AuthController::instance()->noteUnauthorized(); emit oneFetchFailed(eventId, code); return; }
        if (code < 200 || code >= 300) { emit oneFetchFailed(eventId, code); return; }
        const wt::EventData e = parseRow(QJsonDocument::fromJson(reply->readAll()).object());
        if (e.id.isEmpty()) { emit oneFetchFailed(eventId, 0); return; }
        bool found = false;
        for (int i = 0; i < m_all.size(); ++i)
            if (m_all[i].id == e.id) { m_all[i] = e; emit dataChanged(index(i), index(i)); found = true; break; }
        if (!found) {
            beginInsertRows(QModelIndex(), m_all.size(), m_all.size());
            m_all.append(e);
            endInsertRows();
        }
        emit changed();                 // EventsStore re-ingests; the row becomes addressable
        emit oneFetched(toMap(e));
    });
}

QVariantMap EventModel::toMap(const wt::EventData &e) const
{
    QVariantMap m;
    m["eventId"] = e.id;
    m["type"] = e.type;
    m["camId"] = e.camId;
    m["camName"] = e.camName;
    m["group"] = e.group;
    m["time"] = e.time;
    m["desc"] = e.desc;
    m["ack"] = e.ack;
    m["ackBy"] = e.ackBy;
    m["ackTime"] = e.ackTime;
    m["ts"] = static_cast<qlonglong>(e.tsMs);
    m["durationMs"] = static_cast<qlonglong>(e.durationMs);
    m["recordingId"] = e.recordingId;
    m["rawMotionEventId"] = e.rawMotionEventId;
    // redesign contract
    m["severity"] = e.severity;
    m["zoneRestricted"] = e.zoneRestricted;
    m["triageState"] = e.triageState;
    m["disposition"] = e.disposition;
    m["dispositionNote"] = e.dispositionNote;
    m["assignedTo"] = e.assignedTo;
    m["assignedAt"] = e.assignedAt;
    m["bookmarked"] = e.bookmarked;
    m["clipUrl"] = e.clipUrl;
    if (e.detClass.isEmpty()) {
        m["detection"] = QVariant();           // null — no detection (never faked)
    } else {
        QVariantMap det;
        det["cls"] = e.detClass;
        det["confidence"] = e.detConf;
        det["bbox"] = e.detBbox;
        m["detection"] = det;
    }
    return m;
}

QVariantList EventModel::all() const
{
    QVariantList list;
    list.reserve(m_all.size());
    for (const wt::EventData &e : m_all)
        list.append(toMap(e));
    return list;
}

// Per-camera motion tracking off one /events row: freshness (ARMED badge age) +
// episode state (live MOTION indicator). Counts every motion_* row — including
// display-suppressed motion_detected — except motion_not_ready (a health warning).
void EventModel::trackMotionRow(const QJsonObject &o, bool *advanced)
{
    const QString t = o.value("event_type").toString().toLower();
    if (!t.startsWith(QLatin1String("motion_")) || t == QLatin1String("motion_not_ready"))
        return;
    const QDateTime dt = QDateTime::fromString(o.value("start_time").toString(), Qt::ISODate);
    if (!dt.isValid())
        return;
    const QString cid = o.value("camera_id").toString();
    const qint64 ms = dt.toMSecsSinceEpoch();
    auto bump = [&](QHash<QString, qint64> &h) {
        auto it = h.constFind(cid);
        if (it == h.constEnd() || ms > it.value()) { h.insert(cid, ms); *advanced = true; }
    };
    bump(m_lastMotion);
    if (t == QLatin1String("motion_started")) bump(m_lastStarted);
    else if (t == QLatin1String("motion_ended")) bump(m_lastEnded);
}

bool EventModel::motionActive(const QString &cameraId) const
{
    const qint64 started = m_lastStarted.value(cameraId, -1);
    if (started < 0)
        return false;
    if (m_lastEnded.value(cameraId, -1) >= started)
        return false;
    // lost/late motion_ended safety: an "active" episode older than 10 min is stale
    return QDateTime::currentMSecsSinceEpoch() - started < 10 * 60 * 1000;
}

bool EventModel::pollBegin(const char *kind)
{
    static const bool trace = qEnvironmentVariableIsSet("WT_TRACE");
    PollGate &g = m_pollGates[QByteArray(kind)];
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (g.inflight) {
        if (trace) qInfo("[EVPOLL] %s skipped: previous still in flight (%lld ms so far)", kind, (long long)(now - g.startedMs));
        return false;
    }
    const qint64 hold = qMin<qint64>(3 * g.lastMs, 120000);
    if (g.lastMs > 0 && now - g.startedMs < hold) {
        if (trace) qInfo("[EVPOLL] %s skipped: backing off after a %lld ms answer (next in %lld ms)", kind, (long long)g.lastMs, (long long)(hold - (now - g.startedMs)));
        return false;
    }
    g.inflight = true;
    g.startedMs = now;
    return true;
}

void EventModel::pollEnd(const char *kind)
{
    PollGate &g = m_pollGates[QByteArray(kind)];
    g.inflight = false;
    g.lastMs = QDateTime::currentMSecsSinceEpoch() - g.startedMs;
    if (g.lastMs > 2000)
        qInfo("[EVPOLL] %s answered in %lld ms — this client backs off to one poll per %lld ms",
              kind, (long long)g.lastMs, (long long)qMin<qint64>(3 * g.lastMs, 120000));
}

void EventModel::pollMotion()
{
    if (m_baseUrl.isEmpty())
        return;                                        // WT_DEMO / logged out
    QUrl url(m_baseUrl + "/events");
    if (!pollBegin("motion"))
        return;
    QUrlQuery q;
    q.addQueryItem("limit", "100");     // deep enough that the motion_not_ready flood can't bury real motion rows
    url.setQuery(q);
    QNetworkReply *reply = m_nam->get(QNetworkRequest{url});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        pollEnd("motion");
        reply->deleteLater();
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const auto arr = obj.value("events").toArray();
        bool advanced = false;
        for (const auto &v : arr)
            trackMotionRow(v.toObject(), &advanced);
        if (advanced) { ++m_motionRev; emit motionRevChanged(); }
    });
}

// Live Events sidebar: one row per motion incident. Server-side exclude_types
// keeps lifecycle bookends and readiness warnings out.
//
// The old comment here claimed "every returned row is a real incident with a clip
// (=> a mid-event still exists for it)". Measured on the pilot 2026-08-15: of 14
// returned rows, clip_url was set on ONE and metadata.recording_id on three. The
// sidebar gated its thumbnail on clip_url because of that claim, so it issued no
// snapshot request at all for 13 of 14 rows and the whole rail drew placeholder
// glyphs. Gate on recording_id — the precondition the extraction endpoint actually
// has — and never re-derive one fact from a different one.
void EventModel::fetchLiveFeed()
{
    if (m_baseUrl.isEmpty())
        return;                                        // WT_DEMO / logged out
    QUrl url(m_baseUrl + "/events");
    if (!pollBegin("live_feed"))
        return;
    QUrlQuery q;
    q.addQueryItem("limit", "14");
    q.addQueryItem("exclude_types", QLatin1String(kExcludeTypes));
    url.setQuery(q);
    QNetworkReply *reply = m_nam->get(QNetworkRequest{url});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        pollEnd("live_feed");
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError)
            return;                                    // transient — keep the last list
        const auto arr = QJsonDocument::fromJson(reply->readAll()).object()
                             .value("events").toArray();
        static const QRegularExpression ipRe(
            QStringLiteral("\\s*\\((\\d{1,3}(?:\\.\\d{1,3}){3})\\)\\s*$"));
        QVariantList out;
        QString sig;
        bool advanced = false;
        for (const auto &v : arr) {
            const auto o = v.toObject();
            trackMotionRow(o, &advanced);              // the feed doubles as a motion-freshness source
            QVariantMap m;
            const QString id = o.value("event_id").toString();
            m.insert("id", id);
            m.insert("type", o.value("event_type").toString().toLower());
            // Camera line, IP-first: the provisioner bakes "(ip)" into the name —
            // split it out so the IP renders un-clipped and isn't printed twice.
            QString name = plain(o.value("camera_name").toString());
            QString ip;
            const auto match = ipRe.match(name);
            if (match.hasMatch()) {
                ip = match.captured(1);
                name = name.left(match.capturedStart()).trimmed();
            }
            m.insert("ip", ip);
            m.insert("camName", name.isEmpty() ? o.value("camera_id").toString() : name);
            // camId, so the rail can draw the camera's CURRENT still while the recorded
            // event frame is still being written. The paged/search map (toMap above) has
            // carried camId all along; this live-feed map never did, so OpsSidebar's
            // preview had nothing to ask for and every fresh row stayed blank.
            m.insert("camId", o.value("camera_id").toString());
            const QDateTime dt = QDateTime::fromString(o.value("start_time").toString(), Qt::ISODate);
            m.insert("tsMs", dt.isValid() ? double(dt.toMSecsSinceEpoch()) : -1.0);
            m.insert("hasClip", !o.value("clip_url").toString().isEmpty());
            // The sidebar's still comes from `events/{id}/snapshot`, which EXTRACTS a
            // frame from recorded video — it has nothing to do with `clip_url`. Its
            // precondition is a recording_id (CV letter 2026-08-09 reply §1.3, and see
            // the contract table in EvSnapshot.qml). Gating the rail's thumbnail on
            // hasClip meant asking "is there a downloadable clip?" to decide whether a
            // FRAME could be extracted — two different facts, and the answer to the
            // wrong one was no, so the rail never asked and every row drew the
            // no-content glyph (operator report 2026-08-15; zero OpsSidebar image
            // warnings in a 7 h run confirmed no request was ever made).
            m.insert("recordingId", o.value("metadata").toObject()
                                     .value("recording_id").toString());
            m.insert("durationMs", o.value("duration_ms").toVariant().toLongLong());
            const bool ack = !o.value("triage_state").toString().isEmpty()
                             && o.value("triage_state").toString() != QLatin1String("new");
            m.insert("ack", ack);
            out.append(m);
            sig += id + QLatin1Char(ack ? '1' : '0') + QLatin1Char('|');
        }
        if (advanced) { ++m_motionRev; emit motionRevChanged(); }
        if (sig == m_liveFeedSig)
            return;                                    // identical — no delegate churn
        m_liveFeedSig = sig;
        m_liveFeed = out;
        emit liveFeedChanged();
    });
}

// Fast, churn-free sync for the Events screen (10s while visible): fetch the
// newest page and TOP-MERGE — genuinely new incidents insert at row 0, known
// rows get their triage/ack fields patched in place. No model reset, so the
// four tabs (Triage/Verify/Timeline/Map, all fed off changed() -> ingestReal)
// update rapidly without delegate churn; selection is id-based and survives.
void EventModel::refreshIncremental()
{
    if (m_baseUrl.isEmpty() || m_loading)
        return;
    if (!m_qCameraId.isEmpty() || !m_qStart.isEmpty() || !m_qEnd.isEmpty())
        return;                                        // a scoped search is active — don't fight it
    QUrl url(m_baseUrl + "/events");
    if (!pollBegin("incremental"))
        return;
    QUrlQuery q;
    q.addQueryItem("limit", QString::number(m_pageSize));
    q.addQueryItem("exclude_types", QLatin1String(kExcludeTypes));
    url.setQuery(q);
    QNetworkReply *reply = m_nam->get(QNetworkRequest{url});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        pollEnd("incremental");
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError)
            return;
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const auto arr = obj.value("events").toArray();
        QHash<QString, int> byId;
        for (int i = 0; i < m_all.size(); ++i)
            byId.insert(m_all[i].id, i);
        QVector<wt::EventData> fresh;
        bool patched = false, motionAdvanced = false;
        for (const auto &v : arr) {
            const auto o = v.toObject();
            trackMotionRow(o, &motionAdvanced);
            if (isSuppressedType(o.value("event_type").toString().toLower()))
                continue;
            wt::EventData e = parseRow(o);
            const auto it = byId.constFind(e.id);
            if (it != byId.constEnd()) {
                wt::EventData &cur = m_all[*it];
                if (cur.triageState != e.triageState || cur.disposition != e.disposition
                    || cur.assignedTo != e.assignedTo || cur.bookmarked != e.bookmarked
                    || cur.ack != e.ack) {
                    cur = e;
                    const QModelIndex idx = index(*it);
                    emit dataChanged(idx, idx);
                    patched = true;
                }
            } else {
                fresh.append(e);
            }
        }
        if (motionAdvanced) { ++m_motionRev; emit motionRevChanged(); }
        if (!fresh.isEmpty()) {
            beginInsertRows(QModelIndex(), 0, int(fresh.size()) - 1);
            for (int i = int(fresh.size()) - 1; i >= 0; --i)
                m_all.prepend(fresh[i]);
            endInsertRows();
            m_fetched += int(fresh.size());
        }
        m_serverTotal = obj.value("total").toInt(m_serverTotal);
        if (!fresh.isEmpty() || patched)
            emit changed();                            // -> EventsArea re-ingests all four tabs
    });
}
