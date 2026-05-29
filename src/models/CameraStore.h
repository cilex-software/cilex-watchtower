#pragma once

#include <QObject>
#include <QVector>
#include <QHash>
#include <QPair>
#include "Types.h"

// Local SQLite. Phase D: the cilex-vision backend (/streams) is the authoritative
// camera LIST; this store is now (Track B) only a side-table providing stream
// URLs + hardware metadata, MAC-keyed, joined to the backend list by MAC. It also
// holds per-operator prefs (display-name override + favorite) keyed by the backend
// camera_id. The camera list itself is no longer sourced from here.
class CameraStore : public QObject
{
    Q_OBJECT

public:
    explicit CameraStore(QObject *parent = nullptr);
    ~CameraStore() override;

    bool open();          // open/create the DB at the app data location + ensure schema
    bool isEmpty() const; // no provisioning rows yet

    // Track-B side-table: rtsp/metadata (+ a legacy favorite seed) keyed by MAC.
    QVector<wt::CameraData> cameras() const;

    // Import a provisioning export (Track B URL/metadata source). Upserts by MAC.
    int importProvisioning(const QString &path, QString *error = nullptr);

    // Per-operator prefs keyed by the backend camera_id.
    QHash<QString, QPair<QString, bool>> prefs() const;   // camera_id -> {displayName, favorite}
    void setDisplayName(const QString &cameraId, const QString &name);
    void setFavoritePref(const QString &cameraId, bool favorite);

private:
    bool ensureSchema();
    QString m_conn;   // unique connection name
};
