#include "SiteMapModel.h"
#include "AuthController.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QJsonValue>
#include <QUrl>

SiteMapModel::SiteMapModel(QObject *parent)
    : QObject(parent)
{
    auto *auth = AuthController::instance();
    m_nam = auth->nam();
    m_baseUrl = auth->baseUrl();
    connect(auth, &AuthController::baseUrlChanged, this, [this, auth]() { m_baseUrl = auth->baseUrl(); });
}

void SiteMapModel::load()
{
    if (m_baseUrl.isEmpty() || !AuthController::instance()->authenticated())
        return;
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/maps?status=active")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200)
            return;
        const QJsonArray arr = QJsonDocument::fromJson(reply->readAll()).object().value("maps").toArray();
        if (arr.isEmpty())
            return;                          // no active plan — Map stays on the grid fallback
        fetchDetail(arr.first().toObject().value("id").toString());
    });
}

void SiteMapModel::fetchDetail(const QString &mapId)
{
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/maps/" + mapId)});
    connect(reply, &QNetworkReply::finished, this, [this, reply, mapId]() {
        reply->deleteLater();
        if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200)
            return;
        const QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
        m_backgroundUrl = o.value("background_url").toString();   // pre-signed URL, loaded directly
        m_planName = o.value("name").toString();
        m_planWidth = o.value("width_px").toInt();
        m_planHeight = o.value("height_px").toInt();
        fetchObjects(mapId);
    });
}

void SiteMapModel::fetchObjects(const QString &mapId)
{
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/maps/" + mapId + "/objects")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200)
            return;
        const QJsonArray arr = QJsonDocument::fromJson(reply->readAll()).object().value("objects").toArray();
        m_placements.clear();
        for (const QJsonValue &v : arr) {
            const QJsonObject o = v.toObject();
            if (o.value("object_type").toString() != QLatin1String("camera"))
                continue;
            QVariantMap p;
            p["cameraId"] = o.value("linked_entity_id").toString();
            p["x"] = o.value("x_norm").toDouble();
            p["y"] = o.value("y_norm").toDouble();
            p["rotation"] = o.value("rotation_deg").toDouble();
            p["name"] = o.value("name").toString();
            m_placements.append(p);
        }
        m_ready = true;
        emit changed();
    });
}
