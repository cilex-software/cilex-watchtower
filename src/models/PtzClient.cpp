#include "PtzClient.h"
#include "AuthController.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>

PtzClient::PtzClient(QObject *parent) : QObject(parent)
{
    m_nam = AuthController::instance()->nam();
    // WT_DEMO = app-wide demo store; WT_PTZ_DEMO = mock ONLY this client against
    // real cameras (panel-interaction verification until the backend endpoint ships).
    m_demo = qEnvironmentVariableIsSet("WT_DEMO") || qEnvironmentVariableIsSet("WT_PTZ_DEMO");
    m_safety.setSingleShot(true);
    // A vanished release event (window loses focus mid-hold, Wayland grab break)
    // must never leave a camera panning forever: hard-stop after 5 s of hold.
    m_safety.setInterval(5000);
    connect(&m_safety, &QTimer::timeout, this, [this]() { if (m_safetyStop) m_safetyStop(); });
}

void PtzClient::probe(const QString &camId)
{
    if (camId.isEmpty()) return;
    if (m_demo) {   // demo mock: motorized lens, home supported (WT_DEMO builds only)
        QTimer::singleShot(150, this, [this, camId]() {
            emit capsReady(camId, QStringLiteral("lens"), true, false);
        });
        return;
    }
    if (m_caps.contains(camId)) {
        const Caps &c = m_caps.value(camId);
        emit capsReady(camId, c.supported, c.home, c.pending);
        return;
    }
    QNetworkRequest req{QUrl(AuthController::instance()->baseUrl()
                             + "/cameras/" + camId + "/ptz")};
    QNetworkReply *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply, camId]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 200) {
            const QJsonObject obj = QJsonDocument::fromJson(reply->readAll()).object();
            Caps c;
            c.supported = obj.value(QStringLiteral("supported")).toString(QStringLiteral("none"));
            c.home = obj.value(QStringLiteral("home_supported")).toBool(false);
            m_caps.insert(camId, c);
            emit capsReady(camId, c.supported, c.home, false);
        } else if (code == 404 || code == 405 || code == 501) {
            // Endpoint not shipped upstream yet -> honest pending state. Cached for
            // the session; a backend deploy is picked up on next app start.
            Caps c; c.pending = true; c.supported = QStringLiteral("none");
            m_caps.insert(camId, c);
            emit capsReady(camId, c.supported, false, true);
        } else {
            // transient (auth/5xx/transport): report, do NOT cache — retry next open
            emit opFailed(camId, QStringLiteral("probe"),
                          reply->error() != QNetworkReply::NoError
                              ? reply->errorString()
                              : QStringLiteral("HTTP %1").arg(code));
        }
    });
}

void PtzClient::post(const QString &camId, const QString &what, const QString &tail,
                     const QByteArray &json)
{
    if (camId.isEmpty()) return;
    if (m_demo) { emit opDone(camId, what); return; }
    const Caps c = m_caps.value(camId);
    if (c.pending || c.supported == QLatin1String("none")) return;   // UI disables; belt+braces
    QNetworkRequest req{QUrl(AuthController::instance()->baseUrl()
                             + "/cameras/" + camId + "/ptz" + tail)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    QNetworkReply *reply = m_nam->post(req, json);
    connect(reply, &QNetworkReply::finished, this, [this, reply, camId, what]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code >= 200 && code < 300)
            emit opDone(camId, what);
        else
            emit opFailed(camId, what,
                          reply->error() != QNetworkReply::NoError
                              ? reply->errorString()
                              : QStringLiteral("HTTP %1").arg(code));
    });
}

void PtzClient::armSafetyStop(std::function<void()> stopFn)
{
    m_safetyStop = std::move(stopFn);
    m_safety.start();
}

void PtzClient::continuousMove(const QString &camId, double pan, double tilt, double zoom)
{
    const bool isStop = pan == 0.0 && tilt == 0.0 && zoom == 0.0;
    QJsonObject o{{QStringLiteral("pan"), pan},
                  {QStringLiteral("tilt"), tilt},
                  {QStringLiteral("zoom"), zoom}};
    post(camId, isStop ? QStringLiteral("stop") : QStringLiteral("move"),
         QStringLiteral("/continuous"), QJsonDocument(o).toJson(QJsonDocument::Compact));
    if (isStop) { m_safety.stop(); m_safetyStop = nullptr; }
    else armSafetyStop([this, camId]() { continuousMove(camId, 0, 0, 0); });
}

void PtzClient::stopMove(const QString &camId) { continuousMove(camId, 0, 0, 0); }

void PtzClient::focusMove(const QString &camId, double speed)
{
    QJsonObject o{{QStringLiteral("speed"), speed}};
    post(camId, speed == 0.0 ? QStringLiteral("focus-stop") : QStringLiteral("focus"),
         QStringLiteral("/focus"), QJsonDocument(o).toJson(QJsonDocument::Compact));
    if (speed == 0.0) { m_safety.stop(); m_safetyStop = nullptr; }
    else armSafetyStop([this, camId]() { focusMove(camId, 0); });
}

void PtzClient::focusAuto(const QString &camId)
{
    post(camId, QStringLiteral("focus-auto"), QStringLiteral("/focus/auto"),
         QByteArrayLiteral("{}"));
}

void PtzClient::restoreDefaults(const QString &camId)
{
    // The one-button restore: backend maps to home preset (PTZ) and/or lens
    // defaults + autofocus (motorized lens) — semantics in the 2026-07-16 letter.
    post(camId, QStringLiteral("reset"), QStringLiteral("/reset"), QByteArrayLiteral("{}"));
}
