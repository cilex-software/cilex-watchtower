#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>

// Small helper for where exported artifacts (snapshots now; clips later) live.
// Phase 1 stub: snapshots are written under <Pictures>/Watchtower; the full
// Clips & Snapshots library (S07) lands in a later phase.
class Artifacts : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit Artifacts(QObject *parent = nullptr);

    Q_INVOKABLE QString snapshotDir() const;
    Q_INVOKABLE QString newSnapshotPath(const QString &camId) const;
};
