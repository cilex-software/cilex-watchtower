#pragma once

#include <QObject>
#include <QString>
#include <QVideoSink>
#include <QVideoFrame>
#include <QtQml/qqmlregistration.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <mutex>
#include <atomic>

// Low-latency live RTSP source. Owns a GStreamer pipeline with a small rtspsrc
// jitter buffer and pushes decoded frames into a QVideoSink (the sink a QML
// VideoOutput renders). This bypasses QMediaPlayer specifically to control
// rtspsrc `latency`, which QtMultimedia 6.4 cannot expose (see VideoSurface).
//
// Opt-in behind WT_LOWLATENCY; QMediaPlayer remains the default path. Mirrors the
// VideoSurface API (url/active/playing/errored) so it's a drop-in alternative.
class QTimer;

class RtspVideoSource : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString url READ url WRITE setUrl NOTIFY urlChanged)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    Q_PROPERTY(QVideoSink *videoSink READ videoSink WRITE setVideoSink NOTIFY videoSinkChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playingChanged)
    Q_PROPERTY(bool errored READ errored NOTIFY erroredChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY erroredChanged)
    // Jitter buffer in ms (rtspsrc latency). Low for a LAN; the whole point.
    Q_PROPERTY(int latencyMs READ latencyMs WRITE setLatencyMs NOTIFY latencyMsChanged)
    // WARM-KEEP (2026-09-08): hold the RTSP session open with NO decoder, so go2rtc keeps
    // the camera producer alive. Measured: an armed camera opens cold in 424-1003 ms
    // because go2rtc drops its producer the instant the last consumer leaves; with a
    // consumer attached the same camera opens in 72-116 ms. Cost: depay-only, ~0.4% of
    // a core and ~4 MiB per stream. Used by snapshot-badged tiles (over the decode cap),
    // which otherwise hold nothing and are the cold case a guard meets.
    Q_PROPERTY(bool warmOnly READ warmOnly WRITE setWarmOnly NOTIFY warmOnlyChanged)

public:
    explicit RtspVideoSource(QObject *parent = nullptr);
    ~RtspVideoSource() override;

    QString url() const { return m_url; }
    void setUrl(const QString &u);
    bool active() const { return m_active; }
    void setActive(bool a);
    QVideoSink *videoSink() const { return m_sink; }
    void setVideoSink(QVideoSink *s);
    bool playing() const { return m_playing; }
    bool errored() const { return m_errored; }
    QString errorText() const { return m_errorText; }
    int latencyMs() const { return m_latencyMs; }
    void setLatencyMs(int ms);

    // Force a fresh pipeline (teardown + rebuild) to recover a silently-stalled
    // stream — no EOS/error, just no buffers, so `playing` stays stuck true. Rate-
    // limiting and backoff are the caller's job (VideoSurface + the QML
    // ReconnectCoordinator); this just rebuilds now, if we're meant to be streaming.
    Q_INVOKABLE void reconnect();
    bool warmOnly() const { return m_warmOnly; }
    void setWarmOnly(bool v);

    // Internal: the actual GStreamer pipeline build, invoked (staggered, one at a time)
    // by the global build pump in the .cpp. Don't call directly — go through rebuild(),
    // which serializes builds so a burst can't wedge the shared iGPU.
    void startPipelineNow();

    // Diagnostics (P0 memory trace): how many GStreamer pipelines are currently built (live VA-API
    // decodes), and total frames delivered. Lets the memory logger correlate RSS growth with decode
    // count (stable count + rising RSS = a per-decode VA-API leak, not pipeline accumulation).
    static int livePipelineCount();
    static long long totalFramesDelivered();
    // Decode-side totals. totalFramesDelivered() counts frames that reached a sink;
    // these count frames that reached the CLIENT and frames the GUI thread lost.
    static long long totalFramesIn();
    static long long totalFramesCoalesced();
    // Lifecycle gauges, each named by its MEASUREMENT POINT (see DEVELOPMENT.md:
    // livePipes/playing/frames each cost the 08-15/16 investigation days by
    // answering a narrower question than their name implied):
    //   livePipelineCount()  gst pipeline objects CONSTRUCTED
    //   decoderBoundCount()  decodebin actually bound a video decoder
    //   litCount()           delivered a frame to the sink in the last 5 s
    //   erroredCount()       sitting in bus-error state (CameraTile recycle owns these)
    static int decoderBoundCount();
    static int litCount();
    static int erroredCount();
    // Backstop watchdog rebuilds forced, and reconnect() calls that ran vs
    // no-op'd at the guard — a rebuild someone asked for and nobody performed
    // must be a number, not a silence.
    static long long watchdogRebuilds();
    static long long reconnectRuns();
    static long long reconnectNoops();
    // Called from decodebin's deep-element-added on the STREAMING thread — the
    // only cross-thread write in the gauge set, hence the atomic.
    void noteDecoderBound() { m_decoderBound.store(true); }

signals:
    void warmOnlyChanged();
    void urlChanged();
    void activeChanged();
    void videoSinkChanged();
    void playingChanged();
    void erroredChanged();
    void latencyMsChanged();

private:
    void rebuild();    // (re)start the pipeline when active && url && sink are all set
    void teardown();   // stop + dispose the pipeline
    void setPlaying(bool p);
    void setErrored(bool e, const QString &msg = {});
    void deliver();   // runs on the GUI thread; consumes m_pendingFrame

    static GstFlowReturn onNewSample(GstAppSink *sink, gpointer self);
    static gboolean onBus(GstBus *bus, GstMessage *msg, gpointer self);

    QString m_url;
    bool m_active = true;
    QVideoSink *m_sink = nullptr;
    int m_latencyMs = 150;

    GstElement *m_pipeline = nullptr;
    GstBus *m_bus = nullptr;
    guint m_busWatch = 0;

    bool m_playing = false;
    bool m_errored = false;
    bool m_warmOnly = false;
    QString m_errorText;

    // Single-slot "latest frame" mailbox. onNewSample (streaming thread) drops the newest
    // frame here and posts at most ONE deliver() (GUI thread); newer frames replace the
    // unconsumed one. Bounds memory to one frame per pipeline no matter how far behind the
    // GUI thread falls — without this, 16 pipelines × 15 fps of unbounded queued frames
    // (~3.7 MB each) balloon RSS to many GB and OOM-kill the app.
    QVideoFrame m_pendingFrame;
    bool m_deliverQueued = false;
    std::mutex m_frameMutex;
    // Per-pipeline decode-side tallies, written under m_frameMutex in onNewSample.
    long long m_framesIn = 0;          // frames the appsink handed us
    long long m_framesCoalesced = 0;   // frames the GUI thread never drained

    // Backstop stream watchdog + lifecycle-gauge state (see swdTick()).
    void swdTick();
    std::atomic<bool> m_decoderBound{false};   // written on the streaming thread
    qint64 m_lastDeliverMs = 0;                // GUI thread (deliver())
    qint64 m_builtAtMs = 0;
    bool m_deliveredSinceBuild = false;
    int m_swdAttempts = 0;
    qint64 m_swdNextMs = 0;
    QTimer *m_swd = nullptr;
};
