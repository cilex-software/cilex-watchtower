#include "StorageHealth.h"
#include "AuthController.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QJsonDocument>
#include <QJsonObject>

StorageHealth::StorageHealth(QObject *parent)
    : QObject(parent)
{
    auto *auth = AuthController::instance();
    m_nam = auth->nam();
    m_baseUrl = auth->baseUrl();
    connect(auth, &AuthController::baseUrlChanged, this,
            [this, auth]() { m_baseUrl = auth->baseUrl(); });
    connect(auth, &AuthController::authenticatedChanged, this, [this, auth]() {
        if (!auth->authenticated()) {     // signed out — forget last-known health
            m_loaded = false;
            emit changed();
        }
    });
}

void StorageHealth::refresh()
{
    if (qEnvironmentVariableIsSet("WT_DEMO") || m_loading)
        return;
    if (!AuthController::instance()->authenticated())
        return;                           // not signed in — leave status unknown
    m_loading = true;
    fetch();
}

void StorageHealth::fetch()
{
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/health/storage")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        m_loading = false;
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401)
            AuthController::instance()->noteUnauthorized();
        if (reply->error() != QNetworkReply::NoError)
            return;                       // keep last-known; loaded stays as-is
        const auto o = QJsonDocument::fromJson(reply->readAll()).object();
        m_status = o.value("status").toString();
        m_degraded = o.value("degraded").toBool();
        m_reachable = o.value("storage_agent_reachable").toBool(true);
        m_circuitOpen = o.value("circuit_open").toBool();
        m_state = o.value("state").toString();
        m_lastOkAt = o.value("last_ok_at").toString();
        m_checkedAt = o.value("checked_at").toString();
        m_consecutiveFailures = o.value("consecutive_failures").toInt();
        m_reason = o.value("reason").toString();
        m_lastError = o.value("last_error").toString();
        m_reasonText = o.value("reason_text").toString();
        m_loaded = true;
        emit changed();
    });
}
