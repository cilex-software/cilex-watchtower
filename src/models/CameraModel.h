#pragma once

#include <QAbstractListModel>
#include <QtQml/qqmlregistration.h>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>
#include <QSet>
#include <QStringList>
#include "Types.h"
#include "CameraStore.h"

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
        PatternRole,
        RtspUrlRole,
        RtspSubUrlRole,
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

    // Resolve a cilex-vision backend camera_id ("<slug>-<machex>") to the local
    // camera (matched by MAC). Returns the camera map (like get()) or empty.
    Q_INVOKABLE QVariantMap cameraByBackendId(const QString &cameraId) const;

    // Live Monitor view: filter by group + status, sort, and slice to one page.
    // statusFilter: ""|"online"|"offline"|"degraded"|"recording"|"notrec"|
    //               "favorites"|"issues"|"recent". sortMode: "default"|"status"|"alpha".
    Q_INVOKABLE QVariantList page(const QString &groupId, const QString &statusFilter,
                                  const QString &sortMode, int pageNum, int pageSize) const;
    Q_INVOKABLE int countFiltered(const QString &groupId, const QString &statusFilter) const;

    // Import a Cilex Vision Provisioner export into the persistent store, then
    // reload (upserts by MAC; preserves user name/group/favorite). False on error.
    Q_INVOKABLE bool importProvisioning(const QString &path);

    // Per-operator camera visibility. `cameraIds` are backend ids
    // ("<vendor>-<machex>") from the signed-in user's JWT camera_scope; an empty
    // list means "all cameras" (admin). Cameras outside the scope are filtered
    // out of the model entirely (list, counts, paging, resolution).
    Q_INVOKABLE void setCameraScope(const QStringList &cameraIds);

    // Persisted operator edits (by row). Watchtower never invents names — these
    // set what the user chooses; they survive restarts and re-imports.
    Q_INVOKABLE void setCameraName(const QString &mac, const QString &name);
    Q_INVOKABLE void setCameraGroup(const QString &mac, const QString &groupId);

    // User-defined groups (persisted). groupList() returns each group with its
    // live camera counts. Groups are flat in MVP (no nesting yet).
    Q_INVOKABLE QVariantList groupList() const;
    Q_INVOKABLE QString createGroup(const QString &name);
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

    Q_INVOKABLE void toggleFavorite(int row);

signals:
    void countsChanged();
    void groupsChanged();

private:
    void recompute();
    void reload();
    void loadFromStore();   // m_all <- store, filtered by m_scopeMacs (if any)
    bool matches(const wt::CameraData &c, const QString &groupId, const QString &statusFilter) const;
    QVector<int> filteredSorted(const QString &groupId, const QString &statusFilter,
                                const QString &sortMode) const;

    CameraStore m_store;
    QVector<wt::CameraData> m_all;
    QSet<QString> m_scopeMacs;   // normalized MAC hexes the operator may see; empty = all
    int m_online = 0;
    int m_offline = 0;
    int m_degraded = 0;
    int m_recording = 0;
    int m_notRecording = 0;
    int m_recUnknown = 0;
    int m_gap = 0;
};
