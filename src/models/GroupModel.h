#pragma once

#include <QAbstractListModel>
#include <QtQml/qqmlregistration.h>
#include <QVector>
#include "Types.h"

// The camera-group hierarchy (Site -> Building -> Floor -> Area). Flat list with
// a level role for indentation; parentId allows tree reconstruction in QML.
class GroupModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int total READ total CONSTANT)

public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        NameRole,
        ParentIdRole,
        LevelRole,
        CountRole,
    };

    explicit GroupModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int total() const { return int(m_all.size()); }

private:
    QVector<wt::GroupData> m_all;
};
