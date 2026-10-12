#pragma once

#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

class AuthController;
class QNetworkReply;

// App-lifetime visibility incident client. Detection, acknowledgement and all
// suppression deadlines belong to Vision, never to a workstation clock/cache.
class CameraObstructionController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList incidents READ incidents NOTIFY stateChanged)
    Q_PROPERTY(QVariantMap pendingIncident READ pendingIncident NOTIFY stateChanged)
    Q_PROPERTY(QVariantMap reviewIncident READ reviewIncident NOTIFY stateChanged)
    Q_PROPERTY(QString currentCameraId READ currentCameraId WRITE setCurrentCameraId NOTIFY stateChanged)
    Q_PROPERTY(bool available READ available NOTIFY stateChanged)
    Q_PROPERTY(bool actionBusy READ actionBusy NOTIFY stateChanged)
    Q_PROPERTY(bool canManage READ canManage NOTIFY stateChanged)
    Q_PROPERTY(QString errorString READ errorString NOTIFY stateChanged)
    Q_PROPERTY(QString serviceStatus READ serviceStatus NOTIFY stateChanged)
public:
    explicit CameraObstructionController(AuthController *auth, QObject *parent = nullptr);
    QVariantList incidents() const { return m_incidents; }
    QVariantMap pendingIncident() const;
    QVariantMap reviewIncident() const;
    QString currentCameraId() const { return m_currentCameraId; }
    void setCurrentCameraId(const QString &id);
    bool available() const { return m_available; }
    bool actionBusy() const { return !m_actionReply.isNull(); }
    bool canManage() const { return m_canManage; }
    QString errorString() const { return m_error; }
    QString serviceStatus() const { return m_serviceStatus; }

    Q_INVOKABLE void refresh();
    Q_INVOKABLE void beginReview(const QString &incidentId);
    Q_INVOKABLE void act(const QString &incidentId, const QString &action);
    // Shared by the production client and deterministic contract checks.
    static bool requiresAttention(const QVariantMap &incident);
signals:
    void stateChanged();
    void actionFailed(const QString &message);
private:
    void resetSession();
    bool canRequest() const;
    void replaceIncident(const QVariantMap &incident);
    AuthController *m_auth;
    QTimer m_poll;
    QPointer<QNetworkReply> m_pollReply;
    QPointer<QNetworkReply> m_actionReply;
    quint64 m_generation = 0;
    QVariantList m_incidents;
    QString m_currentCameraId, m_reviewingIncidentId, m_error, m_actionError, m_serviceStatus;
    bool m_available = false;
    bool m_canManage = false;
};
