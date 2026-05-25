#include "CameraModel.h"

#include "CameraStatus.h"
#include "MockData.h"
#include "ProvisioningImport.h"

#include <QDebug>
#include <algorithm>

CameraModel::CameraModel(QObject *parent)
    : QAbstractListModel(parent)
{
    // Load a Cilex Vision Provisioner export if WT_CAMERAS points at one;
    // otherwise fall back to the mock dataset.
    const QString prov = qEnvironmentVariable("WT_CAMERAS");
    if (!prov.isEmpty()) {
        const wt::ProvisioningResult res = wt::importProvisioning(prov);
        if (res.ok && !res.cameras.isEmpty()) {
            m_all = res.cameras;
            recompute();
            return;
        }
        qWarning() << "Watchtower: provisioning import failed —" << res.error;
    }
    m_all = wt::mock::cameras();
    recompute();
}

bool CameraModel::loadProvisioning(const QString &path)
{
    const wt::ProvisioningResult res = wt::importProvisioning(path);
    if (!res.ok || res.cameras.isEmpty()) {
        qWarning() << "Watchtower: provisioning import failed —" << res.error;
        return false;
    }
    beginResetModel();
    m_all = res.cameras;
    endResetModel();
    recompute();
    return true;
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
