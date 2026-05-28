#pragma once

#include <QObject>
#include <QString>
#include <QStringList>

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
    Q_PROPERTY(QString baseUrl READ baseUrl NOTIFY baseUrlChanged)
    Q_PROPERTY(QString username READ username NOTIFY identityChanged)
    Q_PROPERTY(QString role READ role NOTIFY identityChanged)
    Q_PROPERTY(QString initials READ initials NOTIFY identityChanged)
    Q_PROPERTY(QStringList cameraScope READ cameraScope NOTIFY identityChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString errorString READ errorString NOTIFY errorChanged)

public:
    explicit AuthController(QObject *parent = nullptr);

    static AuthController *instance() { return s_instance; }

    bool authenticated() const { return m_authenticated; }
    QString baseUrl() const { return m_baseUrl; }
    QString username() const { return m_username; }
    QString role() const { return m_role; }
    QString initials() const;
    QStringList cameraScope() const { return m_cameraScope; }
    bool busy() const { return m_busy; }
    QString errorString() const { return m_errorString; }

    // Shared, session-authenticated network manager used by all models.
    QNetworkAccessManager *nam() const { return m_nam; }

    // Restore a persisted token at startup (optimistic: trusts the local exp,
    // then revalidates against /auth/me in the background). Call from main().
    void restoreSession();

    // Called by models that receive a 401 — drops the session and asks the UI
    // to return to the login screen.
    void noteUnauthorized();

    Q_INVOKABLE void loginWithPassword(const QString &baseUrl,
                                       const QString &username,
                                       const QString &password);
    Q_INVOKABLE void loginWithToken(const QString &baseUrl, const QString &token);
    Q_INVOKABLE void logout();
    Q_INVOKABLE void clearError() { setError(QString()); }

signals:
    void authenticatedChanged();
    void baseUrlChanged();
    void identityChanged();
    void busyChanged();
    void errorChanged();
    void loginFailed(const QString &reason);
    void sessionExpired();

private:
    void setBusy(bool b);
    void setError(const QString &e);
    void setBaseUrl(const QString &url);
    void applyToken(const QString &token);   // store + set cookie + decode claims
    void setAuthenticated(bool a);
    void persist();
    void clearSession();
    static bool decodeClaims(const QString &token, QString &username, QString &role,
                             QStringList &scope, qint64 &expSecs);

    static AuthController *s_instance;

    QNetworkAccessManager *m_nam = nullptr;
    QString m_baseUrl;
    QString m_token;
    QString m_username;
    QString m_role;
    QStringList m_cameraScope;
    qint64 m_exp = 0;          // token expiry, unix seconds
    bool m_authenticated = false;
    bool m_busy = false;
    QString m_errorString;
};
