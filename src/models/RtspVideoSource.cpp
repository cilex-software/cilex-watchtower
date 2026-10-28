#include "RtspVideoSource.h"
#include "AvailabilityObservation.h"
#include "AvailabilityObservationBus.h"

#include <QVideoSink>
#include <QVideoFrame>
#include <QVideoFrameFormat>
#include <QMetaObject>
#include <limits>
#include <QHash>
#include <QCoreApplication>
#include <QPointer>
#include <QDebug>
#include <QUrl>
#include <QCryptographicHash>
#include <QUuid>
#include <QJsonObject>
#include <cstring>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <unordered_set>
#include <gst/video/video.h>
#include <gst/app/gstappsink.h>
#include <QTimer>
#include <QElapsedTimer>
#include <deque>
#include <algorithm>

namespace {
// Tracks live RtspVideoSource instances so the GStreamer streaming-thread
// callback can refuse to touch a destroyed `this`. The destructor erases under
// the same lock and BEFORE letting the QObject base destruct, so the callback
// either sees the instance and proceeds (under the lock) or skips it cleanly.
std::mutex &aliveMutex() { static std::mutex m; return m; }
std::unordered_set<RtspVideoSource *> &aliveSet()
{
    static std::unordered_set<RtspVideoSource *> s;
    return s;
}

// Cap concurrent in-flight pipeline teardowns. Each pipeline holds sockets +
// pipe-pair fds + its own worker thread; without a cap, rapid layout cycling
// stacks dozens of detached teardown threads, exhausting fds before GStreamer
// can drain them ("GWakeup: Too many open files"). 8 is well under any sane
// fd budget while still letting normal churn proceed without GUI blocking.
constexpr int kMaxConcurrentTeardowns = 8;
std::mutex &teardownMutex() { static std::mutex m; return m; }
std::condition_variable &teardownCv() { static std::condition_variable cv; return cv; }
int &teardownInflight() { static int n = 0; return n; }

static std::atomic<long long> g_swdRebuilds{0};
static std::atomic<long long> g_reconRuns{0};
static std::atomic<long long> g_reconNoops{0};
// Monotonic ms for watchdog arithmetic — GLib's clock, immune to NTP steps.
static qint64 steadyMs() { return g_get_monotonic_time() / 1000; }

// True if an NV12 frame is the decoder "empty surface": the all-zero buffer a decoder emits before a
// real keyframe (or for a wedged sub-stream). All-zero NV12 is Y≈0 AND chroma≈0, which renders as the
// notorious solid green RGB(0,135,0). The chroma test is what makes it surgical: a REAL black frame is
// Y≈0 but chroma≈128 (neutral), whereas the empty surface has chroma≈0 — so dark video is not flagged.
// O(1) — 6×6 sample grids on each plane.
bool isEmptyGreenNV12(const unsigned char *y, int yStride,
                      const unsigned char *uv, int uvStride, int w, int h)
{
    if (!y || !uv || w < 4 || h < 4)
        return false;
    constexpr int N = 6;
    int ymax = 0;
    for (int yi = 0; yi < N; ++yi)
        for (int xi = 0; xi < N; ++xi) {
            const int px = xi * (w - 1) / (N - 1);
            const int py = yi * (h - 1) / (N - 1);
            ymax = qMax(ymax, int(y[qsizetype(py) * yStride + px]));
        }
    if (ymax > 24)                       // any real luma → real video, keep it
        return false;
    int uvmax = 0;                       // chroma plane is half-size, bytes interleaved U,V
    const int cw = w / 2, ch = h / 2;
    for (int yi = 0; yi < N; ++yi)
        for (int xi = 0; xi < N; ++xi) {
            const int px = xi * (cw - 1) / (N - 1);
            const int py = yi * (ch - 1) / (N - 1);
            const unsigned char *p = uv + qsizetype(py) * uvStride + qsizetype(px) * 2;
            uvmax = qMax(uvmax, qMax(int(p[0]), int(p[1])));
        }
    return uvmax < 24;                   // chroma ≈ 0 (the green empty surface), not ≈128 (real black)
}

// Global pipeline-BUILD rate limiter (GUI-thread only). Creating a GStreamer/VA-API
// pipeline allocates a decode context on the shared iGPU; doing ~16 at once (a layout
// change, Arrange exit, page turn, app start) is the decode-context churn that wedges the
// chip — the Live-relayout freeze. So builds are SERIALIZED to at most one per
// kBuildStaggerMs: a burst comes up gradually (each tile shows its loading bar until its
// turn) instead of all at once. A lone build still starts immediately — the limiter only
// spaces out bursts. (Teardown is separately bounded by the kMaxConcurrentTeardowns
// semaphore, so create+destroy churn is capped on both sides.)
constexpr int kBuildStaggerMs = 120;
// WT_BUILD_STAGGER_MS overrides the stagger. Exists because of the 2026-08-16
// coordinated-restart verdict: on the booth's 6-core box, a 32-pipeline build
// burst wedges ~sqrt(N) readers' worth of streams — readers stop, the kernel
// closes its receive window, go2rtc times the consumer out, and its FIN queues
// forever behind bytes a zero-window connection will not carry (client socket
// stays ESTABLISHED on a stream that ended). Streams built AFTER the burst
// survived (death-forensics table: jb9, +3.2 s post-burst, lived). A/B knob,
// default unchanged until the booth measures; if slower builds eliminate the
// deaths, the Windows default gets set from that data.
static int buildStaggerMs()
{
    static const int v = qEnvironmentVariableIntValue("WT_BUILD_STAGGER_MS");
    return v > 0 ? v : kBuildStaggerMs;
}

class PipelineBuildPump
{
public:
    static PipelineBuildPump &instance()
    {
        // Leaked on purpose: a process-lifetime singleton, so RtspVideoSource destructors
        // during shutdown can't touch a destroyed pump (no static-destruction-order race).
        static PipelineBuildPump *p = new PipelineBuildPump();
        return *p;
    }
    void request(RtspVideoSource *src)
    {
        if (std::find(m_queue.begin(), m_queue.end(), src) == m_queue.end())
            m_queue.push_back(src);
        // One event-loop turn later, never inline: a view switch destroys the old surfaces
        // in the same event that creates the new one, and a pipeline the old owner PARKS
        // (see ParkingLot) must be in the lot before the new owner looks for it. Costs one
        // loop iteration on a lone build; the stagger logic itself is unchanged.
        m_timer.start(0);
    }
    // Is some queued (not yet built) source waiting for this URL? The parking lot keeps
    // such pipelines ahead of any other when it has to evict.
    bool wants(const QString &url) const
    {
        for (RtspVideoSource *s : m_queue)
            if (s->url() == url)
                return true;
        return false;
    }
    void cancel(RtspVideoSource *src)
    {
        m_queue.erase(std::remove(m_queue.begin(), m_queue.end(), src), m_queue.end());
    }
private:
    PipelineBuildPump()
    {
        m_timer.setSingleShot(true);
        QObject::connect(&m_timer, &QTimer::timeout, [this] { pump(); });
        m_clock.start();
    }
    void pump()
    {
        if (m_queue.empty())
            return;
        const qint64 since = m_clock.elapsed() - m_lastBuildMs;
        if (since >= buildStaggerMs()) {
            RtspVideoSource *src = m_queue.front();
            m_queue.pop_front();
            m_lastBuildMs = m_clock.elapsed();
            src->startPipelineNow();              // the actual gst build — one at a time
            if (!m_queue.empty())
                m_timer.start(buildStaggerMs());
        } else {
            m_timer.start(int(buildStaggerMs() - since));   // wait out the remaining gap
        }
    }
    QTimer m_timer;
    QElapsedTimer m_clock;
    qint64 m_lastBuildMs = -1000000;              // far in the past → first build is immediate
    std::deque<RtspVideoSource *> m_queue;
};
}

// ── Pipeline PARKING (2026-09-08, live-TTFF soak) ───────────────────────────────────────────
// Measured on the pilot fleet: a NEW RTSP consumer joins go2rtc's running producer mid-GOP,
// the camera's keyframe period is ~3.3 s (-sub) / ~4.0 s (main), and the VA decoder emits
// empty (green) surfaces until that keyframe — which onNewSample rightly discards. So a fresh
// pipeline on a warm producer shows its first real picture 0–3.3 s after PLAY (1.8–2.5 s in
// every measured open), while the wall's cold opens light in ~250 ms because a fresh camera
// session starts on an IDR. Opening a camera from the wall tears the tile's pipeline down and
// builds a new one for the detail view — the slow path, every single time.
//
// Parking closes that gap. A healthy, already-lit decode pipeline whose owner goes away is
// held here for a short grace period (WT_PARK_MS, default 2500; 0 disables) instead of being
// destroyed: callbacks detached, last frame kept, decoder still running. A source that wants
// the same URL inside the grace period ADOPTS it — same decoder, keyframe already seen, the
// last frame shown at once and live samples from the next one. Wall→detail, detail→wall and a
// quick page turn all hit it. Bounded: at most WT_PARK_MAX (default 4) parked, oldest evicted
// beyond that, so a page turn parks nothing for long and decode-context churn only goes DOWN
// (an adoption creates no VA context). GUI thread only, like the build pump.
struct ParkedPipeline {
    GstElement *pipeline = nullptr;
    QVideoFrame lastFrame;
    qint64 parkedAtMs = 0;
    bool decoderBound = false;
    int latencyMs = 150;
};
static int parkGraceMs()
{
    static const int v = qEnvironmentVariableIsSet("WT_PARK_MS")
                         ? qEnvironmentVariableIntValue("WT_PARK_MS") : 2500;
    return v;
}
static int parkMax()
{
    static const int v = qEnvironmentVariableIsSet("WT_PARK_MAX")
                         ? qEnvironmentVariableIntValue("WT_PARK_MAX") : 4;
    return v;
}
// The one way a pipeline dies (inline in teardown() until parking, 2026-09-08):
// gst_element_set_state(NULL) blocks while GStreamer tears down RTSP / releases the decoder —
// under tile-destruction churn (layout switch, page change) this stacked up on the GUI
// thread. Hand the pipeline to a detached worker so destruction returns immediately. The
// counting semaphore caps how many pipelines can be in flight at once: the GUI thread briefly
// waits if the cap is hit, which is the desired back-pressure (each in-flight pipeline holds
// RTSP sockets + GMainContext pipe-pair fds + a worker thread). Without it, mashing layouts
// piles up unbounded detached threads and exhausts fds.
static void destroyPipelineAsync(GstElement *p)
{
    {
        std::unique_lock<std::mutex> lock(teardownMutex());
        teardownCv().wait(lock, [] { return teardownInflight() < kMaxConcurrentTeardowns; });
        ++teardownInflight();
    }
    std::thread([p] {
        gst_element_set_state(p, GST_STATE_NULL);
        gst_object_unref(p);
        {
            std::lock_guard<std::mutex> lock(teardownMutex());
            --teardownInflight();
        }
        teardownCv().notify_one();
    }).detach();
}
class ParkingLot
{
public:
    // URLs the app is about to open (LiveHints::wantCamera): kept ahead of anything else.
    QHash<QString, qint64> m_hints;
    bool hinted(const QString &url) const
    {
        auto it = m_hints.find(url);
        return it != m_hints.end() && steadyMs() - it.value() < 5000;
    }
    void hint(const QString &url) { if (!url.isEmpty()) m_hints.insert(url, steadyMs()); }
    static ParkingLot &instance()
    {
        static ParkingLot *lot = new ParkingLot();   // leaked on purpose — same reason as the pump
        return *lot;
    }
    void park(const QString &url, ParkedPipeline e)
    {
        static const bool trace = qEnvironmentVariableIsSet("WT_TRACE");
        if (parkGraceMs() <= 0 || parkMax() <= 0) {
            destroyPipelineAsync(e.pipeline);
            return;
        }
        if (m_lot.contains(url))                       // newest pipeline for a URL wins
            destroyPipelineAsync(m_lot.take(url).pipeline);
        const auto &pump = PipelineBuildPump::instance();
        auto wanted = [&](const QString &u) { return pump.wants(u) || hinted(u); };
        while (m_lot.size() >= parkMax()) {
            // Evict the oldest pipeline nobody is waiting for; if every held one is wanted,
            // an unwanted newcomer loses instead, and only then the oldest wanted one.
            QString victim;
            qint64 t = std::numeric_limits<qint64>::max();
            for (auto it = m_lot.cbegin(); it != m_lot.cend(); ++it)
                if (!wanted(it.key()) && it->parkedAtMs < t) { t = it->parkedAtMs; victim = it.key(); }
            if (victim.isEmpty()) {
                if (!wanted(url)) {
                    destroyPipelineAsync(e.pipeline);
                    return;
                }
                for (auto it = m_lot.cbegin(); it != m_lot.cend(); ++it)
                    if (it->parkedAtMs < t) { t = it->parkedAtMs; victim = it.key(); }
            }
            if (trace)
                qInfo("[WT-PARK] evicted url=%s (for %s)", qUtf8Printable(QUrl(victim).toString(QUrl::RemoveUserInfo).right(40)),
                      qUtf8Printable(QUrl(url).toString(QUrl::RemoveUserInfo).right(40)));
            destroyPipelineAsync(m_lot.take(victim).pipeline);
        }
        if (trace)
            qInfo("[WT-PARK] parked url=%s frame=%s (%d held)",
                  qUtf8Printable(QUrl(url).toString(QUrl::RemoveUserInfo)),
                  e.lastFrame.isValid() ? "yes" : "no", int(m_lot.size()) + 1);
        m_lot.insert(url, std::move(e));
        if (!m_reaper.isActive())
            m_reaper.start();
    }
    bool take(const QString &url, ParkedPipeline &out)
    {
        m_hints.remove(url);
        auto it = m_lot.find(url);
        if (it == m_lot.end())
            return false;
        out = std::move(*it);
        m_lot.erase(it);
        return true;
    }
    int count() const { return int(m_lot.size()); }
private:
    ParkingLot()
    {
        m_reaper.setInterval(250);
        QObject::connect(&m_reaper, &QTimer::timeout, [this] { reap(); });
        if (auto *app = QCoreApplication::instance())
            QObject::connect(app, &QCoreApplication::aboutToQuit, [this] {
                for (auto &e : m_lot) destroyPipelineAsync(e.pipeline);
                m_lot.clear();
            });
    }
    void reap()
    {
        static const bool trace = qEnvironmentVariableIsSet("WT_TRACE");
        const qint64 now = steadyMs();
        for (auto it = m_lot.begin(); it != m_lot.end();) {
            if (now - it->parkedAtMs >= parkGraceMs()) {
                if (trace)
                    qInfo("[WT-PARK] expired url=%s after %lldms",
                          qUtf8Printable(QUrl(it.key()).toString(QUrl::RemoveUserInfo)),
                          (long long)(now - it->parkedAtMs));
                destroyPipelineAsync(it->pipeline);
                it = m_lot.erase(it);
            } else {
                ++it;
            }
        }
        if (m_lot.isEmpty())
            m_reaper.stop();
    }
    QTimer m_reaper;
    QHash<QString, ParkedPipeline> m_lot;
};
int RtspVideoSource::parkedPipelineCount() { return ParkingLot::instance().count(); }
void LiveHints::wantCamera(const QString &subUrl, const QString &mainUrl)
{
    ParkingLot::instance().hint(subUrl);
    ParkingLot::instance().hint(mainUrl);
    static const bool trace = qEnvironmentVariableIsSet("WT_TRACE");
    if (trace)
        qInfo("[WT-PARK] hint sub=%s main=%s", qUtf8Printable(QUrl(subUrl).toString(QUrl::RemoveUserInfo).right(40)),
              qUtf8Printable(QUrl(mainUrl).toString(QUrl::RemoveUserInfo).right(36)));
}

RtspVideoSource::RtspVideoSource(QObject *parent)
    : QObject(parent)
{
    {
        std::lock_guard<std::mutex> lock(aliveMutex());
        aliveSet().insert(this);
    }
    // WT_WALL_CHURN=<ms> (default 2000): test harness for the P0 live-wall leak. While set, each live source
    // repeatedly tears down + rebuilds its pipeline (the exact reconnect() crash path), so a per-teardown leak
    // accumulates fast — at a low WT_MAX_DECODES it reproduces the OOM mechanism safely + bounded. Inert
    // unless the env is set. Logs [WALLCHURN] livePipes each cycle (ratchet>cap = build/teardown imbalance;
    // stable count + rising RSS = the teardown unref / per-decode leak).
    if (qEnvironmentVariableIsSet("WT_WALL_CHURN")) {
        int ms = qEnvironmentVariableIntValue("WT_WALL_CHURN");
        if (ms <= 0) ms = 2000;
        auto *churn = new QTimer(this);
        connect(churn, &QTimer::timeout, this, [this]() {
            if (!m_active || m_url.isEmpty() || !m_sink)
                return;
            qInfo("[WALLCHURN] reconnect url=…%s livePipes=%d frames=%lld",
                  m_url.right(20).toUtf8().constData(), livePipelineCount(), totalFramesDelivered());
            reconnect();
        });
        churn->start(ms);
    }
}

RtspVideoSource::~RtspVideoSource()
{
    closeObservation(QStringLiteral("observer_destroyed"));
    // Remove from the alive set FIRST so any in-flight callback bails out
    // before it can call QMetaObject::invokeMethod on us.
    {
        std::lock_guard<std::mutex> lock(aliveMutex());
        aliveSet().erase(this);
    }
    teardown();
}

void RtspVideoSource::setUrl(const QString &u)
{
    if (m_url == u)
        return;
    if (m_url != u) closeObservation(QStringLiteral("stream_changed"));
    m_url = u;
    const QByteArray identity = QUrl(u).adjusted(QUrl::RemoveUserInfo | QUrl::RemoveQuery |
                                                QUrl::RemoveFragment).toEncoded();
    m_readinessId = QString::fromLatin1(QCryptographicHash::hash(identity, QCryptographicHash::Sha256).toHex());
    m_sinkFrames = 0;
    m_lastSinkFrameMs = 0;
    emit urlChanged();
    rebuild();
    updateObservationMonitoring();
}

void RtspVideoSource::setActive(bool a)
{
    if (m_active == a)
        return;
    m_active = a;
    emit activeChanged();
    rebuild();
    updateObservationMonitoring();
}

void RtspVideoSource::setVideoSink(QVideoSink *s)
{
    if (m_sink == s)
        return;
    m_sink = s;
    emit videoSinkChanged();
    rebuild();
    updateObservationMonitoring();
}

void RtspVideoSource::setLatencyMs(int ms)
{
    ms = qBound(0, ms, 5000);
    if (m_latencyMs == ms)
        return;
    m_latencyMs = ms;
    emit latencyMsChanged();
    m_noPark = true;    // a parked pipeline carries the OLD latency → build fresh
    rebuild();   // latency is set at pipeline build time
    m_noPark = false;
}

void RtspVideoSource::setWarmOnly(bool v)
{
    if (m_warmOnly == v) return;
    m_warmOnly = v;
    emit warmOnlyChanged();
    if (m_active && !m_url.isEmpty()) rebuild();   // mode change = different pipeline
    updateObservationMonitoring();
}

void RtspVideoSource::setCameraId(const QString &value)
{
    if (m_cameraId == value) return;
    closeObservation(QStringLiteral("camera_changed"));
    m_cameraId = value;
    emit observationIdentityChanged();
    updateObservationMonitoring();
}

void RtspVideoSource::setStreamVariant(const QString &value)
{
    const QString normalized = value == QLatin1String("main") || value == QLatin1String("sub")
        ? value : QStringLiteral("unknown");
    if (m_streamVariant == normalized) return;
    closeObservation(QStringLiteral("stream_changed"));
    m_streamVariant = normalized;
    emit observationIdentityChanged();
    updateObservationMonitoring();
}

void RtspVideoSource::setTransport(const QString &value)
{
    const QString normalized = value == QLatin1String("rtsp") || value == QLatin1String("tcp")
        ? value : QStringLiteral("unknown");
    if (m_transport == normalized) return;
    closeObservation(QStringLiteral("transport_changed"));
    m_transport = normalized;
    emit observationIdentityChanged();
    updateObservationMonitoring();
}

void RtspVideoSource::publishObservation(const QString &state, const QString &reason,
                                       const QString &requestedTransition)
{
    if (!m_observationMonitoring || m_observationState == state) return;
    QString transition = requestedTransition;
    if (transition.isEmpty()) {
        if (m_observationState.isEmpty()) transition = QStringLiteral("initial");
        else if (state == QLatin1String("available")
                 && (m_observationState == QLatin1String("unavailable")
                     || m_observationState == QLatin1String("degraded")))
            transition = QStringLiteral("recovery");
        else if (state == QLatin1String("unavailable") || state == QLatin1String("degraded"))
            transition = QStringLiteral("failure");
        else transition = QStringLiteral("state_change");
    }
    QVariantMap details {{QStringLiteral("observer_scope"), QStringLiteral("pipeline")},
        {QStringLiteral("pipeline_id"), m_observerSession},
        {QStringLiteral("stream_variant"), m_streamVariant},
        {QStringLiteral("transport"), m_transport},
        {QStringLiteral("threshold_ms"), wt::availability::liveConfirmationMs}};
    if (!m_observationPositiveAt.isEmpty())
        details[QStringLiteral("last_positive_at")] = m_observationPositiveAt;
    const bool gap = transition == QLatin1String("monitoring_gap")
        || transition == QLatin1String("monitoring_resumed");
    auto event = wt::availability::observation(m_cameraId,
        gap ? QStringLiteral("monitoring") : QStringLiteral("live_delivery"),
        QStringLiteral("client_observed"), state, transition, reason, details);
    AvailabilityObservationBus::publish(event);
    m_observationState = state;
}

void RtspVideoSource::closeObservation(const QString &reason)
{
    if (m_observationMonitoring)
        publishObservation(QStringLiteral("not_monitored"), reason, QStringLiteral("monitoring_gap"));
    m_observationMonitoring = false;
    m_observationState.clear();
    if (m_observationTimer) m_observationTimer->stop();
}

void RtspVideoSource::updateObservationMonitoring()
{
    const bool monitor = m_active && !m_warmOnly && m_sink && !m_url.isEmpty() && !m_cameraId.isEmpty();
    if (!monitor) { closeObservation(QStringLiteral("observer_inactive")); return; }
    if (m_observationMonitoring) return;
    m_observationMonitoring = true;
    m_observerSession = QUuid::createUuid().toString(QUuid::WithoutBraces);
    m_observationStartedMs = m_observationLastTickMs = steadyMs();
    m_observationLastWallMs = QDateTime::currentMSecsSinceEpoch();
    m_observationPositiveMs = -1;
    m_observationPositiveAt.clear();
    publishObservation(QStringLiteral("unknown"), QStringLiteral("awaiting_decoded_frame"));
    if (!m_observationTimer) {
        m_observationTimer = new QTimer(this);
        m_observationTimer->setInterval(5000);
        connect(m_observationTimer, &QTimer::timeout, this, &RtspVideoSource::observationTick);
    }
    m_observationTimer->start();
}

void RtspVideoSource::observationTick()
{
    updateObservationMonitoring();
    if (!m_observationMonitoring) return;
    const qint64 now = steadyMs();
    const qint64 wallNow = QDateTime::currentMSecsSinceEpoch();
    if (wt::availability::observationClockGap(m_observationLastTickMs, now, m_observationLastWallMs, wallNow)) {
        // A delayed GUI timer/suspend is missing observation, not a camera outage.
        publishObservation(QStringLiteral("not_monitored"), QStringLiteral("observer_scheduling_gap"),
                           QStringLiteral("monitoring_gap"));
        m_observationStartedMs = now;
        m_observationPositiveMs = -1;
        publishObservation(QStringLiteral("unknown"), QStringLiteral("observer_resumed"),
                           QStringLiteral("monitoring_resumed"));
    }
    m_observationLastTickMs = now;
    m_observationLastWallMs = wallNow;
    if (wt::availability::confirmedMissingFrame(m_observationStartedMs, m_observationPositiveMs, now))
        publishObservation(QStringLiteral("unavailable"), QStringLiteral("decoded_frame_timeout"));
}

void RtspVideoSource::reconnect()
{
    // A silent stall (no EOS, no error, just no buffers arriving) leaves the pipeline
    // reporting itself "playing" while the picture is frozen/green. The QML watchdog
    // calls this to force a clean rebuild. No-op when we're not meant to be streaming;
    // teardown() routes the old pipeline through the global teardown semaphore, so even
    // a burst of reconnects can't stack unbounded pipeline ops on the GUI thread.
    if (!m_active || m_url.isEmpty() || !m_sink) {
        ++g_reconNoops;   // a rebuild someone asked for and we refused — a number, not a silence
        return;
    }
    ++g_reconRuns;
    m_noPark = true;    // a stalled/errored pipeline must die, not be parked and re-adopted
    rebuild();
    m_noPark = false;
}

// BACKSTOP, not first line of defence. Two QML layers already own recovery:
// VideoSurface's coordinator-serialized reconnect (8 s cold start, backoff after
// first play) and CameraTile's error recycle (6/15/30/60 s, destroys the whole
// element). Both route through app-wide singletons that can wedge — the booth's
// five never-recovered pipelines and CV's collapse window 2 (consumers at 0,
// never rebuilt) carry exactly that signature. This layer shares nothing with
// them: its own QTimer per source, straight to reconnect(). Thresholds sit far
// above the QML layers' cadences, so on a healthy wall it is SILENT — a
// [WT-SWD] line in production means the primary layers failed.
// Env: WT_SWD_FIRST_S / WT_SWD_STALL_S override (test cadences),
// WT_STREAM_WATCHDOG_OFF disables, WT_WALL_CHURN implies off (harness owns
// reconnects), WT_RECON_OFF (QML layers disabled for isolation runs) hands the
// errored state to this layer too.
void RtspVideoSource::swdTick()
{
    static const bool off = qEnvironmentVariableIsSet("WT_STREAM_WATCHDOG_OFF")
                         || qEnvironmentVariableIsSet("WT_WALL_CHURN");
    static const bool qmlLayersOff = qEnvironmentVariableIsSet("WT_RECON_OFF");
    // Defaults raised 45/30 -> 75/75 on 2026-08-17 (booth §4 + CV's arithmetic:
    // go2rtc's own give-up policies are 45 s and 60 s, and a client that tears
    // down at 30 s ALWAYS jumps first — so the server's decision was never
    // observable, and the booth spent a night reading our own recycle storm as
    // server evictions. Client patience must exceed server policy: at 75 s the
    // server acts first, its RST/FIN (or its absence) becomes evidence, and the
    // backstop remains what its name says — the layer that acts when everyone
    // else has provably given up. The QML ladders are untouched: they fire on
    // bus ERRORS, which are signals, not silence.
    static const qint64 firstMs = qEnvironmentVariableIntValue("WT_SWD_FIRST_S") > 0
        ? qEnvironmentVariableIntValue("WT_SWD_FIRST_S") * 1000LL : 75000;
    static const qint64 stallMs = qEnvironmentVariableIntValue("WT_SWD_STALL_S") > 0
        ? qEnvironmentVariableIntValue("WT_SWD_STALL_S") * 1000LL : 75000;
    if (off || !m_active || m_url.isEmpty() || !m_sink)
        return;
    if (m_errored && !qmlLayersOff)
        return;                          // CameraTile's recycle owns the errored state
    const qint64 now = steadyMs();
    const qint64 last = m_deliveredSinceBuild ? m_lastDeliverMs
                                              : (m_builtAtMs ? m_builtAtMs : now);
    const qint64 need = m_deliveredSinceBuild ? stallMs : firstMs;
    if (now - last < need || now < m_swdNextMs)
        return;
    ++m_swdAttempts;
    ++g_swdRebuilds;
    const qint64 backoff = qMin<qint64>(firstMs << qMin(m_swdAttempts, 3), qint64(120000));
    m_swdNextMs = now + backoff;
    qWarning("[WT-SWD] %s attempt=%d silent=%llds backoff=%llds url=…%s",
             m_deliveredSinceBuild ? "stall" : "first-frame", m_swdAttempts,
             (long long)((now - last) / 1000), (long long)(backoff / 1000),
             m_url.right(24).toUtf8().constData());
    reconnect();
}

void RtspVideoSource::setPlaying(bool p)
{
    if (m_playing == p)
        return;
    m_playing = p;
    emit playingChanged();
}

void RtspVideoSource::setErrored(bool e, const QString &msg)
{
    // Log every entry into the errored state. Before this, GStreamer bus errors were set on the object
    // and shown on the tile but NEVER written to the flight recorder — so a wall full of dying streams
    // produced err=0 and an empty log, and the watchdog's 31 s silence was the only visible symptom.
    // Bare gst-launch against the same server logs "Could not receive message. (Parse error)" from
    // gst_rtspsrc_loop_interleaved; without this line we cannot tell whether the app dies the same way.
    if (e && m_errorText != msg)
        qWarning("[WT-ERR] %s — %s", qUtf8Printable(m_url.mid(m_url.lastIndexOf('/') + 1)), qUtf8Printable(msg));
    m_errorText = e ? msg : QString();
    if (m_errored != e) {
        m_errored = e;
        emit erroredChanged();
        if (e) publishObservation(QStringLiteral("degraded"), QStringLiteral("pipeline_error"));
    }
}

// P0 memory-trace diagnostics (see header): live GStreamer pipelines + total frames delivered.
static std::atomic<int> g_livePipelines{0};
static std::atomic<long long> g_totalFrames{0};
// Decode-side counters (see onNewSample). g_framesIn is what the appsink handed us;
// g_framesCoalesced is what the single-slot mailbox threw away because the GUI thread
// had not drained the previous frame yet. g_totalFrames is what reached a sink.
//   framesIn ≈ totalFrames            → the GUI thread is keeping up; a low rate is upstream
//   framesIn >> totalFrames           → the decoder is fine and the PRESENT path is the limiter
static std::atomic<long long> g_framesIn{0};
static std::atomic<long long> g_framesCoalesced{0};
int RtspVideoSource::livePipelineCount() { return g_livePipelines.load(); }
long long RtspVideoSource::totalFramesDelivered() { return g_totalFrames.load(); }
long long RtspVideoSource::totalFramesIn() { return g_framesIn.load(); }
long long RtspVideoSource::totalFramesCoalesced() { return g_framesCoalesced.load(); }
long long RtspVideoSource::watchdogRebuilds() { return g_swdRebuilds.load(); }
long long RtspVideoSource::reconnectRuns() { return g_reconRuns.load(); }
long long RtspVideoSource::reconnectNoops() { return g_reconNoops.load(); }
// Gauge accessors iterate the alive-set (GUI thread; instances mutate their own
// fields on the GUI thread, m_decoderBound is the one streaming-thread write).
int RtspVideoSource::decoderBoundCount()
{
    std::lock_guard<std::mutex> lock(aliveMutex());
    int n = 0;
    for (RtspVideoSource *s : aliveSet())
        if (s->m_decoderBound.load() && s->m_pipeline) ++n;
    return n;
}
int RtspVideoSource::litCount()
{
    std::lock_guard<std::mutex> lock(aliveMutex());
    const qint64 now = steadyMs();
    int n = 0;
    for (RtspVideoSource *s : aliveSet())
        if (s->m_lastDeliverMs && now - s->m_lastDeliverMs <= 5000) ++n;
    return n;
}
int RtspVideoSource::erroredCount()
{
    std::lock_guard<std::mutex> lock(aliveMutex());
    int n = 0;
    for (RtspVideoSource *s : aliveSet())
        if (s->m_errored) ++n;
    return n;
}

QJsonArray RtspVideoSource::videoReadiness()
{
    std::lock_guard<std::mutex> lock(aliveMutex());
    const qint64 now = steadyMs();
    QJsonArray sources;
    for (const RtspVideoSource *s : aliveSet()) {
        // Include pending and stalled sources: omitting them would let a smaller
        // healthy subset masquerade as a fully advancing wall.
        if (!s->m_active || s->m_warmOnly || s->m_url.isEmpty() || !s->m_sink ||
            (s->m_pipeline && s->m_pipelineWarmOnly))
            continue;
        sources.append(QJsonObject{
            {QStringLiteral("id"), s->m_readinessId},
            {QStringLiteral("frames"), s->m_sinkFrames},
            {QStringLiteral("age_ms"), s->m_lastSinkFrameMs
                ? QJsonValue(now - s->m_lastSinkFrameMs) : QJsonValue(QJsonValue::Null)},
            {QStringLiteral("decoder"), s->m_pipeline && s->m_decoderBound.load()},
            {QStringLiteral("error"), s->m_errored}
        });
    }
    return sources;
}

void RtspVideoSource::teardown()
{
    PipelineBuildPump::instance().cancel(this);   // drop any queued (not-yet-started) build
    {
        // Detaching callbacks does not cancel a sample already being copied.
        // Revoke its right to publish before detaching/reusing the pipeline.
        std::lock_guard<std::mutex> flock(m_frameMutex);
        m_frameSource = nullptr;
        m_pendingFrame = QVideoFrame();
    }
    if (m_busWatch) {
        g_source_remove(m_busWatch);
        m_busWatch = 0;
    }
    if (m_bus) {
        gst_object_unref(m_bus);
        m_bus = nullptr;
    }
    if (m_pipeline) {
        --g_livePipelines;   // P0 trace: a built pipeline is leaving this source (parked or destroyed)
        GstElement *p = m_pipeline;
        m_pipeline = nullptr;
        // Detach everything that carries `this` — whether the pipeline dies or is parked for
        // adoption, no callback may reach this object once teardown() returns.
        if (GstElement *sinkEl = gst_bin_get_by_name(GST_BIN(p), "sink")) {
            GstAppSinkCallbacks empty = {};
            gst_app_sink_set_callbacks(GST_APP_SINK(sinkEl), &empty, nullptr, nullptr);
            gst_object_unref(sinkEl);
        }
        if (GstElement *dec = gst_bin_get_by_name(GST_BIN(p), "dec")) {
            g_signal_handlers_disconnect_by_data(dec, this);
            gst_object_unref(dec);
        }
        // A healthy, already-lit decode pipeline is parked for adoption (see ParkingLot);
        // everything else dies as before.
        const bool parkable = !m_pipelineWarmOnly && !m_noPark && m_deliveredSinceBuild && !m_errored
                              && parkGraceMs() > 0 && !m_pipelineUrl.isEmpty();
        if (parkable) {
            ParkedPipeline e;
            e.pipeline = p;
            e.lastFrame = m_lastFrame;
            e.parkedAtMs = steadyMs();
            e.decoderBound = m_decoderBound.load();
            e.latencyMs = m_latencyMs;
            ParkingLot::instance().park(m_pipelineUrl, std::move(e));
        } else {
            destroyPipelineAsync(p);
        }
    }
    m_pipelineUrl.clear();
    m_pipelineWarmOnly = false;
    m_lastFrame = QVideoFrame();
    setPlaying(false);
}

void RtspVideoSource::rebuild()
{
    m_sawFirstSample = false;
    teardown();
    setErrored(false);
    if (!m_active || m_url.isEmpty() || !m_sink)
        return;
    // A parked pipeline for this URL beats any build: no VA context, no keyframe wait.
    if (!m_warmOnly && tryAdoptParked())
        return;
    // Don't build inline. Route through the global rate limiter so a burst of tiles
    // becoming active at once (layout change, Arrange exit, page turn, app start) can't
    // create N VA-API decode contexts simultaneously — that churn wedges the shared iGPU
    // (the relayout freeze). A lone build still starts immediately (see PipelineBuildPump).
    PipelineBuildPump::instance().request(this);
}

// Decoder-selection diagnostics + policy for the live GStreamer path. decodebin auto-picks a decoder:
// VA-API on Linux, and on Windows it SHOULD pick the D3D11/DXVA hardware decoder — never a bundled
// SOFTWARE H.264/H.265 decoder, which costs CPU and carries codec-patent exposure the OS/GPU path avoids.
// These callbacks read only env (no instance state) so they are safe on the streaming thread.
//
// onAutoplugSelect runs per candidate decoder: under WT_TRACE it logs the codec + factory + HW/SW, and
// under WT_HW_ONLY it SKIPs any non-hardware video decoder (decodebin then tries the next, or fails — the
// tile errors and the reconnect watchdog retries — rather than silently software-decoding).
// decodebin's GstAutoplugSelectResult enum is plugin-private (no public header); use its integer values.
enum { WtAutoplugTry = 0, WtAutoplugExpose = 1, WtAutoplugSkip = 2 };
static gint onAutoplugSelect(GstElement *, GstPad *, GstCaps *caps,
                             GstElementFactory *factory, gpointer)
{
    const char *klass = gst_element_factory_get_klass(factory);
    if (!klass || !std::strstr(klass, "Decoder") || !std::strstr(klass, "Video"))
        return WtAutoplugTry;
    const bool isHardware = std::strstr(klass, "Hardware") != nullptr;
    static const bool hwOnly = qEnvironmentVariableIsSet("WT_HW_ONLY");
    static const bool trace  = qEnvironmentVariableIsSet("WT_TRACE");
    const bool skip = hwOnly && !isHardware;
    if (trace) {
        const char *codec = (caps && gst_caps_get_size(caps) > 0)
            ? gst_structure_get_name(gst_caps_get_structure(caps, 0)) : "?";
        qInfo().noquote() << "[WT-DEC]" << codec << "candidate"
                          << gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory))
                          << (isHardware ? "(hardware)" : "(SOFTWARE)")
                          << (skip ? "-> SKIPPED (WT_HW_ONLY)" : "-> try");
    }
    return skip ? WtAutoplugSkip : WtAutoplugTry;
}

// onDeepDecoderAdded logs the decoder actually instantiated (the definitive "what is running") under
// WT_TRACE — autoplug-select only shows candidates considered, not the final binding.
static void onDeepDecoderAdded(GstBin *, GstBin *, GstElement *element, gpointer user)
{
    GstElementFactory *f = gst_element_get_factory(element);
    const char *klass = f ? gst_element_factory_get_klass(f) : nullptr;
    if (!klass || !std::strstr(klass, "Decoder") || !std::strstr(klass, "Video"))
        return;
    // Streaming thread — the one fact recorded here feeds the dec= gauge. Until
    // 2026-08-16 this was trace-only, which is why "26 built / 21 with decoders"
    // was something the booth had to measure with external tooling.
    static_cast<RtspVideoSource *>(user)->noteDecoderBound();
    static const bool trace = qEnvironmentVariableIsSet("WT_TRACE");
    if (!trace)
        return;
    qInfo().noquote() << "[WT-DEC] using" << gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(f))
                      << (std::strstr(klass, "Hardware") ? "(hardware)" : "(SOFTWARE - patent/perf risk)");
}

void RtspVideoSource::startPipelineNow()
{
    // Invoked by the global build pump (staggered). Re-check we still want to stream and
    // hold no pipeline — state can change between the request and the drain.
    if (m_pipeline || !m_active || m_url.isEmpty() || !m_sink)
        return;
    if (!m_warmOnly && tryAdoptParked())   // the old owner may have parked since we queued
        return;
    qstrncpy(m_urlTag, QUrl(m_url).toString(QUrl::RemoveUserInfo).right(38).toUtf8().constData(), sizeof m_urlTag);

    // decodebin picks VA-API on the Intel iGPU. We pull NV12 (the native decode format, 1.5 B/px) —
    // NOT RGBA (4 B/px) — so each frame buffer is ~2.5× smaller and there is no CPU colour-conversion:
    // we hand NV12 to the QVideoSink and Qt's video shader does NV12→RGB on the GPU. videoconvert is a
    // passthrough when the decoder already outputs NV12 (it does for H.264/H.265 VA decode). The URL is
    // set on the element rather than baked into the parse string to avoid escaping the creds.
    GError *err = nullptr;
    // Measurement knob (WT_DECODE_SCALE=WxH, e.g. "480x270"): insert a videoscale so the post-decode
    // frame buffers (appsink NV12 → QVideoFrame → texture — the RSS-resident copies, NOT the GPU decode
    // surfaces) are produced at WxH instead of native 720p. Lets us MEASURE the per-tile frame-buffer
    // saving of display-resolution rendering before committing to the real (dynamic) implementation.
    // WT_RTSP_QUEUE_MS=<ms>: decouple the RTSP socket reader from the decoder.
    //
    // Without a queue here, rtspsrc's streaming thread drives decodebin SYNCHRONOUSLY — the thread that
    // drains the TCP socket is the same thread that waits on the decoder. go2rtc serves RTSP over TCP
    // interleaved ONLY (UDP SETUP is refused: "No supported stream was found", measured 2026-08-16 with
    // gst-launch against the pilot box), so media rides the one transport where a stalled reader is fatal:
    // a decoder that blocks — e.g. D3D12 output-surface contention with N decoders on one iGPU — stops the
    // socket being read, the receive window goes to zero, go2rtc's write blocks until its read timeout and
    // it close()s the session. The stream does not slow down; it dies. That is the zero-window fault CV
    // captured on the wire, and it is why deaths are random per-stream and immune to build pacing.
    //
    // A leaky queue makes the reader independent of decode: under fault we lose RTP packets (recoverable at
    // the next keyframe, exactly like normal UDP loss) instead of losing the stream. This does NOT change
    // any configured frame rate — the fleet still broadcasts at 15 and nothing here resamples; the queue
    // only sheds under a decoder stall that would otherwise kill the connection outright.
    const int qms = qEnvironmentVariableIntValue("WT_RTSP_QUEUE_MS");
    QByteArray rtspQ;
    if (qms > 0) {
        rtspQ = QByteArray("! queue name=q leaky=downstream max-size-buffers=0 max-size-bytes=0 "
                           "max-size-time=") + QByteArray::number(qint64(qms) * 1000000) + " ";
        qInfo("[WT-Q] reader/decoder decoupling active — %d ms leaky queue after rtspsrc", qms);
    }

    QByteArray pipeStr =
        "rtspsrc name=src drop-on-latency=true " + rtspQ + "! decodebin name=dec ! videoconvert "
        "! video/x-raw,format=NV12 ! appsink name=sink sync=false max-buffers=2 drop=true";
    if (m_warmOnly) {
        // Consumer only: depayload and discard. No decodebin, no appsink, no frames — the
        // sole purpose is to be "a consumer" so go2rtc keeps the producer dialled.
        // (Claim about go2rtc, written 2026-09-08 and not re-checked since.)
        pipeStr = "rtspsrc name=src drop-on-latency=true ! rtph264depay ! fakesink sync=false";
        qInfo("[WT-WARM] warm-keep consumer (no decode) for %s",
              qUtf8Printable(QUrl(m_url).toString(QUrl::RemoveUserInfo)));
    }
    const QList<QByteArray> wh = qgetenv("WT_DECODE_SCALE").split('x');
    if (wh.size() == 2 && !wh[0].trimmed().isEmpty() && !wh[1].trimmed().isEmpty()) {
        pipeStr = QByteArray(
            "rtspsrc name=src drop-on-latency=true ") + rtspQ + "! decodebin name=dec ! videoscale ! videoconvert "
            "! video/x-raw,format=NV12,width=" + wh[0].trimmed() + ",height=" + wh[1].trimmed() +
            " ! appsink name=sink sync=false max-buffers=2 drop=true";
        qInfo("[WT-RES] WT_DECODE_SCALE active — decoding to %s", pipeStr.mid(pipeStr.indexOf("width=")).constData());
    }
    m_pipeline = gst_parse_launch(pipeStr.constData(), &err);
    if (!m_pipeline) {
        setErrored(true, err ? QString::fromUtf8(err->message) : QStringLiteral("pipeline build failed"));
        if (err) g_error_free(err);
        return;
    }
    if (err) g_error_free(err);
    m_pipelineUrl = m_url;
    m_pipelineWarmOnly = m_warmOnly;

    // WT_WALL_BADURL=<url>: test harness — force pipelines onto an unresponsive/erroring source so the churn
    // (WT_WALL_CHURN) tears down BAD-STATE pipelines (the go2rtc-instability path the crash hit), not healthy
    // ones. e.g. rtsp://192.0.2.1:554/x (TEST-NET black-hole → rtspsrc hangs connecting) or a 404 stream.
    const QByteArray loc = qEnvironmentVariableIsSet("WT_WALL_BADURL")
                           ? qgetenv("WT_WALL_BADURL") : m_url.toUtf8();
    if (GstElement *src = gst_bin_get_by_name(GST_BIN(m_pipeline), "src")) {
        g_object_set(src, "location", loc.constData(),
                          "latency", guint(m_latencyMs), nullptr);
        if (qEnvironmentVariableIsSet("WT_RTSP_TCP"))   // force TCP-interleaved so a TCP proxy carries media
            g_object_set(src, "protocols", 0x4 /* GST_RTSP_LOWER_TRANS_TCP */, nullptr);
        gst_object_unref(src);
    }
    if (GstElement *sinkEl = gst_bin_get_by_name(GST_BIN(m_pipeline), "sink")) {
        {
            std::lock_guard<std::mutex> flock(m_frameMutex);
            m_frameSource = GST_APP_SINK(sinkEl);
        }
        GstAppSinkCallbacks cbs = {};
        cbs.new_sample = &RtspVideoSource::onNewSample;
        gst_app_sink_set_callbacks(GST_APP_SINK(sinkEl), &cbs, this, nullptr);
        gst_object_unref(sinkEl);
    }

    // Watch (and optionally enforce) which decoder decodebin binds — so a Windows build can VERIFY it
    // runs DXVA/D3D11 hardware decode, never a bundled software H.264/H.265 decoder (perf + codec-patent
    // exposure). WT_TRACE logs the codec + decoder; WT_HW_ONLY refuses software video decoders outright.
    if (GstElement *dec = gst_bin_get_by_name(GST_BIN(m_pipeline), "dec")) {
        g_signal_connect(dec, "autoplug-select", G_CALLBACK(onAutoplugSelect), nullptr);
        g_signal_connect(dec, "deep-element-added", G_CALLBACK(onDeepDecoderAdded), this);
        gst_object_unref(dec);
    }

    m_bus = gst_element_get_bus(m_pipeline);
    m_busWatch = gst_bus_add_watch(m_bus, &RtspVideoSource::onBus, this);

    gst_element_set_state(m_pipeline, GST_STATE_PLAYING);
    // [LIVETIME] stage marker: the pipeline was asked to PLAY. Paired with the
    // surface's "playing dt=" line, the gap between the two is RTSP connect +
    // first-keyframe wait — the part a client cannot shorten, only measure.
    qInfo("[LIVETIME] pipeline_playing url=%s", qUtf8Printable(QUrl(m_url).toString(QUrl::RemoveUserInfo)));
    ++g_livePipelines;   // P0 trace: a new pipeline is now live

    // Arm the backstop watchdog (never stopped once started: after an
    // error-teardown the tick is exactly what brings the stream back).
    m_decoderBound.store(false);
    m_deliveredSinceBuild = false;
    m_builtAtMs = steadyMs();
    armWatchdog();
}
void RtspVideoSource::armWatchdog()
{
    if (!m_swd) {
        m_swd = new QTimer(this);
        m_swd->setInterval(5000);
        connect(m_swd, &QTimer::timeout, this, &RtspVideoSource::swdTick);
    }
    if (!m_swd->isActive())
        m_swd->start();
}
bool RtspVideoSource::tryAdoptParked()
{
    if (m_noPark)
        return false;
    ParkedPipeline e;
    if (!ParkingLot::instance().take(m_url, e))
        return false;
    if (e.latencyMs != m_latencyMs) {           // a different pipeline — not this one
        destroyPipelineAsync(e.pipeline);
        return false;
    }
    GstBus *bus = gst_element_get_bus(e.pipeline);
    const guint watch = bus ? gst_bus_add_watch(bus, &RtspVideoSource::onBus, this) : 0;
    if (!watch) {
        // Without its bus we cannot own its errors → not safe to adopt; build fresh instead.
        qWarning("[WT-PARK] adopt refused (no bus watch) url=…%s", qUtf8Printable(m_url.right(24)));
        if (bus) gst_object_unref(bus);
        destroyPipelineAsync(e.pipeline);
        return false;
    }
    m_pipeline = e.pipeline;
    m_pipelineUrl = m_url;
    m_pipelineWarmOnly = false;
    m_bus = bus;
    m_busWatch = watch;
    qstrncpy(m_urlTag, QUrl(m_url).toString(QUrl::RemoveUserInfo).right(38).toUtf8().constData(), sizeof m_urlTag);
    if (GstElement *sinkEl = gst_bin_get_by_name(GST_BIN(m_pipeline), "sink")) {
        {
            std::lock_guard<std::mutex> flock(m_frameMutex);
            m_frameSource = GST_APP_SINK(sinkEl);
        }
        GstAppSinkCallbacks cbs = {};
        cbs.new_sample = &RtspVideoSource::onNewSample;
        gst_app_sink_set_callbacks(GST_APP_SINK(sinkEl), &cbs, this, nullptr);
        gst_object_unref(sinkEl);
    }
    if (GstElement *dec = gst_bin_get_by_name(GST_BIN(m_pipeline), "dec")) {
        g_signal_connect(dec, "deep-element-added", G_CALLBACK(onDeepDecoderAdded), this);
        gst_object_unref(dec);
    }
    ++g_livePipelines;
    m_decoderBound.store(e.decoderBound);
    m_deliveredSinceBuild = false;
    m_sawFirstSample = true;             // the "adopted" line below stands in for first_sample
    m_builtAtMs = steadyMs();
    armWatchdog();
    const qint64 parkedFor = steadyMs() - e.parkedAtMs;
    if (e.lastFrame.isValid() && m_sink) {
        // Same URL = same camera. The parked picture is at most parkGraceMs() old and beats a
        // blank (stability rule) until the next live sample replaces it, one frame later.
        m_lastFrame = e.lastFrame;
        m_sink->setVideoFrame(e.lastFrame);
        setErrored(false);
        setPlaying(true);
        ++g_totalFrames;
        m_lastDeliverMs = steadyMs();
        m_deliveredSinceBuild = true;
    }
    qInfo("[LIVETIME] adopted url=%s parked_for=%lldms frame=%s decoder=%s",
          qUtf8Printable(QUrl(m_url).toString(QUrl::RemoveUserInfo)), (long long)parkedFor,
          e.lastFrame.isValid() ? "yes" : "no", e.decoderBound ? "bound" : "pending");
    return true;
}

GstFlowReturn RtspVideoSource::onNewSample(GstAppSink *sink, gpointer self)
{
    // Runs on a GStreamer streaming thread. Build the frame here, then marshal
    // delivery to the GUI thread (where the QVideoSink lives).
    auto *me = static_cast<RtspVideoSource *>(self);
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample)
        return GST_FLOW_ERROR;

    GstCaps *caps = gst_sample_get_caps(sample);
    GstVideoInfo info;
    GstBuffer *buf = gst_sample_get_buffer(sample);
    GstVideoFrame vframe;
    QVideoFrame frame;
    if (caps && gst_video_info_from_caps(&info, caps)
        && GST_VIDEO_INFO_FORMAT(&info) == GST_VIDEO_FORMAT_NV12   // pipeline forces NV12; guard defensively
        && gst_video_frame_map(&vframe, &info, buf, GST_MAP_READ)) {
        const int w = GST_VIDEO_INFO_WIDTH(&info);
        const int h = GST_VIDEO_INFO_HEIGHT(&info);
        static thread_local bool resLogged = false;   // WT_TRACE: log each pipeline's decode resolution once
        if (!resLogged && qEnvironmentVariableIsSet("WT_TRACE")) {
            resLogged = true;
            qInfo().noquote() << "[WT-RES] decode" << w << "x" << h << "→ NV12 buffer" << (w * h * 3 / 2 / 1024) << "KB/frame";
        }
        // Carry the stream's colour space + range so Qt's NV12→RGB matches the source (otherwise
        // the GPU shader assumes a default and colours wash out / green-shift). videoconvert used to
        // bake this in for us; now we convert on the GPU, so we must pass it through.
        QVideoFrameFormat fmt(QSize(w, h), QVideoFrameFormat::Format_NV12);
        switch (GST_VIDEO_INFO_COLORIMETRY(&info).matrix) {
        case GST_VIDEO_COLOR_MATRIX_BT601:  fmt.setColorSpace(QVideoFrameFormat::ColorSpace_BT601);  break;
        case GST_VIDEO_COLOR_MATRIX_BT2020: fmt.setColorSpace(QVideoFrameFormat::ColorSpace_BT2020); break;
        default:                            fmt.setColorSpace(QVideoFrameFormat::ColorSpace_BT709);  break;
        }
        fmt.setColorRange(GST_VIDEO_INFO_COLORIMETRY(&info).range == GST_VIDEO_COLOR_RANGE_0_255
                          ? QVideoFrameFormat::ColorRange_Full : QVideoFrameFormat::ColorRange_Video);
        QVideoFrame f(fmt);
        if (f.map(QVideoFrame::WriteOnly)) {
            // Copy the two NV12 planes honouring each side's stride: Y (h rows) then the
            // interleaved UV chroma plane (h/2 rows). No colour conversion — Qt's video shader
            // does NV12→RGB on the GPU, so we never build the big RGBA buffer.
            const unsigned char *srcY = static_cast<const unsigned char *>(GST_VIDEO_FRAME_PLANE_DATA(&vframe, 0));
            const int srcYStride = GST_VIDEO_FRAME_PLANE_STRIDE(&vframe, 0);
            const int dstYStride = f.bytesPerLine(0);
            const int yCopy = qMin(srcYStride, dstYStride);
            for (int y = 0; y < h; ++y)
                std::memcpy(f.bits(0) + qsizetype(y) * dstYStride, srcY + qsizetype(y) * srcYStride, yCopy);
            const unsigned char *srcUV = static_cast<const unsigned char *>(GST_VIDEO_FRAME_PLANE_DATA(&vframe, 1));
            const int srcUVStride = GST_VIDEO_FRAME_PLANE_STRIDE(&vframe, 1);
            const int dstUVStride = f.bytesPerLine(1);
            const int uvCopy = qMin(srcUVStride, dstUVStride);
            for (int y = 0; y < h / 2; ++y)
                std::memcpy(f.bits(1) + qsizetype(y) * dstUVStride, srcUV + qsizetype(y) * srcUVStride, uvCopy);
            // Drop the decoder "empty surface" (flat green) BEFORE delivering — the VideoSurface
            // stays covered and the reconnect watchdog keeps trying, so the operator never sees green.
            const bool empty = isEmptyGreenNV12(f.bits(0), dstYStride, f.bits(1), dstUVStride, w, h);
            f.unmap();
            if (!empty)
                frame = f;
        }
        gst_video_frame_unmap(&vframe);
    }
    gst_sample_unref(sample);
    // [LIVETIME] first sample at the appsink (streaming thread), green or not — paired with
    // first_deliver it splits "decoder produced a frame" from "the GUI got a real one".
    // Behind the alive check, reading only POD fields: `me` may be mid-destruction.
    {
        // Streaming-thread → GUI-thread hop, COALESCED. Posting EVERY decoded frame via a
        // QueuedConnection is unbounded: 16 pipelines × 15 fps = 240 frames/s, each holding a
        // full RGBA buffer (~3.7 MB). When the GUI thread falls behind (picker render, relayout)
        // they pile up in the event queue and RSS explodes to many GB → OOM kill. So we keep
        // only the LATEST frame in a single-slot mailbox and post at most ONE pending deliver();
        // newer frames replace the unconsumed one (correct for live monitoring — the freshest
        // frame is what we want). Memory is then bounded to one frame per pipeline.
        // Guard 1: under the alive-set lock, confirm `me` wasn't destroyed mid-callback.
        // Guard 2: a QPointer so a queued deliver() on a since-deleted object is a no-op.
        std::lock_guard<std::mutex> lock(aliveMutex());
        if (aliveSet().count(me) == 0)
            return GST_FLOW_OK;
        bool needPost = false;
        {
            std::lock_guard<std::mutex> flock(me->m_frameMutex);
            if (me->m_frameSource != sink)
                return GST_FLOW_OK; // a callback from a camera we have left
            if (!me->m_sawFirstSample) {
                me->m_sawFirstSample = true;
                qInfo("[LIVETIME] first_sample url=%s", me->m_urlTag);
            }
            if (!frame.isValid())
                return GST_FLOW_OK;
            // Count what ARRIVES here and what dies here. Until 2026-08-16 neither was
            // counted: `g_totalFrames` increments in deliver() and VideoSurface's own
            // tick fires on QVideoSink::videoFrameChanged, so BOTH existing frame
            // counters measure frames that reached the screen. The booth read
            // 3.2 fps/tile off the delivered counter and concluded the decoder was
            // running at a fifth of the fleet rate — but that counter cannot see the
            // decoder. A decoder running at a full 15 fps with four of every five
            // frames coalesced away right here produces exactly the same reading.
            //
            // So: framesIn is the decode-side rate, framesCoalesced is what the GUI
            // thread could not keep up with, and the difference between framesIn and
            // g_totalFrames is the loss. Same lesson as livePipes counting
            // construction instead of attachment — measure the thing, not its shadow.
            ++g_framesIn;
            ++me->m_framesIn;
            if (me->m_pendingFrame.isValid()) {         // replacing an UNDELIVERED frame
                ++g_framesCoalesced;
                ++me->m_framesCoalesced;
            }
            me->m_pendingFrame = frame;                 // drop any undelivered older frame
            me->m_pendingArrivedMs = steadyMs();
            me->m_pendingArrivedWallMs = QDateTime::currentMSecsSinceEpoch();
            if (!me->m_deliverQueued) { me->m_deliverQueued = true; needPost = true; }
        }
        if (needPost) {
            QPointer<RtspVideoSource> guard(me);
            QMetaObject::invokeMethod(me, [guard]() { if (guard) guard->deliver(); }, Qt::QueuedConnection);
        }
    }
    return GST_FLOW_OK;
}

void RtspVideoSource::deliver()
{
    // [LIVETIME] first GUI-thread delivery for this pipeline — paired with first_sample
    // (GStreamer thread) it splits "decoder produced a frame" from "the GUI got it".
    if (!m_deliveredSinceBuild)
        qInfo("[LIVETIME] first_deliver url=%s", qUtf8Printable(QUrl(m_url).toString(QUrl::RemoveUserInfo).right(40)));
    QVideoFrame frame;
    qint64 arrivedAt = -1;
    qint64 arrivedWall = -1;
    {
        std::lock_guard<std::mutex> flock(m_frameMutex);
        frame = m_pendingFrame;
        arrivedAt = m_pendingArrivedMs;
        arrivedWall = m_pendingArrivedWallMs;
        m_pendingArrivedMs = -1;
        m_pendingArrivedWallMs = -1;
        m_pendingFrame = QVideoFrame();    // release the slot so the buffer can be freed
        m_deliverQueued = false;
    }
    if (!frame.isValid())
        return;
    observationTick();
    if (m_observationMonitoring && m_sink && wt::availability::freshDecoded(
            arrivedAt, steadyMs(), arrivedWall, QDateTime::currentMSecsSinceEpoch())) {
        m_observationPositiveMs = arrivedAt;
        m_observationPositiveAt = wt::availability::instant();
        publishObservation(QStringLiteral("available"), QStringLiteral("decoded_frame_received"));
    }
    if (m_sink) {
        m_sink->setVideoFrame(frame);
        ++m_sinkFrames;
        m_lastSinkFrameMs = steadyMs();
    }
    m_lastFrame = frame;   // shared buffer, no copy — rides along if this pipeline gets parked
    setErrored(false);
    setPlaying(true);
    ++g_totalFrames;   // P0 trace: a frame reached the sink
    m_lastDeliverMs = steadyMs();
    m_deliveredSinceBuild = true;
    if (m_swdAttempts) {
        qInfo("[WT-SWD] recovered after %d attempt(s) url=…%s",
              m_swdAttempts, m_url.right(24).toUtf8().constData());
        m_swdAttempts = 0;
        m_swdNextMs = 0;
    }
}

gboolean RtspVideoSource::onBus(GstBus *, GstMessage *msg, gpointer self)
{
    auto *me = static_cast<RtspVideoSource *>(self);
    switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_ERROR: {
        GError *e = nullptr;
        gchar *dbg = nullptr;
        gst_message_parse_error(msg, &e, &dbg);
        me->setPlaying(false);
        me->setErrored(true, e ? QString::fromUtf8(e->message) : QStringLiteral("stream error"));
        // Bus errors fire repeatedly and this line lands in the flight recorder; the
        // URL may carry camera credentials under the direct transport. Redact.
        qWarning() << "RtspVideoSource:" << QUrl(me->m_url).toString(QUrl::RemoveUserInfo)
                   << "-" << (e ? e->message : "error");
        if (e) g_error_free(e);
        g_free(dbg);
        break;
    }
    case GST_MESSAGE_EOS:
        me->setPlaying(false);
        break;
    default:
        break;
    }
    return TRUE;   // keep the watch
}
