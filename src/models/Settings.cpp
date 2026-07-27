#include "Settings.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QStandardPaths>

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
    m_eventsOnScrubber = m_settings.value(QStringLiteral("playback/eventsOnScrubber"), true).toBool();
    m_badgeTimers = m_settings.value(QStringLiteral("ui/badgeTimers"), true).toBool();
    m_hiddenScrubberEventTypes = m_settings.value(QStringLiteral("playback/hiddenScrubberEventTypes")).toStringList();
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

void Settings::setEventsOnScrubber(bool v)
{
    if (m_eventsOnScrubber == v)
        return;
    m_eventsOnScrubber = v;
    m_settings.setValue(QStringLiteral("playback/eventsOnScrubber"), v);
    emit eventsOnScrubberChanged();
}

void Settings::setHiddenScrubberEventTypes(const QStringList &v)
{
    if (m_hiddenScrubberEventTypes == v)
        return;
    m_hiddenScrubberEventTypes = v;
    m_settings.setValue(QStringLiteral("playback/hiddenScrubberEventTypes"), v);
    emit hiddenScrubberEventTypesChanged();
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

QStringList Settings::wallLayout() const
{
    return m_settings.value(QStringLiteral("wall/playbackLayout")).toStringList();
}

void Settings::setWallLayout(const QStringList &ids)
{
    m_settings.setValue(QStringLiteral("wall/playbackLayout"), ids);
}

void Settings::clearWallLayout()
{
    m_settings.remove(QStringLiteral("wall/playbackLayout"));
}

// Per-group live arrangement. Key the group id under a sub-group; "" (All
// cameras) gets a stable sentinel. Slashes can't appear in QSettings leaf keys,
// so swap any out (backend ids are UUID-like, but belt-and-suspenders).
static QString liveLayoutKey(const QString &groupId)
{
    QString g = groupId.isEmpty() ? QStringLiteral("__all__") : groupId;
    g.replace(QLatin1Char('/'), QLatin1Char('_'));
    return QStringLiteral("live/layout/") + g;
}
QStringList Settings::liveLayout(const QString &groupId) const
{
    return m_settings.value(liveLayoutKey(groupId)).toStringList();
}
void Settings::setLiveLayout(const QString &groupId, const QStringList &ids)
{
    m_settings.setValue(liveLayoutKey(groupId), ids);
}
void Settings::clearLiveLayout(const QString &groupId)
{
    m_settings.remove(liveLayoutKey(groupId));
}

static QString liveSpansKey(const QString &groupId, const QString &layout)
{
    return QStringLiteral("liveSpans/%1/%2")
        .arg(groupId.isEmpty() ? QStringLiteral("all") : groupId, layout);
}

QString Settings::liveSpans(const QString &groupId, const QString &layout) const
{
    return m_settings.value(liveSpansKey(groupId, layout)).toString();
}

void Settings::setLiveSpans(const QString &groupId, const QString &layout, const QString &json)
{
    m_settings.setValue(liveSpansKey(groupId, layout), json);
    m_settings.sync();   // crash-durable, same contract as the view state (CW-05)
}

void Settings::clearLiveSpans(const QString &groupId, const QString &layout)
{
    m_settings.remove(liveSpansKey(groupId, layout));
}

QString Settings::viewState() const
{
    return m_settings.value(QStringLiteral("workspace/viewState")).toString();
}

void Settings::saveViewState(const QString &json)
{
    m_settings.setValue(QStringLiteral("workspace/viewState"), json);
    // Crash-durable by contract: Warden restarts us after SIGKILL — a lazily
    // flushed QSettings would restore the guard to a stale view.
    m_settings.sync();
}

void Settings::markOperatorQuit() const
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
                        + QStringLiteral("/crash");
    QDir().mkpath(dir);
    QFile f(dir + QStringLiteral("/shutdown-intent"));
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        f.write(QDateTime::currentDateTimeUtc().toString(Qt::ISODate).toUtf8());
        f.write("\n");
    }
}

void Settings::setBadgeTimers(bool v)
{
    if (m_badgeTimers == v)
        return;
    m_badgeTimers = v;
    m_settings.setValue(QStringLiteral("ui/badgeTimers"), v);
    emit badgeTimersChanged();
}
