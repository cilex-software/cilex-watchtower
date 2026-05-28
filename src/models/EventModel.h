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

    int total() const { return int(m_all.size()); }
    int unacknowledgedCount() const;
    bool loading() const { return m_loading; }

    // Re-fetch live events from cilex-vision (no-op under WT_DEMO).
    Q_INVOKABLE void refresh();
    // All events as maps (for the Events screen, which filters in QML).
    Q_INVOKABLE QVariantList all() const;

    Q_INVOKABLE void acknowledge(int row, const QString &by);
    Q_INVOKABLE void acknowledgeById(const QString &id);

signals:
    void changed();

private:
    void fetchEvents();
    void applyAcks();
    void persistAck(const QString &id, const QString &by, const QString &time);
    QVariantMap toMap(const wt::EventData &e) const;

    QVector<wt::EventData> m_all;
    QNetworkAccessManager *m_nam = nullptr;
    QString m_baseUrl;
    bool m_loading = false;
};
