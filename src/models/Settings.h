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

    // Format an epoch-ms timestamp for display, honoring time24h. The QML clock
    // displays call this so the Time-format preference takes effect app-wide.
    Q_INVOKABLE QString clock(double ms, bool seconds = false) const;

signals:
    void defaultStreamHdChanged();
    void defaultLandingChanged();
    void time24hChanged();
    void alertSoundChanged();
    void desktopNotificationsChanged();

private:
    QSettings m_settings;
    bool m_defaultStreamHd = false;
    QString m_defaultLanding = QStringLiteral("live");
    bool m_time24h = true;
    bool m_alertSound = true;
    bool m_desktopNotifications = false;
};
