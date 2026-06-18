#include "CvImageProvider.h"
#include "AuthController.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QThread>

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
