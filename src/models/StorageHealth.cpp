#include "StorageHealth.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcessEnvironment>

StorageHealth::StorageHealth(QObject *parent)
    : QObject(parent), m_nam(new QNetworkAccessManager(this))
{
    const auto env = QProcessEnvironment::systemEnvironment();
    m_baseUrl = env.value("WT_CV_URL", "http://192.168.1.79:8000");
    m_user = env.value("WT_CV_USER", "admin");
    m_pass = env.value("WT_CV_PASS", "admin");
}

void StorageHealth::refresh()
{
    if (qEnvironmentVariableIsSet("WT_DEMO") || m_loading)
        return;
    m_loading = true;
    if (m_loggedIn)
        fetch();
    else
        login();
}

void StorageHealth::login()
{
    QNetworkRequest req{QUrl(m_baseUrl + "/auth/login")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonObject body{{"username", m_user}, {"password", m_pass}};
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() != QNetworkReply::NoError || code != 200) {
            m_loading = false;            // unreachable; leave loaded=false (status unknown)
            return;
        }
        m_loggedIn = true;
        fetch();
    });
}

void StorageHealth::fetch()
{
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/health/storage")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        m_loading = false;
        if (reply->error() != QNetworkReply::NoError)
            return;                       // keep last-known; loaded stays as-is
        const auto o = QJsonDocument::fromJson(reply->readAll()).object();
        m_status = o.value("status").toString();
        m_degraded = o.value("degraded").toBool();
        m_reachable = o.value("storage_agent_reachable").toBool(true);
        m_circuitOpen = o.value("circuit_open").toBool();
        m_reason = o.value("reason").toString();
        if (m_reason.isEmpty())
            m_reason = o.value("last_error").toString();
        m_loaded = true;
        emit changed();
    });
}
