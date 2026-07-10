#pragma once

#include <QAbstractListModel>
#include <QtQml/qqmlregistration.h>
#include <QVector>
#include <QVariantList>
#include <QVariantMap>
#include <QStringList>
#include "Types.h"

class QNetworkAccessManager;
class QJsonObject;

// Operational events (motion / offline / online / gap / bookmark) feeding the
// ops sidebar feed, the Events screen, and the nav-rail unacknowledged badge.
// Live events come from cilex-vision's GET /events (authenticated, lazy login);
// WT_DEMO shows a mock stream for development. Acknowledgement is a local
// operator action persisted on this machine — cilex-vision has no acknowledge
// endpoint yet (events carry a lifecycle `state`), so we never fake a shared
// ack. See docs/letters/ for the requested /events/{id}/acknowledge contract.
class EventModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int total READ total NOTIFY changed)
    Q_PROPERTY(int serverTotal READ serverTotal NOTIFY changed)
    Q_PROPERTY(bool hasMore READ hasMore NOTIFY changed)
    Q_PROPERTY(int unacknowledgedCount READ unacknowledgedCount NOTIFY changed)
    Q_PROPERTY(bool loading READ loading NOTIFY changed)

public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        TypeRole,
        CamIdRole,
        CamNameRole,
        GroupRole,
        TimeRole,
        DescRole,
        AckRole,
        AckByRole,
        AckTimeRole,
    };

    explicit EventModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int total() const { return int(m_all.size()); }            // loaded count
    int serverTotal() const { return m_serverTotal; }          // DB count for the query
    bool hasMore() const { return m_fetched < m_serverTotal; }
    int unacknowledgedCount() const;
    bool loading() const { return m_loading; }

    // Re-fetch live events from cilex-vision (no-op under WT_DEMO). Re-runs the
    // current server-side query (camera/time) from page 0.
    Q_INVOKABLE void refresh();
    // Server-side query against /events. Empty cameraId/start/end omit that filter.
    // Resets to page 0. start/end are ISO 8601 instants. (Motion is a client-side
    // pill now — see EventsScreen; the feed already drops redundant motion_detected
    // rows, so the old has_clip=true server filter no longer applies.)
    Q_INVOKABLE void search(const QString &cameraId, const QString &startIso,
                            const QString &endIso);
    // Fetch and append the next page for the current query.
    Q_INVOKABLE void loadMore();
    // All events as maps (for the Events screen, which filters in QML).
    Q_INVOKABLE QVariantList all() const;
    // Backend camera_ids with an event within the last `windowMs` (over the loaded
    // feed). Powers the Live screen's "Recent events" filter.
    Q_INVOKABLE QStringList recentCameraIds(qint64 windowMs) const;

    // Newest motion_* event time (ms epoch) seen for a camera across every fetched
    // page — feeds the ARMED badge's event-freshness readout ("armed" alone says the
    // mode is on, not that events actually flow; a clock-vetoed or subscription-dead
    // camera looks identical without this). Includes display-suppressed
    // motion_detected rows; excludes motion_not_ready (a health warning, not motion).
    // -1 = no motion event seen for that camera in the loaded feed.
    Q_INVOKABLE double lastMotionAtMs(const QString &cameraId) const
    { return double(m_lastMotion.value(cameraId, -1)); }
    // Bumped once per fetch that advanced any camera's last-motion time — QML binds
    // to this to re-evaluate lastMotionAtMs() without re-paging camera rows (tile
    // recreation restarts RTSP pipelines, so row updates are deliberately avoided).
    Q_PROPERTY(int motionRev READ motionRev NOTIFY motionRevChanged)
    int motionRev() const { return m_motionRev; }

    // Is a motion EPISODE currently active on this camera (motion_started seen with
    // no matching motion_ended yet)? Safety-capped at 10 min so a lost ended event
    // can't pin a tile hot forever. Drives the live MOTION tile indicator.
    Q_INVOKABLE bool motionActive(const QString &cameraId) const;

    // Lightweight motion poll: fetches the newest events page and updates ONLY the
    // per-camera motion tracking (lastMotionAtMs / started / ended) — never touches
    // the list model, so the Live Events sidebar doesn't churn. Cheap enough to run
    // every few seconds while the wall is visible: that poll interval IS the live
    // MOTION indicator's latency (true sub-second needs a push feed — CV ask).
    Q_INVOKABLE void pollMotion();

    // Live Events sidebar feed: one row per motion INCIDENT (the deduped
    // motion_detected event, which carries the clip → has a mid-event still),
    // via the server-side exclude_types filter (CV spec 2026-07-10). Kept
    // separate from the triage list model on purpose — different content rules.
    Q_PROPERTY(QVariantList liveFeed READ liveFeed NOTIFY liveFeedChanged)
    QVariantList liveFeed() const { return m_liveFeed; }
    Q_INVOKABLE void fetchLiveFeed();

    Q_INVOKABLE void acknowledge(int row, const QString &by);
    Q_INVOKABLE void acknowledgeById(const QString &id);
    // Shared, server-persisted triage actions (cilex-vision 2026-06-18). POST the
    // action, then replace the row in place from the returned event. Under WT_DEMO
    // (no backend) they fall back to a local patch.
    Q_INVOKABLE void setDisposition(const QString &id, const QString &disposition, const QString &note);
    Q_INVOKABLE void setBookmark(const QString &id, bool value);
    // Assign an event to an operator (empty assignee → unassign). POSTs and swaps
    // in the returned row; WT_DEMO falls back to a local patch.
    Q_INVOKABLE void assignEvent(const QString &id, const QString &assignee);
    // Roster of assignable operators (GET /operators) for the assign menu.
    Q_INVOKABLE void fetchOperators();
    Q_INVOKABLE QVariantList operators() const { return m_operators; }

signals:
    void changed();
    void operatorsChanged();
    void motionRevChanged();
    void liveFeedChanged();

private:
    void fetchPage(bool append);
    void applyAcks();
    void persistAck(const QString &id, const QString &by, const QString &time);
    wt::EventData parseRow(const QJsonObject &o) const;
    void postEventAction(const QString &id, const QString &subpath, const QJsonObject &body);
    QVariantMap toMap(const wt::EventData &e) const;

    QVector<wt::EventData> m_all;
    QVariantList m_operators;
    QNetworkAccessManager *m_nam = nullptr;
    QString m_baseUrl;
    bool m_loading = false;
    // server-side query state (see search()/loadMore())
    QString m_qCameraId, m_qStart, m_qEnd;
    int m_pageSize = 100;
    int m_serverTotal = 0;   // DB rows matching the query (raw count from /events)
    void trackMotionRow(const QJsonObject &o, bool *advanced);
    QHash<QString, qint64> m_lastMotion;   // camera_id → newest motion_* start_time (ms)
    QHash<QString, qint64> m_lastStarted;  // camera_id → newest motion_started (ms)
    QHash<QString, qint64> m_lastEnded;    // camera_id → newest motion_ended (ms)
    QVariantList m_liveFeed;
    QString m_liveFeedSig;                 // change signature — skip emits when identical
    int m_motionRev = 0;
    int m_fetched = 0;       // rows received from the server so far = next page offset.
                             // Distinct from m_all.size(): we drop motion_detected, so
                             // kept rows can be fewer than rows fetched.
    int m_gen = 0;            // supersedes in-flight replies when a newer query starts
};
