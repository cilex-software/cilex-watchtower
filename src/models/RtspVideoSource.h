#pragma once

#include <QObject>
#include <QString>
#include <QVideoSink>
#include <QtQml/qqmlregistration.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>

// Low-latency live RTSP source. Owns a GStreamer pipeline with a small rtspsrc
// jitter buffer and pushes decoded frames into a QVideoSink (the sink a QML
// VideoOutput renders). This bypasses QMediaPlayer specifically to control
// rtspsrc `latency`, which QtMultimedia 6.4 cannot expose (see VideoSurface).
//
// Opt-in behind WT_LOWLATENCY; QMediaPlayer remains the default path. Mirrors the
// VideoSurface API (url/active/playing/errored) so it's a drop-in alternative.
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

signals:
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
    void deliver(const class QVideoFrame &frame);   // runs on the GUI thread

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
    QString m_errorText;
};
