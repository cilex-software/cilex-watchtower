#include "HlsProxy.h"

#include <QDebug>
#include <QElapsedTimer>
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
    forward(sock, path, 0);
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
            body = rewritePlaylist(body, path.contains(QLatin1String("/mosaic-sessions/")));
            if (ct.isEmpty()) ct = "application/vnd.apple.mpegurl";
        }
        writeResponse(sock, code ? code : 200, ct.isEmpty() ? "application/octet-stream" : ct, body);
    });
}

// /api/review -> /review, drop #EXT-X-GAP placeholder segments, and (mosaic only)
// inject #EXT-X-DISCONTINUITY before each segment.
//
// WORKAROUND (diagnosed 2026-06-14, backend letter filed): every mosaic segment
// is rendered independently with reset timestamps (each starts at PTS 0), but the
// mosaic playlist declares a continuous timeline with NO #EXT-X-DISCONTINUITY —
// so the player plays seg0 (0–6 s) then freezes at the boundary when seg1's PTS
// jumps back to 0 with no discontinuity to explain it (cold wall stalls after the
// first 6 s). The single-camera playlist already carries discontinuities and
// plays fine. We inject the missing tags so the player re-bases per segment.
// Auto-disables the moment the backend emits its own discontinuities.
QByteArray HlsProxy::rewritePlaylist(const QByteArray &in, bool injectDiscontinuities)
{
    QByteArray s = in;
    s.replace("/api/review/", "/review/");
    const bool inject = injectDiscontinuities && !s.contains("#EXT-X-DISCONTINUITY");
    const QList<QByteArray> lines = s.split('\n');
    QList<QByteArray> out;
    out.reserve(lines.size());
    bool skipNextGapSeg = false;
    bool sawFirstSeg = false;
    for (QByteArray line : lines) {
        const QByteArray trimmed = line.trimmed();
        if (skipNextGapSeg && trimmed.startsWith("gap-")) {
            skipNextGapSeg = false;
            continue;
        }
        if (trimmed == "#EXT-X-GAP") {
            if (!out.isEmpty() && out.last().trimmed().startsWith("#EXTINF"))
                out.removeLast();
            skipNextGapSeg = true;
            continue;
        }
        if (inject && trimmed.startsWith("#EXTINF")) {
            if (sawFirstSeg) out.append(QByteArrayLiteral("#EXT-X-DISCONTINUITY"));
            sawFirstSeg = true;
        }
        out.append(line);
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
