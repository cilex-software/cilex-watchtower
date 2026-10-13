#pragma once

#include <QAbstractListModel>
#include <QtQml/qqmlregistration.h>
#include <QVector>
#include <QVariantList>
#include <QVariantMap>
#include "Types.h"

// Reusable Live Monitor layouts (Saved Views, design §4). These are a
// Watchtower-local concept (cilex-vision has no "views"), persisted in QSettings.
// A view stores the restorable Live Monitor state (layout/filter/group); the
// screen computes per-view camera counts live from CameraModel. The mock set is
// shown only under WT_DEMO and is never persisted.
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
        FavoriteRole,
        LayoutRole,
        StatusFilterRole,
        SortModeRole,
        GroupIdRole,
        GroupLabelRole,
        LastUsedIsoRole,
        SpansRole,          // merged cells captured at save time — see SavedViewData::spans
        HasCellsRole,
        CellsRole,
    };

    explicit SavedViewModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int total() const { return int(m_all.size()); }

    // All views as maps (for the screen, which filters in QML).
    Q_INVOKABLE QVariantList list() const;
    // Capture the current Live Monitor state as a new view (prepended).
    // `spans` is the merged-cell JSON as LiveMonitor holds it ({cols, rows,
    // regions:[...]}), or "" when nothing is merged. Captured INTO the view rather
    // than left in the global Settings key, which could not tell two views over the
    // same group+layout apart — see SavedViewData::spans.
    Q_INVOKABLE void saveCurrent(const QString &name, bool shared, const QString &layout,
                                 const QString &statusFilter, const QString &sortMode,
                                 const QString &groupId, const QString &groupLabel,
                                 const QString &spans = QString(),
                                 bool hasCells = false, const QStringList &cells = {});
    Q_INVOKABLE void remove(const QString &id);
    Q_INVOKABLE void touch(const QString &id);          // mark just-opened
    Q_INVOKABLE void toggleFavorite(const QString &id);

signals:
    void changed();

private:
    void load();
    void persist() const;
    int indexOfId(const QString &id) const;
    QVariantMap toMap(const wt::SavedViewData &v) const;

    QVector<wt::SavedViewData> m_all;
};
