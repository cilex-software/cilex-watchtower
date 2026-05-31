#include "HlsProxy.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QTcpSocket>
#include <QTimer>
#include <QUrl>

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
    // Guard the socket with QPointer: the player (GStreamer hlsdemux) aborts and
    // closes in-flight segment requests aggressively while scrubbing, which
    // deleteLater()s the socket. By the time this reply finishes — or the 503
    // retry timer fires 400ms later — sock may already be freed, so a raw
    // pointer here is a use-after-free. QPointer nulls out on destruction.
    QPointer<QTcpSocket> guardedSock(sock);
    connect(reply, &QNetworkReply::finished, this, [this, reply, guardedSock, path, attempt]() {
        reply->deleteLater();
        if (!guardedSock || guardedSock->state() != QAbstractSocket::ConnectedState)
            return;
        QTcpSocket *sock = guardedSock;
        const int code = reply->attribute(
            QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 503 && attempt < 12) {           // cold fragment remux / cold mosaic render
            // Honor the server's Retry-After (seconds). The mosaic cold path sends
            // 503 + Retry-After: 1 + X-Cilex-Mosaic-State: rendering while it
            // composites, then 200 on retry; a cold 16-cell render can exceed the
            // old fixed 3.2s. Default 400ms (single-camera remux is sub-second);
            // clamp so one header can't stall us. 12 retries ⇒ ~12s budget at
            // Retry-After:1 (hard max ~24s); see docs/letters mosaic integration.
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
        }
        writeResponse(sock, code ? code : 200, ct.isEmpty() ? "application/octet-stream" : ct, body);
    });
}

// /api/review -> /review, and drop #EXT-X-GAP placeholder segments.
QByteArray HlsProxy::rewritePlaylist(const QByteArray &in)
{
    QByteArray s = in;
    s.replace("/api/review/", "/review/");
    const QList<QByteArray> lines = s.split('\n');
    QList<QByteArray> out;
    out.reserve(lines.size());
    bool skipNextGapSeg = false;
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
