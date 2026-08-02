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

// Duplicate finish()es are suppressed rather than crashing — but a suppression means
// a real double-completion happened, so count them and say so once (WT_TRACE prints
// every one). If this ever climbs, the exit paths below have grown a new leak.
static int s_dupFinish = 0;

CvImageResponse::~CvImageResponse()
{
    // GUI thread (Qt deleteLater()s us). Drop the reply's connection BEFORE aborting:
    // abort() emits QNetworkReply::finished SYNCHRONOUSLY, and our lambda would then
    // run inside this destructor and emit our own finished() again — on an object Qt
    // is already deleting.
    if (m_reply) {
        m_reply->disconnect(this);
        m_reply->abort();
        m_reply->deleteLater();
        m_reply = nullptr;
    }
    releaseSnapshotSlot();              // never strand a governed-extractor slot
}

// Qt calls cancel() on the PIXMAP-READER thread, from inside
// QQuickPixmapReader::processJobs() while it holds that reader's mutex. So this must
// do two things only: raise the flag, and hop. It must NOT touch m_reply — a
// GUI-thread QNetworkReply — and it must NOT emit finished() synchronously, which
// would re-enter QQuickPixmapReader::asyncResponseFinished() under its own lock and,
// worse, race a queued start() into a second completion (the P0 above).
void CvImageResponse::cancel()
{
    m_cancelled.store(true);
    QMetaObject::invokeMethod(this, &CvImageResponse::cancelOnOwnThread, Qt::QueuedConnection);
}

// GUI thread. Qt has already removed us from its response map, but it still deletes
// us only when finished() arrives — so every branch must end the job exactly once.
void CvImageResponse::cancelOnOwnThread()
{
    if (m_finished)
        return;                         // the job beat the cancel here — nothing to stop
    if (m_reply) {
        m_reply->abort();               // → the finished lambda releases the slot + finish()es
        return;
    }
    releaseSnapshotSlot();              // queued / retry-pending / never started
    finish();
}

void CvImageResponse::finish()
{
    if (m_finished) {
        ++s_dupFinish;
        if (s_imgLog || s_dupFinish == 1)
            qWarning("[EVIMG] duplicate finish suppressed (n=%d) %s", s_dupFinish,
                     qPrintable(m_path.right(44)));
        return;
    }
    m_finished = true;
    emit finished();
}

void CvImageResponse::releaseSnapshotSlot()
{
    if (m_gated) {
        m_gated = false;
        --s_snapInFlight;
    }
    // Pump UNCONDITIONALLY — never-gated responses included. A queued candidate
    // that was woken (dequeued + start() invoked) and then cancelled before that
    // queued start() ran used to swallow the wake-up: its early-outs hit the old
    // `if (!m_gated) return;` and nobody re-scanned the queue. With both slots'
    // wakes lost in the same churn window, the pipeline froze permanently —
    // s_snapInFlight == 0, live waiters queued, nothing in flight to ever release
    // again (observed 2026-08-02 cold-start storm: zero fetches after +22 s,
    // 6 tiles empty for the remaining 128 s). Pumping from EVERY terminating
    // path means a dying wake always passes the baton; over-waking is safe
    // because start() re-checks capacity and politely re-enqueues.
    while (s_snapInFlight < kSnapMaxConcurrent && !s_snapQueue.isEmpty()) {
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
    if (!m_auth || !m_nam) { releaseSnapshotSlot(); finish(); return; }
    if (m_cancelled) { releaseSnapshotSlot(); finish(); return; }
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
        if (!r) { releaseSnapshotSlot(); finish(); return; }
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
        finish();
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
