#include "CvImageProvider.h"
#include "AuthController.h"
#include "StationNam.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QCoreApplication>
#include <QDateTime>
#include <QPointer>
#include <QQueue>
#include <QThread>
#include <QTimer>
#include <QDir>
#include <QFileInfo>
#include <QStandardPaths>
#include <QMutex>

// The image-response ledger below needs a stack trace, and there is no portable way
// to take one. `execinfo.h` and `unistd.h` are glibc/POSIX and do not exist under
// MSVC — unguarded they broke the Windows build outright (C1083, 2026-09-26), so no
// Windows release could be cut at all while this file was in that state. Windows gets
// the same diagnostic through CaptureStackBackTrace, which is in kernel32 and needs no
// extra link.
#if defined(Q_OS_WIN)
#  include <windows.h>
#else
#  include <execinfo.h>
#  include <unistd.h>
#endif
#include <cstdio>
#include <cstdlib>

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

// ─── P0 LIFECYCLE LEDGER (added 2026-09-25) ──────────────────────────────────
// THREE crashes, 23/24/25 Sep, ONE stack every time:
//     QQuickPixmapReader::asyncResponseFinished(QQuickImageResponse*)
//       → QObject::deleteLater()
//         → QCoreApplicationPrivate::lockThreadPostEventList()   ← dies here
// MEASURED from the three .ips register dumps, not inferred: x0 holds a plausible
// heap pointer while x21 holds a SMALL garbage value (0x27da94 / 0x378018 /
// 0x5b99b0) and the fault address is x21+0x58 in all three. x21 is the QThreadData*
// read out of the response's QObjectPrivate. A garbage QThreadData means the
// QObjectPrivate was freed AND its memory reused — a use-after-free of the
// response, reached through Qt's unconditional deleteLater().
//
// A crash report cannot say WHO freed it: by then the destructor has returned and
// its frames are gone. So this ledger records every lifecycle transition with the
// object ADDRESS — matchable against x0 in the next report — and captures the
// DESTRUCTOR'S OWN BACKTRACE. Two entries are the smoking guns:
//   DTOR  fin=0   → destroyed while Qt still held the pointer (crash is now owed)
//   DUPFIN        → a second completion, the shape the 2026-07-25 P0 was fixed for
// Default ON: the mean time between these crashes is ~9 h, so there is exactly one
// sample per night and no second chance. WT_IMG_LEDGER=0 disables; any other value
// is used as the log path.
static std::atomic<quint64> s_respSeq { 0 };
static QMutex s_ledgerMx;

static FILE *imgLedgerFile()
{
    static FILE *f = nullptr;
    static bool opened = false;
    if (opened)
        return f;
    opened = true;
    QString path = qEnvironmentVariable("WT_IMG_LEDGER");
    if (path == QLatin1String("0"))
        return nullptr;
    if (path.isEmpty()) {
        // `~/Library/Logs` exists on macOS and nowhere else. On Windows fopen() would
        // just fail and the ledger would be silently OFF — a P0 diagnostic that writes
        // nothing on the platform whose releases this station builds. Put it beside the
        // flight recorder instead, which is where anyone debugging this already looks.
#if defined(Q_OS_MACOS)
        path = QDir::homePath() + QLatin1String("/Library/Logs/watchtower-imgresp.log");
#else
        path = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
               + QLatin1String("/watchtower-imgresp.log");
#endif
    }
    QDir().mkpath(QFileInfo(path).absolutePath());   // fopen("a") does NOT create dirs
    f = fopen(path.toLocal8Bit().constData(), "a");
    if (f) {
        setvbuf(f, nullptr, _IOLBF, 0);          // line-buffered: survive a SIGSEGV
        // QCoreApplication::applicationPid() rather than getpid(): same number, and it
        // does not drag <unistd.h> (POSIX-only) in for one field.
        fprintf(f, "\n=== ledger opened %s pid=%lld ===\n",
                qPrintable(QDateTime::currentDateTime().toString(Qt::ISODateWithMs)),
                static_cast<long long>(QCoreApplication::applicationPid()));
        fflush(f);
    }
    return f;
}

// Frames of the CALLER, skipping this helper. This is the one fact the crash report
// cannot carry, and the whole reason the ledger exists.
static QByteArray imgBacktrace(int skip = 2, int want = 12)
{
    void *frames[32];
#if defined(Q_OS_WIN)
    // CaptureStackBackTrace applies `skip` itself, so the walk starts at 0 here.
    // Addresses only, no symbolisation: resolving them needs dbghelp and a loaded
    // symbol server, and this ledger has to survive a SIGSEGV on a guard station
    // that ships no .pdb. An address plus the .pdb we archive per build is enough
    // to name the frame after the fact, and it costs nothing at crash time.
    const int cap = qBound(1, qMin(want, 32 - 1), 32);
    const int n = int(CaptureStackBackTrace(ULONG(skip), ULONG(cap), frames, nullptr));
    QByteArray out;
    for (int i = 0; i < n; ++i) {
        out += "\n        0x";
        out += QByteArray::number(static_cast<qulonglong>(reinterpret_cast<quintptr>(frames[i])), 16);
    }
    return out;
#else
    const int n = backtrace(frames, qMin(skip + want, 32));
    char **syms = backtrace_symbols(frames, n);
    QByteArray out;
    for (int i = skip; i < n; ++i) {
        out += "\n        ";
        out += syms ? syms[i] : "?";
    }
    free(syms);
    return out;
#endif
}

static void imgLedger(const char *ev, const void *obj, quint64 seq,
                      const QByteArray &extra = QByteArray())
{
    FILE *f = imgLedgerFile();
    if (!f)
        return;
    const QThread *t = QThread::currentThread();
    const QByteArray tn = t ? t->objectName().toLocal8Bit() : QByteArray("?");
    // pid ON EVERY LINE, not just the "ledger opened" banner. Learned the hard way
    // 2026-09-25: the app was terminated and relaunched within the same second, and
    // for a minute two instances were appending here. Per-line pid is the only thing
    // that keeps two interleaved lifecycles from reading as one impossible one —
    // e.g. a NEW from one process and a DTOR from the other at the same address.
    QMutexLocker lock(&s_ledgerMx);
    fprintf(f, "%s pid=%d %-9s obj=%p seq=%llu thr=%p[%s] %s\n",
            qPrintable(QDateTime::currentDateTime().toString(QStringLiteral("HH:mm:ss.zzz"))),
            (int)getpid(), ev, obj, (unsigned long long)seq, (const void *)t,
            tn.isEmpty() ? "unnamed" : tn.constData(), extra.constData());
    fflush(f);
}

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
    // fin=0 here is THE BUG, caught at the moment it is created rather than hours
    // later when Qt dereferences us: Qt only deletes a response from inside
    // asyncResponseFinished(), which runs because finished() was emitted. A
    // destructor without finished() therefore means somebody ELSE destroyed us
    // while Qt still holds the pointer, and the backtrace names them.
    imgLedger(m_finished ? "DTOR" : "DTOR-UNFIN", this, m_seq,
              QByteArray("fin=") + (m_finished ? "1" : "0")
              + " gated=" + (m_gated ? "1" : "0")
              + " queued=" + (m_queued ? "1" : "0")
              + " attempt=" + QByteArray::number(m_attempt)
              + " path=" + m_path.right(48).toLocal8Bit()
              + imgBacktrace());
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
    // HAZARD INTRODUCED BY THE ORDERING FIX, closed here. Since finish() hands the
    // object to the pixmap-reader thread, THIS DESTRUCTOR now runs on that thread —
    // and releaseSnapshotSlot() pumps s_poolCached/s_poolExtract, which are
    // GUI-thread-only data (see their comment) and whose pump calls start() on
    // another response. Running it here would be a cross-thread write to the pools
    // on every completed fetch.
    //
    // It is also unnecessary when finished: EVERY caller of finish() releases the
    // slot first — the reply lambda, cancelOnOwnThread(), and both of start()'s
    // early-outs — so a finished response owes the pool nothing. The net is kept
    // exactly where it is still needed: an unfinished destruction, which stays on
    // the GUI thread because the move only happens inside finish().
    if (!m_finished)
        releaseSnapshotSlot();          // never strand a governed-extractor slot
}

// Qt calls cancel() on the PIXMAP-READER thread, from inside
// QQuickPixmapReader::processJobs() while it holds that reader's mutex. So this must
// do two things only: raise the flag, and hop. It must NOT touch m_reply — a
// GUI-thread QNetworkReply — and it must NOT emit finished() synchronously, which
// would re-enter QQuickPixmapReader::asyncResponseFinished() under its own lock and,
// worse, race a queued start() into a second completion (the P0 above).
void CvImageResponse::cancel()
{
    // Runs on the PIXMAP-READER thread. Logged because a cancel arriving after
    // finish() is the window in which Qt can still hold a pointer to us.
    imgLedger("CANCEL", this, m_seq, QByteArray("fin=") + (m_finished ? "1" : "0"));
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
    if (m_finished.exchange(true)) {
        ++s_dupFinish;
        imgLedger("DUPFIN", this, m_seq,
                  QByteArray::number(s_dupFinish) + " path="
                  + m_path.right(48).toLocal8Bit() + imgBacktrace());
        if (s_imgLog || s_dupFinish == 1)
            qWarning("[EVIMG] duplicate finish suppressed (n=%d) %s", s_dupFinish,
                     qPrintable(m_path.right(44)));
        return;
    }
    // ─── THE ORDERING FIX (2026-09-25) ───────────────────────────────────────
    // Hand ourselves back to the pixmap-reader thread BEFORE emitting.
    //
    // Qt's QQuickPixmapReader::asyncResponseFinished() runs on the READER thread and
    // calls deleteLater() on us unconditionally (verified by disassembly: the only
    // QObject::deleteLater stub reached from QQuickPixmapReader is in that function —
    // cancel() has none). deleteLater() posts DeferredDelete to the object's OWN
    // thread. While we belong to the GUI thread those are two independent queues:
    //     reader queue : [ finished#1 ][ finished#2? ]
    //     GUI queue    : [ DeferredDelete ]          ← can run first
    // so the GUI thread can destroy us while a delivery is still queued on the
    // reader, and the reader then dereferences freed memory. That is exactly the
    // fault the three Sep crashes died on (x21 = garbage QThreadData, fault x21+0x58).
    //
    // WHERE THE SECOND DELIVERY COMES FROM — read off the shipped QtQuick 6.11.1
    // (Homebrew ships no sources), 2026-09-25. QQuickPixmapReader::processJob, right
    // after requestImageResponse() returns:
    //   0x1eef08  connectImpl(response, finished -> asyncResponseFinished)   queued
    //   0x1eefe0  ldaprb <response's finished flag>   "did it ALREADY finish?"
    //   0x1ef030  invokeMethodImpl(reader, "asyncResponseFinished", Qt::QueuedConnection)
    // (the name resolves to the cstring at 0x43387c; w2 = 2 = QueuedConnection). A
    // response that finishes BETWEEN the connect and the check is delivered TWICE
    // from ONE finished(). Only a response living on ANOTHER thread can finish inside
    // that window — ours, moved to the GUI thread by requestImageResponse() — and ours
    // can be fast: of 15,009 fetches in the ledger, one finished 1 ms after creation
    // and 11 within 5 ms, so a few ms of reader-thread preemption is all it takes.
    // The flight recorder shows ZERO "duplicate finish suppressed" lines across the
    // 24 and 25 Sep crash runs: finish() ran once; the duplicate was Qt's own.
    //
    // Owned by the reader, the DeferredDelete goes into the SAME queue as the
    // deliveries and is therefore ordered BEHIND every one of them. A late or
    // duplicate delivery finds us alive; destruction happens only once the queue
    // drains. Emission itself stays legal from this thread — the connection type is
    // chosen from the RECEIVER's thread, so finished() is still delivered queued.
    //
    // Safe because nothing touches `this` after finish() returns on any path (every
    // caller makes it the last statement), m_reply is already null here, and the two
    // slots that can still fire late — start() and cancelOnOwnThread() — both early-
    // out on m_finished before touching GUI-thread-only data.
    if (m_readerThread && m_readerThread != QThread::currentThread()
        && m_readerThread->isRunning())
        moveToThread(m_readerThread);
    // Both arms spelled as QByteArray: `cond ? "-" : someQByteArray` mixes
    // `const char[2]` with QByteArray, which GCC resolves and MSVC rejects outright
    // (C2445, ambiguous conditional). Second Linux-ism in this file to stop the
    // Windows build on 2026-09-26.
    imgLedger("FINI", this, m_seq,
              QByteArray("err=") + (m_error.isEmpty() ? QByteArrayLiteral("-") : m_error.toLocal8Bit())
              + " img=" + QByteArray::number(m_image.width()) + "x"
              + QByteArray::number(m_image.height())
              + " path=" + m_path.right(48).toLocal8Bit());
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
    // IDEMPOTENCE, and a precondition of the moveToThread() in finish(). A 503 retry
    // timer or a woken queue entry can still fire after the job finished or was
    // cancelled. Once finish() has run we may already belong to the reader thread, so
    // this path must touch NOTHING — the pools are GUI-thread-only data and
    // releaseSnapshotSlot() would be a cross-thread write.
    if (m_finished) { imgLedger("LATESTART", this, m_seq); return; }
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
    resp->m_seq = ++s_respSeq;
    // THIS thread — the pixmap loader's — is the one Qt will delete the response
    // from. Remember it so finish() can hand the object back before emitting; see
    // the ordering argument there.
    resp->m_readerThread = QThread::currentThread();
    imgLedger("NEW", resp, resp->m_seq,
              QByteArray("req=") + QByteArray::number(requestedSize.width()) + "x"
              + QByteArray::number(requestedSize.height())
              + " path=" + id.right(48).toLocal8Bit());
    // The NAM lives on the GUI thread; move the response there and kick the fetch
    // on that thread (this method runs on the pixmap-loader worker thread).
    resp->moveToThread(m_auth->thread());
    QMetaObject::invokeMethod(resp, &CvImageResponse::start, Qt::QueuedConnection);
    return resp;
}
