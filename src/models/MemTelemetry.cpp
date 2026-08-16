#include "MemTelemetry.h"
#include "RtspVideoSource.h"   // live-wall pipeline/frame counters (the live decode path MEMTEL must also watch)

#include <QTimer>
#include <QDebug>
// Same RSS reader as main.cpp readRssMb(), minus the signal-safety constraint (this one runs
// on the GUI thread from a QTimer, never a signal handler). Linux: /proc/self/statm; Windows:
// PSAPI WorkingSetSize. Kept per-file rather than shared — the two callers have different
// safety needs and a shared unit would couple them for ~4 saved lines.
#if defined(Q_OS_WIN)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#  include <psapi.h>
#else
#  include <QFile>
#  include <QByteArrayList>
#  include <unistd.h>
#endif

static long rssMb()
{
#if defined(Q_OS_WIN)
    PROCESS_MEMORY_COUNTERS pmc;
    if (::GetProcessMemoryInfo(::GetCurrentProcess(), &pmc, sizeof(pmc)))
        return long(pmc.WorkingSetSize / (1024 * 1024));
    return -1;
#else
    QFile f(QStringLiteral("/proc/self/statm"));   // field 2 = resident pages
    if (!f.open(QIODevice::ReadOnly))
        return -1;
    const QByteArrayList p = f.readAll().simplified().split(' ');
    if (p.size() < 2)
        return -1;
    return (p[1].toLong() * (sysconf(_SC_PAGESIZE) / 1024)) / 1024;
#endif
}

MemTelemetry::MemTelemetry(QObject *parent) : QObject(parent)
{
    m_uptime.start();
    m_timer = new QTimer(this);
    connect(m_timer, &QTimer::timeout, this, &MemTelemetry::tick);
    m_timer->start(30000);          // 30 s heartbeat

    // RSS-shed safety valve (WT_RSS_SHED_MB, default 5000; 0 disables). Checked every 5 s — fast enough to
    // trip before earlyoom on a runaway (the crash went 2.3→8.6 GB in ~60 s). Normal use is well under 1 GB,
    // so 5 GB is unambiguously a leak. Trips shedLive → the live wall drops to snapshot tiles, capping growth.
    m_shedThreshMb = qEnvironmentVariableIsSet("WT_RSS_SHED_MB")
                     ? qEnvironmentVariableIntValue("WT_RSS_SHED_MB") : 5000;
    if (m_shedThreshMb > 0) {
        m_guardTimer = new QTimer(this);
        connect(m_guardTimer, &QTimer::timeout, this, &MemTelemetry::guardTick);
        m_guardTimer->start(5000);
    }

    // Warden supervision indicator (title-bar eye): armed by the spawn env, kept
    // honest on Linux by watching our PARENT pid — Warden IS the parent (run.sh
    // exec-chains into the binary), so its death re-parents us and the eye goes
    // out on the next 5 s check. Quietly: absence of chrome, never an alarm.
    if (qEnvironmentVariableIsSet("WT_UNDER_WARDEN")) {
        m_underWarden = true;
#if !defined(Q_OS_WIN)
        m_wardenPpid = (qint64)::getppid();
        auto *pp = new QTimer(this);
        connect(pp, &QTimer::timeout, this, [this]() {
            if (m_underWarden && (qint64)::getppid() != m_wardenPpid) {
                m_underWarden = false;
                emit underWardenChanged();
                qInfo("[MEMTEL] warden parent gone (re-parented) — supervision indicator off");
            }
        });
        pp->start(5000);
#endif
    }
}

void MemTelemetry::guardTick()
{
    const long rss = rssMb();
    if (rss < 0)
        return;
    if (!m_shedLive && rss > m_shedThreshMb) {
        m_shedLive = true;
        qWarning("[MEMGUARD] RSS %ld MB > %ld MB — SHEDDING live decodes (wall → snapshot tiles) to avert OOM",
                 rss, m_shedThreshMb);
        emit shedLiveChanged();
    } else if (m_shedLive && rss < m_shedThreshMb * 85 / 100) {   // hysteresis: recover at 85 %
        m_shedLive = false;
        qInfo("[MEMGUARD] RSS %ld MB recovered — restoring live decodes", rss);
        emit shedLiveChanged();
    }
}

void MemTelemetry::setPlaying(int id, bool playing)
{
    const bool was = !m_playing.isEmpty();
    if (playing)
        m_playing.insert(id);
    else
        m_playing.remove(id);
    const bool now = !m_playing.isEmpty();
    if (!was && now)
        m_clock.restart();          // first player started → start the playback clock
    else if (was && !now)
        m_cumPlayMs += m_clock.elapsed();   // last player stopped → bank the interval
}

void MemTelemetry::noteOpen()
{
    ++m_opens;
}

void MemTelemetry::tick()
{
    const qint64 playMs = m_cumPlayMs + (m_playing.isEmpty() ? 0 : m_clock.elapsed());
    // livePipes = live-wall VA-API decode pipelines currently built. If RSS climbs while playSec stays flat,
    // this is the path to watch — a livePipes count that ratchets up (not bounded by maxLiveDecodes) is the
    // live-wall pipeline leak (the GLib g_object_unref teardown failure leaking pipelines under reconnect churn).
    // framesIn vs frames(=delivered) is the decode-path-vs-present-path split, added
    // 2026-08-16. `frames` alone cannot distinguish "the decoder is slow" from "the
    // decoder is fine and the GUI thread is dropping four of every five" — the booth
    // read 3.2 fps/tile off it and reasonably, but wrongly, concluded the former.
    // coalesced counts frames the single-slot mailbox discarded undelivered:
    //   coalesced ≈ 0        → the GUI thread keeps up; a low rate is upstream of us
    //   coalesced large      → the PRESENT path is the limiter, not the decoder
    const long long fin = RtspVideoSource::totalFramesIn();
    const long long fdel = RtspVideoSource::totalFramesDelivered();
    const long long fco = RtspVideoSource::totalFramesCoalesced();
    // dec/lit/err are the lifecycle split (constructed vs decoder-bound vs
    // delivering vs errored) — livePipes alone conflated all four, which is how
    // "26 live" hid 5 pipelines with no decoder for a week. swd= is backstop
    // rebuilds (nonzero on a healthy wall means the QML recovery layers failed);
    // recon=ran/refused makes a requested-but-refused rebuild a number.
    qInfo("[MEMTEL] up=%llds rss=%ldMB playSec=%lld opens=%lld active=%d livePipes=%d "
          "frames=%lld framesIn=%lld coalesced=%lld drop=%.1f%% "
          "dec=%d lit=%d err=%d swd=%lld recon=%lld/%lld",
          static_cast<long long>(m_uptime.elapsed() / 1000), rssMb(),
          static_cast<long long>(playMs / 1000), static_cast<long long>(m_opens),
          static_cast<int>(m_playing.size()), RtspVideoSource::livePipelineCount(),
          fdel, fin, fco, fin > 0 ? (100.0 * double(fco) / double(fin)) : 0.0,
          RtspVideoSource::decoderBoundCount(), RtspVideoSource::litCount(),
          RtspVideoSource::erroredCount(), RtspVideoSource::watchdogRebuilds(),
          RtspVideoSource::reconnectRuns(), RtspVideoSource::reconnectNoops());
}
