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
