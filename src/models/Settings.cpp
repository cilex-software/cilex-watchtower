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
    m_triageQueueCollapsed = m_settings.value(QStringLiteral("events/triageQueueCollapsed"), false).toBool();
    m_triageBodyH = m_settings.value(QStringLiteral("events/triageBodyH"), 200).toInt();
    m_groupsPaneW = m_settings.value(QStringLiteral("groups/paneWidth"), 264).toInt();
    m_pbNavH = m_settings.value(QStringLiteral("playback/navHeight"), 115).toInt();
    // Default 64 (operator decision 2026-08-17: dedicated booth PC, guards rarely
    // page past 64 tiles). 0 is the sentinel for NO LIMIT — every tile on the
    // page decodes live and hardware/bandwidth become the only governors (the
    // RSS shed valve still applies). Numeric values clamp 1..64 as before.
    {
        int v = m_settings.value(QStringLiteral("video/maxLiveDecodes"), 64).toInt();
        m_maxLiveDecodes = (v == 0) ? 0 : qBound(1, v, 64);
    }
    m_wallScrubH = m_settings.value(QStringLiteral("wall/scrubHeight"), 160).toInt();
    m_pbPanelW = m_settings.value(QStringLiteral("playback/panelWidth"), 296).toInt();
    m_pbEventsPanel = m_settings.value(QStringLiteral("playback/eventsPanel"), true).toBool();
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

void Settings::setTriageQueueCollapsed(bool v)
{
    if (m_triageQueueCollapsed == v)
        return;
    m_triageQueueCollapsed = v;
    m_settings.setValue(QStringLiteral("events/triageQueueCollapsed"), v);
    emit triageQueueCollapsedChanged();
}

void Settings::setGroupsPaneW(int v)
{
    v = qBound(200, v, 620);
    if (m_groupsPaneW == v)
        return;
    m_groupsPaneW = v;
    m_settings.setValue(QStringLiteral("groups/paneWidth"), v);
    emit groupsPaneWChanged();
}

// Playback navigator height. The floor is 101 = 83 fixed chrome (ribbon 42 +
// header 26 + ruler 15) + the lanes' own 18px minimum — ONE number shared by the
// clamp and the lane arithmetic, so the drag can never reach a position where the
// lanes are taller than the space left for them (spec §2.2b).
void Settings::setPbNavH(int v)
{
    v = qBound(101, v, 620);
    if (m_pbNavH == v)
        return;
    m_pbNavH = v;
    m_settings.setValue(QStringLiteral("playback/navHeight"), v);
    emit pbNavHChanged();
}

void Settings::setPbPanelW(int v)
{
    v = qBound(232, v, 560);
    if (m_pbPanelW == v)
        return;
    m_pbPanelW = v;
    m_settings.setValue(QStringLiteral("playback/panelWidth"), v);
    emit pbPanelWChanged();
}

void Settings::setPbEventsPanel(bool v)
{
    if (m_pbEventsPanel == v)
        return;
    m_pbEventsPanel = v;
    m_settings.setValue(QStringLiteral("playback/eventsPanel"), v);
    emit pbEventsPanelChanged();
}

void Settings::setTriageBodyH(int v)
{
    v = qBound(120, v, 620);
    if (m_triageBodyH == v)
        return;
    m_triageBodyH = v;
    m_settings.setValue(QStringLiteral("events/triageBodyH"), v);
    emit triageBodyHChanged();
}

void Settings::setBadgeTimers(bool v)
{
    if (m_badgeTimers == v)
        return;
    m_badgeTimers = v;
    m_settings.setValue(QStringLiteral("ui/badgeTimers"), v);
    emit badgeTimersChanged();
}

void Settings::setWallScrubH(int v)
{
    v = qBound(36, v, 420);
    if (m_wallScrubH == v)
        return;
    m_wallScrubH = v;
    m_settings.setValue(QStringLiteral("wall/scrubHeight"), v);
    emit wallScrubHChanged();
}

void Settings::setMaxLiveDecodes(int v)
{
    // Floor 1, not 4 (changed 2026-08-16): the booth investigation needed a true
    // single live decode and discovered Preferences SILENTLY turned 1 into 4 —
    // the UI could not express the only configuration that ran at full rate
    // (14.79 fps at 1 pipe vs 6.66 at the clamped 4). A floor above 1 makes the
    // diagnostic configuration unreachable and turns "set it to 1" into a lie.
    // 0 = no limit (2026-08-17), same sentinel as the loader above.
    if (v != 0)
        v = qBound(1, v, 64);
    if (m_maxLiveDecodes == v)
        return;
    m_maxLiveDecodes = v;
    m_settings.setValue(QStringLiteral("video/maxLiveDecodes"), v);
    emit maxLiveDecodesChanged();
}
