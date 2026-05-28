#include "EventModel.h"

#include "MockData.h"
#include "AuthController.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QProcessEnvironment>
#include <QSettings>
#include <QDateTime>

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
        } else {
            beginResetModel();
            m_all.clear();
            endResetModel();
            emit changed();
        }
    });
    if (auth->authenticated())
        refresh();
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

void EventModel::refresh()
{
    if (qEnvironmentVariableIsSet("WT_DEMO") || m_loading)
        return;
    if (!AuthController::instance()->authenticated())
        return;                            // not signed in — leave the list empty
    m_loading = true;
    emit changed();
    fetchEvents();
}

void EventModel::fetchEvents()
{
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/events?limit=200")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401)
            AuthController::instance()->noteUnauthorized();
        const auto arr = QJsonDocument::fromJson(reply->readAll())
                             .object().value("events").toArray();
        QVector<wt::EventData> out;
        out.reserve(arr.size());
        for (const auto &v : arr) {
            const auto o = v.toObject();
            wt::EventData e;
            e.id = o.value("event_id").toString();
            e.type = o.value("event_type").toString().toLower();
            e.camId = o.value("camera_id").toString();
            e.camName = e.camId;           // Events screen resolves a friendly name via CameraModel
            const QString iso = o.value("start_time").toString();
            const QDateTime dt = QDateTime::fromString(iso, Qt::ISODate);
            e.time = dt.isValid() ? dt.toLocalTime().toString("HH:mm:ss") : iso;
            e.desc = descForType(e.type, o.value("duration_ms").toVariant().toLongLong());
            out.push_back(e);
        }
        beginResetModel();
        m_all = out;
        applyAcks();                       // restore locally-persisted acknowledgements
        endResetModel();
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
    for (int i = 0; i < m_all.size(); ++i)
        if (m_all[i].id == id) {
            acknowledge(i, AuthController::instance()->username());  // by the signed-in operator
            return;
        }
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
