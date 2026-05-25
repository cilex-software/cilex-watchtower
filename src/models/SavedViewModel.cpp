#include "SavedViewModel.h"

#include "MockData.h"

SavedViewModel::SavedViewModel(QObject *parent)
    : QAbstractListModel(parent)
{
    m_all = wt::mock::savedViews();
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
    case IdRole:       return v.id;
    case NameRole:     return v.name;
    case SharedRole:   return v.shared;
    case CountRole:    return v.count;
    case LayoutRole:   return v.layout;
    case OkRole:       return v.okCount;
    case IssueRole:    return v.issueCount;
    case LastUsedRole: return v.lastUsed;
    default:           return {};
    }
}

QHash<int, QByteArray> SavedViewModel::roleNames() const
{
    return {
        { IdRole,       "viewId" },
        { NameRole,     "name" },
        { SharedRole,   "shared" },
        { CountRole,    "count" },
        { LayoutRole,   "layout" },
        { OkRole,       "okCount" },
        { IssueRole,    "issueCount" },
        { LastUsedRole, "lastUsed" },
    };
}
