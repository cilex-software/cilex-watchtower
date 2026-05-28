#pragma once

#include <QObject>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>

// Enumerates locally-saved snapshots (the Artifacts snapshot dir) for the Clips &
// Snapshots library (design §8). Snapshots are the only artifacts Watchtower can
// list locally; server-side exported clips need a backend list endpoint (see
// docs/letters/watchtower-to-cilex-vision-api-requests.md §A6). Set `dir` to the
// Artifacts snapshot folder; it re-scans on change.
class SnapshotModel : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString dir READ dir WRITE setDir NOTIFY changed)
    Q_PROPERTY(int total READ total NOTIFY changed)

public:
    explicit SnapshotModel(QObject *parent = nullptr);

    QString dir() const { return m_dir; }
    void setDir(const QString &d);
    int total() const { return int(m_items.size()); }

    Q_INVOKABLE QVariantList all() const { return m_items; }   // newest first, as maps
    Q_INVOKABLE void refresh();

signals:
    void changed();

private:
    QString m_dir;
    QVariantList m_items;
};
