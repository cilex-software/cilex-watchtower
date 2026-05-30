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

    // Clip export: create -> poll -> download to destPath -> emits
    // exportSaved(jobId, localPath). destPath is a local file path (the caller
    // computes it via Artifacts.newExportPath).
    Q_INVOKABLE void createExport(const QString &cameraId, const QString &wallStartIso,
                                  const QString &wallEndIso, const QString &mode,
                                  const QString &destPath);
    Q_INVOKABLE void pollExport(const QString &jobId);

    // Footage calendar: which days have recorded footage within the retention
    // window. Calls GET /review/coverage?camera_id=… and emits coverageReady.
    // `available` is false (with empty days) when the backend hasn't shipped the
    // endpoint yet (404) or on error, so the calendar shows an honest "pending"
    // state instead of fabricating coverage. See docs/letters/ for the API ask.
    Q_INVOKABLE void fetchCoverage(const QString &cameraId);

signals:
    void loggedInChanged();
    void statusChanged();
    void camerasResolved();
    void sessionReady(const QString &sessionId, double compactDuration,
                      const QVariantList &fragments, const QVariantMap &meta);
    void sessionFailed(const QString &error);
    void exportStarted(const QString &jobId);
    void exportProgress(const QString &jobId, const QString &state);
    void exportSaved(const QString &jobId, const QString &localPath);
    void exportFailed(const QString &jobId, const QString &error);
    void coverageReady(const QString &cameraId, bool available, int retentionDays,
                       const QVariantList &days);

private:
    void setStatus(const QString &s);
    void fetchStreams();
    void flushPendingSessions();
    void downloadExport(const QString &jobId, const QString &url, const QString &destPath);

    QNetworkAccessManager *m_nam;
    HlsProxy *m_proxy;
    QString m_baseUrl;
    bool m_loggedIn = false;      // ready: signed in AND /streams resolved
    bool m_loggingIn = false;
    QString m_status;
    QHash<QString, QString> m_ipToCamId;
    QHash<QString, QString> m_macToCamId;
    QHash<QString, QString> m_exportDest;   // jobId -> local file path
};
