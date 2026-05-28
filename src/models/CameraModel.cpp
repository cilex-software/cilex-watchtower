#include "CameraModel.h"

#include "CameraStatus.h"
#include "MockData.h"
#include "ProvisioningImport.h"

#include <QDebug>
#include <QUrl>
#include <QUuid>
#include <algorithm>

CameraModel::CameraModel(QObject *parent)
    : QAbstractListModel(parent)
{
    // WT_DEMO shows the mock dataset (development only). Otherwise the persistent
    // store is the source of truth — the operator's real cameras.
    if (qEnvironmentVariableIsSet("WT_DEMO")) {
        m_all = wt::mock::cameras();
        recompute();
        return;
    }
    if (m_store.open()) {
        // Bootstrap: if the store is empty and WT_CAMERAS points at an export,
        // import it once; thereafter the store loads directly (no env var).
        const QString prov = qEnvironmentVariable("WT_CAMERAS");
        if (m_store.isEmpty() && !prov.isEmpty())
            m_store.importProvisioning(prov);
        m_all = m_store.cameras();
    } else {
        qWarning() << "Watchtower: camera store unavailable; starting with no cameras";
    }
    recompute();
}

bool CameraModel::importProvisioning(const QString &path)
{
    // Accept a file:// URL (from the QML FileDialog) or a plain path.
    const QString local = path.startsWith(QLatin1String("file:")) ? QUrl(path).toLocalFile() : path;
    QString err;
    if (m_store.importProvisioning(local, &err) < 0) {
        qWarning() << "Watchtower: provisioning import failed —" << err;
        return false;
    }
    reload();
    return true;
}

void CameraModel::reload()
{
    beginResetModel();
    m_all = m_store.cameras();
    endResetModel();
    recompute();
}

void CameraModel::setCameraName(const QString &mac, const QString &name)
{
    m_store.setName(mac, name);
    for (int i = 0; i < m_all.size(); ++i) {
        if (m_all[i].mac == mac) {
            m_all[i].name = name;
            emit dataChanged(index(i), index(i), { NameRole });
            return;
        }
    }
}

void CameraModel::setCameraGroup(const QString &mac, const QString &groupId)
{
    m_store.setGroup(mac, groupId);
    reload();   // refresh resolved group names + counts
    emit groupsChanged();
}

QVariantList CameraModel::groupList() const
{
    QVariantList out;
    const QVector<wt::GroupData> gs = m_store.groups();
    for (const wt::GroupData &g : gs) {
        QVariantMap m;
        m["id"] = g.id;
        m["name"] = g.name;
        m["parentId"] = g.parentId;
        m["total"] = countFiltered(g.id, QString());
        m["online"] = countFiltered(g.id, QStringLiteral("online"));
        m["offline"] = countFiltered(g.id, QStringLiteral("offline"));
        m["notRec"] = countFiltered(g.id, QStringLiteral("notrec"));
        out.push_back(m);
    }
    return out;
}

QString CameraModel::createGroup(const QString &name)
{
    wt::GroupData g;
    g.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    g.name = name;
    m_store.upsertGroup(g);
    emit groupsChanged();
    return g.id;
}

void CameraModel::renameGroup(const QString &id, const QString &name)
{
    wt::GroupData g;
    g.id = id;
    g.name = name;
    m_store.upsertGroup(g);
    emit groupsChanged();
}

void CameraModel::removeGroup(const QString &id)
{
    m_store.removeGroup(id);
    reload();
    emit groupsChanged();
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
    // Backend camera_id is "<vendor-slug>-<machex>"; match the trailing MAC hex
    // against a local camera's MAC (normalized: lowercase, no separators).
    const int dash = cameraId.lastIndexOf('-');
    QString hex = (dash >= 0 ? cameraId.mid(dash + 1) : cameraId).toLower();
    if (hex.isEmpty())
        return {};
    for (int i = 0; i < m_all.size(); ++i) {
        QString mac = m_all.at(i).mac.toLower();
        mac.remove(':').remove('-');
        if (!mac.isEmpty() && mac == hex)
            return get(i);
    }
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
    m_store.setFavorite(m_all[row].mac, m_all[row].favorite);
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
