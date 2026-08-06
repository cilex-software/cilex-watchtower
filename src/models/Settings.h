#pragma once

#include <QObject>
#include <QSettings>
#include <QStringList>
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
    // Status-badge timers ("REC · 4m", "OFFLINE · 2h" …): on by default.
    Q_PROPERTY(bool badgeTimers READ badgeTimers WRITE setBadgeTimers NOTIFY badgeTimersChanged)
    // Triage layout: queue column collapsed to a rail; video stage height cap (px).
    Q_PROPERTY(bool triageQueueCollapsed READ triageQueueCollapsed WRITE setTriageQueueCollapsed NOTIFY triageQueueCollapsedChanged)
    Q_PROPERTY(int triageStageMaxH READ triageStageMaxH WRITE setTriageStageMaxH NOTIFY triageStageMaxHChanged)
    // Event-type keys hidden on the playback scrubber legend ("motion" or a raw
    // event_type). Empty = all shown.
    Q_PROPERTY(QStringList hiddenScrubberEventTypes READ hiddenScrubberEventTypes WRITE setHiddenScrubberEventTypes NOTIFY hiddenScrubberEventTypesChanged)

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
    bool badgeTimers() const { return m_badgeTimers; }
    bool triageQueueCollapsed() const { return m_triageQueueCollapsed; }
    int triageStageMaxH() const { return m_triageStageMaxH; }
    void setBadgeTimers(bool v);
    void setTriageQueueCollapsed(bool v);
    void setTriageStageMaxH(int v);
    void setEventsOnScrubber(bool v);

    QStringList hiddenScrubberEventTypes() const { return m_hiddenScrubberEventTypes; }
    void setHiddenScrubberEventTypes(const QStringList &v);

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

    // Merged-cell spans on the Live wall, per (group, layout): an opaque JSON blob
    // owned by LiveMonitor ({cols, rows, regions:[{c,r,cw,ch}]}). Stored beside the
    // manual arrangement so Saved Views and the CW-05 crash-restore get them for
    // free (both restore group+layout; the spans key off exactly that pair).
    Q_INVOKABLE QString liveSpans(const QString &groupId, const QString &layout) const;
    Q_INVOKABLE void setLiveSpans(const QString &groupId, const QString &layout, const QString &json);
    Q_INVOKABLE void clearLiveSpans(const QString &groupId, const QString &layout);

    // Persisted shell view state (Warden CW-05): an opaque JSON blob owned by
    // Main.qml (section, layout, tabs, focused camera, …) so a restart —
    // Warden's crash-restart above all — lands the guard exactly where they
    // were. sync() on every save: the write must be on disk BEFORE the crash,
    // by definition. Empty string = none saved.
    Q_INVOKABLE QString viewState() const;
    Q_INVOKABLE void saveViewState(const QString &json);

    // Explicit shutdown intent (Warden CW-19, heartbeat contract §4): called on
    // Window.onClosing — the guard's close button / compositor close — so Warden
    // can report `operator_quit` from a MARKER rather than guessing from exit 0.
    // "Exit 0 is a decent proxy; a marker is the truth."
    Q_INVOKABLE void markOperatorQuit() const;

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
    void badgeTimersChanged();
    void triageQueueCollapsedChanged();
    void triageStageMaxHChanged();
    void hiddenScrubberEventTypesChanged();

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
    bool m_badgeTimers = true;
    bool m_triageQueueCollapsed = false;
    int m_triageStageMaxH = 372;
    QStringList m_hiddenScrubberEventTypes;
};
