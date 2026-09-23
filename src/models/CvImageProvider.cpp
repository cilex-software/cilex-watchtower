#include "CvImageProvider.h"
#include "AuthController.h"
#include "StationNam.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QDateTime>
#include <QPointer>
#include <QQueue>
#include <QThread>
#include <QTimer>

// The event-snapshot path 503s for two DIFFERENT reasons, both carrying Retry-After:
// the memory-pressure governor shedding load, and (measured 2026-08-15)
//   {"detail":"Footage for this event is still being written/uploaded"}  Retry-After: 30
// on any event newer than the fragment-flush lag. Retry a bounded few times, then give
// up to the caller's fallback. 404 (no episode) still fails immediately.
//
// Do NOT raise the Retry-After clamp below to honour a 30 s hint. The instruction
// stands; the REASON it used to give was wrong about whose resource is at stake, and a
// wrong reason is how a correct rule gets overturned by the next person to read it.
//
// It said "a waiting response holds one of the two extraction slots", which reads as
// the BACKEND's slots. It is not. CV confirmed 2026-09-23: their try_acquire() either
// takes a slot or returns immediately, so a client sitting on a Retry-After occupies
// nothing of theirs. The slot a long wait would hold is one of OURS — s_poolExtract is
// width 2 (below), so three simultaneous waits would stall our own rail for the whole
// window while costing the server nothing.
//
// So the rule is unchanged and CV endorses it: fail fast to free OUR slot, and keep the
// LONG wait in the caller, which is where OpsSidebar's 30 s re-request timer lives.
static constexpr int kMaxSnapshotRetries = 3;

// [EVIMG] — WT_TRACE-gated per-fetch diagnostics (code + latency), to verify the
// thumbnail path stays authorized and to attribute pool pressure.
static const bool s_imgLog = qEnvironmentVariableIsSet("WT_TRACE");

// Client-side pacing for /snapshot requests, per PATH CLASS (GUI-thread only —
// start()/finished both run there, so no locking):
// - EXTRACTION (event stills): the backend admits ~2 concurrent ffmpeg
//   extractions and SHEDS the rest with 503 (CV spec 2026-07-10; measured
//   there: 8 concurrent → 6×503). Width 2 → zero shed, 503-retry stays rare.
// - CACHED camera stills (`streams/cameras/<id>/snapshot`): resolved from the
//   query-api TTL cache, cold-filled via the go2rtc SUB fetch behind a
//   server-side semaphore of 4 (CV reply 2026-08-02). Width 4 matches it —
//   at the old shared width 2, a 39-camera Groups grid drained serially and
//   measured p90 2.3–3.9 s to settle; extraction pressure and wall pressure
//   also starved each other through the shared gate.
struct SnapPool {
    const char *name;
    const int cap;
    int inFlight = 0;
    QQueue<QPointer<CvImageResponse>> queue;

    // WT_QUIET_START_MS: hold this gate to ONE slot for the first N ms after the
    // gate is FIRST consulted — i.e. from the first snapshot request, not from
    // process start — then return to `cap`. Default 0 = today's behaviour exactly.
    //
    // WHY, measured 2026-09-01: CV's serve;dur tracks OUR concurrency and almost
    // nothing else. The same 62-fragment playback session took 19,839 ms with six
    // of our requests in flight and 35 ms with one. Snapshots ride a PRIVATE NAM
    // so they never starve the control plane CLIENT-side (see CvImageProvider.h),
    // but both pools point at ONE backend whose database is the contended
    // resource — so a thumbnail burst still lands on the guard's first open, just
    // by a different route than the one this class was built to avoid.
    //
    // This is a TRADE and it is why it defaults off: width 6 exists because a
    // 39-camera grid settled at p90 2.3-3.9 s at width 2. Narrowing buys the
    // first open and costs how fast the grid fills.
    int effectiveCap() const
    {
        static const int quietMs = qEnvironmentVariableIntValue("WT_QUIET_START_MS");
        if (quietMs <= 0)
            return cap;
        static const qint64 t0 = QDateTime::currentMSecsSinceEpoch();
        return (QDateTime::currentMSecsSinceEpoch() - t0) < quietMs ? 1 : cap;
    }
};
static SnapPool s_poolExtract{"extract", 2};
// 6 = the private NAM's per-host pool. Wider than the server's 4-wide SUB fill
// on purpose: cache HITS (~30 ms) must not queue behind 1–3 s cold fills
// (head-of-line blocking measured 2026-08-02: warm hits finishing at +2–3 s in
// a 39-tile burst). Misses are still bounded at 4 server-side; the extra width
// only lets hits overtake.
static SnapPool s_poolCached{"cached", 6};

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
    if (!m_pool)
        return;                         // never classified as a /snapshot request
    if (m_gated) {
        m_gated = false;
        --m_pool->inFlight;
    }
    // Pump UNCONDITIONALLY — never-gated responses included. A queued candidate
    // that was woken (dequeued + start() invoked) and then cancelled before that
    // queued start() ran used to swallow the wake-up: its early-outs hit the old
    // `if (!m_gated) return;` and nobody re-scanned the queue. With every slot's
    // wake lost in the same churn window, the pipeline froze permanently —
    // inFlight == 0, live waiters queued, nothing in flight to ever release
    // again (observed 2026-08-02 cold-start storm: zero fetches after +22 s,
    // 6 tiles empty for the remaining 128 s). Pumping from EVERY terminating
    // path means a dying wake always passes the baton; over-waking is safe
    // because start() re-checks capacity and politely re-enqueues.
    while (m_pool->inFlight < m_pool->effectiveCap() && !m_pool->queue.isEmpty()) {
        QPointer<CvImageResponse> next = m_pool->queue.dequeue();
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
    // Governed gate: only /snapshot paths queue, each in its class's pool.
    if (!m_gated && m_path.contains(QLatin1String("/snapshot"))) {
        if (!m_pool)
            m_pool = m_path.contains(QLatin1String("streams/cameras/"))
                     ? &s_poolCached : &s_poolExtract;
        if (m_pool->inFlight >= m_pool->effectiveCap()) {
            if (!m_queued) { m_queued = true; m_pool->queue.enqueue(this); }
            return;                     // resumed by releaseSnapshotSlot()
        }
        m_gated = true;
        ++m_pool->inFlight;
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
    // Camera stills: ask the server to scale, not just ourselves. CV's snapshot
    // endpoint takes ?w= (a width CEILING, never an upscale, clamped 64–1280,
    // quantised to 16 px, cached per (camera,width) — their 2026-08-17 letter).
    // Until today the client sent NO width and downscaled locally after paying
    // full-size bytes on the wire: measured server-side, a full frame is
    // 123.8 KB where w=240 is 6.3 KB — a ~20× wire saving for a booth tile that
    // renders at ~235 px. requestedSize is already the tile's pixel size
    // (LiveThumb passes sourceSize), so the ceiling is honest by construction.
    // Only the cached-camera path takes ?w=; the events-extraction path does not.
    if (m_reqSize.isValid() && m_reqSize.width() > 0
        && path.contains(QLatin1String("streams/cameras/"))
        && path.contains(QLatin1String("/snapshot"))) {
        const int w = qBound(64, (m_reqSize.width() + 15) / 16 * 16, 1280);
        path += (path.contains(QLatin1Char('?')) ? QLatin1Char('&') : QLatin1Char('?'));
        path += QLatin1String("w=") + QString::number(w);
    }
    QNetworkRequest req{QUrl(m_auth->baseUrl() + "/" + path)};
    req.setPriority(prio);
    m_effectivePath = path;   // what actually went on the wire (m_path is the cache
                              // identity and never carries the derived w= — logging
                              // m_path here is how a live w= stayed invisible for
                              // three verification runs on 2026-08-17)
    // Private pool + explicit cookie: the login lands on AuthController's NAM, so
    // this jar never sees it — attach the session cookie per request (always the
    // current token, survives relogin with no signal plumbing).
    req.setRawHeader("Cookie", "access_token=" + m_auth->token().toUtf8());
    m_auth->decorate(req);   // station display header when in station mode
    m_reply = m_nam->get(req);
    connect(m_reply, &QNetworkReply::finished, this, [this]() {
        QNetworkReply *r = m_reply;
        if (!r) { releaseSnapshotSlot(); finish(); return; }
        const int code = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (s_imgLog)
            qInfo("[EVIMG] code=%d ms=%lld req=%dx%d %s", code, (long long)m_timer.elapsed(),
                  m_reqSize.width(), m_reqSize.height(), qPrintable(m_effectivePath.right(44)));
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
            // 503 here is transient, but NOT always for the reason this comment used to
            // give. CV measured 2026-09-23 that the overwhelming majority are
            // "footage not written yet" (1,769 of their requests in 3 h) rather than the
            // memory governor shedding (4 in the same window) — the event is simply
            // younger than the ~60 s it takes recorded video to land.
            //
            // DO NOT HOLD THE EXTRACTION SLOT WHILE WAITING. This path used to `return`
            // straight past releaseSnapshotSlot() at the bottom, so a retrying response
            // kept one of the pool's TWO slots for up to kMaxSnapshotRetries x 5 s. The
            // events at the TOP of the rail are the newest, so they are exactly the ones
            // that 503 for being too young — and two of them could hold the entire
            // extraction pool for ~15 s while the older events behind them, which WOULD
            // have been served, never got a turn. Measured before this fix: a 200 s
            // session moved only 21 event-still requests through a 2-wide pool and
            // rendered nothing, with every visible row stuck at Image.Loading.
            //
            // This is the same shape as the read-ahead starvation fixed in HlsProxy
            // earlier today: work that cannot succeed yet occupying a scarce resource
            // that work which CAN succeed is queued behind. Release first, then wait;
            // start() re-acquires or politely re-enqueues, and releasing pumps the
            // queue so somebody else gets the slot immediately.
            bool ok = false;
            const int ra = r->rawHeader("Retry-After").toInt(&ok);
            const int delayMs = (ok && ra > 0) ? qMin(ra, 5) * 1000 : 1200;
            ++m_attempt;
            r->deleteLater();
            m_reply = nullptr;
            releaseSnapshotSlot();
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
    : m_auth(auth), m_nam(new StationNam)
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
