#pragma once

#include <QObject>
#include <QSettings>
#include <QtQml/qqmlregistration.h>

class QNetworkAccessManager;

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

    // Async: fetches a full-resolution still from go2rtc's frame.jpeg endpoint
    // on the main stream (so the saved snapshot is always best-quality, not the
    // ~720p substream the wall renders). Emits snapshotCaptured on success or
    // snapshotCaptureFailed on error — the caller falls back to a tile grab.
    Q_INVOKABLE void captureMainStreamSnapshot(const QString &camId,
                                               const QString &camName,
                                               const QString &mainRtspUrl);

signals:
    void snapshotDirChanged();
    void exportDirChanged();
    void snapshotCaptured(const QString &path, const QString &camId, const QString &camName);
    void snapshotCaptureFailed(const QString &camId, const QString &camName, const QString &reason);

private:
    QSettings m_settings;
    QNetworkAccessManager *m_nam = nullptr;
};
