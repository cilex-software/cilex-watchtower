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
static void onDeepDecoderAdded(GstBin *, GstBin *, GstElement *element, gpointer)
{
    static const bool trace = qEnvironmentVariableIsSet("WT_TRACE");
    if (!trace)
        return;
    GstElementFactory *f = gst_element_get_factory(element);
    const char *klass = f ? gst_element_factory_get_klass(f) : nullptr;
    if (!klass || !std::strstr(klass, "Decoder") || !std::strstr(klass, "Video"))
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
    QByteArray pipeStr =
        "rtspsrc name=src drop-on-latency=true ! decodebin name=dec ! videoconvert "
        "! video/x-raw,format=NV12 ! appsink name=sink sync=false max-buffers=2 drop=true";
    const QList<QByteArray> wh = qgetenv("WT_DECODE_SCALE").split('x');
    if (wh.size() == 2 && !wh[0].trimmed().isEmpty() && !wh[1].trimmed().isEmpty()) {
        pipeStr = QByteArray(
            "rtspsrc name=src drop-on-latency=true ! decodebin name=dec ! videoscale ! videoconvert "
            "! video/x-raw,format=NV12,width=") + wh[0].trimmed() + ",height=" + wh[1].trimmed() +
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
        g_signal_connect(dec, "deep-element-added", G_CALLBACK(onDeepDecoderAdded), nullptr);
        gst_object_unref(dec);
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
