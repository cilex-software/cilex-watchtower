#include "SavedViewModel.h"

#include "MockData.h"

#include <QSettings>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QDateTime>
#include <QUuid>

SavedViewModel::SavedViewModel(QObject *parent)
    : QAbstractListModel(parent)
{
    load();
}

void SavedViewModel::load()
{
    m_all.clear();
    QSettings s;
    const QByteArray raw = s.value("savedViews").toByteArray();
    const QJsonArray arr = QJsonDocument::fromJson(raw).array();
    for (const auto &v : arr) {
        const auto o = v.toObject();
        wt::SavedViewData d;
        d.id = o.value("id").toString();
        d.name = o.value("name").toString();
        d.shared = o.value("shared").toBool();
        d.favorite = o.value("favorite").toBool();
        d.layout = o.value("layout").toString();
        if (d.layout.isEmpty())  // legacy views stored an int "layoutSize"
            d.layout = QString::number(o.value("layoutSize").toInt(16));
        d.statusFilter = o.value("statusFilter").toString();
        d.sortMode = o.value("sortMode").toString();
        if (d.sortMode.isEmpty()) d.sortMode = QStringLiteral("default");
        d.groupId = o.value("groupId").toString();
        d.groupLabel = o.value("groupLabel").toString();
        if (d.groupLabel.isEmpty()) d.groupLabel = QStringLiteral("All cameras");
        d.lastUsedIso = o.value("lastUsedIso").toString();
        m_all.push_back(d);
    }
    // Dev-only: seed the mock set when there are no real views (and only WT_DEMO).
    if (m_all.isEmpty() && qEnvironmentVariableIsSet("WT_DEMO"))
        m_all = wt::mock::savedViews();
}

void SavedViewModel::persist() const
{
    // Never persist the WT_DEMO mock set — it isn't the operator's real data.
    if (qEnvironmentVariableIsSet("WT_DEMO"))
        return;
    QJsonArray arr;
    for (const auto &d : m_all) {
        QJsonObject o;
        o["id"] = d.id;
        o["name"] = d.name;
        o["shared"] = d.shared;
        o["favorite"] = d.favorite;
        o["layout"] = d.layout;
        o["statusFilter"] = d.statusFilter;
        o["sortMode"] = d.sortMode;
        o["groupId"] = d.groupId;
        o["groupLabel"] = d.groupLabel;
        o["lastUsedIso"] = d.lastUsedIso;
        arr.append(o);
    }
    QSettings s;
    s.setValue("savedViews", QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

int SavedViewModel::indexOfId(const QString &id) const
{
    for (int i = 0; i < m_all.size(); ++i)
        if (m_all.at(i).id == id)
            return i;
    return -1;
}

int SavedViewModel::rowCount(const QModelIndex &parent) const
{
    if (parent.isValid())
        return 0;
    return int(m_all.size());
}

QVariant SavedViewModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_all.size())
        return {};
    const wt::SavedViewData &v = m_all.at(index.row());
    switch (role) {
    case IdRole:           return v.id;
    case NameRole:         return v.name;
    case SharedRole:       return v.shared;
    case FavoriteRole:     return v.favorite;
    case LayoutRole:       return v.layout;
    case StatusFilterRole: return v.statusFilter;
    case SortModeRole:     return v.sortMode;
    case GroupIdRole:      return v.groupId;
    case GroupLabelRole:   return v.groupLabel;
    case LastUsedIsoRole:  return v.lastUsedIso;
    default:               return {};
    }
}

QHash<int, QByteArray> SavedViewModel::roleNames() const
{
    return {
        { IdRole,           "viewId" },
        { NameRole,         "name" },
        { SharedRole,       "shared" },
        { FavoriteRole,     "favorite" },
        { LayoutRole,       "layout" },
        { StatusFilterRole, "statusFilter" },
        { SortModeRole,     "sortMode" },
        { GroupIdRole,      "groupId" },
        { GroupLabelRole,   "groupLabel" },
        { LastUsedIsoRole,  "lastUsedIso" },
    };
}

QVariantMap SavedViewModel::toMap(const wt::SavedViewData &v) const
{
    QVariantMap m;
    m["viewId"] = v.id;
    m["name"] = v.name;
    m["shared"] = v.shared;
    m["favorite"] = v.favorite;
    m["layout"] = v.layout;
    m["statusFilter"] = v.statusFilter;
    m["sortMode"] = v.sortMode;
    m["groupId"] = v.groupId;
    m["groupLabel"] = v.groupLabel;
    m["lastUsedIso"] = v.lastUsedIso;
    return m;
}

QVariantList SavedViewModel::list() const
{
    QVariantList out;
    out.reserve(m_all.size());
    for (const wt::SavedViewData &v : m_all)
        out.append(toMap(v));
    return out;
}

void SavedViewModel::saveCurrent(const QString &name, bool shared, const QString &layout,
                                 const QString &statusFilter, const QString &sortMode,
                                 const QString &groupId, const QString &groupLabel)
{
    wt::SavedViewData d;
    d.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    d.name = name.trimmed().isEmpty() ? QStringLiteral("Untitled view") : name.trimmed();
    d.shared = shared;
    d.favorite = false;
    d.layout = layout;
    d.statusFilter = statusFilter;
    d.sortMode = sortMode.isEmpty() ? QStringLiteral("default") : sortMode;
    d.groupId = groupId;
    d.groupLabel = groupLabel.isEmpty() ? QStringLiteral("All cameras") : groupLabel;
    d.lastUsedIso = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
    beginInsertRows({}, 0, 0);
    m_all.prepend(d);
    endInsertRows();
    persist();
    emit changed();
}

void SavedViewModel::remove(const QString &id)
{
    const int row = indexOfId(id);
    if (row < 0)
        return;
    beginRemoveRows({}, row, row);
    m_all.removeAt(row);
    endRemoveRows();
    persist();
    emit changed();
}

void SavedViewModel::touch(const QString &id)
{
    const int row = indexOfId(id);
    if (row < 0)
        return;
    m_all[row].lastUsedIso = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
    emit dataChanged(index(row), index(row), { LastUsedIsoRole });
    persist();
    emit changed();
}

void SavedViewModel::toggleFavorite(const QString &id)
{
    const int row = indexOfId(id);
    if (row < 0)
        return;
    m_all[row].favorite = !m_all[row].favorite;
    emit dataChanged(index(row), index(row), { FavoriteRole });
    persist();
    emit changed();
}
