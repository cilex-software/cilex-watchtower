#pragma once

#include <QObject>
#include <QString>

class HlsProxy;
class QThread;

// App-lifetime loopback proxy for LIVE-over-HTTP — the remote-live transport
// (CV letter 2026-09-07: authenticated fMP4 at /streams/live/stream.mp4?src=,
// the same path Cilex Pro Mobile uses off-site). PlaybackClient's proxy lives
// only while playback does; live surfaces need one whenever the app runs.
// Registered in main.cpp as the QML context property `LiveHttp`.
class LiveProxy : public QObject
{
    Q_OBJECT
public:
    explicit LiveProxy(QObject *parent = nullptr);
    ~LiveProxy() override;

    // Loopback URL for the live fMP4 of the go2rtc source a given rtsp:// URL
    // names (its last path segment, e.g. ".../abc-sub" -> "abc-sub"), or ""
    // when it cannot be derived. This is the source ladder's HTTP rung:
    // VideoSurface plays it when RTSP cannot deliver.
    Q_INVOKABLE QString liveUrlFor(const QString &rtspUrl) const;
    // Proxy URL for one of CV's own HLS fields (hls_sub_url / hls_opt_url): the
    // upstream path must be the live HLS master and `src` is taken from THEIR url —
    // the field is the source of truth (CV 2026-09-11: "stop deriving"). "" when
    // the url is not that shape; callers then fall back to liveUrlFor().
    Q_INVOKABLE QString liveUrlForUpstream(const QString &hlsUrl) const;

    // Is go2rtc's RTSP port reachable from THIS network? -1 unknown, 0 no, 1 yes.
    // A client off the VPN cannot reach 8554 at all, and without this every tile
    // independently spends 2x8 s of doomed connects to find that out — serialized
    // through ReconnectCoordinator's 700 ms global slot, so a 20-tile wall took
    // minutes to settle and a single-camera view looked like it hung forever
    // (measured on the operator's Mac 2026-09-18, 60 s in and only 3 of 20 tiles
    // had given up). One 3 s TCP probe answers it for the whole app.
    Q_PROPERTY(int rtspProbe READ rtspProbe NOTIFY rtspProbeChanged)
    int rtspProbe() const { return m_rtspProbe; }
    // Probe the host:port of an rtsp:// url. Cheap, idempotent per host:port, and
    // re-run when the host changes (roaming on/off the VPN changes the answer).
    void probeRtspHost(const QString &rtspUrl);

    static LiveProxy *instance() { return s_instance; }

signals:
    void rtspProbeChanged();

private:
    void setRtspProbe(int v);

    HlsProxy *m_proxy = nullptr;
    QThread *m_thread = nullptr;
    int m_rtspProbe = -1;          // -1 unknown, 0 unreachable, 1 reachable
    QString m_probedHostPort;      // what m_rtspProbe refers to
    bool m_probeInFlight = false;
    static LiveProxy *s_instance;
};
