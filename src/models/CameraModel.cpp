#include "CameraModel.h"

#include "CameraStatus.h"
#include "MockData.h"
#include "AuthController.h"

#include <QDebug>
#include <QUrl>
#include <QUuid>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QPair>
#include <QStringList>
#include <QSettings>
#include <algorithm>

namespace {
// Numeric sort key for an IPv4 string so 192.168.1.2 < 192.168.1.10 (octet-aware).
// Invalid/empty addresses sort last.
quint32 ipSortKey(const QString &ip)
{
    const QStringList parts = ip.split(QLatin1Char('.'));
    if (parts.size() != 4)
        return 0xFFFFFFFFu;
    quint32 key = 0;
    for (const QString &octet : parts) {
        bool ok = false;
        const uint v = octet.toUInt(&ok);
        if (!ok || v > 255)
            return 0xFFFFFFFFu;
        key = (key << 8) | (v & 0xFFu);
    }
    return key;
}
}

CameraModel::CameraModel(QObject *parent)
    : QAbstractListModel(parent)
{
    // WT_DEMO shows the mock dataset (development only).
    if (qEnvironmentVariableIsSet("WT_DEMO")) {
        m_all = wt::mock::cameras();
        recompute();
        return;
    }

    if (m_store.open()) {
        // The local store now holds only per-operator prefs (display-name override
        // + favorite), keyed by the backend camera_id.
        m_prefs = m_store.prefs();
    } else {
        qWarning() << "Watchtower: prefs store unavailable (name/favorite overrides won't persist)";
    }

    // cilex-vision /streams is the AUTHORITATIVE camera list — server-scoped, with
    // real online/offline + group membership, reached once the operator signs in.
    // The wall stays empty (LoadingState) until the first fetch returns; the app
    // is auth-gated so this gap is brief.
    auto *auth = AuthController::instance();
    m_nam = auth->nam();
    m_baseUrl = auth->baseUrl();
    connect(auth, &AuthController::baseUrlChanged, this,
            [this, auth]() { m_baseUrl = auth->baseUrl(); });
    // Periodic /streams refresh — industry-standard VMS status cadence so the
    // recording badge + online/offline reflect reality without flooding the
    // backend. Started on authentication, stopped on logout.
    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(15 * 1000);   // 15s
    connect(m_pollTimer, &QTimer::timeout, this, [this]() { pollStatuses(); });

    connect(auth, &AuthController::authenticatedChanged, this, [this, auth]() {
        if (auth->authenticated()) {
            fetchGroups();
            fetchCameras();
            m_pollTimer->start();
        } else {
            m_pollTimer->stop();
            beginResetModel();
            m_all.clear();
            endResetModel();
            m_groups.clear();
            recompute();
            emit groupsChanged();
        }
    });
    if (auth->authenticated()) {
        fetchGroups();
        fetchCameras();
        m_pollTimer->start();
    }
}

void CameraModel::setLoading(bool v)
{
    if (m_loading == v)
        return;
    m_loading = v;
    emit loadingChanged();
}

void CameraModel::setCameraScope(const QStringList &)
{
    // No-op: /streams is server-scoped, so the backend already returns exactly the
    // operator's cameras. Kept for QML call-site compatibility; a scope change
    // rides in on a fresh token (re-login triggers a refetch).
}

void CameraModel::setCameraName(const QString &cameraId, const QString &name)
{
    // Local per-operator display-name override (layered over the backend name).
    m_store.setDisplayName(cameraId, name);
    m_prefs[cameraId].first = name;
    for (int i = 0; i < m_all.size(); ++i) {
        if (m_all[i].id == cameraId) {
            m_all[i].name = name;
            emit dataChanged(index(i), index(i), { NameRole });
            return;
        }
    }
}

void CameraModel::setCameraGroup(const QString &cameraId, const QString &groupId)
{
    if (!m_nam || cameraId.isEmpty())
        return;
    QString currentGid;
    for (const wt::CameraData &c : m_all)
        if (c.id == cameraId) { currentGid = c.groupId; break; }

    QNetworkReply *reply = nullptr;
    if (!groupId.isEmpty()) {
        reply = m_nam->put(
            QNetworkRequest{QUrl(m_baseUrl + "/groups/" + groupId + "/cameras/" + cameraId)},
            QByteArray());
    } else if (!currentGid.isEmpty()) {
        reply = m_nam->deleteResource(
            QNetworkRequest{QUrl(m_baseUrl + "/groups/" + currentGid + "/cameras/" + cameraId)});
    } else {
        return;   // already ungrouped
    }

    connect(reply, &QNetworkReply::finished, this, [this, reply, cameraId, groupId]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) { AuthController::instance()->noteUnauthorized(); return; }
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Watchtower: group assignment failed" << code << reply->errorString();
            return;
        }
        QString gname;
        for (const wt::GroupData &g : m_groups)
            if (g.id == groupId) { gname = g.name; break; }
        for (int i = 0; i < m_all.size(); ++i) {
            if (m_all[i].id == cameraId) {
                m_all[i].groupId = groupId;
                m_all[i].groupName = gname;
                emit dataChanged(index(i), index(i), { GroupIdRole, GroupNameRole });
                break;
            }
        }
        emit groupsChanged();
        emit countsChanged();   // refresh group-filtered grid/counts bindings
    });
}

QVariantList CameraModel::groupList() const
{
    QVariantList out;
    for (const wt::GroupData &g : m_groups) {
        QVariantMap m;
        m["id"] = g.id;
        m["name"] = g.name;
        m["parentId"] = QString();
        m["total"] = countFiltered(g.id, QString());
        m["online"] = countFiltered(g.id, QStringLiteral("online"));
        m["offline"] = countFiltered(g.id, QStringLiteral("offline"));
        m["notRec"] = countFiltered(g.id, QStringLiteral("notrec"));
        out.push_back(m);
    }
    return out;
}

void CameraModel::createGroup(const QString &name)
{
    if (!m_nam)
        return;
    QNetworkRequest req{QUrl(m_baseUrl + "/groups")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    const QJsonObject body{{"name", name}};
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) { AuthController::instance()->noteUnauthorized(); return; }
        if (code != 201) {
            qWarning() << "Watchtower: create group failed" << code;
            return;
        }
        const QString id =
            QJsonDocument::fromJson(reply->readAll()).object().value("group_id").toString();
        fetchGroups();           // refresh the list (emits groupsChanged)
        emit groupCreated(id);
    });
}

void CameraModel::renameGroup(const QString &id, const QString &name)
{
    if (!m_nam)
        return;
    QNetworkRequest req{QUrl(m_baseUrl + "/groups/" + id)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    const QJsonObject body{{"name", name}};
    QNetworkReply *reply =
        m_nam->sendCustomRequest(req, "PATCH", QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) { AuthController::instance()->noteUnauthorized(); return; }
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Watchtower: rename group failed" << code;
            return;
        }
        fetchGroups();
    });
}

void CameraModel::removeGroup(const QString &id)
{
    if (!m_nam)
        return;
    QNetworkReply *reply =
        m_nam->deleteResource(QNetworkRequest{QUrl(m_baseUrl + "/groups/" + id)});
    connect(reply, &QNetworkReply::finished, this, [this, reply, id]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) { AuthController::instance()->noteUnauthorized(); return; }
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Watchtower: delete group failed" << code;
            return;
        }
        // Backend SET NULL'd the members; mirror that locally.
        for (int i = 0; i < m_all.size(); ++i) {
            if (m_all[i].groupId == id) {
                m_all[i].groupId.clear();
                m_all[i].groupName.clear();
                emit dataChanged(index(i), index(i), { GroupIdRole, GroupNameRole });
            }
        }
        fetchGroups();
        emit countsChanged();
    });
}

void CameraModel::fetchGroups()
{
    if (!m_nam)
        return;
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/groups")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) { AuthController::instance()->noteUnauthorized(); return; }
        if (reply->error() != QNetworkReply::NoError)
            return;
        const auto arr =
            QJsonDocument::fromJson(reply->readAll()).object().value("groups").toArray();
        m_groups.clear();
        for (const auto &v : arr) {
            const auto o = v.toObject();
            wt::GroupData g;
            g.id = o.value("group_id").toString();
            g.name = o.value("name").toString();
            g.count = o.value("camera_count").toInt();
            m_groups.push_back(g);
        }
        emit groupsChanged();
    });
}

void CameraModel::fetchCameras()
{
    if (!m_nam)
        return;
    setLoading(true);
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/streams")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        setLoading(false);
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) { AuthController::instance()->noteUnauthorized(); return; }
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Watchtower: /streams fetch failed" << code << reply->errorString();
            return;   // keep the last-known list
        }
        const auto arr =
            QJsonDocument::fromJson(reply->readAll()).object().value("streams").toArray();

        QVector<wt::CameraData> out;
        out.reserve(int(arr.size()));
        // Admin-selectable transport (default go2rtc); only an admin client ever
        // receives the raw direct_rtsp_* fields, so non-admins always get go2rtc.
        const QString liveTransport = QSettings().value(QStringLiteral("video/liveTransport"),
                                                        QStringLiteral("go2rtc")).toString();
        for (const auto &v : arr) {
            const auto o = v.toObject();
            const QString camId = o.value("camera_id").toString();
            if (camId.isEmpty())
                continue;

            wt::CameraData c;
            c.id = camId;                           // identity = backend camera_id
            c.ip = o.value("ip").toString();
            c.groupId = o.value("group_id").toString();
            c.groupName = o.value("group_name").toString();

            const QString st = o.value("status").toString();
            c.live = (st == QLatin1String("online"))  ? CameraStatus::Live
                   : (st == QLatin1String("offline")) ? CameraStatus::Offline
                   : (st == QLatin1String("maintenance") || st == QLatin1String("error"))
                                                        ? CameraStatus::Degraded
                                                        : CameraStatus::LiveUnknown;
            // D6 (pending backend): /streams will start carrying a `recording`
            // field per camera. Parsed forward-compatibly here — when the field
            // is absent (today) every tile stays "REC ?" (Unknown), but the
            // moment the backend ships it the badges go truthful with no client
            // change beyond this parse.
            const QString rec = o.value(QStringLiteral("recording")).toString();
            c.recording = (rec == QLatin1String("recording"))     ? CameraStatus::Recording
                        : (rec == QLatin1String("not_recording")) ? CameraStatus::NotRecording
                        : (rec == QLatin1String("recording_gap")) ? CameraStatus::RecordingGap
                                                                  : CameraStatus::RecUnknown;

            // D1/D5: connection config from /streams. Default = go2rtc restream URLs;
            // an admin client may also receive raw direct_rtsp_* and select them via
            // the liveTransport preference.
            const QString go2rtcUrl    = o.value("rtsp_url").toString();
            const QString go2rtcSubUrl = o.value("rtsp_sub_url").toString();
            const QString directUrl    = o.value("direct_rtsp_url").toString();
            const QString directSubUrl = o.value("direct_rtsp_sub_url").toString();
            if (liveTransport == QLatin1String("rtsp") && !directUrl.isEmpty()) {
                c.rtspUrl = directUrl;
                if (!directSubUrl.isEmpty()) c.rtspSubUrl = directSubUrl;
            } else if (!go2rtcUrl.isEmpty()) {
                c.rtspUrl = go2rtcUrl;
                if (!go2rtcSubUrl.isEmpty()) c.rtspSubUrl = go2rtcSubUrl;
            }
            // D2: identity metadata from /streams.
            { const QString s = o.value("mac").toString();      if (!s.isEmpty()) c.mac = s; }
            { const QString s = o.value("vendor").toString();   if (!s.isEmpty()) c.vendor = s; }
            { const QString s = o.value("model").toString();    if (!s.isEmpty()) c.model = s; }
            { const QString s = o.value("firmware").toString(); if (!s.isEmpty()) c.firmware = s; }

            // Name: operator override (prefs) layered over the backend name.
            const auto pit = m_prefs.constFind(camId);
            const QString nameOverride = (pit != m_prefs.constEnd()) ? pit->first : QString();
            c.name = !nameOverride.isEmpty() ? nameOverride : o.value("name").toString();
            // Favorite: prefs if set, else the legacy local seed already on `c`.
            if (pit != m_prefs.constEnd())
                c.favorite = pit->second;

            out.push_back(c);
        }

        beginResetModel();
        m_all = out;
        endResetModel();
        recompute();
        emit groupsChanged();   // group counts derive from the refreshed list
    });
}

void CameraModel::pollStatuses()
{
    // Periodic refresh of live + recording status only. Crucial: this MUST NOT
    // reset the model — beginResetModel() destroys every Repeater delegate,
    // which destroys every CameraTile → VideoSurface → RTSP pipeline; doing
    // that every 15s would flicker the wall and re-establish 16 RTSP sessions
    // each tick. Instead, patch m_all in place and emit dataChanged for the
    // affected rows + roles so QML bindings re-evaluate without delegate churn.
    if (!m_nam)
        return;
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/streams")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) { AuthController::instance()->noteUnauthorized(); return; }
        if (reply->error() != QNetworkReply::NoError)
            return;   // transient — keep the last-known statuses
        const auto arr =
            QJsonDocument::fromJson(reply->readAll()).object().value("streams").toArray();

        // Build {camera_id -> {live, recording}} from the response.
        QHash<QString, QPair<CameraStatus::LiveState, CameraStatus::RecState>> incoming;
        incoming.reserve(int(arr.size()));
        for (const auto &v : arr) {
            const auto o = v.toObject();
            const QString camId = o.value("camera_id").toString();
            if (camId.isEmpty()) continue;
            const QString st = o.value("status").toString();
            const auto live = (st == QLatin1String("online"))  ? CameraStatus::Live
                            : (st == QLatin1String("offline")) ? CameraStatus::Offline
                            : (st == QLatin1String("maintenance") || st == QLatin1String("error"))
                                                                 ? CameraStatus::Degraded
                                                                 : CameraStatus::LiveUnknown;
            const QString rec = o.value(QStringLiteral("recording")).toString();
            const auto recState = (rec == QLatin1String("recording"))     ? CameraStatus::Recording
                                : (rec == QLatin1String("not_recording")) ? CameraStatus::NotRecording
                                : (rec == QLatin1String("recording_gap")) ? CameraStatus::RecordingGap
                                                                          : CameraStatus::RecUnknown;
            incoming.insert(camId, { live, recState });
        }

        // Patch matched rows in place; emit dataChanged once per changed row so
        // tile bindings (live badge, REC badge) refresh without delegate teardown.
        bool anyChanged = false;
        for (int i = 0; i < m_all.size(); ++i) {
            const auto it = incoming.constFind(m_all[i].id);
            if (it == incoming.constEnd()) continue;
            const auto newLive = it->first;
            const auto newRec  = it->second;
            if (m_all[i].live == newLive && m_all[i].recording == newRec) continue;
            m_all[i].live = newLive;
            m_all[i].recording = newRec;
            anyChanged = true;
            const QModelIndex idx = index(i);
            emit dataChanged(idx, idx, { LiveRole, RecordingRole });
        }
        if (anyChanged)
            recompute();   // refresh TopBar counts (online / offline / not-rec)
    });
}

int CameraModel::rowCount(const QModelIndex &parent) const
{
    if (parent.isValid())
        return 0;
    return int(m_all.size());
}

QVariant CameraModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_all.size())
        return {};

    const wt::CameraData &c = m_all.at(index.row());
    switch (role) {
    case IdRole:        return c.id;
    case NameRole:      return c.name;
    case GroupIdRole:   return c.groupId;
    case GroupNameRole: return c.groupName;
    case LiveRole:      return c.live;
    case RecordingRole: return c.recording;
    case HasAudioRole:  return c.hasAudio;
    case FavoriteRole:  return c.favorite;
    case TimestampRole: return c.timestamp;
    case LastSeenRole:  return c.lastSeen;
    case PatternRole:   return c.pattern;
    case RtspUrlRole:    return c.rtspUrl;
    case RtspSubUrlRole: return c.rtspSubUrl;
    case IpRole:         return c.ip;
    case MacRole:       return c.mac;
    case ModelRole:     return c.model;
    case VendorRole:    return c.vendor;
    case FirmwareRole:  return c.firmware;
    default:            return {};
    }
}

QHash<int, QByteArray> CameraModel::roleNames() const
{
    // "camId" rather than "id" to avoid clashing with QML's item id in delegates.
    return {
        { IdRole,        "camId" },
        { NameRole,      "name" },
        { GroupIdRole,   "groupId" },
        { GroupNameRole, "groupName" },
        { LiveRole,      "live" },
        { RecordingRole, "recording" },
        { HasAudioRole,  "hasAudio" },
        { FavoriteRole,  "favorite" },
        { TimestampRole, "timestamp" },
        { LastSeenRole,  "lastSeen" },
        { PatternRole,   "pattern" },
        { RtspUrlRole,    "rtspUrl" },
        { RtspSubUrlRole, "rtspSubUrl" },
        { IpRole,         "ip" },
        { MacRole,       "mac" },
        { ModelRole,     "model" },
        { VendorRole,    "vendor" },
        { FirmwareRole,  "firmware" },
    };
}

QVariantMap CameraModel::get(int row) const
{
    QVariantMap m;
    if (row < 0 || row >= m_all.size())
        return m;
    const wt::CameraData &c = m_all.at(row);
    m["camId"] = c.id;
    m["name"] = c.name;
    m["groupId"] = c.groupId;
    m["groupName"] = c.groupName;
    m["live"] = c.live;
    m["recording"] = c.recording;
    m["hasAudio"] = c.hasAudio;
    m["favorite"] = c.favorite;
    m["timestamp"] = c.timestamp;
    m["lastSeen"] = c.lastSeen;
    m["pattern"] = c.pattern;
    m["rtspUrl"] = c.rtspUrl;
    m["rtspSubUrl"] = c.rtspSubUrl;
    m["ip"] = c.ip;
    m["mac"] = c.mac;
    m["model"] = c.model;
    m["vendor"] = c.vendor;
    m["firmware"] = c.firmware;
    return m;
}

QVariantMap CameraModel::cameraByBackendId(const QString &cameraId) const
{
    // Identity is now the backend camera_id — direct match.
    for (int i = 0; i < m_all.size(); ++i)
        if (m_all.at(i).id == cameraId)
            return get(i);
    return {};
}

bool CameraModel::matches(const wt::CameraData &c, const QString &groupId, const QString &f) const
{
    if (!groupId.isEmpty() && c.groupId != groupId)
        return false;
    if (f.isEmpty() || f == QLatin1String("all"))
        return true;
    if (f == QLatin1String("online"))    return c.live == CameraStatus::Live;
    if (f == QLatin1String("offline"))   return c.live == CameraStatus::Offline;
    if (f == QLatin1String("degraded"))  return c.live == CameraStatus::Degraded;
    if (f == QLatin1String("recording")) return c.recording == CameraStatus::Recording;
    if (f == QLatin1String("notrec"))    return c.recording == CameraStatus::NotRecording;
    if (f == QLatin1String("gap"))       return c.recording == CameraStatus::RecordingGap;
    if (f == QLatin1String("favorites")) return c.favorite;
    if (f == QLatin1String("issues") || f == QLatin1String("recent"))
        return c.live == CameraStatus::Offline || c.live == CameraStatus::Degraded
            || c.recording == CameraStatus::NotRecording || c.recording == CameraStatus::RecordingGap;
    return true;
}

static int statusRank(const wt::CameraData &c)
{
    if (c.live == CameraStatus::Offline) return 0;
    if (c.recording == CameraStatus::NotRecording) return 1;
    if (c.live == CameraStatus::Degraded) return 2;
    if (c.recording == CameraStatus::RecordingGap) return 3;
    return 4;
}

QVector<int> CameraModel::filteredSorted(const QString &groupId, const QString &f,
                                         const QString &sortMode) const
{
    QVector<int> idx;
    idx.reserve(m_all.size());
    for (int i = 0; i < m_all.size(); ++i)
        if (matches(m_all.at(i), groupId, f))
            idx.push_back(i);

    if (sortMode == QLatin1String("alpha")) {
        std::stable_sort(idx.begin(), idx.end(), [this](int a, int b) {
            return m_all.at(a).name.localeAwareCompare(m_all.at(b).name) < 0;
        });
    } else if (sortMode == QLatin1String("status")) {
        std::stable_sort(idx.begin(), idx.end(), [this](int a, int b) {
            const int ra = statusRank(m_all.at(a));
            const int rb = statusRank(m_all.at(b));
            if (ra != rb)
                return ra < rb;
            return m_all.at(a).name.localeAwareCompare(m_all.at(b).name) < 0;
        });
    } else if (sortMode == QLatin1String("ip")) {
        std::stable_sort(idx.begin(), idx.end(), [this](int a, int b) {
            const quint32 ka = ipSortKey(m_all.at(a).ip);
            const quint32 kb = ipSortKey(m_all.at(b).ip);
            if (ka != kb)
                return ka < kb;
            return m_all.at(a).name.localeAwareCompare(m_all.at(b).name) < 0;
        });
    }
    return idx;
}

int CameraModel::countFiltered(const QString &groupId, const QString &statusFilter) const
{
    return int(filteredSorted(groupId, statusFilter, QStringLiteral("default")).size());
}

QVariantList CameraModel::page(const QString &groupId, const QString &statusFilter,
                               const QString &sortMode, int pageNum, int pageSize) const
{
    QVariantList out;
    if (pageSize <= 0)
        return out;
    const QVector<int> idx = filteredSorted(groupId, statusFilter, sortMode);
    const int start = qMax(0, (pageNum - 1) * pageSize);
    const int end = qMin(int(idx.size()), start + pageSize);
    for (int i = start; i < end; ++i)
        out.push_back(get(idx.at(i)));
    return out;
}

void CameraModel::toggleFavorite(int row)
{
    if (row < 0 || row >= m_all.size())
        return;
    m_all[row].favorite = !m_all[row].favorite;
    const QString camId = m_all[row].id;
    m_store.setFavoritePref(camId, m_all[row].favorite);
    m_prefs[camId].second = m_all[row].favorite;
    emit dataChanged(index(row), index(row), { FavoriteRole });
}

void CameraModel::recompute()
{
    m_online = m_offline = m_degraded = 0;
    m_recording = m_notRecording = m_recUnknown = m_gap = 0;

    for (const wt::CameraData &c : m_all) {
        switch (c.live) {
        case CameraStatus::Live:     ++m_online;   break;
        case CameraStatus::Offline:  ++m_offline;  break;
        case CameraStatus::Degraded: ++m_degraded; break;
        default: break;
        }
        switch (c.recording) {
        case CameraStatus::Recording:    ++m_recording;    break;
        case CameraStatus::NotRecording: ++m_notRecording; break;
        case CameraStatus::RecUnknown:   ++m_recUnknown;   break;
        case CameraStatus::RecordingGap: ++m_gap;          break;
        default: break;
        }
    }
    emit countsChanged();
}
