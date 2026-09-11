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

private:
    HlsProxy *m_proxy = nullptr;
    QThread *m_thread = nullptr;
};
