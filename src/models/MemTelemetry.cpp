#include "MemTelemetry.h"
#include "RtspVideoSource.h"
#if defined(Q_OS_LINUX)
#  include <malloc.h>            // mallinfo2/malloc_trim — glibc heap split + teardown trim
#endif   // live-wall pipeline/frame counters (the live decode path MEMTEL must also watch)

#include <QTimer>
#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLoggingCategory>

Q_LOGGING_CATEGORY(videoReadinessLog, "cilex.readiness")
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
#elif defined(Q_OS_MACOS)
#  include <mach/mach.h>         // task_info(MACH_TASK_BASIC_INFO) — the /proc/self/statm equivalent
#  include <malloc/malloc.h>     // malloc_get_all_zones/zone_statistics/pressure_relief — the
                                 //  libmalloc counterpart of mallinfo2/malloc_trim
#  include <unistd.h>            // getppid — the warden-eye parent watch (M1 defect #3:
                                 //  my mach branch took over this arm and dropped it)
#else
#  include <QFile>
#  include <QByteArrayList>
#  include <unistd.h>
#endif

// Component split for the MEMTEL line (operator order 2026-08-21: "which parts use
// memory" as first-party telemetry, not a soak-only external sampler). Values in MB;
// -1 = unmeasured on this platform/moment — absent is never zero. Linux reads
// /proc/self/status (RssAnon/RssFile/RssShmem) + mallinfo2 (glibc heap in-use vs
// retained-free); other platforms carry what their kernel offers.
struct MemParts { long anon = -1, file = -1, shmem = -1, heapUsed = -1, heapFree = -1; };
static MemParts memParts()
{
    MemParts mp;
#if defined(Q_OS_LINUX)
    QFile f(QStringLiteral("/proc/self/status"));   // RssAnon/RssFile/RssShmem live HERE (kB)
    if (f.open(QIODevice::ReadOnly)) {
        const QList<QByteArray> lines = f.readAll().split('\n');
        for (const QByteArray &l : lines) {
            if (l.startsWith("RssAnon:"))       mp.anon  = l.simplified().split(' ').value(1).toLong() / 1024;
            else if (l.startsWith("RssFile:"))  mp.file  = l.simplified().split(' ').value(1).toLong() / 1024;
            else if (l.startsWith("RssShmem:")) mp.shmem = l.simplified().split(' ').value(1).toLong() / 1024;
        }
    }
    struct mallinfo2 mi = mallinfo2();
    mp.heapUsed = long(mi.uordblks / (1024 * 1024));
    mp.heapFree = long(mi.fordblks / (1024 * 1024));   // freed but RETAINED by glibc arenas
#elif defined(Q_OS_MACOS)
    // WRITTEN ON LINUX, NEVER COMPILED ON A MAC (same status as the mach branch in
    // readRssMb; the operator's next mac build verifies). Was all -1 before 2026-08-22 —
    // honest, but five dead fields on every MEMTEL line. phys_footprint decomposition:
    // internal = anonymous resident (the decoder-arena signal the soaks watch),
    // external = file-backed. No per-task shm field on mach — shmem stays -1.
    task_vm_info_data_t vi;
    mach_msg_type_number_t vcnt = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO,
                  reinterpret_cast<task_info_t>(&vi), &vcnt) == KERN_SUCCESS) {
        mp.anon = long(vi.internal / (1024 * 1024));
        mp.file = long(vi.external / (1024 * 1024));
    }
    // libmalloc zone census: size_in_use = live blocks (heapU); size_allocated minus
    // in-use = zone-retained free pages (heapF — what pressure_relief can return).
    vm_address_t *zones = nullptr;
    unsigned zcount = 0;
    if (malloc_get_all_zones(mach_task_self(), nullptr, &zones, &zcount) == KERN_SUCCESS) {
        size_t used = 0, alloc = 0;
        for (unsigned i = 0; i < zcount; ++i) {
            malloc_statistics_t st {};
            malloc_zone_statistics(reinterpret_cast<malloc_zone_t *>(zones[i]), &st);
            used  += st.size_in_use;
            alloc += st.size_allocated;
        }
        mp.heapUsed = long(used / (1024 * 1024));
        mp.heapFree = long((alloc > used ? alloc - used : 0) / (1024 * 1024));
    }
#endif
    return mp;
}

static long rssMb()
{
#if defined(Q_OS_WIN)
    PROCESS_MEMORY_COUNTERS pmc;
    if (::GetProcessMemoryInfo(::GetCurrentProcess(), &pmc, sizeof(pmc)))
        return long(pmc.WorkingSetSize / (1024 * 1024));
    return -1;
#elif defined(Q_OS_MACOS)
    // WRITTEN ON LINUX, NEVER COMPILED ON A MAC (2026-08-16, M2 of the mac-port
    // plan verifies it). Standard mach call; resident_size is bytes.
    mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS)
        return long(info.resident_size / (1024 * 1024));
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
    const MemParts mpParts = memParts();
    const qint64 uptimeSeconds = m_uptime.elapsed() / 1000;
    qInfo("[MEMTEL] up=%llds rss=%ldMB playSec=%lld opens=%lld active=%d livePipes=%d "
          "frames=%lld framesIn=%lld coalesced=%lld drop=%.1f%% "
          "dec=%d lit=%d err=%d swd=%lld recon=%lld/%lld "
          "anon=%ldM file=%ldM shm=%ldM heapU=%ldM heapF=%ldM",
          static_cast<long long>(uptimeSeconds), rssMb(),
          static_cast<long long>(playMs / 1000), static_cast<long long>(m_opens),
          static_cast<int>(m_playing.size()), RtspVideoSource::livePipelineCount(),
          fdel, fin, fco, fin > 0 ? (100.0 * double(fco) / double(fin)) : 0.0,
          RtspVideoSource::decoderBoundCount(), RtspVideoSource::litCount(),
          RtspVideoSource::erroredCount(), RtspVideoSource::watchdogRebuilds(),
          RtspVideoSource::reconnectRuns(), RtspVideoSource::reconnectNoops(),
          mpParts.anon, mpParts.file, mpParts.shmem, mpParts.heapUsed, mpParts.heapFree);
    const QJsonObject video{{QStringLiteral("schema"), 1},
                            {QStringLiteral("up"), uptimeSeconds},
                            {QStringLiteral("sources"), RtspVideoSource::videoReadiness()}};
    qCInfo(videoReadinessLog).noquote() << "[VIDTEL]" << QJsonDocument(video).toJson(QJsonDocument::Compact);
}


// Teardown-trim experiment (2026-08-21 soak): glibc retains freed decode arenas
// (heapF in the MEMTEL line makes the retention visible); malloc_trim returns them to
// the OS. Called from the hero player after session teardown unless WT_NO_TRIM=1.
// Logs only when something moved, so quiet teardowns stay quiet.
void MemTelemetry::trimNow()
{
#if defined(Q_OS_LINUX)
    static const bool off = qEnvironmentVariableIsSet("WT_NO_TRIM");
    if (off)
        return;
    struct mallinfo2 before = mallinfo2();
    malloc_trim(0);
    struct mallinfo2 after = mallinfo2();
    // Signed math: fordblks is size_t and trim can leave it HIGHER (arena consolidation),
    // so unsigned subtraction wrapped to 2^44 "MB" in the first soak night — instrument
    // bug, owned in the 08-21 report; only positive releases are worth a line.
    const long long relMb = (static_cast<long long>(before.fordblks) - static_cast<long long>(after.fordblks)) / (1024 * 1024);
    if (relMb > 4)
        qInfo("[MEMTRIM] released=%lldMB retained_before=%ldMB", relMb,
              long(before.fordblks / (1024 * 1024)));
#elif defined(Q_OS_MACOS)
    // libmalloc's counterpart of malloc_trim: push zone-retained free pages back to
    // the OS. NULL zone = all zones. WRITTEN ON LINUX, NEVER COMPILED ON A MAC (the
    // operator's next mac build verifies). Same WT_NO_TRIM kill switch.
    static const bool off = qEnvironmentVariableIsSet("WT_NO_TRIM");
    if (off)
        return;
    const size_t rel = malloc_zone_pressure_relief(nullptr, 0);
    if (rel > 4u * 1024 * 1024)
        qInfo("[MEMTRIM] released=%lldMB (zone pressure relief)",
              static_cast<long long>(rel) / (1024 * 1024));
#endif
}
