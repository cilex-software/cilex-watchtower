#pragma once
#include <QObject>
#include <QVariantList>
#include <QVariantMap>

class QNetworkAccessManager;

// "The Watch" — guard check-in + progression client (contract:
// docs/letters/2026-07-28-guard-shift-achievements.* thread; backend f571736).
// The client is a renderer + a check-in button: identity is ATTRIBUTION on the
// station's shared session, never authentication. Station identity self-resolves
// from GET /client/stations by hostname (the same row Warden's heartbeats keep
// alive). Probe-gated: where the backend predates the feature, `available`
// stays false and the UI shows nothing — honest pending, house rule.
class WatchClient : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool available READ available NOTIFY stateChanged)
    Q_PROPERTY(QString stationId READ stationId NOTIFY stateChanged)
    Q_PROPERTY(bool onWatch READ onWatch NOTIFY stateChanged)
    Q_PROPERTY(QString guardId READ guardId NOTIFY stateChanged)
    Q_PROPERTY(QString guardName READ guardName NOTIFY stateChanged)
    Q_PROPERTY(QString startedAt READ startedAt NOTIFY stateChanged)
    Q_PROPERTY(QVariantList roster READ roster NOTIFY rosterChanged)
    Q_PROPERTY(QVariantMap watchstate READ watchstate NOTIFY watchstateChanged)
public:
    explicit WatchClient(QObject *parent = nullptr);

    bool available() const { return m_available; }
    QString stationId() const { return m_stationId; }
    bool onWatch() const { return !m_guardId.isEmpty(); }
    QString guardId() const { return m_guardId; }
    QString guardName() const { return m_guardName; }
    QString startedAt() const { return m_startedAt; }
    QVariantList roster() const { return m_roster; }
    QVariantMap watchstate() const { return m_watchstate; }

    Q_INVOKABLE void start();            // resolve station -> watch -> availability
    Q_INVOKABLE void refreshWatch();
    Q_INVOKABLE void fetchGuards();
    Q_INVOKABLE void fetchWatchstate();  // for the guard currently on watch
    Q_INVOKABLE void checkin(const QString &guardId);
    Q_INVOKABLE void checkout();

signals:
    void stateChanged();
    void rosterChanged();
    void watchstateChanged();
    void unlocked(const QString &family, const QString &tier);  // closed-shift truth only
    void opFailed(const QString &message);

private:
    void resolveStation();
    void probeGuards();

    QNetworkAccessManager *m_nam = nullptr;
    bool m_available = false;
    bool m_probed = false;
    int m_resolveTries = 0;
    QString m_stationId;
    QString m_guardId, m_guardName, m_shiftId, m_startedAt;
    QVariantList m_roster;
    QVariantMap m_watchstate;
};
