#pragma once

#include <QObject>
#include <QTcpServer>
#include <QString>
#include <QByteArray>
#include <QHash>
#include <QVector>
#include <QStringList>
#include <QSet>
#include <atomic>

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
    explicit HlsProxy(QObject *parent = nullptr);

    int port() const { return m_port.load(); }
    QString localBase() const;                 // "http://127.0.0.1:<port>"

public slots:
    // These run on the proxy's OWN thread (invoked via queued / blocking connections from the GUI thread),
    // so the proxy keeps serving the player's segment reads even while the GUI thread is blocked — e.g. inside
    // QMediaPlayer teardown on the wall↔Live transition. A GUI-thread proxy deadlocks there: stop() (GUI) waits
    // for the demuxer, the demuxer waits for a segment, and the proxy can't serve it because the GUI is stuck.
    void init();                               // create the NAM + QTcpServer and listen — ON this thread
    void setUpstream(const QString &base) { m_upstream = base; }
    void setAuthToken(const QString &token);   // set the access_token cookie on the proxy's own NAM

private slots:
    void onNewConnection();

private:
    void serveRequest(QTcpSocket *sock, const QString &path);
    // Live fMP4 passthrough (the remote-live transport, CV letter 2026-09-07).
    // Deliberately NONE of the segment machinery applies: no cache (endless
    // body), no single-flight join (a joiner would park forever behind a GET
    // that never finishes — each viewer gets its own upstream pull), no 503
    // retry loop (the surface's source ladder owns recovery), no transfer
    // timeout (long-lived by design; a silent stall is the player's frame-flow
    // watchdog's to catch, and a hung-up player aborts the upstream pull).
    void forwardLive(QTcpSocket *sock, const QString &upath);
    // spentMs accumulates the 503-retry delays already burned on THIS request, so
    // the chain can honour the server's Retry-After without overrunning
    // kRetryBudgetMs (souphttpsrc's ~15 s abort). Callers start at 0.
    void forward(QTcpSocket *sock, const QString &path, int attempt, int spentMs = 0);
    static QByteArray rewritePlaylist(const QByteArray &in);
    void writeResponse(QTcpSocket *sock, int code, const QByteArray &contentType,
                       const QByteArray &body);
    // Headers only, for the STREAMING path: the body then follows as chunks arrive.
    // len < 0 omits Content-Length, which is legal because we always send
    // Connection: close — the body then ends at EOF.
    void writeHead(QTcpSocket *sock, int code, const QByteArray &contentType, qint64 len);
    // THE ONLY place a forwarded response reaches a socket. Serves the leader (if its
    // socket is still up) and every socket parked behind it, then drops the m_joiners
    // entry. Routing every terminal path through one function is what keeps a parked
    // socket from being forgotten — see m_joiners.
    void deliver(const QString &path, QPointer<QTcpSocket> leader, int code,
                 const QByteArray &contentType, const QByteArray &body);

    // Segment read-ahead cache. A backward seek makes hlsdemux2 fetch the target
    // segment and the next one or two SERIALLY from backend storage; each cold
    // HEVC-1440p/30s segment is ~110-160ms, so a cold seek lands at 460-670ms
    // (measured 2026-06-14). We cache .ts bodies (served instantly on re-seek)
    // and, the moment a segment is requested, prefetch the next two in parallel
    // so the demuxer's follow-up requests hit cache — collapsing the serial chain
    // and bringing cold seeks under 500ms.
    struct CachedSeg { QByteArray body; QByteArray ct; };
    static bool isSegmentPath(const QString &path);
    static QString sessionKey(const QString &path);   // ".../<uuid>/seg/N.ts" -> uuid
    void prefetchAround(const QString &path);   // kick read-ahead for path's successors
    void startPrefetch(const QString &path, int chain = 0);   // background fetch → cache (no socket); chain = how many more to follow, one at a time
    bool cacheServe(QTcpSocket *sock, const QString &path);  // serve from cache if present
    void cachePut(const QString &path, const QByteArray &body, const QByteArray &ct);

    QTcpServer *m_server = nullptr;            // created in init() ON the proxy thread
    QNetworkAccessManager *m_nam = nullptr;    // the proxy's OWN nam (not the shared GUI-thread one)
    // Live (HLS) requests are many and short — playlist polls and 0.5 s segments — so
    // they round-robin over a small pool of managers: keep-alive connection reuse
    // (no per-segment TCP+HTTP handshake against a remote RTT) and, with nothing
    // long-lived any more, no per-host starvation either. Cookie set on all.
    QVector<QNetworkAccessManager *> m_livePool;
    int m_liveRr = 0;
    static constexpr int kLivePool = 4;
    std::atomic<int> m_port{0};                // server port, read cross-thread by localBase()/port()
    QString m_upstream;

    QHash<QString, CachedSeg> m_segCache;   // path -> {body, content-type}
    QStringList m_segOrder;                  // LRU order (front = oldest)
    qint64 m_segBytes = 0;
    QSet<QString> m_inflight;                // prefetches in progress (dedupe)
    // Sessions that have already had a segment served. The FIRST segment of a session
    // is the one a guard is waiting on for their first frame, and read-ahead must not
    // race it — see prefetchAround(). Bounded by sessions opened in one app run.
    QSet<QString> m_seededSessions;
    // SINGLE-FLIGHT for forward(). The player asks for the SAME segment down two
    // sockets, so before 2026-08-29 we ran two concurrent upstream GETs for it —
    // measured 10/10 probe runs, 7.57 MB pulled to deliver a 3.79 MB segment, each
    // copy at half the link. Presence of a key means "a fetch for this path is in
    // flight"; the vector holds the sockets waiting on it. Emptied ONLY by deliver().
    QHash<QString, QVector<QPointer<QTcpSocket>>> m_joiners;
    static constexpr qint64 kCacheBudget = 160 * 1024 * 1024;  // ~10-14 HEVC segs
    static constexpr int kReadAhead = 2;     // segments to prefetch ahead
};
