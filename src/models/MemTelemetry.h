#pragma once

#include <QObject>
#include <QElapsedTimer>
#include <QSet>

class QTimer;

// Field memory telemetry: periodically logs process RSS alongside cumulative ACTIVE-PLAYBACK seconds and
// recording-open count, so a real review shift self-reports the inputs needed to judge whether the residual
// per-open RSS growth (see docs/perf/2026-06-29-qt-decode-leak-deepdive.md Revision 3) is shift-breaking.
// The growth tracks playback time (WT_HERO_NOPLAY is flat), not wall-clock — so playSec is the multiplier.
// Players report state via setPlaying(id, playing) (id distinguishes hero vs wall); active playback time is
// the union of all players' playing intervals.
class MemTelemetry : public QObject
{
    Q_OBJECT
public:
    explicit MemTelemetry(QObject *parent = nullptr);

    Q_INVOKABLE void setPlaying(int id, bool playing);   // a player entered/left PlayingState
    Q_INVOKABLE void noteOpen();                         // a recording source-change

    // Safety valve: true when process RSS crosses WT_RSS_SHED_MB (a runaway — the live-wall pipeline leak
    // under go2rtc instability is the known one). The live wall binds maxLiveDecodes to this and sheds live
    // decodes to snapshot tiles, capping the climb below earlyoom so a leak degrades gracefully, not OOM-kills.
    Q_PROPERTY(bool shedLive READ shedLive NOTIFY shedLiveChanged)
    bool shedLive() const { return m_shedLive; }

    // TRUE while Cilex Warden is actually supervising this process RIGHT NOW —
    // not merely "was launched by it". Warden is our PARENT: spawn env
    // (WT_UNDER_WARDEN=1) arms the check, and a periodic getppid() comparison
    // keeps it honest — if Warden dies, we get re-parented and this flips false
    // (the title-bar eye quietly disappears; never an alarm — the guard is not
    // the detector, the heartbeat pipeline is). Windows: env-armed only (v1;
    // live parent check lands with the CW-18 pass).
    Q_PROPERTY(bool underWarden READ underWarden NOTIFY underWardenChanged)
    bool underWarden() const { return m_underWarden; }

signals:
    void shedLiveChanged();
    void underWardenChanged();

private:
    void tick();
    void guardTick();

    QSet<int> m_playing;          // ids of currently-playing players
    QElapsedTimer m_clock;        // running while m_playing is non-empty
    qint64 m_cumPlayMs = 0;
    qint64 m_opens = 0;
    QElapsedTimer m_uptime;
    QTimer *m_timer = nullptr;

    bool m_shedLive = false;
    long m_shedThreshMb = 0;        // WT_RSS_SHED_MB; 0 = guard disabled
    QTimer *m_guardTimer = nullptr;

    bool m_underWarden = false;
    qint64 m_wardenPpid = -1;       // parent pid captured at start (Linux live check)
};
