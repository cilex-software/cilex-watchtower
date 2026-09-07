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
#include <QFile>
#include <QFileDevice>
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
    // No baked-in server. The old default pointed at a dead address over plain
    // http (audit 2026-09-03, finding INFO); the URL comes from WT_CV_URL, the
    // persisted setting, or the sign-in screen — never from a stale literal.
    m_baseUrl = env.value("WT_CV_URL");
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

int AuthController::loginAttemptsMax() const
{
    return kMaxLoginAttempts;
}

void AuthController::setLoginAttempt(int n)
{
    if (m_loginAttempt == n)
        return;
    m_loginAttempt = n;
    emit loginAttemptChanged();
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
    emit tokenChanged();
}

// Proactive session renewal: a guard's wall must never fall to a sign-in
// screen mid-shift because the token aged out. Renewal is credential-less
// (`POST /auth/refresh`, CV reply 2026-08-03) — renew at T-minus-10-min and
// models never see a 401. WT_AUTH_RENEW_S forces the delay (dev). The margin
// comfortably exceeds both the server's ±60 s decode leeway and the measured
// station-server skew (0 s on 2026-08-03).
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
    qInfo("[AUTH] refreshing session (token expires in %llds)",
          (long long)(m_exp - QDateTime::currentSecsSinceEpoch()));
    refreshSession();
}

void AuthController::refreshSession()
{
    QNetworkRequest req{QUrl(m_baseUrl + "/auth/refresh")};
    req.setTransferTimeout(kLoginTimeoutMs);
    req.setRawHeader("Cookie", "access_token=" + m_token.toUtf8());
    QNetworkReply *reply = m_nam->post(req, QByteArray());
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray raw = reply->readAll();
        if (code == 200) {
            const QString token =
                QJsonDocument::fromJson(raw).object().value(QStringLiteral("access_token")).toString();
            if (!token.isEmpty()) {
                applyToken(token);       // logs "[AUTH] token accepted", re-arms renewal
                persist();
                setAuthenticated(true);
                return;
            }
        }
        // Log the server's own sentence VERBATIM — the 2026-08-02 00:52 early
        // rejection was undiagnosable because nobody kept this string.
        const QString detail =
            QJsonDocument::fromJson(raw).object().value(QStringLiteral("detail")).toString();
        qWarning("[AUTH] refresh rejected (HTTP %d): \"%s\"", code,
                 qPrintable(detail.isEmpty() ? QString::fromUtf8(raw.left(120)) : detail));
        if (code == 401) {
            // Past saving: refresh renews, it does not resurrect. Dev boxes may
            // carry service creds (WT_CV_AUTOLOGIN, no longer defaulted anywhere);
            // stations drop honestly to sign-in.
            QString u, p;
            if (serviceCreds(u, p)) {
                qWarning("[AUTH] falling back to service re-login");
                loginWithPassword(m_baseUrl, u, p);
                return;
            }
            qWarning("[AUTH] session expired and no recovery path — dropping to sign-in");
            clearSession();
            emit sessionExpired();
            return;
        }
        // Transient (423/5xx/network): retry while the current token still has life.
        const qint64 left = m_exp - QDateTime::currentSecsSinceEpoch();
        if (++m_reauthFails < 3 && left > 240 && m_renewTimer)
            m_renewTimer->start(180 * 1000);
        else if (left <= 0) {
            clearSession();
            emit sessionExpired();
        }
    });
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
    // The settings file carries a live bearer token. Qt creates it with the
    // process umask (0664 measured, audit 2026-09-03 finding High 05), so any
    // account on the box could lift an operator session. Owner-only, explicitly,
    // every time we write it — never rely on the umask for a secret.
    s.sync();
    QFile::setPermissions(s.fileName(), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    // persist() runs exactly when the server has ACCEPTED a session (login or
    // refresh) — the one honest moment to record the URL in the history.
    rememberServer(m_baseUrl);
}

// --- Saved-servers history ---------------------------------------------------
// One JSON array under servers/history: [{"url":"https://…","nick":"Booth"}],
// most recent first. JSON-as-string (not a QSettings array) so the value is
// portable across the three platforms' native settings formats and trivially
// inspectable. Capped: this is a recall aid, not an inventory.
namespace {
constexpr int kServerHistoryMax = 10;
const QLatin1String kServerHistoryKey("servers/history");

QJsonArray loadServerHistory()
{
    return QJsonDocument::fromJson(QSettings().value(kServerHistoryKey).toByteArray()).array();
}

void saveServerHistory(const QJsonArray &a)
{
    QSettings().setValue(kServerHistoryKey,
                         QJsonDocument(a).toJson(QJsonDocument::Compact));
}
} // namespace

QVariantList AuthController::serverHistory() const
{
    QVariantList out;
    const QJsonArray a = loadServerHistory();
    for (const auto &v : a) {
        const QJsonObject o = v.toObject();
        const QString url = o.value(QLatin1String("url")).toString();
        if (url.isEmpty())
            continue;
        out.append(QVariantMap{{QStringLiteral("url"), url},
                               {QStringLiteral("nick"), o.value(QLatin1String("nick")).toString()}});
    }
    return out;
}

void AuthController::rememberServer(const QString &url)
{
    if (url.isEmpty())
        return;
    QJsonArray a = loadServerHistory();
    // Already freshest? Then this is a token refresh re-persisting — no churn.
    if (!a.isEmpty() && a.first().toObject().value(QLatin1String("url")).toString() == url)
        return;
    QString nick;   // an upsert keeps the operator's nickname
    for (int i = a.size() - 1; i >= 0; --i) {
        if (a.at(i).toObject().value(QLatin1String("url")).toString() == url) {
            nick = a.at(i).toObject().value(QLatin1String("nick")).toString();
            a.removeAt(i);
        }
    }
    a.prepend(QJsonObject{{QLatin1String("url"), url}, {QLatin1String("nick"), nick}});
    while (a.size() > kServerHistoryMax)
        a.removeAt(a.size() - 1);
    saveServerHistory(a);
    emit serverHistoryChanged();
}

void AuthController::setServerNickname(const QString &url, const QString &nickname)
{
    QJsonArray a = loadServerHistory();
    bool changed = false;
    for (int i = 0; i < a.size(); ++i) {
        QJsonObject o = a.at(i).toObject();
        if (o.value(QLatin1String("url")).toString() == url
                && o.value(QLatin1String("nick")).toString() != nickname) {
            o.insert(QLatin1String("nick"), nickname);
            a.replace(i, o);
            changed = true;
        }
    }
    if (!changed)
        return;
    saveServerHistory(a);
    emit serverHistoryChanged();
}

void AuthController::forgetServer(const QString &url)
{
    QJsonArray a = loadServerHistory();
    bool changed = false;
    for (int i = a.size() - 1; i >= 0; --i) {
        if (a.at(i).toObject().value(QLatin1String("url")).toString() == url) {
            a.removeAt(i);
            changed = true;
        }
    }
    if (!changed)
        return;
    saveServerHistory(a);
    emit serverHistoryChanged();
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
    setLoginAttempt(0);
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
        setLoginAttempt(m_loginAttempt + 1);
        if (m_loginAttempt < kMaxLoginAttempts) {
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
    setLoginAttempt(0);
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
        setLoginAttempt(m_loginAttempt + 1);
        if (m_loginAttempt < kMaxLoginAttempts) {
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
    // A 401 mid-session: the token died before (or despite) renewal, or a
    // model raced a renewal. Try ONE credential-less refresh in place — models
    // keep their state and retry on their own cadence; the wall never tears
    // down for a recoverable blip. Cooldown collapses the 401 burst from N
    // models into one attempt; refreshSession() itself escapes to sign-in
    // when the token is past saving.
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    if (nowMs - m_lastReauthMs > 60000 && m_reauthFails < 3) {
        m_lastReauthMs = nowMs;
        qWarning("[AUTH] 401 while authenticated — attempting session refresh in place");
        refreshSession();
        return;
    }
    if (m_reauthFails < 3)
        return;                         // attempt in flight (or cooling down)
    qWarning("[AUTH] session expired and no recovery path — dropping to sign-in");
    clearSession();
    emit sessionExpired();
}

void AuthController::logout()
{
    clearSession();
}
