#pragma once

#include <QObject>
#include <QTcpServer>
#include <QString>
#include <QByteArray>
#include <QHash>
#include <QStringList>
#include <QSet>

class QNetworkAccessManager;
class QTcpSocket;

// Local loopback HLS proxy. Qt 6.4's QMediaPlayer cannot attach an auth cookie
// or custom headers to its HLS requests, so we sit a tiny proxy on 127.0.0.1
// between the player and cilex-vision's query-api. For every request it:
//   - forwards to the upstream query-api carrying the session cookie (via the
//     shared QNetworkAccessManager cookie jar populated at login),
//   - rewrites the playlist's "/api/review/" segment URLs to "/review/" (the
//     "/api" prefix is the Next.js browser proxy, not a backend route),
//   - strips "#EXT-X-GAP" placeholder segments (the v1 hlsdemux QMediaPlayer
//     uses tries to fetch gap-N.ts and 404s; real #EXT-X-DISCONTINUITY kept),
//   - retries briefly on 503 (a cold fragment remuxes sub-second, then 200),
//   - caches fetched .ts segments and prefetches the next ones (see below).
class HlsProxy : public QObject
{
    Q_OBJECT
public:
    explicit HlsProxy(QNetworkAccessManager *nam, QObject *parent = nullptr);

    bool start();                              // listen on 127.0.0.1:<auto>
    int port() const { return m_server.serverPort(); }
    QString localBase() const;                 // "http://127.0.0.1:<port>"
    void setUpstream(const QString &base) { m_upstream = base; }

private slots:
    void onNewConnection();

private:
    void serveRequest(QTcpSocket *sock, const QString &path);
    void forward(QTcpSocket *sock, const QString &path, int attempt);
    static QByteArray rewritePlaylist(const QByteArray &in);
    void writeResponse(QTcpSocket *sock, int code, const QByteArray &contentType,
                       const QByteArray &body);

    // Segment read-ahead cache. A backward seek makes hlsdemux2 fetch the target
    // segment and the next one or two SERIALLY from backend storage; each cold
    // HEVC-1440p/30s segment is ~110-160ms, so a cold seek lands at 460-670ms
    // (measured 2026-06-14). We cache .ts bodies (served instantly on re-seek)
    // and, the moment a segment is requested, prefetch the next two in parallel
    // so the demuxer's follow-up requests hit cache — collapsing the serial chain
    // and bringing cold seeks under 500ms.
    struct CachedSeg { QByteArray body; QByteArray ct; };
    static bool isSegmentPath(const QString &path);
    void prefetchAround(const QString &path);   // kick read-ahead for path's successors
    void startPrefetch(const QString &path);     // background fetch → cache (no socket)
    bool cacheServe(QTcpSocket *sock, const QString &path);  // serve from cache if present
    void cachePut(const QString &path, const QByteArray &body, const QByteArray &ct);

    QTcpServer m_server;
    QNetworkAccessManager *m_nam;
    QString m_upstream;

    QHash<QString, CachedSeg> m_segCache;   // path -> {body, content-type}
    QStringList m_segOrder;                  // LRU order (front = oldest)
    qint64 m_segBytes = 0;
    QSet<QString> m_inflight;                // prefetches in progress (dedupe)
    static constexpr qint64 kCacheBudget = 160 * 1024 * 1024;  // ~10-14 HEVC segs
    static constexpr int kReadAhead = 2;     // segments to prefetch ahead
};
