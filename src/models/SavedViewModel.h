#pragma once

#include <QAbstractListModel>
#include <QtQml/qqmlregistration.h>
#include <QVector>
#include "Types.h"

// Reusable monitoring layouts (Mine / Shared). MVP supports open/duplicate/
// delete and "save current view"; no full drag-and-drop editor (design §18).
class SavedViewModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int total READ total NOTIFY changed)

public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        NameRole,
        SharedRole,
        CountRole,
        LayoutRole,
        OkRole,
        IssueRole,
        LastUsedRole,
    };

    explicit SavedViewModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int total() const { return int(m_all.size()); }

signals:
    void changed();

private:
    QVector<wt::SavedViewData> m_all;
};
