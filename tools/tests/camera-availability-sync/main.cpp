#include "CameraAvailabilityWorker.h"
#include <QCoreApplication>
#include <QDateTime>
#include <QElapsedTimer>
#include <QFile>
#include <QHash>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkProxy>
#include <QPointer>
#include <QSet>
#include <QScopeGuard>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTest>
#include <QTimer>
#include <QUrlQuery>
#include <functional>
#include <memory>

namespace {
const QString camera1 = "hiwatch-fixture-camera-01";
const QString camera2 = "hiwatch-fixture-camera-02";
const QByteArray fixtureToken = "disposable-camera-availability-loopback-fixture";

QJsonObject fixture(const QString &name)
{
    QFile file(QStringLiteral(AVAILABILITY_FIXTURES) + '/' + name);
    if (!file.open(QIODevice::ReadOnly)) qFatal("Shared fixture unavailable");
    return QJsonDocument::fromJson(file.readAll()).object();
}
bool pump(const std::function<bool()> &condition, int timeoutMs = 6000)
{
    QElapsedTimer clock; clock.start();
    while (!condition() && clock.elapsed() < timeoutMs) QTest::qWait(5);
    return condition();
}

// Loopback-only protocol fixture, not a substitute for the real Vision route.
class Backend : public QObject {
public:
    QTcpServer server;
    QJsonObject capabilities = fixture("capabilities-response.json");
    QDateTime instant = QDateTime::currentDateTimeUtc();
    QByteArray expectedToken = fixtureToken;
    int capabilitiesStatus = 200, oneBatchError = 0, holdMs = 0;
    int capabilitiesRequests = 0, changesRequests = 0, activeRequests = 0, maxActiveRequests = 0;
    bool dropCommittedResponses = false, partialAckOnce = false, wrongAckOnce = false;
    bool poison = false, nativePages = false, malformedAckOnce = false, nativeAfterReconnect = false;
    QList<QByteArray> bodies;
    QStringList nativeCursors;
    QHash<QString, QJsonObject> accepted;
    QHash<QString, QByteArray> envelopes;
    QHash<QString, QByteArray> receiptTimes;
    QJsonArray native;

    Backend()
    {
        auto scope = capabilities.value("scope").toObject();
        scope["camera_ids"] = QJsonArray{camera1, camera2}; capabilities["scope"] = scope;
        for (int i = 0; i < 2; ++i) {
            const QString id = i == 0 ? "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1" : "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2";
            native.append(QJsonObject{{"event_id", id}, {"local_seq", i + 1},
                {"run_id", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"}, {"camera_id", camera1},
                {"domain", "backend_reachability"}, {"provenance", "backend_native"},
                {"origin", "backend_native"}, {"state", i == 0 ? "available" : "unknown"},
                {"transition", "initial"}, {"observed_at", instant.toString(Qt::ISODateWithMs)},
                {"reason_code", "initial_observation"}, {"details", QJsonObject{}},
                {"backend_instance_id", capabilities.value("backend_instance_id")},
                {"reporter_station_id", QJsonValue::Null},
                {"producer_id", "cccccccc-cccc-4ccc-8ccc-cccccccccccc"}, {"position", i + 1},
                {"site_id", "00000000-0000-0000-0000-000000000001"},
                {"clock_quality", QJsonObject{{"authority", "backend_observed"}, {"flags", QJsonArray{}}}},
                {"relationship_status", "none"}, {"relationship_authority", "backend_native"},
                {"upstream_reference_status", "not_supplied"}, {"condition_status", "not_applicable"},
                {"condition_status_authority", "backend_native"},
                {"server_received_at", instant.toString(Qt::ISODateWithMs)}});
        }
        if (!server.listen(QHostAddress::LocalHost, 0)) qFatal("Loopback listen failed");
        connect(&server, &QTcpServer::newConnection, this, [this] {
            while (server.hasPendingConnections()) {
                auto *socket = server.nextPendingConnection();
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
                connect(socket, &QTcpSocket::readyRead, this, [this, socket] {
                    if (socket->property("handled").toBool()) return;
                    QByteArray buffer = socket->property("request").toByteArray() + socket->readAll();
                    socket->setProperty("request", buffer);
                    const int divider = buffer.indexOf("\r\n\r\n");
                    if (divider < 0) return;
                    const auto headers = buffer.left(divider).split('\n');
                    int length = 0; bool authenticated = false;
                    for (auto line : headers) {
                        const auto lower = line.toLower();
                        if (lower.startsWith("content-length:")) length = line.mid(line.indexOf(':') + 1).trimmed().toInt();
                        if (lower.startsWith("x-cilex-station-token:")) authenticated = line.mid(line.indexOf(':') + 1).trimmed() == expectedToken;
                    }
                    if (length < 0 || length > 1048576 || buffer.size() < divider + 4 + length) return;
                    socket->setProperty("handled", true);
                    const auto requestLine = headers.value(0).trimmed().split(' ');
                    const auto body = buffer.mid(divider + 4, length);
                    ++activeRequests; maxActiveRequests = qMax(maxActiveRequests, activeRequests);
                    const QPointer<QTcpSocket> guarded(socket);
                    QTimer::singleShot(holdMs, this, [this, guarded, requestLine, body, authenticated] {
                        if (!guarded) { --activeRequests; return; }
                        if (!authenticated) { respond(guarded, 401, QJsonObject{}); return; }
                        handle(guarded, requestLine.value(0), QString::fromLatin1(requestLine.value(1)), body);
                    });
                });
            }
        });
    }
    QString base() const { return "http://127.0.0.1:" + QString::number(server.serverPort()); }
    void respond(QTcpSocket *socket, int code, const QJsonObject &object, const QByteArray &extra = {})
    {
        const auto bytes = QJsonDocument(object).toJson(QJsonDocument::Compact);
        socket->write("HTTP/1.1 " + QByteArray::number(code) + " Fixture\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
                      + QByteArray::number(bytes.size()) + "\r\n" + extra + "\r\n" + bytes);
        socket->disconnectFromHost(); --activeRequests;
    }
    void error(QTcpSocket *socket, int code, const QByteArray &extra = {})
    {
        respond(socket, code, QJsonObject{{"detail", QJsonObject{{"code", "fixture_refusal"},
                 {"message", "Isolated protocol test"}, {"retryable", code == 429 || code == 503}}}}, extra);
    }
    void handle(QTcpSocket *socket, const QByteArray &method, const QString &path, const QByteArray &body)
    {
        if (path.endsWith("/capabilities")) {
            ++capabilitiesRequests;
            if (capabilitiesStatus != 200) { error(socket, capabilitiesStatus, capabilitiesStatus == 429 ? QByteArray("Retry-After: 120\r\n") : QByteArray{}); return; }
            respond(socket, 200, capabilities); return;
        }
        if (path.contains("/changes?")) {
            ++changesRequests;
            const QString cursor = QUrlQuery(QUrl(base() + path)).queryItemValue("cursor");
            nativeCursors.append(cursor);
            auto result = fixture("changes-empty-response.json");
            result["backend_instance_id"] = capabilities.value("backend_instance_id");
            result["reporter_station_id"] = capabilities.value("reporter_station_id");
            result["through_position"] = nativePages ? (nativeAfterReconnect ? 3 : 2) : 0;
            result["resume_cursor"] = nativeAfterReconnect ? "resume-native-3" : "resume-native";
            if (nativePages && cursor.isEmpty()) {
                result["events"] = QJsonArray{native.at(0)};
                result["next_cursor"] = "next-page"; result["resume_cursor"] = QJsonValue::Null;
            } else if (nativePages && cursor == "next-page") result["events"] = QJsonArray{native.at(1)};
            else if (nativePages && nativeAfterReconnect && cursor == "resume-native") {
                auto recovered = native.at(0).toObject();
                recovered["event_id"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3";
                recovered["local_seq"] = 3; recovered["position"] = 3;
                recovered["observed_at"] = instant.toString(Qt::ISODateWithMs);
                recovered["server_received_at"] = instant.toString(Qt::ISODateWithMs);
                result["events"] = QJsonArray{recovered};
            }
            respond(socket, 200, result); return;
        }
        if (method == "POST" && path.endsWith("/batches")) {
            bodies.append(body);
            const auto batch = QJsonDocument::fromJson(body).object();
            const auto events = batch.value("events").toArray();
            const QString batchId = batch.value("batch_id").toString();
            if (oneBatchError) { const int code = oneBatchError; oneBatchError = 0; error(socket, code); return; }
            if (poison) for (const auto &value : events) {
                if (value.toObject().value("reason_code") == "poison_fixture") { error(socket, 422); return; }
            }
            if (envelopes.contains(batchId) && envelopes.value(batchId) != body) { error(socket, 409); return; }
            envelopes.insert(batchId, body);
            QJsonArray fresh, duplicates;
            for (const auto &value : events) {
                const auto event = value.toObject(); const auto id = event.value("event_id").toString();
                if (accepted.contains(id)) duplicates.append(id);
                else { accepted.insert(id, event); fresh.append(id); }
            }
            if (dropCommittedResponses) { --activeRequests; socket->abort(); return; }
            auto ack = fixture("accepted-response.json");
            ack["backend_instance_id"] = capabilities.value("backend_instance_id");
            ack["reporter_station_id"] = capabilities.value("reporter_station_id");
            ack["batch_id"] = batchId; ack["accepted_event_ids"] = fresh; ack["duplicate_event_ids"] = duplicates;
            if (partialAckOnce && events.size() > 1) {
                partialAckOnce = false; ack["accepted_event_ids"] = QJsonArray{events.at(0).toObject().value("event_id")};
                ack["duplicate_event_ids"] = QJsonArray{};
            }
            if (wrongAckOnce) { wrongAckOnce = false; ack["backend_instance_id"] = "99999999-9999-4999-8999-999999999999"; }
            if (malformedAckOnce) { malformedAckOnce = false; ack["accepted_event_ids"] = "not-an-array"; }
            respond(socket, 200, ack); return;
        }
        error(socket, 404);
    }
};

class Rig {
public:
    QTemporaryDir directory;
    Backend backend;
    QVariantMap status;
    QVariantList history;
    bool firstManualRequested = false;
    std::unique_ptr<CameraAvailabilityWorker> worker;
    Rig()
    {
        QFile config(directory.filePath("warden.conf"));
        if (!config.open(QIODevice::WriteOnly)) qFatal("Temporary provisioning unavailable");
        config.write("STATION_TOKEN=" + fixtureToken + "\nBACKEND_URL=" + backend.base().toUtf8() + "\n"); config.close();
    }
    void start()
    {
        CameraAvailabilityWorker::Options options;
        options.provisioningFile = directory.filePath("warden.conf");
        options.timerEnabled = false; options.batchDelayMs = 1;
        options.nowUtc = [this] { return backend.instant; };
        worker = std::make_unique<CameraAvailabilityWorker>(directory.filePath("availability.sqlite3"), options);
        firstManualRequested = false;
        QObject::connect(worker.get(), &CameraAvailabilityWorker::stateReady, worker.get(), [this](const QVariantMap &v) {
            status = v;
            // A fresh journal's automatic cadence starts in three hours. Exercise
            // the manual path only after discovery completes, sharing its uploader.
            if (!firstManualRequested && v.value("state") == "ready" && !v.value("busy").toBool()) {
                firstManualRequested = true;
                QTimer::singleShot(0, worker.get(), &CameraAvailabilityWorker::synchronize);
            }
        });
        QObject::connect(worker.get(), &CameraAvailabilityWorker::historyReady, worker.get(), [this](const QVariantList &v) { history = v; });
        worker->initialize();
        worker->configure(backend.base(), true, "admin", {});
    }
    ~Rig() { if (worker) worker->stop(); }
    void observe(const QString &camera = camera1, const QString &reason = "frame_received")
    {
        worker->observe(QVariantMap{{"camera_id", camera}, {"domain", "live_delivery"},
            {"provenance", "client_observed"}, {"state", "available"}, {"reason_code", reason},
            {"details", QVariantMap{{"stream_variant", "sub"}, {"transport", "rtsp"},
                                   {"observer_scope", "pipeline"}, {"pipeline_id", camera}}}});
    }
    bool ready() const { return firstManualRequested && !status.value("lastAttemptAt").toString().isEmpty()
        && status.value("state") == "ready" && !status.value("busy").toBool()
        && status.value("pendingCount").toInt() == 0; }
    bool failed(const QString &state) const { return status.value("state") == state && !status.value("busy").toBool(); }
    void load() { worker->loadHistory({}, backend.instant.addDays(-1).toString(Qt::ISODateWithMs), backend.instant.addSecs(1).toString(Qt::ISODateWithMs)); }
};
}

class SyncTests : public QObject {
    Q_OBJECT
private slots:
    void initTestCase()
    {
        qunsetenv("WT_WARDEN_STATION_TOKEN"); qunsetenv("WT_STATION_TOKEN");
        QNetworkProxy::setApplicationProxy(QNetworkProxy::NoProxy);
    }
    void nativePaginationAndNoFeedbackLoop()
    {
        Rig r; r.backend.nativePages = true; r.start(); r.observe();
        QVERIFY2(pump([&] { return r.ready(); }), qPrintable(r.status.value("blockingReason").toString()));
        QVERIFY(r.backend.nativeCursors.contains("next-page"));
        QVERIFY(r.backend.nativeCursors.contains("resume-native"));
        r.load(); int imported = 0;
        for (const auto &value : r.history) if (value.toMap().value("delivery_state") == "native") ++imported;
        QCOMPARE(imported, 2);
        for (const auto &body : r.backend.bodies) for (const auto &value : QJsonDocument::fromJson(body).object().value("events").toArray())
            QVERIFY(value.toObject().value("provenance") != "backend_native");
        const int before = r.backend.bodies.size();
        r.worker->synchronize(); QVERIFY(pump([&] { return r.ready(); }));
        QCOMPARE(r.backend.bodies.size(), before); // Empty exhausted cursor is valid and does not upload native rows.
    }
    void backendReconnectCatchesUpWithoutAdvancingUpload()
    {
        Rig r; r.backend.nativePages = true; r.start(); r.observe();
        QVERIFY(pump([&] { return r.ready(); }));
        const QString nextUpload = r.status.value("nextSyncAt").toString();
        QVERIFY(!nextUpload.isEmpty());
        const int posts = r.backend.bodies.size();
        const int changes = r.backend.changesRequests;
        const auto connectivity = [&](const QString &state) {
            r.worker->observe(QVariantMap{{"camera_id", QVariant()}, {"domain", "backend_connectivity"},
                {"provenance", "client_observed"}, {"state", state},
                {"reason_code", state == "available" ? "backend_request_succeeded" : "backend_request_failed"},
                {"details", QVariantMap{}}});
        };
        connectivity("available"); connectivity("unavailable");
        r.backend.nativeAfterReconnect = true;
        connectivity("available"); r.worker->checkDue();
        QVERIFY(pump([&] { return r.backend.changesRequests > changes
            && r.status.value("state") == "ready" && !r.status.value("busy").toBool(); }));
        QCOMPARE(r.backend.bodies.size(), posts);
        QCOMPARE(r.status.value("nextSyncAt").toString(), nextUpload);
        QVERIFY(r.status.value("pendingCount").toInt() >= 2);
        r.load(); int imported = 0; bool caughtUp = false;
        for (const auto &value : r.history) {
            const auto row = value.toMap();
            if (row.value("delivery_state") == "native") ++imported;
            if (row.value("event_id") == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3") caughtUp = true;
        }
        QCOMPARE(imported, 3); QVERIFY(caughtUp);
        const int after = r.backend.changesRequests;
        connectivity("available"); r.worker->checkDue(); QTest::qWait(40);
        QCOMPARE(r.backend.changesRequests, after); // Repeated healthy evidence must not create a polling loop.
        QCOMPARE(r.backend.bodies.size(), posts);
    }
    void lostAckRetriesIdenticalCommittedBatch()
    {
        Rig r; r.backend.dropCommittedResponses = true; r.start(); r.observe();
        QVERIFY(pump([&] { return r.failed("degraded"); }));
        QVERIFY(!r.backend.bodies.isEmpty()); QVERIFY(r.status.value("pendingCount").toInt() >= 2);
        const QByteArray original = r.backend.bodies.first();
        const int committed = r.backend.accepted.size();
        r.backend.dropCommittedResponses = false;
        r.backend.instant = QDateTime::fromString(r.status.value("nextSyncAt").toString(), Qt::ISODateWithMs);
        QVERIFY(r.backend.instant.isValid());
        r.worker->synchronize(); QVERIFY(pump([&] { return r.ready(); }));
        for (const auto &body : r.backend.bodies) QCOMPARE(body, original);
        QCOMPARE(r.backend.accepted.size(), committed); QCOMPARE(r.status.value("pendingCount").toInt(), 0);
    }
    void invalidAckRetainsUnaccountedRecords_data()
    {
        QTest::addColumn<int>("kind");
        QTest::newRow("partial") << 0; QTest::newRow("wrong-identity") << 1; QTest::newRow("malformed") << 2;
    }
    void invalidAckRetainsUnaccountedRecords()
    {
        QFETCH(int, kind);
        Rig r; r.backend.partialAckOnce = kind == 0; r.backend.wrongAckOnce = kind == 1; r.backend.malformedAckOnce = kind == 2;
        r.start(); r.observe(); r.observe(camera2);
        QVERIFY(pump([&] { return r.failed(kind == 1 ? "conflict" : "protocol_error"); }));
        QVERIFY(r.status.value("pendingCount").toInt() >= 2);
        const auto original = r.backend.bodies.first();
        const int before = r.backend.bodies.size();
        r.worker->synchronize(); QTest::qWait(20);
        QCOMPARE(r.backend.bodies.size(), before); // Conflicting/protocol replies require explicit reconciliation.
        r.worker->stop(); r.worker.reset(); r.start();
        QVERIFY(pump([&] { return r.ready(); }));
        QCOMPARE(r.backend.bodies.at(before), original);
        QCOMPARE(r.status.value("pendingCount").toInt(), 0);
    }
    void oversizeCreatesNewImmutableEnvelopes()
    {
        Rig r; r.backend.oneBatchError = 413; r.start(); r.observe(); r.observe(camera2);
        QVERIFY(pump([&] { return r.ready(); }));
        QVERIFY(r.backend.bodies.size() >= 2);
        const auto first = QJsonDocument::fromJson(r.backend.bodies.first()).object();
        QSet<QString> originalIds;
        for (auto v : first.value("events").toArray()) originalIds.insert(v.toObject().value("event_id").toString());
        for (int i = 1; i < r.backend.bodies.size(); ++i) {
            const auto later = QJsonDocument::fromJson(r.backend.bodies.at(i)).object();
            QVERIFY(later.value("batch_id") != first.value("batch_id"));
            for (auto v : later.value("events").toArray()) QVERIFY(originalIds.contains(v.toObject().value("event_id").toString()));
        }
        QCOMPARE(r.status.value("pendingCount").toInt(), 0);
    }
    void poisonRecordRetainedWithoutBlockingValidRecords()
    {
        Rig r; r.backend.poison = true; r.start(); r.observe(camera1, "poison_fixture"); r.observe(camera2);
        QVERIFY(pump([&] { return r.ready(); }));
        QCOMPARE(r.status.value("rejectedCount").toInt(), 1);
        QCOMPARE(r.status.value("pendingCount").toInt(), 0);
        bool good = false;
        for (const auto &event : r.backend.accepted) if (event.value("camera_id") == camera2) good = true;
        QVERIFY(good);
        r.load(); bool retained = false;
        for (const auto &v : r.history) if (v.toMap().value("reason_code") == "poison_fixture") {
            retained = true; QCOMPARE(v.toMap().value("delivery_state").toString(), QString("rejected"));
        }
        QVERIFY(retained);
    }
    void blockedAuthenticationAndScopeDoNotRetry_data()
    {
        QTest::addColumn<int>("code"); QTest::addColumn<QString>("state");
        QTest::newRow("credential") << 401 << QString("auth_required");
        QTest::newRow("scope") << 403 << QString("scope_required");
    }
    void blockedAuthenticationAndScopeDoNotRetry()
    {
        QFETCH(int, code); QFETCH(QString, state);
        Rig r; r.backend.capabilitiesStatus = code; r.start(); r.observe();
        QVERIFY(pump([&] { return r.failed(state); }));
        const int requests = r.backend.capabilitiesRequests;
        r.backend.instant = r.backend.instant.addDays(1); r.worker->checkDue(); QTest::qWait(20);
        QCOMPARE(r.backend.capabilitiesRequests, requests);
        QVERIFY(r.status.value("pendingCount").toInt() >= 2);
    }
    void rejectedCredentialPausesManualUntilRotation()
    {
        Rig r; r.backend.capabilitiesStatus = 401; r.start(); r.observe();
        QVERIFY(pump([&] { return r.failed("auth_required"); }));
        const int before = r.backend.capabilitiesRequests;
        r.backend.capabilitiesStatus = 200;
        for (int i = 0; i < 4; ++i) {
            r.worker->synchronize();
            r.worker->configure(r.backend.base(), true, "admin", {});
            r.worker->checkDue();
        }
        QTest::qWait(40); QCOMPARE(r.backend.capabilitiesRequests, before);
        QVERIFY(r.failed("auth_required"));
        r.worker->stop(); r.worker.reset(); r.start();
        QVERIFY(r.failed("auth_required"));
        r.worker->synchronize(); QTest::qWait(30);
        QCOMPARE(r.backend.capabilitiesRequests, before); // The persisted refusal also survives process restart.
        r.backend.expectedToken = "rotated-disposable-loopback-station";
        QFile config(r.directory.filePath("warden.conf")); QVERIFY(config.open(QIODevice::WriteOnly | QIODevice::Truncate));
        config.write("STATION_TOKEN=" + r.backend.expectedToken + "\nBACKEND_URL=" + r.backend.base().toUtf8() + "\n"); config.close();
        r.firstManualRequested = false;
        r.worker->configure(r.backend.base(), true, "admin", {});
        QVERIFY(pump([&] { return r.ready(); }));
        QVERIFY(r.backend.capabilitiesRequests > before);
        QVERIFY(r.status.value("retainedOtherContextCount").toInt() >= 2);
    }
    void explicitStationOnlyScopeCanSynchronize()
    {
        Rig r;
        auto scope = r.backend.capabilities.value("scope").toObject();
        scope["camera_ids"] = QJsonArray{}; scope["allow_station_events"] = true;
        r.backend.capabilities["scope"] = scope;
        r.start(); QVERIFY(pump([&] { return r.ready(); }));
        QVERIFY(!r.backend.bodies.isEmpty());
        for (const auto &body : r.backend.bodies)
            for (const auto &value : QJsonDocument::fromJson(body).object().value("events").toArray())
                QVERIFY(value.toObject().value("camera_id").isNull());
        r.observe(camera1); r.worker->synchronize();
        QVERIFY(pump([&] { return r.ready(); }));
        QCOMPARE(r.status.value("rejectedCount").toInt(), 1);
        for (const auto &event : r.backend.accepted) QVERIFY(event.value("camera_id").isNull());
    }
    void rateLimitHonorsRetryAfter()
    {
        Rig r; r.backend.capabilitiesStatus = 429; r.start(); r.observe();
        QVERIFY(pump([&] { return r.failed("rate_limited"); }));
        const auto due = QDateTime::fromString(r.status.value("nextSyncAt").toString(), Qt::ISODateWithMs);
        QCOMPARE(r.backend.instant.secsTo(due), qint64(120));
        const int requests = r.backend.capabilitiesRequests;
        r.worker->synchronize(); QTest::qWait(20);
        QCOMPARE(r.backend.capabilitiesRequests, requests);
        r.backend.instant = r.backend.instant.addSecs(119);
        r.worker->synchronize(); r.worker->checkDue(); QTest::qWait(20);
        QCOMPARE(r.backend.capabilitiesRequests, requests);
        r.worker->stop(); r.worker.reset(); r.start();
        QVERIFY(r.failed("rate_limited"));
        r.worker->synchronize(); r.worker->checkDue(); QTest::qWait(20);
        QCOMPARE(r.backend.capabilitiesRequests, requests);
        r.backend.capabilitiesStatus = 200; r.backend.instant = r.backend.instant.addSecs(1);
        r.worker->checkDue(); QVERIFY(pump([&] { return r.ready(); }));
    }
    void scheduledAndManualRequestsShareOneFlight()
    {
        Rig r; r.backend.holdMs = 20; r.start(); r.observe();
        for (int i = 0; i < 5; ++i) { r.worker->synchronize(); r.worker->checkDue(); }
        QVERIFY(pump([&] { return r.ready(); }));
        QCOMPARE(r.backend.maxActiveRequests, 1);
        const auto due = QDateTime::fromString(r.status.value("nextSyncAt").toString(), Qt::ISODateWithMs);
        QCOMPARE(r.backend.instant.msecsTo(due), qint64(180) * 60000);
        r.observe(camera2); const int before = r.backend.bodies.size();
        r.backend.instant = r.backend.instant.addMSecs(180LL * 60000 - 1); r.worker->checkDue(); QTest::qWait(20);
        QCOMPARE(r.backend.bodies.size(), before);
        r.backend.instant = r.backend.instant.addMSecs(1);
        r.worker->checkDue(); r.worker->synchronize();
        QVERIFY(pump([&] { return r.ready() && r.backend.bodies.size() > before; }));
        QCOMPARE(r.backend.maxActiveRequests, 1);
    }
    void historyAccessClearsOnLogoutAndEmptyScope()
    {
        Rig r; r.start(); r.observe(); r.observe(camera2);
        QVERIFY(pump([&] { return r.ready(); }));
        r.worker->configure(r.backend.base(), true, "viewer", {}); r.load(); QCOMPARE(r.history.size(), 0);
        r.worker->configure(r.backend.base(), true, "viewer", {camera1}); r.load();
        QVERIFY(!r.history.isEmpty()); for (const auto &row : r.history) QCOMPARE(row.toMap().value("camera_id").toString(), camera1);
        r.worker->loadHistory(camera2); QCOMPARE(r.history.size(), 0);
        r.worker->configure(r.backend.base(), false, "viewer", {camera1}); r.load(); QCOMPARE(r.history.size(), 0);
        r.worker->configure(r.backend.base(), true, "station", {camera1}); r.load(); QCOMPARE(r.history.size(), 0);
    }
    void identityChangeCannotReplayOldDestination()
    {
        Rig r; r.backend.oneBatchError = 409; r.start(); r.observe();
        QVERIFY(pump([&] { return r.failed("conflict"); }));
        const int before = r.backend.bodies.size();
        r.backend.capabilities["backend_instance_id"] = "99999999-9999-4999-8999-999999999999";
        r.worker->stop(); r.worker.reset(); r.start();
        QVERIFY(pump([&] { return r.failed("conflict"); }));
        QCOMPARE(r.backend.bodies.size(), before);
        QVERIFY(r.status.value("pendingCount").toInt() >= 2);
    }
    void provisionedDestinationCannotBeOverriddenByManualSync()
    {
        Rig r; r.start(); r.observe(); QVERIFY(pump([&] { return r.ready(); }));
        Backend foreign;
        r.worker->configure(foreign.base(), true, "admin", {});
        QVERIFY(r.failed("conflict"));
        r.worker->synchronize(); r.worker->checkDue(); QTest::qWait(50);
        QCOMPARE(foreign.capabilitiesRequests, 0);
        QCOMPARE(foreign.changesRequests, 0);
        QCOMPARE(foreign.bodies.size(), 0);
        QVERIFY(r.failed("conflict"));
    }
    void stationCredentialChangeRetainsOldQueue()
    {
        Rig r; r.backend.oneBatchError = 409; r.start(); r.observe();
        QVERIFY(pump([&] { return r.failed("conflict"); }));
        QSet<QString> oldIds;
        for (const auto &value : QJsonDocument::fromJson(r.backend.bodies.first()).object().value("events").toArray())
            oldIds.insert(value.toObject().value("event_id").toString());
        const int before = r.backend.bodies.size();
        r.backend.expectedToken = "another-disposable-loopback-station";
        r.backend.capabilities["reporter_station_id"] = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
        auto scope = r.backend.capabilities.value("scope").toObject();
        scope["station_id"] = r.backend.capabilities.value("reporter_station_id");
        r.backend.capabilities["scope"] = scope;
        QFile config(r.directory.filePath("warden.conf")); QVERIFY(config.open(QIODevice::WriteOnly | QIODevice::Truncate));
        config.write("STATION_TOKEN=" + r.backend.expectedToken + "\nBACKEND_URL=" + r.backend.base().toUtf8() + "\n"); config.close();
        r.firstManualRequested = false;
        r.worker->configure(r.backend.base(), true, "admin", {});
        QVERIFY(pump([&] { return r.ready(); }));
        QVERIFY(r.status.value("retainedOtherContextCount").toInt() >= 2);
        for (int i = before; i < r.backend.bodies.size(); ++i)
            for (const auto &value : QJsonDocument::fromJson(r.backend.bodies.at(i)).object().value("events").toArray())
                QVERIFY(!oldIds.contains(value.toObject().value("event_id").toString()));
    }
    void busyContextChangeCannotExposeOrWriteOldContext()
    {
        Rig r; r.start(); r.observe(camera1, "old_context_marker");
        QVERIFY(pump([&] { return r.ready(); }));
        r.load(); bool oldRecordSeen = false;
        for (const auto &value : r.history)
            if (value.toMap().value("reason_code") == "old_context_marker") oldRecordSeen = true;
        QVERIFY(oldRecordSeen);
        Backend foreign;
        const QString connection = "availability-context-busy-fixture";
        const auto cleanupConnection = qScopeGuard([connection] { QSqlDatabase::removeDatabase(connection); });
        {
            QSqlDatabase lock = QSqlDatabase::addDatabase("QSQLITE", connection);
            lock.setDatabaseName(r.directory.filePath("availability.sqlite3"));
            QVERIFY(lock.open());
            QSqlQuery query(lock); QVERIFY(query.exec("BEGIN IMMEDIATE"));
            r.worker->configure(foreign.base(), true, "viewer", {camera1}, 42);
            r.worker->loadHistory();
            QCOMPARE(r.history.size(), 0); // WAL reads remain possible; this must be the new context fence.
            QCOMPARE(r.status.value("state").toString(), QString("storage_error"));
            const QVariantMap marker{{"camera_id", camera1}, {"domain", "live_delivery"},
                {"provenance", "client_observed"}, {"state", "unavailable"},
                {"reason_code", "context_change_marker"},
                {"details", QVariantMap{{"observer_scope", "pipeline"}, {"pipeline_id", "switching-context"}}}};
            r.worker->observe(marker); r.worker->synchronize();
            QCOMPARE(foreign.capabilitiesRequests, 0);
            QVERIFY(query.exec("ROLLBACK"));
            // Storage is writable again, but no configure retry has succeeded yet.
            // A missing context fence would now append this event to the old journal.
            r.worker->observe(marker); r.worker->loadHistory();
            QCOMPARE(r.history.size(), 0);
            query.prepare("SELECT COUNT(*) FROM events WHERE payload LIKE ?");
            query.addBindValue("%context_change_marker%");
            QVERIFY(query.exec()); QVERIFY(query.next()); QCOMPARE(query.value(0).toInt(), 0);
            query.finish(); lock.close();
        }
        // Deliberately authorize the fixture's new destination, then retry the
        // previously failed context transition. No production credential is used.
        QFile config(r.directory.filePath("warden.conf")); QVERIFY(config.open(QIODevice::WriteOnly | QIODevice::Truncate));
        config.write("STATION_TOKEN=" + fixtureToken + "\nBACKEND_URL=" + foreign.base().toUtf8() + "\n"); config.close();
        r.firstManualRequested = false;
        r.worker->configure(foreign.base(), true, "admin", {}, 43);
        QVERIFY(pump([&] { return r.ready(); }));
        QVERIFY(foreign.capabilitiesRequests > 0);
        r.worker->loadHistory();
        for (const auto &value : r.history)
            QVERIFY(value.toMap().value("reason_code") != "old_context_marker");
    }
    void restartPreservesPendingBatchAndNativeCursor()
    {
        Rig r; r.backend.nativePages = true; r.backend.oneBatchError = 409; r.start(); r.observe();
        QVERIFY(pump([&] { return r.failed("conflict"); }));
        QVERIFY(!r.backend.bodies.isEmpty()); const auto original = r.backend.bodies.first();
        r.worker->stop(); r.worker.reset(); r.backend.nativeCursors.clear();
        r.start(); r.worker->synchronize();
        QVERIFY(pump([&] { return r.ready(); }));
        QVERIFY(r.backend.nativeCursors.contains("resume-native"));
        QVERIFY(!r.backend.nativeCursors.contains(""));
        QVERIFY(r.backend.bodies.size() > 1); QCOMPARE(r.backend.bodies.at(1), original);
        QCOMPARE(r.status.value("pendingCount").toInt(), 0);
    }
};

QTEST_GUILESS_MAIN(SyncTests)
#include "main.moc"
