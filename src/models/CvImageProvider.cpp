#include "CvImageProvider.h"
#include "AuthController.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QQueue>
#include <QThread>
#include <QTimer>

// The event-snapshot path 503-sheds under memory pressure (the backend governor).
// That's transient + carries Retry-After, so retry a bounded few times before
// giving up to the live-frame fallback. 404 (no clip) still fails immediately.
static constexpr int kMaxSnapshotRetries = 3;

// [EVIMG] — WT_TRACE-gated per-fetch diagnostics (code + latency), to verify the
// thumbnail path stays authorized and to attribute pool pressure.
static const bool s_imgLog = qEnvironmentVariableIsSet("WT_TRACE");

// Client-side pacing for the governed snapshot extractor (CV spec 2026-07-10):
// the backend admits ~2 concurrent ffmpeg extractions and SHEDS the rest with
// 503 (measured there: 8 concurrent → 6×503). A wall of thumbnails must queue
// client-side at the same width — 2 concurrent → zero shed (their measurement),
// no blank tiles, and the 503-retry below becomes the rare path, not the norm.
// GUI-thread only (start()/finished both run there), so no locking.
static constexpr int kSnapMaxConcurrent = 2;
static int s_snapInFlight = 0;
static QQueue<QPointer<CvImageResponse>> s_snapQueue;

CvImageResponse::~CvImageResponse()
{
    if (m_reply)
        m_reply->abort();
}

void CvImageResponse::cancel()
{
    m_cancelled = true;
    if (m_reply)
        m_reply->abort();               // finished lambda releases the slot + emits
    else if (m_queued)
        emit finished();                // still queued: the dequeuer will skip us
}

void CvImageResponse::releaseSnapshotSlot()
{
    if (!m_gated)
        return;
    m_gated = false;
    --s_snapInFlight;
    while (!s_snapQueue.isEmpty()) {
        QPointer<CvImageResponse> next = s_snapQueue.dequeue();
        if (next && !next->m_cancelled) {
            next->m_queued = false;
            QMetaObject::invokeMethod(next, &CvImageResponse::start, Qt::QueuedConnection);
            break;
        }
    }
}

void CvImageResponse::start()
{
    if (!m_auth || !m_nam) { emit finished(); return; }
    if (m_cancelled) { releaseSnapshotSlot(); emit finished(); return; }
    // Governed-extractor gate: only /snapshot paths (the ffmpeg extraction) queue.
    if (!m_gated && m_path.contains(QLatin1String("/snapshot"))) {
        if (s_snapInFlight >= kSnapMaxConcurrent) {
            if (!m_queued) { m_queued = true; s_snapQueue.enqueue(this); }
            return;                     // resumed by releaseSnapshotSlot()
        }
        m_gated = true;
        ++s_snapInFlight;
    }
    m_timer.start();
    // Optional leading "wtp<N>/" token carries a network-scheduling priority set by
    // the caller (EvSnapshot): 2=High (focal/visible still), 0=Low (background
    // fallback); absent = Normal. Qt's HTTP stack dispatches HigherPriority requests
    // first when the per-host pool (6) is saturated, so the thumbnail the operator is
    // looking at jumps ahead of the go2rtc fallback storm. Strip it before forming the
    // backend path; QML keeps the (stable) token in its cache key.
    QString path = m_path;
    QNetworkRequest::Priority prio = QNetworkRequest::NormalPriority;
    if (path.size() > 4 && path.startsWith(QLatin1String("wtp"))
        && path.at(4) == QLatin1Char('/')
        && path.at(3) >= QLatin1Char('0') && path.at(3) <= QLatin1Char('2')) {
        prio = path.at(3) == QLatin1Char('2') ? QNetworkRequest::HighPriority
             : path.at(3) == QLatin1Char('0') ? QNetworkRequest::LowPriority
                                              : QNetworkRequest::NormalPriority;
        path = path.mid(5);
    }
    QNetworkRequest req{QUrl(m_auth->baseUrl() + "/" + path)};
    req.setPriority(prio);
    // Private pool + explicit cookie: the login lands on AuthController's NAM, so
    // this jar never sees it — attach the session cookie per request (always the
    // current token, survives relogin with no signal plumbing).
    req.setRawHeader("Cookie", "access_token=" + m_auth->token().toUtf8());
    m_reply = m_nam->get(req);
    connect(m_reply, &QNetworkReply::finished, this, [this]() {
        QNetworkReply *r = m_reply;
        if (!r) { emit finished(); return; }
        const int code = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (s_imgLog)
            qInfo("[EVIMG] code=%d ms=%lld %s", code, (long long)m_timer.elapsed(),
                  qPrintable(m_path.right(44)));
        if (code == 200) {
            QImage img;
            if (img.loadFromData(r->readAll())) {
                // Decode/cache at the requested DISPLAY size, not the full 2560x1440 sensor frame.
                // QtQuick caches this provider's QImage, so a full-res still per event is ~14 MB that
                // never shrinks — the dominant per-open RSS leak (localized 2026-06-29). Downscale to
                // the QML sourceSize (thumbnail/poster) → caps each cached still to well under 1 MB.
                if (m_reqSize.isValid() && !m_reqSize.isEmpty()
                    && (img.width() > m_reqSize.width() || img.height() > m_reqSize.height()))
                    img = img.scaled(m_reqSize, Qt::KeepAspectRatio, Qt::SmoothTransformation);
                m_image = img;
            } else {
                m_error = QStringLiteral("decode failed");
            }
        } else if (r->error() == QNetworkReply::OperationCanceledError) {
            m_error = QStringLiteral("cancelled");
        } else if (code == 503 && m_attempt < kMaxSnapshotRetries) {
            // Governor shed under memory pressure — transient. Honor Retry-After
            // (seconds; default ~1.2s) and retry; the still shows once pressure clears.
            bool ok = false;
            const int ra = r->rawHeader("Retry-After").toInt(&ok);
            const int delayMs = (ok && ra > 0) ? qMin(ra, 5) * 1000 : 1200;
            ++m_attempt;
            r->deleteLater();
            m_reply = nullptr;
            QTimer::singleShot(delayMs, this, &CvImageResponse::start);
            return;
        } else {
            m_error = QStringLiteral("HTTP %1").arg(code);   // 404 → caller falls back to the live frame
        }
        r->deleteLater();
        m_reply = nullptr;
        releaseSnapshotSlot();
        emit finished();
    });
}

// PRIVATE NAM (own 6-connection pool). Thumbnail bursts — dozens of parallel event
// stills per Events tab, plus live-frame fallbacks — are the app's bulk HTTP
// traffic. On the shared AuthController NAM they filled its 6-per-host pool and
// starved the control plane: a playback session POST measured 2.3–4.1 s queued
// behind them (fixed 2026-07-02, PlaybackClient got its own NAM), and the Events
// list queries queued the same way. Isolating the storm here un-starves EVERY
// shared-NAM consumer (EventModel, CameraModel, StorageHealth, SiteMapModel) at
// once. Constructed on the GUI thread (main.cpp) — matches where start() runs.
CvImageProvider::CvImageProvider(AuthController *auth)
    : m_auth(auth), m_nam(new QNetworkAccessManager)
{
}

CvImageProvider::~CvImageProvider()
{
    delete m_nam;
}

QQuickImageResponse *CvImageProvider::requestImageResponse(const QString &id, const QSize &requestedSize)
{
    auto *resp = new CvImageResponse(m_auth, m_nam, id, requestedSize);
    // The NAM lives on the GUI thread; move the response there and kick the fetch
    // on that thread (this method runs on the pixmap-loader worker thread).
    resp->moveToThread(m_auth->thread());
    QMetaObject::invokeMethod(resp, &CvImageResponse::start, Qt::QueuedConnection);
    return resp;
}
