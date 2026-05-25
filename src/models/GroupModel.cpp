#include "GroupModel.h"

#include "MockData.h"

GroupModel::GroupModel(QObject *parent)
    : QAbstractListModel(parent)
{
    m_all = wt::mock::groups();
}

int GroupModel::rowCount(const QModelIndex &parent) const
{
    if (parent.isValid())
        return 0;
    return int(m_all.size());
}

QVariant GroupModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_all.size())
        return {};

    const wt::GroupData &g = m_all.at(index.row());
    switch (role) {
    case IdRole:       return g.id;
    case NameRole:     return g.name;
    case ParentIdRole: return g.parentId;
    case LevelRole:    return g.level;
    case CountRole:    return g.count;
    default:           return {};
    }
}

QHash<int, QByteArray> GroupModel::roleNames() const
{
    return {
        { IdRole,       "gid" },
        { NameRole,     "name" },
        { ParentIdRole, "parentId" },
        { LevelRole,    "level" },
        { CountRole,    "count" },
    };
}
