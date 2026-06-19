#include "CvImageProvider.h"
#include "AuthController.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QThread>
#include <QTimer>

// The event-snapshot path 503-sheds under memory pressure (the backend governor).
// That's transient + carries Retry-After, so retry a bounded few times before
// giving up to the live-frame fallback. 404 (no clip) still fails immediately.
static constexpr int kMaxSnapshotRetries = 3;

CvImageResponse::~CvImageResponse()
{
    if (m_reply)
        m_reply->abort();
}

void CvImageResponse::cancel()
{
    if (m_reply)
        m_reply->abort();
}

void CvImageResponse::start()
{
    if (!m_auth) { emit finished(); return; }
    QNetworkRequest req{QUrl(m_auth->baseUrl() + "/" + m_path)};
    m_reply = m_auth->nam()->get(req);   // cookie auto-attached by the shared jar
    connect(m_reply, &QNetworkReply::finished, this, [this]() {
        QNetworkReply *r = m_reply;
        if (!r) { emit finished(); return; }
        const int code = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 200) {
            QImage img;
            if (img.loadFromData(r->readAll()))
                m_image = img;
            else
                m_error = QStringLiteral("decode failed");
        } else if (r->error() == QNetworkReply::OperationCanceledError) {
            m_error = QStringLiteral("cancelled");
        } else if (code == 503 && m_attempt < kMaxSnapshotRetries) {
            // Governor shed under memory pressure — transient. Honor Retry-After
            // (seconds; default ~1.2s) and retry; the still shows once pressure clears.
            bool ok = false;
            const int ra = r->rawHeader("Retry-After").toInt(&ok);
            const int delayMs = (ok && ra > 0) ? qMin(ra, 5) * 1000 : 1200;
            ++m_attempt;
            r->deleteLater();
            m_reply = nullptr;
            QTimer::singleShot(delayMs, this, &CvImageResponse::start);
            return;
        } else {
            m_error = QStringLiteral("HTTP %1").arg(code);   // 404 → caller falls back to the live frame
        }
        r->deleteLater();
        m_reply = nullptr;
        emit finished();
    });
}

QQuickImageResponse *CvImageProvider::requestImageResponse(const QString &id, const QSize &)
{
    auto *resp = new CvImageResponse(m_auth, id);
    // The NAM lives on the GUI thread; move the response there and kick the fetch
    // on that thread (this method runs on the pixmap-loader worker thread).
    resp->moveToThread(m_auth->thread());
    QMetaObject::invokeMethod(resp, &CvImageResponse::start, Qt::QueuedConnection);
    return resp;
}
