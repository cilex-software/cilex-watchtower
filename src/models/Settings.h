#pragma once

#include <QObject>
#include <QSettings>
#include <QtQml/qqmlregistration.h>

// Global, persisted user preferences (QSettings — ~/.config/Cilex Vision/
// Watchtower.conf). Exposed to QML as a singleton; edited by the Preferences
// screen (§9).
class Settings : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // false = SD (substream, default — lighter/more responsive); true = HD (main).
    Q_PROPERTY(bool defaultStreamHd READ defaultStreamHd WRITE setDefaultStreamHd NOTIFY defaultStreamHdChanged)
    // Landing target on launch: "live" | "view:<id>" | "group:<id>".
    Q_PROPERTY(QString defaultLanding READ defaultLanding WRITE setDefaultLanding NOTIFY defaultLandingChanged)
    // Clock display: true = 24-hour (default), false = 12-hour.
    Q_PROPERTY(bool time24h READ time24h WRITE setTime24h NOTIFY time24hChanged)
    // Play a sound when a camera raises an alert (consulted by the alert pipeline).
    Q_PROPERTY(bool alertSound READ alertSound WRITE setAlertSound NOTIFY alertSoundChanged)
    // Show OS desktop notifications for alerts.
    Q_PROPERTY(bool desktopNotifications READ desktopNotifications WRITE setDesktopNotifications NOTIFY desktopNotificationsChanged)
    // Live-tile overlay components (each toggleable to reduce clutter).
    Q_PROPERTY(bool overlayShowName READ overlayShowName WRITE setOverlayShowName NOTIFY overlayShowNameChanged)
    Q_PROPERTY(bool overlayShowIp READ overlayShowIp WRITE setOverlayShowIp NOTIFY overlayShowIpChanged)
    Q_PROPERTY(bool overlayShowId READ overlayShowId WRITE setOverlayShowId NOTIFY overlayShowIdChanged)
    // Live video transport, admin-only: "go2rtc" (default; camera creds stay
    // server-side) or "rtsp" (direct RTSP using creds delivered by the API).
    Q_PROPERTY(QString liveTransport READ liveTransport WRITE setLiveTransport NOTIFY liveTransportChanged)
    // Show the motion/events lane on the playback scrubber (default on).
    Q_PROPERTY(bool eventsOnScrubber READ eventsOnScrubber WRITE setEventsOnScrubber NOTIFY eventsOnScrubberChanged)

public:
    explicit Settings(QObject *parent = nullptr);

    bool defaultStreamHd() const { return m_defaultStreamHd; }
    void setDefaultStreamHd(bool v);

    QString defaultLanding() const { return m_defaultLanding; }
    void setDefaultLanding(const QString &v);

    bool time24h() const { return m_time24h; }
    void setTime24h(bool v);

    bool alertSound() const { return m_alertSound; }
    void setAlertSound(bool v);

    bool desktopNotifications() const { return m_desktopNotifications; }
    void setDesktopNotifications(bool v);

    bool overlayShowName() const { return m_overlayShowName; }
    void setOverlayShowName(bool v);

    bool overlayShowIp() const { return m_overlayShowIp; }
    void setOverlayShowIp(bool v);

    bool overlayShowId() const { return m_overlayShowId; }
    void setOverlayShowId(bool v);

    QString liveTransport() const { return m_liveTransport; }
    void setLiveTransport(const QString &v);

    bool eventsOnScrubber() const { return m_eventsOnScrubber; }
    void setEventsOnScrubber(bool v);

    // Format an epoch-ms timestamp for display, honoring time24h. The QML clock
    // displays call this so the Time-format preference takes effect app-wide.
    Q_INVOKABLE QString clock(double ms, bool seconds = false) const;

    // Persisted wall-playback layout: the ordered backend camera ids the
    // operator assigned/arranged on the synchronized wall (empty = none saved;
    // the wall then seeds from the live page). Order is the grid order.
    Q_INVOKABLE QStringList wallLayout() const;
    Q_INVOKABLE void setWallLayout(const QStringList &ids);
    Q_INVOKABLE void clearWallLayout();

    // Persisted live-grid arrangement, per camera group: the ordered backend
    // camera ids the operator pinned/arranged on the Live Monitor grid. When set
    // it overrides the default sort for that group (cameras not listed append
    // after, so new cameras still appear). Keyed by group id ("" = All cameras);
    // empty list = none saved.
    Q_INVOKABLE QStringList liveLayout(const QString &groupId) const;
    Q_INVOKABLE void setLiveLayout(const QString &groupId, const QStringList &ids);
    Q_INVOKABLE void clearLiveLayout(const QString &groupId);

signals:
    void defaultStreamHdChanged();
    void defaultLandingChanged();
    void time24hChanged();
    void alertSoundChanged();
    void desktopNotificationsChanged();
    void overlayShowNameChanged();
    void overlayShowIpChanged();
    void overlayShowIdChanged();
    void liveTransportChanged();
    void eventsOnScrubberChanged();

private:
    QSettings m_settings;
    bool m_defaultStreamHd = false;
    QString m_defaultLanding = QStringLiteral("live");
    bool m_time24h = true;
    bool m_alertSound = true;
    bool m_desktopNotifications = false;
    bool m_overlayShowName = true;
    bool m_overlayShowIp = true;
    bool m_overlayShowId = false;
    QString m_liveTransport = QStringLiteral("go2rtc");
    bool m_eventsOnScrubber = true;
};
