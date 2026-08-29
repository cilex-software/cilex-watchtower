#include "HlsProxy.h"

#include <QAtomicInteger>
#include <QCoreApplication>
#include <QDebug>
#include <QElapsedTimer>
#include <QFile>
#include <QHostAddress>
#include <QNetworkAccessManager>
#include <QNetworkCookie>
#include <QNetworkCookieJar>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QSharedPointer>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QUrl>

namespace {
// WT_HLS_LOG=1 — per-request upstream timing on stderr ("WTHLS …"), for
// diagnosing playback/seek latency (segment fetch time, 503 remux retries).
const bool s_hlsLog = qEnvironmentVariableIsSet("WT_HLS_LOG");
// Total 503-retry budget for ONE upstream request. souphttpsrc aborts its HTTP
// request at ~15 s, so the whole retry chain must answer before that; 13 s leaves
// headroom for the in-flight fetch itself. This replaces a per-delay 2000 ms clamp
// that could not express the invariant it was standing in for — see forward().
const int kRetryBudgetMs = 13000;
// WT_HLS_NO_SINGLEFLIGHT=1 — restore the pre-2026-08-29 behaviour where two
// concurrent requests for the same path each ran their own upstream GET. Exists so
// the fix can be A/B'd against the same 10-run harness on one binary, and as an
// escape hatch if joining ever misbehaves in the field.
const bool s_noSingleFlight = qEnvironmentVariableIsSet("WT_HLS_NO_SINGLEFLIGHT");
// WT_HLS_NO_STREAM=1 — go back to store-and-forward, where a segment is fully
// downloaded before the player receives its first byte. Measured 2026-08-30: CV's
// first byte lands at ~200 ms and the last at ~3,000 ms, and the player used to be
// handed NOTHING until the end — so it idled ~2.8 s over data already in our buffer,
// then decoded in 67 ms. Streaming is why YouTube starts on a slow line and we did
// not. Kept as an escape hatch and as the A/B control on one binary.
const bool s_noStream = qEnvironmentVariableIsSet("WT_HLS_NO_STREAM");
// X-Request-Id — CV echoes ours back unchanged and forwards it to
// playback-service (their letter 2026-08-29, §4). Sent on EVERY upstream request,
// not just when logging, so their side can always join; it costs one header.
// This is what makes the join exact across a retry, which reuses the path and is
// precisely when pairing by path stops working.
QByteArray nextRequestId()
{
    static QAtomicInteger<quint64> seq(0);
    static const QByteArray prefix = QByteArrayLiteral("wt-booth-")
        + QByteArray::number(QCoreApplication::applicationPid()) + '-';
    return prefix + QByteArray::number(seq.fetchAndAddRelaxed(1));
}
// WT_HLS_SLOW_MS=<ms> — TEST ONLY: emulate a DEGRADED backend by holding every
// segment response this long before delivering it (and bypassing the read-ahead
// cache so the delay always bites). Reproduces the "cameras unplugged → backend
// slow → historic playback awfully slow / session teardown blocks the GUI thread"
// conditions, for A/B measuring calendar/playback behaviour. 0 = off (normal).
const int s_slowMs = qEnvironmentVariableIntValue("WT_HLS_SLOW_MS");
// WT_HLS_SLOW_EVERY=<n> — TEST ONLY: with WT_HLS_SLOW_MS, hold only every Nth
// segment (default 1 = every). N>1 emulates a backend that mostly serves but
// intermittently stalls (the real degraded condition): playback still advances,
// so the full soak flow (seeks/exports/drawer grabs) keeps running WITH a starved
// in-flight read usually present — the GUI-wedge repro cocktail.
const int s_slowEvery = qMax(1, qEnvironmentVariableIntValue("WT_HLS_SLOW_EVERY"));

// Upstream idle-timeout (ms). QNetworkRequest::setTransferTimeout aborts a reply
// that transfers NO bytes for this long (it resets on each byte, so a slow-but-
// progressing fetch is never aborted). Without it, forward()/startPrefetch() have
// no bound: on Windows under heavy-day seekFar re-open churn, an upstream segment/
// playlist GET can occasionally hang with no response — and because the loopback
// socket is only written from that reply's finished handler, the socket (and the
// FFmpeg demuxer blocked reading it in avformat_open_input) hangs until Qt's avio
// interrupt fires ("Immediate exit requested"), permanently wedging playback with
// no recovery (verified: cdb showed the proxy event loop ALIVE with pending
// replies; docs/perf/2026-07-10-windows-fsoak-proxy-wedge.md). Bounding the fetch
// turns a hung upstream into a fast 502 → the demuxer's own segment-retry re-asks,
// and the stuck reply/socket/inflight entry is reclaimed. WT_HLS_UPSTREAM_TIMEOUT_MS
// overrides (0 disables). 10 s clears genuine hangs while tolerating cold-tier
// remux (which returns 503s promptly, handled by the retry loop, not this timeout).
const int s_upstreamTimeoutMs = []{
    const int v = qEnvironmentVariableIntValue("WT_HLS_UPSTREAM_TIMEOUT_MS");
    return v != 0 ? v : 10000;
}();
}

HlsProxy::HlsProxy(QObject *parent)
    : QObject(parent)
{
    // Nothing here: the NAM, the QTcpServer and every accepted socket must be created on the proxy's OWN
    // thread (see init()), never on the GUI thread — that is the whole point of the move-to-thread.
}

void HlsProxy::init()
{
    if (m_nam)
        return;                                // already initialised
    m_nam = new QNetworkAccessManager(this);   // the proxy's own, thread-affine manager
    m_server = new QTcpServer(this);
    connect(m_server, &QTcpServer::newConnection, this, &HlsProxy::onNewConnection);
    m_server->listen(QHostAddress::LocalHost, 0);
    m_port.store(m_server->serverPort());
    // WT_PROXY_STATS=1 — periodic dump of the proxy's live internals, to localize the per-open RSS leak.
    if (qEnvironmentVariableIsSet("WT_PROXY_STATS")) {
        auto *t = new QTimer(this);
        connect(t, &QTimer::timeout, this, [this]() {
            qInfo("[PROXYSTATS] cacheN=%lld cacheMB=%lld inflight=%lld sockets=%lld replies=%lld",
                  (long long)m_segCache.size(), (long long)(m_segBytes / 1048576),
                  (long long)m_inflight.size(),
                  (long long)m_server->findChildren<QTcpSocket *>().size(),
                  (long long)m_nam->findChildren<QNetworkReply *>().size());
        });
        t->start(3000);
    }
}

void HlsProxy::setAuthToken(const QString &token)
{
    if (!m_nam || token.isEmpty())
        return;                                // pushed again on (re)login
    QNetworkCookie cookie("access_token", token.toUtf8());
    m_nam->cookieJar()->setCookiesFromUrl({cookie}, QUrl(m_upstream));
}

QString HlsProxy::localBase() const
{
    return QStringLiteral("http://127.0.0.1:%1").arg(m_port.load());
}

void HlsProxy::onNewConnection()
{
    while (QTcpSocket *sock = m_server->nextPendingConnection()) {
        connect(sock, &QTcpSocket::readyRead, this, [this, sock]() {
            if (sock->property("served").toBool())
                return;                            // request already dispatched
            QByteArray data = sock->property("hdr").toByteArray();
            data += sock->readAll();
            sock->setProperty("hdr", data);
            if (!data.contains("\r\n\r\n"))
                return;                            // headers not complete yet
            const QByteArray firstLine = data.left(data.indexOf("\r\n"));
            const auto parts = firstLine.split(' ');
            if (parts.size() < 2) {
                sock->disconnectFromHost();
                return;
            }
            sock->setProperty("served", true);
            serveRequest(sock, QString::fromUtf8(parts.at(1)));
        });
        connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
    }
}

void HlsProxy::serveRequest(QTcpSocket *sock, const QString &path)
{
    // Only GET is needed for HLS; reject anything that escapes /review/.
    if (!path.startsWith(QLatin1String("/review/"))) {
        writeResponse(sock, 404, "text/plain", "not found");
        return;
    }
    if (isSegmentPath(path) && s_slowMs == 0) {
        // Kick read-ahead in parallel with serving this one, so the demuxer's
        // next (serial) request lands in cache instead of a fresh cold fetch.
        // (Bypassed under WT_HLS_SLOW_MS so the emulated backend delay always bites.)
        prefetchAround(path);
        if (cacheServe(sock, path))
            return;
    }
    forward(sock, path, 0);
}

bool HlsProxy::isSegmentPath(const QString &path)
{
    return path.endsWith(QLatin1String(".ts"));
}

bool HlsProxy::cacheServe(QTcpSocket *sock, const QString &path)
{
    auto it = m_segCache.find(path);
    if (it == m_segCache.end())
        return false;
    m_segOrder.removeOne(path);      // touch → most-recently-used
    m_segOrder.append(path);
    if (s_hlsLog)
        qInfo().noquote() << QStringLiteral("WTHLS cache=1 %1").arg(path.section(QLatin1Char('/'), -1));
    writeResponse(sock, 200, it->ct.isEmpty() ? QByteArrayLiteral("video/mp2t") : it->ct, it->body);
    return true;
}

void HlsProxy::cachePut(const QString &path, const QByteArray &body, const QByteArray &ct)
{
    if (body.isEmpty())
        return;
    if (qEnvironmentVariableIsSet("WT_DUMP_SEG") && path.endsWith(QLatin1String(".ts"))) {   // capture real segments
        const QString base = path.mid(path.lastIndexOf(QLatin1Char('/')) + 1);
        QFile f(QStringLiteral("/tmp/realseg/") + base);
        if (!f.exists() && f.open(QIODevice::WriteOnly)) { f.write(body); f.close(); }
    }
    auto it = m_segCache.find(path);
    if (it != m_segCache.end()) {
        m_segBytes -= it->body.size();
        m_segOrder.removeOne(path);
    }
    m_segCache.insert(path, CachedSeg{body, ct});
    m_segOrder.append(path);
    m_segBytes += body.size();
    // Evict oldest until under budget (keep at least the just-added entry).
    while (m_segBytes > kCacheBudget && m_segOrder.size() > 1) {
        const QString old = m_segOrder.takeFirst();
        auto oi = m_segCache.find(old);
        if (oi != m_segCache.end()) {
            m_segBytes -= oi->body.size();
            m_segCache.erase(oi);
        }
    }
}

// Prefetch the next kReadAhead segments after `path` (.../<n>.ts) into cache.
//
// MEASURED LATENCY PROPERTY — DO NOT SERIALISE (CV cold-offset thread, closed
// 2026-07-12, reply3). Each prefetch is an INDEPENDENT async QNetworkReply that
// runs CONCURRENTLY with the forward() serving the operator's requested
// segment. On a cold mid-session seek the demuxer fetches target + successor;
// because these overlap, the successor hides in the target's shadow and our
// in-window first-touch seek costs ~285 ms (target cold serve ~204 ms + demuxer
// open/RTT ~80 ms) instead of the ~340 ms a serial target-then-successor would
// cost. A future refactor that makes segment fetches serial (a blocking
// forward, a single-flight queue over the shared NAM, dropping the async
// prefetch) would silently add ~55 ms per seek with no visible cause. Keep the
// fetches independent and concurrent.
void HlsProxy::prefetchAround(const QString &path)
{
    if (qEnvironmentVariableIsSet("WT_NO_PREFETCH")) return;   // leak bisect: isolate the read-ahead path
    const int slash = path.lastIndexOf(QLatin1Char('/'));
    if (slash < 0)
        return;
    const QString file = path.mid(slash + 1);          // "1235.ts"
    if (!file.endsWith(QLatin1String(".ts")))
        return;
    bool ok = false;
    const qlonglong n = file.left(file.size() - 3).toLongLong(&ok);   // strip ".ts"
    if (!ok || n < 0)
        return;
    const QString prefix = path.left(slash + 1);
    for (int k = 1; k <= kReadAhead; ++k) {
        const QString next = prefix + QString::number(n + k) + QStringLiteral(".ts");
        if (m_segCache.contains(next) || m_inflight.contains(next))
            continue;
        startPrefetch(next);
    }
}

void HlsProxy::startPrefetch(const QString &path)
{
    m_inflight.insert(path);
    QNetworkRequest req{QUrl(m_upstream + path)};
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    if (s_upstreamTimeoutMs > 0) req.setTransferTimeout(s_upstreamTimeoutMs);
    QNetworkReply *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply, path]() {
        reply->deleteLater();
        m_inflight.remove(path);
        // Best-effort: only cache a clean 200. A cold segment may 503 (still
        // rendering) — drop it; the real request will retry and warm the cache.
        if (reply->error() != QNetworkReply::NoError)
            return;
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code != 200 && code != 0)
            return;
        cachePut(path, reply->readAll(), reply->header(QNetworkRequest::ContentTypeHeader).toByteArray());
    });
}

// Serve the leader and everyone parked behind it, then forget the path. take()
// removes the entry as it reads it, so the bookkeeping cannot be left half-done and
// a second call for the same path is a harmless no-op.
void HlsProxy::deliver(const QString &path, QPointer<QTcpSocket> leader, int code,
                       const QByteArray &contentType, const QByteArray &body)
{
    if (leader && leader->state() == QAbstractSocket::ConnectedState)
        writeResponse(leader, code, contentType, body);
    const QVector<QPointer<QTcpSocket>> parked = m_joiners.take(path);
    if (s_hlsLog && !parked.isEmpty())
        qInfo().noquote() << QStringLiteral("WTHLS served=%1 joiners %2")
                                 .arg(parked.size()).arg(path.section(QLatin1Char('/'), -1));
    for (const QPointer<QTcpSocket> &j : parked) {
        if (j && j->state() == QAbstractSocket::ConnectedState)
            writeResponse(j, code, contentType, body);
    }
}

void HlsProxy::forward(QTcpSocket *sock, const QString &path, int attempt, int spentMs)
{
    // SINGLE-FLIGHT. Measured 2026-08-29 across 10/10 probe runs: the player requests
    // the SAME segment down two sockets, so we issued two concurrent upstream GETs and
    // pulled 7.57 MB to deliver a 3.79 MB segment — each copy then running at roughly
    // half the link (12.6-18 Mbit/s, against 32-36 whenever a segment happened to be
    // fetched only once). A later caller now parks on the leader's fetch.
    //
    // THE HAZARD, named because this file has already paid it once
    // (docs/perf/2026-07-10-windows-fsoak-proxy-wedge.md): a parked socket that never
    // receives a response wedges the demuxer permanently. So every terminal path in
    // the handler below routes through deliver() — including the one where the
    // LEADER's own socket died, where the parked sockets must still be answered. The
    // single path that deliberately does NOT release is the 503 retry, because there
    // the leader is still working on everyone's behalf.
    //
    // Only attempt 0 registers: a retry is the same leader continuing, not a new one.
    if (attempt == 0 && !s_noSingleFlight) {
        auto it = m_joiners.find(path);
        if (it != m_joiners.end()) {
            it->append(QPointer<QTcpSocket>(sock));
            if (s_hlsLog)
                qInfo().noquote() << QStringLiteral("WTHLS join=1 %1")
                                         .arg(path.section(QLatin1Char('/'), -1));
            return;
        }
        m_joiners.insert(path, {});          // we are the leader for this path
    }
    QNetworkRequest req{QUrl(m_upstream + path)};
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    if (s_upstreamTimeoutMs > 0) req.setTransferTimeout(s_upstreamTimeoutMs);
    const QByteArray rid = nextRequestId();
    req.setRawHeader("X-Request-Id", rid);
    QNetworkReply *reply = m_nam->get(req);          // cookie auto-attached by shared jar
    QElapsedTimer fetchTimer;
    fetchTimer.start();
    // Split the fetch into WAITING vs READING. `ms` alone cannot distinguish "the
    // server had not answered yet" from "we were dragging the body across the
    // socket", and that is the whole question for the ~1 s per segment measured on
    // 2026-08-29 (CV serve 12-132 ms, plain urllib 678 ms for the same 3.79 MB).
    //   hdr = response headers arrived  -> upstream think time + first RTT
    //   fb  = first body byte read      -> transfer started
    //   ms  = finished                  -> ms-fb is the body read
    // QElapsedTimer is a value type carrying its start tick, so these copies all
    // measure from the same origin.
    // Guard the socket with QPointer: the player (GStreamer hlsdemux) aborts and
    // closes in-flight segment requests aggressively while scrubbing, which
    // deleteLater()s the socket. By the time this reply finishes — or the 503
    // retry timer fires 400ms later — sock may already be freed, so a raw
    // pointer here is a use-after-free. QPointer nulls out on destruction.
    // Declared HERE (not just before the finished handler) because the streaming
    // lambdas below write to it as chunks arrive.
    QPointer<QTcpSocket> guardedSock(sock);
    auto hdrMs = QSharedPointer<qint64>::create(-1);
    auto fbMs  = QSharedPointer<qint64>::create(-1);
    // STREAM SEGMENTS THROUGH INSTEAD OF BUFFERING THEM.
    //
    // Until 2026-08-30 this proxy was store-and-forward: it downloaded a whole
    // segment, then handed the complete body to the player. Measured on the booth,
    // CV's FIRST byte arrives at ~200 ms and the LAST at ~3,000 ms — so the player
    // was given nothing for ~2.8 s while the bytes it needed sat in our buffer, and
    // then decoded in 67 ms. That is the entire reason time-to-first-frame tracked
    // segment SIZE (0.27 MB -> 1.08 s, 20 MB -> 5.09 s) rather than link speed, and
    // why a phone on a slow line starts a video faster than this station did.
    //
    // `streaming` flips once headers are committed to the player's socket; from then
    // on chunks go straight through. `acc` keeps a copy, because the segment cache
    // still needs the whole body and a single-flight joiner cannot be handed bytes
    // that have already left the building — it gets the copy at the end.
    auto streaming = QSharedPointer<bool>::create(false);
    auto acc = QSharedPointer<QByteArray>::create();

    connect(reply, &QNetworkReply::metaDataChanged, reply,
            [this, reply, guardedSock, path, fetchTimer, hdrMs, streaming]() {
        if (*hdrMs < 0) *hdrMs = fetchTimer.elapsed();
        if (*streaming || s_noStream)
            return;
        // Playlists are REWRITTEN (rewritePlaylist: EXT-X-GAP removal, discontinuity
        // normalisation), so they cannot be answered until complete.
        if (!isSegmentPath(path))
            return;
        if (s_slowMs > 0)
            return;                       // the slow-backend test hook needs buffering
        // Commit only on a definite 200: a 503 must stay on the retry path and a
        // transport error must still be able to become a 502. Neither is possible
        // once we have put headers on the wire.
        if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200)
            return;
        if (!guardedSock || guardedSock->state() != QAbstractSocket::ConnectedState)
            return;
        QByteArray ct = reply->header(QNetworkRequest::ContentTypeHeader).toByteArray();
        if (ct.isEmpty()) ct = QByteArrayLiteral("video/mp2t");
        const QVariant clen = reply->header(QNetworkRequest::ContentLengthHeader);
        writeHead(guardedSock, 200, ct, clen.isValid() ? clen.toLongLong() : -1);
        *streaming = true;
    });

    connect(reply, &QNetworkReply::readyRead, reply,
            [reply, guardedSock, fetchTimer, fbMs, streaming, acc]() {
        if (*fbMs < 0) *fbMs = fetchTimer.elapsed();
        if (!*streaming)
            return;                       // buffered path still reads it all in finished
        const QByteArray chunk = reply->readAll();
        if (chunk.isEmpty())
            return;
        acc->append(chunk);               // keep a copy for the cache and joiners
        if (guardedSock && guardedSock->state() == QAbstractSocket::ConnectedState)
            guardedSock->write(chunk);    // ...and give it to the player NOW
    });
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, guardedSock, path, attempt, spentMs, fetchTimer, rid, hdrMs, fbMs,
             streaming, acc]() {
        reply->deleteLater();
        if (s_hlsLog) {
            const int logCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            // Server-Timing carries CV's OWN decomposition — serve, queue, index,
            // storage, serialize, frags, storageops, and cache;desc="hit|miss" — and
            // has shipped on EVERY response since 2026-07-11 (CV letter 2026-08-29 §3).
            // We were throwing it away for seven weeks and then asked them to build it.
            // With it: our ms= minus their serve= is transport, and their own terms name
            // which server phase was slow — no extra server-side logging required.
            const QByteArray st = reply->rawHeader("Server-Timing");
            // X-Cilex-Mosaic-State names WHICH 503 this is — rendering (work already
            // running) vs saturated (queue full). Appended only when present, so
            // single-camera lines stay clean; without it our own logs cannot tell the
            // two apart, which is how 549 saturated responses went unnoticed here.
            const QByteArray mst = reply->rawHeader("X-Cilex-Mosaic-State");
            // bytesAvailable() does NOT consume the buffer — readAll() below still gets
            // the whole body. Logging the size matters: a "383,896 bytes" figure carried
            // over from a DIFFERENT session sent one analysis down the wrong road, when
            // the segment actually measured here is 3.79 MB. Never infer a size again.
            // On the STREAMED path readyRead has already drained the reply into `acc`,
            // so bytesAvailable() is only the tail — reporting it alone printed
            // bytes=0 for every segment, which would have re-created exactly the
            // size-blindness this field was added to prevent.
            const qint64 nbytes = *streaming ? (acc->size() + reply->bytesAvailable())
                                             : reply->bytesAvailable();
            QString line = QStringLiteral("WTHLS a=%1 code=%2 ms=%3 hdr=%4 fb=%5 bytes=%6 rid=%7 ")
                .arg(attempt).arg(logCode).arg(fetchTimer.elapsed())
                .arg(*hdrMs).arg(*fbMs).arg(nbytes)
                .arg(QString::fromLatin1(rid));
            line += path.section(QLatin1Char('/'), -3);
            line += QStringLiteral(" st=[") + QString::fromUtf8(st) + QLatin1Char(']');
            if (!mst.isEmpty())
                line += QStringLiteral(" mstate=") + QString::fromLatin1(mst);
            qInfo().noquote() << line;
        }
        // STREAMED: the leader already has its bytes, so this is only the tail, the
        // cache, and the joiners. Nothing below applies — the 503 retry and the 502
        // path are both unreachable once a 200 has been committed to the wire.
        if (*streaming) {
            acc->append(reply->readAll());          // whatever arrived after the last readyRead
            QByteArray ct = reply->header(QNetworkRequest::ContentTypeHeader).toByteArray();
            if (ct.isEmpty()) ct = QByteArrayLiteral("video/mp2t");
            if (guardedSock && guardedSock->state() == QAbstractSocket::ConnectedState) {
                guardedSock->flush();
                guardedSock->disconnectFromHost();   // Connection: close terminates the body
            }
            if (reply->error() == QNetworkReply::NoError) {
                cachePut(path, *acc, ct);
                deliver(path, nullptr, 200, ct, *acc);   // nullptr = leader already served
            } else {
                // Upstream died mid-body. The leader gets a short read and its own
                // retry loop handles that; joiners must NOT be handed the truncated
                // copy, so they get a 502 and re-ask instead.
                deliver(path, nullptr, 502, QByteArrayLiteral("text/plain"),
                        QByteArrayLiteral("upstream failed mid-stream"));
            }
            return;
        }
        // Deliberately NO early return when the leader's socket has gone. Sockets may
        // be parked behind this fetch and still need an answer — deliver() copes with
        // a dead leader. Reading the body regardless also warms the cache for a
        // re-seek even when the original requester walked away, which the old
        // early-return threw away.
        const int code = reply->attribute(
            QNetworkRequest::HttpStatusCodeAttribute).toInt();
        // Cold fragment remux / cold mosaic render. A cold 16-cell mosaic takes the
        // backend ~25-45s to produce the landed-on segment (measured 2026-06-11,
        // ~0.36× realtime render) — far beyond any per-request budget we can hold:
        // GStreamer's souphttpsrc aborts its HTTP request at ~15s, so the chain
        // must answer BEFORE that. 12 retries ≈ 13s at Retry-After:1 stays just
        // under it; the player then gets a clean 503 and its outer fragment-retry
        // loop (patient, playlist refetch + re-request) paces the long render.
        // Holding longer was measured WORSE (souphttpsrc timeout + socket churn).
        // TWO 503 STATES, and until 2026-08-29 we only ever handled one. The comment
        // above names `rendering` because that is the only value we anticipated;
        // CV's X-Cilex-Mosaic-State actually carries two (their letter, reply2 §3):
        //   rendering  — a cold composite is BUILDING       Retry-After 1
        //   saturated  — the render backlog is AT ITS CAP   Retry-After 3
        // Retrying `rendering` waits on work already running. Retrying `saturated`
        // re-queues against a queue that is FULL — and the old
        // `qBound(400, ra * 1000, 2000)` silently clamped their 3 s down to 2 s, so
        // we re-asked FASTER than we were told to, exactly when the renderer had no
        // room. 136 soak cycles produced 6,924 responses (~51/cycle), 549+ saturated.
        //
        // Worse, the ceiling could not express the invariant it stood in for: at
        // 12 x 2000 ms the chain ran 24 s and blew straight through souphttpsrc's
        // ~15 s abort, earning a player re-request on top of our own retries. So
        // honour Retry-After up to 8 s and bound the TOTAL instead. At Retry-After:1
        // that is 12 retries ≈ 13 s — today's behaviour, unchanged. At Retry-After:3
        // it is ~4 retries ≈ 12 s, three times fewer arrivals and inside the abort.
        if (code == 503 && attempt < 12) {
            int delayMs = 400;                       // single-camera remux is sub-second
            bool ok = false;
            const int ra = reply->rawHeader("Retry-After").toInt(&ok);
            if (ok && ra > 0) delayMs = qBound(400, ra * 1000, 8000);
            if (spentMs + delayMs <= kRetryBudgetMs) {
                QTimer::singleShot(delayMs, this,
                                   [this, guardedSock, path, attempt, spentMs, delayMs]() {
                    if (guardedSock && guardedSock->state() == QAbstractSocket::ConnectedState) {
                        forward(guardedSock, path, attempt + 1, spentMs + delayMs);
                    } else {
                        // Leader abandoned mid-retry. Anyone parked behind it would
                        // otherwise wait forever — this is the wedge. A clean 503 hands
                        // them to the player's own patient re-ask loop.
                        deliver(path, nullptr, 503, QByteArrayLiteral("text/plain"),
                                QByteArrayLiteral("upstream retry abandoned"));
                    }
                });
                return;
            }
            // Budget spent: fall through and hand the player a CLEAN 503 so its own
            // patient outer loop (playlist refetch + re-request) paces the render —
            // which is what the block above always intended to happen at attempt 12.
        }
        // Build the response ONCE, then hand it to exactly one delivery point below.
        int outCode = 200;
        QByteArray outCt, body;
        if (reply->error() != QNetworkReply::NoError && code == 0) {
            outCode = 502;
            outCt = QByteArrayLiteral("text/plain");
            body = reply->errorString().toUtf8();
        } else {
            body = reply->readAll();
            outCt = reply->header(QNetworkRequest::ContentTypeHeader).toByteArray();
            if (path.endsWith(QLatin1String(".m3u8")) || outCt.contains("mpegurl")) {
                body = rewritePlaylist(body);
                if (outCt.isEmpty()) outCt = QByteArrayLiteral("application/vnd.apple.mpegurl");
            } else if (isSegmentPath(path) && (code == 200 || code == 0)) {
                cachePut(path, body, outCt);   // warm the cache for re-seeks to this region
            }
            outCode = code ? code : 200;
            if (outCt.isEmpty()) outCt = QByteArrayLiteral("application/octet-stream");
        }
        // TEST hook: hold a segment response s_slowMs before delivering, to emulate a
        // slow backend so the player's read blocks (as it does on a degraded backend).
        // Deferred on THIS (proxy) thread; the socket may be closed meanwhile (player
        // teardown / disconnect) → writeResponse no-ops on a non-connected socket.
        if (s_slowMs > 0 && isSegmentPath(path)) {
            static int s_nthSeg = 0;   // WT_HLS_SLOW_EVERY: hold only every Nth segment
            if (++s_nthSeg % s_slowEvery == 0) {
                QTimer::singleShot(s_slowMs, this,
                                   [this, path, guardedSock, outCode, outCt, body]() {
                    deliver(path, guardedSock, outCode, outCt, body);   // still the one exit
                });
                return;
            }
        }
        deliver(path, guardedSock, outCode, outCt, body);
    });
}

// /api/review -> /review, drop #EXT-X-GAP placeholder segments, and normalize
// #EXT-X-DISCONTINUITY so EVERY media segment is preceded by exactly one.
//
// Why (diagnosed 2026-06-14): every review/mosaic segment is encoded
// independently and RESETS its PTS (single-cam segments start at ~1.4 s, mosaic
// at 0). hlsdemux2 only stays in sync across a PTS reset if a #EXT-X-DISCONTINUITY
// announces it. Continuous 24/7 cameras get one per segment from the backend and
// play fine; motion-triggered clips (and cold mosaics) DON'T get them between
// in-clip segments, so the player decodes the first segment then freezes on the
// backward PTS jump while the playhead clock free-runs — frozen frame, ticking
// timer (reproduced on .106's motion clips: stalled after ~5 s of each clip).
// We add the missing tags, deduped, so it's a no-op where the backend already
// emits them (.108, mosaic post-0d71c0d). Backend letter filed; this is the
// client safety net. Also strips #EXT-X-GAP dead-air so playback skips gaps.
QByteArray HlsProxy::rewritePlaylist(const QByteArray &in)
{
    QByteArray s = in;
    s.replace("/api/review/", "/review/");
    const QList<QByteArray> lines = s.split('\n');

    // Pass 1 — strip #EXT-X-GAP blocks: remove the gap's #EXTINF (+ a preceding
    // #EXT-X-PROGRAM-DATE-TIME) and the gap-N.ts URI, so playback skips dead air.
    QList<QByteArray> kept;
    kept.reserve(lines.size());
    bool skipNextSeg = false;
    for (const QByteArray &line : lines) {
        const QByteArray t = line.trimmed();
        if (skipNextSeg && t.endsWith(".ts")) { skipNextSeg = false; continue; }
        if (t == "#EXT-X-GAP") {
            while (!kept.isEmpty()) {
                const QByteArray lt = kept.last().trimmed();
                if (lt.startsWith("#EXTINF") || lt.startsWith("#EXT-X-PROGRAM-DATE-TIME"))
                    kept.removeLast();
                else break;
            }
            skipNextSeg = true;
            continue;
        }
        kept.append(line);
    }

#ifdef Q_OS_MACOS
    // macOS diet (2026-08-17): trust the UPSTREAM discontinuity structure — dedupe and
    // drop leading tags, but never inject. The injector below marks EVERY segment
    // boundary as a discontinuity (the legacy-session crutch); FFmpeg tolerates that,
    // but if the darwin/AVFoundation backend is serving MediaPlayer, AVPlayer restarts
    // its pipeline at each marked break and freezes after the first segment — the
    // operator's v1.1.101 symptom (first frame renders, then a still). Measured upstream
    // tonight: a continuous session's playlist carries NO mid-window discontinuities;
    // the injected ones were pure fabrication for this player.
    {
        QList<QByteArray> mout;
        mout.reserve(kept.size());
        bool sawSeg = false, pendingDisc = false;
        for (const QByteArray &line : kept) {
            const QByteArray t = line.trimmed();
            if (t == "#EXT-X-DISCONTINUITY") { pendingDisc = sawSeg; continue; }   // hold one; drop leading
            if (pendingDisc && (t.startsWith("#EXTINF") || t.startsWith("#EXT-X-PROGRAM-DATE-TIME"))) {
                mout.append(QByteArrayLiteral("#EXT-X-DISCONTINUITY"));
                pendingDisc = false;
            }
            mout.append(line);
            if (t.endsWith(".ts")) sawSeg = true;
        }
        return mout.join('\n');
    }
#endif

    // Pass 2 — ensure each real segment is preceded by exactly one discontinuity
    // (inject before its metadata block; dedupe consecutive; drop leading ones —
    // the first segment establishes the timeline and needs none).
    QList<QByteArray> out;
    out.reserve(kept.size() + 16);
    bool needDiscont = false;     // a segment was emitted; the next one needs a discontinuity
    for (const QByteArray &line : kept) {
        const QByteArray t = line.trimmed();
        if (t == "#EXT-X-DISCONTINUITY") {
            if (!needDiscont) continue;            // dedupe / drop leading
            needDiscont = false;
            out.append(line);
            continue;
        }
        if (needDiscont && (t.startsWith("#EXT-X-PROGRAM-DATE-TIME") || t.startsWith("#EXTINF"))) {
            out.append(QByteArrayLiteral("#EXT-X-DISCONTINUITY"));
            needDiscont = false;
        }
        out.append(line);
        if (t.endsWith(".ts")) needDiscont = true;   // the NEXT segment needs one
    }
    return out.join('\n');
}

void HlsProxy::writeHead(QTcpSocket *sock, int code, const QByteArray &contentType, qint64 len)
{
    if (!sock || sock->state() != QAbstractSocket::ConnectedState)
        return;
    QByteArray resp = "HTTP/1.1 " + QByteArray::number(code) + " OK\r\n";
    resp += "Content-Type: " + contentType + "\r\n";
    if (len >= 0)
        resp += "Content-Length: " + QByteArray::number(len) + "\r\n";
    resp += "Cache-Control: no-store\r\n";
    resp += "Connection: close\r\n\r\n";
    sock->write(resp);
    sock->flush();
}

void HlsProxy::writeResponse(QTcpSocket *sock, int code, const QByteArray &contentType,
                             const QByteArray &body)
{
    if (sock->state() != QAbstractSocket::ConnectedState)
        return;
    QByteArray resp = "HTTP/1.1 " + QByteArray::number(code) + " OK\r\n";
    resp += "Content-Type: " + contentType + "\r\n";
    resp += "Content-Length: " + QByteArray::number(body.size()) + "\r\n";
    resp += "Cache-Control: no-store\r\n";
    resp += "Connection: close\r\n\r\n";
    resp += body;
    sock->write(resp);
    sock->flush();
    sock->disconnectFromHost();
}
