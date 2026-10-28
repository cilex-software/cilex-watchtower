#include "CameraAvailabilityWorker.h"
#include "CameraAvailabilityJournal.h"
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QThread>
#include <QTimer>
#include <QUrlQuery>
#include <QUuid>

namespace {
bool uuid(const QString &s) { return !QUuid(s).isNull(); }
QString roleName(QString s) { return s.trimmed().toLower(); }
bool stationRows(const QString &role) { return role == "admin" || role == "owner"; }
QString safeBase(const QString &text) {
    const QUrl u(text.trimmed());
    if (!u.isValid() || (u.scheme() != "http" && u.scheme() != "https") || u.host().isEmpty()
        || !u.userInfo().isEmpty() || u.hasQuery() || u.hasFragment()) return {};
    return u.toString(QUrl::FullyEncoded).remove(QRegularExpression("/+$"));
}
}

CameraAvailabilityWorker::CameraAvailabilityWorker(const QString &path) : m_path(path) {}
CameraAvailabilityWorker::CameraAvailabilityWorker(const QString &path, const Options &options)
    : m_options(options), m_path(path) {}
CameraAvailabilityWorker::~CameraAvailabilityWorker() = default;
QDateTime CameraAvailabilityWorker::now() const
{ return m_options.nowUtc ? m_options.nowUtc().toUTC() : QDateTime::currentDateTimeUtc(); }

void CameraAvailabilityWorker::initialize()
{
    m_clock.start();
    if (m_path.isEmpty()) m_path = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
        + QStringLiteral("/availability/availability.sqlite3");
    m_journal = std::make_unique<CameraAvailabilityJournal>();
    if (!m_journal->open(m_path, now())) {
        m_state = "storage_error"; m_reason = m_journal->error(); publish(); return;
    }
    m_nam = new QNetworkAccessManager(this);
    m_timer = new QTimer(this);
    m_timer->setInterval(1000);
    connect(m_timer, &QTimer::timeout, this, &CameraAvailabilityWorker::tick);
    if (m_options.timerEnabled) m_timer->start();
    publish();
}

bool CameraAvailabilityWorker::readProvisioning()
{
    // Use this account's existing station provisioning. No user/display token
    // can substitute for the long-lived station ingest credential.
    const bool explicitFile = !m_options.provisioningFile.isEmpty();
    QString token = explicitFile ? QString{} : qEnvironmentVariable("WT_WARDEN_STATION_TOKEN").trimmed();
    if (!explicitFile && token.isEmpty()) token = qEnvironmentVariable("WT_STATION_TOKEN").trimmed();
    QString configuredBase;
    QStringList paths{QDir::homePath() + "/.config/watchtower-warden/warden.conf"};
    const QString extra = qEnvironmentVariable("WT_WARDEN_CONFIG_FILE");
    if (QDir::isAbsolutePath(extra)) paths.append(extra);
    if (!m_options.provisioningFile.isEmpty()) paths = {m_options.provisioningFile};
    for (const auto &path : paths) {
        QFile f(path);
        if (!f.open(QIODevice::ReadOnly) || f.size() > 262144) continue;
        const auto lines = QString::fromUtf8(f.readAll()).split('\n');
        for (QString line : lines) {
            if (line.startsWith(QChar(0xfeff))) line.remove(0, 1);
            line = line.trimmed(); if (line.startsWith('#')) continue;
            const int equal = line.indexOf('='); if (equal < 1) continue;
            const QString key = line.left(equal).trimmed(), value = line.mid(equal + 1).trimmed();
            if (key == "STATION_TOKEN" && (explicitFile || (qEnvironmentVariableIsEmpty("WT_WARDEN_STATION_TOKEN")
                && qEnvironmentVariableIsEmpty("WT_STATION_TOKEN")))) token = value;
            if (key == "BACKEND_URL") configuredBase = value;
        }
    }
    const QString provisionedBase = safeBase(configuredBase);
    QString base = safeBase(m_requestedBase.isEmpty() ? configuredBase : m_requestedBase);
    const bool destinationConflict = !provisionedBase.isEmpty() && base != provisionedBase;
    if (token.size() > 4096 || token.contains('\r') || token.contains('\n')) token.clear();
    const QString context = QString::fromLatin1(QCryptographicHash::hash(
        base.toUtf8() + '\0' + provisionedBase.toUtf8() + '\0' + token.toUtf8(), QCryptographicHash::Sha256).toHex());
    if (context == m_context) return false;
    m_contextReady = false;
    ++m_generation;
    if (m_reply) { auto old = m_reply; m_reply.clear(); old->abort(); }
    if (!m_context.isEmpty() && !m_journal->endRun(now(), m_clock.elapsed())) { storageFailure(); return true; }
    m_base = base; m_stationToken = token; m_context = context;
    m_bound = false; m_blocked = false; m_cycle = false; m_nativeBacklog = false; m_backendId.clear(); m_stationId.clear();
    m_grantedCameras.clear(); m_retiredPipelines.clear(); m_batch = {}; m_failures = 0; m_notBefore = 0; m_retryUntil = {};
    m_backendWasUnavailable = false; m_nativeRefreshPending = false;
    if (!m_journal->selectContext(context, now()) || m_journal->startRun(now(), m_clock.elapsed()).isEmpty()) {
        m_context.clear(); m_blocked = true;
        m_state = "storage_error"; m_reason = m_journal->error(); publish(); return true;
    }
    m_contextReady = true;
    if (destinationConflict) { m_state = "conflict"; m_reason = "provisioned_destination_mismatch"; m_blocked = true; }
    else if (!token.isEmpty() && provisionedBase.isEmpty()) { m_state = "provisioning_required"; m_reason = "station_destination_required"; m_blocked = true; }
    else if (base.isEmpty() || token.isEmpty()) { m_state = "provisioning_required"; m_reason = "station_credentials_required"; }
    else {
        const auto persisted = m_journal->status(now());
        const auto error = persisted.value("syncError").toString();
        if (error == "station_credential_rejected") {
            m_state = "auth_required"; m_reason = error; m_blocked = true;
        } else {
            if (error == "rate_limited" || error == "backend_unavailable")
                m_retryUntil = QDateTime::fromString(persisted.value("nextSyncAt").toString(), Qt::ISODateWithMs);
            if (m_retryUntil.isValid() && now() < m_retryUntil) {
                m_state = error == "rate_limited" ? "rate_limited" : "degraded"; m_reason = error;
            } else { m_state = "discovering"; m_reason.clear(); discover(); }
        }
    }
    return true;
}

void CameraAvailabilityWorker::configure(const QString &baseUrl, bool authenticated,
                                       const QString &role, const QStringList &scope, quint64 viewGeneration)
{
    m_requestedBase = baseUrl;
    m_authenticated = authenticated; m_role = roleName(role); m_cameraScope = scope;
    m_viewGeneration = viewGeneration;
    emit historyReady({}, m_viewGeneration);
    if (m_journal && m_journal->isOpen()) readProvisioning();
    publish();
}

void CameraAvailabilityWorker::observe(const QVariantMap &fields)
{
    if (m_stopping || !m_journal || !m_journal->isOpen() || !m_contextReady) { ++m_lostObservations; publish(); return; }
    if (!recordContinuity()) { ++m_lostObservations; return; }
    QJsonObject event = QJsonObject::fromVariantMap(fields);
    const auto details = event.value("details").toObject();
    const QString pipeline = details.value("pipeline_id").toString();
    const QString transition = event.value("transition").toString();
    const QString observerScope = details.value("observer_scope").toString();
    if (!pipeline.isEmpty() && (observerScope == "pipeline" || observerScope == "snapshot_request")) {
        if (event.value("domain").toString() == "monitoring") {
            if (transition == "monitoring_gap") {
                m_retiredPipelines.insert(pipeline, m_clock.elapsed());
                // Lifecycle publishers already fence late callbacks. Keep an
                // additional bounded queue fence for recently retired sources.
                if (m_retiredPipelines.size() > 4096) {
                    auto oldest = m_retiredPipelines.begin();
                    for (auto it = m_retiredPipelines.begin(); it != m_retiredPipelines.end(); ++it)
                        if (it.value() < oldest.value()) oldest = it;
                    m_retiredPipelines.erase(oldest);
                }
            }
            if (transition == "monitoring_resumed") m_retiredPipelines.remove(pipeline);
        } else if (m_retiredPipelines.contains(pipeline)) return;
    }
    const QDateTime observed = QDateTime::fromString(event.value("observed_at").toString(), Qt::ISODateWithMs);
    const qint64 monotonic = event.value("monotonic_ms").isDouble()
        ? qint64(event.value("monotonic_ms").toDouble()) : m_clock.elapsed();
    const auto id = m_journal->observe(event, observed.isValid() ? observed.toUTC() : now(), monotonic);
    if (id.isEmpty() && !m_journal->error().isEmpty()) { ++m_lostObservations; storageFailure(); return; }
    if (event.value("domain") == "backend_connectivity") {
        if (event.value("state") == "available") {
            if (m_backendWasUnavailable) m_nativeRefreshPending = true;
            m_backendWasUnavailable = false;
        } else m_backendWasUnavailable = true;
    }
    publish();
    serviceNativeRefresh();
}

void CameraAvailabilityWorker::tick()
{
    if (m_stopping || !m_journal || !m_journal->isOpen()) return;
    const qint64 elapsed = m_clock.elapsed();
    if (!recordContinuity()) return;
    if (elapsed - m_lastProvisioning >= 60000) { m_lastProvisioning = elapsed; readProvisioning(); }
    serviceNativeRefresh();
    if (!m_reply && !m_blocked && elapsed >= m_notBefore && m_journal->syncDue(now())) synchronize();
}

bool CameraAvailabilityWorker::recordContinuity()
{
    const qint64 elapsed = m_clock.elapsed();
    const auto wall = now();
    const qint64 monotonicDelta = m_continuityMono < 0 ? 0 : elapsed - m_continuityMono;
    const qint64 wallDelta = m_continuityWall.isValid() ? m_continuityWall.msecsTo(wall) : monotonicDelta;
    const bool gapDetected = m_continuityMono >= 0 && (monotonicDelta < 0 || monotonicDelta > 30000
        || wallDelta < 0 || qAbs(wallDelta - monotonicDelta) > 30000);
    m_continuityMono = elapsed; m_continuityWall = wall;
    if (gapDetected && m_contextReady) {
        // A stopped event loop / suspend is an observation gap, never a camera outage.
        QJsonObject gap{{"domain", "monitoring"}, {"provenance", "client_observed"},
            {"state", "unknown"}, {"transition", "monitoring_gap"}, {"reason_code", "observation_gap"},
            {"details", QJsonObject{{"observer_scope", "monitoring"}}}};
        if (m_journal->observe(gap, wall, elapsed).isEmpty() && !m_journal->error().isEmpty()) { storageFailure(); return false; }
        gap["transition"] = "monitoring_resumed"; gap["reason_code"] = "monitor_resumed";
        if (m_journal->observe(gap, wall, elapsed).isEmpty() && !m_journal->error().isEmpty()) { storageFailure(); return false; }
    }
    return true;
}

void CameraAvailabilityWorker::synchronize()
{
    if (m_stopping || !m_journal || !m_journal->isOpen() || !m_contextReady || m_reply || m_cycle) return;
    if (m_reason == "provisioned_destination_mismatch" || m_reason == "station_destination_required"
        || m_state == "auth_required" || m_state == "conflict" || m_state == "protocol_error") { publish(); return; }
    m_blocked = false;
    if (m_base.isEmpty() || m_stationToken.isEmpty()) { m_state = "provisioning_required"; publish(); return; }
    if (m_clock.elapsed() < m_notBefore || (m_retryUntil.isValid() && now() < m_retryUntil)) { publish(); return; }
    m_cycle = true; m_cycleBatches = 0; m_feedPages = 0;
    if (!m_journal->recordAttempt(now())) { storageFailure(); return; }
    discover();
}

void CameraAvailabilityWorker::discover()
{
    if (!m_reply && m_nam) request("capabilities", "/client/stations/camera-availability/capabilities");
}

void CameraAvailabilityWorker::request(const QString &kind, const QString &path, const QByteArray &body)
{
    if (m_reply || m_stopping) return;
    QNetworkRequest req{QUrl(m_base + path)};
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    req.setTransferTimeout(12000);
    req.setRawHeader("Accept", "application/json");
    req.setRawHeader("X-Cilex-Station-Token", m_stationToken.toUtf8());
    if (!body.isEmpty()) req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    auto *reply = body.isEmpty() ? m_nam->get(req) : m_nam->post(req, body);
    m_reply = reply;
    const quint64 generation = m_generation;
    // Never accumulate an unbounded response in memory.
    connect(reply, &QIODevice::readyRead, this, [reply] { if (reply->bytesAvailable() > 4 * 1048576) reply->abort(); });
    connect(reply, &QNetworkReply::finished, this, [this, kind, reply, generation] { received(kind, reply, generation); });
    m_state = m_cycle ? "syncing" : "discovering";
    publish();
}

void CameraAvailabilityWorker::failNetwork(const QString &state, const QString &reason, QNetworkReply *reply)
{
    m_state = state; m_reason = reason; m_cycle = false;
    const bool blocked = state == "auth_required" || state == "scope_required" || state == "conflict"
        || state == "unsupported" || state == "protocol_error";
    m_blocked = blocked;
    int retrySeconds = qMin(10800, 30 * (1 << qMin(++m_failures, 8))) + int(QRandomGenerator::global()->bounded(20));
    if (reply) {
        const auto value = reply->rawHeader("Retry-After");
        bool ok = false; const int seconds = value.toInt(&ok);
        if (ok && seconds >= 0) retrySeconds = qBound(1, seconds, 86400);
        else {
            const auto date = QDateTime::fromString(QString::fromLatin1(value), Qt::RFC2822Date);
            if (date.isValid()) retrySeconds = int(qBound<qint64>(qint64(1), now().secsTo(date), qint64(86400)));
        }
    }
    // If SQLite cannot persist the backoff, the process-local monotonic fence
    // still prevents one request per timer tick. Evidence remains disk-only.
    m_notBefore = m_clock.elapsed() + qint64(blocked ? 10800 : retrySeconds) * 1000;
    m_retryUntil = blocked ? QDateTime{} : now().addSecs(retrySeconds);
    if (!m_journal->recordFailure(reason, now().addSecs(blocked ? 10800 : retrySeconds))) { storageFailure(); return; }
    m_notBefore = 0;
    publish();
}

void CameraAvailabilityWorker::storageFailure()
{
    m_cycle = false; m_state = "storage_error"; m_reason = m_journal ? m_journal->error() : "storage_unavailable";
    m_notBefore = qMax(m_notBefore, m_clock.elapsed() + 60000);
    publish();
}

void CameraAvailabilityWorker::received(const QString &kind, QNetworkReply *reply, quint64 generation)
{
    reply->deleteLater();
    if (generation != m_generation || m_stopping) return;
    if (m_reply == reply) m_reply.clear();
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QByteArray bytes = reply->readAll();
    QJsonParseError parse;
    const auto doc = QJsonDocument::fromJson(bytes, &parse);
    const auto object = doc.object();
    if (status < 200 || status >= 300 || reply->error() != QNetworkReply::NoError) {
        if (status == 401) { failNetwork("auth_required", "station_credential_rejected"); return; }
        if (status == 403) { failNetwork("scope_required", "station_scope_denied"); return; }
        if (status == 409) { failNetwork("conflict", "destination_or_event_conflict"); return; }
        if (status == 404 || status == 405 || status == 501) { failNetwork("unsupported", "availability_contract_unsupported"); return; }
        if (kind == "batch" && (status == 413 || status == 422)) {
            const auto events = m_batch.value("events").toArray();
            if (!m_journal->abandonBatch(status == 413 ? "oversize" : "invalid_event", now())) {
                failNetwork("storage_error", m_journal->error()); return;
            }
            if (events.size() <= 1) {
                QStringList ids;
                for (auto e : events) ids.append(e.toObject().value("event_id").toString());
                if (!m_journal->rejectEvents(ids, status == 413 ? "event_oversize" : "event_rejected", now())) { storageFailure(); return; }
            } else m_maxEvents = qMax(1, int(events.size() / 2));
            m_batch = {};
            QTimer::singleShot(m_options.batchDelayMs, this, &CameraAvailabilityWorker::uploadNext);
            publish(); return;
        }
        failNetwork(status == 429 ? "rate_limited" : "degraded", status == 429 ? "rate_limited" : "backend_unavailable", reply);
        return;
    }
    if (parse.error != QJsonParseError::NoError || !doc.isObject() || bytes.size() > 4 * 1048576) {
        failNetwork("protocol_error", "invalid_response"); return;
    }
    if (kind == "capabilities") {
        const auto versions = object.value("supported_schema_versions").toArray();
        const auto scope = object.value("scope").toObject();
        const QString backend = object.value("backend_instance_id").toString();
        const QString station = object.value("reporter_station_id").toString();
        if (object.value("schema_version").toInt() != 1 || !versions.contains(1)
            || !uuid(backend) || !uuid(station)) { failNetwork("unsupported", "availability_contract_unsupported"); return; }
        if (!object.value("scope_configured").toBool() || !scope.value("configured").toBool()
            || scope.value("station_id").toString() != station || !scope.value("camera_ids").isArray()
            || (scope.value("camera_ids").toArray().isEmpty() && !scope.value("allow_station_events").toBool())) {
            failNetwork("scope_required", "scope_not_configured"); return;
        }
        if (!m_journal->bind(backend, station, now())) { failNetwork("conflict", "destination_identity_mismatch"); return; }
        m_backendId = backend; m_stationId = station; m_bound = true;
        m_grantedCameras.clear();
        for (auto id : scope.value("camera_ids").toArray()) m_grantedCameras.insert(id.toString());
        m_allowStation = scope.value("allow_station_events").toBool();
        const auto limits = object.value("limits").toObject();
        const int eventLimit = limits.value("max_events").toInt();
        const int byteLimit = limits.value("max_body_bytes").toInt();
        if (eventLimit < 1 || byteLimit < 1024) { failNetwork("protocol_error", "invalid_capability_limits"); return; }
        m_maxEvents = qMin(500, eventLimit); m_maxBytes = qMin(1048576, byteLimit);
        m_state = "ready"; m_reason.clear(); m_failures = 0; m_retryUntil = {};
        // Poll missed native transitions even when the first scheduled upload is not due.
        m_feedPages = 0; fetchChanges(); return;
    }
    if (object.value("backend_instance_id").toString() != m_backendId
        || object.value("reporter_station_id").toString() != m_stationId
        || object.value("schema_version").toInt() != 1) {
        failNetwork("conflict", "response_identity_mismatch"); return;
    }
    if (kind == "changes") {
        const auto nextValue = object.value("next_cursor"), resumeValue = object.value("resume_cursor");
        if (!object.value("events").isArray() || object.value("events").toArray().size() > 500
            || (nextValue.toString().isEmpty() && !resumeValue.isString())
            || (!object.value("next_cursor").isNull() && !object.value("next_cursor").isString())) {
            failNetwork("protocol_error", "invalid_native_feed"); return;
        }
        const QString next = object.value("next_cursor").toString();
        const QString cursor = next.isEmpty() ? object.value("resume_cursor").toString() : next;
        if (cursor.isEmpty() || cursor.size() > 8192 || (!next.isEmpty() && cursor == m_journal->nativeCursor())) {
            failNetwork("protocol_error", "native_cursor_not_committed"); return;
        }
        if (!m_journal->importNative(object.value("events").toArray(), cursor, now())) {
            const auto error = m_journal->error();
            if (error.startsWith("sqlite_") || error.startsWith("storage_") || error == "database_unavailable") storageFailure();
            else failNetwork("protocol_error", "native_cursor_not_committed");
            return;
        }
        if (!next.isEmpty() && ++m_feedPages < 20) { fetchChanges(); return; }
        m_nativeBacklog = !next.isEmpty();
        // Large fixed snapshots resume safely at the stored next_cursor later.
        if (m_cycle) uploadNext();
        else {
            m_state = m_nativeBacklog ? "backlog_pending" : "ready";
            if (m_nativeBacklog && !m_journal->setNextSyncDue(now().addSecs(90))) { storageFailure(); return; }
            publish(); if (m_journal->syncDue(now())) synchronize();
        }
        return;
    }
    if (kind == "batch") {
        if (!m_journal->applyAck(object, now())) { failNetwork("protocol_error", m_journal->error()); return; }
        m_uploadCount += m_batch.value("events").toArray().size(); m_batch = {};
        ++m_cycleBatches;
        QTimer::singleShot(m_options.batchDelayMs, this, &CameraAvailabilityWorker::uploadNext);
        publish();
    }
}

void CameraAvailabilityWorker::fetchChanges()
{
    if (!m_bound || m_reply || m_stopping) return;
    QUrlQuery query; query.addQueryItem("limit", "500");
    const auto cursor = m_journal->nativeCursor();
    if (!cursor.isEmpty()) query.addQueryItem("cursor", cursor);
    request("changes", "/client/stations/camera-availability/changes?" + query.toString(QUrl::FullyEncoded));
}

void CameraAvailabilityWorker::serviceNativeRefresh()
{
    if (!m_nativeRefreshPending || !m_bound || !m_contextReady || m_reply || m_cycle || m_stopping || m_blocked
        || m_clock.elapsed() < m_notBefore || (m_retryUntil.isValid() && now() < m_retryUntil)) return;
    m_nativeRefreshPending = false; m_feedPages = 0;
    fetchChanges(); // Reconnect catch-up does not advance the three-hour upload schedule.
}

void CameraAvailabilityWorker::uploadNext()
{
    if (m_stopping || m_reply || !m_cycle || !m_bound) return;
    if (m_cycleBatches >= 16) {
        if (!m_journal->setNextSyncDue(now().addSecs(90))) { storageFailure(); return; }
        m_cycle = false; m_state = "backlog_pending"; publish(); return;
    }
    m_batch = m_journal->prepareBatch(m_maxEvents, m_maxBytes, now());
    if (m_batch.isEmpty()) {
        if (!m_journal->error().isEmpty()) { failNetwork("storage_error", m_journal->error()); return; }
        finishCycle(); return;
    }
    // Scope removals retain old pending evidence, never send it to a different scope.
    QStringList outOfScope;
    for (auto value : m_batch.value("events").toArray()) {
        const auto event = value.toObject();
        if ((event.value("camera_id").isNull() && !m_allowStation)
            || (!event.value("camera_id").isNull() && !m_grantedCameras.contains(event.value("camera_id").toString())))
            outOfScope.append(event.value("event_id").toString());
    }
    if (!outOfScope.isEmpty()) {
        if (!m_journal->abandonBatch("scope_changed", now())
            || !m_journal->rejectEvents(outOfScope, "scope_changed", now())) { storageFailure(); return; }
        QTimer::singleShot(0, this, &CameraAvailabilityWorker::uploadNext); return;
    }
    request("batch", "/client/stations/camera-availability/batches", m_journal->batchPayload());
}

void CameraAvailabilityWorker::finishCycle()
{
    m_cycle = false; m_state = m_nativeBacklog ? "backlog_pending" : "ready"; m_reason.clear(); m_failures = 0;
    if (!m_journal->setNextSyncDue(m_nativeBacklog ? now().addSecs(90)
        : now().addMSecs(CameraAvailabilityJournal::SyncIntervalMs))
        || !m_journal->maintenance(now(), 0, 0)) { storageFailure(); return; }
    publish(); loadHistory(m_historyCamera, m_historyFrom, m_historyUntil);
}

void CameraAvailabilityWorker::publish()
{
    QVariantMap s = m_journal && m_contextReady ? m_journal->status(now()).toVariantMap() : QVariantMap{};
    s["state"] = m_state; s["blockingReason"] = m_reason; s["busy"] = bool(m_reply) || m_cycle;
    s["automaticIntervalMinutes"] = 180; s["uploadedCount"] = m_uploadCount;
    s["lostObservationCount"] = m_lostObservations;
    emit stateReady(s);
}

bool CameraAvailabilityWorker::authorizedForHistory(const QString &cameraId) const
{
    if (!m_authenticated || m_role == "station") return false;
    if (stationRows(m_role)) return true;
    return !cameraId.isEmpty() && m_cameraScope.contains(cameraId);
}

void CameraAvailabilityWorker::loadHistory(const QString &cameraId, const QString &from, const QString &until)
{
    m_historyCamera = cameraId; m_historyFrom = from; m_historyUntil = until;
    if (!m_journal || !m_journal->isOpen() || !m_contextReady || !m_authenticated || m_role == "station") { emit historyReady({}, m_viewGeneration); return; }
    QDateTime a = QDateTime::fromString(from, Qt::ISODateWithMs), b = QDateTime::fromString(until, Qt::ISODateWithMs);
    if (!a.isValid()) a = now().addDays(-7);
    if (!b.isValid()) b = now().addSecs(1);
    if (a >= b || a.msecsTo(b) > 31LL * 86400000 || (!cameraId.isEmpty() && !authorizedForHistory(cameraId))) { emit historyReady({}, m_viewGeneration); return; }
    QVariantList rows;
    for (auto value : m_journal->history(cameraId, a, b, 1000,
                                       stationRows(m_role) ? QStringList{} : m_cameraScope, stationRows(m_role))) {
        const auto row = value.toObject();
        if (authorizedForHistory(row.value("camera_id").toString())) rows.append(row.toVariantMap());
    }
    emit historyReady(rows, m_viewGeneration);
}

void CameraAvailabilityWorker::stop()
{
    if (m_stopping) return;
    m_stopping = true; ++m_generation;
    if (m_timer) m_timer->stop();
    if (m_reply) { auto reply = m_reply; m_reply.clear(); reply->abort(); }
    if (m_journal) { m_journal->endRun(now(), m_clock.elapsed()); m_journal.reset(); }
    emit finished();
}
