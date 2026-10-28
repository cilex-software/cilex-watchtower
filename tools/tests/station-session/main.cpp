#include "AuthController.h"
#include <QCoreApplication>
#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkCookie>
#include <QNetworkCookieJar>
#include <QNetworkProxy>
#include <QPointer>
#include <QSettings>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTest>
#include <QTimer>
#include <memory>

namespace {
const QString stationKey = "disposable-loopback-station-key";
QString operatorToken(const QString &nonce = {})
{
    const auto body = QJsonDocument(QJsonObject{{"username", "fixture-operator"}, {"role", "operator"},
        {"camera_scope", QJsonArray{"fixture-camera"}}, {"nonce", nonce},
        {"exp", QDateTime::currentSecsSinceEpoch() + 3600}}).toJson(QJsonDocument::Compact);
    return "fixture." + QString::fromLatin1(body.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)) + ".fixture";
}
class Backend : public QObject {
public:
    QTcpServer listener;
    int exchanges = 0, logins = 0, refreshes = 0, ttlMs = 1600;
    int stationStatus = 200, loginStatus = 200, stationDelay = 0, loginDelay = 0, refreshDelay = 0;
    int meStatus = 200, meDelay = 0, refreshStatus = 200;
    QString lastLoginToken, lastRefreshToken;
    QString scope = "station:live";
    QJsonArray cameraScope{"fixture-camera"};
    QByteArray extraHeaders;
    QList<QByteArray> stationRequests;
    Backend()
    {
        if (!listener.listen(QHostAddress::LocalHost, 0)) qFatal("Loopback listener unavailable");
        connect(&listener, &QTcpServer::newConnection, this, [this] {
            while (auto *socket = listener.nextPendingConnection()) {
                auto bytes = std::make_shared<QByteArray>();
                connect(socket, &QTcpSocket::readyRead, socket, [this, socket, bytes] {
                    *bytes += socket->readAll();
                    const int boundary = bytes->indexOf("\r\n\r\n");
                    if (boundary < 0 || socket->property("handled").toBool()) return;
                    int length = 0;
                    for (auto line : bytes->left(boundary).split('\n'))
                        if (line.toLower().startsWith("content-length:")) length = line.mid(15).trimmed().toInt();
                    if (bytes->size() < boundary + 4 + length) return;
                    socket->setProperty("handled", true);
                    const auto path = bytes->split(' ').value(1);
                    int status = 200, delay = 0;
                    QJsonObject result;
                    QByteArray headers;
                    if (path == "/client/stations/display-session") {
                        ++exchanges; stationRequests.append(*bytes);
                        status = stationStatus; delay = stationDelay; headers = extraHeaders;
                        result = {{"token", QString("display-%1").arg(exchanges)}, {"scope", scope},
                            {"expires_at", QDateTime::currentDateTimeUtc().addMSecs(ttlMs).toString(Qt::ISODateWithMs)},
                            {"station_id", "fixture-station"}, {"camera_scope", cameraScope}};
                        if (status != 200) result = {{"code", status == 429 ? "station_exchange_rate_limited" : "station_credential_rejected"}};
                    } else if (path == "/auth/login") {
                        ++logins; status = loginStatus; delay = loginDelay;
                        lastLoginToken = operatorToken(QString("login-%1").arg(logins));
                        result = {{"access_token", lastLoginToken}};
                        headers = "Set-Cookie: access_token=stale-server-cookie; Path=/\r\n";
                    } else if (path == "/auth/refresh") {
                        ++refreshes; delay = refreshDelay; status = refreshStatus;
                        lastRefreshToken = operatorToken(QString("refresh-%1").arg(refreshes));
                        result = {{"access_token", lastRefreshToken}};
                        headers = "Set-Cookie: access_token=stale-refresh-cookie; Path=/\r\n";
                    } else if (path == "/auth/me") { status = meStatus; delay = meDelay; result = {{"ok", true}}; }
                    else result = {{"ok", true}};
                    const auto body = QJsonDocument(result).toJson(QJsonDocument::Compact);
                    QTimer::singleShot(delay, socket, [socket, body, status, headers] {
                        if (socket->state() != QAbstractSocket::ConnectedState) return;
                        socket->write("HTTP/1.1 " + QByteArray::number(status) + " Fixture\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
                            + QByteArray::number(body.size()) + "\r\n" + headers + "\r\n" + body);
                        socket->disconnectFromHost();
                    });
                });
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
            }
        });
    }
    QString base() const { return QString("http://127.0.0.1:%1").arg(listener.serverPort()); }
};
QByteArray cookie(AuthController &auth, const QString &base)
{
    for (const auto &value : auth.nam()->cookieJar()->cookiesForUrl(QUrl(base)))
        if (value.name() == "access_token") return value.value();
    return {};
}
}

class StationSessionTest : public QObject {
    Q_OBJECT
    QTemporaryDir settings;
private slots:
    void initTestCase()
    {
        QVERIFY(settings.isValid());
        QCoreApplication::setOrganizationName("StationSessionLoopbackFixture");
        QCoreApplication::setApplicationName("StationSessionLoopbackFixture");
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, settings.path());
        QNetworkProxy::setApplicationProxy(QNetworkProxy::NoProxy);
        qunsetenv("WT_CV_AUTOLOGIN"); qunsetenv("WT_AUTH_RENEW_S"); qunsetenv("WT_CV_URL");
        qputenv("WT_NO_STATION_ENROL", "1");
    }
    void init() { QSettings().clear(); qunsetenv("WT_CV_AUTOLOGIN"); qunsetenv("WT_CV_USER"); qunsetenv("WT_CV_PASS"); qunsetenv("WT_AUTH_RENEW_S"); }
    void renewsWithoutDroppingWall()
    {
        Backend b; AuthController auth; QSignalSpy changed(&auth, &AuthController::authenticatedChanged);
        QNetworkCookie prior("access_token", "prior-operator-cookie"); prior.setPath("/");
        auth.nam()->cookieJar()->setCookiesFromUrl({prior}, QUrl(b.base()));
        auth.loginWithStationToken(b.base(), stationKey);
        QTRY_VERIFY(auth.stationSessionCurrent());
        QVERIFY(auth.authenticated()); QVERIFY(auth.stationLive()); QCOMPARE(auth.role(), "station");
        QCOMPARE(auth.cameraScope(), QStringList{"fixture-camera"}); QVERIFY(auth.token().isEmpty());
        QVERIFY(cookie(auth, b.base()).isEmpty());
        QTRY_VERIFY_WITH_TIMEOUT(b.exchanges >= 2, 3000);
        QTRY_COMPARE(auth.displaySession(), QString("display-2"));
        QCOMPARE(changed.count(), 1); QCOMPARE(b.refreshes, 0);
        QVERIFY(b.stationRequests.first().contains("X-Cilex-Station-Token: " + stationKey.toUtf8()));
        QVERIFY(!b.stationRequests.first().contains("Cookie:"));
        QVERIFY(QSettings().value("auth/token").toString().isEmpty());
    }
    void expiryKeepsVideoAndBacksOff()
    {
        Backend b; b.ttlMs = 800; AuthController auth;
        auth.loginWithStationToken(b.base(), stationKey); QTRY_VERIFY(auth.stationSessionCurrent());
        b.stationStatus = 503;
        QTRY_COMPARE_WITH_TIMEOUT(b.exchanges, 2, 1600);
        QTRY_VERIFY_WITH_TIMEOUT(!auth.stationSessionCurrent(), 1500);
        QVERIFY(auth.authenticated()); QVERIFY(auth.stationLive()); QVERIFY(!auth.errorString().isEmpty());
        const auto display = auth.displaySession();
        for (int i = 0; i < 50; ++i) auth.noteUnauthorized();
        QTest::qWait(200); QCOMPARE(b.exchanges, 2); QCOMPARE(auth.displaySession(), display);
        b.stationStatus = 200;
        QTRY_VERIFY_WITH_TIMEOUT(auth.stationSessionCurrent(), 6200);
        QCOMPARE(b.refreshes, 0);
    }
    void honorsRetryAfter()
    {
        Backend b; b.stationStatus = 429; b.extraHeaders = "Retry-After: 6\r\n"; AuthController auth;
        auth.loginWithStationToken(b.base(), stationKey); QTRY_COMPARE(b.exchanges, 1);
        b.stationStatus = 200; b.extraHeaders.clear();
        QTest::qWait(5200); QCOMPARE(b.exchanges, 1);
        QTRY_VERIFY_WITH_TIMEOUT(auth.stationSessionCurrent(), 2000);
    }
    void terminalRejectionDoesNotRetry()
    {
        Backend b; b.stationStatus = 401; AuthController auth;
        auth.loginWithStationToken(b.base(), stationKey); QTRY_COMPARE(b.exchanges, 1);
        QTest::qWait(5200); QCOMPARE(b.exchanges, 1); QVERIFY(!auth.authenticated());
    }
    void redirectNeverReceivesCredential()
    {
        Backend origin, other; origin.stationStatus = 307;
        origin.extraHeaders = "Location: " + other.base().toUtf8() + "/client/stations/display-session\r\n";
        AuthController auth; auth.loginWithStationToken(origin.base(), stationKey);
        QTRY_COMPARE(origin.exchanges, 1); QTest::qWait(250);
        QCOMPARE(other.exchanges, 0); QVERIFY(!auth.authenticated());
    }
    void rejectsWrongScopeAndExpiredSession()
    {
        Backend b; b.scope = "admin"; AuthController auth;
        auth.loginWithStationToken(b.base(), stationKey); QTRY_COMPARE(b.exchanges, 1);
        QTest::qWait(100); QVERIFY(!auth.authenticated());
        b.scope = "station:live"; b.ttlMs = -100;
        auth.loginWithStationToken(b.base(), stationKey); QTRY_COMPARE(b.exchanges, 2);
        QTest::qWait(100); QVERIFY(!auth.authenticated());
    }
    void operatorSupersedesPendingDisplay()
    {
        Backend b; b.stationDelay = 350; AuthController auth;
        auth.loginWithStationToken(b.base(), stationKey); QTRY_COMPARE(b.exchanges, 1);
        auth.loginWithPassword(b.base(), "fixture", "disposable");
        QTRY_VERIFY(auth.authenticated()); QTest::qWait(450);
        QVERIFY(!auth.stationLive()); QCOMPARE(auth.role(), "operator");
        QCOMPARE(cookie(auth, b.base()), b.lastLoginToken.toUtf8()); QVERIFY(auth.displaySession().isEmpty());
    }
    void operatorSupersedesEstablishedDisplay()
    {
        Backend b; AuthController auth; auth.loginWithStationToken(b.base(), stationKey);
        QTRY_VERIFY(auth.stationSessionCurrent());
        auth.loginWithPassword(b.base(), "fixture", "disposable"); QTRY_COMPARE(auth.role(), QString("operator"));
        QVERIFY(!auth.stationLive()); QVERIFY(!auth.stationSessionCurrent());
        QNetworkRequest request(QUrl(b.base() + "/streams")); auth.decorate(request);
        QVERIFY(!request.hasRawHeader("X-Cilex-Display-Session"));
        QTest::qWait(1800); QCOMPARE(b.exchanges, 1);
    }
    void failedOperatorLoginPreservesStation()
    {
        Backend b; AuthController auth; auth.loginWithStationToken(b.base(), stationKey);
        QTRY_VERIFY(auth.stationSessionCurrent()); b.loginStatus = 401;
        auth.loginWithPassword(b.base(), "fixture", "disposable"); QTRY_VERIFY(!auth.busy());
        QVERIFY(auth.authenticated()); QVERIFY(auth.stationLive());
        QTRY_VERIFY_WITH_TIMEOUT(b.exchanges >= 2, 1500);
    }
    void logoutFencesDelayedCookiesAndDisplay()
    {
        Backend b; b.loginDelay = 350; AuthController auth;
        auth.loginWithPassword(b.base(), "fixture", "disposable"); QTRY_COMPARE(b.logins, 1);
        auth.logout(); QTest::qWait(450);
        QVERIFY(!auth.authenticated()); QVERIFY(!auth.busy()); QVERIFY(cookie(auth, b.base()).isEmpty());
        b.stationDelay = 350; auth.loginWithStationToken(b.base(), stationKey); QTRY_COMPARE(b.exchanges, 1);
        auth.logout(); QTest::qWait(450);
        QVERIFY(!auth.authenticated()); QVERIFY(!auth.stationLive()); QVERIFY(auth.displaySession().isEmpty());
    }
    void newStationFencesOldOperatorAndDestination()
    {
        Backend old, current; old.loginDelay = 350; AuthController auth;
        auth.loginWithPassword(old.base(), "fixture", "disposable"); QTRY_COMPARE(old.logins, 1);
        auth.loginWithStationToken(current.base(), stationKey); QTRY_VERIFY(auth.stationSessionCurrent());
        QTest::qWait(450); QCOMPARE(auth.baseUrl(), current.base()); QCOMPARE(auth.role(), "station");
        QVERIFY(auth.token().isEmpty()); QVERIFY(cookie(auth, old.base()).isEmpty());
        old.stationDelay = 350; auth.loginWithStationToken(old.base(), stationKey); QTRY_COMPARE(old.exchanges, 1);
        auth.loginWithStationToken(current.base(), stationKey); QTRY_VERIFY(auth.stationSessionCurrent());
        QTest::qWait(450); QCOMPARE(auth.baseUrl(), current.base()); QCOMPARE(auth.role(), "station");
    }
    void outOfScopeDoesNotRenewEarly()
    {
        Backend b; AuthController auth; auth.loginWithStationToken(b.base(), stationKey);
        QTRY_VERIFY(auth.stationSessionCurrent());
        for (int i = 0; i < 100; ++i) auth.noteUnauthorized();
        QTest::qWait(200); QCOMPARE(b.exchanges, 1); QVERIFY(auth.authenticated());
    }
    void displayHeaderStaysOnItsOwnOrigin()
    {
        Backend b, other; AuthController auth; auth.loginWithStationToken(b.base(), stationKey);
        QTRY_VERIFY(auth.stationSessionCurrent());
        QNetworkRequest own(QUrl(b.base() + "/streams")), foreign(QUrl(other.base() + "/streams"));
        auth.decorate(own); auth.decorate(foreign);
        QVERIFY(own.hasRawHeader("X-Cilex-Display-Session"));
        QVERIFY(!foreign.hasRawHeader("X-Cilex-Display-Session"));
    }
    void expiryRemainsHonestWhileOperatorLoginWaits()
    {
        Backend b; b.ttlMs = 650; b.loginDelay = 1100; b.loginStatus = 401;
        AuthController auth; auth.loginWithStationToken(b.base(), stationKey);
        QTRY_VERIFY(auth.stationSessionCurrent());
        auth.loginWithPassword(b.base(), "fixture", "disposable");
        QTRY_VERIFY_WITH_TIMEOUT(!auth.stationSessionCurrent(), 900);
        QVERIFY(auth.authenticated()); QVERIFY(auth.stationLive()); QVERIFY(auth.busy());
        QTRY_VERIFY_WITH_TIMEOUT(!auth.busy(), 800);
        QTRY_VERIFY(auth.stationSessionCurrent());
    }
    void normalOperatorRefreshStillWorks()
    {
        Backend b; AuthController auth;
        auth.loginWithPassword(b.base(), "fixture", "disposable"); QTRY_VERIFY(auth.authenticated());
        const auto original = auth.token(); auth.noteUnauthorized();
        QTRY_COMPARE(b.refreshes, 1); QTRY_COMPARE(auth.token(), b.lastRefreshToken);
        QVERIFY(auth.token() != original); QVERIFY(auth.authenticated()); QVERIFY(!auth.stationLive());
        QCOMPARE(cookie(auth, b.base()), auth.token().toUtf8());
        for (int i = 0; i < 25; ++i) auth.noteUnauthorized();
        QTest::qWait(100); QCOMPARE(b.refreshes, 1);
    }
    void logoutFencesPendingRefreshCookie()
    {
        Backend b; b.refreshDelay = 350; AuthController auth;
        auth.loginWithPassword(b.base(), "fixture", "disposable"); QTRY_VERIFY(auth.authenticated());
        auth.noteUnauthorized(); QTRY_COMPARE(b.refreshes, 1); auth.logout(); QTest::qWait(450);
        QVERIFY(!auth.authenticated()); QVERIFY(cookie(auth, b.base()).isEmpty());
    }
    void lateSavedTokenRejectionCannotClearNewRefresh()
    {
        Backend b; b.meStatus = 401; b.meDelay = 350;
        QSettings().setValue("auth/baseUrl", b.base());
        QSettings().setValue("auth/token", operatorToken("saved"));
        AuthController auth; auth.restoreSession(); QVERIFY(auth.authenticated());
        auth.noteUnauthorized(); QTRY_COMPARE(auth.token(), b.lastRefreshToken);
        QTest::qWait(450); QVERIFY(auth.authenticated()); QCOMPARE(auth.token(), b.lastRefreshToken);
    }
    void oldPasswordRetryCannotResumeAfterStationSignIn()
    {
        Backend b; b.loginStatus = 503; AuthController auth;
        auth.loginWithPassword(b.base(), "fixture", "disposable"); QTRY_COMPARE(b.logins, 1);
        QTest::qWait(100); auth.loginWithStationToken(b.base(), stationKey);
        QTRY_VERIFY(auth.stationSessionCurrent()); QTest::qWait(1600);
        QCOMPARE(b.logins, 1); QVERIFY(auth.stationLive());
    }
    void missingServiceCredentialsAreNeverGuessed()
    {
        Backend b; b.refreshStatus = 401; AuthController auth;
        auth.loginWithPassword(b.base(), "fixture", "disposable"); QTRY_VERIFY(auth.authenticated());
        qputenv("WT_CV_AUTOLOGIN", "1"); auth.noteUnauthorized();
        QTRY_VERIFY(!auth.authenticated()); QCOMPARE(b.logins, 1);
    }
    void operatorAndStationSupersedePendingRefresh()
    {
        Backend b; b.refreshDelay = 350; AuthController auth;
        auth.loginWithPassword(b.base(), "fixture", "disposable"); QTRY_VERIFY(auth.authenticated());
        auth.noteUnauthorized(); QTRY_COMPARE(b.refreshes, 1);
        qputenv("WT_AUTH_RENEW_S", "1");
        auth.loginWithPassword(b.base(), "fixture", "disposable"); QTRY_COMPARE(b.logins, 2);
        QTRY_COMPARE(auth.token(), b.lastLoginToken); QTest::qWait(450);
        QCOMPARE(auth.token(), b.lastLoginToken); QCOMPARE(cookie(auth, b.base()), auth.token().toUtf8());
        QTRY_COMPARE_WITH_TIMEOUT(b.refreshes, 2, 1700);
        auth.loginWithStationToken(b.base(), stationKey); QTRY_VERIFY(auth.stationSessionCurrent());
        QTest::qWait(450);
        QVERIFY(auth.token().isEmpty()); QVERIFY(cookie(auth, b.base()).isEmpty());
    }
    void scopeRenewalNotifiesWithoutDroppingWall()
    {
        Backend b; AuthController auth; auth.loginWithStationToken(b.base(), stationKey);
        QTRY_VERIFY(auth.stationSessionCurrent());
        QSignalSpy identity(&auth, &AuthController::identityChanged);
        QSignalSpy authenticated(&auth, &AuthController::authenticatedChanged);
        b.cameraScope = {"fixture-camera-2"};
        QTRY_COMPARE_WITH_TIMEOUT(auth.cameraScope(), QStringList{"fixture-camera-2"}, 3000);
        QCOMPARE(identity.count(), 1); QCOMPARE(authenticated.count(), 0);
        auth.logout(); QTest::qWait(1800); QCOMPARE(b.exchanges, 2);
        QVERIFY(!auth.stationLive()); QVERIFY(!auth.stationSessionCurrent());
    }
    void invalidDestinationSendsNothing()
    {
        Backend b; AuthController auth;
        auth.loginWithStationToken("file:///not-a-server", stationKey);
        auth.loginWithStationToken(b.base() + "?redirect=other", stationKey);
        auto credentials = QUrl(b.base()); credentials.setUserInfo("fixture:disposable");
        auth.loginWithStationToken(credentials.toString(), stationKey);
        QTest::qWait(100); QCOMPARE(b.exchanges, 0); QVERIFY(!auth.authenticated());
    }
};
QTEST_GUILESS_MAIN(StationSessionTest)
#include "main.moc"
