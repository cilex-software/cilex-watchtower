#include "AuthController.h"
#include "CameraObstructionController.h"
#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QtTest>

// Loopback-only HTTP contract test exercises the real authenticated NAM,
// controller, request encoding, response validation and session resets.
class Fixture : public QTcpServer {
public:
    QJsonObject incident{{"incident_id", "incident-a"}, {"camera_id", "camera-a"},
        {"camera_name", "Hall A"}, {"state", "obstructed"}, {"disposition", "pending"},
        {"alert_pending", true}, {"suppressed", false}, {"can_disable_7d", false}};
    int posts = 0;
    int gets = 0;
    int actionStatus = 200;
    QByteArray lastAction;
    bool sawCookie = false;
    bool malformedGet = false;
    bool canManage = true;
    explicit Fixture(QObject *parent = nullptr) : QTcpServer(parent) {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (hasPendingConnections()) {
                auto *socket = nextPendingConnection();
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
                connect(socket, &QTcpSocket::readyRead, socket, [this, socket] {
                    QByteArray data = socket->property("request").toByteArray() + socket->readAll();
                    socket->setProperty("request", data);
                    const int end = data.indexOf("\r\n\r\n");
                    if (end < 0 || socket->property("handled").toBool()) return;
                    const auto headers = data.left(end);
                    int length = 0;
                    for (const auto &line : headers.split('\n'))
                        if (line.toLower().startsWith("content-length:")) length = line.mid(15).trimmed().toInt();
                    if (data.size() < end + 4 + length) return;
                    socket->setProperty("handled", true);
                    const auto first = data.left(data.indexOf('\r'));
                    const auto body = data.mid(end + 4, length);
                    QJsonObject response;
                    int status = 200;
                    if (first.startsWith("POST /auth/login ")) {
                        const QJsonObject claims{{"sub", "operator"}, {"role", "admin"},
                            {"exp", QDateTime::currentSecsSinceEpoch() + 7200}};
                        const auto payload = QJsonDocument(claims).toJson(QJsonDocument::Compact)
                            .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
                        response = {{"access_token", QString::fromLatin1("e30." + payload + ".fixture")}};
                    } else if (first.startsWith("GET /camera-visibility/incidents?active=true ")) {
                        ++gets;
                        sawCookie |= headers.contains("access_token=");
                        response = malformedGet ? QJsonObject{{"incidents", "wrong"}}
                                                : QJsonObject{{"incidents", QJsonArray{incident}}, {"service_status", "running"}, {"can_manage", canManage}};
                    } else if (first.startsWith("POST /camera-visibility/incidents/incident-a/actions ")) {
                        ++posts;
                        lastAction = QJsonDocument::fromJson(body).object().value("action").toString().toUtf8();
                        status = actionStatus;
                        if (status == 200) {
                            incident["alert_pending"] = false;
                            if (lastAction == "confirm") incident["disposition"] = "confirmed";
                            else {
                                incident["disposition"] = "false_alarm";
                                incident["suppressed"] = true;
                                incident["suppressed_until"] = "2099-01-01T00:00:00Z";
                                incident["report_status"] = "queued";
                                incident["evidence_status"] = "pending";
                            }
                            response = {{"incident", incident}};
                        } else response = {{"detail", "fixture action refused"}};
                    } else { status = 404; response = {{"detail", "fixture unknown path"}}; }
                    const QByteArray raw = QJsonDocument(response).toJson(QJsonDocument::Compact);
                    socket->write("HTTP/1.1 " + QByteArray::number(status) + " Fixture\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " + QByteArray::number(raw.size()) + "\r\n\r\n" + raw);
                    socket->disconnectFromHost();
                });
            }
        });
        listen(QHostAddress::LocalHost, 0);
    }
    QString url() const { return "http://127.0.0.1:" + QString::number(serverPort()); }
};

class Contract : public QObject {
    Q_OBJECT
private slots:
    void viewerHasReadOnlyReviewWithoutIntrusivePopup() {
        QTemporaryDir config;
        QVERIFY(config.isValid());
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, config.path());
        QCoreApplication::setOrganizationName("CilexObstructionTest");
        QCoreApplication::setApplicationName("isolated-viewer-contract");
        qputenv("WT_NO_STATION_ENROL", "1");
        qunsetenv("WT_CV_AUTOLOGIN");
        Fixture server;
        server.canManage = false;
        QVERIFY(server.isListening());
        AuthController auth;
        CameraObstructionController controller(&auth);
        auth.loginWithPassword(server.url(), "viewer", "fixture");
        QTRY_VERIFY_WITH_TIMEOUT(controller.available(), 3000);
        QVERIFY(!controller.canManage());
        QCOMPARE(controller.incidents().size(), 1);
        QVERIFY2(controller.pendingIncident().isEmpty(), "Read-only viewers must not receive the central intrusive alarm");
        controller.setCurrentCameraId("camera-a");
        QCOMPARE(controller.reviewIncident().value("incident_id").toString(), QString("incident-a"));
        controller.act("incident-a", "false_alarm");
        QCOMPARE(server.posts, 0);

        server.canManage = true;
        controller.refresh();
        QTRY_VERIFY_WITH_TIMEOUT(controller.canManage(), 3000);
        QCOMPARE(controller.pendingIncident().value("camera_id").toString(), QString("camera-a"));
        server.canManage = false;
        controller.refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!controller.canManage(), 3000);
        QVERIFY(controller.pendingIncident().isEmpty());
        QCOMPARE(controller.reviewIncident().value("camera_id").toString(), QString("camera-a"));
        auth.logout();
    }
    void actionsAndSessionIsolation() {
        QTemporaryDir config;
        QVERIFY(config.isValid());
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, config.path());
        QCoreApplication::setOrganizationName("CilexObstructionTest");
        QCoreApplication::setApplicationName("isolated-contract");
        qputenv("WT_NO_STATION_ENROL", "1");
        qunsetenv("WT_CV_AUTOLOGIN");
        Fixture server;
        QVERIFY(server.isListening());
        AuthController auth;
        CameraObstructionController controller(&auth);
        auth.loginWithPassword(server.url(), "operator", "fixture");
        QTRY_VERIFY_WITH_TIMEOUT(controller.available(), 3000);
        QVERIFY(server.sawCookie);
        QCOMPARE(controller.pendingIncident().value("camera_id").toString(), QString("camera-a"));
        controller.setCurrentCameraId("camera-b");
        QVERIFY(controller.reviewIncident().isEmpty());
        controller.setCurrentCameraId("camera-a");
        QVERIFY(!controller.pendingIncident().isEmpty()); // New alarm interrupts even the already-open camera.
        controller.beginReview("incident-a");
        QVERIFY(controller.pendingIncident().isEmpty());
        QCOMPARE(controller.reviewIncident().value("incident_id").toString(), QString("incident-a"));
        controller.act("incident-a", "disable_7d");
        QCOMPARE(server.posts, 0); // Eligibility must come from Vision.
        controller.act("incident-a", "false_alarm");
        QTRY_COMPARE_WITH_TIMEOUT(server.posts, 1, 3000);
        QTRY_VERIFY_WITH_TIMEOUT(!controller.actionBusy(), 3000);
        QCOMPARE(server.lastAction, QByteArray("false_alarm"));
        QVERIFY(controller.reviewIncident().value("suppressed").toBool());
        QCOMPARE(controller.reviewIncident().value("report_status").toString(), QString("queued"));
        controller.setCurrentCameraId("");
        QVERIFY(controller.pendingIncident().isEmpty());

        server.incident["can_disable_7d"] = true;
        controller.refresh();
        QTRY_VERIFY_WITH_TIMEOUT(controller.incidents().first().toMap().value("can_disable_7d").toBool(), 3000);
        controller.act("incident-a", "disable_7d");
        QTRY_COMPARE_WITH_TIMEOUT(server.posts, 2, 3000);
        QTRY_VERIFY_WITH_TIMEOUT(!controller.actionBusy(), 3000);
        QCOMPARE(server.lastAction, QByteArray("disable_7d"));

        server.incident["disposition"] = "pending";
        server.incident["alert_pending"] = true;
        server.incident["suppressed"] = false;
        server.incident.remove("suppressed_until");
        controller.refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!controller.pendingIncident().isEmpty(), 3000);
        server.actionStatus = 500;
        controller.act("incident-a", "confirm");
        QTRY_COMPARE_WITH_TIMEOUT(server.posts, 3, 3000);
        QTRY_VERIFY_WITH_TIMEOUT(!controller.actionBusy(), 3000);
        QCOMPARE(server.incident.value("disposition").toString(), QString("pending"));
        QVERIFY(!controller.pendingIncident().isEmpty());
        server.actionStatus = 200;
        controller.act("incident-a", "confirm");
        QTRY_COMPARE_WITH_TIMEOUT(server.posts, 4, 3000);
        QTRY_VERIFY_WITH_TIMEOUT(!controller.actionBusy(), 3000);
        QVERIFY(controller.pendingIncident().isEmpty());
        QCOMPARE(controller.incidents().first().toMap().value("disposition").toString(), QString("confirmed"));

        server.canManage = false;
        controller.refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!controller.canManage(), 3000);
        controller.act("incident-a", "false_alarm");
        QCOMPARE(server.posts, 4); // Viewer cannot send classification mutations.

        server.malformedGet = true;
        controller.refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!controller.errorString().isEmpty(), 3000);
        QCOMPARE(controller.incidents().size(), 1); // Preserve last known state, flagged stale.
        auth.logout();
        QVERIFY(controller.incidents().isEmpty());
        QVERIFY(!controller.available());
        QVERIFY(controller.pendingIncident().isEmpty());
    }
};
QTEST_GUILESS_MAIN(Contract)
#include "main.moc"
