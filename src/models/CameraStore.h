#pragma once

#include <QObject>
#include <QVector>
#include "Types.h"

// Local persistence (SQLite) for the operator's cameras. Cameras come from a
// Cilex Provisioner import; the operator's display names and favorites are
// stored here and preserved across re-imports (keyed by the stable MAC).
// Groups are NOT stored here — they're owned by cilex-vision (the /groups API);
// per-camera membership is applied at runtime from /streams. Watchtower never
// invents camera names — only the user (or a cilex-vision name feed) does.
class CameraStore : public QObject
{
    Q_OBJECT

public:
    explicit CameraStore(QObject *parent = nullptr);
    ~CameraStore() override;

    bool open();          // open/create the DB at the app data location + ensure schema
    bool isEmpty() const; // no cameras stored yet

    QVector<wt::CameraData> cameras() const;

    // Import a provisioning export. Upserts by MAC: device fields (ip, rtsp,
    // firmware, ...) are refreshed; user fields (name, favorite) are preserved
    // if already set. Returns count imported, or -1 on error.
    int importProvisioning(const QString &path, QString *error = nullptr);

    // User edits (keyed by MAC).
    void setName(const QString &mac, const QString &name);
    void setFavorite(const QString &mac, bool favorite);

private:
    bool ensureSchema();
    QString m_conn;   // unique connection name
};
