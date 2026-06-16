#pragma once

#include <QAbstractListModel>
#include <QtQml/qqmlregistration.h>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>
#include <QSet>
#include <QHash>
#include <QPair>
#include <QStringList>
#include <QTimer>
#include "Types.h"
#include "CameraStore.h"

class QNetworkAccessManager;
class QJsonObject;

// Flat list of all cameras, exposed to QML. Group/status filtering and paging
// for the Live Monitor are layered on top later (proxy/QML); this model is the
// source of truth and the global status counts.
class CameraModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int total READ total NOTIFY countsChanged)
    Q_PROPERTY(int onlineCount READ onlineCount NOTIFY countsChanged)
    Q_PROPERTY(int offlineCount READ offlineCount NOTIFY countsChanged)
    Q_PROPERTY(int degradedCount READ degradedCount NOTIFY countsChanged)
    Q_PROPERTY(int recordingCount READ recordingCount NOTIFY countsChanged)
    Q_PROPERTY(int notRecordingCount READ notRecordingCount NOTIFY countsChanged)
    Q_PROPERTY(int recUnknownCount READ recUnknownCount NOTIFY countsChanged)
    Q_PROPERTY(int recordingGapCount READ recordingGapCount NOTIFY countsChanged)
    // True while the first /streams fetch is in flight (auth -> list arrives).
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    // Business-function state from /streams `functions` (fail-safe: true unless the
    // backend explicitly reports enabled:false). Lets the UI show a deliberate
    // "switched off" instead of a fault. See docs/letters/2026-06-16-function-state*.
    Q_PROPERTY(bool recordingEnabled READ recordingEnabled NOTIFY functionsChanged)
    Q_PROPERTY(bool liveViewEnabled READ liveViewEnabled NOTIFY functionsChanged)

public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        NameRole,
        GroupIdRole,
        GroupNameRole,
        LiveRole,
        RecordingRole,
        HasAudioRole,
        FavoriteRole,
        TimestampRole,
        LastSeenRole,
        LastSegmentAtRole,
        PatternRole,
        RtspUrlRole,
        RtspSubUrlRole,
        SnapshotUrlRole,
        IpRole,
        MacRole,
        ModelRole,
        VendorRole,
        FirmwareRole,
    };

    explicit CameraModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    // Row accessor for QML (returns the camera's fields as a map, keyed by the
    // same names as the roles).
    Q_INVOKABLE QVariantMap get(int row) const;

    // Resolve a cilex-vision backend camera_id to its row. Returns the camera map
    // (like get()) or empty.
    Q_INVOKABLE QVariantMap cameraByBackendId(const QString &cameraId) const;

    // Live Monitor view: filter by group + status, sort, and slice to one page.
    // statusFilter: ""|"online"|"offline"|"degraded"|"recording"|"notrec"|
    //               "favorites"|"issues"|"recent". sortMode: "default"|"status"|"alpha".
    Q_INVOKABLE QVariantList page(const QString &groupId, const QString &statusFilter,
                                  const QString &sortMode, int pageNum, int pageSize) const;
    Q_INVOKABLE int countFiltered(const QString &groupId, const QString &statusFilter) const;

    // Per-operator camera visibility. `cameraIds` are backend ids
    // ("<vendor>-<machex>") from the signed-in user's JWT camera_scope; an empty
    // list means "all cameras" (admin). Cameras outside the scope are filtered
    // out of the model entirely (list, counts, paging, resolution).
    Q_INVOKABLE void setCameraScope(const QStringList &cameraIds);

    // Backend camera_ids with a recent event (fed from the Live screen's events
    // feed). Drives the "recent" status filter; empty = nothing recent.
    Q_INVOKABLE void setRecentCameras(const QStringList &ids);

    // Re-fetch group definitions (/groups) AND the camera list (/streams) from
    // the server — picks up admin-side changes immediately (regroups, new/renamed
    // groups, new stream URLs after a live-transport switch). Used by the live
    // group switcher's manual "Sync from server"; the 15s poll also auto-syncs
    // group membership in place, so this is for instant resync on demand.
    Q_INVOKABLE void refresh() { fetchGroups(); fetchCameras(); }

    // Per-operator edits keyed by the backend camera_id: a local display-name
    // override (layered over the backend name) and favorite.
    Q_INVOKABLE void setCameraName(const QString &cameraId, const QString &name);
    Q_INVOKABLE void setCameraGroup(const QString &cameraId, const QString &groupId);

    // Groups are owned by cilex-vision (the `/groups` API); this model fetches
    // them and reads per-camera membership (group_id) straight from /streams.
    // groupList() returns each backend group with locally-computed counts.
    // Mutations are async — completion is signalled via groupsChanged (and
    // groupCreated for create, so the UI can select the new group).
    Q_INVOKABLE QVariantList groupList() const;
    Q_INVOKABLE void createGroup(const QString &name);
    Q_INVOKABLE void renameGroup(const QString &id, const QString &name);
    Q_INVOKABLE void removeGroup(const QString &id);

    int total() const { return int(m_all.size()); }
    int onlineCount() const { return m_online; }
    int offlineCount() const { return m_offline; }
    int degradedCount() const { return m_degraded; }
    int recordingCount() const { return m_recording; }
    int notRecordingCount() const { return m_notRecording; }
    int recUnknownCount() const { return m_recUnknown; }
    int recordingGapCount() const { return m_gap; }
    bool loading() const { return m_loading; }

    Q_INVOKABLE void toggleFavorite(int row);
    // Toggle by backend camera_id — the Live Monitor tiles carry the camera_id
    // (from the paged snapshot), not the model row.
    Q_INVOKABLE void toggleFavoriteById(const QString &cameraId);

    bool recordingEnabled() const { return m_recordingEnabled; }
    bool liveViewEnabled() const { return m_liveViewEnabled; }

signals:
    void countsChanged();
    void groupsChanged();
    void groupCreated(const QString &groupId);
    void loadingChanged();
    void functionsChanged();

private:
    void recompute();
    bool matches(const wt::CameraData &c, const QString &groupId, const QString &statusFilter) const;
    QVector<int> filteredSorted(const QString &groupId, const QString &statusFilter,
                                const QString &sortMode) const;
    // Backend camera integration (cilex-vision /streams is the authoritative list).
    void fetchCameras();       // GET /streams -> m_all full reset (login / manual refresh)
    void pollStatuses();       // GET /streams -> in-place update of live + recording (15s poll)
    void fetchGroups();        // GET /groups  -> m_groups (definitions for groupList)
    void applyFunctions(const QJsonObject &funcs);  // parse /streams `functions` (fail-safe)
    void setLoading(bool v);

    CameraStore m_store;
    QVector<wt::CameraData> m_all;
    QNetworkAccessManager *m_nam = nullptr;   // shared, from AuthController
    QString m_baseUrl;
    QVector<wt::GroupData> m_groups;          // backend group definitions
    QHash<QString, QPair<QString, bool>> m_prefs;   // camera_id -> {displayName, favorite}
    QSet<QString> m_recentCamIds;                   // cameras with a recent event ("recent" filter)
    bool m_loading = false;
    bool m_recordingEnabled = true;   // fail-safe defaults: a function is "on" unless
    bool m_liveViewEnabled = true;    // /streams explicitly reports enabled:false
    int m_online = 0;
    int m_offline = 0;
    int m_degraded = 0;
    int m_recording = 0;
    int m_notRecording = 0;
    int m_recUnknown = 0;
    int m_gap = 0;
    QTimer *m_pollTimer = nullptr;   // periodic /streams refresh (recording + live status)
};
