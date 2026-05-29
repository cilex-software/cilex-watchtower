#include "Settings.h"

#include <QDateTime>

Settings::Settings(QObject *parent)
    : QObject(parent)
{
    m_defaultStreamHd = m_settings.value(QStringLiteral("video/defaultStreamHd"), false).toBool();
    m_defaultLanding = m_settings.value(QStringLiteral("workspace/defaultLanding"), QStringLiteral("live")).toString();
    m_time24h = m_settings.value(QStringLiteral("time/time24h"), true).toBool();
    m_alertSound = m_settings.value(QStringLiteral("alerts/sound"), true).toBool();
    m_desktopNotifications = m_settings.value(QStringLiteral("alerts/desktopNotifications"), false).toBool();
    m_overlayShowName = m_settings.value(QStringLiteral("overlay/showName"), true).toBool();
    m_overlayShowIp = m_settings.value(QStringLiteral("overlay/showIp"), true).toBool();
    m_overlayShowId = m_settings.value(QStringLiteral("overlay/showId"), false).toBool();
    m_liveTransport = m_settings.value(QStringLiteral("video/liveTransport"), QStringLiteral("go2rtc")).toString();
}

void Settings::setDefaultStreamHd(bool v)
{
    if (m_defaultStreamHd == v)
        return;
    m_defaultStreamHd = v;
    m_settings.setValue(QStringLiteral("video/defaultStreamHd"), v);
    emit defaultStreamHdChanged();
}

void Settings::setDefaultLanding(const QString &v)
{
    if (m_defaultLanding == v)
        return;
    m_defaultLanding = v;
    m_settings.setValue(QStringLiteral("workspace/defaultLanding"), v);
    emit defaultLandingChanged();
}

void Settings::setTime24h(bool v)
{
    if (m_time24h == v)
        return;
    m_time24h = v;
    m_settings.setValue(QStringLiteral("time/time24h"), v);
    emit time24hChanged();
}

void Settings::setAlertSound(bool v)
{
    if (m_alertSound == v)
        return;
    m_alertSound = v;
    m_settings.setValue(QStringLiteral("alerts/sound"), v);
    emit alertSoundChanged();
}

void Settings::setDesktopNotifications(bool v)
{
    if (m_desktopNotifications == v)
        return;
    m_desktopNotifications = v;
    m_settings.setValue(QStringLiteral("alerts/desktopNotifications"), v);
    emit desktopNotificationsChanged();
}

void Settings::setOverlayShowName(bool v)
{
    if (m_overlayShowName == v)
        return;
    m_overlayShowName = v;
    m_settings.setValue(QStringLiteral("overlay/showName"), v);
    emit overlayShowNameChanged();
}

void Settings::setOverlayShowIp(bool v)
{
    if (m_overlayShowIp == v)
        return;
    m_overlayShowIp = v;
    m_settings.setValue(QStringLiteral("overlay/showIp"), v);
    emit overlayShowIpChanged();
}

void Settings::setOverlayShowId(bool v)
{
    if (m_overlayShowId == v)
        return;
    m_overlayShowId = v;
    m_settings.setValue(QStringLiteral("overlay/showId"), v);
    emit overlayShowIdChanged();
}

void Settings::setLiveTransport(const QString &v)
{
    if (m_liveTransport == v)
        return;
    m_liveTransport = v;
    m_settings.setValue(QStringLiteral("video/liveTransport"), v);
    emit liveTransportChanged();
}

QString Settings::clock(double ms, bool seconds) const
{
    const QDateTime dt = QDateTime::fromMSecsSinceEpoch(qint64(ms));
    const QString fmt = m_time24h ? (seconds ? QStringLiteral("HH:mm:ss") : QStringLiteral("HH:mm"))
                                  : (seconds ? QStringLiteral("h:mm:ss AP") : QStringLiteral("h:mm AP"));
    return dt.toString(fmt);
}
