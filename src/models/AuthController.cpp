#include "AuthController.h"
#include "ServerMessage.h"
#include "ServerCodes.h"
#include "StationEnrolment.h"
#include "StationNam.h"

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
#include <limits>

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
    user = env.value("WT_CV_USER");
    pass = env.value("WT_CV_PASS");
    return !user.isEmpty() && !pass.isEmpty();
}


AuthController::AuthController(QObject *parent)
    : QObject(parent), m_nam(new StationNam(this))
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
    connect(this, &AuthController::loginFailed, this, [this](const QString &) {
        if (!m_authenticated || m_stationLive)
            return;                     // interactive sign-in failure — not ours
        ++m_reauthFails;
        const qint64 left = m_exp - QDateTime::currentSecsSinceEpoch();
        qWarning("[AUTH] background re-login failed (#%d) — token has %llds left",
                 m_reauthFails, (long long)left);
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
    clearStationSession();             // a successful operator sign-in wins
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
        // Self-provision a station identity if this box has none (StationEnrolment.h).
        // Gated there: only under Warden, only when Warden reports NO token, only for an
        // admin session, once per process. Runs on the session the operator already has —
        // CV's POST /client/stations takes the ordinary cookie, so nobody ever mints,
        // carries or pastes a station token by hand.
        wt::enrolStation(m_nam, m_baseUrl, m_role, [](const QString &line) {
            qInfo("[STATION] %s", qUtf8Printable(line));
        });
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
    if (!m_authenticated || m_stationLive)
        return;
    qInfo("[AUTH] refreshing session (token expires in %llds)",
          (long long)(m_exp - QDateTime::currentSecsSinceEpoch()));
    refreshSession();
}

void AuthController::refreshSession()
{
    if (!m_authenticated || m_stationLive || m_refreshReply)
        return;
    const quint64 generation = m_authGeneration;
    QNetworkRequest req{QUrl(m_baseUrl + "/auth/refresh")};
    req.setAttribute(QNetworkRequest::CookieLoadControlAttribute, QNetworkRequest::Manual);
    req.setAttribute(QNetworkRequest::CookieSaveControlAttribute, QNetworkRequest::Manual);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    req.setTransferTimeout(kLoginTimeoutMs);
    req.setRawHeader("Cookie", "access_token=" + m_token.toUtf8());
    QNetworkReply *reply = m_nam->post(req, QByteArray());
    m_refreshReply = reply;
    connect(reply, &QNetworkReply::finished, this, [this, reply, generation]() {
        reply->deleteLater();
        if (generation != m_authGeneration)
            return;
        m_refreshReply.clear();
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
        // An error body can itself contain a bearer token. Keep diagnostics
        // useful without ever copying server response text into the auth log.
        qWarning("[AUTH] refresh rejected (HTTP %d)", code);
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
    invalidateAuthRequests();
    clearStationSession();
    m_token.clear();
    m_username.clear();
    m_role.clear();
    m_cameraScope.clear();
    m_exp = 0;
    m_pendingPassword.clear();
    m_pendingUser.clear();
    setBusy(false);
    // Replacing the jar drops the access_token cookie cleanly.
    m_nam->setCookieJar(new QNetworkCookieJar(m_nam));
    QSettings().remove("auth/token");
    emit identityChanged();
    setAuthenticated(false);
}

void AuthController::loginWithPassword(const QString &baseUrl, const QString &username,
                                      const QString &password)
{
    if (baseUrl != m_baseUrl)
        clearSession();               // never send a prior station header to a new server
    else
        invalidateAuthRequests();
    setError(QString());
    setBaseUrl(baseUrl);
    m_pendingUser = username;
    m_pendingPassword = password;
    setLoginAttempt(0);
    setBusy(true);
    attemptPasswordLogin(m_authGeneration);
}

void AuthController::attemptPasswordLogin(quint64 generation)
{
    if (generation != m_authGeneration)
        return;
    QNetworkRequest req{QUrl(m_baseUrl + "/auth/login")};
    req.setAttribute(QNetworkRequest::CookieSaveControlAttribute, QNetworkRequest::Manual);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setTransferTimeout(kLoginTimeoutMs);
    const QJsonObject body{{"username", m_pendingUser}, {"password", m_pendingPassword}};
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, generation]() {
        reply->deleteLater();
        if (generation != m_authGeneration)
            return;
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray raw = reply->readAll();
        if (reply->error() == QNetworkReply::NoError && code == 200) {
            const QString token = QJsonDocument::fromJson(raw).object().value("access_token").toString();
            setBusy(false);
            m_pendingPassword.clear();
            if (token.isEmpty()) {
                resumeStationSession();
                setError(tr("Login response did not include a token"));
                emit loginFailed(m_errorString);
                return;
            }
            applyToken(token);
            persist();
            setAuthenticated(true);
            return;
        }
        // Hard rejection: the server gave a definitive answer — do not retry.
        //
        // 423 BELONGS HERE and was missing. CV's sign-in 423 is `service_suspended`
        // (their reply15 §2) — a provider/billing state a human must lift, not a blip.
        // It fell through to the transient branch below and, after four retries, told a
        // guard "Could not reach the server" while the server had answered promptly with
        // the exact reason. Not merely unlocalised: FALSE, and it sends whoever is called
        // out to check the network for a fault that is not there.
        if (code == 401 || code == 403 || code == 400 || code == 423) {
            setBusy(false);
            m_pendingPassword.clear();
            resumeStationSession();
            // `message ?? detail` (serverMessage above): on the SSO sites `detail` is the
            // raw enum — "SSO_TOKEN_EXPIRED" — and the sentence is in `message`. Reading
            // `detail` alone put that enum on a guard's sign-in screen.
            //
            // Still ENGLISH prose, and still not localisable here: matching on the text
            // would break the day CV rewords it. What CV shipped is the part that IS
            // matchable — a stable `code` beside it (invalid_credentials, SSO_TOKEN_EXPIRED,
            // account_deactivated, service_suspended, not_authenticated, role_not_authorized,
            // …). e8b0a4a gave 15 on routers/auth.py; 654b9df et al added the seven shared
            // sites in auth/jwt.py the same night (count as of 2026-09-20 — do not trust a
            // number here over CV's own table, which is the only thing that moves).
            // Mapping those to Russian copy is the follow-up, and it is UNBLOCKED as of
            // 2026-09-20 (docs/BACKLOG.md). Until then the server's sentence beats the
            // server's enum, which is what this line buys.
            // The fallback below is OURS, so it is translated; it fires only when CV sends
            // neither key, which for bad credentials it does not.
            QString detail = wt::localisedServerError(raw);
            if (detail.isEmpty())
                detail = tr("Invalid username or password");
            setError(detail);
            emit loginFailed(detail);
            return;
        }
        // Transient (server not ready / network): retry before giving up.
        setLoginAttempt(m_loginAttempt + 1);
        if (m_loginAttempt < kMaxLoginAttempts) {
            QTimer::singleShot(kLoginRetryMs, this, [this, generation]() { attemptPasswordLogin(generation); });
            return;
        }
        setBusy(false);
        m_pendingPassword.clear();
        resumeStationSession();
        // Only claim unreachability when NOTHING answered. `code == 0` is this repo's
        // convention for no HTTP response at all (transport failure); any other code means
        // the server replied and we simply have no branch for it. Saying "could not reach
        // the server" then is an invented diagnosis — the 423 case above is how that was
        // found, and the same lie was waiting behind every unhandled status.
        QString why;
        if (code == 0)
            why = tr("Could not reach the server");
        else {
            why = wt::localisedServerError(raw);
            if (why.isEmpty())
                why = tr("The server refused the sign-in (HTTP %1)").arg(code);
        }
        setError(why);
        emit loginFailed(m_errorString);
    });
}

void AuthController::loginWithToken(const QString &baseUrl, const QString &token)
{
    // Off by the owner's decision (kPersonalTokenSignIn, AuthController.h). The login screen no
    // longer offers it; this refuses anyone else who calls it. Nothing below is removed.
    if (!kPersonalTokenSignIn) {
        setError(tr("Signing in with a token is switched off"));
        emit loginFailed(m_errorString);
        return;
    }
    invalidateAuthRequests();
    setError(QString());
    setBaseUrl(baseUrl);
    const QString tok = token.trimmed();
    if (tok.isEmpty()) {
        setError(tr("Enter a token"));
        emit loginFailed(m_errorString);
        return;
    }
    QString u, r;
    QStringList sc;
    qint64 e = 0;
    if (!decodeClaims(tok, u, r, sc, e)) {
        setError(tr("That does not look like a valid token"));
        emit loginFailed(m_errorString);
        return;
    }
    applyToken(tok);
    setLoginAttempt(0);
    setBusy(true);
    attemptTokenLogin(m_authGeneration);
}

void AuthController::attemptTokenLogin(quint64 generation)
{
    if (generation != m_authGeneration)
        return;
    QNetworkRequest req{QUrl(m_baseUrl + "/auth/me")};
    req.setAttribute(QNetworkRequest::CookieSaveControlAttribute, QNetworkRequest::Manual);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    req.setTransferTimeout(kLoginTimeoutMs);
    QNetworkReply *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply, generation]() {
        reply->deleteLater();
        if (generation != m_authGeneration)
            return;
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
            setError(tr("Token rejected or expired"));
            emit loginFailed(m_errorString);
            return;
        }
        // Transient (server not ready / network): retry before giving up.
        setLoginAttempt(m_loginAttempt + 1);
        if (m_loginAttempt < kMaxLoginAttempts) {
            QTimer::singleShot(kLoginRetryMs, this, [this, generation]() { attemptTokenLogin(generation); });
            return;
        }
        setBusy(false);
        clearSession();
        setError(tr("Could not reach the server"));
        emit loginFailed(m_errorString);
    });
}

void AuthController::decorate(QNetworkRequest &req) const
{
    const QUrl origin(m_stationBaseUrl), target(req.url());
    const auto effectivePort = [](const QUrl &url) { return url.port(url.scheme() == QLatin1String("https") ? 443 : 80); };
    if (m_stationLive && !m_displaySession.isEmpty() && target.scheme() == origin.scheme()
        && target.host() == origin.host() && effectivePort(target) == effectivePort(origin))
        req.setRawHeader("X-Cilex-Display-Session", m_displaySession.toUtf8());
}

void AuthController::loginWithStationToken(const QString &baseUrl, const QString &stationToken)
{
    const QUrl destination(baseUrl);
    if (!destination.isValid() || destination.host().isEmpty()
        || (destination.scheme() != QLatin1String("http") && destination.scheme() != QLatin1String("https"))
        || !destination.userInfo().isEmpty() || destination.hasQuery() || destination.hasFragment()
        || stationToken.trimmed().isEmpty()) {
        setError(tr("Station sign-in settings are invalid"));
        if (!m_authenticated || m_stationLive) emit loginFailed(m_errorString);
        return;
    }
    if (baseUrl != m_baseUrl)
        clearSession();
    else
        invalidateAuthRequests();
    setError(QString());
    setBaseUrl(baseUrl);
    setBusy(false);
    m_pendingPassword.clear();
    m_pendingUser.clear();
    m_stationBaseUrl = baseUrl;
    m_stationToken = stationToken;
    m_stationFailures = 0;
    m_stationRetryDelayMs = 0;
    m_stationRetryClock.invalidate();
    if (!m_stationRenewTimer) {
        m_stationRenewTimer = new QTimer(this);
        m_stationRenewTimer->setSingleShot(true);
        connect(m_stationRenewTimer, &QTimer::timeout, this, &AuthController::requestStationSession);
        m_stationExpiryTimer = new QTimer(this);
        m_stationExpiryTimer->setSingleShot(true);
        connect(m_stationExpiryTimer, &QTimer::timeout, this, &AuthController::expireStationSession);
    }
    requestStationSession();
}

void AuthController::invalidateAuthRequests()
{
    ++m_authGeneration;
    if (m_renewTimer) m_renewTimer->stop();
    if (m_stationRenewTimer) m_stationRenewTimer->stop();
    const auto station = m_stationReply;
    const auto refresh = m_refreshReply;
    m_stationReply.clear();
    m_refreshReply.clear();
    if (station) station->abort();
    if (refresh) refresh->abort();
}

void AuthController::clearStationSession()
{
    const bool wasStation = m_stationLive;
    const bool wasCurrent = m_stationSessionCurrent;
    if (m_stationRenewTimer) m_stationRenewTimer->stop();
    if (m_stationExpiryTimer) m_stationExpiryTimer->stop();
    m_stationToken.clear();
    m_stationBaseUrl.clear();
    m_displaySession.clear();
    m_stationExpiresMs = 0;
    m_stationLive = false;
    m_stationSessionCurrent = false;
    m_stationRetryDelayMs = 0;
    m_stationRetryClock.invalidate();
    if (wasStation) emit stationLiveChanged();
    if (wasCurrent) emit stationSessionChanged();
}

void AuthController::expireStationSession()
{
    if (!m_stationLive || !m_stationSessionCurrent)
        return;
    m_stationSessionCurrent = false;
    setError(tr("Station live information is unavailable; existing video is kept"));
    emit stationSessionChanged();
    // Keep the roster, surfaces and RTSP pipelines. An unavailable API is not
    // evidence that a camera stopped, and must never erase a flowing picture.
}

void AuthController::resumeStationSession()
{
    if (!m_stationLive || m_stationToken.isEmpty())
        return;
    const qint64 left = m_stationExpiresMs - QDateTime::currentMSecsSinceEpoch();
    if (left <= 0) expireStationSession();
    else m_stationExpiryTimer->start(int(qMin<qint64>(left, 86400000)));
    requestStationSession();
}

void AuthController::requestStationSession()
{
    if (m_busy || m_stationToken.isEmpty() || m_stationBaseUrl != m_baseUrl || m_stationReply)
        return;
    // Retry-After uses elapsed time: changing the PC clock cannot bypass it.
    if (m_stationRetryClock.isValid() && m_stationRetryClock.elapsed() < m_stationRetryDelayMs) {
        m_stationRenewTimer->start(int(qMin<qint64>(m_stationRetryDelayMs - m_stationRetryClock.elapsed(), 86400000)));
        return;
    }
    const quint64 generation = m_authGeneration;
    QNetworkRequest req{QUrl(m_stationBaseUrl + "/client/stations/display-session")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    req.setAttribute(QNetworkRequest::CookieLoadControlAttribute, QNetworkRequest::Manual);
    req.setAttribute(QNetworkRequest::CookieSaveControlAttribute, QNetworkRequest::Manual);
    req.setRawHeader("X-Cilex-Station-Token", m_stationToken.toUtf8());
    req.setTransferTimeout(kLoginTimeoutMs);
    QNetworkReply *reply = m_nam->post(req, QByteArrayLiteral("{}"));
    m_stationReply = reply;
    connect(reply, &QNetworkReply::finished, this, [this, reply, generation]() {
        reply->deleteLater();
        if (generation != m_authGeneration)
            return;
        m_stationReply.clear();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
        const QString tok = o.value("token").toString();
        auto expires = QDateTime::fromString(o.value("expires_at").toString(), Qt::ISODateWithMs);
        if (!expires.isValid()) expires = QDateTime::fromString(o.value("expires_at").toString(), Qt::ISODate);
        const qint64 ttl = expires.toMSecsSinceEpoch() - QDateTime::currentMSecsSinceEpoch();
        if (code != 200 || tok.isEmpty() || o.value("scope").toString() != QLatin1String("station:live")
            || !expires.isValid() || ttl <= 0 || ttl > 86400000) {
            // No server text/body, URL or credential is logged on this path.
            qWarning("[AUTH] station display-session unavailable (HTTP %d)", code);
            if (code == 401 || code == 403 || (code >= 300 && code < 500 && code != 429)) {
                m_stationToken.clear(); // explicit reconfiguration is required after rejection
                setError(tr("Station credential rejected"));
                if (o.value("code").toString() == QLatin1String("station_revoked")) expireStationSession();
                if (!m_authenticated || m_stationLive) emit loginFailed(m_errorString);
                return;
            }
            const int delays[] = {5000, 15000, 30000, 60000};
            qint64 delay = delays[qMin(m_stationFailures++, 3)];
            if (code == 429) {
                const QByteArray retry = reply->rawHeader("Retry-After").trimmed();
                bool numeric = false;
                const qint64 seconds = retry.toLongLong(&numeric);
                if (numeric && seconds >= 0)
                    delay = qMax(delay, qMin<qint64>(seconds, std::numeric_limits<qint64>::max() / 1000) * 1000);
                else {
                    const auto date = QDateTime::fromString(QString::fromLatin1(retry), Qt::RFC2822Date);
                    if (date.isValid()) delay = qMax(delay, QDateTime::currentDateTimeUtc().msecsTo(date));
                }
            }
            m_stationRetryDelayMs = delay;
            m_stationRetryClock.start();
            m_stationRenewTimer->start(int(qMin<qint64>(delay, 86400000)));
            if (!m_stationLive) setError(tr("Station live information is unavailable"));
            return;
        }
        if (m_renewTimer) m_renewTimer->stop();
        m_token.clear();
        m_exp = 0;
        const auto previousScope = m_cameraScope;
        m_cameraScope.clear();
        for (const auto &camera : o.value("camera_scope").toArray()) m_cameraScope.append(camera.toString());
        m_nam->setCookieJar(new QNetworkCookieJar(m_nam));
        m_displaySession = tok;
        const bool wasStation = m_stationLive;
        m_stationLive = true;
        m_stationSessionCurrent = true;
        m_stationExpiresMs = expires.toMSecsSinceEpoch();
        m_username = QStringLiteral("station");
        m_role = QStringLiteral("station");
        m_stationFailures = 0;
        m_stationRetryDelayMs = 0;
        m_stationRetryClock.invalidate();
        setError(QString());
        m_stationExpiryTimer->start(int(ttl));
        m_stationRenewTimer->start(int(qMax<qint64>(100, ttl - qBound<qint64>(100LL, ttl / 4, 60000LL))));
        qInfo("[AUTH] station live session accepted; renewal scheduled");
        if (!wasStation) { emit stationLiveChanged(); emit tokenChanged(); }
        if (!wasStation || previousScope != m_cameraScope) emit identityChanged();
        emit stationSessionChanged();
        setAuthenticated(true);
    });
}

void AuthController::restoreSession()
{
    invalidateAuthRequests();
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
    const quint64 generation = m_authGeneration;
    const QString restoredToken = m_token;
    QNetworkRequest req{QUrl(m_baseUrl + "/auth/me")};
    req.setAttribute(QNetworkRequest::CookieSaveControlAttribute, QNetworkRequest::Manual);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    QNetworkReply *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply, generation, restoredToken]() {
        reply->deleteLater();
        if (generation != m_authGeneration || m_token != restoredToken)
            return;
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) {
            clearSession();
            emit sessionExpired();
        }
    });
}

void AuthController::noteUnauthorized()
{
    // Station live mode: only /streams and snapshots are in scope; events, groups,
    // The Watch, review all answer 401/403 BY DESIGN. Those are not a dead session
    // and must not drop the wall to sign-in (measured 2026-09-08: the wall lit,
    // then three out-of-scope 401s tore it down within 20 ms).
    if (m_stationLive) {
        if (!m_stationSessionCurrent || QDateTime::currentMSecsSinceEpoch() >= m_stationExpiresMs) {
            expireStationSession();
            requestStationSession();
        }
        return;
    }
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
