#pragma once
#include <QObject>
#include <QPointer>
#include <QElapsedTimer>
#include <QJsonObject>
#include <QSet>
#include <QHash>
#include <QStringList>
#include <memory>
#include <functional>
#include <QDateTime>

class CameraAvailabilityJournal;
class QNetworkAccessManager;
class QNetworkReply;
class QTimer;

// The only database connection and network uploader live on this worker.
class CameraAvailabilityWorker : public QObject {
    Q_OBJECT
public:
    struct Options {
        QString provisioningFile;
        std::function<QDateTime()> nowUtc;
        bool timerEnabled = true;
        int batchDelayMs = 3500;
    };
    explicit CameraAvailabilityWorker(const QString &databasePath = {});
    CameraAvailabilityWorker(const QString &databasePath, const Options &options);
    ~CameraAvailabilityWorker() override;
    void checkDue() { tick(); }
public slots:
    void initialize();
    void configure(const QString &baseUrl, bool authenticated, const QString &role,
                   const QStringList &cameraScope, quint64 viewGeneration = 0);
    void observe(const QVariantMap &evidence);
    void synchronize();
    void loadHistory(const QString &cameraId = {}, const QString &fromUtc = {}, const QString &untilUtc = {});
    void stop();
signals:
    void stateReady(const QVariantMap &status);
    void historyReady(const QVariantList &rows, quint64 viewGeneration);
    void finished();
private:
    void tick();
    bool readProvisioning();
    void publish();
    void discover();
    void fetchChanges();
    void serviceNativeRefresh();
    void uploadNext();
    void request(const QString &kind, const QString &path, const QByteArray &body = {});
    void received(const QString &kind, QNetworkReply *reply, quint64 generation);
    void failNetwork(const QString &state, const QString &reason, QNetworkReply *reply = nullptr);
    void storageFailure();
    bool recordContinuity();
    bool authorizedForHistory(const QString &cameraId) const;
    void finishCycle();
    QDateTime now() const;
    Options m_options;
    QString m_path, m_requestedBase, m_base, m_stationToken, m_context;
    QString m_backendId, m_stationId, m_state = QStringLiteral("starting"), m_reason;
    QString m_role, m_historyCamera, m_historyFrom, m_historyUntil;
    QStringList m_cameraScope;
    QSet<QString> m_grantedCameras;
    QHash<QString, qint64> m_retiredPipelines;
    bool m_authenticated = false, m_stopping = false, m_cycle = false;
    bool m_bound = false, m_blocked = false, m_allowStation = false, m_nativeBacklog = false, m_contextReady = false;
    bool m_backendWasUnavailable = false, m_nativeRefreshPending = false;
    int m_maxEvents = 500, m_cycleBatches = 0, m_feedPages = 0, m_failures = 0;
    qint64 m_maxBytes = 1048576, m_uploadCount = 0, m_lostObservations = 0;
    quint64 m_generation = 0;
    quint64 m_viewGeneration = 0;
    std::unique_ptr<CameraAvailabilityJournal> m_journal;
    QNetworkAccessManager *m_nam = nullptr;
    QPointer<QNetworkReply> m_reply;
    QTimer *m_timer = nullptr;
    QElapsedTimer m_clock;
    QDateTime m_retryUntil;
    QDateTime m_continuityWall;
    qint64 m_continuityMono = -1, m_lastProvisioning = -60000, m_notBefore = 0;
    QJsonObject m_batch;
};
