#pragma once

#include <QObject>
#include <QNetworkRequest>
#include <QString>
#include <QStringList>
#include <QVariantList>

class QNetworkAccessManager;

// Single source of truth for the operator session. Owns the one shared
// QNetworkAccessManager every backend-talking model uses, so logging in once
// authenticates the whole app (the cilex-vision JWT lives in the shared cookie
// jar as `access_token`). The app shell is gated on `authenticated`.
//
// Registered as a singleton INSTANCE in main.cpp (qmlRegisterSingletonInstance)
// rather than QML_SINGLETON, so the instance exists before any QML-instantiated
// model is constructed and `AuthController::instance()` is valid in their ctors.
class AuthController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool authenticated READ authenticated NOTIFY authenticatedChanged)
    // STATION LIVE MODE (2026-09-08). The app authenticates with the station's own
    // credential via CV's display-session contract (POST /client/stations/display-session,
    // header X-Cilex-Display-Session), scope station:live. It lights the LIVE wall —
    // /streams and snapshots — and nothing else: review, mosaic, events, groups are
    // out of scope by DESIGN ("the PAST is an act by a person") and stay 401/403.
    // Activated by WT_STATION_TOKEN at boot; an operator sign-in always supersedes it.
    Q_PROPERTY(bool stationLive READ stationLive NOTIFY stationLiveChanged)
    Q_PROPERTY(QString baseUrl READ baseUrl NOTIFY baseUrlChanged)
    Q_PROPERTY(QString username READ username NOTIFY identityChanged)
    Q_PROPERTY(QString role READ role NOTIFY identityChanged)
    Q_PROPERTY(bool isAdmin READ isAdmin NOTIFY identityChanged)
    Q_PROPERTY(QString initials READ initials NOTIFY identityChanged)
    Q_PROPERTY(QStringList cameraScope READ cameraScope NOTIFY identityChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    // 1-based position on the login retry ladder while busy ("attempt 2 of 4").
    // Moves past 1 only when an attempt has already timed out — the login
    // screen uses that to say "trying to reach server" instead of guessing.
    Q_PROPERTY(int loginAttempt READ loginAttempt NOTIFY loginAttemptChanged)
    Q_PROPERTY(int loginAttemptsMax READ loginAttemptsMax CONSTANT)
    Q_PROPERTY(QString errorString READ errorString NOTIFY errorChanged)
    // Servers that have ACCEPTED a login (most recent first), each with an
    // operator-assigned nickname — the login screen's saved-servers dropdown.
    // Only successful logins are recorded: a typo never becomes a suggestion.
    Q_PROPERTY(QVariantList serverHistory READ serverHistory NOTIFY serverHistoryChanged)

public:
    explicit AuthController(QObject *parent = nullptr);

    static AuthController *instance() { return s_instance; }

    bool authenticated() const { return m_authenticated; }
    QString baseUrl() const { return m_baseUrl; }
    QString username() const { return m_username; }
    QString role() const { return m_role; }
    bool isAdmin() const { return m_role.compare(QStringLiteral("admin"), Qt::CaseInsensitive) == 0; }
    QString initials() const;
    QStringList cameraScope() const { return m_cameraScope; }
    bool busy() const { return m_busy; }
    int loginAttempt() const { return m_loginAttempt + 1; }
    int loginAttemptsMax() const;
    QString errorString() const { return m_errorString; }

    // Shared, session-authenticated network manager used by all models.
    QNetworkAccessManager *nam() const { return m_nam; }
    // The raw session token (the `access_token` cookie value) — for off-GUI-thread
    // consumers that run their own QNetworkAccessManager (e.g. the HLS proxy thread).
    QString token() const { return m_token; }
    bool stationLive() const { return m_stationLive; }
    QString displaySession() const { return m_displaySession; }
    // Attach the station display header when in station mode (no-op otherwise).
    void decorate(QNetworkRequest &req) const;
    Q_INVOKABLE void loginWithStationToken(const QString &baseUrl, const QString &stationToken);

    // Restore a persisted token at startup (optimistic: trusts the local exp,
    // then revalidates against /auth/me in the background). Call from main().
    void restoreSession();

    // Called by models that receive a 401. With service credentials present
    // (WT_CV_AUTOLOGIN) it re-logs-in IN PLACE — the wall never drops; without
    // them it clears the session and the UI returns to the sign-in screen.
    void noteUnauthorized();

    // Dev/test hook (WT_AUTH_EXPIRE_S): invalidates the live token in memory +
    // cookie jar so the next backend round-trip 401s — exercises the real
    // expiry path end-to-end without waiting ~10 h.
    Q_INVOKABLE void corruptTokenForTest();

    Q_INVOKABLE void loginWithPassword(const QString &baseUrl,
                                       const QString &username,
                                       const QString &password);
    Q_INVOKABLE void loginWithToken(const QString &baseUrl, const QString &token);
    Q_INVOKABLE void logout();
    Q_INVOKABLE void clearError() { setError(QString()); }

    // Saved-servers list: [{url, nick}], most recent first, capped.
    QVariantList serverHistory() const;
    Q_INVOKABLE void setServerNickname(const QString &url, const QString &nickname);
    Q_INVOKABLE void forgetServer(const QString &url);

signals:
    void stationLiveChanged();
    void authenticatedChanged();
    void baseUrlChanged();
    void identityChanged();
    void busyChanged();
    void loginAttemptChanged();
    void errorChanged();
    void loginFailed(const QString &reason);
    void serverHistoryChanged();
    void sessionExpired();
    // The access token was REPLACED in place (silent /auth/refresh). Components
    // that cache the cookie in their own NAM — PlaybackClient, HlsProxy — must
    // re-copy it here: a refresh changes neither `authenticated` nor baseUrl, so
    // without this they serve a stale token forever and playback 401s with
    // "Token expired" while the rest of the app is fine (operator, 2026-08-10).
    void tokenChanged();

private:
    void setBusy(bool b);
    void setLoginAttempt(int n);
    void setError(const QString &e);
    void setBaseUrl(const QString &url);
    void applyToken(const QString &token);   // store + set cookie + decode claims
    void setAuthenticated(bool a);
    void persist();
    void rememberServer(const QString &url);   // upsert to front of serverHistory
    void clearSession();
    // Login attempts retry on transient network/server-not-ready failures
    // (e.g. the backend still coming up at boot) before surfacing an error.
    void attemptTokenLogin();
    void attemptPasswordLogin();
    // Session continuity for 24/7 stations: schedule a renewal before the
    // token's exp claim, and recover in place from mid-session 401s.
    void armRenewal();
    void renewNow();
    // POST /auth/refresh (CV reply 2026-08-03): renews a still-valid session
    // WITHOUT credentials on the box. 401 = token past saving (expired /
    // account gone) -> service-creds fallback if env-provided, else sign-in.
    void refreshSession();
    static bool decodeClaims(const QString &token, QString &username, QString &role,
                             QStringList &scope, qint64 &expSecs);

    static AuthController *s_instance;

    QNetworkAccessManager *m_nam = nullptr;
    QString m_baseUrl;
    QString m_token;
    bool m_stationLive = false;
    QString m_displaySession;
    QString m_username;
    QString m_role;
    QStringList m_cameraScope;
    qint64 m_exp = 0;          // token expiry, unix seconds
    bool m_authenticated = false;
    bool m_busy = false;
    QString m_errorString;
    int m_loginAttempt = 0;          // retry counter for the current login
    QString m_pendingUser;           // held across password-login retries
    QString m_pendingPassword;
    class QTimer *m_renewTimer = nullptr;   // proactive renewal (armRenewal)
    qint64 m_lastReauthMs = 0;       // cooldown: one background re-login per minute
    int m_reauthFails = 0;           // background re-login failures; ≥3 → sign-in
};
