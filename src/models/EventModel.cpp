#include "EventModel.h"

#include "MockData.h"

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
// Human description from the event type (+ duration for gaps). Unknown types
// fall back to the type itself, capitalized — we never invent a description.
QString descForType(const QString &type, qint64 durMs)
{
    if (type == "motion")   return QStringLiteral("Motion detected");
    if (type == "offline")  return QStringLiteral("Camera went offline");
    if (type == "online")   return QStringLiteral("Camera back online");
    if (type == "bookmark") return QStringLiteral("Bookmark");
    if (type == "gap")
        return durMs > 0 ? QStringLiteral("Recording gap (%1s)").arg(durMs / 1000)
                         : QStringLiteral("Recording gap");
    if (type.isEmpty()) return QStringLiteral("Event");
    return type.left(1).toUpper() + type.mid(1);
}
}

EventModel::EventModel(QObject *parent)
    : QAbstractListModel(parent)
{
    const auto env = QProcessEnvironment::systemEnvironment();
    m_baseUrl = env.value("WT_CV_URL", "http://192.168.1.79:8000");
    m_user = env.value("WT_CV_USER", "admin");
    m_pass = env.value("WT_CV_PASS", "admin");
    m_nam = new QNetworkAccessManager(this);

    if (qEnvironmentVariableIsSet("WT_DEMO")) {
        m_all = wt::mock::events();
        applyAcks();
    } else {
        // Live events from cilex-vision; the list stays empty (honest) until the
        // feed has events or until login/fetch completes. Fully async.
        refresh();
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

void EventModel::refresh()
{
    if (qEnvironmentVariableIsSet("WT_DEMO") || m_loading)
        return;
    m_loading = true;
    emit changed();
    if (m_loggedIn)
        fetchEvents();
    else
        login();
}

void EventModel::login()
{
    QNetworkRequest req{QUrl(m_baseUrl + "/auth/login")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonObject body{{"username", m_user}, {"password", m_pass}};
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() != QNetworkReply::NoError || code != 200) {
            m_loading = false;             // leave the list empty on failure (honest)
            emit changed();
            return;
        }
        m_loggedIn = true;                 // cookie stored in this model's jar
        fetchEvents();
    });
}

void EventModel::fetchEvents()
{
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/events?limit=200")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
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
            acknowledge(i, m_user);        // acknowledged by the logged-in operator
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
