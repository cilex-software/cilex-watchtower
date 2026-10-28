#pragma once
#include <QObject>
#include <QThread>
#include <QVariantList>
#include <QVariantMap>

class AuthController;
class CameraAvailabilityWorker;

class CameraAvailabilityService : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap status READ status NOTIFY stateChanged)
    Q_PROPERTY(QVariantList history READ history NOTIFY stateChanged)
    Q_PROPERTY(bool canSync READ canSync NOTIFY stateChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY stateChanged)
    Q_PROPERTY(bool canViewStationEvents READ canViewStationEvents NOTIFY stateChanged)
public:
    explicit CameraAvailabilityService(AuthController *auth, QObject *parent = nullptr);
    ~CameraAvailabilityService() override;
    QVariantMap status() const { return m_status; }
    QVariantList history() const { return m_history; }
    bool canSync() const;
    bool canViewStationEvents() const;
    bool busy() const { return m_status.value("busy").toBool(); }
    Q_INVOKABLE void syncNow();
    Q_INVOKABLE void refreshHistory(const QString &cameraId = {}, const QString &fromUtc = {}, const QString &untilUtc = {});
signals:
    void stateChanged();
    void configureRequested(const QString &baseUrl, bool authenticated, const QString &role,
                            const QStringList &cameraScope, quint64 viewGeneration);
    void syncRequested();
    void stopRequested();
    void historyRequested(const QString &cameraId, const QString &fromUtc, const QString &untilUtc);
private:
    void updateSession();
    AuthController *m_auth;
    QThread *m_thread = nullptr;
    CameraAvailabilityWorker *m_worker = nullptr;
    QVariantMap m_status;
    QVariantList m_history;
    quint64 m_viewGeneration = 0;
};
