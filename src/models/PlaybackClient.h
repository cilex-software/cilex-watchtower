#pragma once

#include <QQuickImageProvider>

#include <QObject>
#include <QHash>
#include <QSet>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class QNetworkAccessManager;
class HlsProxy;
class QThread;

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
    Q_PROPERTY(bool authFault READ authFault NOTIFY authFaultChanged)
    Q_PROPERTY(QString authFaultDetail READ authFaultDetail NOTIFY authFaultChanged)
    // True once a control call (session POST / coverage GET) has aborted with NO HTTP
    // response at all, and until one answers again. Distinct from authFault (the server
    // answered, and said no) and from status (which narrates a healthy open). The
    // screen shows it INSTEAD of "Loading recording...", so a guard can tell a stalled
    // backend from a hung app - see the 2026-09-22 111 s API stall.
    Q_PROPERTY(bool serverUnresponsive READ serverUnresponsive NOTIFY serverUnresponsiveChanged)
public:
    explicit PlaybackClient(QObject *parent = nullptr);
    ~PlaybackClient() override;               // stops + joins the proxy thread

    bool loggedIn() const { return m_loggedIn; }
    QString status() const { return m_status; }
    bool authFault() const { return m_authFault; }
    QString authFaultDetail() const { return m_authFaultDetail; }
    bool serverUnresponsive() const { return m_serverUnresponsive; }

    // Ensure a session cookie exists (auto-login with configured/dev creds),
    // then resolve camera_ids from /streams. Safe to call repeatedly.
    Q_INVOKABLE void ensureReady();

    // camera_id is "<vendor-slug>-<mac-hex>"; resolve from the /streams map
    // (authoritative) or compute from a MAC if streams aren't loaded yet.
    Q_INVOKABLE QString cameraIdForIp(const QString &ip) const;
    Q_INVOKABLE QString cameraIdForMac(const QString &mac) const;

    // Open a review session over [wallStartIso, wallEndIso] (<=24h). Emits
    // sessionReady(sessionId, compactDuration, fragments, meta) or sessionFailed.
    // Decoded thumbnail tiles served to QML via image://thumbtile/<key>
    // (data: URLs proved unreliable in QQuickImage here; the provider path is
    // the same battle-tested route CvImageProvider uses).
    static QImage thumbTile(const QString &key);

    // Fetch operator-facing thumbnails (CV /review/thumbnails). `tag` echoes
    // through thumbnailsReady so callers can route hover vs day-strip replies.
    // format: "json" (per-tile data URLs) or "sprite" (one sheet + x/width).
    Q_INVOKABLE void fetchThumbnails(const QString &cameraId, const QString &tag,
                                     const QString &wallStartIso, const QString &wallEndIso,
                                     int count, int height,
                                     const QString &precision = QStringLiteral("keyframe"),
                                     const QString &format = QStringLiteral("json"));
    Q_INVOKABLE void openSession(const QString &cameraId, const QString &wallStartIso,
                                 const QString &wallEndIso, bool hevcCapable = true,
                                 const QString &tag = QString());

    // Local proxy playlist URL for QMediaPlayer.
    Q_INVOKABLE QString playlistUrl(const QString &sessionId) const;

    // Clip export: create -> poll -> download to destPath -> emits
    // exportSaved(jobId, localPath). destPath is a local file path (the caller
    // computes it via Artifacts.newExportPath).
    // groupId (I7) ties a dual-archive set (N per-camera + 1 mosaic of one wall
    // moment) together in the exports list; purpose (A1) is the operator label.
    // Both optional.
    // post (optional) = client-side post-processing of the downloaded clip:
    //   { height:int (0=keep), name:bool, timestamp:bool, label:string,
    //     startEpochMs:qint64, durationMs:qint64 }. Empty = deliver the export as-is.
    Q_INVOKABLE void createExport(const QString &cameraId, const QString &wallStartIso,
                                  const QString &wallEndIso, const QString &mode,
                                  const QString &destPath,
                                  const QString &groupId = QString(), const QString &purpose = QString(),
                                  bool hevcCapable = true,   // true = High (H.265 main original), false = Standard (H.264 sub)
                                  const QVariantMap &post = QVariantMap());
    // Re-run the last single-camera export as High (hevc_capable=true). For when a Standard export
    // fails because the camera's sub-stream wasn't recorded for that window — the High main is still
    // there (Cilex Vision reply9 / our reply10, option 1). No-op if there was no prior export.
    Q_INVOKABLE void retryLastExportAsHigh();
    Q_INVOKABLE void pollExport(const QString &jobId);

    // Combined synchronized-grid export (E2): render a window of a mosaic session
    // to one file. Reuses the export_jobs poll/download flow + token download.
    Q_INVOKABLE void createMosaicExport(const QString &sessionId, const QString &wallStartIso,
                                        const QString &wallEndIso, const QString &mode,
                                        const QString &destPath,
                                        const QString &groupId = QString(), const QString &purpose = QString());

    // Exports library (A6): GET /review/exports → the operator's server exports
    // (single + mosaic), newest first, each with state/bytes/resolution/group_id/
    // purpose/download_url. Emits exportsListReady. download_url is proxied so the
    // local player/browser can fetch it with the session cookie.
    Q_INVOKABLE void fetchExports();

    // Footage calendar: which days have recorded footage within the retention
    // window. Calls GET /review/coverage?camera_id=… and emits coverageReady.
    // `available` is false (with empty days) when the backend hasn't shipped the
    // endpoint yet (404) or on error, so the calendar shows an honest "pending"
    // state instead of fabricating coverage. See docs/letters/ for the API ask.
    Q_INVOKABLE void fetchCoverage(const QString &cameraId);
    // Last known coverage from disk, for the FAST OPEN target ONLY while the live
    // request is still in CV's database. Never for the ribbon or the empty-day
    // claim — see the honesty note at the definition.
    Q_INVOKABLE QVariantList cachedCoverageDays(const QString &cameraId,
                                                int retentionDays = 35) const;
    // Last known ip -> camera_id, from disk, so the coverage cache can be read before
    // /streams answers. Stale entries are overwritten by the live /streams response.
    Q_INVOKABLE QString cachedCameraIdForIp(const QString &ip) const;

    // Motion timeline for the playback scrubber (S06 / 2026-06-15 letter): GET
    // /events/timeline → server-joined motion episode SPANS (episodes mode), or
    // density BINS when buckets>0. Emits timelineReady(cameraId, mode, blocks);
    // mode is "episodes" | "buckets" | "error".
    Q_INVOKABLE void fetchTimeline(const QString &cameraId, const QString &startIso,
                                   const QString &endIso, int buckets = 0);

    // Synchronized multi-camera review (E1). Opens a SERVER-COMPOSITED grid
    // session over [wallStartIso, wallEndIso]; the backend returns ONE HLS VOD
    // of the whole grid + a cell↔camera mapping + a /review-shaped composited
    // manifest. Emits mosaicSessionReady or mosaicSessionFailed (the latter on
    // 404 until the endpoint ships → the wall shows an honest "pending" state).
    // `replaces` (B2a): the prior session id to reap server-side (one wall = one
    // live session). `prewarmAt` (B3): fragment index to warm around on create
    // (-1 = none).
    Q_INVOKABLE void openMosaicSession(const QStringList &cameraIds,
                                       const QString &wallStartIso, const QString &wallEndIso,
                                       int cols, int rows,
                                       const QString &replaces = QString(), int prewarmAt = -1);
    // B1: dispose a session (DELETE) — cancels the chase + in-flight renders and
    // frees its cache; fire-and-forget. Call on leaving the wall.
    Q_INVOKABLE void disposeMosaicSession(const QString &sessionId);
    // B3: seek-hint — warm `ahead` fragments around `atFrag`; fire-and-forget (202).
    Q_INVOKABLE void prewarmMosaic(const QString &sessionId, int atFrag, int ahead = 0);
    // Proxied playlist URL for the composited mosaic stream.
    Q_INVOKABLE QString mosaicPlaylistUrl(const QString &sessionId) const;

    // Coverage union for the wall calendar (E4): GET /review/coverage?camera_ids=…
    // → a day is "covered" if ANY camera has footage. Emits coverageUnionReady;
    // available=false on 404/error (honest "pending" calendar).
    Q_INVOKABLE void fetchCoverageUnion(const QStringList &cameraIds);

signals:
    void loggedInChanged();
    void statusChanged();
    void serverUnresponsiveChanged();
    void authFaultChanged();
    void camerasResolved();
    // tag: OWNERSHIP token echoed from openSession(). Multiple consumers share
    // these broadcast signals (PlaybackScreen tabs + the events hero player);
    // 2026-08-04 the untagged broadcast let one screen hijack another's session
    // (triage seek -> permanent black square). Consumers filter on their tag.
    void sessionReady(const QString &sessionId, double compactDuration,
                      const QVariantList &fragments, const QVariantMap &meta,
                      const QString &tag);
    void sessionFailed(const QString &error, const QString &tag);
    void exportStarted(const QString &jobId);
    void exportProgress(const QString &jobId, const QString &state);
    void exportSaved(const QString &jobId, const QString &localPath);
    void exportFailed(const QString &jobId, const QString &error);
    // /review/thumbnails (CV v1, frozen contract 2026-07-12): tiles carry
    // wallTime + tileUrl (image://thumbtile/...) or an empty tileUrl + reason
    // for gaps (never packed into the sheet).
    void thumbnailsReady(const QString &cameraId, const QString &tag,
                         const QVariantList &tiles, const QString &spriteDataUrl);
    void coverageReady(const QString &cameraId, bool available, int retentionDays,
                       const QVariantList &days);
    void timelineReady(const QString &cameraId, const QString &mode, const QVariantList &blocks);
    void mosaicSessionReady(const QString &sessionId, const QVariantMap &grid,
                            const QVariantList &cells, double compactDuration,
                            const QVariantList &fragments, const QVariantMap &meta);
    void mosaicSessionFailed(const QString &error, bool pending);   // pending=true ⇒ endpoint not shipped (404)
    void coverageUnionReady(bool available, int retentionDays, const QVariantList &unionDays);
    void exportsListReady(const QVariantList &exports);   // A6: the operator's server exports

private:
    void setStatus(const QString &s);
    void setServerUnresponsive(bool v);
    void applyAuthCookie();
    void setAuthFault(bool v, const QString &detail);   // mirror the access_token into our private NAM's jar
    void fetchStreams();
    // POST /review/sessions for a resolved camera id; retries on a transport-level
    // failure (HTTP code 0 — timeout / unreachable / reset) before giving up.
    void requestSession(const QString &cameraId, const QString &wallStartIso,
                        const QString &wallEndIso, bool hevcCapable, int attempt,
                        const QString &tag);
    void flushPendingSessions();
    void downloadExport(const QString &jobId, const QString &url, const QString &destPath);

    QNetworkAccessManager *m_nam;
    HlsProxy *m_proxy = nullptr;
    QThread *m_proxyThread = nullptr;        // the proxy runs here, off the GUI thread
    QString m_baseUrl;
    // Coverage requests in flight, by camera id. Three QML callers fire within
    // microseconds of camerasResolved, so this endpoint was requested twice on every
    // screen entry — see the single-flight note in fetchCoverage().
    QSet<QString> m_coverageInflight;
    // /streams was likewise issued twice per launch — see the single-flight note in
    // fetchStreams(). It gates camerasResolved, so a duplicate competes with the very
    // request chain it unblocks.
    bool m_streamsInflight = false;
    bool m_loggedIn = false;      // ready: signed in AND /streams resolved
    QString m_sessionTag;
    // Playback-subsystem health. Set when a session open is refused for an
    // AUTH reason — the 2026-08-10 P0 class, where playback died silently
    // while every other surface looked healthy. Never silent again: it is a
    // property the UI renders and a [WT-DEGRADED] line Warden can alert on.
    bool m_authFault = false;
    QString m_authFaultDetail;         // ownership token of the in-flight openSession
    bool m_loggingIn = false;
    QString m_status;
    bool m_serverUnresponsive = false;
    QHash<QString, QString> m_ipToCamId;
    QHash<QString, QString> m_macToCamId;
    QHash<QString, QString> m_exportDest;   // jobId -> local file path
    QHash<QString, QVariantMap> m_exportPost;   // jobId -> client post-process opts (compression/overlays)
    // Last single-camera export request, so a "Standard failed: no sub footage" can be re-run
    // one-click as High (the main stream is still there). See retryLastExportAsHigh().
    struct LastExport { QString cameraId, wallStart, wallEnd, mode, destPath, groupId, purpose;
                        QVariantMap post; bool valid = false; };
    LastExport m_lastExport;
    void runPostProcess(const QString &jobId, const QString &srcPath,
                        const QString &dstPath, const QVariantMap &post);
};

// image://thumbtile/<tag>~<index> — decoded /review/thumbnails tiles
// (PlaybackClient::thumbTile store).
class ThumbTileProvider : public QQuickImageProvider
{
public:
    ThumbTileProvider() : QQuickImageProvider(QQuickImageProvider::Image) {}
    QImage requestImage(const QString &id, QSize *size, const QSize &requested) override;
};
