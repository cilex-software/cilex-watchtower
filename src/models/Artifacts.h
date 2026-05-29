#pragma once

#include <QObject>
#include <QSettings>
#include <QtQml/qqmlregistration.h>

// Where exported artifacts are saved. Both directories are persisted,
// user-configurable settings (Preferences): snapshots default to
// <Pictures>/Watchtower, exported clips to <Movies>/Watchtower.
class Artifacts : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QString snapshotDir READ snapshotDir WRITE setSnapshotDir NOTIFY snapshotDirChanged)
    Q_PROPERTY(QString exportDir READ exportDir WRITE setExportDir NOTIFY exportDirChanged)

public:
    explicit Artifacts(QObject *parent = nullptr);

    QString snapshotDir() const;             // effective dir (configured or default), ensured to exist
    void setSnapshotDir(const QString &dir); // accepts a path or a file:// URL
    Q_INVOKABLE QString defaultSnapshotDir() const;
    Q_INVOKABLE QString newSnapshotPath(const QString &camId) const;

    QString exportDir() const;               // effective clip-export dir, ensured to exist
    void setExportDir(const QString &dir);   // accepts a path or a file:// URL
    Q_INVOKABLE QString defaultExportDir() const;
    Q_INVOKABLE QString newExportPath(const QString &camId, const QString &ext = QStringLiteral("mp4")) const;

signals:
    void snapshotDirChanged();
    void exportDirChanged();

private:
    QSettings m_settings;
};
