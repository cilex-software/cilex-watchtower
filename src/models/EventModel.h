#pragma once

#include <QAbstractListModel>
#include <QtQml/qqmlregistration.h>
#include <QVector>
#include <QVariantList>
#include <QVariantMap>
#include "Types.h"

class QNetworkAccessManager;

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
    bool hasMore() const { return int(m_all.size()) < m_serverTotal; }
    int unacknowledgedCount() const;
    bool loading() const { return m_loading; }

    // Re-fetch live events from cilex-vision (no-op under WT_DEMO). Re-runs the
    // current server-side query (camera/time/motion) from page 0.
    Q_INVOKABLE void refresh();
    // Server-side query against /events. Empty cameraId/start/end omit that filter;
    // motionOnly adds has_clip=true (the motion events that have footage). Resets
    // to page 0. start/end are ISO 8601 instants.
    Q_INVOKABLE void search(const QString &cameraId, const QString &startIso,
                            const QString &endIso, bool motionOnly);
    // Fetch and append the next page for the current query.
    Q_INVOKABLE void loadMore();
    // All events as maps (for the Events screen, which filters in QML).
    Q_INVOKABLE QVariantList all() const;

    Q_INVOKABLE void acknowledge(int row, const QString &by);
    Q_INVOKABLE void acknowledgeById(const QString &id);

signals:
    void changed();

private:
    void fetchPage(bool append);
    void applyAcks();
    void persistAck(const QString &id, const QString &by, const QString &time);
    QVariantMap toMap(const wt::EventData &e) const;

    QVector<wt::EventData> m_all;
    QNetworkAccessManager *m_nam = nullptr;
    QString m_baseUrl;
    bool m_loading = false;
    // server-side query state (see search()/loadMore())
    QString m_qCameraId, m_qStart, m_qEnd;
    bool m_qMotion = false;
    int m_pageSize = 100;
    int m_serverTotal = 0;
    int m_gen = 0;            // supersedes in-flight replies when a newer query starts
};
