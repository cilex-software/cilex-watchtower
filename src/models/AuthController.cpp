#include "AuthController.h"

#include <QNetworkAccessManager>
#include <QNetworkCookie>
#include <QNetworkCookieJar>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QProcessEnvironment>
#include <QSettings>
#include <QDateTime>
#include <QRegularExpression>
#include <QUrl>
#include <QTimer>

namespace {
// A login may be issued while the backend is still coming up (Watchtower and
// cilex-vision boot together on the same host). Retry transient failures before
// telling the operator the server is unreachable.
constexpr int kMaxLoginAttempts = 4;
constexpr int kLoginRetryMs = 1500;
constexpr int kLoginTimeoutMs = 8000;
}

AuthController *AuthController::s_instance = nullptr;

// Service credentials for unattended re-login (guard stations run 24/7; the
// backend token lives ~10 h — measured twice on 2026-08-02/03). Present when
// WT_CV_AUTOLOGIN is set: the same contract as the boot auto-login in main().
static bool serviceCreds(QString &user, QString &pass)
{
    if (!qEnvironmentVariableIsSet("WT_CV_AUTOLOGIN"))
        return false;
    const auto env = QProcessEnvironment::systemEnvironment();
    user = env.value("WT_CV_USER", "admin");
    pass = env.value("WT_CV_PASS", "admin");
    return true;
}

AuthController::AuthController(QObject *parent)
    : QObject(parent), m_nam(new QNetworkAccessManager(this))
{
    s_instance = this;
    const auto env = QProcessEnvironment::systemEnvironment();
    m_baseUrl = env.value("WT_CV_URL", "http://192.168.1.79:8000");
    // Background re-login failures (renewNow / noteUnauthorized): keep the wall
    // up while the token is still valid, retry shortly, and only after repeated
    // failures fall back to the sign-in screen — a dead-quiet wall is the worst
    // outcome (observed 2026-08-03: token expired 11:07, livePipes=0 for an
    // hour with no operator-visible cause).
    connect(this, &AuthController::loginFailed, this, [this](const QString &why) {
        if (!m_authenticated)
            return;                     // interactive sign-in failure — not ours
        ++m_reauthFails;
        const qint64 left = m_exp - QDateTime::currentSecsSinceEpoch();
        qWarning("[AUTH] background re-login failed (#%d, %s) — token has %llds left",
                 m_reauthFails, qPrintable(why), (long long)left);
        if (m_reauthFails >= 3) {
            qWarning("[AUTH] giving up on background re-login — dropping to sign-in");
            clearSession();
            emit sessionExpired();
        } else if (left > 240 && m_renewTimer) {
            m_renewTimer->start(180 * 1000);
        }
    });
}

QString AuthController::initials() const
{
    if (m_username.isEmpty())
        return QString();
    const QStringList parts =
        m_username.split(QRegularExpression("[^A-Za-z0-9]+"), Qt::SkipEmptyParts);
    QString s;
    if (parts.size() >= 2)
        s = parts.at(0).left(1) + parts.at(1).left(1);
    else
        s = m_username.left(2);
    return s.toUpper();
}

void AuthController::setBusy(bool b)
{
    if (m_busy == b)
        return;
    m_busy = b;
    emit busyChanged();
}

void AuthController::setError(const QString &e)
{
    if (m_errorString == e)
        return;
    m_errorString = e;
    emit errorChanged();
}

void AuthController::setBaseUrl(const QString &url)
{
    if (url.isEmpty() || url == m_baseUrl)
        return;
    m_baseUrl = url;
    emit baseUrlChanged();
}

void AuthController::setAuthenticated(bool a)
{
    if (m_authenticated == a)
        return;
    m_authenticated = a;
    emit authenticatedChanged();
}

bool AuthController::decodeClaims(const QString &token, QString &username, QString &role,
                                 QStringList &scope, qint64 &expSecs)
{
    const QStringList parts = token.split('.');
    if (parts.size() < 2)
        return false;
    QByteArray payload = parts.at(1).toUtf8();
    while (payload.size() % 4 != 0)        // base64url is unpadded; pad for Qt
        payload.append('=');
    const QByteArray json = QByteArray::fromBase64(payload, QByteArray::Base64UrlEncoding);
    const QJsonObject o = QJsonDocument::fromJson(json).object();
    if (o.isEmpty())
        return false;
    username = o.value("username").toString();
    role = o.value("role").toString();
    scope.clear();
    for (const auto &v : o.value("camera_scope").toArray())
        scope.append(v.toString());
    expSecs = qint64(o.value("exp").toDouble());
    return !role.isEmpty();
}

void AuthController::applyToken(const QString &token)
{
    m_token = token;
    QNetworkCookie cookie("access_token", token.toUtf8());
    cookie.setPath("/");
    m_nam->cookieJar()->setCookiesFromUrl({cookie}, QUrl(m_baseUrl));

    QString u, r;
    QStringList sc;
    qint64 e = 0;
    if (decodeClaims(token, u, r, sc, e)) {
        m_username = u;
        m_role = r;
        m_cameraScope = sc;
        m_exp = e;
        m_reauthFails = 0;
        qInfo("[AUTH] token accepted user=%s role=%s ttl=%llds", qPrintable(u), qPrintable(r),
              (long long)(e - QDateTime::currentSecsSinceEpoch()));
        emit identityChanged();
        armRenewal();
    }
}

// Proactive session renewal: a guard's wall must never fall to a sign-in
// screen mid-shift because the token aged out. With service creds, re-login
// T-minus-10-min (seamless — models never see a 401); without them, warn
// loudly so the coming sign-in is at least announced. WT_AUTH_RENEW_S forces
// the delay (dev).
void AuthController::armRenewal()
{
    if (!m_renewTimer) {
        m_renewTimer = new QTimer(this);
        m_renewTimer->setSingleShot(true);
        connect(m_renewTimer, &QTimer::timeout, this, &AuthController::renewNow);
    }
    qint64 delayS = qEnvironmentVariableIntValue("WT_AUTH_RENEW_S");
    if (delayS <= 0) {
        if (m_exp <= 0)
            return;                     // no exp claim — nothing to schedule
        delayS = qMax<qint64>(30, m_exp - QDateTime::currentSecsSinceEpoch() - 600);
    }
    m_renewTimer->start(int(qMin<qint64>(delayS, 86400) * 1000));
    qInfo("[AUTH] session renewal armed in %llds", (long long)delayS);
}

void AuthController::renewNow()
{
    QString u, p;
    const qint64 left = m_exp - QDateTime::currentSecsSinceEpoch();
    if (serviceCreds(u, p)) {
        qInfo("[AUTH] proactive re-login (token expires in %llds)", (long long)left);
        loginWithPassword(m_baseUrl, u, p);
    } else {
        qWarning("[AUTH] token expires in %llds and no service credentials are set "
                 "(WT_CV_AUTOLOGIN) — the app will drop to sign-in when it does",
                 (long long)left);
    }
}

// Dev/test (WT_AUTH_EXPIRE_S): poison the live token in memory + cookie jar so
// the next backend round-trip 401s — the real expiry path, without the 10 h.
void AuthController::corruptTokenForTest()
{
    qWarning("[AUTH] TEST: corrupting session token now");
    m_token = QStringLiteral("wt-test-expired");
    QNetworkCookie cookie("access_token", m_token.toUtf8());
    cookie.setPath("/");
    m_nam->cookieJar()->setCookiesFromUrl({cookie}, QUrl(m_baseUrl));
}

void AuthController::persist()
{
    QSettings s;
    s.setValue("auth/token", m_token);
    s.setValue("auth/baseUrl", m_baseUrl);
}

void AuthController::clearSession()
{
    m_token.clear();
    m_username.clear();
    m_role.clear();
    m_cameraScope.clear();
    m_exp = 0;
    // Replacing the jar drops the access_token cookie cleanly.
    m_nam->setCookieJar(new QNetworkCookieJar(m_nam));
    QSettings().remove("auth/token");
    emit identityChanged();
    setAuthenticated(false);
}

void AuthController::loginWithPassword(const QString &baseUrl, const QString &username,
                                      const QString &password)
{
    setError(QString());
    setBaseUrl(baseUrl);
    m_pendingUser = username;
    m_pendingPassword = password;
    m_loginAttempt = 0;
    setBusy(true);
    attemptPasswordLogin();
}

void AuthController::attemptPasswordLogin()
{
    QNetworkRequest req{QUrl(m_baseUrl + "/auth/login")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setTransferTimeout(kLoginTimeoutMs);
    const QJsonObject body{{"username", m_pendingUser}, {"password", m_pendingPassword}};
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray raw = reply->readAll();
        if (reply->error() == QNetworkReply::NoError && code == 200) {
            const QString token = QJsonDocument::fromJson(raw).object().value("access_token").toString();
            setBusy(false);
            m_pendingPassword.clear();
            if (token.isEmpty()) {
                setError(QStringLiteral("Login response did not include a token"));
                emit loginFailed(m_errorString);
                return;
            }
            applyToken(token);
            persist();
            setAuthenticated(true);
            return;
        }
        // Hard rejection (bad credentials / bad request): don't retry.
        if (code == 401 || code == 403 || code == 400) {
            setBusy(false);
            m_pendingPassword.clear();
            QString detail = QJsonDocument::fromJson(raw).object().value("detail").toString();
            if (detail.isEmpty())
                detail = QStringLiteral("Invalid username or password");
            setError(detail);
            emit loginFailed(detail);
            return;
        }
        // Transient (server not ready / network): retry before giving up.
        if (++m_loginAttempt < kMaxLoginAttempts) {
            QTimer::singleShot(kLoginRetryMs, this, [this]() { attemptPasswordLogin(); });
            return;
        }
        setBusy(false);
        m_pendingPassword.clear();
        setError(QStringLiteral("Could not reach the server"));
        emit loginFailed(m_errorString);
    });
}

void AuthController::loginWithToken(const QString &baseUrl, const QString &token)
{
    setError(QString());
    setBaseUrl(baseUrl);
    const QString tok = token.trimmed();
    if (tok.isEmpty()) {
        setError(QStringLiteral("Enter a token"));
        emit loginFailed(m_errorString);
        return;
    }
    QString u, r;
    QStringList sc;
    qint64 e = 0;
    if (!decodeClaims(tok, u, r, sc, e)) {
        setError(QStringLiteral("That does not look like a valid token"));
        emit loginFailed(m_errorString);
        return;
    }
    applyToken(tok);
    m_loginAttempt = 0;
    setBusy(true);
    attemptTokenLogin();
}

void AuthController::attemptTokenLogin()
{
    QNetworkRequest req{QUrl(m_baseUrl + "/auth/me")};
    req.setTransferTimeout(kLoginTimeoutMs);
    QNetworkReply *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() == QNetworkReply::NoError && code == 200) {
            setBusy(false);
            persist();
            setAuthenticated(true);
            return;
        }
        // Token actually rejected: don't retry.
        if (code == 401 || code == 403) {
            setBusy(false);
            clearSession();
            setError(QStringLiteral("Token rejected or expired"));
            emit loginFailed(m_errorString);
            return;
        }
        // Transient (server not ready / network): retry before giving up.
        if (++m_loginAttempt < kMaxLoginAttempts) {
            QTimer::singleShot(kLoginRetryMs, this, [this]() { attemptTokenLogin(); });
            return;
        }
        setBusy(false);
        clearSession();
        setError(QStringLiteral("Could not reach the server"));
        emit loginFailed(m_errorString);
    });
}

void AuthController::restoreSession()
{
    QSettings s;
    const QString url = s.value("auth/baseUrl").toString();
    if (!url.isEmpty())
        setBaseUrl(url);
    const QString token = s.value("auth/token").toString();
    if (token.isEmpty())
        return;

    QString u, r;
    QStringList sc;
    qint64 e = 0;
    if (!decodeClaims(token, u, r, sc, e) || e <= QDateTime::currentSecsSinceEpoch()) {
        clearSession();
        return;
    }
    applyToken(token);
    setAuthenticated(true);

    // Revalidate in the background to catch server-side revocation.
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/auth/me")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) {
            clearSession();
            emit sessionExpired();
        }
    });
}

void AuthController::noteUnauthorized()
{
    if (!m_authenticated)
        return;
    // A 401 mid-session: the token died before (or despite) renewal. With
    // service creds, recover IN PLACE — models keep their state and retry on
    // their own cadence; the wall never tears down. Cooldown collapses the
    // 401 burst from N models into one attempt; repeated failures escape to
    // the sign-in screen via the loginFailed hook in the constructor.
    QString u, p;
    if (serviceCreds(u, p)) {
        const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
        if (nowMs - m_lastReauthMs > 60000 && m_reauthFails < 3) {
            m_lastReauthMs = nowMs;
            qWarning("[AUTH] 401 while authenticated — service re-login in place");
            loginWithPassword(m_baseUrl, u, p);
        }
        if (m_reauthFails < 3)
            return;                     // attempt in flight (or cooling down)
    }
    qWarning("[AUTH] session expired and no recovery path — dropping to sign-in");
    clearSession();
    emit sessionExpired();
}

void AuthController::logout()
{
    clearSession();
}
