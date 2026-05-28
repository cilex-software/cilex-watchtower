#pragma once

#include <QObject>
#include <QHash>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class QNetworkAccessManager;
class HlsProxy;

// Client for cilex-vision's recorded-playback API (the recording backend;
// cameras have no local storage). Handles cookie login, camera_id resolution,
// review-session creation + manifest, and clip export. HLS bytes are served to
// QMediaPlayer through a local HlsProxy (see HlsProxy.h) so the auth cookie and
// URL rewrites are applied transparently.
class PlaybackClient : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool loggedIn READ loggedIn NOTIFY loggedInChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
public:
    explicit PlaybackClient(QObject *parent = nullptr);

    bool loggedIn() const { return m_loggedIn; }
    QString status() const { return m_status; }

    // Ensure a session cookie exists (auto-login with configured/dev creds),
    // then resolve camera_ids from /streams. Safe to call repeatedly.
    Q_INVOKABLE void ensureReady();

    // camera_id is "<vendor-slug>-<mac-hex>"; resolve from the /streams map
    // (authoritative) or compute from a MAC if streams aren't loaded yet.
    Q_INVOKABLE QString cameraIdForIp(const QString &ip) const;
    Q_INVOKABLE QString cameraIdForMac(const QString &mac) const;

    // Open a review session over [wallStartIso, wallEndIso] (<=24h). Emits
    // sessionReady(sessionId, compactDuration, fragments, meta) or sessionFailed.
    Q_INVOKABLE void openSession(const QString &cameraId, const QString &wallStartIso,
                                 const QString &wallEndIso, bool hevcCapable = true);

    // Local proxy playlist URL for QMediaPlayer.
    Q_INVOKABLE QString playlistUrl(const QString &sessionId) const;

    // Clip export: create -> poll -> emits exportReady(jobId, downloadUrl).
    Q_INVOKABLE void createExport(const QString &cameraId, const QString &wallStartIso,
                                  const QString &wallEndIso, const QString &mode);
    Q_INVOKABLE void pollExport(const QString &jobId);

signals:
    void loggedInChanged();
    void statusChanged();
    void camerasResolved();
    void sessionReady(const QString &sessionId, double compactDuration,
                      const QVariantList &fragments, const QVariantMap &meta);
    void sessionFailed(const QString &error);
    void exportStarted(const QString &jobId);
    void exportProgress(const QString &jobId, const QString &state);
    void exportReady(const QString &jobId, const QString &downloadUrl);
    void exportFailed(const QString &jobId, const QString &error);

private:
    void setStatus(const QString &s);
    void fetchStreams();
    void flushPendingSessions();

    QNetworkAccessManager *m_nam;
    HlsProxy *m_proxy;
    QString m_baseUrl;
    bool m_loggedIn = false;      // ready: signed in AND /streams resolved
    bool m_loggingIn = false;
    QString m_status;
    QHash<QString, QString> m_ipToCamId;
    QHash<QString, QString> m_macToCamId;
};
