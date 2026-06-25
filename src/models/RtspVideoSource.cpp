#include "RtspVideoSource.h"

#include <QVideoSink>
#include <QVideoFrame>
#include <QVideoFrameFormat>
#include <QMetaObject>
#include <QPointer>
#include <QDebug>
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

// True if a (sampled) RGBA frame is one flat green colour — the signature of a decoder
// "empty surface": the all-zero NV12 buffer a decoder emits before a real keyframe (or
// for a wedged sub-stream) converts to ~RGB(0,135,0), the notorious solid green. Real
// video is never a uniform flat colour, and a real green scene has texture, so this is
// surgical: uniform AND green-dominant with R,B near zero. O(1) — a 6×6 sample grid.
bool isEmptyGreenSurface(const unsigned char *base, int w, int h, int stride)
{
    if (!base || w < 2 || h < 2)
        return false;
    int rmin = 255, rmax = 0, gmin = 255, gmax = 0, bmin = 255, bmax = 0;
    constexpr int N = 6;
    for (int yi = 0; yi < N; ++yi)
        for (int xi = 0; xi < N; ++xi) {
            const int px = xi * (w - 1) / (N - 1);
            const int py = yi * (h - 1) / (N - 1);
            const unsigned char *p = base + qsizetype(py) * stride + qsizetype(px) * 4;
            rmin = qMin(rmin, int(p[0])); rmax = qMax(rmax, int(p[0]));   // RGBA byte order
            gmin = qMin(gmin, int(p[1])); gmax = qMax(gmax, int(p[1]));
            bmin = qMin(bmin, int(p[2])); bmax = qMax(bmax, int(p[2]));
        }
    const bool uniform  = (rmax - rmin) <= 8 && (gmax - gmin) <= 8 && (bmax - bmin) <= 8;
    const bool greenish = rmax < 60 && bmax < 60 && gmin > 70 && gmax < 200;
    return uniform && greenish;
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
        pump();
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
        if (since >= kBuildStaggerMs) {
            RtspVideoSource *src = m_queue.front();
            m_queue.pop_front();
            m_lastBuildMs = m_clock.elapsed();
            src->startPipelineNow();              // the actual gst build — one at a time
            if (!m_queue.empty())
                m_timer.start(kBuildStaggerMs);
        } else {
            m_timer.start(int(kBuildStaggerMs - since));   // wait out the remaining gap
        }
    }
    QTimer m_timer;
    QElapsedTimer m_clock;
    qint64 m_lastBuildMs = -1000000;              // far in the past → first build is immediate
    std::deque<RtspVideoSource *> m_queue;
};
}

RtspVideoSource::RtspVideoSource(QObject *parent)
    : QObject(parent)
{
    std::lock_guard<std::mutex> lock(aliveMutex());
    aliveSet().insert(this);
}

RtspVideoSource::~RtspVideoSource()
{
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
    m_url = u;
    emit urlChanged();
    rebuild();
}

void RtspVideoSource::setActive(bool a)
{
    if (m_active == a)
        return;
    m_active = a;
    emit activeChanged();
    rebuild();
}

void RtspVideoSource::setVideoSink(QVideoSink *s)
{
    if (m_sink == s)
        return;
    m_sink = s;
    emit videoSinkChanged();
    rebuild();
}

void RtspVideoSource::setLatencyMs(int ms)
{
    ms = qBound(0, ms, 5000);
    if (m_latencyMs == ms)
        return;
    m_latencyMs = ms;
    emit latencyMsChanged();
    rebuild();   // latency is set at pipeline build time
}

void RtspVideoSource::reconnect()
{
    // A silent stall (no EOS, no error, just no buffers arriving) leaves the pipeline
    // reporting itself "playing" while the picture is frozen/green. The QML watchdog
    // calls this to force a clean rebuild. No-op when we're not meant to be streaming;
    // teardown() routes the old pipeline through the global teardown semaphore, so even
    // a burst of reconnects can't stack unbounded pipeline ops on the GUI thread.
    if (!m_active || m_url.isEmpty() || !m_sink)
        return;
    rebuild();
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
    m_errorText = e ? msg : QString();
    if (m_errored != e) {
        m_errored = e;
        emit erroredChanged();
    }
}

// P0 memory-trace diagnostics (see header): live GStreamer pipelines + total frames delivered.
static std::atomic<int> g_livePipelines{0};
static std::atomic<long long> g_totalFrames{0};
int RtspVideoSource::livePipelineCount() { return g_livePipelines.load(); }
long long RtspVideoSource::totalFramesDelivered() { return g_totalFrames.load(); }

void RtspVideoSource::teardown()
{
    PipelineBuildPump::instance().cancel(this);   // drop any queued (not-yet-started) build
    if (m_busWatch) {
        g_source_remove(m_busWatch);
        m_busWatch = 0;
    }
    if (m_bus) {
        gst_object_unref(m_bus);
        m_bus = nullptr;
    }
    if (m_pipeline) {
        --g_livePipelines;   // P0 trace: a built pipeline is being torn down
        // Clear appsink callbacks so the streaming thread won't dereference us
        // after we return. The thread that owns the pipeline below will still
        // see this — the appsink is part of the pipeline.
        if (GstElement *sinkEl = gst_bin_get_by_name(GST_BIN(m_pipeline), "sink")) {
            GstAppSinkCallbacks empty = {};
            gst_app_sink_set_callbacks(GST_APP_SINK(sinkEl), &empty, nullptr, nullptr);
            gst_object_unref(sinkEl);
        }
        // gst_element_set_state(NULL) blocks while GStreamer tears down RTSP /
        // releases the decoder — under tile-destruction churn (layout switch,
        // page change) this stacked up on the GUI thread. Hand the pipeline to a
        // detached worker so destruction returns immediately. The counting
        // semaphore caps how many pipelines can be in flight at once: the GUI
        // thread briefly waits if the cap is hit, which is the desired back-
        // pressure (each in-flight pipeline holds RTSP sockets + GMainContext
        // pipe-pair fds + a worker thread). Without it, mashing layouts piles
        // up unbounded detached threads and exhausts fds.
        GstElement *p = m_pipeline;
        m_pipeline = nullptr;
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
    setPlaying(false);
}

void RtspVideoSource::rebuild()
{
    teardown();
    setErrored(false);
    if (!m_active || m_url.isEmpty() || !m_sink)
        return;
    // Don't build inline. Route through the global rate limiter so a burst of tiles
    // becoming active at once (layout change, Arrange exit, page turn, app start) can't
    // create N VA-API decode contexts simultaneously — that churn wedges the shared iGPU
    // (the relayout freeze). A lone build still starts immediately (see PipelineBuildPump).
    PipelineBuildPump::instance().request(this);
}

void RtspVideoSource::startPipelineNow()
{
    // Invoked by the global build pump (staggered). Re-check we still want to stream and
    // hold no pipeline — state can change between the request and the drain.
    if (m_pipeline || !m_active || m_url.isEmpty() || !m_sink)
        return;

    // decodebin picks VA-API on the Intel iGPU. RGBA out for a simple single-plane
    // copy (NV12 + zero-copy is the follow-up optimization). The URL is set on the
    // element rather than baked into the parse string to avoid escaping the creds.
    GError *err = nullptr;
    m_pipeline = gst_parse_launch(
        "rtspsrc name=src drop-on-latency=true ! decodebin ! videoconvert "
        "! video/x-raw,format=RGBA ! appsink name=sink sync=false max-buffers=2 drop=true",
        &err);
    if (!m_pipeline) {
        setErrored(true, err ? QString::fromUtf8(err->message) : QStringLiteral("pipeline build failed"));
        if (err) g_error_free(err);
        return;
    }
    if (err) g_error_free(err);

    if (GstElement *src = gst_bin_get_by_name(GST_BIN(m_pipeline), "src")) {
        g_object_set(src, "location", m_url.toUtf8().constData(),
                          "latency", guint(m_latencyMs), nullptr);
        gst_object_unref(src);
    }
    if (GstElement *sinkEl = gst_bin_get_by_name(GST_BIN(m_pipeline), "sink")) {
        GstAppSinkCallbacks cbs = {};
        cbs.new_sample = &RtspVideoSource::onNewSample;
        gst_app_sink_set_callbacks(GST_APP_SINK(sinkEl), &cbs, this, nullptr);
        gst_object_unref(sinkEl);
    }

    m_bus = gst_element_get_bus(m_pipeline);
    m_busWatch = gst_bus_add_watch(m_bus, &RtspVideoSource::onBus, this);

    gst_element_set_state(m_pipeline, GST_STATE_PLAYING);
    ++g_livePipelines;   // P0 trace: a new pipeline is now live
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
    GstMapInfo map;
    QVideoFrame frame;
    if (caps && gst_video_info_from_caps(&info, caps) && gst_buffer_map(buf, &map, GST_MAP_READ)) {
        const int w = GST_VIDEO_INFO_WIDTH(&info);
        const int h = GST_VIDEO_INFO_HEIGHT(&info);
        const int srcStride = GST_VIDEO_INFO_PLANE_STRIDE(&info, 0);
        static thread_local bool resLogged = false;   // WT_TRACE: log each pipeline's decode resolution once
        if (!resLogged && qEnvironmentVariableIsSet("WT_TRACE")) {
            resLogged = true;
            qInfo().noquote() << "[WT-RES] decode" << w << "x" << h << "→ RGBA buffer" << (w * h * 4 / 1024) << "KB/frame";
        }
        QVideoFrame f(QVideoFrameFormat(QSize(w, h), QVideoFrameFormat::Format_RGBA8888));
        if (f.map(QVideoFrame::WriteOnly)) {
            const int dstStride = f.bytesPerLine(0);
            const int copy = qMin(srcStride, dstStride);
            for (int y = 0; y < h; ++y)
                std::memcpy(f.bits(0) + qsizetype(y) * dstStride,
                            map.data + qsizetype(y) * srcStride, copy);
            // Sample for the "empty surface" green BEFORE unmapping. If it's that flat
            // green (a decoder zero-buffer, not a real picture), drop it: don't deliver,
            // don't mark playing — the VideoSurface stays covered and the reconnect
            // watchdog keeps trying, so the operator never sees green.
            const bool empty = isEmptyGreenSurface(f.bits(0), w, h, dstStride);
            f.unmap();
            if (!empty)
                frame = f;
        }
        gst_buffer_unmap(buf, &map);
    }
    gst_sample_unref(sample);

    if (frame.isValid()) {
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
            me->m_pendingFrame = frame;                 // drop any undelivered older frame
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
    QVideoFrame frame;
    {
        std::lock_guard<std::mutex> flock(m_frameMutex);
        frame = m_pendingFrame;
        m_pendingFrame = QVideoFrame();    // release the slot so the buffer can be freed
        m_deliverQueued = false;
    }
    if (!frame.isValid())
        return;
    if (m_sink)
        m_sink->setVideoFrame(frame);
    setErrored(false);
    setPlaying(true);
    ++g_totalFrames;   // P0 trace: a frame reached the sink
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
        qWarning() << "RtspVideoSource:" << me->m_url << "-" << (e ? e->message : "error");
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
