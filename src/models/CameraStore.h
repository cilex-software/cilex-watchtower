#pragma once

#include <QObject>
#include <QVector>
#include "Types.h"

// Local persistence (SQLite) — the source of truth for the operator's cameras
// and groups. Cameras come from a Cilex Provisioner import; the operator's
// display names, group assignments, and favorites are stored here and preserved
// across re-imports (keyed by the stable MAC). Watchtower is a client: it never
// invents camera names — only the user (or a future cilex-vision name feed) does.
class CameraStore : public QObject
{
    Q_OBJECT

public:
    explicit CameraStore(QObject *parent = nullptr);
    ~CameraStore() override;

    bool open();          // open/create the DB at the app data location + ensure schema
    bool isEmpty() const; // no cameras stored yet

    QVector<wt::CameraData> cameras() const;
    QVector<wt::GroupData> groups() const;

    // Import a provisioning export. Upserts by MAC: device fields (ip, rtsp,
    // firmware, ...) are refreshed; user fields (name, group, favorite) are
    // preserved if already set. Returns count imported, or -1 on error.
    int importProvisioning(const QString &path, QString *error = nullptr);

    // User edits (keyed by MAC).
    void setName(const QString &mac, const QString &name);
    void setGroup(const QString &mac, const QString &groupId);
    void setFavorite(const QString &mac, bool favorite);

    // Group management.
    void upsertGroup(const wt::GroupData &group);
    void removeGroup(const QString &id);

private:
    bool ensureSchema();
    QString m_conn;   // unique connection name
};
