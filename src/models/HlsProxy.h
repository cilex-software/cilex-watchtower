#pragma once

#include <QObject>
#include <QTcpServer>
#include <QString>

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
//   - retries briefly on 503 (a cold fragment remuxes sub-second, then 200).
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
    static QByteArray rewritePlaylist(const QByteArray &in, bool injectDiscontinuities = false);
    void writeResponse(QTcpSocket *sock, int code, const QByteArray &contentType,
                       const QByteArray &body);

    QTcpServer m_server;
    QNetworkAccessManager *m_nam;
    QString m_upstream;
};
