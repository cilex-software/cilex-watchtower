#include "CameraObstructionController.h"
#include "AuthController.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QUrl>

namespace {
QNetworkRequest requestFor(AuthController *auth, const QString &path)
{
    QNetworkRequest request{QUrl(auth->baseUrl() + path)};
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    request.setRawHeader("Accept", "application/json");
    request.setTransferTimeout(8000);
    auth->decorate(request);
    return request;
}
bool validIncident(const QVariantMap &incident)
{
    return !incident.value("incident_id").toString().isEmpty()
        && !incident.value("camera_id").toString().isEmpty()
        && !incident.value("state").toString().isEmpty();
}
QString detailFor(const QJsonObject &object, int status)
{
    const QString detail = object.value("detail").toString();
    return detail.isEmpty() ? QObject::tr("Camera visibility service returned HTTP %1.").arg(status) : detail;
}
}

CameraObstructionController::CameraObstructionController(AuthController *auth, QObject *parent)
    : QObject(parent), m_auth(auth)
{
    m_poll.setInterval(2000);
    connect(&m_poll, &QTimer::timeout, this, &CameraObstructionController::refresh);
    connect(auth, &AuthController::authenticatedChanged, this, &CameraObstructionController::resetSession);
    connect(auth, &AuthController::baseUrlChanged, this, &CameraObstructionController::resetSession);
    connect(auth, &AuthController::identityChanged, this, &CameraObstructionController::resetSession);
    connect(auth, &AuthController::stationLiveChanged, this, &CameraObstructionController::resetSession);
    QTimer::singleShot(0, this, &CameraObstructionController::resetSession);
}

bool CameraObstructionController::canRequest() const
{
    // A display-only credential must not gain operator incident access.
    return m_auth->authenticated() && !m_auth->stationLive() && !m_auth->baseUrl().isEmpty();
}

void CameraObstructionController::resetSession()
{
    ++m_generation;
    m_poll.stop();
    if (m_pollReply) m_pollReply->abort();
    if (m_actionReply) m_actionReply->abort();
    m_pollReply.clear();
    m_actionReply.clear();
    m_incidents.clear();
    m_reviewingIncidentId.clear();
    m_error.clear();
    m_actionError.clear();
    m_serviceStatus.clear();
    m_available = false;
    m_canManage = false;
    emit stateChanged();
    if (canRequest()) {
        m_poll.start();
        refresh();
    }
}

bool CameraObstructionController::requiresAttention(const QVariantMap &incident)
{
    const QString state = incident.value("state").toString();
    const QString disposition = incident.value("disposition").toString();
    // The server's boolean includes suppression expiry using its own clock.
    if (incident.contains("alert_pending"))
        return incident.value("alert_pending").toBool();
    if (incident.contains("requires_attention"))
        return incident.value("requires_attention").toBool();
    return (state == "obstructed" || state == "active")
        && (disposition.isEmpty() || disposition == "pending" || disposition == "unreviewed")
        && !incident.value("suppressed").toBool()
        && incident.value("suppressed_until").toString().isEmpty();
}

QVariantMap CameraObstructionController::pendingIncident() const
{
    // Only Vision-authorised responders receive the intrusive central alert.
    // Camera-scoped viewers retain the read-only review strip when navigating
    // to the camera themselves; local role strings must not override the server.
    if (!m_canManage) return {};
    // When viewing an alarm camera, its review strip replaces the central card.
    // Other incidents remain queued until the current one has been classified.
    const auto review = reviewIncident();
    if (requiresAttention(review) && review.value("incident_id").toString() == m_reviewingIncidentId) return {};
    for (const QVariant &value : m_incidents) {
        const auto incident = value.toMap();
        if (requiresAttention(incident)) return incident;
    }
    return {};
}

QVariantMap CameraObstructionController::reviewIncident() const
{
    if (m_currentCameraId.isEmpty()) return {};
    QVariantMap latest;
    for (const QVariant &value : m_incidents) {
        const auto incident = value.toMap();
        if (incident.value("camera_id").toString() != m_currentCameraId) continue;
        if (requiresAttention(incident)) return incident;
        if (latest.isEmpty() || incident.value("detected_at").toString() > latest.value("detected_at").toString())
            latest = incident;
    }
    return latest;
}

void CameraObstructionController::setCurrentCameraId(const QString &id)
{
    if (m_currentCameraId == id) return;
    m_currentCameraId = id;
    m_reviewingIncidentId.clear();
    emit stateChanged();
}

void CameraObstructionController::beginReview(const QString &incidentId)
{
    const auto incident = reviewIncident();
    if (incident.value("incident_id").toString() != incidentId) return;
    m_reviewingIncidentId = incidentId;
    emit stateChanged();
}

void CameraObstructionController::refresh()
{
    if (!canRequest() || m_pollReply || m_actionReply) return;
    const auto generation = m_generation;
    // Recent dismissed incidents retain the camera suppression/report status.
    auto *reply = m_auth->nam()->get(requestFor(m_auth, QStringLiteral("/camera-visibility/incidents?active=true")));
    m_pollReply = reply;
    connect(reply, &QNetworkReply::finished, this, [this, reply, generation]() {
        reply->deleteLater();
        if (generation != m_generation) return;
        m_pollReply.clear();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status == 401) { m_auth->noteUnauthorized(); return; }
        if (status == 403 || status == 404) {
            m_available = false;
            m_canManage = false;
            m_incidents.clear();
            m_serviceStatus = status == 403 ? tr("Camera visibility access denied") : tr("Camera visibility monitoring unavailable");
            m_poll.setInterval(30000);
            emit stateChanged();
            return;
        }
        QJsonParseError parseError;
        const auto document = QJsonDocument::fromJson(reply->readAll(), &parseError);
        if (status != 200 || reply->error() != QNetworkReply::NoError
            || parseError.error != QJsonParseError::NoError || !document.isObject()
            || !document.object().value("incidents").isArray()) {
            // Keep the last incident visible, explicitly stale, on transport loss.
            m_error = tr("Camera visibility updates unavailable; displayed state may be stale.");
            emit stateChanged();
            return;
        }
        QVariantList incidents;
        for (const auto &value : document.object().value("incidents").toArray()) {
            if (!value.isObject() || !validIncident(value.toObject().toVariantMap())) {
                m_error = tr("Invalid camera visibility incident received; displayed state may be stale.");
                emit stateChanged();
                return;
            }
            incidents.append(value.toObject().toVariantMap());
        }
        m_incidents = incidents;
        if (!requiresAttention(reviewIncident())) m_reviewingIncidentId.clear();
        m_available = true;
        m_canManage = document.object().value("can_manage").toBool(false);
        m_error = m_actionError;
        m_serviceStatus = document.object().value("service_status").toString();
        m_poll.setInterval(2000);
        emit stateChanged();
    });
}

void CameraObstructionController::replaceIncident(const QVariantMap &incident)
{
    for (auto &value : m_incidents) {
        if (value.toMap().value("incident_id") == incident.value("incident_id")) {
            value = incident;
            if (!requiresAttention(incident) && incident.value("incident_id").toString() == m_reviewingIncidentId)
                m_reviewingIncidentId.clear();
            return;
        }
    }
    m_incidents.append(incident);
}

void CameraObstructionController::act(const QString &incidentId, const QString &action)
{
    if (!canRequest() || !m_canManage || m_actionReply || incidentId.isEmpty()) return;
    if (action != "false_alarm" && action != "confirm" && action != "disable_7d") return;
    QVariantMap selected;
    for (const auto &value : m_incidents)
        if (value.toMap().value("incident_id").toString() == incidentId) selected = value.toMap();
    if (selected.isEmpty() || (action == "disable_7d" && !selected.value("can_disable_7d").toBool())) return;
    // Invalidate a GET already in flight so it cannot restore pre-action state.
    ++m_generation;
    if (m_pollReply) m_pollReply->abort();
    m_pollReply.clear();
    const auto generation = m_generation;
    m_error.clear();
    m_actionError.clear();
    const QString path = "/camera-visibility/incidents/" + QString::fromLatin1(QUrl::toPercentEncoding(incidentId)) + "/actions";
    auto *reply = m_auth->nam()->post(requestFor(m_auth, path),
                                    QJsonDocument(QJsonObject{{"action", action}}).toJson(QJsonDocument::Compact));
    m_actionReply = reply;
    emit stateChanged();
    connect(reply, &QNetworkReply::finished, this, [this, reply, generation, incidentId]() {
        reply->deleteLater();
        if (generation != m_generation) return;
        m_actionReply.clear();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        QJsonParseError parseError;
        const auto document = QJsonDocument::fromJson(reply->readAll(), &parseError);
        const auto object = document.object();
        const auto incident = object.value("incident").isObject()
            ? object.value("incident").toObject().toVariantMap() : object.toVariantMap();
        if (status >= 200 && status < 300 && reply->error() == QNetworkReply::NoError
            && parseError.error == QJsonParseError::NoError && validIncident(incident)
            && incident.value("incident_id").toString() == incidentId) {
            replaceIncident(incident);
            m_error.clear();
        } else {
            m_error = tr("Action was not confirmed. %1").arg(detailFor(object, status));
            m_actionError = m_error;
            emit actionFailed(m_error);
        }
        emit stateChanged();
        if (status == 401) m_auth->noteUnauthorized();
        else refresh();
    });
}
