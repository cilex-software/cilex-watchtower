#include "HlsProxy.h"

#include <QDebug>
#include <QElapsedTimer>
#include <QFile>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QTcpSocket>
#include <QTimer>
#include <QUrl>

namespace {
// WT_HLS_LOG=1 — per-request upstream timing on stderr ("WTHLS …"), for
// diagnosing playback/seek latency (segment fetch time, 503 remux retries).
const bool s_hlsLog = qEnvironmentVariableIsSet("WT_HLS_LOG");
}

HlsProxy::HlsProxy(QNetworkAccessManager *nam, QObject *parent)
    : QObject(parent), m_nam(nam)
{
    connect(&m_server, &QTcpServer::newConnection, this, &HlsProxy::onNewConnection);
    // WT_PROXY_STATS=1 — periodic dump of the proxy's live internals, to localize the per-open RSS leak.
    if (qEnvironmentVariableIsSet("WT_PROXY_STATS")) {
        auto *t = new QTimer(this);
        connect(t, &QTimer::timeout, this, [this]() {
            qInfo("[PROXYSTATS] cacheN=%lld cacheMB=%lld inflight=%lld sockets=%lld replies=%lld",
                  (long long)m_segCache.size(), (long long)(m_segBytes / 1048576),
                  (long long)m_inflight.size(),
                  (long long)m_server.findChildren<QTcpSocket *>().size(),
                  (long long)m_nam->findChildren<QNetworkReply *>().size());
        });
        t->start(3000);
    }
}

bool HlsProxy::start()
{
    if (m_server.isListening())
        return true;
    return m_server.listen(QHostAddress::LocalHost, 0);
}

QString HlsProxy::localBase() const
{
    return QStringLiteral("http://127.0.0.1:%1").arg(m_server.serverPort());
}

void HlsProxy::onNewConnection()
{
    while (QTcpSocket *sock = m_server.nextPendingConnection()) {
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
    if (isSegmentPath(path)) {
        // Kick read-ahead in parallel with serving this one, so the demuxer's
        // next (serial) request lands in cache instead of a fresh cold fetch.
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

void HlsProxy::forward(QTcpSocket *sock, const QString &path, int attempt)
{
    QNetworkRequest req{QUrl(m_upstream + path)};
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    QNetworkReply *reply = m_nam->get(req);          // cookie auto-attached by shared jar
    QElapsedTimer fetchTimer;
    fetchTimer.start();
    // Guard the socket with QPointer: the player (GStreamer hlsdemux) aborts and
    // closes in-flight segment requests aggressively while scrubbing, which
    // deleteLater()s the socket. By the time this reply finishes — or the 503
    // retry timer fires 400ms later — sock may already be freed, so a raw
    // pointer here is a use-after-free. QPointer nulls out on destruction.
    QPointer<QTcpSocket> guardedSock(sock);
    connect(reply, &QNetworkReply::finished, this, [this, reply, guardedSock, path, attempt, fetchTimer]() {
        reply->deleteLater();
        if (s_hlsLog) {
            const int logCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            qInfo().noquote() << QStringLiteral("WTHLS a=%1 code=%2 ms=%3 %4")
                .arg(attempt).arg(logCode).arg(fetchTimer.elapsed())
                .arg(path.section(QLatin1Char('/'), -3));
        }
        if (!guardedSock || guardedSock->state() != QAbstractSocket::ConnectedState)
            return;
        QTcpSocket *sock = guardedSock;
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
        if (code == 503 && attempt < 12) {
            // Honor the server's Retry-After (seconds). The mosaic cold path sends
            // 503 + Retry-After: 1 + X-Cilex-Mosaic-State: rendering while it
            // composites, then 200 on retry. Default 400ms (single-camera remux is
            // sub-second); clamp so one header can't stall us.
            int delayMs = 400;
            bool ok = false;
            const int ra = reply->rawHeader("Retry-After").toInt(&ok);
            if (ok && ra > 0) delayMs = qBound(400, ra * 1000, 2000);
            QTimer::singleShot(delayMs, this, [this, guardedSock, path, attempt]() {
                if (guardedSock && guardedSock->state() == QAbstractSocket::ConnectedState)
                    forward(guardedSock, path, attempt + 1);
            });
            return;
        }
        if (reply->error() != QNetworkReply::NoError && code == 0) {
            writeResponse(sock, 502, "text/plain", reply->errorString().toUtf8());
            return;
        }
        QByteArray body = reply->readAll();
        QByteArray ct = reply->header(QNetworkRequest::ContentTypeHeader).toByteArray();
        if (path.endsWith(QLatin1String(".m3u8")) || ct.contains("mpegurl")) {
            body = rewritePlaylist(body);
            if (ct.isEmpty()) ct = "application/vnd.apple.mpegurl";
        } else if (isSegmentPath(path) && (code == 200 || code == 0)) {
            cachePut(path, body, ct);   // warm the cache for re-seeks to this region
        }
        writeResponse(sock, code ? code : 200, ct.isEmpty() ? "application/octet-stream" : ct, body);
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
