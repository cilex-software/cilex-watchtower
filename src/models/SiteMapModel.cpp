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

void SiteMapModel::clearPlan()
{
    m_ready = false;
    m_backgroundUrl.clear();
    m_planName.clear();
    m_planWidth = m_planHeight = 0;
    m_placements.clear();
}

void SiteMapModel::load()
{
    if (m_baseUrl.isEmpty() || !AuthController::instance()->authenticated())
        return;
    // Full list, always refetched: admins add/replace/delete maps while the
    // wall runs, and a presigned background URL is a snapshot, not a truth.
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/maps")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200)
            return;                          // transient — keep whatever we have
        const QJsonArray arr = QJsonDocument::fromJson(reply->readAll()).object().value("maps").toArray();
        m_maps.clear();
        QString firstActive, first;
        bool currentStillExists = false;
        for (const QJsonValue &v : arr) {
            const QJsonObject o = v.toObject();
            QVariantMap m;
            m["id"] = o.value("id").toString();
            m["name"] = o.value("name").toString();
            m["status"] = o.value("status").toString();
            m["updatedAt"] = o.value("updated_at").toString();
            m_maps.append(m);
            if (first.isEmpty()) first = m["id"].toString();
            if (firstActive.isEmpty() && m["status"].toString() == QLatin1String("active"))
                firstActive = m["id"].toString();
            if (m["id"].toString() == m_currentId)
                currentStillExists = true;
        }
        if (arr.isEmpty()) {
            // the admin deleted every map — a ghost plan must not survive that
            m_currentId.clear();
            clearPlan();
            emit changed();
            return;
        }
        const QString pick = currentStillExists ? m_currentId
                            : (!firstActive.isEmpty() ? firstActive : first);
        m_currentId = pick;
        emit changed();                      // maps list is fresh even before the detail lands
        fetchDetail(pick);                   // always re-pull: updated_at/presigned URL may have rolled
    });
}

void SiteMapModel::selectMap(const QString &mapId)
{
    if (mapId.isEmpty() || mapId == m_currentId)
        return;
    m_currentId = mapId;
    emit changed();
    fetchDetail(mapId);
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
