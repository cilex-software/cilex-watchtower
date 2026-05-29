#include "RtspVideoSource.h"

#include <QVideoSink>
#include <QVideoFrame>
#include <QVideoFrameFormat>
#include <QMetaObject>
#include <QDebug>
#include <cstring>
#include <thread>
#include <gst/video/video.h>
#include <gst/app/gstappsink.h>

RtspVideoSource::RtspVideoSource(QObject *parent)
    : QObject(parent)
{
}

RtspVideoSource::~RtspVideoSource()
{
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

void RtspVideoSource::teardown()
{
    if (m_busWatch) {
        g_source_remove(m_busWatch);
        m_busWatch = 0;
    }
    if (m_bus) {
        gst_object_unref(m_bus);
        m_bus = nullptr;
    }
    if (m_pipeline) {
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
        // detached worker so destruction returns immediately.
        GstElement *p = m_pipeline;
        m_pipeline = nullptr;
        std::thread([p] {
            gst_element_set_state(p, GST_STATE_NULL);
            gst_object_unref(p);
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
        QVideoFrame f(QVideoFrameFormat(QSize(w, h), QVideoFrameFormat::Format_RGBA8888));
        if (f.map(QVideoFrame::WriteOnly)) {
            const int dstStride = f.bytesPerLine(0);
            const int copy = qMin(srcStride, dstStride);
            for (int y = 0; y < h; ++y)
                std::memcpy(f.bits(0) + qsizetype(y) * dstStride,
                            map.data + qsizetype(y) * srcStride, copy);
            f.unmap();
            frame = f;
        }
        gst_buffer_unmap(buf, &map);
    }
    gst_sample_unref(sample);

    if (frame.isValid())
        QMetaObject::invokeMethod(me, [me, frame]() { me->deliver(frame); }, Qt::QueuedConnection);
    return GST_FLOW_OK;
}

void RtspVideoSource::deliver(const QVideoFrame &frame)
{
    if (m_sink)
        m_sink->setVideoFrame(frame);
    setErrored(false);
    setPlaying(true);
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
