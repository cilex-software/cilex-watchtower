#pragma once

#include <QObject>
#include <QSettings>
#include <QtQml/qqmlregistration.h>

// Where exported artifacts (snapshots now; clips later) are saved. The snapshot
// directory is a persisted, user-configurable setting (Preferences); it defaults
// to <Pictures>/Watchtower.
class Artifacts : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QString snapshotDir READ snapshotDir WRITE setSnapshotDir NOTIFY snapshotDirChanged)

public:
    explicit Artifacts(QObject *parent = nullptr);

    QString snapshotDir() const;             // effective dir (configured or default), ensured to exist
    void setSnapshotDir(const QString &dir); // accepts a path or a file:// URL
    Q_INVOKABLE QString defaultSnapshotDir() const;
    Q_INVOKABLE QString newSnapshotPath(const QString &camId) const;

signals:
    void snapshotDirChanged();

private:
    QSettings m_settings;
};
