#include "CameraAvailabilityJournal.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QProcess>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QTextStream>
#include <QUuid>
#include <cstdlib>

namespace {
int passed = 0, failed = 0;
const QString backend = QStringLiteral("11111111-1111-4111-8111-111111111111");
const QString station = QStringLiteral("22222222-2222-4222-8222-222222222222");
const QDateTime base = QDateTime::fromString(QStringLiteral("2026-10-29T12:00:00.000Z"), Qt::ISODateWithMs);
void check(bool condition, const char *name)
{
    QTextStream out(stdout);
    out << (condition ? "PASS " : "FAIL ") << name << Qt::endl;
    if (condition) ++passed; else ++failed;
}
QJsonObject observation(const QString &state, const QString &pipeline = QStringLiteral("wall-01"))
{
    return {{QStringLiteral("camera_id"),QStringLiteral("camera-01")},
        {QStringLiteral("domain"),QStringLiteral("live_delivery")},
        {QStringLiteral("provenance"),QStringLiteral("client_observed")},
        {QStringLiteral("state"),state}, {QStringLiteral("reason_code"),QStringLiteral("frame_received")},
        {QStringLiteral("details"),QJsonObject {{QStringLiteral("stream_variant"),QStringLiteral("sub")},
            {QStringLiteral("transport"),QStringLiteral("rtsp")},{QStringLiteral("observer_scope"),QStringLiteral("pipeline")},
            {QStringLiteral("pipeline_id"),pipeline}}}};
}
bool setup(CameraAvailabilityJournal &journal, const QString &path, const QString &context = QStringLiteral("test-context"))
{
    return journal.open(path,base) && journal.selectContext(context,base)
        && journal.bind(backend,station,base) && !journal.startRun(base,0).isEmpty();
}
QJsonObject ackFor(const QJsonObject &batch, bool duplicate = false)
{
    QJsonArray ids;
    for (const auto &v : batch.value(QStringLiteral("events")).toArray())
        ids.append(v.toObject().value(QStringLiteral("event_id")));
    return {{QStringLiteral("schema_version"),1},{QStringLiteral("batch_id"),batch.value(QStringLiteral("batch_id"))},
        {QStringLiteral("backend_instance_id"),backend},{QStringLiteral("reporter_station_id"),station},
        {QStringLiteral("server_received_at"),QStringLiteral("2026-10-29T12:00:01.000Z")},
        {QStringLiteral("accepted_event_ids"),duplicate ? QJsonArray() : ids},
        {QStringLiteral("duplicate_event_ids"),duplicate ? ids : QJsonArray()}};
}
QJsonObject eventById(const CameraAvailabilityJournal &journal, const QString &id)
{
    for (const auto &v : journal.history({}, {}, {},1000))
        if (v.toObject().value(QStringLiteral("event_id")).toString() == id) return v.toObject();
    return {};
}
QSqlDatabase journalDb()
{
    for (const auto &name : QSqlDatabase::connectionNames())
        if (name.startsWith(QStringLiteral("availability-"))) return QSqlDatabase::database(name);
    return {};
}
QJsonObject nativeEvent()
{
    return {{QStringLiteral("event_id"),QStringLiteral("99999999-9999-4999-8999-999999999999")},
        {QStringLiteral("run_id"),QStringLiteral("88888888-8888-4888-8888-888888888888")},
        {QStringLiteral("producer_id"),QStringLiteral("77777777-7777-4777-8777-777777777777")},
        {QStringLiteral("local_seq"),1},{QStringLiteral("camera_id"),QStringLiteral("camera-01")},
        {QStringLiteral("domain"),QStringLiteral("backend_reachability")},
        {QStringLiteral("provenance"),QStringLiteral("backend_native")},
        {QStringLiteral("origin"),QStringLiteral("backend_native")},
        {QStringLiteral("state"),QStringLiteral("available")},{QStringLiteral("transition"),QStringLiteral("initial")},
        {QStringLiteral("observed_at"),QStringLiteral("2026-10-29T11:59:00.000Z")},
        {QStringLiteral("reason_code"),QStringLiteral("initial_observation")},
        {QStringLiteral("backend_instance_id"),backend},{QStringLiteral("reporter_station_id"),QJsonValue::Null},
        {QStringLiteral("position"),1},{QStringLiteral("site_id"),QJsonValue::Null},
        {QStringLiteral("server_received_at"),QStringLiteral("2026-10-29T11:59:01.000Z")},
        {QStringLiteral("clock_quality"),QJsonObject{{QStringLiteral("authority"),QStringLiteral("backend_observed")},{QStringLiteral("flags"),QJsonArray()}}},
        {QStringLiteral("relationship_status"),QStringLiteral("none")},
        {QStringLiteral("relationship_authority"),QStringLiteral("backend_native")},
        {QStringLiteral("upstream_reference_status"),QStringLiteral("not_supplied")},
        {QStringLiteral("condition_status"),QStringLiteral("not_applicable")},
        {QStringLiteral("condition_status_authority"),QStringLiteral("backend_native")}};
}
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc,argv);
    if (app.arguments().value(1) == QLatin1String("--abrupt-child")) {
        const auto path = app.arguments().value(2);
        CameraAvailabilityJournal journal;
        if (!setup(journal,path)
            || journal.observe(observation(QStringLiteral("available")),base,1).isEmpty()
            || journal.observe(observation(QStringLiteral("unavailable")),base.addSecs(1),1001).isEmpty()
            || journal.prepareBatch(500,1048576,base).isEmpty()) return 90;
        QFile witness(path + QStringLiteral(".payload"));
        if (!witness.open(QIODevice::WriteOnly) || witness.write(journal.batchPayload()) < 1 || !witness.flush()) return 91;
        witness.close();
        // Isolated fixture only: bypass all destructors to exercise committed
        // WAL recovery after process loss, without touching a running station.
        std::_Exit(0);
    }
    QTemporaryDir temporary;
    check(temporary.isValid(),"temporary fixtures directory");
    {
        const auto path = temporary.filePath(QStringLiteral("abrupt.sqlite"));
        QProcess child;
        child.start(QCoreApplication::applicationFilePath(),{QStringLiteral("--abrupt-child"),path});
        check(child.waitForStarted(10000) && child.waitForFinished(15000) && child.exitCode() == 0,
              "isolated child committed then exited without journal cleanup");
        QFile witness(path + QStringLiteral(".payload")); witness.open(QIODevice::ReadOnly);
        const auto payload = witness.readAll();
        CameraAvailabilityJournal journal;
        check(journal.open(path,base) && journal.selectContext(QStringLiteral("test-context"),base)
              && journal.bind(backend,station,base) && !journal.prepareBatch(500,1048576,base).isEmpty()
              && journal.batchPayload() == payload && journal.status(base).value(QStringLiteral("pendingCount")).toInteger() == 3,
              "abrupt process exit preserves committed events and exact retry bytes");
    }
    {
        CameraAvailabilityJournal journal;
        const auto path = temporary.filePath(QStringLiteral("durable.sqlite"));
        check(setup(journal,path),"QSQLITE open schema WAL commit");
        auto db = journalDb();
        QSqlQuery pragma(db);
        check(pragma.exec(QStringLiteral("PRAGMA journal_mode")) && pragma.next()
              && pragma.value(0).toString() == QLatin1String("wal"),"WAL durability mode");
        check(pragma.exec(QStringLiteral("PRAGMA synchronous")) && pragma.next()
              && pragma.value(0).toInt() == 2,"FULL synchronous durability");
        const auto baseline = journal.observe(observation(QStringLiteral("available")),base.addSecs(1),1000);
        const auto failure = journal.observe(observation(QStringLiteral("unavailable")),base.addSecs(2),2000);
        check(!baseline.isEmpty() && !failure.isEmpty(),"baseline and failure committed");
        check(journal.observe(observation(QStringLiteral("unavailable")),base.addSecs(3),3000).isEmpty()
              && journal.error().isEmpty(),"same-state polling deduplicated");
        auto warning = observation(QStringLiteral("degraded"));
        const auto escalation = journal.observe(warning,base.addSecs(4),4000);
        const auto recovery = journal.observe(observation(QStringLiteral("available")),base.addSecs(7),7000);
        const auto recovered = eventById(journal,recovery);
        check(!escalation.isEmpty() && recovered.value(QStringLiteral("transition")).toString() == QLatin1String("recovery")
              && recovered.value(QStringLiteral("duration_ms")).toInteger() == 5000
              && recovered.value(QStringLiteral("related_event_id")).toString() == failure,
              "recovery pairs original failure and same-run duration");
        const auto secondFailure = journal.observe(observation(QStringLiteral("unavailable")),base.addSecs(8),8000);
        check(eventById(journal,secondFailure).value(QStringLiteral("condition_id"))
              != eventById(journal,failure).value(QStringLiteral("condition_id")),"separate incidents have separate condition IDs");
        const auto independent = journal.observe(observation(QStringLiteral("available"),QStringLiteral("detail-02")),base.addSecs(9),9000);
        check(eventById(journal,independent).value(QStringLiteral("transition")).toString() == QLatin1String("initial"),
              "independent observer cannot recover another source");
        const auto priorHistory = journal.status(base).value(QStringLiteral("historyCount")).toInteger();
        const auto batch = journal.prepareBatch(500,1048576,base);
        const auto bytes = journal.batchPayload();
        check(!batch.isEmpty() && bytes == journal.batchPayload(),"immutable batch persisted before sending");
        check(journal.prepareBatch(500,1048576,base.addSecs(10)) == batch && journal.batchPayload() == bytes,
              "lost response retries identical ordered payload");
        const QString producer = batch.value(QStringLiteral("producer_id")).toString();
        db = {}; pragma = QSqlQuery();
        journal.close();
        check(journal.open(path,base.addSecs(20)) && journal.selectContext(QStringLiteral("test-context"),base)
              && journal.bind(backend,station,base),"reopen durable bound scope");
        check(journal.prepareBatch(500,1048576,base) == batch && journal.batchPayload() == bytes
              && journal.status(base).value(QStringLiteral("producerId")).toString() == producer,
              "restart preserves producer batch IDs and bytes");
        check(journal.status(base).value(QStringLiteral("historyCount")).toInteger() == priorHistory,
              "restart preserves pending history");
        check(!journal.startRun(base.addSecs(20),0).isEmpty(),"new monitoring run committed");
        const auto afterGap = journal.observe(observation(QStringLiteral("available")),base.addSecs(21),1000);
        check(eventById(journal,afterGap).value(QStringLiteral("transition")).toString() == QLatin1String("initial")
              && !eventById(journal,afterGap).contains(QStringLiteral("duration_ms")),
              "restart gap does not manufacture recovery or duration");
        auto malformed = ackFor(batch);
        malformed.insert(QStringLiteral("reporter_station_id"),QStringLiteral("33333333-3333-4333-8333-333333333333"));
        const auto pendingBefore = journal.status(base).value(QStringLiteral("pendingCount"));
        check(!journal.applyAck(malformed,base) && journal.status(base).value(QStringLiteral("pendingCount")) == pendingBefore,
              "wrong station ACK acknowledges nothing");
        malformed = ackFor(batch);
        auto duplicateIds = malformed.value(QStringLiteral("accepted_event_ids")).toArray();
        duplicateIds.append(duplicateIds.first());
        malformed.insert(QStringLiteral("accepted_event_ids"),duplicateIds);
        check(!journal.applyAck(malformed,base) && journal.status(base).value(QStringLiteral("pendingCount")) == pendingBefore,
              "duplicate or overlapping ACK IDs rejected atomically");
        auto partial = ackFor(batch);
        auto allIds = partial.value(QStringLiteral("accepted_event_ids")).toArray();
        partial.insert(QStringLiteral("accepted_event_ids"),QJsonArray{allIds.first()});
        check(!journal.applyAck(partial,base) && journal.error() == QLatin1String("partial_ack")
              && journal.status(base).value(QStringLiteral("pendingCount")).toInteger() == pendingBefore.toInteger()-1,
              "partial ACK marks exact IDs and retains remainder");
        check(journal.prepareBatch(500,1048576,base) == batch && journal.batchPayload() == bytes,
              "partial response retains immutable retry envelope");
        check(journal.applyAck(ackFor(batch,true),base.addSecs(30)),"duplicate retry ACK completes original envelope");
        check(!eventById(journal,failure).isEmpty() && eventById(journal,failure).value(QStringLiteral("delivery_state")).toString()
              == QLatin1String("acknowledged"),"acknowledgement preserves local history");
        const auto smaller = journal.prepareBatch(2,1048576,base);
        check(smaller.value(QStringLiteral("events")).toArray().size() <= 2,"event batch bound enforced");
        const auto oldBatchId = smaller.value(QStringLiteral("batch_id"));
        check(journal.abandonBatch(QStringLiteral("body_too_large"),base),"413 retires envelope without deleting events");
        const auto split = journal.prepareBatch(1,1048576,base);
        check(split.value(QStringLiteral("batch_id")) != oldBatchId
              && split.value(QStringLiteral("events")).toArray().size() == 1,"413 creates a new smaller immutable batch");
        const auto poison = split.value(QStringLiteral("events")).toArray().first().toObject().value(QStringLiteral("event_id")).toString();
        check(journal.rejectEvents({poison},QStringLiteral("invalid_event"),base)
              && eventById(journal,poison).value(QStringLiteral("delivery_state")).toString() == QLatin1String("rejected"),
              "poison event retained visibly");
        check(!journal.prepareBatch(1,1048576,base).isEmpty(),"poison event does not starve unrelated valid records");
        check(!journal.syncDue(base.addMSecs(CameraAvailabilityJournal::SyncIntervalMs-1)),"automatic sync not early");
        check(journal.syncDue(base.addMSecs(CameraAvailabilityJournal::SyncIntervalMs+31000)),"automatic sync due after 180 minutes");
        check(journal.recordAttempt(base.addSecs(60)) && journal.recordFailure(QStringLiteral("backend_unavailable"),base.addSecs(120)),
              "retry schedule and attempt stored durably");
        journal.close();
        check(journal.open(path,base.addSecs(180)) && journal.selectContext(QStringLiteral("test-context"),base)
              && journal.syncDue(base.addSecs(180)),"restart catches overdue durable retry schedule");
        const auto oldPending = journal.status(base).value(QStringLiteral("pendingCount")).toInteger();
        check(journal.selectContext(QStringLiteral("different-credential-fingerprint"),base)
              && journal.status(base).value(QStringLiteral("pendingCount")).toInteger() == 0
              && journal.status(base).value(QStringLiteral("retainedOtherContextCount")).toInteger() >= oldPending,
              "credential context changes isolate and retain old pending queues");
        check(journal.prepareBatch(500,1048576,base).isEmpty() && journal.error() == QLatin1String("identity_unbound"),
              "unbound records cannot upload");
        check(journal.bind(backend,station,base)
              && !journal.bind(QStringLiteral("44444444-4444-4444-8444-444444444444"),station,base),
              "bound backend identity cannot be overwritten");
    }
    {
        CameraAvailabilityJournal journal;
        check(setup(journal,temporary.filePath(QStringLiteral("native.sqlite"))),"native fixture open");
        const auto native = nativeEvent();
        const auto pending = journal.status(base).value(QStringLiteral("pendingCount"));
        check(journal.importNative({native},QStringLiteral("cursor-1"),base)
              && journal.nativeCursor() == QLatin1String("cursor-1")
              && journal.status(base).value(QStringLiteral("pendingCount")) == pending,
              "native import commits cursor without outbound feedback");
        const auto count = journal.status(base).value(QStringLiteral("historyCount"));
        check(journal.importNative({native},QStringLiteral("cursor-2"),base)
              && journal.status(base).value(QStringLiteral("historyCount")) == count,"native duplicate import idempotent");
        auto bad = native;
        bad.insert(QStringLiteral("event_id"),QStringLiteral("bad-id"));
        check(!journal.importNative({bad},QStringLiteral("cursor-skipped"),base)
              && journal.nativeCursor() == QLatin1String("cursor-2"),"malformed native page cannot advance cursor");
        auto first = native;
        first.insert(QStringLiteral("event_id"),QStringLiteral("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"));
        check(!journal.importNative({first,bad},QStringLiteral("cursor-partial"),base)
              && eventById(journal,first.value(QStringLiteral("event_id")).toString()).isEmpty()
              && journal.nativeCursor() == QLatin1String("cursor-2"),"native page insertion and cursor are atomic");
        auto changed = native;
        changed.insert(QStringLiteral("state"),QStringLiteral("unavailable"));
        check(!journal.importNative({changed},QStringLiteral("cursor-conflict"),base)
              && journal.nativeCursor() == QLatin1String("cursor-2"),"conflicting native identity retained without overwrite");
        auto annotated = native;
        annotated.insert(QStringLiteral("condition_status"),QStringLiteral("recovery_referenced"));
        check(journal.importNative({annotated},QStringLiteral("cursor-annotated"),base)
              && journal.status(base).value(QStringLiteral("historyCount")) == count,
              "new server annotations do not duplicate an immutable native observation");
        auto unsafeNative = native;
        unsafeNative.insert(QStringLiteral("event_id"),QStringLiteral("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"));
        unsafeNative.insert(QStringLiteral("token"),QStringLiteral("disposable-native-secret"));
        check(!journal.importNative({unsafeNative},QStringLiteral("cursor-unsafe"),base)
              && journal.nativeCursor() == QLatin1String("cursor-annotated"),
              "native extra fields rejected before persistence or cursor advancement");
        auto offsetNative = native;
        offsetNative.insert(QStringLiteral("event_id"),QStringLiteral("cccccccc-cccc-4ccc-8ccc-cccccccccccc"));
        offsetNative.insert(QStringLiteral("observed_at"),QStringLiteral("2026-10-29T15:00:00.000+03:00"));
        check(journal.importNative({offsetNative},QStringLiteral("cursor-offset"),base)
              && journal.history({},base.addSecs(-1),base.addSecs(1),100).size() == 2,
              "native timezone text preserved while time filtering uses the correct instant");
        const auto countWithOffset = journal.status(base).value(QStringLiteral("historyCount"));
        check(journal.maintenance(base.addYears(2)) && journal.status(base).value(QStringLiteral("historyCount")) == countWithOffset,
              "default retention never deletes history or pending records");
        check(journal.selectContext(QStringLiteral("second-native-scope"),base) && journal.bind(backend,station,base)
              && journal.importNative({native},QStringLiteral("same-native-new-scope"),base),
              "native identity can occur independently in another retained scope");
    }
    {
        CameraAvailabilityJournal journal;
        const auto path = temporary.filePath(QStringLiteral("busy.sqlite"));
        check(setup(journal,path),"storage fault fixture open");
        const QString externalName = QStringLiteral("external-lock");
        {
            auto external = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"),externalName);
            external.setDatabaseName(path);
            QSqlQuery lock(external);
            check(external.open() && lock.exec(QStringLiteral("BEGIN IMMEDIATE")),"separate SQLite writer lock acquired");
            const auto before = journal.status(base).value(QStringLiteral("pendingCount"));
            check(journal.observe(observation(QStringLiteral("unavailable")),base,1).isEmpty()
                  && journal.error() == QLatin1String("sqlite_busy")
                  && journal.status(base).value(QStringLiteral("pendingCount")) == before,
                  "busy write fails honestly without memory-only recording");
            lock.exec(QStringLiteral("ROLLBACK"));
            external.close();
        }
        QSqlDatabase::removeDatabase(externalName);
        check(!journal.observe(observation(QStringLiteral("available")),base,2).isEmpty(),"logging resumes after lock released");
        auto db = journalDb();
        QSqlQuery limit(db);
        limit.exec(QStringLiteral("PRAGMA page_count")); limit.next();
        const int pages = limit.value(0).toInt();
        check(limit.exec(QStringLiteral("PRAGMA max_page_count=%1").arg(pages+1)),"bounded database full fixture enabled");
        bool fullObserved = false;
        for (int i=0;i<200;++i) {
            const auto id = journal.observe(observation(i%2 ? QStringLiteral("available") : QStringLiteral("unavailable"),
                                                       QStringLiteral("full-%1").arg(i)),base.addMSecs(i),i);
            if (id.isEmpty() && journal.error() == QLatin1String("sqlite_full")) { fullObserved = true; break; }
        }
        check(fullObserved && !journal.status(base).value(QStringLiteral("loggingComplete")).toBool(),
              "SQLITE_FULL surfaces incomplete logging and retains existing database");
        check(limit.exec(QStringLiteral("PRAGMA max_page_count=100000")),"storage full fixture cleared");
        check(!journal.observe(observation(QStringLiteral("available"),QStringLiteral("recovered-storage")),base,1000).isEmpty(),
              "new commits resume after full condition clears");
        limit = QSqlQuery(); db = {};
        journal.close();
        check(journal.open(path,base) && journal.status(base).value(QStringLiteral("unrecordedCount")).toInteger() >= 2,
              "recovered logging-loss count survives reopen");
    }
    {
        const auto path = temporary.filePath(QStringLiteral("corrupt.sqlite"));
        QFile corrupt(path);
        corrupt.open(QIODevice::WriteOnly); corrupt.write("This is not a SQLite database."); corrupt.close();
        CameraAvailabilityJournal journal;
        check(!journal.open(path,base) && QFile(path).size() > 0,
              "corrupt database is preserved and never replaced or memory-backed");
    }
    {
        const auto path = temporary.filePath(QStringLiteral("future.sqlite"));
        const QString externalName = QStringLiteral("future-schema");
        {
            auto db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"),externalName);
            db.setDatabaseName(path); db.open();
            QSqlQuery query(db); query.exec(QStringLiteral("PRAGMA user_version=99")); db.close();
        }
        QSqlDatabase::removeDatabase(externalName);
        CameraAvailabilityJournal journal;
        check(!journal.open(path,base) && journal.error() == QLatin1String("unsupported_schema"),
              "newer schema refused without destructive migration");
        check(!journal.isOpen(),"failed schema admission closes database access");
    }
    {
        const auto path = temporary.filePath(QStringLiteral("failed-migration.sqlite"));
        const QString externalName = QStringLiteral("failed-migration");
        {
            auto db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"),externalName);
            db.setDatabaseName(path); db.open();
            QSqlQuery query(db); query.exec(QStringLiteral("CREATE TABLE metadata(existing_data TEXT)"));
            query.exec(QStringLiteral("INSERT INTO metadata VALUES ('preserved')")); db.close();
        }
        QSqlDatabase::removeDatabase(externalName);
        CameraAvailabilityJournal journal;
        check(!journal.open(path,base) && !journal.isOpen(),"conflicting schema migration fails instead of resetting the database");
        {
            auto db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"),externalName);
            db.setDatabaseName(path); db.open(); QSqlQuery query(db);
            check(query.exec(QStringLiteral("SELECT existing_data FROM metadata")) && query.next()
                  && query.value(0).toString() == QLatin1String("preserved"),"migration failure preserves existing contents");
            db.close();
        }
        QSqlDatabase::removeDatabase(externalName);
    }
    {
        CameraAvailabilityJournal journal;
        check(setup(journal,temporary.filePath(QStringLiteral("validation.sqlite"))),"validation fixture open");
        auto sensitive = observation(QStringLiteral("available"));
        auto details = sensitive.value(QStringLiteral("details")).toObject();
        details.insert(QStringLiteral("token"),QStringLiteral("disposable-test-secret"));
        details.insert(QStringLiteral("pipeline_id"),QStringLiteral("https://user:password@host/path?token=test"));
        details.insert(QStringLiteral("consecutive_failures"),10001);
        sensitive.insert(QStringLiteral("details"),details);
        const auto id = journal.observe(sensitive,base,1);
        const auto serialized = QJsonDocument(eventById(journal,id)).toJson();
        check(!id.isEmpty() && !serialized.contains("disposable-test-secret") && !serialized.contains("password@")
              && !eventById(journal,id).value(QStringLiteral("details")).toObject().contains(QStringLiteral("consecutive_failures")),
              "credential URLs arbitrary keys and invalid details are excluded");
        auto invalid = observation(QStringLiteral("available"));
        invalid.insert(QStringLiteral("camera_id"),QStringLiteral("rtsp://user:secret@camera"));
        check(journal.observe(invalid,base,1).isEmpty() && journal.error() == QLatin1String("invalid_observation"),
              "credentialed stream URL cannot become canonical camera identity");
        auto report = QJsonObject{{QStringLiteral("camera_id"),QStringLiteral("camera-01")},
            {QStringLiteral("domain"),QStringLiteral("backend_reachability")},
            {QStringLiteral("provenance"),QStringLiteral("backend_reported_by_client")},
            {QStringLiteral("state"),QStringLiteral("unavailable")},
            {QStringLiteral("reason_code"),QStringLiteral("backend_status_reported")},
            {QStringLiteral("backend_observation"),QJsonObject{{QStringLiteral("status"),QStringLiteral("offline")},
                {QStringLiteral("status_since"),QStringLiteral("2026-10-29T10:00:00Z")}}}};
        const auto r1 = journal.observe(report,base,1);
        check(!r1.isEmpty() && journal.observe(report,base.addSecs(10),2).isEmpty(),"backend baseline repeated receipt deduplicated");
        auto reported = report.value(QStringLiteral("backend_observation")).toObject();
        reported.insert(QStringLiteral("status_since"),QStringLiteral("2026-10-29T11:00:00Z"));
        report.insert(QStringLiteral("backend_observation"),reported);
        const auto r2 = journal.observe(report,base.addSecs(20),3);
        check(!r2.isEmpty() && eventById(journal,r2).value(QStringLiteral("condition_id"))
              != eventById(journal,r1).value(QStringLiteral("condition_id")),
              "new reported incident effective time and condition are retained even in same state");
        check(!journal.observe(observation(QStringLiteral("available")),base.addSecs(29),29000).isEmpty(),
              "live evidence established before observation gap");
        const auto unknown = journal.observe(observation(QStringLiteral("unknown")),base.addSecs(30),30000);
        check(eventById(journal,unknown).value(QStringLiteral("domain")).toString() == QLatin1String("monitoring")
              && eventById(journal,unknown).value(QStringLiteral("transition")).toString() == QLatin1String("monitoring_gap"),
              "lost evidence becomes monitoring gap rather than camera outage");
        check(journal.observe(observation(QStringLiteral("unknown")),base.addSecs(30),30001).isEmpty()
              && journal.error().isEmpty(),"repeated missing evidence does not manufacture monitoring resumption");
        const auto resumed = journal.observe(observation(QStringLiteral("available")),base.addSecs(31),31000);
        check(eventById(journal,resumed).value(QStringLiteral("transition")).toString() == QLatin1String("initial"),
              "positive evidence after gap is new baseline");
        check(!journal.observe(observation(QStringLiteral("unavailable")),base.addSecs(32),32000).isEmpty(),
              "pipeline failure established before explicit monitoring gap");
        auto monitoring = observation(QStringLiteral("unknown"));
        monitoring.insert(QStringLiteral("domain"),QStringLiteral("monitoring"));
        monitoring.insert(QStringLiteral("transition"),QStringLiteral("monitoring_gap"));
        check(!journal.observe(monitoring,base.addSecs(33),33000).isEmpty(),"separate monitoring domain records pipeline observation gap");
        monitoring.insert(QStringLiteral("transition"),QStringLiteral("monitoring_resumed"));
        const auto monitoringResumed = journal.observe(monitoring,base.addSecs(34),34000);
        check(eventById(journal,monitoringResumed).value(QStringLiteral("transition")).toString() == QLatin1String("monitoring_resumed"),
              "explicit resumption may retain unknown camera evidence");
        const auto afterExplicit = journal.observe(observation(QStringLiteral("available")),base.addSecs(35),35000);
        check(eventById(journal,afterExplicit).value(QStringLiteral("transition")).toString() == QLatin1String("initial")
              && !eventById(journal,afterExplicit).contains(QStringLiteral("duration_ms")),
              "monitoring domain gap interrupts related live-delivery duration");
        journal.observe(observation(QStringLiteral("unavailable")),base.addSecs(36),36000);
        auto stationGap = QJsonObject{{QStringLiteral("camera_id"),QJsonValue::Null},
            {QStringLiteral("domain"),QStringLiteral("monitoring")},{QStringLiteral("state"),QStringLiteral("unknown")},
            {QStringLiteral("transition"),QStringLiteral("monitoring_gap")},{QStringLiteral("reason_code"),QStringLiteral("observation_gap")}};
        check(!journal.observe(stationGap,base.addSecs(37),37000).isEmpty(),"station monitoring gap committed");
        const auto afterStationGap = journal.observe(observation(QStringLiteral("available")),base.addSecs(38),38000);
        check(eventById(journal,afterStationGap).value(QStringLiteral("transition")).toString() == QLatin1String("initial"),
              "station gap invalidates prior pipeline evidence without false recovery");
        auto batch = journal.prepareBatch(500,1048576,base);
        check(!batch.isEmpty() && journal.batchPayload().size() <= 1048576,"complete serialized request respects byte bound");
        if (app.arguments().value(1) == QLatin1String("--write-protocol-fixture")) {
            QFile protocol(app.arguments().value(2));
            check(protocol.open(QIODevice::WriteOnly) && protocol.write(journal.batchPayload()) == journal.batchPayload().size(),
                  "actual journal-generated protocol fixture exported for normative schema validation");
        }
        check(journal.recordAttempt(base) && journal.syncDue(base.addMSecs(-CameraAvailabilityJournal::SyncIntervalMs-1)),
              "backward clock jump cannot indefinitely defer schedule");
    }
    {
        CameraAvailabilityJournal journal;
        check(setup(journal,temporary.filePath(QStringLiteral("capacity.sqlite"))),"capacity fixture open");
        auto db = journalDb();
        QSqlQuery fill(db);
        check(fill.exec(QStringLiteral("INSERT INTO metadata(key,value) VALUES ('capacity_fixture',zeroblob(1100000))")),
              "isolated database capacity fixture allocated");
        const auto pending = journal.status(base).value(QStringLiteral("pendingCount"));
        check(!journal.maintenance(base,0,0,1048576) && journal.error() == QLatin1String("storage_capacity_exceeded"),
              "configured journal capacity surfaced without pruning records");
        check(journal.observe(observation(QStringLiteral("available")),base,1).isEmpty()
              && journal.status(base).value(QStringLiteral("pendingCount")) == pending
              && !journal.status(base).value(QStringLiteral("loggingComplete")).toBool(),
              "capacity refuses new recording honestly while preserving pending data");
        check(journal.maintenance(base,0,0,4*1048576)
              && !journal.observe(observation(QStringLiteral("available")),base,1).isEmpty(),
              "explicit capacity increase permits recording to resume");
    }
    {
        CameraAvailabilityJournal journal;
        check(setup(journal,temporary.filePath(QStringLiteral("backwards-monotonic.sqlite"))),"monotonic fixture open");
        journal.observe(observation(QStringLiteral("available")),base,10);
        journal.observe(observation(QStringLiteral("unavailable")),base,20);
        const auto id = journal.observe(observation(QStringLiteral("available")),base,15);
        check(!id.isEmpty() && eventById(journal,id).value(QStringLiteral("transition")).toString() != QLatin1String("recovery")
              && !eventById(journal,id).contains(QStringLiteral("duration_ms")),
              "decreasing monotonic offset cannot manufacture measured recovery");
    }
    {
        CameraAvailabilityJournal journal;
        check(setup(journal,temporary.filePath(QStringLiteral("backend-gap.sqlite"))),"backend gap fixture open");
        journal.observe(observation(QStringLiteral("available")),base,10);
        journal.observe(observation(QStringLiteral("unavailable")),base,20);
        auto report = QJsonObject{{QStringLiteral("camera_id"),QStringLiteral("camera-01")},
            {QStringLiteral("domain"),QStringLiteral("backend_reachability")},
            {QStringLiteral("provenance"),QStringLiteral("backend_reported_by_client")},
            {QStringLiteral("state"),QStringLiteral("unavailable")},
            {QStringLiteral("reason_code"),QStringLiteral("backend_status_reported")},
            {QStringLiteral("details"),QJsonObject{{QStringLiteral("observer_scope"),QStringLiteral("backend")}}},
            {QStringLiteral("backend_observation"),QJsonObject{{QStringLiteral("status"),QStringLiteral("offline")}}}};
        journal.observe(report,base,20);
        QJsonObject apiGap{{QStringLiteral("camera_id"),QJsonValue::Null},
            {QStringLiteral("domain"),QStringLiteral("monitoring")},{QStringLiteral("state"),QStringLiteral("unknown")},
            {QStringLiteral("transition"),QStringLiteral("monitoring_gap")},{QStringLiteral("reason_code"),QStringLiteral("observation_gap")},
            {QStringLiteral("details"),QJsonObject{{QStringLiteral("observer_scope"),QStringLiteral("backend")}}}};
        check(!journal.observe(apiGap,base,25).isEmpty(),"API observer gap committed once for the station");
        const auto localRecovery = journal.observe(observation(QStringLiteral("available")),base,30);
        check(eventById(journal,localRecovery).value(QStringLiteral("transition")).toString() == QLatin1String("recovery")
              && eventById(journal,localRecovery).value(QStringLiteral("duration_ms")).toInteger() == 10,
              "API outage cannot erase independent live-delivery failure or recovery evidence");
        report.insert(QStringLiteral("state"),QStringLiteral("available"));
        report.insert(QStringLiteral("backend_observation"),QJsonObject{{QStringLiteral("status"),QStringLiteral("online")}});
        const auto afterApi = journal.observe(report,base,30);
        check(eventById(journal,afterApi).value(QStringLiteral("transition")).toString() == QLatin1String("initial"),
              "API observer resumes with baseline rather than invented camera recovery");
    }
    {
        CameraAvailabilityJournal journal;
        check(setup(journal,temporary.filePath(QStringLiteral("scoped-history.sqlite"))),"scoped history fixture open");
        const auto accessible = journal.observe(observation(QStringLiteral("available")),base,1);
        bool generated = !accessible.isEmpty();
        for (int i = 0; i < 1005; ++i) {
            auto privateCamera = observation(QStringLiteral("available"),QStringLiteral("private-%1").arg(i));
            privateCamera.insert(QStringLiteral("camera_id"),QStringLiteral("private-camera"));
            if (journal.observe(privateCamera,base.addMSecs(i+1),i+2).isEmpty()) { generated=false; break; }
        }
        check(generated,"more than 1000 newer out-of-scope observations committed");
        bool unrestrictedContainsOld = false;
        for (const auto &v : journal.history({}, {}, {},1000))
            if (v.toObject().value(QStringLiteral("event_id")).toString() == accessible) unrestrictedContainsOld=true;
        check(!unrestrictedContainsOld,"unrestricted latest row bound excludes older accessible observation");
        const auto scoped = journal.history({}, {}, {},1000,{QStringLiteral("camera-01")},false);
        check(scoped.size() == 1 && scoped.first().toObject().value(QStringLiteral("event_id")).toString() == accessible,
              "camera scope filters before row bound so accessible history is not falsely absent");
        check(journal.history({}, {}, {},1000,{},false).isEmpty(),"empty restricted scope grants no camera or station history");
        const auto withStation = journal.history({}, {}, {},1000,{QStringLiteral("camera-01")},true);
        check(withStation.size() == 2,"explicit scoped station history includes only granted camera and station rows");
    }
    {
        CameraAvailabilityJournal journal;
        check(setup(journal,temporary.filePath(QStringLiteral("reported-unknown.sqlite"))),"reported unknown fixture open");
        QJsonObject report{{QStringLiteral("camera_id"),QStringLiteral("camera-01")},
            {QStringLiteral("domain"),QStringLiteral("backend_reachability")},
            {QStringLiteral("provenance"),QStringLiteral("backend_reported_by_client")},
            {QStringLiteral("state"),QStringLiteral("available")},
            {QStringLiteral("reason_code"),QStringLiteral("backend_status_reported")},
            {QStringLiteral("backend_observation"),QJsonObject{{QStringLiteral("status"),QStringLiteral("online")}}}};
        journal.observe(report,base,1);
        report.insert(QStringLiteral("state"),QStringLiteral("unavailable"));
        report.insert(QStringLiteral("backend_observation"),QJsonObject{{QStringLiteral("status"),QStringLiteral("offline")}});
        journal.observe(report,base.addSecs(1),1001);
        report.insert(QStringLiteral("state"),QStringLiteral("unknown"));
        report.insert(QStringLiteral("backend_observation"),QJsonObject{{QStringLiteral("status"),QStringLiteral("unknown")},
            {QStringLiteral("status_since"),QStringLiteral("2026-10-29T12:00:02.000Z")}});
        const auto unknown=journal.observe(report,base.addSecs(2),2001);
        const auto row=eventById(journal,unknown);
        check(!unknown.isEmpty() && row.value(QStringLiteral("domain")).toString() == QLatin1String("backend_reachability")
              && row.value(QStringLiteral("provenance")).toString() == QLatin1String("backend_reported_by_client")
              && row.value(QStringLiteral("backend_observation")).toObject().value(QStringLiteral("status")).toString() == QLatin1String("unknown")
              && row.value(QStringLiteral("backend_observation")).toObject().contains(QStringLiteral("status_since")),
              "upstream unknown retains report metadata and original domain");
        check(journal.observe(report,base.addSecs(3),3001).isEmpty() && journal.error().isEmpty(),"repeated upstream unknown report deduplicates");
        report.insert(QStringLiteral("state"),QStringLiteral("available"));
        report.insert(QStringLiteral("backend_observation"),QJsonObject{{QStringLiteral("status"),QStringLiteral("online")}});
        const auto fresh=eventById(journal,journal.observe(report,base.addSecs(4),4001));
        check(fresh.value(QStringLiteral("transition")).toString() == QLatin1String("initial") && !fresh.contains(QStringLiteral("duration_ms")),
              "upstream unknown interrupts measured failure pairing");
    }
    {
        const auto path=temporary.filePath(QStringLiteral("loss-continuity.sqlite"));
        CameraAvailabilityJournal journal;
        check(setup(journal,path),"storage loss continuity fixture open");
        journal.observe(observation(QStringLiteral("available")),base,1);
        const auto failure=journal.observe(observation(QStringLiteral("unavailable")),base.addSecs(1),1001);
        const QString externalName=QStringLiteral("loss-continuity-lock");
        {
            auto external=QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"),externalName);
            external.setDatabaseName(path);check(external.open(),"storage loss fixture external connection open");
            QSqlQuery lock(external);check(lock.exec(QStringLiteral("BEGIN IMMEDIATE")),"storage loss fixture write lock held");
            check(journal.observe(observation(QStringLiteral("available")),base.addSecs(2),2001).isEmpty()
                  && journal.error() == QLatin1String("sqlite_busy"),"recovery observation genuinely fails during database lock");
            lock.exec(QStringLiteral("ROLLBACK"));external.close();
        }
        QSqlDatabase::removeDatabase(externalName);
        const auto resumed=eventById(journal,journal.observe(observation(QStringLiteral("available")),base.addSecs(3),3001));
        check(resumed.value(QStringLiteral("transition")).toString() == QLatin1String("initial") && !resumed.contains(QStringLiteral("duration_ms")),
              "positive observation after logging loss is baseline without invented duration");
        check(eventById(journal,failure).value(QStringLiteral("condition_status")).toString() == QLatin1String("interrupted_by_monitoring_gap"),
              "history marks failure interrupted by durable logging gap");
        bool foundGap=false;
        for (auto v:journal.history({}, {}, {},1000)) if(v.toObject().value(QStringLiteral("reason_code")).toString() == QLatin1String("local_logging_interrupted")) foundGap=true;
        check(foundGap,"logging resumes with an explicit durable storage observation gap");
        journal.observe(observation(QStringLiteral("unavailable")),base.addSecs(4),4001);
        const auto failure2=journal.history({}, {}, {},1).first().toObject().value(QStringLiteral("event_id")).toString();
        const auto recovered=eventById(journal,journal.observe(observation(QStringLiteral("available")),base.addSecs(5),5001));
        check(recovered.value(QStringLiteral("transition")).toString() == QLatin1String("recovery")
              && recovered.value(QStringLiteral("relationship_status")).toString() == QLatin1String("reported_same_run_reference")
              && eventById(journal,failure2).value(QStringLiteral("condition_status")).toString() == QLatin1String("recovery_referenced"),
              "later uninterrupted incident pairs and history no longer calls failure unresolved");
        const auto batch=journal.prepareBatch(500,1048576,base);
        bool immutable=true;
        for(auto v:batch.value(QStringLiteral("events")).toArray()) if(v.toObject().contains(QStringLiteral("condition_status")) || v.toObject().contains(QStringLiteral("relationship_status"))) immutable=false;
        check(immutable,"derived history relationships never mutate immutable outgoing event payloads");
    }
    {
        CameraAvailabilityJournal journal;
        const auto path=temporary.filePath(QStringLiteral("loss-restored-unknown.sqlite"));
        check(setup(journal,path),"restored unknown continuity fixture open");
        journal.observe(observation(QStringLiteral("unknown")),base,1);
        const QString externalName=QStringLiteral("restored-unknown-lock");
        {
            auto external=QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"),externalName);external.setDatabaseName(path);external.open();
            QSqlQuery lock(external);lock.exec(QStringLiteral("BEGIN IMMEDIATE"));
            check(journal.observe(observation(QStringLiteral("available")),base.addSecs(1),1001).isEmpty()
                  && journal.error() == QLatin1String("sqlite_busy"),"write loss follows an already unknown observation");
            lock.exec(QStringLiteral("ROLLBACK"));external.close();
        }
        QSqlDatabase::removeDatabase(externalName);
        const auto restored=journal.observe(observation(QStringLiteral("unknown")),base.addSecs(2),2001);
        bool durableGap=false;
        for(auto v:journal.history({}, {}, {},1000)) if(v.toObject().value(QStringLiteral("reason_code")).toString() == QLatin1String("local_logging_interrupted")) durableGap=true;
        check(!restored.isEmpty() && durableGap && journal.error().isEmpty(),
              "first restored unknown commits storage gap and baseline instead of deduplicating rollback");
    }
    {
        CameraAvailabilityJournal journal;
        check(setup(journal,temporary.filePath(QStringLiteral("native-capacity.sqlite"))),"all insertion capacity fixture open");
        auto db=journalDb();QSqlQuery fill(db);
        check(fill.exec(QStringLiteral("INSERT INTO metadata(key,value) VALUES ('fill_capacity',zeroblob(1100000))")),"central insertion capacity fixture allocated");
        journal.maintenance(base,0,0,1048576);
        const auto before=journal.status(base).value(QStringLiteral("historyCount"));
        check(!journal.importNative({nativeEvent()},QStringLiteral("must-not-advance"),base)
              && journal.error() == QLatin1String("storage_capacity_exceeded") && journal.nativeCursor().isEmpty()
              && journal.status(base).value(QStringLiteral("historyCount")) == before,
              "native insertion refuses capacity overflow atomically without cursor advance");
        check(!journal.endRun(base,10) && journal.error() == QLatin1String("storage_capacity_exceeded")
              && journal.status(base).value(QStringLiteral("historyCount")) == before,
              "run-end insertion uses the same capacity fence");
        check(journal.maintenance(base,0,0,4*1048576) && journal.endRun(base,11),"run can close after explicit capacity increase");
        journal.maintenance(base,0,0,1048576);
        const auto closedCount=journal.status(base).value(QStringLiteral("historyCount"));
        check(journal.startRun(base,12).isEmpty() && journal.error() == QLatin1String("storage_capacity_exceeded")
              && journal.status(base).value(QStringLiteral("historyCount")) == closedCount,
              "run-start insertion refuses capacity overflow without partial rows");
    }
    {
        CameraAvailabilityJournal journal;
        check(setup(journal,temporary.filePath(QStringLiteral("native-transaction-capacity.sqlite"))),"native transaction growth fixture open");
        check(journal.maintenance(base,0,0,1048576),"native transaction starts below configured capacity");
        const auto before=journal.status(base).value(QStringLiteral("historyCount"));
        QJsonArray page;
        for(int i=0;i<80;++i){
            auto event=nativeEvent();event.insert(QStringLiteral("event_id"),QUuid::createUuid().toString(QUuid::WithoutBraces));
            event.insert(QStringLiteral("local_seq"),i+1);event.insert(QStringLiteral("position"),i+1);page.append(event);
        }
        check(!journal.importNative(page,QStringLiteral("partial-page-must-not-commit"),base)
              && journal.error() == QLatin1String("storage_capacity_exceeded") && journal.nativeCursor().isEmpty()
              && journal.status(base).value(QStringLiteral("historyCount")) == before,
              "capacity reached inside a multi-event native transaction rolls back every row and cursor");
    }
    {
        CameraAvailabilityJournal journal;
        check(setup(journal,temporary.filePath(QStringLiteral("native-relationships.sqlite"))),"native relationship refresh fixture open");
        auto failure=nativeEvent();
        const QString condition=QStringLiteral("66666666-6666-4666-8666-666666666666");
        failure.insert(QStringLiteral("state"),QStringLiteral("unavailable"));failure.insert(QStringLiteral("transition"),QStringLiteral("failure"));
        failure.insert(QStringLiteral("condition_id"),condition);failure.insert(QStringLiteral("monotonic_ms"),1000);
        failure.insert(QStringLiteral("condition_status"),QStringLiteral("open_unpaired_failure"));
        check(journal.importNative({failure},QStringLiteral("native-failure-cursor"),base),"native open failure imported first");
        auto recovery=failure;
        recovery.insert(QStringLiteral("event_id"),QStringLiteral("55555555-5555-4555-8555-555555555555"));
        recovery.insert(QStringLiteral("local_seq"),2);recovery.insert(QStringLiteral("position"),2);
        recovery.insert(QStringLiteral("state"),QStringLiteral("available"));recovery.insert(QStringLiteral("transition"),QStringLiteral("recovery"));
        recovery.insert(QStringLiteral("related_event_id"),failure.value(QStringLiteral("event_id")));
        recovery.insert(QStringLiteral("monotonic_ms"),2000);recovery.insert(QStringLiteral("duration_ms"),1000);
        recovery.insert(QStringLiteral("condition_status"),QStringLiteral("not_applicable"));
        recovery.insert(QStringLiteral("relationship_status"),QStringLiteral("native_same_run_reference"));
        check(journal.importNative({recovery},QStringLiteral("native-recovery-cursor"),base.addSecs(1)),"later native recovery imported in another page");
        check(eventById(journal,failure.value(QStringLiteral("event_id")).toString()).value(QStringLiteral("condition_status")).toString() == QLatin1String("recovery_referenced")
              && eventById(journal,recovery.value(QStringLiteral("event_id")).toString()).value(QStringLiteral("relationship_status")).toString() == QLatin1String("native_same_run_reference"),
              "local native history refreshes formerly open failure without reimporting or rewriting it");
    }
    QTextStream(stdout) << "RESULT " << passed << " passed; " << failed << " failed" << Qt::endl;
    return failed == 0 ? 0 : 1;
}
