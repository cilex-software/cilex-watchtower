#include "CameraAvailabilityJournal.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonValue>
#include <QRegularExpression>
#include <QSet>
#include <QSqlError>
#include <QSqlQuery>
#include <QThread>
#include <QUuid>
#include <QVariant>
#include <algorithm>
#include <limits>

namespace {
constexpr qint64 WalRetentionBytes = 1024 * 1024;
constexpr qint64 MinimumTransactionReserve = 16384;
QString uuid() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
QString instant(const QDateTime &dt) { return dt.toUTC().toString(Qt::ISODateWithMs); }
bool isUuid(const QString &s)
{
    static const QRegularExpression re(QStringLiteral(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"));
    return re.match(s).hasMatch();
}
QString sqlCode(const QSqlError &e)
{
    const auto code = e.nativeErrorCode().split(QLatin1Char(',')).value(0).toInt() & 0xff;
    if (code == 5 || code == 6) return QStringLiteral("sqlite_busy");
    if (code == 13) return QStringLiteral("sqlite_full");
    if (code == 11 || code == 26) return QStringLiteral("sqlite_corrupt");
    if (code == 8 || code == 14 || code == 23) return QStringLiteral("sqlite_permission");
    return QStringLiteral("sqlite_error");
}
QString boundedCode(const QString &text, int maximum = 64)
{
    static const QRegularExpression allowed(QStringLiteral("^[a-z][a-z0-9_]*$"));
    return !text.isEmpty() && text.size() <= maximum && allowed.match(text).hasMatch()
        ? text : QStringLiteral("unspecified");
}
bool awareTime(const QJsonValue &value)
{
    if (!value.isString()) return false;
    const QString text = value.toString();
    static const QRegularExpression offset(QStringLiteral("(?:[zZ]|[+-][0-9]{2}:[0-9]{2})$"));
    return text.contains(QLatin1Char('T')) && offset.match(text).hasMatch()
        && QDateTime::fromString(text, Qt::ISODateWithMs).isValid();
}
bool faultState(const QString &state)
{
    return state == QLatin1String("unavailable") || state == QLatin1String("degraded");
}
QByteArray compact(const QJsonObject &object) { return QJsonDocument(object).toJson(QJsonDocument::Compact); }
QString stateString(const QVariant &value) { return value.isNull() ? QString() : value.toString(); }

bool optionalInteger(const QJsonObject &object, const QString &key, qint64 minimum = 0)
{
    const auto value = object.value(key);
    return value.isUndefined() || value.isNull()
        || (value.isDouble() && value.toInteger(-1) >= minimum);
}

bool validNativeObject(const QJsonObject &event, const QString &backendId)
{
    static const QSet<QString> required {QStringLiteral("event_id"),QStringLiteral("local_seq"),QStringLiteral("run_id"),
        QStringLiteral("camera_id"),QStringLiteral("domain"),QStringLiteral("provenance"),QStringLiteral("state"),
        QStringLiteral("transition"),QStringLiteral("observed_at"),QStringLiteral("reason_code"),QStringLiteral("position"),
        QStringLiteral("origin"),QStringLiteral("backend_instance_id"),QStringLiteral("reporter_station_id"),
        QStringLiteral("producer_id"),QStringLiteral("site_id"),QStringLiteral("server_received_at"),
        QStringLiteral("clock_quality"),QStringLiteral("relationship_status"),QStringLiteral("relationship_authority"),
        QStringLiteral("upstream_reference_status"),QStringLiteral("condition_status"),QStringLiteral("condition_status_authority")};
    static const QSet<QString> optional {QStringLiteral("monotonic_ms"),QStringLiteral("duration_ms"),QStringLiteral("condition_id"),
        QStringLiteral("related_event_id"),QStringLiteral("details"),QStringLiteral("backend_observation")};
    for (const auto &key : required) if (!event.contains(key)) return false;
    for (auto it = event.begin(); it != event.end(); ++it)
        if (!required.contains(it.key()) && !optional.contains(it.key())) return false;
    for (const auto &name : {QStringLiteral("event_id"),QStringLiteral("run_id"),QStringLiteral("producer_id"),QStringLiteral("backend_instance_id")})
        if (!isUuid(event.value(name).toString())) return false;
    if (event.value(QStringLiteral("backend_instance_id")).toString() != backendId
        || event.value(QStringLiteral("origin")).toString() != QLatin1String("backend_native")
        || event.value(QStringLiteral("provenance")).toString() != QLatin1String("backend_native")
        || !event.value(QStringLiteral("reporter_station_id")).isNull()) return false;
    for (const auto &name : {QStringLiteral("condition_id"),QStringLiteral("related_event_id"),QStringLiteral("site_id")}) {
        const auto value = event.value(name);
        if (!value.isUndefined() && !value.isNull() && !isUuid(value.toString())) return false;
    }
    for (const auto &name : {QStringLiteral("observed_at"),QStringLiteral("server_received_at")})
        if (!awareTime(event.value(name)) || event.value(name).toString().size() > 40) return false;
    if (!event.value(QStringLiteral("local_seq")).isDouble() || event.value(QStringLiteral("local_seq")).toInteger(-1) < 1
        || !event.value(QStringLiteral("position")).isDouble() || event.value(QStringLiteral("position")).toInteger(-1) < 1
        || !optionalInteger(event,QStringLiteral("monotonic_ms")) || !optionalInteger(event,QStringLiteral("duration_ms"))) return false;
    static const QRegularExpression opaque(QStringLiteral("^[A-Za-z0-9._:-]{1,64}$"));
    const auto camera = event.value(QStringLiteral("camera_id"));
    if (!camera.isNull() && !opaque.match(camera.toString()).hasMatch()) return false;
    const QString reason = event.value(QStringLiteral("reason_code")).toString();
    if (reason != boundedCode(reason)) return false;
    static const QHash<QString,QSet<QString>> choices {
        {QStringLiteral("domain"), {QStringLiteral("backend_reachability"),QStringLiteral("recording_catalogue"),QStringLiteral("live_delivery"),QStringLiteral("snapshot_delivery"),QStringLiteral("backend_connectivity"),QStringLiteral("monitoring")}},
        {QStringLiteral("state"), {QStringLiteral("available"),QStringLiteral("unavailable"),QStringLiteral("degraded"),QStringLiteral("unknown"),QStringLiteral("not_monitored")}},
        {QStringLiteral("transition"), {QStringLiteral("initial"),QStringLiteral("failure"),QStringLiteral("recovery"),QStringLiteral("state_change"),QStringLiteral("monitoring_gap"),QStringLiteral("monitoring_resumed")}},
        {QStringLiteral("relationship_status"), {QStringLiteral("none"),QStringLiteral("pending_reference"),QStringLiteral("incompatible_reference"),QStringLiteral("reported_same_run_reference"),QStringLiteral("native_same_run_reference")}},
        {QStringLiteral("relationship_authority"), {QStringLiteral("client_reported"),QStringLiteral("backend_native")}},
        {QStringLiteral("upstream_reference_status"), {QStringLiteral("not_supplied"),QStringLiteral("resolved_native_reference"),QStringLiteral("unresolved_reference")}},
        {QStringLiteral("condition_status"), {QStringLiteral("not_applicable"),QStringLiteral("recovery_referenced"),QStringLiteral("interrupted_by_monitoring_gap"),QStringLiteral("open_unpaired_failure")}},
        {QStringLiteral("condition_status_authority"), {QStringLiteral("client_reported"),QStringLiteral("backend_native")}}
    };
    for (auto it = choices.begin(); it != choices.end(); ++it)
        if (!it.value().contains(event.value(it.key()).toString())) return false;
    const auto detailsValue = event.value(QStringLiteral("details"));
    if (!detailsValue.isUndefined()) {
        if (!detailsValue.isObject()) return false;
        const auto details = detailsValue.toObject();
        const auto sanitized = CameraAvailabilityJournal::sanitizedDetails(details);
        static const QSet<QString> detailNames {QStringLiteral("stream_variant"),QStringLiteral("transport"),QStringLiteral("observer_scope"),
            QStringLiteral("pipeline_id"),QStringLiteral("consecutive_failures"),QStringLiteral("catalogue_age_ms"),QStringLiteral("threshold_ms"),QStringLiteral("last_positive_at")};
        for (auto it = details.begin(); it != details.end(); ++it)
            if (!detailNames.contains(it.key()) || (!it.value().isNull() && sanitized.value(it.key()) != it.value())) return false;
    }
    const auto backendValue = event.value(QStringLiteral("backend_observation"));
    if (!backendValue.isUndefined() && !backendValue.isNull()) {
        if (!backendValue.isObject()) return false;
        const auto observed = backendValue.toObject();
        if (!awareTime(observed.value(QStringLiteral("received_locally_at")))) return false;
        const QSet<QString> dateNames {QStringLiteral("status_since"),QStringLiteral("recording_since"),QStringLiteral("last_seen"),
            QStringLiteral("last_segment_at"),QStringLiteral("received_locally_at")};
        const QSet<QString> statuses {QStringLiteral("online"),QStringLiteral("offline"),QStringLiteral("maintenance"),QStringLiteral("error"),QStringLiteral("unknown")};
        const QSet<QString> recording {QStringLiteral("recording"),QStringLiteral("stalled"),QStringLiteral("armed"),QStringLiteral("offline"),QStringLiteral("disabled"),QStringLiteral("unknown")};
        for (auto it = observed.begin(); it != observed.end(); ++it) {
            if (dateNames.contains(it.key())) {
                if (!it.value().isNull() && (!awareTime(it.value()) || it.value().toString().size() > 40)) return false;
            } else if (it.key() == QLatin1String("status")) {
                if (!it.value().isNull() && !statuses.contains(it.value().toString())) return false;
            } else if (it.key() == QLatin1String("recording_state")) {
                if (!it.value().isNull() && !recording.contains(it.value().toString())) return false;
            } else if (it.key() == QLatin1String("upstream_event_id")) {
                if (!it.value().isNull() && !isUuid(it.value().toString())) return false;
            } else return false;
        }
    }
    const auto qualityValue = event.value(QStringLiteral("clock_quality"));
    if (!qualityValue.isObject()) return false;
    const auto quality = qualityValue.toObject();
    if (quality.value(QStringLiteral("authority")).toString() != QLatin1String("backend_observed")
        || !quality.value(QStringLiteral("flags")).isArray()) return false;
    static const QSet<QString> flags {QStringLiteral("future_observation"),QStringLiteral("delayed_delivery"),
        QStringLiteral("producer_sequence_out_of_order"),QStringLiteral("client_clock_out_of_order")};
    const auto qualityFlags = quality.value(QStringLiteral("flags")).toArray();
    if (qualityFlags.size() > 4) return false;
    for (const auto &flag : qualityFlags) if (!flags.contains(flag.toString())) return false;
    for (auto it = quality.begin(); it != quality.end(); ++it) {
        if (it.key() == QLatin1String("authority") || it.key() == QLatin1String("flags")) continue;
        if (it.key() == QLatin1String("future_tolerance_s") && it.value().toInteger(-1) == 300) continue;
        if (it.key() == QLatin1String("delivery_interval_s") && it.value().toInteger(-1) == 10800) continue;
        return false;
    }
    return true;
}

QJsonObject immutableNative(QJsonObject event)
{
    for (const auto &name : {QStringLiteral("clock_quality"),QStringLiteral("relationship_status"),
        QStringLiteral("relationship_authority"),QStringLiteral("upstream_reference_status"),
        QStringLiteral("condition_status"),QStringLiteral("condition_status_authority")}) event.remove(name);
    return event;
}
}

CameraAvailabilityJournal::CameraAvailabilityJournal()
    : m_connection(QStringLiteral("availability-%1").arg(uuid())),
      m_ownerThread(reinterpret_cast<quintptr>(QThread::currentThreadId()))
{
}

CameraAvailabilityJournal::~CameraAvailabilityJournal() { close(); }

bool CameraAvailabilityJournal::onOwnerThread() const
{
    return reinterpret_cast<quintptr>(QThread::currentThreadId()) == m_ownerThread;
}

bool CameraAvailabilityJournal::fail(const QString &code, const QString &state) const
{
    m_error = code;
    m_storageState = state;
    return false;
}

void CameraAvailabilityJournal::clearError() const
{
    m_error.clear();
    if (m_db.isOpen()) m_storageState = QStringLiteral("healthy");
}

QString CameraAvailabilityJournal::error() const { return m_error; }
bool CameraAvailabilityJournal::isOpen() const { return onOwnerThread() && m_db.isOpen(); }

bool CameraAvailabilityJournal::exec(const QString &sql) const
{
    QSqlQuery query(m_db);
    if (!query.exec(sql)) return fail(sqlCode(query.lastError()));
    return true;
}
bool CameraAvailabilityJournal::begin() const
{
    m_transactionBytes = 0;
    // Only the journal worker calls this, before BEGIN and before its own read
    // cursors exist. A retained WAL tail is reusable storage, not more history.
    if (!reclaimWal()) return false;
    return exec(QStringLiteral("BEGIN IMMEDIATE"));
}
bool CameraAvailabilityJournal::commit() const
{
    if (m_unrecordedCount > 0
        && !putMeta(QStringLiteral("unrecorded_count"), QString::number(m_unrecordedCount))) {
        rollback(); return false;
    }
    if (!exec(QStringLiteral("COMMIT"))) { rollback(); return false; }
    m_transactionBytes = 0;
    return true;
}
void CameraAvailabilityJournal::rollback() const
{
    QSqlQuery query(m_db);
    query.exec(QStringLiteral("ROLLBACK"));
    m_transactionBytes = 0;
}

bool CameraAvailabilityJournal::reclaimWal(bool forceCheckpoint) const
{
    const auto walBytes = QFileInfo(m_path + QStringLiteral("-wal")).size();
    const auto bytes = QFileInfo(m_path).size() + walBytes;
    const bool pressure = walBytes > WalRetentionBytes
        || bytes + MinimumTransactionReserve > m_capacityBytes;
    if (!forceCheckpoint && !pressure) return true;

    const auto checkpoint = [this](const QString &mode, bool *complete) {
        QSqlQuery query(m_db);
        if (!query.exec(QStringLiteral("PRAGMA wal_checkpoint(%1)").arg(mode))) {
            const auto code = sqlCode(query.lastError());
            query.finish();
            // A reader may defer reclamation. The subsequent physical capacity
            // fence still refuses growth; no event/cursor has changed here.
            return code == QLatin1String("sqlite_busy") || fail(code);
        }
        if (!query.next()) { query.finish(); return fail(QStringLiteral("sqlite_error")); }
        if (complete) *complete = query.value(0).toInt() == 0
            && query.value(1).toLongLong() >= 0
            && query.value(1).toLongLong() == query.value(2).toLongLong();
        query.finish();
        return true;
    };
    bool complete = false;
    if (!checkpoint(QStringLiteral("PASSIVE"), &complete)) return false;
    if (!pressure || !complete) return true;

    // Do not wait for another reader to release the WAL. SQLite performs the
    // checkpoint on this worker, never on the GUI thread. Restore the normal
    // short write-lock timeout on every path after the temporary override.
    if (!exec(QStringLiteral("PRAGMA busy_timeout=0"))) return false;
    const bool reclaimed = checkpoint(QStringLiteral("TRUNCATE"), nullptr);
    const bool restored = exec(QStringLiteral("PRAGMA busy_timeout=250"));
    return reclaimed && restored;
}

bool CameraAvailabilityJournal::reserveStorage(qint64 bytes) const
{
    const qint64 currentBytes = QFileInfo(m_path).size() + QFileInfo(m_path + QStringLiteral("-wal")).size();
    if (currentBytes + m_transactionBytes + bytes > m_capacityBytes)
        return fail(QStringLiteral("storage_capacity_exceeded"), QStringLiteral("capacity_exceeded"));
    m_transactionBytes += bytes;
    return true;
}

void CameraAvailabilityJournal::noteUnrecorded()
{
    ++m_unrecordedCount;
    m_observationLossPending = true;
}

bool CameraAvailabilityJournal::validTime(const QDateTime &time) const
{
    return time.isValid() && time.date().year() >= 1970 && time.date().year() <= 9999;
}

bool CameraAvailabilityJournal::open(const QString &path, const QDateTime &nowUtc)
{
    if (!onOwnerThread()) return fail(QStringLiteral("wrong_thread"));
    if (!validTime(nowUtc)) return fail(QStringLiteral("invalid_clock"));
    close();
    m_unrecordedCount = 0;
    m_observationLossPending = false;
    const QFileInfo info(path);
    if (path.isEmpty() || info.isSymLink()) return fail(QStringLiteral("unsafe_database_path"));
    QDir parent = info.absoluteDir();
    if (!parent.exists() && !parent.mkpath(QStringLiteral(".")))
        return fail(QStringLiteral("database_directory_unavailable"));
    m_path = info.absoluteFilePath();
#ifndef Q_OS_WIN
    if (!QFileInfo::exists(m_path)) {
        QFile initial(m_path);
        if (!initial.open(QIODevice::WriteOnly | QIODevice::NewOnly))
            return fail(QStringLiteral("sqlite_permission"));
        if (!initial.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner))
            return fail(QStringLiteral("sqlite_permission"));
        initial.close();
    }
    if (!QFile::setPermissions(m_path, QFileDevice::ReadOwner | QFileDevice::WriteOwner))
        return fail(QStringLiteral("sqlite_permission"));
#endif
    m_db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), m_connection);
    m_db.setDatabaseName(m_path);
    m_db.setConnectOptions(QStringLiteral("QSQLITE_BUSY_TIMEOUT=250"));
    if (!m_db.open()) return fail(sqlCode(m_db.lastError()));
    const auto abortOpen = [this]() {
        const QString code = m_error;
        const QString state = m_storageState;
        close();
        return fail(code.isEmpty() ? QStringLiteral("database_unavailable") : code, state);
    };
    // SQL text, event details and credentials never appear in diagnostics.
    if (!exec(QStringLiteral("PRAGMA foreign_keys=ON"))
        || !exec(QStringLiteral("PRAGMA journal_mode=WAL"))
        || !exec(QStringLiteral("PRAGMA synchronous=FULL"))
        || !exec(QStringLiteral("PRAGMA wal_autocheckpoint=256"))
        || !exec(QStringLiteral("PRAGMA journal_size_limit=1048576"))
        || !ensureSchema()) return abortOpen();
    QSqlQuery check(m_db);
    if (!check.exec(QStringLiteral("PRAGMA quick_check(1)")) || !check.next()
        || check.value(0).toString() != QLatin1String("ok"))
    {
        fail(QStringLiteral("sqlite_corrupt"));
        check.finish();
        return abortOpen();
    }
    check.finish();
#ifndef Q_OS_WIN
    // The application owns the dedicated directory; do not chmod shared parents.
    QFile::setPermissions(m_path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    QFile::setPermissions(m_path + QStringLiteral("-wal"), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    QFile::setPermissions(m_path + QStringLiteral("-shm"), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
#endif
    clearError();
    m_unrecordedCount = meta(QStringLiteral("unrecorded_count"), QStringLiteral("0")).toLongLong();
    if (!selectContext(QStringLiteral("unconfigured"), nowUtc)) return abortOpen();
    return true;
}

void CameraAvailabilityJournal::close()
{
    if (!onOwnerThread()) { fail(QStringLiteral("wrong_thread")); return; }
    if (m_db.isValid()) {
        m_db.close();
        m_db = QSqlDatabase();
        QSqlDatabase::removeDatabase(m_connection);
    }
    m_contextId.clear(); m_contextKey.clear(); m_backendId.clear(); m_stationId.clear();
    m_producerId.clear(); m_runId.clear(); m_batchPayload.clear();
    m_storageState = QStringLiteral("closed");
}

bool CameraAvailabilityJournal::ensureSchema()
{
    QSqlQuery version(m_db);
    if (!version.exec(QStringLiteral("PRAGMA user_version")) || !version.next())
        return fail(sqlCode(version.lastError()));
    const int existing = version.value(0).toInt();
    version.finish();
    if (existing > SchemaVersion || existing < 0) return fail(QStringLiteral("unsupported_schema"));
    if (existing == SchemaVersion) return true;
    if (!begin()) return false;
    const QStringList statements {
        QStringLiteral("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)"),
        QStringLiteral("INSERT INTO metadata VALUES ('last_seq','0')"),
        QStringLiteral("CREATE TABLE contexts (id TEXT PRIMARY KEY, context_key TEXT NOT NULL UNIQUE, "
                       "backend_id TEXT, station_id TEXT, producer_id TEXT NOT NULL, native_cursor TEXT NOT NULL DEFAULT '', "
                       "last_attempt_at TEXT, last_success_at TEXT, next_sync_at TEXT NOT NULL, sync_error TEXT NOT NULL DEFAULT '', "
                       "active_batch_id TEXT, created_at TEXT NOT NULL)"),
        QStringLiteral("CREATE TABLE runs (run_id TEXT PRIMARY KEY, context_id TEXT NOT NULL REFERENCES contexts(id), "
                       "started_at TEXT NOT NULL, ended_at TEXT)"),
        QStringLiteral("CREATE TABLE events (event_id TEXT NOT NULL, context_id TEXT NOT NULL REFERENCES contexts(id), "
                       "local_seq INTEGER NOT NULL UNIQUE CHECK(local_seq>0), payload BLOB NOT NULL, observed_at TEXT NOT NULL, "
                       "camera_id TEXT, domain TEXT NOT NULL, provenance TEXT NOT NULL, state TEXT NOT NULL, transition TEXT NOT NULL, "
                       "condition_key TEXT NOT NULL DEFAULT '', condition_id TEXT, run_id TEXT NOT NULL, "
                       "delivery TEXT NOT NULL CHECK(delivery IN ('pending','acknowledged','rejected','native')), "
                       "acknowledged_at TEXT, rejection_reason TEXT, native_key TEXT, PRIMARY KEY(context_id,event_id))"),
        QStringLiteral("CREATE INDEX events_pending ON events(context_id,delivery,local_seq)"),
        QStringLiteral("CREATE INDEX events_history ON events(context_id,observed_at,local_seq)"),
        QStringLiteral("CREATE INDEX events_relationship ON events(context_id,condition_id,transition,local_seq)"),
        QStringLiteral("CREATE INDEX events_gaps ON events(context_id,transition,local_seq)"),
        QStringLiteral("CREATE UNIQUE INDEX events_native ON events(context_id,native_key) WHERE native_key IS NOT NULL"),
        QStringLiteral("CREATE TABLE conditions (context_id TEXT NOT NULL REFERENCES contexts(id), condition_key TEXT NOT NULL, vantage_key TEXT NOT NULL, "
                       "observer_scope TEXT NOT NULL, "
                       "state TEXT NOT NULL, condition_id TEXT, last_event_id TEXT NOT NULL, run_id TEXT NOT NULL, "
                       "observed_at TEXT NOT NULL, monotonic_ms INTEGER, active INTEGER NOT NULL DEFAULT 0, "
                       "gap_pending INTEGER NOT NULL DEFAULT 0, failure_event_id TEXT, failure_monotonic_ms INTEGER, "
                       "PRIMARY KEY(context_id,condition_key))"),
        QStringLiteral("CREATE INDEX conditions_vantage ON conditions(context_id,vantage_key)"),
        QStringLiteral("CREATE TABLE batches (batch_id TEXT PRIMARY KEY, context_id TEXT NOT NULL REFERENCES contexts(id), "
                       "payload BLOB NOT NULL, state TEXT NOT NULL, created_at TEXT NOT NULL)"),
        QStringLiteral("CREATE TABLE batch_events (batch_id TEXT NOT NULL REFERENCES batches(batch_id) ON DELETE CASCADE, "
                       "context_id TEXT NOT NULL REFERENCES contexts(id), event_id TEXT NOT NULL, "
                       "FOREIGN KEY(context_id,event_id) REFERENCES events(context_id,event_id), PRIMARY KEY(batch_id,event_id))"),
        QStringLiteral("PRAGMA user_version=1")
    };
    for (const auto &statement : statements) {
        if (!exec(statement)) { rollback(); return false; }
    }
    return commit();
}

QString CameraAvailabilityJournal::meta(const QString &key, const QString &fallback) const
{
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("SELECT value FROM metadata WHERE key=?"));
    query.addBindValue(key);
    if (!query.exec()) { fail(sqlCode(query.lastError())); return fallback; }
    return query.next() ? query.value(0).toString() : fallback;
}

bool CameraAvailabilityJournal::putMeta(const QString &key, const QString &value) const
{
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"));
    query.addBindValue(key); query.addBindValue(value);
    return query.exec() || fail(sqlCode(query.lastError()));
}

bool CameraAvailabilityJournal::loadContext(const QString &key)
{
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("SELECT id,backend_id,station_id,producer_id FROM contexts WHERE context_key=?"));
    query.addBindValue(key);
    if (!query.exec()) return fail(sqlCode(query.lastError()));
    if (!query.next()) return false;
    const QString id = query.value(0).toString();
    if (id != m_contextId) { m_runId.clear(); m_batchPayload.clear(); }
    m_contextId = id; m_contextKey = key;
    m_backendId = stateString(query.value(1)); m_stationId = stateString(query.value(2));
    m_producerId = query.value(3).toString();
    return true;
}

bool CameraAvailabilityJournal::selectContext(const QString &contextKey, const QDateTime &nowUtc)
{
    if (!isOpen()) return fail(QStringLiteral("database_unavailable"));
    if (contextKey.isEmpty() || contextKey.size() > 256 || !validTime(nowUtc))
        return fail(QStringLiteral("invalid_context"), QStringLiteral("healthy"));
    clearError();
    if (loadContext(contextKey)) return true;
    if (!m_error.isEmpty()) return false;
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("INSERT INTO contexts(id,context_key,producer_id,next_sync_at,created_at) VALUES (?,?,?,?,?)"));
    query.addBindValue(uuid()); query.addBindValue(contextKey); query.addBindValue(uuid());
    query.addBindValue(instant(nowUtc.addMSecs(SyncIntervalMs))); query.addBindValue(instant(nowUtc));
    if (!query.exec()) return fail(sqlCode(query.lastError()));
    return loadContext(contextKey);
}

bool CameraAvailabilityJournal::writeContext(const QString &column, const QString &value) const
{
    static const QSet<QString> allowed { QStringLiteral("native_cursor"), QStringLiteral("last_attempt_at"),
        QStringLiteral("last_success_at"), QStringLiteral("next_sync_at"), QStringLiteral("sync_error"),
        QStringLiteral("active_batch_id") };
    if (!allowed.contains(column)) return fail(QStringLiteral("invalid_context_field"));
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("UPDATE contexts SET %1=? WHERE id=?").arg(column));
    query.addBindValue(value.isNull() ? QStringLiteral("") : value); query.addBindValue(m_contextId);
    return query.exec() || fail(sqlCode(query.lastError()));
}

bool CameraAvailabilityJournal::bind(const QString &backendInstanceId, const QString &reporterStationId,
                                      const QDateTime &nowUtc)
{
    if (!isOpen() || m_contextId.isEmpty()) return fail(QStringLiteral("database_unavailable"));
    if (!isUuid(backendInstanceId) || !isUuid(reporterStationId) || !validTime(nowUtc))
        return fail(QStringLiteral("invalid_identity"), QStringLiteral("healthy"));
    if (!m_backendId.isEmpty() && (m_backendId != backendInstanceId || m_stationId != reporterStationId))
        return fail(QStringLiteral("identity_conflict"), QStringLiteral("healthy"));
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("UPDATE contexts SET backend_id=?,station_id=? WHERE id=?"));
    query.addBindValue(backendInstanceId); query.addBindValue(reporterStationId); query.addBindValue(m_contextId);
    if (!query.exec()) return fail(sqlCode(query.lastError()));
    m_backendId = backendInstanceId; m_stationId = reporterStationId;
    clearError();
    return true;
}

QString CameraAvailabilityJournal::appendEvent(QJsonObject event, const QString &key,
                                               const QString &delivery, const QDateTime &nowUtc, bool imported)
{
    bool sequenceOk = false;
    const qint64 oldSeq = meta(QStringLiteral("last_seq")).toLongLong(&sequenceOk);
    if (!sequenceOk || oldSeq >= 9007199254740990LL) { fail(QStringLiteral("sequence_exhausted")); return {}; }
    const qint64 sequence = oldSeq + 1;
    const QString eventId = imported ? event.value(QStringLiteral("event_id")).toString() : uuid();
    event.insert(QStringLiteral("event_id"), eventId);
    if (!imported) {
        event.insert(QStringLiteral("local_seq"), sequence);
        event.insert(QStringLiteral("run_id"), m_runId);
        event.insert(QStringLiteral("observed_at"), instant(nowUtc));
    }
    // Every insertion path (native pages and run boundaries included) shares
    // one capacity fence. Reserve transaction growth because WAL pages may not
    // reach the filesystem until commit. Refusal never advances a native cursor.
    const QByteArray payload = compact(event);
    const qint64 reserve = std::max<qint64>(MinimumTransactionReserve, payload.size() * 2 + 8192);
    if (!reserveStorage(reserve)) return {};
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("INSERT INTO events(event_id,context_id,local_seq,payload,observed_at,camera_id,domain,"
                                 "provenance,state,transition,condition_key,condition_id,run_id,delivery,native_key) "
                                 "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"));
    query.addBindValue(eventId); query.addBindValue(m_contextId); query.addBindValue(sequence);
    query.addBindValue(payload);
    const auto eventTime = QDateTime::fromString(event.value(QStringLiteral("observed_at")).toString(), Qt::ISODateWithMs);
    query.addBindValue(instant(eventTime.isValid() ? eventTime : nowUtc));
    query.addBindValue(event.value(QStringLiteral("camera_id")).isNull()
                           ? QVariant(QMetaType::fromType<QString>()) : event.value(QStringLiteral("camera_id")).toVariant());
    query.addBindValue(event.value(QStringLiteral("domain")).toString());
    query.addBindValue(event.value(QStringLiteral("provenance")).toString());
    query.addBindValue(event.value(QStringLiteral("state")).toString());
    query.addBindValue(event.value(QStringLiteral("transition")).toString());
    query.addBindValue(key.isNull() ? QStringLiteral("") : key);
    query.addBindValue(event.value(QStringLiteral("condition_id")).toVariant());
    query.addBindValue(event.value(QStringLiteral("run_id")).toString(m_runId));
    query.addBindValue(delivery);
    query.addBindValue(imported ? QVariant(eventId) : QVariant(QMetaType::fromType<QString>()));
    if (!query.exec()) { fail(sqlCode(query.lastError())); return {}; }
    if (!putMeta(QStringLiteral("last_seq"), QString::number(sequence))) return {};
    return eventId;
}

QString CameraAvailabilityJournal::startRun(const QDateTime &nowUtc, qint64 monotonicMs)
{
    if (!isOpen() || !validTime(nowUtc)) { fail(QStringLiteral("database_unavailable")); return {}; }
    if (!m_runId.isEmpty()) return m_runId;
    clearError();
    if (!begin()) return {};
    m_runId = uuid();
    QSqlQuery run(m_db);
    run.prepare(QStringLiteral("INSERT INTO runs(run_id,context_id,started_at) VALUES (?,?,?)"));
    run.addBindValue(m_runId); run.addBindValue(m_contextId); run.addBindValue(instant(nowUtc));
    if (!run.exec()) { fail(sqlCode(run.lastError())); rollback(); m_runId.clear(); return {}; }

    // A restart is an observation boundary, never evidence of continuous outage
    // or recovery. Preserve each source's last known state in the prior event.
    struct Gap { QString key; QString previousId; QJsonObject event; };
    for (;;) {
        QSqlQuery prior(m_db);
        prior.prepare(QStringLiteral("SELECT c.condition_key,c.last_event_id,e.payload FROM conditions c "
                                     "JOIN events e ON e.event_id=c.last_event_id AND e.context_id=c.context_id "
                                     "WHERE c.context_id=? AND c.gap_pending=0 LIMIT 500"));
        prior.addBindValue(m_contextId);
        if (!prior.exec()) { fail(sqlCode(prior.lastError())); rollback(); m_runId.clear(); return {}; }
        QList<Gap> gaps;
        while (prior.next()) gaps.append({prior.value(0).toString(), prior.value(1).toString(),
            QJsonDocument::fromJson(prior.value(2).toByteArray()).object()});
        prior.finish();
        if (gaps.isEmpty()) break;
        for (const auto &gap : gaps) {
            QJsonObject event = gap.event;
            event.remove(QStringLiteral("duration_ms")); event.remove(QStringLiteral("backend_observation"));
            event.remove(QStringLiteral("condition_id"));
            event.insert(QStringLiteral("domain"), QStringLiteral("monitoring"));
            event.insert(QStringLiteral("provenance"), QStringLiteral("client_observed"));
            event.insert(QStringLiteral("state"), QStringLiteral("unknown"));
            event.insert(QStringLiteral("transition"), QStringLiteral("monitoring_gap"));
            event.insert(QStringLiteral("related_event_id"), gap.previousId);
            event.insert(QStringLiteral("reason_code"), QStringLiteral("monitoring_restarted"));
            if (monotonicMs >= 0) event.insert(QStringLiteral("monotonic_ms"), monotonicMs);
            else event.remove(QStringLiteral("monotonic_ms"));
            const auto id = appendEvent(event, gap.key, QStringLiteral("pending"), nowUtc);
            if (id.isEmpty()) { rollback(); m_runId.clear(); return {}; }
            QSqlQuery update(m_db);
            update.prepare(QStringLiteral("UPDATE conditions SET state='unknown',last_event_id=?,run_id=?,observed_at=?,"
                                          "monotonic_ms=NULL,gap_pending=1,failure_event_id=NULL,failure_monotonic_ms=NULL "
                                          "WHERE context_id=? AND condition_key=?"));
            update.addBindValue(id); update.addBindValue(m_runId); update.addBindValue(instant(nowUtc));
            update.addBindValue(m_contextId); update.addBindValue(gap.key);
            if (!update.exec()) { fail(sqlCode(update.lastError())); rollback(); m_runId.clear(); return {}; }
        }
    }
    QJsonObject start { {QStringLiteral("camera_id"), QJsonValue::Null},
        {QStringLiteral("domain"), QStringLiteral("monitoring")},
        {QStringLiteral("provenance"), QStringLiteral("client_observed")},
        {QStringLiteral("state"), QStringLiteral("available")},
        {QStringLiteral("transition"), QStringLiteral("monitoring_resumed")},
        {QStringLiteral("reason_code"), QStringLiteral("process_started")} };
    if (monotonicMs >= 0) start.insert(QStringLiteral("monotonic_ms"), monotonicMs);
    if (appendEvent(start, {}, QStringLiteral("pending"), nowUtc).isEmpty() || !commit()) {
        rollback(); m_runId.clear(); return {};
    }
    clearError();
    return m_runId;
}

bool CameraAvailabilityJournal::endRun(const QDateTime &nowUtc, qint64 monotonicMs)
{
    if (!isOpen() || m_runId.isEmpty() || !validTime(nowUtc)) return false;
    if (!begin()) return false;
    QJsonObject event { {QStringLiteral("camera_id"), QJsonValue::Null},
        {QStringLiteral("domain"), QStringLiteral("monitoring")},
        {QStringLiteral("provenance"), QStringLiteral("client_observed")},
        {QStringLiteral("state"), QStringLiteral("not_monitored")},
        {QStringLiteral("transition"), QStringLiteral("monitoring_gap")},
        {QStringLiteral("reason_code"), QStringLiteral("process_stopped")} };
    if (monotonicMs >= 0) event.insert(QStringLiteral("monotonic_ms"), monotonicMs);
    if (appendEvent(event, {}, QStringLiteral("pending"), nowUtc).isEmpty()) { rollback(); return false; }
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("UPDATE runs SET ended_at=? WHERE run_id=?"));
    query.addBindValue(instant(nowUtc)); query.addBindValue(m_runId);
    if (!query.exec()) { fail(sqlCode(query.lastError())); rollback(); return false; }
    if (!commit()) return false;
    m_runId.clear(); clearError();
    return true;
}

QJsonObject CameraAvailabilityJournal::sanitizedDetails(const QJsonObject &details)
{
    // Protocol whitelist: no URLs, free-form dumps, arbitrary keys or nested
    // payloads can enter a journal/export/upload through this boundary.
    static const QSet<QString> names { QStringLiteral("stream_variant"), QStringLiteral("transport"),
        QStringLiteral("observer_scope"), QStringLiteral("pipeline_id"), QStringLiteral("consecutive_failures"),
        QStringLiteral("catalogue_age_ms"), QStringLiteral("threshold_ms"), QStringLiteral("last_positive_at") };
    QJsonObject clean;
    static const QRegularExpression opaque(QStringLiteral("^[A-Za-z0-9._:-]{1,64}$"));
    static const QHash<QString,QSet<QString>> enums {
        {QStringLiteral("stream_variant"), {QStringLiteral("main"),QStringLiteral("sub"),QStringLiteral("unknown")}},
        {QStringLiteral("transport"), {QStringLiteral("rtsp"),QStringLiteral("http"),QStringLiteral("webrtc"),QStringLiteral("hls"),QStringLiteral("tcp"),QStringLiteral("unknown")}},
        {QStringLiteral("observer_scope"), {QStringLiteral("backend"),QStringLiteral("station"),QStringLiteral("pipeline"),QStringLiteral("snapshot_request"),QStringLiteral("monitoring")}}
    };
    for (auto it = details.begin(); it != details.end(); ++it) {
        if (!names.contains(it.key())) continue;
        if (it.value().isDouble()) {
            const double number = it.value().toDouble();
            const bool numericField = it.key() == QLatin1String("consecutive_failures")
                || it.key() == QLatin1String("catalogue_age_ms") || it.key() == QLatin1String("threshold_ms");
            const double maximum = it.key() == QLatin1String("consecutive_failures") ? 10000.0 : 9007199254740991.0;
            if (numericField && number >= 0 && number <= maximum && number == static_cast<qint64>(number))
                clean.insert(it.key(), it.value());
        } else if (it.value().isString()) {
            const QString value = it.value().toString();
            if ((enums.contains(it.key()) && enums.value(it.key()).contains(value))
                || (it.key() == QLatin1String("pipeline_id") && opaque.match(value).hasMatch())
                || (it.key() == QLatin1String("last_positive_at") && value.size() <= 40 && awareTime(value)))
                clean.insert(it.key(), value);
        }
    }
    return clean;
}

QString CameraAvailabilityJournal::conditionKey(const QJsonObject &event, const QString &observer) const
{
    const auto details = event.value(QStringLiteral("details")).toObject();
    QJsonArray parts { event.value(QStringLiteral("camera_id")), event.value(QStringLiteral("domain")),
        event.value(QStringLiteral("provenance")), observer,
        details.value(QStringLiteral("observer_scope")), details.value(QStringLiteral("pipeline_id")),
        details.value(QStringLiteral("stream_variant")), details.value(QStringLiteral("transport")) };
    return QString::fromLatin1(QCryptographicHash::hash(QJsonDocument(parts).toJson(QJsonDocument::Compact),
                                                       QCryptographicHash::Sha256).toHex());
}

QString CameraAvailabilityJournal::vantageKey(const QJsonObject &event) const
{
    const auto details = event.value(QStringLiteral("details")).toObject();
    const QJsonArray parts {event.value(QStringLiteral("camera_id")),details.value(QStringLiteral("observer_scope")),
        details.value(QStringLiteral("pipeline_id")),details.value(QStringLiteral("stream_variant")),details.value(QStringLiteral("transport"))};
    return QString::fromLatin1(QCryptographicHash::hash(QJsonDocument(parts).toJson(QJsonDocument::Compact),
                                                       QCryptographicHash::Sha256).toHex());
}

QString CameraAvailabilityJournal::observe(const QJsonObject &observation, const QDateTime &nowUtc, qint64 monotonicMs)
{
    if (!isOpen() || m_runId.isEmpty()) { noteUnrecorded(); fail(QStringLiteral("monitoring_run_unavailable")); return {}; }
    static const QSet<QString> domains { QStringLiteral("backend_reachability"), QStringLiteral("recording_catalogue"),
        QStringLiteral("live_delivery"), QStringLiteral("snapshot_delivery"), QStringLiteral("backend_connectivity"), QStringLiteral("monitoring") };
    static const QSet<QString> states { QStringLiteral("available"), QStringLiteral("unavailable"), QStringLiteral("degraded"),
        QStringLiteral("unknown"), QStringLiteral("not_monitored") };
    static const QSet<QString> provenance { QStringLiteral("client_observed"), QStringLiteral("backend_reported_by_client") };
    static const QSet<QString> transitions { QStringLiteral("initial"), QStringLiteral("failure"), QStringLiteral("recovery"),
        QStringLiteral("state_change"), QStringLiteral("monitoring_gap"), QStringLiteral("monitoring_resumed") };
    clearError();
    const QString domain = observation.value(QStringLiteral("domain")).toString();
    const QString state = observation.value(QStringLiteral("state")).toString();
    const QString source = observation.value(QStringLiteral("provenance")).toString(QStringLiteral("client_observed"));
    const QString camera = observation.value(QStringLiteral("camera_id")).toString();
    static const QRegularExpression cameraPattern(QStringLiteral("^[A-Za-z0-9._:-]{1,64}$"));
    if (!validTime(nowUtc) || !domains.contains(domain) || !states.contains(state) || !provenance.contains(source)
        || (!camera.isEmpty() && !cameraPattern.match(camera).hasMatch())) {
        noteUnrecorded(); fail(QStringLiteral("invalid_observation"), QStringLiteral("healthy")); return {};
    }
    if (camera.isEmpty() && domain != QLatin1String("backend_connectivity") && domain != QLatin1String("monitoring")) {
        noteUnrecorded(); fail(QStringLiteral("camera_identity_required"), QStringLiteral("healthy")); return {};
    }
    const bool reportedDomain = domain == QLatin1String("backend_reachability") || domain == QLatin1String("recording_catalogue");
    if ((reportedDomain && source != QLatin1String("backend_reported_by_client"))
        || (!reportedDomain && source != QLatin1String("client_observed"))
        || (domain == QLatin1String("backend_connectivity") && !camera.isEmpty())) {
        noteUnrecorded(); fail(QStringLiteral("invalid_domain_provenance"), QStringLiteral("healthy")); return {};
    }
    QJsonObject event {
        {QStringLiteral("camera_id"), camera.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(camera)},
        {QStringLiteral("domain"), domain}, {QStringLiteral("provenance"), source}, {QStringLiteral("state"), state},
        {QStringLiteral("reason_code"), boundedCode(observation.value(QStringLiteral("reason_code")).toString())}
    };
    const QJsonObject details = sanitizedDetails(observation.value(QStringLiteral("details")).toObject());
    if (!details.isEmpty()) event.insert(QStringLiteral("details"), details);
    if (monotonicMs >= 0) event.insert(QStringLiteral("monotonic_ms"), monotonicMs);
    if (source == QLatin1String("backend_reported_by_client")) {
        const auto original = observation.value(QStringLiteral("backend_observation")).toObject();
        QJsonObject backend;
        static const QSet<QString> reportedStatuses {QStringLiteral("online"),QStringLiteral("offline"),QStringLiteral("maintenance"),QStringLiteral("error"),QStringLiteral("unknown")};
        static const QSet<QString> recordingStates {QStringLiteral("recording"),QStringLiteral("stalled"),QStringLiteral("armed"),QStringLiteral("offline"),QStringLiteral("disabled"),QStringLiteral("unknown")};
        const QStringList textFields { QStringLiteral("status"), QStringLiteral("recording_state"), QStringLiteral("upstream_event_id") };
        for (const auto &name : textFields) {
            const QString value = original.value(name).toString();
            if ((name == QLatin1String("status") && reportedStatuses.contains(value))
                || (name == QLatin1String("recording_state") && recordingStates.contains(value))
                || (name == QLatin1String("upstream_event_id") && isUuid(value))) backend.insert(name, value);
        }
        const QStringList dates { QStringLiteral("status_since"), QStringLiteral("recording_since"),
            QStringLiteral("last_seen"), QStringLiteral("last_segment_at") };
        for (const auto &name : dates)
            if (original.value(name).toString().size() <= 40 && awareTime(original.value(name))) backend.insert(name, original.value(name));
        backend.insert(QStringLiteral("received_locally_at"), instant(nowUtc));
        const QString requiredField = domain == QLatin1String("backend_reachability") ? QStringLiteral("status") : QStringLiteral("recording_state");
        if (!backend.contains(requiredField)) {
            noteUnrecorded(); fail(QStringLiteral("reported_state_required"), QStringLiteral("healthy")); return {};
        }
        event.insert(QStringLiteral("backend_observation"), backend);
    }
    const QString observer = observation.value(QStringLiteral("observer_key")).toString().left(256);
    const QString key = conditionKey(event, observer);
    const QString vantage = vantageKey(event);
    const QString requestedTransition = observation.value(QStringLiteral("transition")).toString();
    if (!begin()) { noteUnrecorded(); return {}; }
    const bool recoveringLogging = m_observationLossPending;
    if (recoveringLogging) {
        // The event that could not be committed is not reconstructed. Persist
        // the missing interval and invalidate all measured pairings atomically
        // with the first later observation that really reaches durable storage.
        QJsonObject gapEvent{{QStringLiteral("camera_id"), QJsonValue::Null},
            {QStringLiteral("domain"), QStringLiteral("monitoring")},
            {QStringLiteral("provenance"), QStringLiteral("client_observed")},
            {QStringLiteral("state"), QStringLiteral("unknown")},
            {QStringLiteral("transition"), QStringLiteral("monitoring_gap")},
            {QStringLiteral("reason_code"), QStringLiteral("local_logging_interrupted")},
            {QStringLiteral("details"), QJsonObject{{QStringLiteral("observer_scope"), QStringLiteral("monitoring")}}}};
        if (monotonicMs >= 0) gapEvent.insert(QStringLiteral("monotonic_ms"),monotonicMs);
        if (appendEvent(gapEvent, {}, QStringLiteral("pending"), nowUtc).isEmpty()) {
            rollback(); noteUnrecorded(); return {};
        }
        QSqlQuery interrupt(m_db);
        interrupt.prepare(QStringLiteral("UPDATE conditions SET state='unknown',gap_pending=1,failure_event_id=NULL,"
                                         "failure_monotonic_ms=NULL WHERE context_id=?"));
        interrupt.addBindValue(m_contextId);
        if (!interrupt.exec()) { fail(sqlCode(interrupt.lastError())); rollback(); noteUnrecorded(); return {}; }
    }
    QSqlQuery previous(m_db);
    previous.prepare(QStringLiteral("SELECT state,condition_id,last_event_id,run_id,monotonic_ms,gap_pending,failure_event_id,failure_monotonic_ms FROM conditions "
                                    "WHERE context_id=? AND condition_key=?"));
    previous.addBindValue(m_contextId); previous.addBindValue(key);
    if (!previous.exec()) { fail(sqlCode(previous.lastError())); rollback(); noteUnrecorded(); return {}; }
    const bool hasPrevious = previous.next();
    const QString oldState = hasPrevious ? previous.value(0).toString() : QString();
    QString conditionId = hasPrevious ? previous.value(1).toString() : QString();
    QString relatedId = hasPrevious ? previous.value(2).toString() : QString();
    const QString previousRun = hasPrevious ? previous.value(3).toString() : QString();
    const bool gap = hasPrevious && previous.value(5).toBool();
    if (gap) conditionId.clear();
    QString failureId = hasPrevious ? previous.value(6).toString() : QString();
    QVariant failureMono = hasPrevious ? previous.value(7) : QVariant();
    previous.finish();
    bool changedReportedIncident = false;
    if (hasPrevious && oldState == state && source == QLatin1String("backend_reported_by_client")) {
        QSqlQuery oldPayload(m_db);
        oldPayload.prepare(QStringLiteral("SELECT payload FROM events WHERE context_id=? AND event_id=?"));
        oldPayload.addBindValue(m_contextId); oldPayload.addBindValue(relatedId);
        if (!oldPayload.exec()) { fail(sqlCode(oldPayload.lastError())); rollback(); noteUnrecorded(); return {}; }
        if (oldPayload.next()) {
            const auto before = QJsonDocument::fromJson(oldPayload.value(0).toByteArray()).object()
                                    .value(QStringLiteral("backend_observation")).toObject();
            const auto after = event.value(QStringLiteral("backend_observation")).toObject();
            const QStringList identityFields = domain == QLatin1String("backend_reachability")
                ? QStringList {QStringLiteral("status"),QStringLiteral("status_since"),QStringLiteral("upstream_event_id")}
                : QStringList {QStringLiteral("recording_state"),QStringLiteral("recording_since"),QStringLiteral("upstream_event_id")};
            for (const auto &field : identityFields)
                if (before.value(field) != after.value(field)) changedReportedIncident = true;
        }
    }
    if (hasPrevious && oldState == state && !changedReportedIncident && !recoveringLogging
        && !observation.value(QStringLiteral("force_event")).toBool()
        && !(gap && domain == QLatin1String("monitoring") && requestedTransition == QLatin1String("monitoring_resumed"))) {
        rollback(); clearError(); return {};
    }
    QString transition;
    if (!hasPrevious) transition = QStringLiteral("initial");
    else if (gap) transition = domain == QLatin1String("monitoring") ? QStringLiteral("monitoring_resumed") : QStringLiteral("initial");
    else if ((state == QLatin1String("unknown") || state == QLatin1String("not_monitored")) && oldState != state
             && source != QLatin1String("backend_reported_by_client"))
        transition = QStringLiteral("monitoring_gap");
    else if (state == QLatin1String("available") && faultState(oldState) && previousRun == m_runId && !failureId.isEmpty()
             && (failureMono.isNull() || monotonicMs < 0 || monotonicMs >= failureMono.toLongLong()))
        transition = QStringLiteral("recovery");
    else if (faultState(state) && !faultState(oldState)) transition = QStringLiteral("failure");
    else transition = QStringLiteral("state_change");
    if (!requestedTransition.isEmpty() && !transitions.contains(requestedTransition)) {
        rollback(); noteUnrecorded(); fail(QStringLiteral("invalid_transition"), QStringLiteral("healthy")); return {};
    }
    // Baseline/gap hints are legitimate; a caller cannot manufacture recovery
    // across an unobserved interval or turn the startup baseline into failure.
    if (requestedTransition == QLatin1String("initial") || requestedTransition == QLatin1String("monitoring_gap")
        || requestedTransition == QLatin1String("monitoring_resumed")) transition = requestedTransition;
    // An explicit upstream unknown remains an upstream observation. It is not
    // evidence that this station stopped monitoring, and its metadata must stay.
    if (source == QLatin1String("backend_reported_by_client") && state == QLatin1String("unknown"))
        transition = !hasPrevious || gap ? QStringLiteral("initial") : QStringLiteral("state_change");
    if (changedReportedIncident && faultState(state)) {
        // A newly reported effective-time/native identity distinguishes a new
        // reported incident even if intermediate polls were not observed.
        conditionId = uuid(); failureId.clear(); failureMono = QVariant();
    }
    if (transition == QLatin1String("monitoring_gap") || state == QLatin1String("not_monitored")) {
        if (state != QLatin1String("unknown") && state != QLatin1String("not_monitored")) {
            rollback(); noteUnrecorded();
            fail(QStringLiteral("invalid_transition_state"), QStringLiteral("healthy")); return {};
        }
        event.insert(QStringLiteral("domain"), QStringLiteral("monitoring"));
        event.insert(QStringLiteral("provenance"), QStringLiteral("client_observed"));
        event.remove(QStringLiteral("backend_observation"));
        transition = QStringLiteral("monitoring_gap");
        failureId.clear(); failureMono = QVariant();
    } else if (transition == QLatin1String("monitoring_resumed") && domain != QLatin1String("monitoring")) {
        transition = QStringLiteral("initial");
    }
    if (transition == QLatin1String("monitoring_resumed") && state != QLatin1String("available") && state != QLatin1String("unknown"))
        transition = QStringLiteral("state_change");
    if (transition == QLatin1String("failure") || (faultState(state) && conditionId.isEmpty())) conditionId = uuid();
    if (!conditionId.isEmpty()) event.insert(QStringLiteral("condition_id"), conditionId);
    if (!relatedId.isEmpty()) event.insert(QStringLiteral("related_event_id"), relatedId);
    event.insert(QStringLiteral("transition"), transition);
    if (transition == QLatin1String("recovery")) {
        relatedId = failureId;
        event.insert(QStringLiteral("related_event_id"), relatedId);
    }
    if (transition == QLatin1String("recovery") && !failureMono.isNull() && monotonicMs >= failureMono.toLongLong()
        && previousRun == m_runId)
        event.insert(QStringLiteral("duration_ms"), monotonicMs - failureMono.toLongLong());
    const QString id = appendEvent(event, key, QStringLiteral("pending"), nowUtc);
    if (id.isEmpty()) { rollback(); noteUnrecorded(); return {}; }
    if (transition == QLatin1String("failure")) {
        failureId = id;
        failureMono = monotonicMs >= 0 ? QVariant(monotonicMs) : QVariant();
    } else if (!faultState(state)) {
        failureId.clear(); failureMono = QVariant();
    }
    QSqlQuery update(m_db);
    update.prepare(QStringLiteral("INSERT INTO conditions(context_id,condition_key,vantage_key,observer_scope,state,condition_id,last_event_id,run_id,observed_at,"
                                  "monotonic_ms,active,gap_pending,failure_event_id,failure_monotonic_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?) "
                                  "ON CONFLICT(context_id,condition_key) DO UPDATE SET state=excluded.state,condition_id=excluded.condition_id,"
                                  "last_event_id=excluded.last_event_id,run_id=excluded.run_id,observed_at=excluded.observed_at,"
                                  "monotonic_ms=excluded.monotonic_ms,active=excluded.active,gap_pending=excluded.gap_pending,"
                                  "failure_event_id=excluded.failure_event_id,failure_monotonic_ms=excluded.failure_monotonic_ms"));
    update.addBindValue(m_contextId); update.addBindValue(key); update.addBindValue(vantage);
    update.addBindValue(details.value(QStringLiteral("observer_scope")).toString(QStringLiteral("unknown")));
    update.addBindValue(state);
    update.addBindValue(conditionId); update.addBindValue(id); update.addBindValue(m_runId);
    update.addBindValue(instant(nowUtc));
    update.addBindValue(monotonicMs >= 0 ? QVariant(monotonicMs) : QVariant(QMetaType::fromType<qint64>()));
    update.addBindValue(faultState(state) ? 1 : 0);
    update.addBindValue(transition == QLatin1String("monitoring_gap") || state == QLatin1String("unknown") ? 1 : 0);
    update.addBindValue(failureId);
    update.addBindValue(failureMono.isNull() ? QVariant(QMetaType::fromType<qint64>()) : failureMono);
    if (!update.exec()) { fail(sqlCode(update.lastError())); rollback(); noteUnrecorded(); return {}; }
    if (transition == QLatin1String("monitoring_gap")) {
        QSqlQuery invalidate(m_db);
        const bool stationGap = camera.isEmpty() && domain == QLatin1String("monitoring");
        const bool backendGap = stationGap && details.value(QStringLiteral("observer_scope")).toString() == QLatin1String("backend");
        invalidate.prepare(QStringLiteral("UPDATE conditions SET state='unknown',gap_pending=1,failure_event_id=NULL,"
                                          "failure_monotonic_ms=NULL WHERE context_id=? AND condition_key<>?")
                           + (backendGap ? QStringLiteral(" AND observer_scope='backend'")
                                         : stationGap ? QString() : QStringLiteral(" AND vantage_key=?")));
        invalidate.addBindValue(m_contextId); invalidate.addBindValue(key);
        if (!stationGap) invalidate.addBindValue(vantage);
        if (!invalidate.exec()) { fail(sqlCode(invalidate.lastError())); rollback(); noteUnrecorded(); return {}; }
    }
    if (!commit()) { noteUnrecorded(); return {}; }
    m_observationLossPending = false;
    clearError();
    return id;
}

QJsonObject CameraAvailabilityJournal::prepareBatch(int maxEvents, qint64 maxBytes, const QDateTime &nowUtc)
{
    m_batchPayload.clear();
    if (!isOpen() || m_contextId.isEmpty()) { fail(QStringLiteral("database_unavailable")); return {}; }
    if (m_backendId.isEmpty() || m_stationId.isEmpty()) { fail(QStringLiteral("identity_unbound"), QStringLiteral("healthy")); return {}; }
    if (maxEvents < 1 || maxBytes < 256 || !validTime(nowUtc)) {
        fail(QStringLiteral("invalid_batch_limits"), QStringLiteral("healthy")); return {};
    }
    maxEvents = std::min(maxEvents, 500);
    maxBytes = std::min<qint64>(maxBytes, 1048576);
    clearError();
    QSqlQuery existing(m_db);
    existing.prepare(QStringLiteral("SELECT b.payload FROM batches b JOIN contexts c ON c.active_batch_id=b.batch_id "
                                    "WHERE c.id=? AND b.state='pending'"));
    existing.addBindValue(m_contextId);
    if (!existing.exec()) { fail(sqlCode(existing.lastError())); return {}; }
    if (existing.next()) {
        const QByteArray payload = existing.value(0).toByteArray();
        const auto parsed = QJsonDocument::fromJson(payload);
        if (!parsed.isObject() || parsed.object().value(QStringLiteral("backend_instance_id")).toString() != m_backendId) {
            fail(QStringLiteral("persisted_batch_corrupt")); return {};
        }
        existing.finish();
        if (payload.size() <= maxBytes && parsed.object().value(QStringLiteral("events")).toArray().size() <= maxEvents) {
            m_batchPayload = payload;
            return parsed.object();
        }
        if (!abandonBatch(QStringLiteral("negotiated_limit_changed"), nowUtc)) return {};
    }
    if (!begin()) return {};
    const QString batchId = uuid();
    QJsonObject envelope { {QStringLiteral("schema_version"), 1},
        {QStringLiteral("backend_instance_id"), m_backendId}, {QStringLiteral("producer_id"), m_producerId},
        {QStringLiteral("batch_id"), batchId}, {QStringLiteral("events"), QJsonArray()} };
    QSqlQuery rows(m_db);
    rows.prepare(QStringLiteral("SELECT event_id,payload FROM events WHERE context_id=? AND delivery='pending' "
                                "ORDER BY local_seq LIMIT 500"));
    rows.addBindValue(m_contextId);
    if (!rows.exec()) { fail(sqlCode(rows.lastError())); rollback(); return {}; }
    struct Candidate { QString id; QJsonObject event; };
    QList<Candidate> candidates;
    while (rows.next()) {
        const auto payload = QJsonDocument::fromJson(rows.value(1).toByteArray());
        if (!payload.isObject()) { fail(QStringLiteral("persisted_event_corrupt")); rollback(); return {}; }
        candidates.append({rows.value(0).toString(), payload.object()});
    }
    rows.finish();
    QJsonArray events;
    QStringList ids;
    bool poisonFound = false;
    for (const auto &candidate : candidates) {
        if (events.size() >= maxEvents) break;
        QJsonArray trial = events;
        trial.append(candidate.event);
        envelope.insert(QStringLiteral("events"), trial);
        const auto bytes = compact(envelope);
        if (bytes.size() > maxBytes) {
            if (!events.isEmpty()) break;
            // A permanently oversized single record is retained visibly, and
            // does not starve later valid records. Never rewrite its content.
            QSqlQuery reject(m_db);
            reject.prepare(QStringLiteral("UPDATE events SET delivery='rejected',rejection_reason='event_exceeds_body_limit' "
                                          "WHERE event_id=? AND context_id=? AND delivery='pending'"));
            reject.addBindValue(candidate.id); reject.addBindValue(m_contextId);
            if (!reject.exec()) { fail(sqlCode(reject.lastError())); rollback(); return {}; }
            poisonFound = true;
            continue;
        }
        events = trial;
        ids.append(candidate.id);
    }
    if (events.isEmpty()) {
        if (!commit()) return {};
        if (poisonFound) fail(QStringLiteral("rejected_oversized_events"), QStringLiteral("healthy"));
        return {};
    }
    envelope.insert(QStringLiteral("events"), events);
    const QByteArray payload = compact(envelope);
    // Envelopes duplicate immutable event JSON and add membership/index rows.
    // Refuse the entire transaction before assigning an active batch when that
    // bounded extra storage cannot fit; the original pending records survive.
    if (!reserveStorage(std::max<qint64>(MinimumTransactionReserve,
            payload.size() * 2 + 8192 + ids.size() * 256))) { rollback(); return {}; }
    QSqlQuery batch(m_db);
    batch.prepare(QStringLiteral("INSERT INTO batches(batch_id,context_id,payload,state,created_at) VALUES (?,?,?,'pending',?)"));
    batch.addBindValue(batchId); batch.addBindValue(m_contextId); batch.addBindValue(payload); batch.addBindValue(instant(nowUtc));
    if (!batch.exec()) { fail(sqlCode(batch.lastError())); rollback(); return {}; }
    QSqlQuery link(m_db);
    link.prepare(QStringLiteral("INSERT INTO batch_events(batch_id,context_id,event_id) VALUES (?,?,?)"));
    for (const auto &id : ids) {
        link.bindValue(0, batchId); link.bindValue(1, m_contextId); link.bindValue(2, id);
        if (!link.exec()) { fail(sqlCode(link.lastError())); rollback(); return {}; }
    }
    if (!writeContext(QStringLiteral("active_batch_id"), batchId) || !commit()) { rollback(); return {}; }
    m_batchPayload = payload;
    return envelope;
}

QByteArray CameraAvailabilityJournal::batchPayload() const { return m_batchPayload; }

bool CameraAvailabilityJournal::applyAck(const QJsonObject &ack, const QDateTime &nowUtc)
{
    if (!isOpen()) return fail(QStringLiteral("database_unavailable"));
    static const QSet<QString> keys {QStringLiteral("schema_version"),QStringLiteral("batch_id"),
        QStringLiteral("backend_instance_id"),QStringLiteral("reporter_station_id"),QStringLiteral("server_received_at"),
        QStringLiteral("accepted_event_ids"),QStringLiteral("duplicate_event_ids")};
    QSet<QString> supplied;
    for (auto it = ack.begin(); it != ack.end(); ++it) supplied.insert(it.key());
    if (supplied != keys || !ack.value(QStringLiteral("schema_version")).isDouble()
        || ack.value(QStringLiteral("schema_version")).toDouble() != 1.0
        || ack.value(QStringLiteral("backend_instance_id")).toString() != m_backendId
        || ack.value(QStringLiteral("reporter_station_id")).toString() != m_stationId
        || !awareTime(ack.value(QStringLiteral("server_received_at")))
        || !ack.value(QStringLiteral("accepted_event_ids")).isArray()
        || !ack.value(QStringLiteral("duplicate_event_ids")).isArray() || !validTime(nowUtc))
        return fail(QStringLiteral("invalid_ack"), QStringLiteral("healthy"));
    QSqlQuery active(m_db);
    active.prepare(QStringLiteral("SELECT active_batch_id FROM contexts WHERE id=?"));
    active.addBindValue(m_contextId);
    if (!active.exec() || !active.next()) return fail(sqlCode(active.lastError()));
    const QString batchId = active.value(0).toString();
    active.finish();
    if (batchId.isEmpty() || ack.value(QStringLiteral("batch_id")).toString() != batchId)
        return fail(QStringLiteral("mismatched_ack"), QStringLiteral("healthy"));
    QSqlQuery members(m_db);
    members.prepare(QStringLiteral("SELECT event_id FROM batch_events WHERE batch_id=?"));
    members.addBindValue(batchId);
    if (!members.exec()) return fail(sqlCode(members.lastError()));
    QSet<QString> expected;
    while (members.next()) expected.insert(members.value(0).toString());
    QSet<QString> acknowledged;
    const auto accepted = ack.value(QStringLiteral("accepted_event_ids")).toArray();
    const auto duplicates = ack.value(QStringLiteral("duplicate_event_ids")).toArray();
    if (accepted.size() > 500 || duplicates.size() > 500)
        return fail(QStringLiteral("invalid_ack"), QStringLiteral("healthy"));
    for (const auto &list : {accepted, duplicates}) {
        for (const auto &value : list) {
            const QString id = value.toString();
            if (!value.isString() || !isUuid(id) || !expected.contains(id) || acknowledged.contains(id))
                return fail(QStringLiteral("invalid_ack_ids"), QStringLiteral("healthy"));
            acknowledged.insert(id);
        }
    }
    if (acknowledged.isEmpty()) return fail(QStringLiteral("partial_ack"), QStringLiteral("healthy"));
    clearError();
    if (!begin()) return false;
    QSqlQuery update(m_db);
    update.prepare(QStringLiteral("UPDATE events SET delivery='acknowledged',acknowledged_at=? "
                                  "WHERE event_id=? AND context_id=? AND delivery='pending'"));
    for (const auto &id : acknowledged) {
        update.bindValue(0, instant(nowUtc)); update.bindValue(1, id); update.bindValue(2, m_contextId);
        if (!update.exec()) { fail(sqlCode(update.lastError())); rollback(); return false; }
    }
    const bool complete = acknowledged == expected;
    if (complete) {
        QSqlQuery done(m_db);
        done.prepare(QStringLiteral("UPDATE batches SET state='acknowledged' WHERE batch_id=?"));
        done.addBindValue(batchId);
        if (!done.exec()) { fail(sqlCode(done.lastError())); rollback(); return false; }
        if (!writeContext(QStringLiteral("active_batch_id"), QString())
            || !writeContext(QStringLiteral("last_success_at"), instant(nowUtc))
            || !writeContext(QStringLiteral("sync_error"), QString())
            || !writeContext(QStringLiteral("next_sync_at"), instant(nowUtc.addMSecs(SyncIntervalMs)))) {
            rollback(); return false;
        }
    } else if (!writeContext(QStringLiteral("sync_error"), QStringLiteral("partial_ack"))) {
        rollback(); return false;
    }
    if (!commit()) return false;
    if (!complete) return fail(QStringLiteral("partial_ack"), QStringLiteral("healthy"));
    m_batchPayload.clear(); clearError();
    return true;
}

bool CameraAvailabilityJournal::abandonBatch(const QString &reason, const QDateTime &nowUtc)
{
    if (!isOpen() || !validTime(nowUtc)) return fail(QStringLiteral("database_unavailable"));
    if (!begin()) return false;
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("UPDATE batches SET state='retired' WHERE context_id=? AND batch_id="
                                 "(SELECT active_batch_id FROM contexts WHERE id=?)"));
    query.addBindValue(m_contextId); query.addBindValue(m_contextId);
    if (!query.exec()) { fail(sqlCode(query.lastError())); rollback(); return false; }
    if (!writeContext(QStringLiteral("active_batch_id"), QString())
        || !writeContext(QStringLiteral("sync_error"), boundedCode(reason)) || !commit()) {
        rollback(); return false;
    }
    m_batchPayload.clear(); clearError();
    return true;
}

bool CameraAvailabilityJournal::rejectEvents(const QStringList &eventIds, const QString &reason, const QDateTime &nowUtc)
{
    if (!isOpen() || !validTime(nowUtc)) return fail(QStringLiteral("database_unavailable"));
    if (eventIds.isEmpty() || eventIds.size() > 500) return fail(QStringLiteral("invalid_rejection"), QStringLiteral("healthy"));
    for (const auto &id : eventIds) if (!isUuid(id)) return fail(QStringLiteral("invalid_rejection"), QStringLiteral("healthy"));
    if (!begin()) return false;
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("UPDATE events SET delivery='rejected',rejection_reason=? "
                                 "WHERE context_id=? AND event_id=? AND delivery='pending'"));
    for (const auto &id : eventIds) {
        query.bindValue(0, boundedCode(reason)); query.bindValue(1, m_contextId); query.bindValue(2, id);
        if (!query.exec()) { fail(sqlCode(query.lastError())); rollback(); return false; }
    }
    QSqlQuery batch(m_db);
    batch.prepare(QStringLiteral("UPDATE batches SET state='retired' WHERE context_id=? AND batch_id="
                                 "(SELECT active_batch_id FROM contexts WHERE id=?)"));
    batch.addBindValue(m_contextId); batch.addBindValue(m_contextId);
    if (!batch.exec()) { fail(sqlCode(batch.lastError())); rollback(); return false; }
    if (!writeContext(QStringLiteral("active_batch_id"), QString())
        || !writeContext(QStringLiteral("sync_error"), boundedCode(reason)) || !commit()) {
        rollback(); return false;
    }
    m_batchPayload.clear(); clearError();
    return true;
}

bool CameraAvailabilityJournal::importNative(const QJsonArray &events, const QString &nextCursor, const QDateTime &nowUtc)
{
    if (!isOpen() || m_backendId.isEmpty()) return fail(QStringLiteral("identity_unbound"), QStringLiteral("healthy"));
    if (events.size() > 500 || nextCursor.size() > 4096 || !validTime(nowUtc))
        return fail(QStringLiteral("invalid_native_page"), QStringLiteral("healthy"));
    if (!begin()) return false;
    for (const auto &value : events) {
        if (!value.isObject()) { rollback(); return fail(QStringLiteral("invalid_native_event"), QStringLiteral("healthy")); }
        const auto event = value.toObject();
        const QString id = event.value(QStringLiteral("event_id")).toString();
        if (!validNativeObject(event,m_backendId)) {
            rollback(); return fail(QStringLiteral("invalid_native_event"), QStringLiteral("healthy"));
        }
        // Validate transport-scoped events before preserving the exact native
        // object; arbitrary server strings never become local log/export data.
        if (compact(event).size() > 16384) { rollback(); return fail(QStringLiteral("native_event_too_large"), QStringLiteral("healthy")); }
        QSqlQuery duplicate(m_db);
        duplicate.prepare(QStringLiteral("SELECT payload FROM events WHERE event_id=? AND context_id=?"));
        duplicate.addBindValue(id); duplicate.addBindValue(m_contextId);
        if (!duplicate.exec()) { fail(sqlCode(duplicate.lastError())); rollback(); return false; }
        if (duplicate.next()) {
            const auto existing = QJsonDocument::fromJson(duplicate.value(0).toByteArray()).object();
            duplicate.finish();
            if (immutableNative(existing) != immutableNative(event)) {
                rollback(); return fail(QStringLiteral("native_event_conflict"), QStringLiteral("healthy"));
            }
            continue;
        }
        duplicate.finish();
        if (appendEvent(event, {}, QStringLiteral("native"), nowUtc, true).isEmpty()) { rollback(); return false; }
    }
    if (!writeContext(QStringLiteral("native_cursor"), nextCursor) || !commit()) { rollback(); return false; }
    clearError();
    return true;
}

QString CameraAvailabilityJournal::nativeCursor() const
{
    if (!isOpen()) return {};
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("SELECT native_cursor FROM contexts WHERE id=?"));
    query.addBindValue(m_contextId);
    if (!query.exec()) { fail(sqlCode(query.lastError())); return {}; }
    return query.next() ? query.value(0).toString() : QString();
}

bool CameraAvailabilityJournal::recordAttempt(const QDateTime &nowUtc)
{
    if (!isOpen() || !validTime(nowUtc)) return fail(QStringLiteral("invalid_clock"));
    return writeContext(QStringLiteral("last_attempt_at"), instant(nowUtc));
}

bool CameraAvailabilityJournal::recordFailure(const QString &reason, const QDateTime &retryAtUtc)
{
    if (!isOpen() || !validTime(retryAtUtc)) return fail(QStringLiteral("invalid_clock"));
    if (!begin()) return false;
    if (!writeContext(QStringLiteral("sync_error"), boundedCode(reason))
        || !writeContext(QStringLiteral("next_sync_at"), instant(retryAtUtc)) || !commit()) {
        rollback(); return false;
    }
    return true;
}

bool CameraAvailabilityJournal::setNextSyncDue(const QDateTime &nextUtc)
{
    if (!isOpen() || !validTime(nextUtc)) return fail(QStringLiteral("invalid_clock"));
    return writeContext(QStringLiteral("next_sync_at"), instant(nextUtc));
}

bool CameraAvailabilityJournal::syncDue(const QDateTime &nowUtc) const
{
    if (!isOpen() || !validTime(nowUtc)) return false;
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("SELECT next_sync_at,last_attempt_at FROM contexts WHERE id=?"));
    query.addBindValue(m_contextId);
    if (!query.exec()) { fail(sqlCode(query.lastError())); return false; }
    if (!query.next()) return false;
    const auto next = QDateTime::fromString(query.value(0).toString(), Qt::ISODateWithMs);
    const auto attempt = QDateTime::fromString(query.value(1).toString(), Qt::ISODateWithMs);
    // A backwards wall-clock adjustment must not defer a queue indefinitely.
    // The service additionally uses its process-local monotonic timer.
    return !next.isValid() || nowUtc >= next
        || (attempt.isValid() && nowUtc < attempt.addMSecs(-SyncIntervalMs));
}

QJsonObject CameraAvailabilityJournal::status(const QDateTime &nowUtc) const
{
    QJsonObject result { {QStringLiteral("storageState"), m_storageState},
        {QStringLiteral("error"), m_error}, {QStringLiteral("pendingCount"), 0},
        {QStringLiteral("rejectedCount"), 0}, {QStringLiteral("retainedOtherContextCount"), 0},
        {QStringLiteral("oldestPendingAt"), QJsonValue::Null},
        {QStringLiteral("lastAttemptAt"), QJsonValue::Null}, {QStringLiteral("lastSuccessfulSyncAt"), QJsonValue::Null},
        {QStringLiteral("nextSyncAt"), QJsonValue::Null},
        {QStringLiteral("identityState"), m_backendId.isEmpty() ? QStringLiteral("unbound") : QStringLiteral("bound")},
        {QStringLiteral("unrecordedCount"), m_unrecordedCount}, {QStringLiteral("loggingComplete"), m_unrecordedCount == 0},
        {QStringLiteral("runId"), m_runId}, {QStringLiteral("producerId"), m_producerId},
        {QStringLiteral("backendInstanceId"), m_backendId}, {QStringLiteral("reporterStationId"), m_stationId} };
    if (!isOpen()) return result;
    QSqlQuery count(m_db);
    count.prepare(QStringLiteral("SELECT delivery,COUNT(*),MIN(observed_at) FROM events WHERE context_id=? GROUP BY delivery"));
    count.addBindValue(m_contextId);
    if (!count.exec()) { fail(sqlCode(count.lastError())); result.insert(QStringLiteral("error"), m_error); return result; }
    qint64 historyCount = 0;
    while (count.next()) {
        const QString delivery = count.value(0).toString();
        const qint64 number = count.value(1).toLongLong();
        historyCount += number;
        if (delivery == QLatin1String("pending")) {
            result.insert(QStringLiteral("pendingCount"), number);
            const QString oldest = count.value(2).toString();
            result.insert(QStringLiteral("oldestPendingAt"), oldest);
            const auto dt = QDateTime::fromString(oldest, Qt::ISODateWithMs);
            if (dt.isValid() && validTime(nowUtc)) result.insert(QStringLiteral("oldestPendingAgeMs"), std::max<qint64>(0, dt.msecsTo(nowUtc)));
        } else if (delivery == QLatin1String("rejected")) result.insert(QStringLiteral("rejectedCount"), number);
    }
    result.insert(QStringLiteral("historyCount"), historyCount);
    QSqlQuery context(m_db);
    context.prepare(QStringLiteral("SELECT last_attempt_at,last_success_at,next_sync_at,sync_error,active_batch_id FROM contexts WHERE id=?"));
    context.addBindValue(m_contextId);
    if (!context.exec()) { fail(sqlCode(context.lastError())); result.insert(QStringLiteral("error"), m_error); return result; }
    if (context.next()) {
        const QStringList keys {QStringLiteral("lastAttemptAt"),QStringLiteral("lastSuccessfulSyncAt"),QStringLiteral("nextSyncAt")};
        for (int i = 0; i < keys.size(); ++i) if (!context.value(i).isNull()) result.insert(keys[i], context.value(i).toString());
        result.insert(QStringLiteral("syncError"), context.value(3).toString());
        result.insert(QStringLiteral("activeBatchId"), context.value(4).toString());
    }
    QSqlQuery other(m_db);
    other.prepare(QStringLiteral("SELECT COUNT(*) FROM events WHERE context_id<>? AND delivery IN ('pending','rejected')"));
    other.addBindValue(m_contextId);
    if (!other.exec()) { fail(sqlCode(other.lastError())); result.insert(QStringLiteral("error"), m_error); return result; }
    if (other.next()) result.insert(QStringLiteral("retainedOtherContextCount"), other.value(0).toLongLong());
    if (m_error == QLatin1String("identity_conflict")) result.insert(QStringLiteral("identityState"), QStringLiteral("conflict"));
    return result;
}

QJsonObject CameraAvailabilityJournal::historyRelationships(QJsonObject event, qint64 position, qint64 bound) const
{
    const bool native = event.value(QStringLiteral("provenance")).toString() == QLatin1String("backend_native");
    const QString authority = native ? QStringLiteral("backend_native") : QStringLiteral("client_reported");
    const auto compatible = [this](const QJsonObject &failure,const QJsonObject &recovery) {
        if (failure.value(QStringLiteral("transition")).toString() != QLatin1String("failure")
            || !faultState(failure.value(QStringLiteral("state")).toString()) ) return false;
        for (const auto &key : {QStringLiteral("camera_id"),QStringLiteral("domain"),QStringLiteral("provenance"),
                               QStringLiteral("run_id"),QStringLiteral("condition_id"),QStringLiteral("producer_id")})
            if (failure.value(key) != recovery.value(key)) return false;
        if (failure.value(QStringLiteral("condition_id")).toString().isEmpty()
            || recovery.value(QStringLiteral("state")).toString() != QLatin1String("available")
            || failure.value(QStringLiteral("event_id")) != recovery.value(QStringLiteral("related_event_id"))
            || vantageKey(failure) != vantageKey(recovery)) return false;
        const auto a = failure.value(QStringLiteral("monotonic_ms")), b = recovery.value(QStringLiteral("monotonic_ms"));
        return a.isUndefined() || a.isNull() || b.isUndefined() || b.isNull() || b.toInteger(-1) >= a.toInteger(-1);
    };
    const auto interrupted = [this](const QJsonObject &failure,qint64 first,qint64 last) {
        QSqlQuery gaps(m_db);
        gaps.prepare(QStringLiteral("SELECT payload FROM events WHERE context_id=? AND transition='monitoring_gap' "
                                    "AND local_seq>? AND local_seq<=? ORDER BY local_seq"));
        gaps.addBindValue(m_contextId);gaps.addBindValue(first);gaps.addBindValue(last);
        if (!gaps.exec()) { fail(sqlCode(gaps.lastError())); return true; }
        while (gaps.next()) {
            const auto gap = QJsonDocument::fromJson(gaps.value(0).toByteArray()).object();
            // Independent stations/producers and independent observation paths
            // cannot erase each other's positive or failure evidence.
            const bool nativeFailure = failure.value(QStringLiteral("provenance")).toString() == QLatin1String("backend_native");
            const bool nativeGap = gap.value(QStringLiteral("provenance")).toString() == QLatin1String("backend_native");
            if (nativeFailure != nativeGap || failure.value(QStringLiteral("producer_id")) != gap.value(QStringLiteral("producer_id"))) continue;
            const auto details = gap.value(QStringLiteral("details")).toObject();
            if (gap.value(QStringLiteral("camera_id")).isNull()) {
                if (details.value(QStringLiteral("observer_scope")).toString() != QLatin1String("backend")
                    || failure.value(QStringLiteral("details")).toObject().value(QStringLiteral("observer_scope")).toString() == QLatin1String("backend")) return true;
            } else if (gap.value(QStringLiteral("camera_id")) == failure.value(QStringLiteral("camera_id"))
                       && (vantageKey(gap) == vantageKey(failure) || (nativeGap && details.isEmpty()))) return true;
        }
        return false;
    };
    const QString transition = event.value(QStringLiteral("transition")).toString();
    event.insert(QStringLiteral("relationship_authority"),authority);
    event.insert(QStringLiteral("condition_status_authority"),authority);
    if (transition == QLatin1String("failure")) {
        QString status = QStringLiteral("open_unpaired_failure");
        QSqlQuery recoveries(m_db);
        recoveries.prepare(QStringLiteral("SELECT payload,local_seq FROM events WHERE context_id=? AND condition_id=? "
                                          "AND transition='recovery' AND local_seq<=? ORDER BY local_seq"));
        recoveries.addBindValue(m_contextId);recoveries.addBindValue(event.value(QStringLiteral("condition_id")).toString());recoveries.addBindValue(bound);
        if (!recoveries.exec()) { fail(sqlCode(recoveries.lastError())); status=QStringLiteral("interrupted_by_monitoring_gap"); }
        else while (recoveries.next()) {
            const auto recovery=QJsonDocument::fromJson(recoveries.value(0).toByteArray()).object();
            if (compatible(event,recovery) && !interrupted(event,position,recoveries.value(1).toLongLong())) {
                status=QStringLiteral("recovery_referenced");break;
            }
        }
        if (status == QLatin1String("open_unpaired_failure")) {
            if (interrupted(event,position,bound)) status=QStringLiteral("interrupted_by_monitoring_gap");
            else if (native && (event.value(QStringLiteral("condition_status")).toString() == QLatin1String("recovery_referenced")
                     || event.value(QStringLiteral("condition_status")).toString() == QLatin1String("interrupted_by_monitoring_gap")))
                status=event.value(QStringLiteral("condition_status")).toString(); // Established by the received native page.
        }
        event.insert(QStringLiteral("condition_status"),status);
    } else event.insert(QStringLiteral("condition_status"),QStringLiteral("not_applicable"));
    if (transition == QLatin1String("recovery")) {
        QSqlQuery reference(m_db);
        reference.prepare(QStringLiteral("SELECT payload,local_seq FROM events WHERE context_id=? AND event_id=? AND local_seq<=?"));
        reference.addBindValue(m_contextId);reference.addBindValue(event.value(QStringLiteral("related_event_id")).toString());reference.addBindValue(bound);
        QString status=native && event.value(QStringLiteral("relationship_status")).toString() == QLatin1String("native_same_run_reference")
            ? QStringLiteral("native_same_run_reference") : QStringLiteral("pending_reference");
        if (!reference.exec()) { fail(sqlCode(reference.lastError())); status=QStringLiteral("incompatible_reference"); }
        else if (reference.next()) {
            const auto failure=QJsonDocument::fromJson(reference.value(0).toByteArray()).object();
            status=compatible(failure,event) && !interrupted(failure,reference.value(1).toLongLong(),position)
                ? native ? QStringLiteral("native_same_run_reference") : QStringLiteral("reported_same_run_reference")
                : QStringLiteral("incompatible_reference");
        }
        event.insert(QStringLiteral("relationship_status"),status);
    } else if (!event.contains(QStringLiteral("relationship_status"))) event.insert(QStringLiteral("relationship_status"),QStringLiteral("none"));
    return event;
}

QJsonArray CameraAvailabilityJournal::history(const QString &cameraId, const QDateTime &fromUtc,
                                             const QDateTime &untilUtc, int limit,
                                             const QStringList &allowedCameraIds, bool includeStationRows) const
{
    QJsonArray result;
    if (!isOpen()) return result;
    if (allowedCameraIds.size() > 10000) {
        fail(QStringLiteral("history_scope_too_large"),QStringLiteral("healthy")); return result;
    }
    QStringList allowed = allowedCameraIds;
    allowed.removeDuplicates();
    QSqlQuery head(m_db);
    head.prepare(QStringLiteral("SELECT COALESCE(MAX(local_seq),0) FROM events WHERE context_id=?"));head.addBindValue(m_contextId);
    if (!head.exec() || !head.next()) { fail(sqlCode(head.lastError()));return result; }
    const qint64 bound=head.value(0).toLongLong();head.finish();
    QString sql = QStringLiteral("SELECT payload,delivery,rejection_reason,acknowledged_at,local_seq FROM events WHERE context_id=? AND local_seq<=?");
    if (!cameraId.isEmpty()) sql += QStringLiteral(" AND camera_id=?");
    const bool scoped = !allowed.isEmpty() || !includeStationRows;
    if (scoped) {
        if (allowed.isEmpty()) sql += QStringLiteral(" AND 0");
        else {
            QStringList placeholders;
            placeholders.reserve(allowed.size());
            for (qsizetype i = 0; i < allowed.size(); ++i) placeholders.append(QStringLiteral("?"));
            sql += QStringLiteral(" AND (camera_id IN (%1)").arg(placeholders.join(QLatin1Char(',')));
            if (includeStationRows) sql += QStringLiteral(" OR camera_id IS NULL");
            sql += QLatin1Char(')');
        }
    }
    if (fromUtc.isValid()) sql += QStringLiteral(" AND observed_at>=?");
    if (untilUtc.isValid()) sql += QStringLiteral(" AND observed_at<=?");
    sql += QStringLiteral(" ORDER BY local_seq DESC LIMIT ?");
    QSqlQuery query(m_db);
    query.prepare(sql);
    query.addBindValue(m_contextId);
    query.addBindValue(bound);
    if (!cameraId.isEmpty()) query.addBindValue(cameraId);
    if (scoped) for (const auto &id : allowed) query.addBindValue(id);
    if (fromUtc.isValid()) query.addBindValue(instant(fromUtc));
    if (untilUtc.isValid()) query.addBindValue(instant(untilUtc));
    query.addBindValue(std::clamp(limit, 1, 1000));
    if (!query.exec()) { fail(sqlCode(query.lastError())); return result; }
    while (query.next()) {
        auto event = historyRelationships(QJsonDocument::fromJson(query.value(0).toByteArray()).object(),query.value(4).toLongLong(),bound);
        event.insert(QStringLiteral("delivery_state"), query.value(1).toString());
        if (!query.value(2).isNull()) event.insert(QStringLiteral("rejection_reason"), query.value(2).toString());
        if (!query.value(3).isNull()) event.insert(QStringLiteral("acknowledged_at"), query.value(3).toString());
        result.append(event);
    }
    return result;
}

bool CameraAvailabilityJournal::maintenance(const QDateTime &nowUtc, int retentionDays,
                                            qint64 acknowledgedRowLimit, qint64 databaseByteLimit)
{
    if (!isOpen() || !validTime(nowUtc)) return fail(QStringLiteral("database_unavailable"));
    retentionDays = std::clamp(retentionDays, 0, 3650);
    acknowledgedRowLimit = std::clamp<qint64>(acknowledgedRowLimit, 0, 10000000);
    databaseByteLimit = std::max<qint64>(databaseByteLimit, 1048576);
    m_capacityBytes = databaseByteLimit;
    if ((retentionDays > 0 || acknowledgedRowLimit > 0) && !begin()) return false;
    // Delete inactive envelopes first; active retries must retain every member,
    // including already acknowledged members of a partial response.
    QSqlQuery oldBatches(m_db);
    oldBatches.prepare(QStringLiteral("DELETE FROM batches WHERE state<>'pending' AND created_at<?"));
    oldBatches.addBindValue(instant(nowUtc.addDays(-retentionDays)));
    if (retentionDays > 0 && !oldBatches.exec()) { fail(sqlCode(oldBatches.lastError())); rollback(); return false; }
    const QString protectedRows = QStringLiteral(
        " AND event_id NOT IN (SELECT last_event_id FROM conditions UNION SELECT failure_event_id FROM conditions WHERE failure_event_id IS NOT NULL)"
        " AND event_id NOT IN (SELECT event_id FROM batch_events)");
    QSqlQuery aged(m_db);
    aged.prepare(QStringLiteral("DELETE FROM events WHERE delivery IN ('acknowledged','native') AND observed_at<?") + protectedRows);
    aged.addBindValue(instant(nowUtc.addDays(-retentionDays)));
    if (retentionDays > 0 && !aged.exec()) { fail(sqlCode(aged.lastError())); rollback(); return false; }
    QSqlQuery excess(m_db);
    excess.prepare(QStringLiteral("DELETE FROM events WHERE event_id IN (SELECT event_id FROM events WHERE delivery IN ('acknowledged','native') "
                                  "ORDER BY local_seq DESC LIMIT -1 OFFSET ?)") + protectedRows);
    excess.addBindValue(acknowledgedRowLimit);
    if (acknowledgedRowLimit > 0 && !excess.exec()) { fail(sqlCode(excess.lastError())); rollback(); return false; }
    if ((retentionDays > 0 || acknowledgedRowLimit > 0) && !commit()) return false;
    if (!reclaimWal(true)) return false;
    const qint64 bytes = QFileInfo(m_path).size() + QFileInfo(m_path + QStringLiteral("-wal")).size();
    if (bytes > databaseByteLimit) return fail(QStringLiteral("storage_capacity_exceeded"), QStringLiteral("capacity_exceeded"));
    clearError();
    return true;
}
