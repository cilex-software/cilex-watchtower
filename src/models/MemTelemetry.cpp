#include "MemTelemetry.h"
#include "RtspVideoSource.h"   // live-wall pipeline/frame counters (the live decode path MEMTEL must also watch)

#include <QTimer>
#include <QFile>
#include <QByteArrayList>
#include <QDebug>
#include <unistd.h>

static long rssMb()
{
    QFile f(QStringLiteral("/proc/self/statm"));   // field 2 = resident pages
    if (!f.open(QIODevice::ReadOnly))
        return -1;
    const QByteArrayList p = f.readAll().simplified().split(' ');
    if (p.size() < 2)
        return -1;
    return (p[1].toLong() * (sysconf(_SC_PAGESIZE) / 1024)) / 1024;
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
    qInfo("[MEMTEL] up=%llds rss=%ldMB playSec=%lld opens=%lld active=%d livePipes=%d frames=%lld",
          static_cast<long long>(m_uptime.elapsed() / 1000), rssMb(),
          static_cast<long long>(playMs / 1000), static_cast<long long>(m_opens),
          static_cast<int>(m_playing.size()), RtspVideoSource::livePipelineCount(),
          static_cast<long long>(RtspVideoSource::totalFramesDelivered()));
}
