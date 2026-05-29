#pragma once

#include <QObject>
#include <QHash>
#include <QPair>
#include <QString>

// Local SQLite — per-operator preferences only. The cilex-vision backend
// (/streams) is the authoritative camera list, identity, and stream URLs; this
// store holds no camera/provisioning data. It persists the operator's local
// overrides keyed by the backend camera_id: a display-name override + favorite.
class CameraStore : public QObject
{
    Q_OBJECT

public:
    explicit CameraStore(QObject *parent = nullptr);
    ~CameraStore() override;

    bool open();          // open/create the DB at the app data location + ensure schema

    // Per-operator prefs keyed by the backend camera_id.
    QHash<QString, QPair<QString, bool>> prefs() const;   // camera_id -> {displayName, favorite}
    void setDisplayName(const QString &cameraId, const QString &name);
    void setFavoritePref(const QString &cameraId, bool favorite);

private:
    bool ensureSchema();
    QString m_conn;   // unique connection name
};
