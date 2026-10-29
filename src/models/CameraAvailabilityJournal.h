#pragma once

#include <QByteArray>
#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QSqlDatabase>
#include <QString>
#include <QStringList>

// Worker-thread-owned journal. Construct, use and destroy on one worker thread.
// No network, GUI, credentials, or memory-only fallback lives in this class.
class CameraAvailabilityJournal
{
public:
    static constexpr qint64 SyncIntervalMs = 180LL * 60 * 1000;
    static constexpr int SchemaVersion = 1;
    static constexpr int DefaultHistoryLimit = 200;
    static constexpr qint64 DefaultDatabaseByteLimit = 2LL * 1024 * 1024 * 1024;

    CameraAvailabilityJournal();
    ~CameraAvailabilityJournal();
    CameraAvailabilityJournal(const CameraAvailabilityJournal &) = delete;
    CameraAvailabilityJournal &operator=(const CameraAvailabilityJournal &) = delete;

    bool open(const QString &path, const QDateTime &nowUtc);
    void close();
    bool isOpen() const;
    QString error() const;

    // A non-secret fingerprint of configured destination + provisioned identity.
    // Changing it isolates old queues BEFORE capabilities are obtained. Never pass
    // a token/credential here. Only the first verified bind of this context may
    // associate its previously unbound observations with the authenticated scope.
    bool selectContext(const QString &contextKey, const QDateTime &nowUtc);
    bool bind(const QString &backendInstanceId, const QString &reporterStationId,
              const QDateTime &nowUtc);
    QString startRun(const QDateTime &nowUtc, qint64 monotonicMs = 0);
    bool endRun(const QDateTime &nowUtc, qint64 monotonicMs = -1);

    // Input uses protocol event fields. IDs, sequence, run and observation time
    // are assigned durably here. Optional private observer_key selects an
    // independent evidence source and is not sent to the backend. Repeated
    // same-state input is deduplicated unless force_event=true (also private).
    // Returns the committed event UUID; empty means duplicate or failure (error
    // differentiates them). Caller-supplied details are bounded and sanitized.
    QString observe(const QJsonObject &observation, const QDateTime &nowUtc,
                    qint64 monotonicMs = -1);

    // Returns an existing immutable batch before creating a new one. The exact
    // persisted compact payload MUST be sent, and reused unchanged after a lost
    // response. Empty object means no eligible events, an unbound scope or error.
    QJsonObject prepareBatch(int maxEvents, qint64 maxBytes, const QDateTime &nowUtc);
    QByteArray batchPayload() const;
    bool applyAck(const QJsonObject &ack, const QDateTime &nowUtc);
    // 413 may retire an envelope and rebuild smaller batches; event identities
    // and event JSON never change. Terminal poison events remain visible.
    bool abandonBatch(const QString &reason, const QDateTime &nowUtc);
    bool rejectEvents(const QStringList &eventIds, const QString &reason,
                      const QDateTime &nowUtc);

    // Native history is local-only; its IDs/cursor commit in one transaction.
    bool importNative(const QJsonArray &events, const QString &nextCursor,
                      const QDateTime &nowUtc);
    QString nativeCursor() const;

    bool recordAttempt(const QDateTime &nowUtc);
    bool recordFailure(const QString &reason, const QDateTime &retryAtUtc);
    bool setNextSyncDue(const QDateTime &nextUtc);
    bool syncDue(const QDateTime &nowUtc) const;
    QJsonObject status(const QDateTime &nowUtc) const;
    // Scope filtering happens in SQL BEFORE the row limit. Empty allowed IDs
    // with includeStationRows=false grants no history. The default preserves
    // unrestricted administrator/test callers.
    QJsonArray history(const QString &cameraId = {}, const QDateTime &fromUtc = {},
                       const QDateTime &untilUtc = {}, int limit = DefaultHistoryLimit,
                       const QStringList &allowedCameraIds = {}, bool includeStationRows = true) const;

    // v1 retains history indefinitely (zero defaults). Explicit positive local
    // policy may prune only acknowledged/native history; never pending/rejected
    // events, unresolved conditions or active retry envelopes.
    bool maintenance(const QDateTime &nowUtc, int retentionDays = 0,
                     qint64 acknowledgedRowLimit = 0,
                     qint64 databaseByteLimit = DefaultDatabaseByteLimit);

    static QJsonObject sanitizedDetails(const QJsonObject &details);

private:
    bool onOwnerThread() const;
    bool fail(const QString &code, const QString &storageState = QStringLiteral("degraded")) const;
    bool exec(const QString &sql) const;
    bool begin() const;
    bool commit() const;
    void rollback() const;
    bool reclaimWal(bool forceCheckpoint = false) const;
    bool reserveStorage(qint64 bytes) const;
    QString meta(const QString &key, const QString &fallback = {}) const;
    bool putMeta(const QString &key, const QString &value) const;
    bool loadContext(const QString &key);
    bool writeContext(const QString &column, const QString &value) const;
    QString appendEvent(QJsonObject event, const QString &conditionKey,
                        const QString &deliveryState, const QDateTime &nowUtc,
                        bool imported = false);
    QString conditionKey(const QJsonObject &event, const QString &observer) const;
    QString vantageKey(const QJsonObject &event) const;
    bool ensureSchema();
    bool validTime(const QDateTime &time) const;
    void clearError() const;
    void noteUnrecorded();
    QJsonObject historyRelationships(QJsonObject event, qint64 position, qint64 bound) const;

    QString m_connection;
    QSqlDatabase m_db;
    QString m_path;
    QString m_contextId;
    QString m_contextKey;
    QString m_backendId;
    QString m_stationId;
    QString m_producerId;
    QString m_runId;
    QByteArray m_batchPayload;
    quintptr m_ownerThread = 0;
    mutable QString m_error;
    mutable QString m_storageState = QStringLiteral("closed");
    mutable qint64 m_unrecordedCount = 0;
    mutable qint64 m_transactionBytes = 0;
    bool m_observationLossPending = false;
    qint64 m_capacityBytes = DefaultDatabaseByteLimit;
};
